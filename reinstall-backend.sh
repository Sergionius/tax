#!/usr/bin/env bash
set -euo pipefail

# Update the TAX checkout on the server and redeploy the backend.
#
# Deployment values come from the private deployment configuration
# (TAX_DEPLOY_CONFIG, ~/.config/tax/deploy.env or the environment; see
# docs/LOCAL_CONFIGURATION.md). The configuration is validated before any
# Git command runs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/deploy-config.sh
source "$SCRIPT_DIR/scripts/deploy-config.sh"

if ! tax_deploy_config_load; then
    exit 1
fi

# The checkout and its private GitHub credentials belong to the service user.
# If an administrator starts the script as root, switch users before touching
# Git. The service identity and checkout location are passed explicitly so
# the service user session does not depend on root's HOME.
if [[ "$EUID" -eq 0 ]]; then
    exec /usr/bin/sudo -iu "$TAX_DEPLOY_USER" \
        env \
        TAX_DEPLOY_PROJECT_DIR="$TAX_DEPLOY_PROJECT_DIR" \
        TAX_DEPLOY_USER="$TAX_DEPLOY_USER" \
        TAX_DEPLOY_GROUP="$TAX_DEPLOY_GROUP" \
        "$TAX_DEPLOY_PROJECT_DIR/reinstall-backend.sh"
fi

cd "$TAX_DEPLOY_PROJECT_DIR"

echo "== Updating TAX =="
git fetch origin main
git pull --ff-only origin main

echo "== Deploying TAX backend =="
exec "$TAX_DEPLOY_PROJECT_DIR/deploy.sh"
