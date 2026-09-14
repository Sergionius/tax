import XCTest
@testable import tax

final class DeviceRegistrationServiceTests: XCTestCase {
    private let baseURL = URL(string: "https://example.test")!

    func testRegistersDeviceWithoutTaskContent() async throws {
        let transport = RecordingTransport([.response(status: 200, data: Data("{}".utf8))])
        let service = DeviceRegistrationService(baseURL: baseURL, apiKey: "secret", transport: transport)
        try await service.registerDevice(token: "device", pushMode: .taxOnly)

        let request = await transport.request()
        XCTAssertEqual(request.url?.path, "/register-device")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["device_token"] as? String, "device")
    }

    func testHealthAndRedactedHTTPError() async throws {
        let transport = RecordingTransport([
            .response(status: 200, data: Data(#"{"ok":true}"#.utf8)),
            .response(status: 401, data: Data(#"{"detail":"bad secret"}"#.utf8))
        ])
        let service = DeviceRegistrationService(baseURL: baseURL, apiKey: "secret", transport: transport)
        let healthy = try await service.health()
        XCTAssertTrue(healthy)
        do {
            _ = try await service.health()
            XCTFail("Expected HTTP error")
        } catch let error as RemoteServiceError {
            guard case let .httpStatus(code, detail) = error else { return XCTFail("Wrong error") }
            XCTAssertEqual(code, 401)
            XCTAssertEqual(detail, "bad [redacted]")
        }
    }

    func testMapsTransportFailure() async {
        let transport = RecordingTransport([.failure(URLError(.timedOut))])
        let service = DeviceRegistrationService(baseURL: baseURL, apiKey: "secret", transport: transport)
        do {
            _ = try await service.health()
            XCTFail("Expected failure")
        } catch let error as RemoteServiceError {
            XCTAssertEqual(error, .network(.timedOut))
        } catch { XCTFail("Unexpected error: \(error)") }
    }
}
