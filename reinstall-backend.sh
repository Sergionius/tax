#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${TAX_PROJECT_DIR:-/home/hermes/tax}"

# The checkout and its private GitHub credentials belong to hermes. If an
# administrator starts the script as root, switch users before touching Git.
if [[ "$EUID" -eq 0 ]]; then
    exec /usr/bin/sudo -iu hermes env TAX_PROJECT_DIR="$PROJECT_DIR" "$PROJECT_DIR/reinstall-backend.sh"
fi

cd "$PROJECT_DIR"

echo "== Updating tax =="
git fetch origin main
git pull --ff-only origin main

echo "== Deploying tax backend =="
exec "$PROJECT_DIR/deploy.sh"
