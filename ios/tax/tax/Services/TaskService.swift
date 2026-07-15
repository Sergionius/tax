import Foundation

actor TaskService {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TaskServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw TaskServiceError.httpStatus(httpResponse.statusCode, message)
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
