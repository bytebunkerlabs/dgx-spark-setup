#!/usr/bin/env bash
# 02-security.sh — sensible hardening for a box that will host model endpoints,
# plus Tailscale for remote access (works cleanly over CGNAT — no port forwards).
# Conservative by design: SSH stays key-based, firewall defaults to deny-in.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_dgx

step "Security hardening"

apt_ensure ufw fail2ban unattended-upgrades

# --- firewall ---------------------------------------------------------------
# Default deny inbound. Allow SSH. App ports are exposed ONLY over the Tailscale
# interface by default, so your inference/gateway/Grafana aren't on the LAN.
log "Configuring ufw (default deny in / allow out)"
sudo_ ufw --force reset >/dev/null
sudo_ ufw default deny incoming
sudo_ ufw default allow outgoing
sudo_ ufw allow OpenSSH
# Allow the app ports on the Tailscale interface only (tailscale0), not eth0/wlan0.
for port in "${INFER_PORT}" "${LITELLM_PORT}" "${OPENWEBUI_PORT}" \
            "${GRAFANA_PORT}" "${PROMETHEUS_PORT}"; do
  sudo_ ufw allow in on tailscale0 to any port "${port}" proto tcp >/dev/null 2>&1 || true
done
# DGX Dashboard stays local-only (loopback) — do not expose it.
sudo_ ufw --force enable
ok "ufw enabled. App ports reachable over Tailscale only; SSH open on all interfaces."
warn "If you administer this box over the LAN, add: sudo ufw allow from <your-subnet> to any port 22"

# --- fail2ban ---------------------------------------------------------------
if [[ ! -f /etc/fail2ban/jail.local ]]; then
  sudo_ tee /etc/fail2ban/jail.local >/dev/null <<'EOF'
[sshd]
enabled  = true
maxretry = 5
bantime  = 1h
findtime = 10m
EOF
  ok "fail2ban sshd jail configured"
fi
sudo_ systemctl enable --now fail2ban >/dev/null 2>&1 || true

# --- SSH hardening (non-destructive: only tightens if defaults are loose) ----
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-dgx-hardening.conf"
if [[ ! -f "$SSHD_DROPIN" ]]; then
  log "Writing SSH hardening drop-in (key auth, no root login)"
  sudo_ tee "$SSHD_DROPIN" >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
X11Forwarding no
MaxAuthTries 4
EOF
  warn "PasswordAuthentication is now OFF. Make sure your SSH KEY is installed before you log out!"
  if confirm "Restart sshd now to apply?"; then
    sudo_ systemctl restart ssh || sudo_ systemctl restart sshd || true
    ok "sshd restarted"
  else
    warn "Not restarted. Apply later with: sudo systemctl restart ssh"
  fi
else
  ok "SSH hardening drop-in already present"
fi

# --- unattended security upgrades (security pocket only) --------------------
sudo_ dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
ok "Unattended security upgrades enabled"

# --- Tailscale --------------------------------------------------------------
step "Tailscale (remote access over CGNAT — the same pattern the official playbooks use)"
if ! have tailscale; then
  if confirm "Install Tailscale?"; then
    curl -fsSL https://tailscale.com/install.sh | sh
    ok "Tailscale installed"
  fi
fi
if have tailscale; then
  if ! tailscale status >/dev/null 2>&1; then
    warn "Bring the node online with:  sudo tailscale up --ssh --hostname ${SPARK_HOSTNAME}"
    warn "  --ssh lets you SSH over the tailnet even if LAN SSH is locked down."
    warn "  Add --advertise-tags=tag:spark if you use tailnet ACL tags."
  else
    ok "Tailscale already up:"; tailscale status 2>/dev/null | head -n 3 | sed 's/^/    /'
  fi
fi

echo
ok "Hardening complete."
log "Next: dgxsetup models   (HF cache + pull embedding/test models)"
