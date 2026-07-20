#!/usr/bin/env bash
# setup.sh — orchestrator for the DGX Spark setup. Run ./install.sh once to get
# the  command;  and  are the same thing.
# Run modules individually (recommended first time) or 'all' for the base stack.
#
#   dgxsetup preflight     # verify the box (read-only)   <- start here
#   dgxsetup system        # host basics (docker group, tooling, dirs)
#   dgxsetup security      # hardening + Tailscale
#   dgxsetup models        # HF cache + embedding/test model pulls
#   dgxsetup inference     # serve primary model + LiteLLM gateway + Open WebUI
#   dgxsetup rag           # pgvector for RAG
#   dgxsetup finetune      # LoRA/QLoRA workspace
#   dgxsetup monitoring    # Prometheus + Grafana + GPU/node exporters
#   dgxsetup thermal       # (see: ./scripts/08-thermal.sh --help)
#   dgxsetup cluster       # two-Spark link staging/validation
#   dgxsetup cluster-serve {setup|start|status|logs|stop|sync-gateway}  # pooled big model across both Sparks
#   dgxsetup multinode {ray-up|serve tp|pp|bench|compare|boundaries tp|pp|status|stop|ray-down}  # YOUR TP/PP test lab
#   dgxsetup health        # check all endpoints
#   dgxsetup reset {stacks|images|data|all}   # tear down to start fresh (see reset.sh)
#   dgxsetup all           # preflight->system->security->models->inference->rag->monitoring
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="${HERE}/scripts"

if [[ ! -f "${HERE}/.env" ]]; then
  echo "[!] No .env found. Creating from template — EDIT IT before running modules."
  cp "${HERE}/.env.example" "${HERE}/.env"
  echo "[!] Edit ${HERE}/.env (HF_TOKEN, passwords, model, cluster IPs), then re-run."
  [[ "${1:-}" == "preflight" ]] || exit 1
fi

cmd="${1:-help}"; shift || true
case "$cmd" in
  preflight)  bash "${S}/00-preflight.sh"  "$@";;
  system)     bash "${S}/01-system.sh"     "$@";;
  security)   bash "${S}/02-security.sh"    "$@";;
  models)     bash "${S}/03-model-cache.sh" "$@";;
  inference)  bash "${S}/04-inference.sh"   "$@";;
  rag)        bash "${S}/05-rag.sh"         "$@";;
  finetune)   bash "${S}/06-finetune.sh"    "$@";;
  monitoring) bash "${S}/07-monitoring.sh"  "$@";;
  thermal)    bash "${S}/08-thermal.sh"     "$@";;
  cluster)    bash "${S}/09-cluster.sh"     "$@";;
  cluster-serve) bash "${S}/10-cluster-serve.sh" "$@";;
  multinode)  bash "${S}/11-multinode.sh"    "$@";;
  health)     bash "${HERE}/helpers/health.sh" "$@";;
  reset)      bash "${HERE}/reset.sh" "$@";;
  all)
    bash "${S}/00-preflight.sh"
    bash "${S}/01-system.sh"
    bash "${S}/02-security.sh"
    bash "${S}/03-model-cache.sh"
    bash "${S}/04-inference.sh"
    bash "${S}/05-rag.sh"
    bash "${S}/07-monitoring.sh"
    echo "[+] Base stack done. Fine-tuning workspace: dgxsetup finetune. Cluster: dgxsetup cluster."
    ;;
  help|-h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//';;
  *) echo "Unknown: $cmd"; grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1;;
esac
