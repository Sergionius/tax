import Foundation
@testable import tax

actor RecordingTransport: HTTPTransport {
    enum Stub: @unchecked Sendable {
        case response(status: Int, data: Data)
        case failure(URLError)
        case invalidResponse(Data)
    }

    private var stubs: [Stub]
    private(set) var requests: [URLRequest] = []

    init(_ stubs: [Stub]) { self.stubs = stubs }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !stubs.isEmpty else { throw URLError(.badServerResponse) }
        switch stubs.removeFirst() {
        case let .response(status, data):
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case let .failure(error): throw error
        case let .invalidResponse(data):
            return (data, URLResponse(url: request.url!, mimeType: nil, expectedContentLength: data.count, textEncodingName: nil))
        }
    }

    func request(at index: Int = 0) -> URLRequest { requests[index] }
}

actor ServiceStub: DeviceRegistering {
    private(set) var registrations: [(String, PushMode)] = []
    func registerDevice(token: String, pushMode: PushMode) async throws { registrations.append((token, pushMode)) }
    func health() async throws -> Bool { true }
}
