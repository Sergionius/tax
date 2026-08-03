#!/bin/sh
# Native project picker: create/reuse a workspace and start Pi with an optional prompt.
set -eu
AGTERMCTL=${AGTERMCTL:-agtermctl}
ROOTS=${TAX_PROJECT_ROOTS:-$HOME/Developer}
LIMIT=1000

agt() {
  if [ -n "${AGT_SOCKET:-}" ]; then "$AGTERMCTL" "$@" --socket "$AGT_SOCKET"; else "$AGTERMCTL" "$@"; fi
}
fail() { agt notify "$1" --title "Launch Pi Project" >/dev/null 2>&1 || true; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is not on PATH"

list=''
old_ifs=$IFS; IFS=:
# shellcheck disable=SC2086
set -- $ROOTS
IFS=$old_ifs
for root in "$@"; do
  root=${root%/}; [ -d "$root" ] || continue
  for dir in "$root"/*/; do
    [ -d "$dir" ] || continue; dir=${dir%/}
    list="${list}${dir}\t${dir##*/}\n"
  done
done
[ -n "$list" ] || fail "No projects under $ROOTS"
count=$(printf '%b' "$list" | wc -l | tr -d ' ')
[ "$count" -le "$LIMIT" ] || fail "$count projects exceed picker limit $LIMIT"
items=$(printf '%b' "$list" | jq -R -s 'split("\n") | map(select(length>0)|split("\t")) | map({id:.[0],label:.[1],subtitle:.[0]})')

set +e
choice=$(printf '%s' "$items" | agt pick --prompt "project — or project: prompt" --allow-custom --window "${AGT_WINDOW_ID:-active}")
rc=$?; set -e
[ "$rc" -eq 2 ] && exit 0
[ "$rc" -eq 0 ] || fail "Picker failed (exit $rc)"
result=$(printf '%s' "$choice" | jq -r '.result')
prompt=''
case $result in
  picked) dir=$(printf '%s' "$choice" | jq -r '.id') ;;
  custom)
    query=$(printf '%s' "$choice" | jq -r '.query')
    key=${query%%:*}; prompt=${query#*:}; prompt=$(printf '%s' "$prompt" | sed 's/^[[:space:]]*//')
    matches=$(printf '%b' "$list" | awk -F '\t' -v key="$key" 'tolower($2)==tolower(key){print $1}')
    [ "$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 1 ] || fail "Use exact project name before colon"
    dir=$matches ;;
  *) exit 0 ;;
esac
workspace=${dir##*/}
if [ -n "$prompt" ]; then
  file=$(mktemp "${TMPDIR:-/tmp}/tax-prompt.XXXXXX") || fail "mktemp failed"
  printf '%s' "$prompt" >"$file"
  command="zsh -lc 'p=\$(cat \"$file\"); rm -f \"$file\"; pi \"\$p\"'"
  agt session new --window "${AGT_WINDOW_ID:-active}" --workspace-name "$workspace" --create-workspace --cwd "$dir" --command "$command" >/dev/null || { rm -f "$file"; fail "Session launch failed"; }
else
  agt session new --window "${AGT_WINDOW_ID:-active}" --workspace-name "$workspace" --create-workspace --cwd "$dir" --command "zsh -lc pi" >/dev/null || fail "Session launch failed"
fi
