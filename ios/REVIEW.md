# iOS App Review + Fixes + APNs Setup

Single file with required code fixes and APNs certificate instructions.

## Required code fixes

### 1. Remove deprecated `fetch` from Info.plist

Edit `ios/tax/tax/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>UIBackgroundModes</key>
	<array>
		<string>remote-notification</string>
	</array>
</dict>
</plist>
```

### 2. Rename `taxApp` to `TaxApp`

Edit `ios/tax/tax/taxApp.swift`:

```swift
import SwiftUI

@main
struct TaxApp: App {
    ...
}
```

### 3. Fix SettingsView footer text

Edit `ios/tax/tax/Views/SettingsView.swift`, replace footer text:

```swift
} footer: {
    Text("Device token is registered to the server when you save settings.")
}
```

### 4. Show API key in Settings with a reveal toggle and save to Keychain

Edit `ios/tax/tax/Views/SettingsView.swift`. Replace the API key section with:

```swift
Section {
    HStack {
        if showAPIKey {
            TextField("API Key", text: $settings.apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
        } else {
            SecureField("API Key", text: $settings.apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        Button(showAPIKey ? "Hide" : "Show") {
            showAPIKey.toggle()
        }
        .buttonStyle(.borderless)
    }

    HStack {
        Button(settings.apiKey.isEmpty ? "Paste" : "Copy API Key") {
            if settings.apiKey.isEmpty, let pasted = UIPasteboard.general.string {
                settings.apiKey = pasted
            } else {
                UIPasteboard.general.string = settings.apiKey
            }
        }
        if !settings.apiKey.isEmpty {
            Button("Clear") { settings.apiKey = "" }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
        }
    }
} header: {
    Text("API Key")
} footer: {
    Text("Saved in Keychain. The backend requires Authorization: Bearer <key>")
}
```

Add to the top of `SettingsView`:

```swift
@State private var showAPIKey = false
```

Make sure `SettingsStore.save()` persists `apiKey` to the Keychain:

```swift
func save() {
    do {
        try Keychain.save(key: apiKeyKey, value: apiKey)
        defaults.set(serverURL, forKey: serverURLKey)
        cachedService = nil
        lastSaveError = nil
    } catch {
        lastSaveError = error.localizedDescription
    }
}
```

### 5. Fix race condition: register device token after TaskService is ready

Edit `ios/tax/tax/App/AppDelegate.swift`. In `didRegisterForRemoteNotificationsWithDeviceToken`, only save the token locally:

```swift
func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    NotificationCenter.default.post(name: .taxDeviceTokenUpdated, object: token)
}
```

Edit `ios/tax/tax/taxApp.swift`. After `configureDelegateService()`, register the saved token if it exists:

```swift
private func configureDelegateService() {
    appDelegate.taskService = settingsStore.configuredService
    registerSavedDeviceToken()
}

private func registerSavedDeviceToken() {
    let token = settingsStore.deviceToken
    guard let service = settingsStore.configuredService, !token.isEmpty else { return }
    Swift.Task {
        try? await service.registerDevice(token: token)
    }
}
```

### 6. Cache TaskService in SettingsStore

Edit `ios/tax/tax/Stores/SettingsStore.swift`:

```swift
@Observable
final class SettingsStore {
    var apiKey: String
    var serverURL: String
    var deviceToken: String
    var lastSaveError: String?

    @ObservationIgnored private var cachedService: TaskService?

    ...

    var configuredService: TaskService? {
        guard !apiKey.isEmpty, let url = URL(string: serverURL) else { return nil }
        if let cached = cachedService {
            return cached
        }
        let service = TaskService(baseURL: url, apiKey: apiKey)
        cachedService = service
        return service
    }

    private func invalidateService() {
        cachedService = nil
    }
}
```

Also call `invalidateService()` when `apiKey` or `serverURL` changes. Since they are `@Observable`, simplest is to invalidate in `save()`:

```swift
func save() {
    do {
        ...
        cachedService = nil
        ...
    }
}
```

### 7. Add launch screen / app icon (optional but recommended)

- Add `AppIcon` image set in `Assets.xcassets`
- The launch screen is generated from `UILaunchScreen_Generation` in Info.plist, so no extra work needed

### 8. Verify build warnings

In Xcode, press `Cmd+B` and check the Issue Navigator. Fix any Swift 6 concurrency warnings.

## APNs certificate setup

### What you need

1. Apple Developer Program membership ($99/year) — required for APNs
2. App ID with Push Notifications enabled
3. APNs Authentication Key (p8) — recommended over certificates

### Steps

#### 1. Create App ID in Apple Developer Portal

1. Go to https://developer.apple.com/account/resources/identifiers/list
2. Click `+` to add a new identifier
3. Choose `App IDs`
4. Select type `App`
5. Fill in:
   - Description: `tax`
   - Bundle ID: `ru.madmaximuus.yandexmapstestapp.YandexMapsTestApp` (explicit, must match Xcode)
6. Enable capability: `Push Notifications`
7. Click `Continue`, then `Register`

#### 2. Create APNs Authentication Key (p8)

1. Go to https://developer.apple.com/account/resources/authkeys/list
2. Click `+` to create a new key
3. Name: `tax APNS`
4. Enable `Apple Push Notifications service (APNs)`
5. Click `Continue`, then `Register`
6. Download the `.p8` file immediately. You can only download it once.
7. Note the `Key ID` (e.g., `ABCD123456`). It is shown in the portal.
8. Note your `Team ID` from https://developer.apple.com/account (top right, e.g., `WQ3X4DQT53`)

#### 3. Place the key on the VPS

On your Mac, copy the `.p8` file to the server:

```bash
scp /path/to/AuthKey_ABCD123456.p8 hermes@138.249.127.23:/home/hermes/tax/keys/AuthKey.p8
```

The server already expects it at `/home/hermes/tax/keys/AuthKey.p8` (see `TAX_APNS_KEY_PATH` in systemd unit).

#### 4. Update backend environment

Edit `/home/hermes/tax/server/.env` on the VPS:

```bash
TAX_APNS_KEY_ID=ABCD123456
TAX_APNS_TEAM_ID=WQ3X4DQT53
TAX_APNS_BUNDLE_ID=ru.madmaximuus.yandexmapstestapp.YandexMapsTestApp
TAX_APNS_USE_SANDBOX=true
```

For production builds and App Store distribution, set:

```bash
TAX_APNS_USE_SANDBOX=false
```

While testing with a debug build on your iPhone, use `true` (development APNs).

#### 5. Restart the backend

```bash
sudo systemctl restart tax.service
sudo systemctl status tax.service
```

Check logs:

```bash
sudo journalctl -u tax.service -f
```

## Full deployment checklist

### On VPS

1. Place `AuthKey.p8` at `/home/hermes/tax/keys/AuthKey.p8`
2. Ensure permissions:

```bash
sudo chown hermes:hermes /home/hermes/tax/keys/AuthKey.p8
sudo chmod 600 /home/hermes/tax/keys/AuthKey.p8
```

3. Update `/home/hermes/tax/server/.env` with APNS values
4. Restart: `sudo systemctl restart tax.service`

### On Mac

1. Add to `~/.zshrc`:

```bash
export TAX_API_KEY="your-backend-api-key"
export TAX_SERVER="https://tax.138-249-127-23.nip.io"
```

2. Reload: `source ~/.zshrc`

### In Xcode

1. Open `ios/tax/tax.xcodeproj`
2. Select target → `Signing & Capabilities`:
   - Team: your Apple Developer team
   - Bundle Identifier: `ru.madmaximuus.yandexmapstestapp.YandexMapsTestApp`
   - Capability: `Push Notifications` must be present
3. Build and run on a real iPhone (not simulator)

### In the iOS app

1. Open Settings tab
2. Enter API key (same as backend `TAX_API_KEY`)
3. Enter server URL: `https://tax.138-249-127-23.nip.io`
4. Tap `Request Push Registration` → allow notifications
5. Tap `Save Settings`
6. Device token should appear; tap `Copy Device Token` if you want to use it manually

### Test push from Mac

```bash
source ~/.zshrc
tax run --detach pi -p "hello iOS push"
```

You should see a push notification on your iPhone within seconds.

Tap the notification → it opens the task in the app.

Tap `Reply` → type a message → send.

Back on Mac:

```bash
tax status
```

The task should show `replied` status.

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| No push received | APNS key not configured | Check `.env`, restart service, check `journalctl` |
| `Bad device token` (APNs error 400) | Sandbox/production mismatch | Set `TAX_APNS_USE_SANDBOX=true` for debug builds, `false` for release |
| `Invalid provider token` (APNs error 403) | Wrong key ID or team ID | Verify `TAX_APNS_KEY_ID` and `TAX_APNS_TEAM_ID` |
| `Topic disallowed` | Wrong bundle ID | Verify `TAX_APNS_BUNDLE_ID=ru.madmaximuus.yandexmapstestapp.YandexMapsTestApp` |
| App doesn't ask for push | Capability missing | Add `Push Notifications` in Xcode Signing & Capabilities |
| Token not registered | API key wrong in iOS | Check Settings → API key, use `Check Server Health` |
| Reply not received on Mac | Task ID mismatch | Ensure reply is sent to the same task opened by the push |

## Security notes

- Never commit `AuthKey.p8` to git. The repo already has `keys/` in `.gitignore` and `.gitignore` ignores `*.p8`.
- Never share your Apple Developer Team ID or Key ID in public.
- The backend API key is the same for Mac and iOS. Keep it secret.
