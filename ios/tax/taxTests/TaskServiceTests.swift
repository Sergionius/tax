import XCTest
@testable import tax

final class TaskServiceTests: XCTestCase {
    private let baseURL = URL(string: "https://example.test/api")!
    private let apiKey = "super-secret-key"

    func testFetchTasksRequest() async throws {
        let data = try JSONEncoder().encode(TaskListResponse(ok: true, tasks: [makeTask()]))
        let (service, transport) = makeService(.response(status: 200, data: data))
        let tasks = try await service.fetchTasks()
        XCTAssertEqual(tasks.map(\.id), ["task-1"])
        try await assertRequest(transport, method: "GET", path: "/api/tasks")
    }

    func testFetchTaskSafelyEncodesTaskID() async throws {
        let (service, transport) = makeService(.response(status: 200, data: try taskResponseData()))
        _ = try await service.fetchTask(id: "a/b ?")
        try await assertRequest(transport, method: "GET", path: "/api/task/a%2Fb%20%3F")
    }

    func testSendReplyRequest() async throws {
        let (service, transport) = makeService(.response(status: 200, data: try taskResponseData()))
        _ = try await service.sendReply(taskID: "task-1", text: "hello")
        let request = await transport.request()
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/task/task-1/reply")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: body) as? [String: String])?["text"], "hello")
    }

    func testRegisterDeviceRequest() async throws {
        let (service, transport) = makeService(.response(status: 200, data: Data("{\"ok\":true}".utf8)))
        try await service.registerDevice(token: "token", pushMode: .off)
        let request = await transport.request()
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/register-device")
        let body = try XCTUnwrap(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(object?["device_token"] as? String, "token")
        XCTAssertEqual((object?["preferences"] as? [String: String])?["push_mode"], "off")
    }

    func testHealthRequest() async throws {
        let (service, transport) = makeService(.response(status: 200, data: Data("{\"ok\":true,\"database\":\"ok\"}".utf8)))
        let isHealthy = try await service.health()
        XCTAssertTrue(isHealthy)
        try await assertRequest(transport, method: "GET", path: "/api/health")
    }

    func testMapsHTTPFailuresWithoutExposingAPIKey() async {
        for code in [401, 404, 409, 422, 500] {
            let body = Data("{\"detail\":\"failure super-secret-key\"}".utf8)
            let (service, _) = makeService(.response(status: code, data: body))
            do {
                _ = try await service.fetchTasks()
                XCTFail("Expected HTTP \(code)")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains(apiKey))
                XCTAssertTrue(error is TaskServiceError)
            }
        }
    }

    func testInvalidJSON() async {
        let (service, _) = makeService(.response(status: 200, data: Data("not-json".utf8)))
        await assertServiceError(.invalidData) { try await service.fetchTasks() }
    }

    func testEmptyResponse() async {
        let (service, _) = makeService(.response(status: 200, data: Data()))
        await assertServiceError(.emptyResponse) { try await service.fetchTasks() }
    }

    func testInvalidURLResponse() async {
        let (service, _) = makeService(.invalidResponse(Data("{}".utf8)))
        await assertServiceError(.invalidResponse) { try await service.fetchTasks() }
    }

    func testTimeoutAndOfflineErrorsAreUserFriendly() async {
        for code in [URLError.Code.timedOut, .notConnectedToInternet] {
            let (service, _) = makeService(.failure(URLError(code)))
            do {
                _ = try await service.fetchTasks()
                XCTFail("Expected network error")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains(apiKey))
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
    }

    private func makeService(_ stub: RecordingTransport.Stub) -> (TaskService, RecordingTransport) {
        let transport = RecordingTransport([stub])
        return (TaskService(baseURL: baseURL, apiKey: apiKey, transport: transport), transport)
    }

    private func assertRequest(
        _ transport: RecordingTransport,
        method: String,
        path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let request = await transport.request()
        XCTAssertEqual(request.httpMethod, method, file: file, line: line)
        XCTAssertEqual(request.url?.path(percentEncoded: true), path, file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(apiKey)", file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json", file: file, line: line)
    }

    private func assertServiceError<T>(
        _ expected: TaskServiceError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as TaskServiceError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
