#!/usr/bin/env bash
# reset.sh — tear down what this project created, to start fresh.
# Drop this in the repo root (next to setup.sh) and run a tier:
#
#   ./reset.sh stacks   containers + their volumes + networks   (KEEPS images & model cache)
#   ./reset.sh images   stacks + the Docker images we pulled     (forces re-pull later)
#   ./reset.sh data     stacks + ~/dgx (models, logs, finetune) + cluster netplan + env snippet + .env
#   ./reset.sh all      stacks + images + data  (clean slate, minus OS + security hardening)
#
# Does NOT touch: DGX OS, drivers/CUDA, or ufw/fail2ban/SSH/Tailscale hardening
# (revert notes printed at the end). For a true OS wipe, use NVIDIA's factory
# recovery via the DGX Dashboard — not this script. Run it on EACH Spark.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh" 2>/dev/null || { echo "Run from the repo root (needs lib/common.sh)."; exit 1; }

# Catch containers/volumes/networks from every project name this repo has used,
# old and new, via the compose project label — no hardcoded resource names.
PROJECTS=(compose dgx-inference dgx-rag dgx-monitoring)
MANUAL_LEFTOVERS=(open-webui)   # from the early manual docker runs

reset_stacks() {
  step "Containers, volumes, networks for: ${PROJECTS[*]}"
  for p in "${PROJECTS[@]}"; do
    local ids vols nets
    ids=$(docker ps -aq  --filter "label=com.docker.compose.project=$p" 2>/dev/null || true)
    [[ -n "$ids"  ]] && { log "rm containers ($p)"; echo "$ids"  | xargs -r docker rm -f       >/dev/null; }
    vols=$(docker volume ls -q --filter "label=com.docker.compose.project=$p" 2>/dev/null || true)
    [[ -n "$vols" ]] && { log "rm volumes ($p)";    echo "$vols" | xargs -r docker volume rm   >/dev/null; }
    nets=$(docker network ls -q --filter "label=com.docker.compose.project=$p" 2>/dev/null || true)
    [[ -n "$nets" ]] && { log "rm networks ($p)";   echo "$nets" | xargs -r docker network rm  >/dev/null 2>&1 || true; }
  done
  for c in "${MANUAL_LEFTOVERS[@]}"; do
    docker rm -f "$c" >/dev/null 2>&1 && log "removed leftover container: $c" || true
  done
  ok "Stacks torn down."
}

reset_images() {
  step "Docker images this project pulled"
  local envf="${REPO_ROOT}/.env"; [[ -f "$envf" ]] || envf="${REPO_ROOT}/.env.example"
  # shellcheck disable=SC1090
  set -a; source "$envf" 2>/dev/null || true; set +a
  local imgs=("${VLLM_IMAGE:-}" "${SGLANG_IMAGE:-}" "${LITELLM_IMAGE:-}" "${OPENWEBUI_IMAGE:-}" \
              "${PGVECTOR_IMAGE:-}" "${PROMETHEUS_IMAGE:-}" "${GRAFANA_IMAGE:-}" \
              "${NODE_EXPORTER_IMAGE:-}" "${GPU_EXPORTER_IMAGE:-}" "${NGC_PYTORCH_IMAGE:-}")
  for i in "${imgs[@]}"; do
    [[ -n "$i" ]] || continue
    docker image rm "$i" >/dev/null 2>&1 && log "removed image: $i" || true
  done
  ok "Images removed — they re-pull on next 'up'."
}

reset_data() {
  step "Project data + local config"
  if [[ -f "${REPO_ROOT}/.env" ]]; then
    cp "${REPO_ROOT}/.env" "${REPO_ROOT}/.env.bak"
    ok "Backed up .env -> .env.bak (so you don't lose your HF token)"
    rm -f "${REPO_ROOT}/.env"
  fi
  local droot="${DATA_ROOT:-$HOME/dgx}"
  if [[ -d "$droot" ]]; then
    local sz; sz=$(du -sh "$droot" 2>/dev/null | cut -f1 || echo "?")
    warn "Delete ${droot} (${sz}) — includes downloaded models + thermal logs + finetune workspace."
    if confirm "Delete ${droot}?"; then rm -rf "$droot"; ok "Deleted ${droot}"; else warn "Kept ${droot}"; fi
  fi
  if [[ -f /etc/netplan/99-spark-cluster.yaml ]]; then
    sudo_ rm -f /etc/netplan/99-spark-cluster.yaml
    sudo_ netplan apply 2>/dev/null || true
    ok "Removed cluster netplan drop-in (point-to-point IPs reverted)"
  fi
  rm -f "${HOME}/.config/dgx-spark.env.sh"
  sed -i '/dgx-spark.env.sh/d' "${HOME}/.bashrc" 2>/dev/null || true
  rm -f "${HOME}/.local/bin/spark-gpu" "${HOME}/.local/bin/spark-flush-cache" "${HOME}/.local/bin/spark-health"
  ok "Removed env snippet + helper commands."
}

manual_notes() {
  cat <<EOF

  Left untouched on purpose (revert manually only if you truly want to):
    Firewall:   sudo ufw disable
    fail2ban:   sudo systemctl disable --now fail2ban
    SSH:        sudo rm /etc/ssh/sshd_config.d/99-dgx-hardening.conf && sudo systemctl restart ssh
                (^ RE-ENABLES password auth — you almost never want this)
    Tailscale:  sudo tailscale down        (or 'tailscale logout' to unlink the node)
    Ollama:     stock DGX OS service — leave it.

  For a full OS wipe (true factory reset): use NVIDIA's recovery flow via the
  DGX Dashboard / recovery image, not this script.

  Start clean after reset:
    dgxsetup preflight            # recreates .env from template
    # edit .env (HF_TOKEN, passwords), then:
    dgxsetup system && dgxsetup security && dgxsetup models && dgxsetup inference
EOF
}

CMD="${1:-}"
case "$CMD" in
  stacks|images|data|all) : ;;
  *) echo "Usage: $0 {stacks|images|data|all}"; grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

warn "Tier '${CMD}' will remove resources on THIS node. This cannot be undone."
confirm "Proceed with '${CMD}' reset?" || { warn "Aborted — nothing changed."; exit 0; }

case "$CMD" in
  stacks) reset_stacks ;;
  images) reset_stacks; reset_images ;;
  data)   reset_stacks; reset_data ;;
  all)    reset_stacks; reset_images; reset_data ;;
esac
manual_notes
ok "Reset complete on this node (tier: ${CMD})."
