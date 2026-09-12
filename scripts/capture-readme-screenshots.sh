#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/ios/tax/tax.xcodeproj"
SCHEME="tax"
DEVICE_NAME="${TAX_SCREENSHOT_DEVICE_NAME:-TAX README iPhone 16 Pro}"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
DERIVED_DATA="${TAX_SCREENSHOT_DERIVED_DATA:-$ROOT_DIR/tmp/readme-screenshots-derived-data}"
OUTPUT_DIR="${TAX_SCREENSHOT_OUTPUT_DIR:-$ROOT_DIR/docs/images}"

if [[ -n "${TAX_SCREENSHOT_DEVICE_ID:-}" ]]; then
    DEVICE_ID="$TAX_SCREENSHOT_DEVICE_ID"
else
    DEVICE_ID="$(xcrun simctl list devices -j | python3 -c '
import json, sys
name = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
print(next((device["udid"] for values in devices.values() for device in values if device["name"] == name and device.get("isAvailable", True)), ""))
' "$DEVICE_NAME")"
fi

if [[ -z "$DEVICE_ID" ]]; then
    RUNTIME_ID="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
runtimes = [item for item in json.load(sys.stdin)["runtimes"] if item.get("isAvailable") and item.get("platform") == "iOS"]
if not runtimes:
    raise SystemExit("No available iOS Simulator runtime")
print(runtimes[-1]["identifier"])
')"
    DEVICE_ID="$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME_ID")"
fi

xcrun simctl boot "$DEVICE_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEVICE_ID" -b
defaults write com.apple.iphonesimulator DevicePreferences -dict-add "$DEVICE_ID" '{ ConnectHardwareKeyboard = 0; }'
open -a Simulator --args -CurrentDeviceUDID "$DEVICE_ID"
xcrun simctl ui "$DEVICE_ID" appearance dark
xcrun simctl spawn "$DEVICE_ID" defaults write NSGlobalDomain AppleLanguages -array "en-US"
xcrun simctl spawn "$DEVICE_ID" defaults write NSGlobalDomain AppleLocale "en_US"
xcrun simctl spawn "$DEVICE_ID" defaults write NSGlobalDomain AppleKeyboards -array "en_US@sw=QWERTY;hw=Automatic"
xcrun simctl spawn "$DEVICE_ID" defaults write com.apple.keyboard.preferences KeyboardLastUsed "en_US@sw=QWERTY;hw=Automatic"
xcrun simctl spawn "$DEVICE_ID" defaults write com.apple.keyboard.preferences KeyboardsCurrentAndNext -array "en_US@sw=QWERTY;hw=Automatic"
xcrun simctl spawn "$DEVICE_ID" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
xcrun simctl spawn "$DEVICE_ID" defaults write com.apple.keyboard.preferences UIKeyboardDidShowInternationalInfoIntroduction -bool true
xcrun simctl status_bar "$DEVICE_ID" override \
    --time "9:41" \
    --dataNetwork wifi \
    --wifiMode active \
    --wifiBars 3 \
    --cellularMode active \
    --cellularBars 4 \
    --batteryState charged \
    --batteryLevel 100

xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$DEVICE_ID" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/tax.app"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Info.plist")"
xcrun simctl install "$DEVICE_ID" "$APP_PATH"
mkdir -p "$OUTPUT_DIR"

for screen in workspaces terminal files settings; do
    xcrun simctl launch --terminate-running-process "$DEVICE_ID" "$BUNDLE_ID" \
        --ui-testing \
        --screenshot-mode \
        --screenshot-screen "$screen" >/dev/null
    sleep "${TAX_SCREENSHOT_SETTLE_SECONDS:-8}"
    xcrun simctl io "$DEVICE_ID" screenshot "$OUTPUT_DIR/$screen.png" >/dev/null
done

printf 'README screenshots written to %s\n' "$OUTPUT_DIR"
