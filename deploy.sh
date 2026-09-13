#!/bin/bash
set -euo pipefail

# TAX backend deployment (systemd + Caddy).
#
# Every deployment value comes from the private deployment configuration
# (TAX_DEPLOY_CONFIG, ~/.config/tax/deploy.env or the environment; see
# docs/LOCAL_CONFIGURATION.md). The configuration is validated before this
# script touches Git, sudo, files or services.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/deploy-config.sh
source "$SCRIPT_DIR/scripts/deploy-config.sh"

if ! tax_deploy_config_load; then
    exit 1
fi

PROJECT_DIR="$TAX_DEPLOY_PROJECT_DIR"
SERVER_DIR="$TAX_DEPLOY_SERVER_DIR"
VENV_DIR="$TAX_DEPLOY_VENV_DIR"
DATA_DIR="$TAX_DEPLOY_DATA_DIR"
KEYS_DIR="$TAX_DEPLOY_KEYS_DIR"
DB_PATH="$TAX_DEPLOY_DB_PATH"
DOMAIN="$TAX_DEPLOY_DOMAIN"
APP_HOST="127.0.0.1"
APP_PORT="$TAX_DEPLOY_PORT"
SERVICE_DST="/etc/systemd/system/tax.service"
CADDYFILE="/etc/caddy/Caddyfile"

RENDER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tax-deploy.XXXXXX")"
STATUS_FILE=""

cleanup() {
    rm -rf "$RENDER_DIR"
    if [[ -n "$STATUS_FILE" ]]; then
        rm -f "$STATUS_FILE"
    fi
}
trap cleanup EXIT

# Render the tracked templates from the validated configuration. Rendering
# only writes into the temporary directory and refuses leftover placeholders,
# so an unrendered template can never be installed.
if ! tax_deploy_render_templates "$RENDER_DIR"; then
    exit 1
fi
RENDERED_SERVICE="$RENDER_DIR/tax.service"
RENDERED_CADDY="$RENDER_DIR/Caddyfile"

cd "$PROJECT_DIR"

# Refuse diverged or broken updates instead of deploying an unknown revision.
git pull --ff-only origin main

# Ensure data and keys directories exist.
mkdir -p "$DATA_DIR" "$KEYS_DIR"

# Create a consistent online backup before the service can run a schema migration.
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

# Create virtual environment and install the generated, hash-checked
# requirements export.
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install --require-hashes -r "$SERVER_DIR/requirements.txt"

# The backend requires operator-provided secrets. Never create a .env file
# with an empty API key: report the missing configuration instead.
if [ ! -f "$SERVER_DIR/.env" ]; then
    cat >&2 <<EOF
ERROR: backend environment file is missing: $SERVER_DIR/.env

Create it from server/.env.example with a non-empty TAX_API_KEY and the APNs
values, then re-run this script:

  cp "$SCRIPT_DIR/server/.env.example" "$SERVER_DIR/.env"
  # edit "$SERVER_DIR/.env": set TAX_API_KEY and the APNs values
EOF
    exit 1
fi
API_KEY="$(/usr/bin/grep -E '^TAX_API_KEY=' "$SERVER_DIR/.env" | /usr/bin/head -n 1 | /usr/bin/cut -d '=' -f2-)"
if [[ -z "$API_KEY" ]]; then
    echo "ERROR: TAX_API_KEY in $SERVER_DIR/.env is empty; deployment requires a non-empty API key." >&2
    exit 1
fi

# Check Caddy configuration. We cannot write to /etc/caddy as the service
# user, so if the configured domain is missing, show the exact rendered block
# for root and exit.
if ! /usr/bin/grep -qE "^$DOMAIN" "$CADDYFILE"; then
    {
        echo
        echo "ERROR: Caddyfile is missing the configured domain ($DOMAIN)."
        echo
        echo "Run this command as root to add the rendered block:"
        echo
        echo "  /usr/bin/tee -a /etc/caddy/Caddyfile <<'CADDY'"
        /usr/bin/cat "$RENDERED_CADDY"
        echo "CADDY"
        echo "  /usr/bin/systemctl reload caddy"
        echo
        echo "Then re-run: $SCRIPT_DIR/deploy.sh"
    } >&2
    exit 1
fi

# Backup existing Caddyfile locally (we don't have write access to /etc/caddy)
/usr/bin/cp "$CADDYFILE" "$PROJECT_DIR/Caddyfile.bak.$(date +%Y%m%d%H%M%S)"

# Install the rendered systemd unit. Defence in depth: refuse a file that
# still contains unrendered placeholders.
if /usr/bin/grep -qE '@TAX_DEPLOY_[A-Za-z0-9_]+@' "$RENDERED_SERVICE"; then
    echo "ERROR: rendered systemd unit still contains placeholders; aborting." >&2
    exit 1
fi
sudo /usr/bin/cp "$RENDERED_SERVICE" "$SERVICE_DST"

# Reload systemd, enable and start service
sudo /usr/bin/systemctl daemon-reload
sudo /usr/bin/systemctl enable tax
sudo /usr/bin/systemctl restart tax

# Reload caddy to pick up any config changes (already configured)
sudo /usr/bin/systemctl reload caddy

echo "tax deployed."

# Health check against the same configured loopback port used by systemd and
# the Caddy reverse proxy.
sleep 2
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
expected = {
    "orca_terminal_handle", "orca_worktree_id", "orca_tab_id", "orca_pane_key",
    "push_status", "push_attempted_at", "push_environment", "apns_status_code", "apns_reason", "apns_id",
}
print(len(columns & expected))
PY
)
if [[ "$ORCA_COLUMN_COUNT" != "10" ]]; then
    echo "Schema verification failed: expected 10 routing/diagnostic columns, found $ORCA_COLUMN_COUNT." >&2
    exit 1
fi
echo "Orca and push diagnostic schema verification passed."

# Show status. Use a unique file because a stale root-owned /tmp file may not be writable.
# The allowed sudo command is exactly: /usr/bin/systemctl status tax
STATUS_FILE=$(mktemp /tmp/tax.status.XXXXXX)
sudo /usr/bin/systemctl status tax > "$STATUS_FILE"
echo "Service status:"
cat "$STATUS_FILE"
