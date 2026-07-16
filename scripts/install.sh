#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

command -v pipx >/dev/null || { echo "❌ pipx is required" >&2; exit 1; }
pipx install --force -e .

echo "✅ tax installed via pipx"

if command -v pi >/dev/null; then
  LEGACY_EXTENSION="$HOME/.pi/agent/extensions/tax-push.ts"
  if [[ -f "$LEGACY_EXTENSION" ]]; then
    mv "$LEGACY_EXTENSION" "$LEGACY_EXTENSION.legacy.bak"
    echo "ℹ️ disabled legacy extension copy: $LEGACY_EXTENSION.legacy.bak"
  fi
  pi install "$ROOT_DIR"
  echo "✅ tax Pi extension installed"
else
  echo "⚠️ pi not found; extension installation skipped" >&2
fi

"$ROOT_DIR/scripts/install-launch-agent.sh"
