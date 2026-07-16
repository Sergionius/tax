# iOS Plan — tax

## Goal
Add a user-facing setting that controls which push notifications the user receives.

## Changes in `ios/tax/`

### 1. Add `PushMode` enum
```swift
enum PushMode: String, CaseIterable, Identifiable {
    case all = "all"
    case taxOnly = "tax"
    case off = "off"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Все"
        case .taxOnly: return "Только tax"
        case .off: return "Выключены"
        }
    }
}
```

### 2. Add `SettingsStore`
Use `@AppStorage` or observable store to persist `pushMode`:
```swift
@AppStorage("pushMode") var pushMode: String = PushMode.taxOnly.rawValue
```

### 3. Add `SettingsView`
- Picker with three options: Все / Только tax / Выключены
- Save button or automatic save on change

### 4. Update device registration
In the service that calls `POST /register-device`, include `preferences`:
```swift
let payload = [
    "device_token": deviceToken,
    "preferences": ["push_mode": pushMode]
]
```

### 5. Update task detail / reply view
No major changes. Keep reply text field and submit button.

### 6. Optional: client-side badge
When a push arrives with `app != "tax"` while mode is `taxOnly`, the app may still receive it silently; decide whether to show or ignore. Preferred: backend filters server-side.

### 7. Test checklist
- Register device in each mode and verify backend receives `preferences`.
- Send `/push` with `app: "tax"` → should arrive in `tax` mode, should be skipped in `off` mode.
- Send `/push` with `app: "other"` → should arrive only in `all` mode.

## Open questions
- Should the setting live in the app itself or in the system Settings bundle? Decision: in-app toggle is enough for MVP.
- Should we show current mode somewhere in the task list? Nice to have, not required.

## Acceptance criteria
- User can switch between All / Tax Only / Off in Settings.
- Selected mode is sent to backend on next registration.
- Push behavior matches selected mode.
- Existing reply flow continues to work.
