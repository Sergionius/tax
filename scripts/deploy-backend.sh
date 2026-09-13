#!/usr/bin/env bash
set -euo pipefail

# Trigger the backend deployment on the configured server over SSH.
#
# The SSH destination and the remote checkout path come from the private
# deployment configuration (TAX_DEPLOY_CONFIG, ~/.config/tax/deploy.env or
# the environment; see docs/LOCAL_CONFIGURATION.md). The configuration is
# validated before any SSH connection is opened.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=deploy-config.sh
source "$SCRIPT_DIR/deploy-config.sh"

if ! tax_deploy_config_load; then
    exit 1
fi

# Build the remote command with POSIX quoting so unusual (but valid) values
# cannot break out of the remote shell.
remote_dir="$(tax_deploy_sh_quote "$TAX_DEPLOY_PROJECT_DIR")"
remote_command="set -euo pipefail; cd ${remote_dir}; git fetch origin main; git pull --ff-only origin main; ./deploy.sh"

printf 'Deploying TAX backend on the configured host...\n'
exec ssh -t "$TAX_DEPLOY_HOST" "$remote_command"
