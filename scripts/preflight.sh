#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
UV_BIN="${UV_BIN:-uv}"

# Dedicated per-run output directory. Only preflight's own temporary data
# inside it is removed; shared directories such as dist/ or build/ are
# never touched.
PREFLIGHT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tax-preflight.XXXXXXXX")"
trap 'rm -rf "$PREFLIGHT_TMP"' EXIT

if ! command -v "$UV_BIN" >/dev/null 2>&1; then
  echo "uv is required for the Python checks (see README for install instructions)" >&2
  exit 1
fi

if [[ -n "$(git status --short)" ]]; then
  echo "⚠️  Working tree contains changes:" >&2
  git status --short >&2
fi

echo "== Version =="
"$UV_BIN" run --locked --extra dev python -c 'import tax; print(getattr(tax, "__version__", "from pyproject.toml"))'
git rev-parse --short HEAD
git describe --tags --abbrev=0 2>/dev/null || echo "no previous tag"

echo "== Python lint and tests (locked sync) =="
"$UV_BIN" sync --locked --extra dev
"$UV_BIN" run --locked --extra dev ruff check server src tests
"$UV_BIN" run --locked --extra dev pytest -q

echo "== Public tree check =="
# Covers the tracked snapshot only (git ls-files); ignored local files are
# never read, and Git history is not validated.
python3 scripts/check-public-tree.py

echo "== Extension tests (Node) =="
if command -v npm >/dev/null 2>&1; then
  npm test
else
  echo "ℹ️  npm unavailable; extension tests skipped"
fi

echo "== Build package =="
BUILD_OUT="$PREFLIGHT_TMP/dist"
"$UV_BIN" build --out-dir "$BUILD_OUT"
VENV_DIR="$PREFLIGHT_TMP/venv"
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" --quiet install "$BUILD_OUT"/*.whl
"$VENV_DIR/bin/tax" --help >/dev/null
"$VENV_DIR/bin/tax" notify --help >/dev/null
"$VENV_DIR/bin/tax" run --help >/dev/null
"$VENV_DIR/bin/tax" remote-host --help >/dev/null

if command -v xcodebuild >/dev/null && [[ -f ios/tax/tax.xcodeproj/project.pbxproj ]]; then
  IOS_DESTINATION="${IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
  # Default result directory lives inside the per-run temporary directory;
  # an explicit IOS_RESULT_DIR is used as-is and never deleted wholesale.
  IOS_RESULT_DIR="${IOS_RESULT_DIR:-$PREFLIGHT_TMP/ios-results}"
  mkdir -p "$IOS_RESULT_DIR"
  rm -rf "$IOS_RESULT_DIR/unit-tests.xcresult" "$IOS_RESULT_DIR/ui-tests.xcresult"

  echo "== iOS release metadata =="
  test -n "$(find ios/tax/tax/Assets.xcassets/AppIcon.appiconset -type f -name '*.png' -print -quit)"
  test -f ios/Config/Public.xcconfig
  # Configurable signing contract: the project must bind every configuration
  # to the neutral defaults in Public.xcconfig (optionally overridden by the
  # private ios/Config/Local.xcconfig), not to personal identifiers.
  grep -q '#include? "Local.xcconfig"' ios/Config/Public.xcconfig
  for variable in TAX_DEVELOPMENT_TEAM TAX_APP_BUNDLE_IDENTIFIER TAX_TESTS_BUNDLE_IDENTIFIER TAX_UITESTS_BUNDLE_IDENTIFIER; do
    grep -q "^${variable} =" ios/Config/Public.xcconfig
  done
  grep -q 'DEVELOPMENT_TEAM = \$(TAX_DEVELOPMENT_TEAM)' ios/Config/Public.xcconfig
  for variable in TAX_APP_BUNDLE_IDENTIFIER TAX_TESTS_BUNDLE_IDENTIFIER TAX_UITESTS_BUNDLE_IDENTIFIER; do
    grep -q "PRODUCT_BUNDLE_IDENTIFIER = \"\$(TAX_${variable#TAX_})\";" ios/tax/tax.xcodeproj/project.pbxproj
  done
  test "$(grep -c 'baseConfigurationReference = ' ios/tax/tax.xcodeproj/project.pbxproj)" -eq 8
  grep -q '<key>aps-environment</key>' ios/tax/tax/tax.entitlements
  test -f ios/tax/tax/PrivacyInfo.xcprivacy
  grep -q 'MARKETING_VERSION = ' ios/tax/tax.xcodeproj/project.pbxproj
  grep -q 'CURRENT_PROJECT_VERSION = ' ios/tax/tax.xcodeproj/project.pbxproj

  echo "== iOS simulator build =="
  # SWIFT_TREAT_WARNINGS_AS_ERRORS is intentionally not passed: it adds
  # -warnings-as-errors to every Swift invocation, which conflicts with the
  # -suppress-warnings flag used by SwiftTerm's SwiftTermBuildInfoGenerator
  # target. CI does not use this flag either.
  xcodebuild -quiet -project ios/tax/tax.xcodeproj -scheme tax \
    -destination 'generic/platform=iOS Simulator' -configuration Debug \
    CODE_SIGNING_ALLOWED=NO build

  echo "== iOS unit tests =="
  xcodebuild -quiet test -project ios/tax/tax.xcodeproj -scheme tax \
    -destination "$IOS_DESTINATION" -only-testing:taxTests \
    -resultBundlePath "$IOS_RESULT_DIR/unit-tests.xcresult"

  if [[ "${IOS_UI_TESTS:-0}" == "1" ]]; then
    echo "== iOS UI smoke tests =="
    xcodebuild -quiet test -project ios/tax/tax.xcodeproj -scheme tax \
      -destination "$IOS_DESTINATION" -only-testing:taxUITests \
      -resultBundlePath "$IOS_RESULT_DIR/ui-tests.xcresult"
  fi

  echo "== Release notes (since previous tag) =="
  "$ROOT_DIR/scripts/release-notes.sh" | tee "$IOS_RESULT_DIR/release-notes.md"
else
  echo "ℹ️  Xcode unavailable; iOS checks skipped"
fi

echo "✅ Preflight passed. No upload or deployment was performed."
