import Foundation
import OSLog

protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

protocol TaskServing: Sendable {
    func fetchTasks() async throws -> [Task]
    func fetchTask(id: String) async throws -> Task
    func sendReply(taskID: String, text: String) async throws -> Task
    func registerDevice(token: String, pushMode: PushMode) async throws
    func health() async throws -> Bool
}

actor TaskService: TaskServing {
    private let baseURL: URL
    private let apiKey: String
    private let transport: any HTTPTransport
    private let logger = Logger(subsystem: "ru.madmaximuus.yandexmapstestapp.YandexMapsTestApp", category: "TaskService")

    init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.init(baseURL: baseURL, apiKey: apiKey, transport: URLSessionTransport(session: session))
    }

    init(baseURL: URL, apiKey: String, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.transport = transport
        logger.info("TaskService initialized: baseURL=\(baseURL.absoluteString, privacy: .public), apiKeyPresent=\(!apiKey.isEmpty), apiKeyLength=\(apiKey.count)")
    }

    func fetchTasks() async throws -> [Task] {
        let data = try await request(pathComponents: ["tasks"])
        return try decode(TaskListResponse.self, from: data).tasks
    }

    func fetchTask(id: String) async throws -> Task {
        let data = try await request(pathComponents: ["task", id])
        return try decode(TaskResponse.self, from: data).task
    }

    func sendReply(taskID: String, text: String) async throws -> Task {
        let data = try await request(
            pathComponents: ["task", taskID, "reply"],
            method: "POST",
            body: ReplyPayload(text: text)
        )
        return try decode(TaskResponse.self, from: data).task
    }

    func registerDevice(token: String, pushMode: PushMode) async throws {
        let payload = DeviceTokenPayload(
            deviceToken: token,
            preferences: DevicePreferences(pushMode: pushMode)
        )
        _ = try await request(pathComponents: ["register-device"], method: "POST", body: payload)
    }

    func health() async throws -> Bool {
        let data = try await request(pathComponents: ["health"])
        return try decode(HealthResponse.self, from: data).ok
    }

    private func request(
        pathComponents: [String],
        method: String = "GET",
        body: (any Encodable)? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url(for: pathComponents))
        request.timeoutInterval = 15
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw TaskServiceError.network(error.code)
        } catch {
            throw TaskServiceError.network(nil)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid server response")
            throw TaskServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            logger.error("Request failed with HTTP \(httpResponse.statusCode)")
            let detail = Self.apiDetail(from: data)
            let safeDetail = apiKey.isEmpty ? detail : detail?.replacingOccurrences(of: apiKey, with: "[redacted]")
            throw TaskServiceError.httpStatus(httpResponse.statusCode, safeDetail)
        }
        guard !data.isEmpty else {
            throw TaskServiceError.emptyResponse
        }
        return data
    }

    private func url(for pathComponents: [String]) -> URL {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedPath = pathComponents
            .map { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
            .joined(separator: "/")
        let root = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(root)/\(encodedPath)") ?? baseURL
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw TaskServiceError.invalidData
        }
    }

    private static func apiDetail(from data: Data) -> String? {
        struct ErrorResponse: Decodable { let detail: String }
        return try? JSONDecoder().decode(ErrorResponse.self, from: data).detail
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

enum TaskServiceError: LocalizedError, Equatable {
    case invalidResponse
    case emptyResponse
    case invalidData
    case network(URLError.Code?)
    case httpStatus(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid server response."
        case .emptyResponse:
            "The server returned an empty response."
        case .invalidData:
            "The server returned data in an unexpected format."
        case let .network(code):
            switch code {
            case .timedOut: "The request timed out. Try again."
            case .notConnectedToInternet, .networkConnectionLost: "No network connection. Try again when you are online."
            default: "The network request failed. Try again."
            }
        case let .httpStatus(code, detail):
            switch code {
            case 401: "Authentication failed. Check the API key."
            case 404: "The requested task was not found."
            case 422: "The server rejected the request."
            case 500...599: "The server is temporarily unavailable."
            default:
                if let detail, !detail.isEmpty, detail.count <= 200 {
                    "Server returned HTTP \(code): \(detail)"
                } else {
                    "Server returned HTTP \(code)."
                }
            }
        }
    }
}
