#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PREVIOUS_TAG="${1:-$(git describe --tags --abbrev=0 2>/dev/null || true)}"
if [[ -n "$PREVIOUS_TAG" ]]; then
  RANGE="$PREVIOUS_TAG..HEAD"
  echo "# Changes since $PREVIOUS_TAG"
else
  RANGE="HEAD"
  echo "# Changes"
fi

echo
CHANGES="$(git log "$RANGE" --no-merges --pretty='- %s (%h)' -- ios src server extensions 2>/dev/null || true)"
if [[ -n "$CHANGES" ]]; then
  printf '%s\n' "$CHANGES"
else
  echo "- No committed user-facing changes."
fi
