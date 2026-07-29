#!/bin/bash
set -euo pipefail

# tax deploy script
# Run from /home/hermes/tax on the VPS.

PROJECT_DIR="/home/hermes/tax"
SERVER_DIR="$PROJECT_DIR/server"
VENV_DIR="$SERVER_DIR/venv"
DATA_DIR="$PROJECT_DIR/data"
KEYS_DIR="$PROJECT_DIR/keys"
SERVICE_SRC="$SERVER_DIR/tax.service"
SERVICE_DST="/etc/systemd/system/tax.service"
CADDYFILE="/etc/caddy/Caddyfile"
APP_HOST="127.0.0.1"
APP_PORT="8002"
DOMAIN="tax.138-249-127-23.nip.io"

cd "$PROJECT_DIR"

# Ensure git repo is up to date (manual pull, no sudo)
git pull || true

# Ensure data and keys directories exist
mkdir -p "$DATA_DIR" "$KEYS_DIR"

# Create virtual environment and install dependencies
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/pip" install --upgrade pip
if [ -f "$SERVER_DIR/requirements.txt" ]; then
    "$VENV_DIR/bin/pip" install -r "$SERVER_DIR/requirements.txt"
fi

# Ensure .env file exists (user will fill APNS values later)
if [ ! -f "$SERVER_DIR/.env" ]; then
    /usr/bin/cat > "$SERVER_DIR/.env" <<EOF
TAX_API_KEY=
TAX_APNS_KEY_ID=
TAX_APNS_TEAM_ID=
TAX_APNS_BUNDLE_ID=
TAX_APNS_USE_SANDBOX=1
EOF
fi

# Check Caddyfile configuration. We cannot write to /etc/caddy as hermes,
# so if the subdomain is missing, show the exact command for root and exit.
if ! /usr/bin/grep -qE "^$DOMAIN" "$CADDYFILE"; then
    /usr/bin/cat <<EOF

ERROR: Caddyfile is missing the tax subdomain.

Run this command as root to add it:

  /usr/bin/tee -a /etc/caddy/Caddyfile <<'CADDY'

$DOMAIN {
    reverse_proxy $APP_HOST:$APP_PORT
}
CADDY
  /usr/bin/systemctl reload caddy

Then re-run: /home/hermes/tax/deploy.sh
EOF
    exit 1
fi

# Backup existing Caddyfile locally (we don't have write access to /etc/caddy)
/usr/bin/cp "$CADDYFILE" "$PROJECT_DIR/Caddyfile.bak.$(date +%Y%m%d%H%M%S)"

# Install systemd service
sudo /usr/bin/cp "$SERVICE_SRC" "$SERVICE_DST"

# Reload systemd, enable and start service
sudo /usr/bin/systemctl daemon-reload
sudo /usr/bin/systemctl enable tax
sudo /usr/bin/systemctl restart tax

# Reload caddy to pick up any config changes (already configured)
sudo /usr/bin/systemctl reload caddy

echo "tax deployed."

# Health check
sleep 2
API_KEY=$(/usr/bin/grep '^TAX_API_KEY=' "$SERVER_DIR/.env" | /usr/bin/cut -d '=' -f2-)
if /usr/bin/curl -sf "http://$APP_HOST:$APP_PORT/health" -H "Authorization: Bearer $API_KEY" > /dev/null; then
    echo "Health check passed."
    echo "Public URL: https://$DOMAIN"
else
    echo "Health check failed."
    exit 1
fi

# Show status. Use a unique file because a stale root-owned /tmp file may not be writable.
# The allowed sudo command is exactly: /usr/bin/systemctl status tax
STATUS_FILE=$(mktemp /tmp/tax.status.XXXXXX)
trap 'rm -f "$STATUS_FILE"' EXIT
sudo /usr/bin/systemctl status tax > "$STATUS_FILE"
echo "Service status:"
cat "$STATUS_FILE"
