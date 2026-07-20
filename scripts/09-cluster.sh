#!/usr/bin/env bash
# 09-cluster.sh — stage + validate the direct two-Spark QSFP link.
#
# Reality check baked in: the QSFP ports negotiate 200GbE, but the ConnectX-7
# hangs off a PCIe Gen5 x4 lane, so real cross-node throughput tops out around
# ~100 Gbps. For your mixed workload (serving + fine-tuning + RAG),
# two INDEPENDENT nodes often beat one tightly-sharded pair; only span both when
# a single model exceeds the 128GB pool.
#
# This script does the SAFE parts (detect devices, set point-to-point IPs + MTU,
# validate bandwidth/latency). The authoritative distributed-INFERENCE bring-up
# (llama.cpp RPC / multi-node vLLM) lives in NVIDIA's official playbook:
#   https://github.com/NVIDIA/dgx-spark-playbooks  ->  nvidia/connect-two-sparks
#
# Subcommands:
#   ./09-cluster.sh detect      # what QSFP/RDMA devices exist + link state
#   ./09-cluster.sh stage       # install tools, set static IP + jumbo MTU (this node)
#   ./09-cluster.sh bandwidth   # TCP iperf3 test (run server on peer first)
#   ./09-cluster.sh rdma        # print the RDMA perftest commands to run
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_dgx

CMD="${1:-detect}"

detect() {
  step "QSFP / RDMA device discovery"
  apt_ensure rdma-core perftest ibverbs-utils >/dev/null
  if have ibdev2netdev; then
    log "RDMA devices -> netdevs (look for state Up once the cable + peer are live):"
    ibdev2netdev 2>/dev/null | sed 's/^/    /' || warn "ibdev2netdev returned nothing"
  fi
  if have rdma; then
    log "rdma link:"; rdma link 2>/dev/null | sed 's/^/    /' || true
  fi
  log "QSFP-class netdevs (high-speed, non-eth0/wlan0):"
  for i in /sys/class/net/*; do
    n=$(basename "$i"); spd=$(cat "$i/speed" 2>/dev/null || echo "?")
    [[ "$n" == lo || "$n" == wl* || "$n" == docker* || "$n" == tailscale* || "$n" == veth* ]] && continue
    printf '    %-16s speed=%s state=%s\n' "$n" "$spd" "$(cat "$i/operstate" 2>/dev/null)"
  done
  echo
  warn "Cable not connected yet? Link will read DOWN — that's expected until the"
  warn "MCP1650-V001E30 lands and the other Spark is powered on the far end."
}

stage() {
  step "Stage this node for the point-to-point link"
  : "${CLUSTER_QSFP_IFACE:=}"
  if [[ -z "${CLUSTER_QSFP_IFACE}" ]]; then
    warn "CLUSTER_QSFP_IFACE not set in .env. Detected candidates:"
    detect
    die "Set CLUSTER_QSFP_IFACE=<iface> in .env (the QSFP netdev), then re-run 'stage'."
  fi
  local np="/etc/netplan/99-spark-cluster.yaml"
  log "Proposed netplan for ${CLUSTER_QSFP_IFACE}: ${CLUSTER_LOCAL_IP}/24, MTU ${CLUSTER_MTU}"
  cat <<EOF
    ${np}:
    network:
      version: 2
      ethernets:
        ${CLUSTER_QSFP_IFACE}:
          addresses: [${CLUSTER_LOCAL_IP}/24]
          mtu: ${CLUSTER_MTU}
EOF
  confirm "Write and apply this netplan on THIS node?" || { warn "Skipped."; return 0; }
  sudo_ tee "$np" >/dev/null <<EOF
network:
  version: 2
  ethernets:
    ${CLUSTER_QSFP_IFACE}:
      addresses: [${CLUSTER_LOCAL_IP}/24]
      mtu: ${CLUSTER_MTU}
EOF
  sudo_ chmod 600 "$np"
  sudo_ netplan apply
  ok "Applied. This node: ${CLUSTER_LOCAL_IP}/24 on ${CLUSTER_QSFP_IFACE}, MTU ${CLUSTER_MTU}"
  # If the security module hardened ufw (default-deny inbound), it only opened app
  # ports on tailscale0 and knows nothing about this point-to-point link — so inter-
  # node traffic (iperf3, RDMA, NCCL) gets silently dropped while ping still works.
  # Open the cluster interface explicitly so the two modules stop fighting.
  if have ufw && sudo_ ufw status 2>/dev/null | grep -q "Status: active"; then
    sudo_ ufw allow in on "${CLUSTER_QSFP_IFACE}" >/dev/null 2>&1 || true
    ok "ufw: allowed cluster traffic on ${CLUSTER_QSFP_IFACE}"
  fi
  warn "Do the mirror on the OTHER Spark with CLUSTER_LOCAL_IP=${CLUSTER_PEER_IP}."
  if ping -c1 -W2 "${CLUSTER_PEER_IP}" >/dev/null 2>&1; then
    ok "Peer ${CLUSTER_PEER_IP} reachable — link is live."
  else
    warn "Peer ${CLUSTER_PEER_IP} not reachable yet (expected until cable + far node are up)."
  fi
}

bandwidth() {
  step "TCP bandwidth test (expect ~90–100 Gbps ceiling, not 200)"
  apt_ensure iperf3 >/dev/null
  warn "On the PEER Spark run:   iperf3 -s"
  confirm "Peer running 'iperf3 -s'? Start the client test?" || { warn "Skipped."; return 0; }
  iperf3 -c "${CLUSTER_PEER_IP}" -P 4 -t 15 | sed 's/^/    /'
  echo
  log "Seeing ~96 Gbps aggregate is the known PCIe Gen5 x4 limit, not a fault."
}

rdma() {
  step "RDMA validation commands (RoCE over the QSFP link)"
  cat <<'EOF'
  RDMA is per-link. Find your Up device first:
      ibdev2netdev            # e.g. rocep1s0f0  (yours may differ)

  One-way write bandwidth (two terminals, one per Spark):
      # on peer:   ib_write_bw -d <rdma_dev> -F --report_gbits
      # on this:   ib_write_bw -d <rdma_dev> -F --report_gbits <peer_ip>

  Write latency:
      # on peer:   ib_write_lat -d <rdma_dev> -F
      # on this:   ib_write_lat -d <rdma_dev> -F <peer_ip>

  For the full, validated procedure (and multi-node inference), use the official
  performance_benchmarking_guide.md in NVIDIA/dgx-spark-playbooks:connect-two-sparks.
EOF
}

case "$CMD" in
  detect)    detect ;;
  stage)     stage ;;
  bandwidth) bandwidth ;;
  rdma)      rdma ;;
  *) die "Usage: $0 {detect|stage|bandwidth|rdma}" ;;
esac
