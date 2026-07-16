#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

git pull
git submodule update --init --recursive

"$ROOT_DIR/scripts/install.sh"

echo "✅ tax reinstalled"
