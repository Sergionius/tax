#!/usr/bin/env bash
set -euo pipefail

HOST="${TAX_DEPLOY_HOST:-hermes@138.249.127.23}"
PROJECT_DIR="${TAX_DEPLOY_PROJECT_DIR:-/home/hermes/tax}"

printf 'Deploying tax backend on %s...\n' "$HOST"
exec ssh -t "$HOST" \
  "set -euo pipefail; cd '$PROJECT_DIR'; git fetch origin main; git pull --ff-only origin main; ./deploy.sh"
