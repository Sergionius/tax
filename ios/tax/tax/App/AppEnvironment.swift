import Foundation

@MainActor
enum AppEnvironment {
    static let arguments = ProcessInfo.processInfo.arguments
    static var isUITesting: Bool { arguments.contains("--ui-testing") }

    static func makeSettingsStore() -> SettingsStore {
        guard isUITesting else { return SettingsStore() }
        let shouldFail = arguments.contains("--mock-network-error")
        let shouldFailReply = arguments.contains("--mock-reply-error")
        let preconfigured = arguments.contains("--mock-configured") || shouldFail || shouldFailReply || mockTaskID != nil
        let preferences = MemoryPreferencesStore(values: [
            "tax.serverURL": argument(after: "--mock-server-url") ?? "https://tax.138-249-127-23.nip.io",
            "tax.hostID": argument(after: "--mock-host-id") ?? "mac-main",
            "tax.remoteDeviceID": argument(after: "--mock-device-id") ?? "iphone-main"
        ])
        return SettingsStore(
            preferences: preferences,
            keychain: MemoryKeychainStore(
                apiKey: preconfigured ? (argument(after: "--mock-api-key") ?? "ui-test-key") : nil,
                e2eeKey: argument(after: "--mock-e2ee-key")
            ),
            serviceFactory: { _, _ in MockTaskService(shouldFail: shouldFail, shouldFailReply: shouldFailReply) }
        )
    }

    static var mockTaskID: String? { argument(after: "--mock-task-id") }

    private static func argument(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

@MainActor
private final class MemoryPreferencesStore: PreferencesStoring {
    private var values: [String: String]

    init(values: [String: String] = [:]) { self.values = values }

    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
}

@MainActor
private final class MemoryKeychainStore: KeychainStoring {
    private var values: [String: String]

    init(apiKey: String? = nil, e2eeKey: String? = nil) {
        values = [:]
        values["tax.apiKey"] = apiKey
        values["tax.remoteE2EEKey"] = e2eeKey
    }

    func save(key: String, value: String) throws { values[key] = value }
    func load(key: String) throws -> String? { values[key] }
    func delete(key: String) throws { values[key] = nil }
}

private actor MockTaskService: TaskServing {
    private let shouldFail: Bool
    private let shouldFailReply: Bool
    private var tasks: [Task]

    init(shouldFail: Bool, shouldFailReply: Bool) {
        self.shouldFail = shouldFail
        self.shouldFailReply = shouldFailReply
        tasks = [
            Task(
                id: "mock-task-1",
                deviceToken: nil,
                title: "Mock tax task",
                body: "Review the generated tax report.",
                status: "pending",
                context: "UI test context",
                logs: "UI test logs",
                reply: nil,
                createdAt: "2026-07-28T08:00:00Z",
                updatedAt: "2026-07-28T08:00:00Z"
            )
        ]
    }

    func fetchTasks() throws -> [Task] {
        try failIfNeeded()
        return tasks
    }

    func fetchTask(id: String) throws -> Task {
        try failIfNeeded()
        guard let task = tasks.first(where: { $0.id == id }) else { throw TaskServiceError.httpStatus(404, nil) }
        return task
    }

    func sendReply(taskID: String, text: String) throws -> Task {
        if shouldFailReply { throw TaskServiceError.network(.networkConnectionLost) }
        try failIfNeeded()
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { throw TaskServiceError.httpStatus(404, nil) }
        let old = tasks[index]
        let updated = Task(
            id: old.id,
            deviceToken: old.deviceToken,
            title: old.title,
            body: old.body,
            status: "replied",
            context: old.context,
            logs: old.logs,
            reply: text,
            createdAt: old.createdAt,
            updatedAt: "2026-07-28T09:00:00Z"
        )
        tasks[index] = updated
        return updated
    }

    func registerDevice(token: String, pushMode: PushMode) throws {
        try failIfNeeded()
    }

    func health() throws -> Bool {
        try failIfNeeded()
        return true
    }

    private func failIfNeeded() throws {
        if shouldFail { throw TaskServiceError.network(.notConnectedToInternet) }
    }
}
