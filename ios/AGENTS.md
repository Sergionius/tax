# AGENTS.md — iOS SwiftUI app for tax

This file provides guidance to AI agents building the iOS SwiftUI app for the `tax` project.

## Project overview

- **Backend:** FastAPI at `https://tax.138-249-127-23.nip.io`
- **Authentication:** `Authorization: Bearer ** Push transport:** Apple Push Notification service (APNs). The backend sends pushes directly using a JWT `.p8` auth key.
- **Flow:**
  1. Mac CLI (`tax run`) executes an AI agent (`pi`) and sends the result to the backend via `POST /push`.
  2. Backend stores the task and sends a push to the iPhone.
  3. iPhone receives the push, user opens the app, sees task details, and can reply.
  4. iPhone sends the reply to `POST /task/{id}/reply`.
  5. Mac agent polls the backend and sends the reply to the original Orca terminal via `orca terminal send`.

## Tech stack

- **SwiftUI** with `@Observable` / `@State` / `@Bindable`
- **Swift 6** with strict concurrency checking enabled (`SWIFT_STRICT_CONCURRENCY = complete`)
- **Target:** iOS 17+
- **Networking:** `URLSession` with `async/await`
- **Push:** `UserNotifications` framework, `UNUserNotificationCenterDelegate`
- **Bundle ID:** `ru.madmaximuus.yandexmapstestapp.YandexMapsTestApp`
- **Capability:** Push Notifications

## API schema

```swift
struct Task: Codable, Identifiable, Sendable {
    let id: String
    let deviceToken: String?
    let title: String
    let body: String
    let status: String
    let context: String?
    let logs: String?
    let reply: String?
    let createdAt: String
    let updatedAt: String
}

struct TaskListResponse: Codable, Sendable {
    let ok: Bool
    let tasks: [Task]
}

struct TaskResponse: Codable, Sendable {
    let ok: Bool
    let task: Task
}

struct ReplyPayload: Codable, Sendable {
    let text: String
}
```

Endpoints (all require `Authorization: Bearer ** GET /tasks` — list recent tasks
- `GET /task/{id}` — fetch one task
- `POST /task/{id}/reply` — send reply from iPhone
- `GET /health` — health check

## SwiftUI rules

- Use `@Observable` models, not `ObservableObject`.
- Keep views small; extract subviews.
- Use `NavigationStack` and `.navigationDestination`.
- Use `List` with `.refreshable { await load() }`.
- Use `ContentUnavailableView` for empty states and `ProgressView` for loading.
- Use `TextEditor` for reply input; `Form` or `VStack` for layout.
- Prefer `Markdown` for logs only if the source is trusted; otherwise plain text.

## Swift concurrency rules

- All UI mutations happen on `@MainActor`.
- Network service must be `nonisolated` or an actor to avoid main-thread blocking.
- Make all Codable models `Sendable` (value types or `final class` with `Sendable`).
- Avoid `@unchecked Sendable`.
- Use `Task { ... }` from views; `.task` cancels automatically on view disappear.
- Avoid `DispatchQueue.main.async`; use `MainActor.run` or `@MainActor`.

## Networking service

```swift
import Foundation

nonisolated actor TaskService {
    private let baseURL: URL
    private let apiKey: String

    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    func fetchTasks() async throws -> [Task] {
        let url = baseURL.appending(path: "tasks")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(TaskListResponse.self, from: data).tasks
    }

    func fetchTask(id: String) async throws -> Task {
        let url = baseURL.appending(path: "task/\(id)")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(TaskResponse.self, from: data).task
    }

    func sendReply(taskID: String, text: String) async throws -> Task {
        let url = baseURL.appending(path: "task/\(taskID)/reply")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ReplyPayload(text: text))
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(TaskResponse.self, from: data).task
    }
}
```

## Push notifications

- Register in `taxApp.swift` at launch:
  ```swift
  UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
  UIApplication.shared.registerForRemoteNotifications()
  ```
- Implement `UNUserNotificationCenterDelegate` for foreground presentation and reply actions.
- Extract `task_id` from the push payload.
- On device token registration, display it in the app so the user can copy it to Mac CLI:
  ```bash
  tax config --device-token <token>
  ```
- Add a `UNNotificationAction` with identifier `REPLY` for inline replies if desired.

## App architecture

```
tax/ios/
├── taxApp.swift                  // App entry, UNUserNotificationCenter setup
├── AppState.swift                // @Observable global state
├── Models/
│   └── Task.swift
├── Services/
│   ├── TaskService.swift
│   └── NotificationService.swift
├── Views/
│   ├── TaskListView.swift
│   ├── TaskDetailView.swift
│   └── SettingsView.swift
└── tax.entitlements              // Push Notifications capability
```

## Build and run

1. Open `tax/ios/tax.xcodeproj` in Xcode.
2. Select a real iPhone device (simulator cannot receive APNs).
3. Set the signing team and ensure bundle ID matches Apple Developer Portal.
4. Enable Push Notifications capability.
5. Build and run.
6. Copy the device token from the Settings view.

## Testing

1. On Mac:
   ```bash
   tax config --device-token <token>
   tax run pi -p "привет"
   ```
2. iPhone should receive a push.
3. Tap the push or open the app; send a reply.
4. Mac agent should receive the reply and feed it to the original Orca terminal.

## Common pitfalls

- Do not hardcode the API key. Use a settings text field for MVP; keychain for production.
- Do not decode dates as `Date` unless using a custom ISO8601 strategy; backend returns ISO strings.
- APNs device token is a hex string; do not wrap it in `<>` or spaces when copying to `tax config`.
- Do not forget `Content-Type: application/json` on POST requests.
- Simulators cannot receive APNs; use a real device.
