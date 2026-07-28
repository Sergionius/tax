#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
PYTHON="${PYTHON:-$ROOT_DIR/.venv/bin/python}"

if [[ ! -x "$PYTHON" ]]; then
  PYTHON="$(command -v python3)"
fi

if [[ -n "$(git status --short)" ]]; then
  echo "⚠️  Working tree contains changes:" >&2
  git status --short >&2
fi

echo "== Version =="
"$PYTHON" -c 'import tax; print(getattr(tax, "__version__", "from pyproject.toml"))'
git rev-parse --short HEAD
git describe --tags --abbrev=0 2>/dev/null || echo "no previous tag"

echo "== Python lint and tests =="
"$PYTHON" -m ruff check server src tests
"$PYTHON" -m pytest -q

echo "== Build package =="
rm -rf dist build
"$PYTHON" -m build
TMP_VENV="$(mktemp -d)/venv"
"$PYTHON" -m venv "$TMP_VENV"
"$TMP_VENV/bin/pip" --quiet install dist/*.whl
"$TMP_VENV/bin/tax" --help >/dev/null
"$TMP_VENV/bin/tax" agent --help >/dev/null

if command -v xcodebuild >/dev/null && [[ -f ios/tax/tax.xcodeproj/project.pbxproj ]]; then
  IOS_DESTINATION="${IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
  IOS_RESULT_DIR="${IOS_RESULT_DIR:-$ROOT_DIR/tmp/ios-preflight}"
  rm -rf "$IOS_RESULT_DIR"
  mkdir -p "$IOS_RESULT_DIR"

  echo "== iOS release metadata =="
  test -n "$(find ios/tax/tax/Assets.xcassets/AppIcon.appiconset -type f -name '*.png' -print -quit)"
  grep -q 'PRODUCT_BUNDLE_IDENTIFIER = ru.madmaximuus.yandexmapstestapp.YandexMapsTestApp;' ios/tax/tax.xcodeproj/project.pbxproj
  grep -q '<key>aps-environment</key>' ios/tax/tax/tax.entitlements
  test -f ios/tax/tax/PrivacyInfo.xcprivacy
  grep -q 'MARKETING_VERSION = ' ios/tax/tax.xcodeproj/project.pbxproj
  grep -q 'CURRENT_PROJECT_VERSION = ' ios/tax/tax.xcodeproj/project.pbxproj

  echo "== iOS simulator build =="
  xcodebuild -quiet -project ios/tax/tax.xcodeproj -scheme tax \
    -destination 'generic/platform=iOS Simulator' -configuration Debug \
    CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build

  echo "== iOS unit tests =="
  xcodebuild -quiet test -project ios/tax/tax.xcodeproj -scheme tax \
    -destination "$IOS_DESTINATION" -only-testing:taxTests \
    -resultBundlePath "$IOS_RESULT_DIR/unit-tests.xcresult" \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

  if [[ "${IOS_UI_TESTS:-0}" == "1" ]]; then
    echo "== iOS UI smoke tests =="
    xcodebuild -quiet test -project ios/tax/tax.xcodeproj -scheme tax \
      -destination "$IOS_DESTINATION" -only-testing:taxUITests \
      -resultBundlePath "$IOS_RESULT_DIR/ui-tests.xcresult" \
      SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
  fi

  "$ROOT_DIR/scripts/release-notes.sh" > "$IOS_RESULT_DIR/release-notes.md"
  echo "Release notes: $IOS_RESULT_DIR/release-notes.md"
else
  echo "ℹ️  Xcode unavailable; iOS checks skipped"
fi

echo "✅ Preflight passed. No upload or deployment was performed."
