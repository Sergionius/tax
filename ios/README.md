# tax iOS

SwiftUI client for remote Orca workspaces: terminals, files, settings, and navigation from agent push notifications (pi, Claude Code, Codex).

- iOS 17+
- Swift 6, strict concurrency
- SwiftUI Observation (`@Observable`)
- API key in Keychain; URL and push preferences in UserDefaults
- Bundle identifiers come from `ios/Config/Public.xcconfig` (`com.example.tax` by default) and can be overridden privately via `ios/Config/Local.xcconfig`; see [`docs/LOCAL_CONFIGURATION.md`](../docs/LOCAL_CONFIGURATION.md)

## Getting started

1. Open `tax/tax.xcodeproj`.
2. Select your signing team and a physical iPhone for real APNs testing.
3. Make sure the **Push Notifications** capability is enabled.
4. In the app, open Settings and enter your server URL and API key.
5. Tap **Save Settings**, then **Request Push Registration**.

The simulator works for builds and unit/mock UI tests, but not for real APNs.

## Automated checks

```bash
xcodebuild build \
  -project tax/tax.xcodeproj \
  -scheme tax \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test \
  -project tax/tax.xcodeproj \
  -scheme tax \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:taxTests

xcodebuild test \
  -project tax/tax.xcodeproj \
  -scheme tax \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:taxUITests
```

UI tests launch the app against a mock backend through launch arguments and never touch the network, your Keychain, or secrets.

From the repository root:

```bash
./scripts/preflight.sh                 # build + unit tests
IOS_UI_TESTS=1 ./scripts/preflight.sh  # also UI smoke tests
```

Preflight never uploads anything to TestFlight/App Store.

## Versions and builds

- `MARKETING_VERSION` (`CFBundleShortVersionString`) changes for a user-facing release: `major.minor.patch`.
- `CURRENT_PROJECT_VERSION` (`CFBundleVersion`) increments for every uploaded build and is never reused.
- Change both for Debug and Release configurations at the same time.
- Uploading is a separate explicit command requiring confirmation; signing credentials and the APNs `.p8` are never stored in Git.
- Release notes draft: `./scripts/release-notes.sh [previous-tag]`.

## APNs verification

Follow [`APNS_SMOKE_CHECKLIST.md`](APNS_SMOKE_CHECKLIST.md). Debug builds use the APNs sandbox; TestFlight/App Store use production.

## Structure

- `tax/tax/` — the app, stores, services, and push routing.
- `tax/taxTests/` — unit tests and JSON fixtures matching the current backend schema.
- `tax/taxUITests/` — mock UI smoke tests.
- `.github/workflows/ios.yml` — simulator build, unit, and UI jobs.
