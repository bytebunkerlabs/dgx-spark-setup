#!/usr/bin/env bash
# spark-gpu — quick GPU + unified-memory status (installed as ~/.local/bin/spark-gpu).
# On the Spark, GPU "memory" via nvidia-smi reads Not Supported (unified memory),
# so this shows GPU compute stats from nvidia-smi AND real memory from free.
set -euo pipefail

echo "== GPU =="
nvidia-smi --query-gpu=name,temperature.gpu,power.draw,clocks.sm,clocks.max.sm,utilization.gpu,clocks_throttle_reasons.active \
           --format=csv 2>/dev/null || nvidia-smi

echo
echo "== Unified memory (the real budget) =="
free -h

echo
echo "== Top GPU processes =="
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv 2>/dev/null \
  || echo "(compute-app query not supported on this build)"
