#!/usr/bin/env bash
# 07-monitoring.sh — Prometheus + Grafana + GPU/node exporters.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_dgx

COMPOSE="docker compose -f ${REPO_ROOT}/compose/monitoring.yml --env-file ${REPO_ROOT}/.env"

step "Observability stack"

log "Using an nvidia-smi-based GPU exporter (DCGM does not work on GB10)."
$COMPOSE pull || warn "pull issue — check image tags in .env"
$COMPOSE up -d

log "Waiting for exporters…"
sleep 8
if curl -sf "http://127.0.0.1:${GPU_EXPORTER_PORT}/metrics" >/dev/null 2>&1; then
  ok "GPU exporter serving metrics"
  curl -s "http://127.0.0.1:${GPU_EXPORTER_PORT}/metrics" 2>/dev/null \
    | grep -E 'nvidia_smi_(temperature_gpu|power_draw|clocks_current_sm)' | head -n 3 | sed 's/^/    /' || true
else
  warn "GPU metrics not up yet. Logs: $COMPOSE logs -f nvidia-gpu-exporter"
fi

echo
ok "Monitoring up."
cat <<EOF

  Grafana:     http://127.0.0.1:${GRAFANA_PORT}   (admin / \$GRAFANA_ADMIN_PASSWORD)
  Prometheus:  http://127.0.0.1:${PROMETHEUS_PORT}

  First-time Grafana:
    1) Add data source -> Prometheus -> URL http://prometheus:9090
    2) Import Grafana.com dashboard ID 14574 (nvidia_gpu_exporter) for
       out-of-the-box GPU temp/power/clock/util panels.

  For thermal A/B testing: Prometheus keeps 90 days, so you can run a baseline
  load, then an A/B with a cooling mod, and diff sustained SM clock +
  throttle-active time in the same Grafana view.

  Reach remotely:  tailscale serve --bg --https=443 ${GRAFANA_PORT}
EOF
log "Next: dgxsetup thermal   (standalone CSV logger for controlled test runs)"
