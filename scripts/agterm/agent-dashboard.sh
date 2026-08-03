#!/bin/sh
# Toggle a live grid of flagged panes that are running a foreground command.
set -eu
AGTERMCTL=${AGTERMCTL:-agtermctl}
agt() { if [ -n "${AGT_SOCKET:-}" ]; then "$AGTERMCTL" "$@" --socket "$AGT_SOCKET"; else "$AGTERMCTL" "$@"; fi; }
snapshot=$(agt tree --json)
panes=$(printf '%s' "$snapshot" | jq -r '.result.tree.workspaces[].sessions[] | select(.flagged) | (if .foreground then "\(.id):left" else empty end), (if .splitForeground then "\(.id):right" else empty end)')
[ -n "$panes" ] || { agt notify "No flagged agent is running" --title "Agent Dashboard" >/dev/null 2>&1 || true; exit 0; }
on_screen=$(printf '%s' "$snapshot" | jq -r '(.result.tree.dashboardMembers // []) | sort | join(" ")')
wanted=$(printf '%s\n' "$panes" | sort | tr '\n' ' ' | sed 's/ $//')
if [ "$on_screen" = "$wanted" ]; then agt dashboard --close >/dev/null; exit 0; fi
set --
for pane in $panes; do set -- "$@" "$pane"; done
agt dashboard "$@" --auto-size >/dev/null
