# Agent Instructions: tax iOS

This file is for AI coding agents (pi, Claude Code, Codex, etc.) working on the iOS SwiftUI app for the `tax` project.

## Project overview

`tax` = Task Agent eXchange. Push notifications and remote reply for AI agents running in `agterm` on a Mac.

- Mac runs `pi` via `tax run`.
- On completion, Mac POSTs to the FastAPI backend at `https://tax.138-249-127-23.nip.io`.
- Backend sends an APNs push to the iPhone.
- iPhone shows the task; user types a reply; iPhone POSTs the reply to the backend.
- Mac long-polls the backend and feeds the reply back into `agterm`.

## Repository layout

```
tax/ios/
├── tax.xcodeproj/         # Xcode project (create once)
├── tax/
│   ├── taxApp.swift         # App entry + UNUserNotificationCenter setup
│   ├── AppState.swift       # @Observable app state
│   ├── Services/
│   │   ├── TaskService.swift      # Backend API client
│   │   └── NotificationService.swift # APNs registration + delegate
│   ├── Views/
│   │   ├── TaskListView.swift
│   │   ├── TaskDetailView.swift
│   │   └── ReplyView.swift
│   └── Models/
│       └── Task.swift
└── tax.entitlements
```

## API reference

Base URL: `https://tax.138-249-127-23.nip.io`
All endpoints require `Authorization: Bearer <TAX_API_KEY>`.

- `GET /health` → `{ ok: true }`
- `POST /push` → `{ ok: true, task_id: string }`
  - Request body: `{ device_token?: string, title: string, body: string, context?: string, logs?: string }`
- `GET /tasks` → `{ ok: true, tasks: Task[] }`
- `GET /task/{id}` → `{ ok: true, task: Task }`
- `POST /task/{id}/reply` → `{ ok: true, task: Task }`
  - Request body: `{ text: string }`

## Task model (Swift)

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

    enum CodingKeys: String, CodingKey {
        case id, title, body, status, context, logs, reply
        case deviceToken = "device_token"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
```

## Tech stack

- iOS 17+
- Swift 6
- SwiftUI with `@Observable` / `@Bindable`
- Strict concurrency checking enabled (`SWIFT_STRICT_CONCURRENCY = complete`)
- APNs for push notifications
- `UserNotifications` framework for registration, delegate, and reply actions
- `URLSession` with `async/await`
- No third-party networking libraries for MVP

## Coding rules

1. **Swift 6 strict concurrency**: all models are `Sendable`, UI state lives on `@MainActor`, network work is `nonisolated` or inside an actor.
2. **No `ObservableObject`**: prefer `@Observable` classes and `@State`/`@Bindable`.
3. **No `DispatchQueue.main.async`**: use `MainActor.run` or keep state `@MainActor`.
4. **Small views**: extract subviews; keep body short.
5. **Loading/error states**: use `ContentUnavailableView` and clear error messages.
6. **Security**: do not hardcode the API key. Provide a settings screen or keychain input.
7. **Dates**: backend returns ISO8601 strings. Decode as `String` unless you add a custom date strategy.

## Push notification handling

- Register for remote notifications in `taxApp.init` or `application(_:didFinishLaunchingWithOptions:)`.
- Request authorization with `.alert`, `.badge`, `.sound`.
- Implement `UNUserNotificationCenterDelegate`.
- On receiving a push, extract `task_id` from the payload root.
- Store the device token and show it in the Settings view so the user can copy it to the Mac CLI.
- Define a `TASK_REPLY` notification category with a `REPLY` action.
- When the user replies from the notification, POST the text to `/task/{task_id}/reply`.

## App entry example

```swift
import SwiftUI
import UserNotifications

@main
struct taxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task {
            try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            await UIApplication.shared.registerForRemoteNotifications()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("APNs device token: \(token)")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Failed to register for remote notifications: \(error)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .badge, .sound])
    }
}
```

## Network service pattern

```swift
nonisolated actor TaskService {
    private let baseURL: URL
    private let apiKey: String

    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    private func request(for path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    func fetchTasks() async throws -> [Task] {
        let (data, _) = try await URLSession.shared.data(for: request(for: "tasks"))
        return try JSONDecoder().decode(TaskListResponse.self, from: data).tasks
    }

    func sendReply(taskID: String, text: String) async throws -> Task {
        let body = try JSONEncoder().encode(["text": text])
        let (data, _) = try await URLSession.shared.data(
            for: request(for: "task/\(taskID)/reply", method: "POST", body: body)
        )
        return try JSONDecoder().decode(TaskResponse.self, from: data).task
    }
}

struct TaskListResponse: Codable, Sendable {
    let ok: Bool
    let tasks: [Task]
}

struct TaskResponse: Codable, Sendable {
    let ok: Bool
    let task: Task
}
```

## Signing and capabilities

- Bundle ID: `com.sergionius.tax`
- Team: your Apple Development Team
- Capability: Push Notifications
- Background modes: not required for MVP

## Testing checklist

- [ ] App builds on real device (simulator cannot receive APNs)
- [ ] Device token is printed and visible in Settings
- [ ] Mac CLI configured with the token
- [ ] `tax run pi -p "hello"` delivers a push to the iPhone
- [ ] Tapping the notification opens the task detail
- [ ] Sending a reply from the app makes Mac CLI receive it and feed it to agterm

## Common errors

- `401 Unauthorized` on backend: API key is missing or wrong. The key is set in `TAX_API_KEY` on the Mac and entered in the iOS app settings.
- `device_token` empty in task: Mac CLI was not configured with the token; push won't be sent, but the task is still stored.
- No push received: check that the backend `.env` has APNs key, team, bundle ID, and that `AuthKey.p8` is in `keys/`.
- `stale ctx` error from pi: fix the `agterm-status.ts` extension; wrap retry handlers in `try/catch`.
