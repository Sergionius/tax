import Foundation

enum PushMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case all
    case taxOnly = "tax"
    case off

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "Все"
        case .taxOnly: "Только tax"
        case .off: "Выключены"
        }
    }
}

struct Task: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let deviceToken: String?
    let title: String
    let body: String
    var status: String
    let context: String?
    let logs: String?
    let reply: String?
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case deviceToken = "device_token"
        case title
        case body
        case status
        case context
        case logs
        case reply
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: String,
        deviceToken: String?,
        title: String,
        body: String,
        status: String,
        context: String?,
        logs: String?,
        reply: String?,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.deviceToken = deviceToken
        self.title = title
        self.body = body
        self.status = status
        self.context = context
        self.logs = logs
        self.reply = reply
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        deviceToken = try container.decodeIfPresent(String.self, forKey: .deviceToken)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Task"
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        context = try container.decodeIfPresent(String.self, forKey: .context)
        logs = try container.decodeIfPresent(String.self, forKey: .logs)
        reply = try container.decodeIfPresent(String.self, forKey: .reply)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

enum TaskStatusKind: Sendable, Equatable {
    case pending
    case success
    case failure
    case unknown
}

extension Task {
    var displayCreatedAt: String {
        Self.displayDate(from: createdAt)
    }

    var displayUpdatedAt: String {
        Self.displayDate(from: updatedAt)
    }

    var displayStatus: String {
        status.isEmpty ? "unknown" : status
    }

    var statusKind: TaskStatusKind {
        switch status.lowercased() {
        case "replied", "done", "completed", "delivered": .success
        case "failed", "error", "delivery_failed": .failure
        case "pending", "new": .pending
        default: .unknown
        }
    }

    static func displayDate(from value: String, timeZone: TimeZone = .current) -> String {
        guard !value.isEmpty else { return value }

        if let date = parseDate(value) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.timeZone = timeZone
            formatter.dateFormat = "HH:mm:ss dd:MM:yyyy"
            return formatter.string(from: date)
        }

        return value
    }

    private static func parseDate(_ value: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = isoFormatter.date(from: value) {
            return date
        }

        isoFormatter.formatOptions = [.withInternetDateTime]
        return isoFormatter.date(from: value)
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

struct ReplyPayload: Codable, Sendable {
    let text: String
}

struct DevicePreferences: Codable, Sendable {
    let pushMode: PushMode

    enum CodingKeys: String, CodingKey {
        case pushMode = "push_mode"
    }
}

struct DeviceTokenPayload: Codable, Sendable {
    let deviceToken: String
    let preferences: DevicePreferences

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case preferences
    }
}

struct HealthResponse: Codable, Sendable {
    let ok: Bool
}
