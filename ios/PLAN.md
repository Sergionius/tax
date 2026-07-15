# tax iOS App — Plan

Single-file plan for building and connecting the iOS SwiftUI app for `tax`.

## Project context

- Backend: FastAPI at `https://tax.138-249-127-23.nip.io`
- Mac CLI `tax` reads `TAX_API_KEY` and `TAX_SERVER` from `~/.zshrc`, runs `pi`, and sends results to backend `POST /push`
- Backend sends push notifications via APNs to iOS
- iOS app receives push, lists tasks, opens a task, and sends a reply back to the Mac

## Mac environment

Add to `~/.zshrc`:

```bash
export TAX_API_KEY="your-backend-api-key"
export TAX_SERVER="https://tax.138-249-127-23.nip.io"
```

Reload and verify:

```bash
source ~/.zshrc
echo $TAX_API_KEY
echo $TAX_SERVER
```

## Backend endpoints

All endpoints require `Authorization: Bearer <TAX_API_KEY>`.

| Method | Path | Purpose | Body | Response |
|--------|------|---------|------|----------|
| POST | `/push` | Create a new task/push | `PushPayload` | `{ "ok": true, "task_id": "..." }` |
| GET | `/tasks` | List recent tasks | — | `{ "ok": true, "tasks": [...] }` |
| GET | `/task/{id}` | Get one task | — | `{ "ok": true, "task": {...} }` |
| POST | `/task/{id}/reply` | Submit a reply | `{ "text": "..." }` | `{ "ok": true, "task": {...} }` |
| POST | `/register-device` | Register iOS device token | `{ "device_token": "..." }` | `{ "ok": true }` |
| GET | `/health` | Health check | — | `{ "ok": true }` |

## iOS stack

- iOS 17+
- Swift 6
- SwiftUI + `@Observable`
- `async/await` + `URLSession`
- `UNUserNotificationCenter` for APNs
- Keychain for API key
- UserDefaults for server URL
- Bundle ID: `ru.madmaximuus.yandexmapstestapp.YandexMapsTestApp`

## Project files

Existing:

```
ios/tax/tax.xcodeproj
ios/tax/tax/Info.plist
ios/tax/tax/tax.entitlements
ios/tax/tax/ContentView.swift
ios/tax/tax/taxApp.swift
ios/skills/AGENTS.md
ios/skills/swiftui-pro.md
ios/skills/swift-concurrency-pro.md
ios/skills/background-execution.md
ios/skills/ios-simulator.md
```

## Step-by-step implementation

### 1. Project setup

- Verify bundle ID = `ru.madmaximuus.yandexmapstestapp.YandexMapsTestApp`
- Verify `tax.entitlements` contains `aps-environment` key
- Verify `Info.plist` allows remote notifications
- Add an `AppDelegate` and connect it to the SwiftUI app lifecycle

### 2. Models

Create `ios/tax/tax/Models/Task.swift`:

```swift
import Foundation

struct Task: Identifiable, Codable, Sendable {
    let id: String
    let deviceToken: String
    let title: String
    let body: String
    var status: String
    let context: String
    let logs: String
    let reply: String?
    let createdAt: String
    let updatedAt: String
}

struct ReplyRequest: Codable, Sendable {
    let text: String
}

struct DeviceTokenRequest: Codable, Sendable {
    let deviceToken: String
}
```

### 3. TaskService

Create `ios/tax/tax/Services/TaskService.swift` as an actor:

```swift
import Foundation

actor TaskService {
    private let apiKey: String
    private let baseURL: URL

    init(apiKey: String, baseURL: URL) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    private func request(path: String, method: String = "GET", body: Encodable? = nil) async throws -> (Data, URLResponse) {
        var url = baseURL
        url.append(path: path)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }

        return try await URLSession.shared.data(for: request)
    }

    func listTasks() async throws -> [Task] {
        let (data, _) = try await request(path: "/tasks")
        let response = try JSONDecoder().decode(TasksResponse.self, from: data)
        return response.tasks
    }

    func getTask(id: String) async throws -> Task {
        let (data, _) = try await request(path: "/task/\(id)")
        let response = try JSONDecoder().decode(TaskResponse.self, from: data)
        return response.task
    }

    func sendReply(taskId: String, text: String) async throws -> Task {
        let (data, _) = try await request(path: "/task/\(taskId)/reply", method: "POST", body: ReplyRequest(text: text))
        let response = try JSONDecoder().decode(TaskResponse.self, from: data)
        return response.task
    }

    func registerDevice(token: String) async throws {
        _ = try await request(path: "/register-device", method: "POST", body: DeviceTokenRequest(deviceToken: token))
    }
}

struct TasksResponse: Codable, Sendable {
    let ok: Bool
    let tasks: [Task]
}

struct TaskResponse: Codable, Sendable {
    let ok: Bool
    let task: Task
}
```

### 4. Keychain helper

Create `ios/tax/tax/Utils/Keychain.swift`:

```swift
import Security
import Foundation

enum Keychain {
    static func save(key: String, value: String) throws {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.saveFailed(status) }
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: Error {
    case saveFailed(OSStatus)
}
```

### 5. Settings store

Create `ios/tax/tax/Stores/SettingsStore.swift`:

```swift
import Foundation
import Observation

@Observable
final class SettingsStore {
    var apiKey: String
    var serverURL: String

    private let apiKeyKey = "tax.apiKey"
    private let serverURLKey = "tax.serverURL"
    private let defaults = UserDefaults.standard

    init() {
        apiKey = Keychain.load(key: apiKeyKey) ?? ""
        serverURL = defaults.string(forKey: serverURLKey) ?? "https://tax.138-249-127-23.nip.io"
    }

    func save() {
        try? Keychain.save(key: apiKeyKey, value: apiKey)
        defaults.set(serverURL, forKey: serverURLKey)
    }
}
```

### 6. App Delegate

Create `ios/tax/tax/App/AppDelegate.swift`:

```swift
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var taskService: TaskService?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                DispatchQueue.main.async { application.registerForRemoteNotifications() }
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        Task {
            try? await taskService?.registerDevice(token: token)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Failed to register: \(error)")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let taskId = userInfo["task_id"] as? String {
            NotificationCenter.default.post(name: .openTask, object: taskId)
        }
        completionHandler()
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        NotificationCenter.default.post(name: .refreshTasks, object: nil)
        completionHandler(.newData)
    }
}

extension Notification.Name {
    static let openTask = Notification.Name("tax.openTask")
    static let refreshTasks = Notification.Name("tax.refreshTasks")
}
```

### 7. SwiftUI App entry

Update `ios/tax/tax/taxApp.swift`:

```swift
import SwiftUI

@main
struct TaxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settingsStore = SettingsStore()
    @State private var taskService: TaskService?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settingsStore)
                .task {
                    appDelegate.taskService = await makeTaskService()
                }
        }
    }

    private func makeTaskService() async -> TaskService? {
        guard let url = URL(string: settingsStore.serverURL), !settingsStore.apiKey.isEmpty else { return nil }
        let service = TaskService(apiKey: settingsStore.apiKey, baseURL: url)
        appDelegate.taskService = service
        return service
    }
}
```

### 8. Views

Create the following files:

- `ios/tax/tax/Views/TaskListView.swift` — list of tasks, pull-to-refresh, navigation to detail
- `ios/tax/tax/Views/TaskDetailView.swift` — task details + reply button
- `ios/tax/tax/Views/ReplyView.swift` — text editor + submit reply
- `ios/tax/tax/Views/SettingsView.swift` — API key, server URL, device token display
- `ios/tax/tax/Views/ContentView.swift` — root tab view

Example `TaskListView.swift`:

```swift
import SwiftUI

struct TaskListView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var tasks: [Task] = []
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List(tasks) { task in
                NavigationLink(task.title, value: task.id)
            }
            .navigationTitle("Tasks")
            .refreshable { await load() }
            .task { await load() }
            .onReceive(NotificationCenter.default.publisher(for: .refreshTasks)) { _ in
                Task { await load() }
            }
            .navigationDestination(for: String.self) { id in
                TaskDetailView(taskId: id)
            }
            .overlay {
                if isLoading { ProgressView() }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "")
            })
        }
    }

    private func load() async {
        guard let url = URL(string: settings.serverURL), !settings.apiKey.isEmpty else {
            errorMessage = "Configure API key and server URL in Settings"
            return
        }
        isLoading = true
        defer { isLoading = false }
        let service = TaskService(apiKey: settings.apiKey, baseURL: url)
        do {
            tasks = try await service.listTasks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

### 9. Settings view

Example `SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var savedDeviceToken: String = ""

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server URL", text: settingsBind(\.serverURL))
            }
            Section("API Key") {
                SecureTextField("API Key", text: settingsBind(\.apiKey))
            }
            Section("Device Token") {
                Text(savedDeviceToken.isEmpty ? "Not registered yet" : savedDeviceToken)
                    .font(.caption)
                    .lineLimit(3)
            }
            Button("Save") {
                settings.save()
            }
        }
        .navigationTitle("Settings")
    }

    private func settingsBind(_ keyPath: ReferenceWritableKeyPath<SettingsStore, String>) -> Binding<String> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { settings[keyPath: keyPath] = $0 }
        )
    }
}
```

### 10. Testing plan

1. Build and run on a real iPhone
2. Enter API key and server URL in Settings, save
3. Allow push notifications
4. Verify device token appears on screen or in backend logs
5. From Mac run:

```bash
source ~/.zshrc
tax run --detach pi -p "hello from tax"
```

6. Expect a push notification on the iPhone
7. Tap the notification → open task detail
8. Type a reply → send
9. On Mac verify reply received:

```bash
tax status
```

## Common pitfalls

- Do not use `UserDefaults` for the API key; use Keychain
- `deviceToken` must be hex-encoded without spaces
- APNs does not work in the iOS Simulator; use a real device
- `background-execution.md` skill covers silent push handling
- `swift-concurrency-pro.md` covers `Sendable` and `MainActor` usage

## .gitignore notes

Ensure `.gitignore` ignores:

```
*.xcuserdata/
*.xcworkspace/
DerivedData/
Build/
*.ipa
*.dSYM
```
