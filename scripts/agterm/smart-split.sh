#!/bin/sh
set -eu
AGTERMCTL=${AGTERMCTL:-agtermctl}
agt() { if [ -n "${AGT_SOCKET:-}" ]; then "$AGTERMCTL" "$@" --socket "$AGT_SOCKET"; else "$AGTERMCTL" "$@"; fi; }
split=$(agt tree --json --window "${AGT_WINDOW_ID:-active}" | jq -r --arg id "${AGT_SESSION_ID:-}" '.result.tree.workspaces[].sessions[] | select(.id==$id) | .split')
if [ "$split" = true ]; then
  agt session focus left --target "${AGT_SESSION_ID:-active}" >/dev/null
  agt session split off --target "${AGT_SESSION_ID:-active}" >/dev/null
else
  agt session split on --target "${AGT_SESSION_ID:-active}" >/dev/null
  agt session focus right --target "${AGT_SESSION_ID:-active}" >/dev/null
fi
