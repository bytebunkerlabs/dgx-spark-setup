# DGX Spark setup

A modular, idempotent setup for an NVIDIA DGX Spark (GB10) that gets you from
first boot to: a served model behind an OpenAI-compatible gateway, a RAG store,
a fine-tuning workspace, full GPU/thermal observability, and a staged two-Spark
cluster — built so your agents point at one endpoint, your RAG store has a local
vector store, and you can fine-tune and break things at zero marginal cost.

Everything is re-runnable. ( is a thin launcher for  — they are interchangeable.) Nothing here reinstalls the driver/CUDA (that fights
the DGX OS bundle); the supported path is NGC containers, which is what this uses.

## Quick start

```bash
./install.sh              # puts the dgxsetup command on your PATH (once)
cp .env.example .env      # then EDIT: HF_TOKEN, passwords, model, cluster IPs
dgxsetup preflight      # read-only sanity check of the box
dgxsetup system         # docker group, tooling, dirs   (new shell after this)
dgxsetup security       # ufw + fail2ban + SSH + Tailscale
dgxsetup models         # HF cache + embedding/test models
dgxsetup inference      # serve model + LiteLLM gateway + Open WebUI
dgxsetup rag            # pgvector for RAG
dgxsetup monitoring     # Prometheus + Grafana + nvidia-smi GPU exporter
dgxsetup finetune       # LoRA/QLoRA workspace
dgxsetup cluster detect # QSFP/RDMA discovery (stage/validate when cable lands)
dgxsetup health         # is everything up?
```

`dgxsetup all` runs the base stack (preflight → system → security → models →
inference → rag → monitoring) in order.

## The gotchas this repo already handles (read these once)

1. **Unified memory breaks `nvidia-smi` memory.** The 128GB is shared CPU+GPU,
   so `nvidia-smi` reports memory as *Not Supported*. Use `free -h` (the helper
   `spark-gpu` shows both). Your real model budget is the `free` number.

2. **Buffer cache eats the pool.** After serving/loading big models, Linux page
   cache holds part of the 128GB. The next heavy job (a fine-tune) can OOM with
   capacity "free". Run **`spark-flush-cache`** before switching heavy workloads.

3. **Docker bypasses ufw.** Docker rewrites iptables, so publishing a port to
   `0.0.0.0` exposes it on your LAN regardless of the firewall. Every service
   here publishes to **`127.0.0.1` only**; services talk to each other over the
   compose network. Reach them from your laptop via Tailscale or SSH tunnel:
   ```bash
   tailscale serve --bg --https=443 4000          # gateway over the tailnet
   ssh -N -L 4000:127.0.0.1:4000 spark-01         # or a plain tunnel
   ```

4. **Container tags for aarch64/Blackwell (sm_121) move fast.** The image tags in
   `.env` are sensible defaults, **not guaranteed-current pins**. Verify against
   the NGC catalog, the official playbook READMEs, and the community image index
   (all linked in `.env`) before first pull. `flash-attn` in particular needs an
   sm_121-patched wheel for training.

5. **Only the first-boot account can apply OS/firmware updates**, via the DGX
   Dashboard on `http://localhost:11000`. Leave that on loopback; don't expose it.

## How the pieces map to your work

- **Your agents** → point every agent at the LiteLLM gateway
  (`http://<spark>:4000/v1`, one API key, one model name `primary`). The gateway
  logs every request, standard gateway audit discipline. vLLM/SGLang
  behind it does continuous batching, which is exactly the concurrent-agent
  pattern the Spark is tuned for.
- **Your RAG store** → `pgvector` is the store (768-dim to match `nomic-embed-text`),
  embeddings served through the same gateway. Multilingual `lang` column and a
  JSONB `metadata` column are already in the schema.
- **Fine-tuning** → QLoRA up to ~70B on one node from the NGC PyTorch container.
  Local = iterate freely, no per-token cost.
- **Thermal A/B testing** → the monitoring stack (90-day Prometheus retention; nvidia-smi GPU exporter, since DCGM is memory-blind on GB10) plus
  the standalone `08-thermal.sh` logger capture sustained SM-clock-% and
  throttle-active time. Run one labeled `baseline`, one `with-cooler`, same load
  and duration, and diff them. That delta is your answer.

## Your own TP/PP test lab (multinode)

`11-multinode.sh` is the owned experiment rig — Ray + vLLM directly, no wrapper,
with the parallelism strategy as a dial and `bench/bench.py` (zero-dependency)
measuring throughput / latency / TTFT so *your* numbers decide.

```bash
dgxsetup multinode ray-up            # Ray head (this box) + worker (peer), NCCL pinned to RoCE
dgxsetup multinode serve pp          # launch BIG_MODEL pipeline-parallel (or: serve tp)
dgxsetup multinode bench pp          # one load test against the live endpoint
dgxsetup multinode compare           # serve TP → bench → serve PP → bench, side-by-side table
dgxsetup multinode boundaries pp     # sweep concurrency + context length until it breaks
dgxsetup multinode ray-down          # tear the cluster down, free the port
```

What each topology is testing: `tp` splits every layer across both GPUs (all-reduce
every layer — low latency, hammers your ~100 Gbps link); `pp` splits the layer stack
into two stages (one handoff per token — light on the link, high throughput via
micro-batching). `compare` runs both on identical load; `boundaries` finds where
deployment breaks — the concurrency knee (throughput saturates) and the context wall
(a prompt long enough to OOM). Results land in `~/dgx/multinode-results/*.csv` to
chart. Watch the serve logs for `NET/IB` (RDMA engaged) vs `NET/Socket` (TCP
fallback). Prereqs: fabric staged, passwordless SSH head→worker, HF token; `serve`
rsyncs the model to the worker for you.

## Pooled "big" model across both Sparks (cluster-serve)

Two serving modes now live in the gateway, and they're **mutually exclusive on
memory** — a big tensor-parallel model claims most of both boxes' 128 GB, so you
can't hold it *and* the single-node fast model on the head at once:

- **fast** — single-node engine (`dgxsetup inference`), served as gateway model
  `primary`, on host port `INFER_PORT` (default now `8001`).
- **big** — one large model split across BOTH Sparks via tensor parallelism,
  served as gateway model `big`, on host port `BIG_PORT` (default `8000`).

The big path wraps the community repo `mark-ramsey-ri/vllm-dgx-spark` (Ray +
NCCL over your RoCE fabric). Because you already staged and validated the link
with `09-cluster.sh`, that repo's entire OS-setup section is skipped.

```bash
# one-time: set CLUSTER_WORKER_MGMT (worker's LAN/Tailscale IP) + BIG_MODEL in .env, then
dgxsetup cluster-serve setup     # clone repo, generate its config, preflight (SSH/fabric/HF)
dgxsetup cluster-serve start     # launch the pooled model; exposes it as gateway model 'big'
dgxsetup cluster-serve status    # up? which model?
dgxsetup cluster-serve stop      # frees :8000 for the fast engine again
```

Prereqs the launcher checks for you: peer reachable (fabric up), **passwordless
SSH from head→worker** (`ssh-copy-id <user>@<worker>`), and `HF_TOKEN`. Two manual
notes it prints: symlink `/raid/hf-cache → $HF_HOME` to reuse downloads, and
`docker login nvcr.io` if the NGC image pull 401s. Apps switch modes by asking the
gateway for `"big"` vs `"primary"` — no code changes. If you change `BIG_MODEL`,
run `dgxsetup cluster-serve sync-gateway` to re-point the `big` route.

## Two-Spark cluster (when the MCP1650-V001E30 arrives)

The QSFP link negotiates 200GbE, but the ConnectX-7 sits on a **PCIe Gen5 x4**
lane, so real cross-node throughput is **~100 Gbps**, not 200. Plan around that.
For your mixed workload (serve + fine-tune + RAG), **two independent nodes often
beat one tightly-sharded pair** — only span both when a single model exceeds the
128GB pool (that's the ~405B-parameter territory NVIDIA cites for two units).

`09-cluster.sh` does the safe parts: device discovery, static point-to-point IP +
jumbo MTU, and TCP/RDMA validation. The **authoritative multi-node inference
bring-up** (llama.cpp RPC / multi-node vLLM) lives in NVIDIA's official
`connect-two-sparks` playbook — this repo stages the link so that's a short hop.

## Layout

```
setup.sh                orchestrator (subcommands, incl. `reset`)
reset.sh                tiered teardown: stacks | images | data | all
.env.example            central config — copy to .env and edit
lib/common.sh           shared helpers (logging, guards, idempotent apt)
scripts/                00 preflight → 11 multinode
compose/                inference.yml, rag.yml, monitoring.yml
config/                 litellm.config.yaml, prometheus.yml, rag-init.sql
helpers/                spark-gpu, spark-flush-cache, spark-health
```

## Caveats

These scripts are written against the documented DGX OS 7.x environment and the
official playbooks. They were **not** executed on GB10 hardware to produce this
repo, so run `preflight` first and expect to verify image tags. Every module is
idempotent and safe to re-run.
