#!/usr/bin/env bash
# spark-flush-cache — reclaim the Linux buffer cache from the unified memory pool.
#
# On the Spark, 128GB is shared between CPU and GPU. After serving/loading large
# models, page cache can hold a big chunk of that pool, and the next heavy job
# (e.g. a fine-tune) can hit "Out of Memory" despite free capacity. Flushing the
# cache before switching heavy workloads reclaims that space. Safe to run.
set -euo pipefail

echo "Before:"; free -h | awk 'NR==1||/Mem:/{print "  "$0}'
sync
if [[ "$(id -u)" -eq 0 ]]; then
  echo 3 > /proc/sys/vm/drop_caches
else
  sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
fi
echo "After:"; free -h | awk 'NR==1||/Mem:/{print "  "$0}'
echo "Buffer cache dropped."
