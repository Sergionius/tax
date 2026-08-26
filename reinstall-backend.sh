#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${TAX_PROJECT_DIR:-/home/hermes/tax}"
cd "$PROJECT_DIR"

echo "== Updating tax =="
git fetch origin main
git pull --ff-only origin main

echo "== Deploying tax backend =="
exec "$PROJECT_DIR/deploy.sh"
