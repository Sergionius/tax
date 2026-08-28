#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "❌ remote host LaunchAgent requires macOS" >&2
  exit 1
fi

HOST_ID="${TAX_HOST_ID:-mac-main}"
DEVICE_ID="${TAX_DEVICE_ID:-iphone-main}"
PAIRING_FILE="${TAX_ORCA_PAIRING_FILE:-$HOME/.config/tax/orca-pairing}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-id) HOST_ID="${2:?missing value for --host-id}"; shift 2 ;;
    --device-id) DEVICE_ID="${2:?missing value for --device-id}"; shift 2 ;;
    --pairing-code-file) PAIRING_FILE="${2:?missing value for --pairing-code-file}"; shift 2 ;;
    --help)
      cat <<'EOF'
Usage: scripts/install-remote-host-launch-agent.sh [options]

Options:
  --host-id ID                 Relay host ID (default: mac-main)
  --device-id ID               Relay device ID (default: iphone-main)
  --pairing-code-file PATH     Protected Orca pairing file
EOF
      exit 0
      ;;
    *) echo "❌ unknown argument: $1" >&2; exit 2 ;;
  esac
done

TAX_BIN="$(command -v tax || true)"
if [[ -z "$TAX_BIN" ]]; then
  echo "❌ tax executable not found in PATH; run ./scripts/install.sh first" >&2
  exit 1
fi

if [[ ! -f "$PAIRING_FILE" ]]; then
  echo "❌ Orca pairing file not found: $PAIRING_FILE" >&2
  exit 1
fi
if [[ "$(stat -f '%OLp' "$PAIRING_FILE")" != "600" ]]; then
  echo "❌ pairing file must have mode 600: chmod 600 '$PAIRING_FILE'" >&2
  exit 1
fi
if ! "$TAX_BIN" e2ee-key show >/dev/null 2>&1; then
  echo "❌ tax E2EE key is missing; run: tax e2ee-key generate" >&2
  exit 1
fi
if ! python3 - "$HOME/.config/tax/config.json" <<'PY'
import json
import sys
from pathlib import Path

try:
    config = json.loads(Path(sys.argv[1]).read_text())
    valid = bool(config.get("api_key") and config.get("server"))
except (OSError, ValueError):
    valid = False
raise SystemExit(0 if valid else 1)
PY
then
  echo "❌ backend is not configured; run: tax config --server URL --api-key KEY" >&2
  exit 1
fi

LABEL="tax.remote-host"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tax"
LOG_DIR="$STATE_DIR/logs"
mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"
PAIRING_FILE="$(cd "$(dirname "$PAIRING_FILE")" && pwd)/$(basename "$PAIRING_FILE")"

xml_escape() { python3 -c 'import html,sys; print(html.escape(sys.argv[1]))' "$1"; }
TAX_BIN_XML="$(xml_escape "$TAX_BIN")"
HOST_ID_XML="$(xml_escape "$HOST_ID")"
DEVICE_ID_XML="$(xml_escape "$DEVICE_ID")"
PAIRING_FILE_XML="$(xml_escape "$PAIRING_FILE")"
PATH_XML="$(xml_escape "$PATH")"
LOG_DIR_XML="$(xml_escape "$LOG_DIR")"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$TAX_BIN_XML</string>
        <string>remote-host</string>
        <string>--host-id</string>
        <string>$HOST_ID_XML</string>
        <string>--device-id</string>
        <string>$DEVICE_ID_XML</string>
        <string>--orca-pairing-code-file</string>
        <string>$PAIRING_FILE_XML</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$PATH_XML</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$LOG_DIR_XML/remote-host.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR_XML/remote-host-error.log</string>
</dict>
</plist>
EOF
chmod 600 "$PLIST"
plutil -lint "$PLIST" >/dev/null

DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
loaded=false
for _ in {1..10}; do
  if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
    loaded=true
    break
  fi
  sleep 0.5
done
if [[ "$loaded" != true ]] && ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  echo "❌ failed to bootstrap $LABEL" >&2
  exit 1
fi
launchctl enable "$DOMAIN/$LABEL"
launchctl kickstart -k "$DOMAIN/$LABEL"

sleep 1
if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  echo "❌ $LABEL was installed but is not loaded" >&2
  exit 1
fi

echo "✅ remote host LaunchAgent installed"
echo "   Host ID: $HOST_ID"
echo "   Device ID: $DEVICE_ID"
echo "   Plist: $PLIST"
echo "   Logs: $LOG_DIR/remote-host.log"
echo "   Status: launchctl print $DOMAIN/$LABEL"
echo "   Restart: launchctl kickstart -k $DOMAIN/$LABEL"
