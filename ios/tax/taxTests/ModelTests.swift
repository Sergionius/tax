import XCTest
@testable import tax

final class ModelTests: XCTestCase {
    func testDecodesFullBackendFixture() throws {
        let response = try JSONDecoder().decode(TaskResponse.self, from: fixture("task-full"))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.task.id, "task-123")
        XCTAssertEqual(response.task.deviceToken, "abc123")
        XCTAssertEqual(response.task.context, "trusted context")
        XCTAssertEqual(response.task.logs, "agent logs")
        XCTAssertEqual(response.task.reply, "Looks good")
    }

    func testDecodesNullableFieldsAndUnknownStatus() throws {
        let response = try JSONDecoder().decode(TaskListResponse.self, from: fixture("tasks-nullable"))
        let task = try XCTUnwrap(response.tasks.first)
        XCTAssertNil(task.deviceToken)
        XCTAssertNil(task.context)
        XCTAssertNil(task.logs)
        XCTAssertNil(task.reply)
        XCTAssertEqual(task.displayStatus, "future_status")
        XCTAssertEqual(task.statusKind, .unknown)
    }

    func testDecodesEveryPushMode() throws {
        for rawValue in ["all", "tax", "off"] {
            let data = Data("\"\(rawValue)\"".utf8)
            XCTAssertNoThrow(try JSONDecoder().decode(PushMode.self, from: data))
        }
    }

    func testDateFormattingIsStableAndInvalidDateFallsBack() {
        let utc = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(Task.displayDate(from: "2026-07-28T08:30:45.123Z", timeZone: utc), "08:30:45 28:07:2026")
        XCTAssertEqual(Task.displayDate(from: "not-a-date", timeZone: utc), "not-a-date")
    }

    func testStatusKinds() {
        XCTAssertEqual(makeTask(status: "pending").statusKind, .pending)
        XCTAssertEqual(makeTask(status: "delivered").statusKind, .success)
        XCTAssertEqual(makeTask(status: "delivery_failed").statusKind, .failure)
        XCTAssertEqual(makeTask(status: "new-backend-status").statusKind, .unknown)
    }

    func testEncodesReplyAndDeviceTokenPayloads() throws {
        let encoder = JSONEncoder()
        let reply = try JSONSerialization.jsonObject(with: encoder.encode(ReplyPayload(text: "hello"))) as? [String: String]
        XCTAssertEqual(reply?["text"], "hello")

        let data = try encoder.encode(DeviceTokenPayload(
            deviceToken: "abc",
            preferences: DevicePreferences(pushMode: .taxOnly)
        ))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["device_token"] as? String, "abc")
        XCTAssertEqual((object?["preferences"] as? [String: String])?["push_mode"], "tax")
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
