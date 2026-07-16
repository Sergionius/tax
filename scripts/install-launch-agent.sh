#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ℹ️ launchd setup skipped: macOS is required"
  exit 0
fi

TAX_BIN="$(command -v tax || true)"
if [[ -z "$TAX_BIN" ]]; then
  echo "❌ tax executable not found in PATH" >&2
  exit 1
fi

LABEL="tax.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tax"
LOG_DIR="$STATE_DIR/logs"
mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"

# Escape values before embedding them in XML.
TAX_BIN_XML="$(python3 -c 'import html,sys; print(html.escape(sys.argv[1]))' "$TAX_BIN")"
PATH_XML="$(python3 -c 'import html,os; print(html.escape(os.environ.get("PATH", "")))')"
STATE_XML="$(python3 -c 'import html,sys; print(html.escape(sys.argv[1]))' "$STATE_DIR")"

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
        <string>agent</string>
        <string>--state-dir</string>
        <string>$STATE_XML</string>
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
    <key>StandardOutPath</key>
    <string>$STATE_XML/logs/agent.log</string>
    <key>StandardErrorPath</key>
    <string>$STATE_XML/logs/agent-error.log</string>
</dict>
</plist>
EOF

DOMAIN="gui/$(id -u)"
if ! python3 - "$HOME/.config/tax/config.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    configured = bool(json.loads(path.read_text()).get("api_key"))
except (OSError, ValueError):
    configured = False
raise SystemExit(0 if configured else 1)
PY
then
  echo "⚠️ LaunchAgent plist created but not loaded: configure the API key first:" >&2
  echo "   tax config --api-key YOUR_API_KEY" >&2
  echo "   $0" >&2
  exit 0
fi

launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$DOMAIN/$LABEL"
launchctl kickstart -k "$DOMAIN/$LABEL"

echo "✅ tax-agent LaunchAgent installed: $PLIST"

for _ in {1..30}; do
  if curl --silent --fail http://127.0.0.1:17373/health >/dev/null 2>&1; then
    echo "✅ tax-agent health check passed"
    exit 0
  fi
  sleep 0.5
done

echo "⚠️ tax-agent is not healthy yet. Configure TAX_API_KEY with 'tax config --api-key ...' and restart:" >&2
echo "   launchctl kickstart -k $DOMAIN/$LABEL" >&2
