#!/usr/bin/env bash
set -euo pipefail
umask 077

# Run as root with an explicit private configuration. Git updates are separate:
# scripts/deploy-backend.sh updates as the checkout owner before invoking sudo.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/deploy-config.sh"
tax_deploy_config_load || exit 1

if [[ "$EUID" -ne 0 ]]; then
    echo 'Run deployment as root with TAX_DEPLOY_CONFIG pointing to the private deployment file.' >&2
    exit 1
fi
for tool in python3 runuser systemctl caddy; do
    command -v "$tool" >/dev/null || { echo "Required command missing: $tool" >&2; exit 1; }
done

as_service() { runuser -u "$TAX_DEPLOY_USER" -- "$@"; }
CHECKS="$SCRIPT_DIR/scripts/deployment_checks.py"
CADDYFILE=/etc/caddy/Caddyfile

# Validate all runtime configuration and access before creating directories,
# installing dependencies or stopping a service. No credential is put in argv.
as_service python3 "$CHECKS" env "$TAX_DEPLOY_ENV_FILE" "$TAX_DEPLOY_DB_PATH" "$TAX_DEPLOY_APNS_KEY_PATH"
as_service test -w "$TAX_DEPLOY_PROJECT_DIR"
if [[ -e "$TAX_DEPLOY_DB_PATH" ]]; then
    as_service test -r "$TAX_DEPLOY_DB_PATH"
    as_service test -w "$TAX_DEPLOY_DB_PATH"
fi
python3 -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ is required"'

RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT
tax_deploy_render_templates "$RENDER_DIR"
caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1
caddy adapt --config "$CADDYFILE" --adapter caddyfile > "$RENDER_DIR/caddy.json" 2>/dev/null
python3 "$CHECKS" caddy "$RENDER_DIR/caddy.json" "$TAX_DEPLOY_DOMAIN" "$TAX_DEPLOY_PORT"

# Deliberately never rewrite the shared Caddyfile: other sites may use it.
# A changed upstream must be applied and validated by the operator first.
install -d -m 700 -o "$TAX_DEPLOY_USER" -g "$TAX_DEPLOY_GROUP" "$TAX_DEPLOY_DATA_DIR"
BACKUP_DIR="$TAX_DEPLOY_DATA_DIR/backups"
install -d -m 700 -o "$TAX_DEPLOY_USER" -g "$TAX_DEPLOY_GROUP" "$BACKUP_DIR"
STAMP="$(date +%Y%m%d%H%M%S)-$$"
install -m 600 -o "$TAX_DEPLOY_USER" -g "$TAX_DEPLOY_GROUP" "$CADDYFILE" "$BACKUP_DIR/Caddyfile-$STAMP"
install -m 600 -o "$TAX_DEPLOY_USER" -g "$TAX_DEPLOY_GROUP" "$TAX_DEPLOY_ENV_FILE" "$BACKUP_DIR/environment-$STAMP"
if [[ -f "$TAX_DEPLOY_DB_PATH" ]]; then
    as_service python3 "$CHECKS" backup "$TAX_DEPLOY_DB_PATH" "$BACKUP_DIR/tax-$STAMP.db"
fi

# Stop before changing the live venv. A dependency failure leaves the service
# stopped, not running with a partially replaced environment. Keep backups.
LOAD_STATE="$(systemctl show tax.service --property=LoadState --value)"
if [[ "$LOAD_STATE" != "not-found" ]]; then
    systemctl stop tax.service
fi
if [[ ! -d "$TAX_DEPLOY_VENV_DIR" ]]; then
    as_service python3 -m venv "$TAX_DEPLOY_VENV_DIR"
fi
as_service "$TAX_DEPLOY_VENV_DIR/bin/python" -m pip install --require-hashes -r "$TAX_DEPLOY_SERVER_DIR/requirements.txt"
as_service bash -c 'cd "$1"; "$2" -c "import main, relay, storage, apns"' -- "$TAX_DEPLOY_SERVER_DIR" "$TAX_DEPLOY_VENV_DIR/bin/python"
install -m 644 "$RENDER_DIR/tax.service" /etc/systemd/system/tax.service
systemctl daemon-reload
systemctl enable tax.service
systemctl restart tax.service

healthy=false
for _ in {1..15}; do
    if python3 "$CHECKS" health "$TAX_DEPLOY_ENV_FILE" "$TAX_DEPLOY_PORT" 2>/dev/null; then
        healthy=true
        break
    fi
    sleep 1
done
if [[ "$healthy" != true ]]; then
    echo 'Health check failed. Inspect tax.service; backups were retained. No automatic database rollback was attempted.' >&2
    exit 1
fi
systemctl is-active --quiet tax.service
echo 'TAX deployed. Health check passed. Private backups are in the configured data directory.'
systemctl status tax.service --no-pager
