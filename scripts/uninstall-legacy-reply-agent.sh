#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ℹ️ launchd cleanup skipped: macOS is required"
  exit 0
fi

launchctl bootout "gui/$UID/tax.agent" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/tax.agent.plist"

echo "✅ legacy tax.agent LaunchAgent removed"
