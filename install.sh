#!/usr/bin/env bash
# install.sh — put `dgxsetup` on your PATH, pointing at this checkout.
# Re-run any time; it just rewrites the launcher. Uninstall: rm ~/.local/bin/dgxsetup
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${DGXSETUP_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN"
cat > "$BIN/dgxsetup" <<EOF
#!/usr/bin/env bash
exec "$HERE/setup.sh" "\$@"
EOF
chmod +x "$BIN/dgxsetup"
echo "[ok] installed: $BIN/dgxsetup -> $HERE/setup.sh"
case ":$PATH:" in
  *":$BIN:"*) : ;;
  *) echo "[!] $BIN is not on your PATH. Add this to your shell profile:"
     echo "    export PATH=\"$BIN:\$PATH\"" ;;
esac
echo "Try: dgxsetup preflight"
