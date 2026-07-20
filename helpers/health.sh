#!/usr/bin/env bash
# spark-health — one-shot health check of the local stack endpoints.
set -euo pipefail

# Load ports from the repo .env if we can find it; else use defaults.
for cand in "$HOME/dgx-spark-setup/.env" "$(dirname "$0")/../.env"; do
  [[ -f "$cand" ]] && { set -a; . "$cand"; set +a; break; }
done
: "${INFER_PORT:=8001}"; : "${LITELLM_PORT:=4000}"; : "${OPENWEBUI_PORT:=3000}"
: "${GRAFANA_PORT:=3001}"; : "${PROMETHEUS_PORT:=9090}"; : "${PG_PORT:=5432}"
: "${GPU_EXPORTER_PORT:=9835}"; : "${BIG_PORT:=8000}"

check() {  # name url
  if curl -sf -o /dev/null --max-time 3 "$2"; then
    printf '  \033[0;32m[up]\033[0m   %-14s %s\n' "$1" "$2"
  else
    printf '  \033[0;31m[down]\033[0m %-14s %s\n' "$1" "$2"
  fi
}
port() {   # name host:port
  if (exec 3<>"/dev/tcp/${2%%:*}/${2##*:}") 2>/dev/null; then
    printf '  \033[0;32m[up]\033[0m   %-14s %s\n' "$1" "$2"; exec 3>&- 2>/dev/null || true
  else
    printf '  \033[0;31m[down]\033[0m %-14s %s\n' "$1" "$2"
  fi
}

echo "Local stack health:"
check "engine(fast)" "http://127.0.0.1:${INFER_PORT}/health"
check "cluster(big)"  "http://127.0.0.1:${BIG_PORT}/health"
check "gateway"    "http://127.0.0.1:${LITELLM_PORT}/health/liveliness"
check "open-webui" "http://127.0.0.1:${OPENWEBUI_PORT}"
check "grafana"    "http://127.0.0.1:${GRAFANA_PORT}/api/health"
check "prometheus" "http://127.0.0.1:${PROMETHEUS_PORT}/-/healthy"
check "gpu-exporter" "http://127.0.0.1:${GPU_EXPORTER_PORT}/metrics"
port  "postgres"   "127.0.0.1:${PG_PORT}"
port  "ollama"     "127.0.0.1:11434"
port  "dashboard"  "127.0.0.1:11000"
