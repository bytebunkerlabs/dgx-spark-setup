#!/usr/bin/env bash
# 03-model-cache.sh — prime the model caches. Ollama is preinstalled on DGX OS,
# so we use it for the quick-experiment path + embeddings. HF cache is pointed at
# the internal NVMe. Nothing here loads into the 128GB pool until a model runs.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_dgx

step "Model cache + initial pulls"

export HF_HOME OLLAMA_MODELS
mkdir -p "$HF_HOME" "$MODELS_DIR" "$OLLAMA_MODELS"

# --- Hugging Face auth (needed for gated repos like Llama) ------------------
if [[ -n "${HF_TOKEN}" ]]; then
  if ! have huggingface-cli; then
    log "Installing huggingface_hub CLI (user-local via pipx)"
    have pipx && pipx install "huggingface_hub[cli]" >/dev/null 2>&1 || \
      pip install --user --break-system-packages "huggingface_hub[cli]" >/dev/null 2>&1 || true
  fi
  if have huggingface-cli; then
    huggingface-cli login --token "${HF_TOKEN}" --add-to-git-credential >/dev/null 2>&1 \
      && ok "Logged into Hugging Face" || warn "HF login failed — check HF_TOKEN"
  fi
else
  warn "HF_TOKEN empty in .env — gated models (Llama, etc.) won't download. Public models still work."
fi

# --- Ollama: quick-path models ----------------------------------------------
if have ollama; then
  ok "Ollama present: $(ollama --version 2>/dev/null | head -n1)"
  log "Pulling embedding model for RAG: ${EMBED_MODEL}"
  ollama pull "${EMBED_MODEL}" || warn "Could not pull ${EMBED_MODEL}"

  if confirm "Also pull a small general model (llama3.2:3b) for a quick smoke test?"; then
    ollama pull llama3.2:3b || warn "pull failed"
    log "Smoke test:"
    ollama run llama3.2:3b "Reply with exactly: DGX Spark online." 2>/dev/null | sed 's/^/    /' || true
  fi
else
  warn "Ollama not found — it ships preinstalled on DGX OS. Skipping quick-path pulls."
fi

echo
ok "Model cache ready."
log "HF cache:     ${HF_HOME}"
log "Ollama store: ${OLLAMA_MODELS}"
log "Next: dgxsetup inference   (serve ${PRIMARY_MODEL} + LiteLLM gateway + Open WebUI)"
