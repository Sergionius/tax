#!/usr/bin/env bash
set -euo pipefail

# Update Git as its owner, then apply deployment with root privileges.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/deploy-config.sh"
tax_deploy_config_load || exit 1
CONFIG_FILE="$(tax_deploy_config_file)" || { echo 'A private deployment config file is required.' >&2; exit 1; }
export TAX_DEPLOY_CONFIG="$CONFIG_FILE"
cd "$TAX_DEPLOY_PROJECT_DIR"

if [[ -n "$(git -c safe.directory="$TAX_DEPLOY_PROJECT_DIR" status --porcelain)" ]]; then
    echo 'Checkout has local changes; preserve them before updating.' >&2
    exit 1
fi
if [[ "$EUID" -eq 0 ]]; then
    runuser -u "$TAX_DEPLOY_USER" -- git -C "$TAX_DEPLOY_PROJECT_DIR" pull --ff-only origin main
    exec "$TAX_DEPLOY_PROJECT_DIR/deploy.sh"
else
    git pull --ff-only origin main
    deploy_env=("TAX_DEPLOY_CONFIG=$CONFIG_FILE")
    for name in $TAX_DEPLOY_CONTRACT_VARS; do
        deploy_env+=("$name=${!name}")
    done
    exec sudo env "${deploy_env[@]}" "$TAX_DEPLOY_PROJECT_DIR/deploy.sh"
fi
