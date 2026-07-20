#!/usr/bin/env bash
# 11-multinode.sh — YOUR OWN multi-node serving lab (no third-party wrapper).
#
# Built directly on the primitives: a Ray cluster (head on this box, worker on the
# peer) with NCCL pinned to your RoCE fabric, then ONE `vllm serve` with the
# parallelism strategy as a dial. Flip between tensor- and pipeline-parallel,
# benchmark each with bench/bench.py, and sweep concurrency + context length until
# it breaks — so you find the deployment boundaries by measurement, not guesswork.
#
# Recap of the physics you're testing:
#   TP=2  — splits every layer across both GPUs, all-reduce EVERY layer. Lowest
#           latency, but hammers your ~100 Gbps link. Expect link-bound.
#   PP=2  — splits the layer stack into 2 stages, ONE handoff per token. Light on
#           the link; micro-batching keeps both GPUs busy → high throughput.
#
# Subcommands:
#   dgxsetup multinode ray-up               start the Ray cluster (head + worker)
#   dgxsetup multinode serve tp|pp          launch the model with that topology
#   dgxsetup multinode bench [tp|pp]        one benchmark against the live endpoint
#   dgxsetup multinode compare              serve TP→bench→serve PP→bench, side by side
#   dgxsetup multinode boundaries tp|pp     sweep concurrency + context until it breaks
#   dgxsetup multinode status               what's running
#   dgxsetup multinode stop                 stop the vLLM server (keep Ray up)
#   dgxsetup multinode ray-down             tear the whole Ray cluster down
#
# Prereqs (same as the cluster path): fabric up, passwordless SSH head→worker,
# HF token, and the model present on BOTH nodes (serve rsyncs it for you).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_dgx

WORKER="${CLUSTER_WORKER_USER:-$USER}@${CLUSTER_WORKER_MGMT}"
HEAD_IP="${CLUSTER_LOCAL_IP}"          # this node on the fabric (192.168.100.1)
RAY_PORT="${RAY_PORT:-6379}"
IMG="${VLLM_IMAGE}"
RESULTS="${DATA_ROOT}/multinode-results"
mkdir -p "$RESULTS"

# ---- NCCL env pinned to your validated RoCE fabric ------------------------
nccl_hca() {                            # auto-detect the RDMA device for the link iface
  [[ -n "${NCCL_IB_HCA:-}" ]] && { echo "$NCCL_IB_HCA"; return; }
  ibdev2netdev 2>/dev/null | awk -v i="${CLUSTER_QSFP_IFACE}" '$0 ~ i {print $1; exit}'
}
nccl_env_args() {
  local hca; hca="$(nccl_hca)"
  printf ' -e NCCL_SOCKET_IFNAME=%s -e GLOO_SOCKET_IFNAME=%s -e NCCL_IB_DISABLE=0 -e NCCL_NET_GDR_LEVEL=5 -e NCCL_DEBUG=WARN' \
    "${CLUSTER_QSFP_IFACE}" "${CLUSTER_QSFP_IFACE}"
  [[ -n "$hca" ]] && printf ' -e NCCL_IB_HCA=%s' "$hca"
}

precheck() {
  [[ -n "${CLUSTER_WORKER_MGMT}" ]] || die "Set CLUSTER_WORKER_MGMT in .env (worker's LAN/Tailscale IP)."
  ping -c1 -W2 "${CLUSTER_PEER_IP}" >/dev/null 2>&1 || die "Peer ${CLUSTER_PEER_IP} unreachable — stage the fabric first (dgxsetup cluster stage)."
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$WORKER" true 2>/dev/null || die "No passwordless SSH to $WORKER — run: ssh-copy-id $WORKER"
}

sync_model() {
  log "Ensuring the model cache is on the worker (rsync — idempotent, skips unchanged)…"
  ssh "$WORKER" "mkdir -p ${HF_HOME}" 2>/dev/null || true
  rsync -a "${HF_HOME}/" "${WORKER}:${HF_HOME}/" 2>/dev/null \
    && ok "Model cache in sync." || warn "rsync had issues — the worker may re-download its shard."
}

# ---------------------------------------------------------------------------
ray_up() {
  step "Start Ray cluster (head=${HEAD_IP}, worker=${CLUSTER_PEER_IP})"
  precheck
  local ncc; ncc="$(nccl_env_args)"
  local common="--network host --gpus all --ipc host --shm-size=16g -e HUGGING_FACE_HUB_TOKEN=${HF_TOKEN} -v ${HF_HOME}:/root/.cache/huggingface ${ncc}"

  log "Head container…"
  # shellcheck disable=SC2086
  docker rm -f ray-head >/dev/null 2>&1 || true
  docker run -d --name ray-head $common "$IMG" \
    bash -c "ray start --head --node-ip-address=${HEAD_IP} --port=${RAY_PORT} --dashboard-host=0.0.0.0 && sleep infinity" >/dev/null
  ok "ray-head up."

  log "Worker container on ${WORKER}…"
  # shellcheck disable=SC2086
  ssh "$WORKER" "docker rm -f ray-worker >/dev/null 2>&1; docker run -d --name ray-worker $common $IMG bash -c 'ray start --address=${HEAD_IP}:${RAY_PORT} --node-ip-address=${CLUSTER_PEER_IP} --block'" >/dev/null \
    && ok "ray-worker up." || die "Failed to start worker container."

  log "Waiting for both nodes to join Ray…"
  for i in $(seq 1 24); do
    if docker exec ray-head ray status 2>/dev/null | grep -q "2 node"; then
      ok "Ray cluster formed (2 nodes)."; docker exec ray-head ray status 2>/dev/null | sed 's/^/    /' | head -12; return 0
    fi
    sleep 5
  done
  warn "Ray didn't show 2 nodes yet. Check: docker exec ray-head ray status"
}

serve() {
  local topo="${1:-pp}"; local tp pp
  case "$topo" in
    tp) tp="${BIG_TP:-2}"; pp=1 ;;
    pp) tp=1; pp="${BIG_TP:-2}" ;;
    *) die "topology must be 'tp' or 'pp'." ;;
  esac
  step "Serve ${BIG_MODEL} — topology=${topo^^} (TP=${tp} PP=${pp})"
  docker ps --format '{{.Names}}' | grep -q '^ray-head$' || die "Ray not up. Run: dgxsetup multinode ray-up"
  sync_model

  docker exec ray-head pkill -f 'vllm serve' 2>/dev/null || true; sleep 2
  log "Launching vLLM on the Ray cluster (logs → /tmp/vllm-serve.log in ray-head)…"
  docker exec -d ray-head bash -c "vllm serve '${BIG_MODEL}' \
    --distributed-executor-backend ray \
    --tensor-parallel-size ${tp} --pipeline-parallel-size ${pp} \
    --host 0.0.0.0 --port ${BIG_PORT} \
    --gpu-memory-utilization ${BIG_GPU_MEM_UTIL} --max-model-len ${BIG_MAX_MODEL_LEN} \
    > /tmp/vllm-serve.log 2>&1"

  log "Waiting for the endpoint on :${BIG_PORT} (sharded loads are slow; watch NET/IB in logs)…"
  for i in $(seq 1 120); do
    if curl -sf "http://127.0.0.1:${BIG_PORT}/health" >/dev/null 2>&1; then
      ok "Serving ${topo^^} on :${BIG_PORT}."
      docker exec ray-head grep -m1 -E 'NET/(IB|Socket)' /tmp/vllm-serve.log 2>/dev/null | sed 's/^/    NCCL transport: /' || true
      return 0
    fi
    # surface a hard failure early instead of waiting the full 20 min
    if docker exec ray-head grep -qiE 'error|traceback|out of memory' /tmp/vllm-serve.log 2>/dev/null; then
      err "vLLM reported an error while loading (topology=${topo}). Last lines:"
      docker exec ray-head tail -n 15 /tmp/vllm-serve.log | sed 's/^/    /'
      return 1
    fi
    sleep 10
  done
  warn "Not healthy yet — tail: docker exec ray-head tail -f /tmp/vllm-serve.log"
  return 1
}

bench() {
  local label="${1:-live}"
  local conc="${BENCH_CONCURRENCY:-8}" inl="${BENCH_INPUT_TOKENS:-512}" outl="${BENCH_OUTPUT_TOKENS:-128}"
  curl -sf "http://127.0.0.1:${BIG_PORT}/health" >/dev/null 2>&1 || die "No endpoint on :${BIG_PORT}. Serve first."
  python3 "${REPO_ROOT}/bench/bench.py" \
    --url "http://127.0.0.1:${BIG_PORT}/v1" --model "${BIG_MODEL}" \
    --concurrency "$conc" --input-tokens "$inl" --output-tokens "$outl" \
    --label "$label" --csv "${RESULTS}/bench.csv" || true
}

compare() {
  step "Compare TP vs PP on identical load"
  local out="${RESULTS}/compare_$(date +%Y%m%d-%H%M%S).csv"
  BENCH_CSV="$out"
  for topo in tp pp; do
    if serve "$topo"; then
      log "Warming up…"; sleep 3
      python3 "${REPO_ROOT}/bench/bench.py" --url "http://127.0.0.1:${BIG_PORT}/v1" \
        --model "${BIG_MODEL}" --concurrency "${BENCH_CONCURRENCY:-8}" \
        --input-tokens "${BENCH_INPUT_TOKENS:-512}" --output-tokens "${BENCH_OUTPUT_TOKENS:-128}" \
        --label "$topo" --csv "$out" || warn "$topo bench failed (possible OOM/boundary)."
    else
      warn "$topo failed to serve — recording as a boundary."
    fi
    docker exec ray-head pkill -f 'vllm serve' 2>/dev/null || true; sleep 3
  done
  echo; ok "Comparison written: $out"; echo
  [[ -f "$out" ]] && column -s, -t < "$out"
  log "Read it: higher throughput_tok_s wins for your agent swarm; lower ttft/lat wins for interactive use."
}

boundaries() {
  local topo="${1:-pp}"
  step "Boundary sweep — topology=${topo^^} (find where deployment breaks)"
  serve "$topo" || die "Couldn't serve ${topo} at baseline — lower BIG_MAX_MODEL_LEN or pick a smaller model."
  local out="${RESULTS}/boundaries_${topo}_$(date +%Y%m%d-%H%M%S).csv"

  log "Sweep 1: concurrency (fixed 512-in / 128-out) — throughput scaling + saturation"
  for c in 1 2 4 8 16 32 64; do
    python3 "${REPO_ROOT}/bench/bench.py" --url "http://127.0.0.1:${BIG_PORT}/v1" \
      --model "${BIG_MODEL}" --concurrency "$c" --input-tokens 512 --output-tokens 128 \
      --label "conc${c}" --csv "$out" || { warn "Broke at concurrency=$c — boundary found."; break; }
  done

  log "Sweep 2: context length (fixed concurrency 4) — how long a prompt it survives"
  for L in 512 2048 8192 16384 32768 65536; do
    [[ "$L" -gt "${BIG_MAX_MODEL_LEN}" ]] && { warn "Skipping L=$L (> BIG_MAX_MODEL_LEN=${BIG_MAX_MODEL_LEN}); raise it to probe further."; break; }
    python3 "${REPO_ROOT}/bench/bench.py" --url "http://127.0.0.1:${BIG_PORT}/v1" \
      --model "${BIG_MODEL}" --concurrency 4 --input-tokens "$L" --output-tokens 128 \
      --label "ctx${L}" --csv "$out" || { warn "Broke at context=$L — that's your prompt ceiling for ${topo}."; break; }
  done

  echo; ok "Boundary data: $out"
  [[ -f "$out" ]] && column -s, -t < "$out"
  log "Chart throughput_tok_s vs concurrency (saturation knee) and vs input_tokens (memory wall)."
  log "Where ok<total or it 'Broke' = the deployment boundary for this topology."
}

status() {
  step "Multi-node status"
  docker ps --filter "name=ray-" --format '    {{.Names}}\t{{.Status}}' || true
  docker exec ray-head ray status 2>/dev/null | sed 's/^/    /' | head -10 || warn "ray-head not running."
  if curl -sf "http://127.0.0.1:${BIG_PORT}/health" >/dev/null 2>&1; then
    ok "Endpoint healthy on :${BIG_PORT}"
    docker exec ray-head grep -m1 -E 'NET/(IB|Socket)' /tmp/vllm-serve.log 2>/dev/null | sed 's/^/    NCCL: /' || true
  else
    warn "No live endpoint on :${BIG_PORT}."
  fi
}

stop() { docker exec ray-head pkill -f 'vllm serve' 2>/dev/null && ok "vLLM stopped (Ray still up)." || warn "No vLLM process found."; }

ray_down() {
  step "Tear down Ray cluster"
  ssh "$WORKER" "docker rm -f ray-worker >/dev/null 2>&1" 2>/dev/null && ok "worker removed." || warn "worker cleanup skipped."
  docker rm -f ray-head >/dev/null 2>&1 && ok "head removed." || warn "head already gone."
  log "Port ${BIG_PORT} is free — single-node fast engine can take it back."
}

case "${1:-help}" in
  ray-up)     ray_up ;;
  serve)      serve "${2:-pp}" ;;
  bench)      bench "${2:-live}" ;;
  compare)    compare ;;
  boundaries) boundaries "${2:-pp}" ;;
  status)     status ;;
  stop)       stop ;;
  ray-down)   ray_down ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' ;;
esac
