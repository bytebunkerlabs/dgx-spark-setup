#!/usr/bin/env bash
# 08-thermal.sh — standalone thermal/perf CSV logger for controlled runs.
#
# Purpose: capture the exact dataset that tells you whether your DGX Spark
# cooling mod is worth it — sustained SM clock as a % of max, and how
# much wall-clock time the GPU spends throttled — plus GPU/CPU/NVMe temps and
# power, over a labeled run you can A/B (stock vs with-cooler).
#
# Usage:
#   ./08-thermal.sh --label baseline --interval 2 --duration 3600
#   ./08-thermal.sh --label with-cooler --interval 2       # Ctrl-C to stop
#
# Pairs with a sustained load. Generate load with your real workload, by
# hammering the endpoint, or with the official connect-two-sparks / benchmark
# playbook. Logging and load are intentionally decoupled so you can point this
# at any load source.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

LABEL="run"; INTERVAL=2; DURATION=0   # duration 0 = until Ctrl-C
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)    LABEL="$2"; shift 2;;
    --interval) INTERVAL="$2"; shift 2;;
    --duration) DURATION="$2"; shift 2;;
    -h|--help)  grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

have nvidia-smi || die "nvidia-smi required."

OUTDIR="${DATA_ROOT:-$HOME/dgx}/thermal-logs"
mkdir -p "$OUTDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
CSV="${OUTDIR}/thermal_${LABEL}_${STAMP}.csv"

# --- helpers to read sensors the Spark actually exposes ---------------------
cpu_temp_c() {   # hottest ARM/SoC thermal zone, in °C
  local max=0 t
  for z in /sys/class/thermal/thermal_zone*/temp; do
    [[ -r "$z" ]] || continue
    t=$(( $(cat "$z") / 1000 ))
    (( t > max )) && max=$t
  done
  echo "$max"
}
nvme_temp_c() {  # NVMe composite temp. Non-blocking: needs passwordless sudo,
                 # else prefer the hwmon sysfs path, else leave blank. Never prompts.
  local dev; dev=$(ls /dev/nvme?n1 2>/dev/null | head -n1 || true)
  [[ -n "$dev" ]] || { echo ""; return; }
  if have nvme && sudo -n true 2>/dev/null; then
    sudo -n nvme smart-log "$dev" 2>/dev/null \
      | awk -F: '/^temperature/{gsub(/[^0-9]/,"",$2); print $2; exit}'
    return
  fi
  # Fallback: NVMe hwmon exposes composite temp in millidegrees, no sudo needed.
  local t
  t=$(cat /sys/class/nvme/nvme0/device/hwmon*/temp1_input 2>/dev/null | head -n1)
  [[ -n "$t" ]] && echo $(( t / 1000 )) || echo ""
}
mem_used_mb() { free -m | awk '/^Mem:/{print $3}'; }   # UMA: real number lives here

# --- CSV header -------------------------------------------------------------
echo "timestamp,label,gpu_temp_c,gpu_power_w,sm_clock_mhz,sm_clock_max_mhz,sm_clock_pct,gpu_util_pct,throttle_active_hex,cpu_temp_c,nvme_temp_c,mem_used_mb" > "$CSV"

ok "Logging to: $CSV"
log "Label='${LABEL}'  interval=${INTERVAL}s  duration=$( [[ $DURATION -eq 0 ]] && echo 'until Ctrl-C' || echo "${DURATION}s" )"
warn "Start your sustained load now (real workload / endpoint stress / benchmark)."

start=$(date +%s)
trap 'echo; ok "Stopped. Rows: $(( $(wc -l < "$CSV") - 1 )). File: $CSV"; summarize; exit 0' INT TERM

summarize() {
  # Quick at-a-glance verdict: mean SM clock %, and % of samples throttled.
  awk -F, 'NR>1 {
      n++; sumpct+=$7;
      if ($9 != "0x0000000000000000" && $9 != "" && $9 != "0x0") thr++;
      if ($3+0>maxt) maxt=$3;
    }
    END { if (n>0) {
      printf "    samples=%d  mean_sm_clock=%.1f%%  throttled_samples=%.1f%%  peak_gpu_temp=%d C\n",
             n, sumpct/n, (thr/n)*100, maxt;
    } }' "$CSV"
}

while :; do
  now=$(date +%s)
  [[ $DURATION -gt 0 && $(( now - start )) -ge $DURATION ]] && { ok "Duration reached."; summarize; break; }

  # One nvidia-smi call for the GPU fields (CSV, no units, no header).
  read -r gtemp gpow smclk smmax gutil thr < <(
    nvidia-smi --query-gpu=temperature.gpu,power.draw,clocks.sm,clocks.max.sm,utilization.gpu,clocks_throttle_reasons.active \
               --format=csv,noheader,nounits 2>/dev/null | tr -d ',' | awk '{$1=$1; print}'
  ) || { warn "nvidia-smi query failed; retrying"; sleep "$INTERVAL"; continue; }

  # clocks_throttle_reasons.active may be unsupported on some driver builds.
  [[ "$thr" =~ ^0x ]] || thr="unsupported"
  pct=""
  if [[ "$smclk" =~ ^[0-9]+$ && "$smmax" =~ ^[0-9]+$ && "$smmax" -gt 0 ]]; then
    pct=$(awk -v a="$smclk" -v b="$smmax" 'BEGIN{printf "%.1f", (a/b)*100}')
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date -Is)" "$LABEL" "$gtemp" "$gpow" "$smclk" "$smmax" "$pct" "$gutil" \
    "$thr" "$(cpu_temp_c)" "$(nvme_temp_c)" "$(mem_used_mb)" >> "$CSV"

  sleep "$INTERVAL"
done

echo
ok "Done. Analyze:  column -s, -t < '$CSV' | less -S"
log "A/B tip: run one labeled 'baseline', one 'with-cooler', same load + duration,"
log "then compare mean_sm_clock% and throttled_samples% — that's the answer."
