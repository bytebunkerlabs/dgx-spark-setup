#!/usr/bin/env bash
# lib/common.sh — shared helpers for the DGX Spark setup scripts.
# Sourced, not executed. Requires bash 4+ (DGX OS / Ubuntu 24.04 ships bash 5).

# ---- strict mode (callers should also set this, but be safe) -----------------
set -o errexit -o nounset -o pipefail

# ---- resolve repo root regardless of where a script is called from -----------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# ---- load .env if present ----------------------------------------------------
if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "${REPO_ROOT}/.env"; set +a
fi

# ---- colours (disabled if not a tty) -----------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
  C_BLU=$'\033[0;34m'; C_DIM=$'\033[2m';   C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_RST=""
fi

log()   { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()   { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()   { err "$*"; exit 1; }
step()  { printf '\n%s==== %s ====%s\n' "$C_BLU" "$*" "$C_RST"; }

# ---- small utilities ---------------------------------------------------------
have()      { command -v "$1" >/dev/null 2>&1; }
is_root()   { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

# Run a command with sudo only if we are not already root.
sudo_() {
  if is_root; then "$@"; else sudo "$@"; fi
}

confirm() {
  # confirm "Question?"  -> returns 0 on y/Y, 1 otherwise. Auto-yes if ASSUME_YES=1.
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Guard so we don't silently run generic-Linux commands on the wrong machine.
require_dgx() {
  if [[ "${SKIP_DGX_CHECK:-0}" == "1" ]]; then
    warn "SKIP_DGX_CHECK=1 — not verifying this is a DGX Spark."
    return 0
  fi
  local model="/proc/device-tree/model"
  if [[ -r "$model" ]] && grep -qiE 'spark|gb10|nvidia' "$model" 2>/dev/null; then
    return 0
  fi
  if have nvidia-smi && nvidia-smi -L 2>/dev/null | grep -qiE 'gb10|blackwell'; then
    return 0
  fi
  warn "This does not look like a DGX Spark (GB10)."
  warn "Model: $( [[ -r $model ]] && tr -d '\0' < "$model" || echo unknown )"
  warn "Re-run with SKIP_DGX_CHECK=1 to force (only if you know what you're doing)."
  die  "Aborting to avoid running Spark-specific steps on the wrong host."
}

# Idempotent apt install: only touches packages that are missing.
apt_ensure() {
  local missing=()
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "apt packages already present: $*"
    return 0
  fi
  log "Installing: ${missing[*]}"
  sudo_ apt-get update -qq
  sudo_ apt-get install -y --no-install-recommends "${missing[@]}"
}
