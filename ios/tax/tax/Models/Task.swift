import Foundation

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

struct DeviceTokenPayload: Codable, Sendable {
    let deviceToken: String

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
    }
}

struct HealthResponse: Codable, Sendable {
    let ok: Bool
}
