#!/usr/bin/env bash
# 00-preflight.sh — verify the DGX Spark environment. Changes NOTHING.
# Run this first. It confirms the box is what we think it is and that the
# preinstalled NVIDIA stack (driver, CUDA, Docker, container toolkit) is live.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

step "DGX Spark preflight"

# --- identity ---------------------------------------------------------------
if [[ -r /proc/device-tree/model ]]; then
  ok "Board model: $(tr -d '\0' < /proc/device-tree/model)"
fi
ok "Kernel: $(uname -sr)  Arch: $(uname -m)"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release; ok "OS: ${PRETTY_NAME:-unknown}"
fi
[[ "$(uname -m)" == "aarch64" ]] || warn "Arch is not aarch64 — DGX Spark is ARM. Are you on the box?"

# --- GPU / driver -----------------------------------------------------------
if have nvidia-smi; then
  ok "nvidia-smi present"
  nvidia-smi --query-gpu=name,driver_version,temperature.gpu,power.draw,clocks.sm \
             --format=csv,noheader 2>/dev/null | sed 's/^/    GPU: /' || true
  warn "Reminder: nvidia-smi memory shows 'Not Supported' on the Spark (unified memory). Use 'free -h'."
else
  err "nvidia-smi not found — the NVIDIA driver stack is expected preinstalled on DGX OS."
fi

# --- CUDA -------------------------------------------------------------------
if have nvcc; then ok "CUDA toolkit: $(nvcc --version | awk '/release/{print $6}' | tr -d ',')"
else warn "nvcc not on PATH (fine — the supported path is running CUDA inside NGC containers)."; fi

# --- memory (the real number, since nvidia-smi won't show it) ---------------
step "Unified memory (this is your model budget)"
free -h | sed 's/^/    /'

# --- Docker + NVIDIA runtime ------------------------------------------------
step "Container runtime"
if have docker; then
  ok "docker: $(docker --version)"
  if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -qi 'nvidia' \
     || docker info 2>/dev/null | grep -qi 'nvidia'; then
    ok "NVIDIA container runtime registered"
  else
    warn "NVIDIA runtime not detected via 'docker info' (newer Docker formats this differently — if your GPU containers run, ignore this)."
  fi
  if docker ps >/dev/null 2>&1; then
    ok "Current user can run docker without sudo"
  else
    warn "Cannot run docker as this user yet. Fix with 01-system.sh (adds you to the 'docker' group)."
  fi
else
  err "docker not found — expected preinstalled on DGX OS."
fi

# --- DGX Dashboard (preinstalled web UI on :11000) --------------------------
if ss -ltn 2>/dev/null | grep -q ':11000'; then
  ok "DGX Dashboard is listening on http://localhost:11000"
else
  warn "DGX Dashboard (:11000) not detected — it's the preinstalled monitoring/JupyterLab hub."
fi

# --- disk -------------------------------------------------------------------
step "Disk"
df -h / "${HOME}" 2>/dev/null | sort -u | sed 's/^/    /'

# --- networking / RDMA (for the future two-Spark cluster) -------------------
step "QSFP / RDMA (for clustering later)"
if have ibdev2netdev; then
  ibdev2netdev 2>/dev/null | sed 's/^/    /' || true
elif have rdma; then
  rdma link 2>/dev/null | sed 's/^/    /' || true
else
  warn "RDMA userspace tools not installed yet (perftest / rdma-core). 09-cluster.sh installs them."
fi

echo
ok "Preflight complete. Nothing was modified."
log "Next: cp .env.example .env  &&  edit it  &&  run ./setup.sh system"
