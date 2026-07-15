import Foundation
import OSLog

actor TaskService {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private let logger = Logger(subsystem: "ru.madmaximuus.yandexmapstestapp.YandexMapsTestApp", category: "TaskService")

    init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
        logger.info("TaskService initialized: baseURL=\(baseURL.absoluteString, privacy: .public), apiKey prefix=\(String(apiKey.prefix(8)), privacy: .public), length=\(apiKey.count)")
    }

    func fetchTasks() async throws -> [Task] {
        let data = try await data(path: "tasks")
        return try JSONDecoder().decode(TaskListResponse.self, from: data).tasks
    }

    func fetchTask(id: String) async throws -> Task {
        let data = try await data(path: "task/\(id)")
        return try JSONDecoder().decode(TaskResponse.self, from: data).task
    }

    func sendReply(taskID: String, text: String) async throws -> Task {
        let data = try await data(path: "task/\(taskID)/reply", method: "POST", body: ReplyPayload(text: text))
        return try JSONDecoder().decode(TaskResponse.self, from: data).task
    }

    func registerDevice(token: String) async throws {
        _ = try await data(path: "register-device", method: "POST", body: DeviceTokenPayload(deviceToken: token))
    }

    func health() async throws -> Bool {
        let data = try await data(path: "health")
        return try JSONDecoder().decode(HealthResponse.self, from: data).ok
    }

    private func data(path: String, method: String = "GET", body: (any Encodable)? = nil) async throws -> Data {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        let authHeader = "Bearer \(apiKey)"
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        logger.info("\(method) \(path) — Authorization prefix=\(String(authHeader.prefix(16)), privacy: .public), apiKey length=\(apiKey.count)")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response for \(path)")
            throw TaskServiceError.invalidResponse
        }
        let responseBody = String(data: data, encoding: .utf8) ?? "<empty>"
        logger.info("\(method) \(path) — status=\(httpResponse.statusCode), body=\(responseBody, privacy: .public)")
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TaskServiceError.httpStatus(httpResponse.statusCode, responseBody)
        }
        return data
    }

    private func url(for path: String) -> URL {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return baseURL.appending(path: cleanPath)
    }
}

private struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void

    init(_ encodable: any Encodable) {
        encodeClosure = encodable.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}

enum TaskServiceError: LocalizedError {
    case invalidResponse
    case httpStatus(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid server response."
        case let .httpStatus(code, message):
            if let message, !message.isEmpty {
                "Server returned HTTP \(code): \(message)"
            } else {
                "Server returned HTTP \(code)."
            }
        }
    }
}
