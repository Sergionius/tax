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

# Refuse diverged or broken updates instead of deploying an unknown revision.
git pull --ff-only origin main

# Ensure data and keys directories exist.
mkdir -p "$DATA_DIR" "$KEYS_DIR"

# Create a consistent online backup before the service can run a schema migration.
DB_PATH="$DATA_DIR/tax.db"
if [[ -f "$DB_PATH" ]]; then
    BACKUP_PATH="$DATA_DIR/tax-pre-deploy-$(date +%Y%m%d%H%M%S).db"
    python3 - "$DB_PATH" "$BACKUP_PATH" <<'PY'
import sqlite3
import sys

source_path, backup_path = sys.argv[1:]
with sqlite3.connect(source_path) as source, sqlite3.connect(backup_path) as backup:
    source.backup(backup)
    result = source.execute("PRAGMA integrity_check").fetchone()[0]
if result != "ok":
    raise SystemExit(f"Database integrity check failed: {result}")
PY
    echo "Database backup: $BACKUP_PATH"
fi

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

ORCA_COLUMN_COUNT=$(python3 - "$DB_PATH" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    columns = {row[1] for row in connection.execute("PRAGMA table_info(tasks)")}
expected = {"orca_terminal_handle", "orca_worktree_id", "orca_tab_id", "orca_pane_key"}
print(len(columns & expected))
PY
)
if [[ "$ORCA_COLUMN_COUNT" != "4" ]]; then
    echo "Orca schema verification failed: expected 4 routing columns, found $ORCA_COLUMN_COUNT." >&2
    exit 1
fi
echo "Orca schema verification passed."

# Show status. Use a unique file because a stale root-owned /tmp file may not be writable.
# The allowed sudo command is exactly: /usr/bin/systemctl status tax
STATUS_FILE=$(mktemp /tmp/tax.status.XXXXXX)
trap 'rm -f "$STATUS_FILE"' EXIT
sudo /usr/bin/systemctl status tax > "$STATUS_FILE"
echo "Service status:"
cat "$STATUS_FILE"
