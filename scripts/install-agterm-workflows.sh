#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/agterm" && pwd)"
INSTALL_DIR="$HOME/.config/tax/agterm"
KEYMAP="$HOME/.config/agterm/keymap.conf"
ZSHRC="$HOME/.zshrc"
mkdir -p "$INSTALL_DIR" "$(dirname "$KEYMAP")"
cp "$SOURCE_DIR"/* "$INSTALL_DIR"/
chmod +x "$INSTALL_DIR"/*.sh

# Install the bundled Pi status hook when agterm is in its standard location.
# The app's full menu installer remains the source for Claude/Codex/OpenCode hooks.
AGTERM_STATUS="/Applications/agterm.app/Contents/Resources/agent-status"
if [[ -d "$AGTERM_STATUS" && -d "$HOME/.pi/agent" ]]; then
  STATUS_DIR="$HOME/.config/agterm/agent-status"
  mkdir -p "$STATUS_DIR" "$HOME/.pi/agent/extensions"
  sed 's|${AGTERMCTL:-agtermctl}|${AGTERMCTL:-/Applications/agterm.app/Contents/MacOS/agtermctl}|g' \
    "$AGTERM_STATUS/agterm-agent-status.sh" >"$STATUS_DIR/agterm-agent-status.sh"
  chmod +x "$STATUS_DIR/agterm-agent-status.sh"
  cp "$AGTERM_STATUS/pi/agterm-status.ts" "$HOME/.pi/agent/extensions/agterm-status.ts"
fi

begin="# >>> tax agterm workflows >>>"
end="# <<< tax agterm workflows <<<"
python3 - "$KEYMAP" "$begin" "$end" "$INSTALL_DIR" <<'PY'
import sys
from pathlib import Path
path, begin, end, scripts = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
text = path.read_text() if path.exists() else ""
block = f'''{begin}
command "Launch Pi Project" cmd+shift+g zsh -lc "{scripts}/project-launcher.sh"
command "Agent Dashboard" ctrl+shift+g zsh -lc "{scripts}/agent-dashboard.sh"
command "Pick Directory" ctrl+opt+d zsh -lc "AGT_PICK_ROOTS=$HOME/Developer {scripts}/pick-dir.sh"
command "Smart Split" ctrl+opt+s zsh -lc "{scripts}/smart-split.sh"
{end}'''
if begin in text and end in text:
    prefix, rest = text.split(begin, 1)
    _, suffix = rest.split(end, 1)
    text = prefix.rstrip() + "\n\n" + block + suffix
else:
    text = text.rstrip() + "\n\n" + block + "\n"
path.write_text(text)
PY

source_line="source \"$INSTALL_DIR/pi-resume.zsh\""
if ! grep -Fqx "$source_line" "$ZSHRC" 2>/dev/null; then
  printf '\n# Stable Pi conversation per agterm tab.\n%s\n' "$source_line" >>"$ZSHRC"
fi

if command -v agtermctl >/dev/null 2>&1; then
  agtermctl keymap reload
fi
printf 'Installed tax agterm workflows in %s\n' "$INSTALL_DIR"
