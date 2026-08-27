import Foundation
import OSLog

protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { try await session.data(for: request) }
}

protocol DeviceRegistering: Sendable {
    func registerDevice(token: String, pushMode: PushMode) async throws
    func health() async throws -> Bool
}

actor DeviceRegistrationService: DeviceRegistering {
    private let baseURL: URL
    private let apiKey: String
    private let transport: any HTTPTransport
    private let logger = Logger(subsystem: "ru.madmaximuus.yandexmapstestapp.YandexMapsTestApp", category: "DeviceRegistration")

    init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.init(baseURL: baseURL, apiKey: apiKey, transport: URLSessionTransport(session: session))
    }

    init(baseURL: URL, apiKey: String, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.transport = transport
    }

    func registerDevice(token: String, pushMode: PushMode) async throws {
        let payload = DeviceTokenPayload(deviceToken: token, preferences: DevicePreferences(pushMode: pushMode))
        _ = try await request(path: "register-device", method: "POST", body: payload)
    }

    func health() async throws -> Bool {
        let data = try await request(path: "health")
        return try decode(HealthResponse.self, from: data).ok
    }

    private func request(path: String, method: String = "GET", body: (any Encodable)? = nil) async throws -> Data {
        let root = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(root)/\(path)") else { throw RemoteServiceError.invalidResponse }
        var request = URLRequest(url: url)
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
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError { throw RemoteServiceError.network(error.code) }
        catch { throw RemoteServiceError.network(nil) }
        guard let response = response as? HTTPURLResponse else { throw RemoteServiceError.invalidResponse }
        guard (200 ..< 300).contains(response.statusCode) else {
            let detail = Self.apiDetail(from: data)?.replacingOccurrences(of: apiKey, with: "[redacted]")
            logger.error("Registration request failed with HTTP \(response.statusCode)")
            throw RemoteServiceError.httpStatus(response.statusCode, detail)
        }
        guard !data.isEmpty else { throw RemoteServiceError.emptyResponse }
        return data
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw RemoteServiceError.invalidData }
    }

    private static func apiDetail(from data: Data) -> String? {
        struct ErrorResponse: Decodable { let detail: String }
        return try? JSONDecoder().decode(ErrorResponse.self, from: data).detail
    }
}

private struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void
    init(_ encodable: any Encodable) { encodeClosure = encodable.encode(to:) }
    func encode(to encoder: Encoder) throws { try encodeClosure(encoder) }
}

enum RemoteServiceError: LocalizedError, Equatable {
    case invalidResponse, emptyResponse, invalidData
    case network(URLError.Code?)
    case httpStatus(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid server response."
        case .emptyResponse: "The server returned an empty response."
        case .invalidData: "The server returned unexpected data."
        case let .network(code):
            code == .timedOut ? "The request timed out." : "The network request failed."
        case let .httpStatus(code, detail):
            detail.map { "Server returned HTTP \(code): \($0)" } ?? "Server returned HTTP \(code)."
        }
    }
}
