#!/usr/bin/env zsh
# Source from ~/.zshrc. A stable agterm tab owns a stable Pi session.
pi() {
  emulate -L zsh
  local sid=${AGTERM_SESSION_ID:l}
  [[ -z $sid ]] && { command pi "$@"; return; }

  if [[ "$1" == --session-id && "${2:l}" == "$sid" ]]; then
    shift 2
  else
    local arg
    for arg in "$@"; do
      case $arg in
        --session|--session=*|--session-id|--session-id=*|-r|--resume|-c|--continue|--fork|--fork=*|\
        --no-session|-p|--print|-h|--help|-v|--version|install|remove|uninstall|update|list|config|auth)
          command pi "$@"; return ;;
      esac
    done
  fi

  command pi --session-id "$sid" "$@"
}
