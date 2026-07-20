#!/usr/bin/env bash
# 04-inference.sh — bring up the primary inference endpoint + gateway + UI.
# Serves ${PRIMARY_MODEL} via vLLM or SGLang, fronted by LiteLLM on :${LITELLM_PORT}.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_dgx

COMPOSE="docker compose -f ${REPO_ROOT}/compose/inference.yml --env-file ${REPO_ROOT}/.env"
ENGINE="${INFER_ENGINE:-vllm}"

step "Inference stack (engine: ${ENGINE})"

case "$ENGINE" in
  vllm|sglang) : ;;
  *) die "INFER_ENGINE must be 'vllm' or 'sglang' (got '${ENGINE}')." ;;
esac

warn "Reminder: verify the ${ENGINE^^} image tag in .env against the NGC catalog"
warn "and the official playbook README before first pull (aarch64/sm_121 moves fast)."

log "Pulling images (first run downloads several GB)…"
$COMPOSE --profile "$ENGINE" pull || warn "pull hit an issue — check the image tag in .env"

log "Starting containers…"
$COMPOSE --profile "$ENGINE" up -d

echo
log "Waiting for the engine to become healthy (weights map into the UMA pool — a 30B+ can take 10-15 min on first load)…"
for i in $(seq 1 100); do
  if curl -sf "http://127.0.0.1:${INFER_PORT}/health" >/dev/null 2>&1; then
    ok "Engine healthy on 127.0.0.1:${INFER_PORT}"
    break
  fi
  sleep 10
  [[ $i -eq 100 ]] && warn "Still not reporting healthy — a big model may just need more time. This is usually NOT a failure; watch it finish loading: $COMPOSE --profile $ENGINE logs -f ${ENGINE}"
done

# --- smoke test through the gateway ----------------------------------------
log "Smoke-testing the LiteLLM gateway…"
sleep 3
resp="$(curl -sf "http://127.0.0.1:${LITELLM_PORT}/v1/chat/completions" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${SERVED_MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with: gateway ok\"}],\"max_tokens\":16}" \
  2>/dev/null || true)"
if echo "$resp" | grep -qi 'ok'; then
  ok "Gateway round-trip works."
else
  warn "No clean gateway response yet (engine may still be loading). Raw: ${resp:0:200}"
fi

echo
ok "Inference stack up."
cat <<EOF

  Point your apps here (OpenAI-compatible):
    Base URL : http://127.0.0.1:${LITELLM_PORT}/v1   (or over Tailscale, see below)
    API key  : ${LITELLM_MASTER_KEY}
    Model    : ${SERVED_MODEL_NAME}

  Your apps: set OPENAI_API_BASE + OPENAI_API_KEY to the above.

  Chat UI (Open WebUI): http://127.0.0.1:${OPENWEBUI_PORT}

  Reach from your laptop (loopback-bound on purpose):
    tailscale serve --bg --https=443 ${LITELLM_PORT}      # gateway over tailnet w/ TLS
    # or an SSH tunnel:
    ssh -N -L ${LITELLM_PORT}:127.0.0.1:${LITELLM_PORT} ${SPARK_HOSTNAME}

  Logs:  $COMPOSE --profile ${ENGINE} logs -f
  Stop:  $COMPOSE --profile ${ENGINE} down
EOF
log "Next: ./setup.sh rag   (pgvector for RAG)   then   ./setup.sh monitoring"
