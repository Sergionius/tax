import XCTest
@testable import tax

@MainActor
final class PushRoutingTests: XCTestCase {
    private let router = PushRouter()

    func testValidTaskIDOpensExpectedTask() {
        XCTAssertEqual(router.action(from: ["task_id": "task-42"]), .openTask("task-42"))
        XCTAssertEqual(router.action(from: ["taskId": "task-43"]), .openTask("task-43"))
        XCTAssertEqual(router.action(from: ["aps": ["task_id": "task-44"]]), .openTask("task-44"))
    }

    func testMissingTaskIDDoesNothing() {
        XCTAssertEqual(router.action(from: ["aps": ["alert": "hello"]]), .none)
    }

    func testReplyActionCarriesTextToCorrectTask() {
        XCTAssertEqual(
            router.action(from: ["task_id": "task-9"], actionIdentifier: "REPLY", replyText: " answer "),
            .reply(taskID: "task-9", text: " answer ")
        )
        XCTAssertEqual(
            router.action(from: ["task_id": "task-9"], actionIdentifier: "REPLY", replyText: "  "),
            .openTask("task-9")
        )
    }

    func testPendingPushSurvivesUntilUIConsumesIt() {
        let suite = "PendingTaskStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PendingTaskStore(defaults: defaults)

        XCTAssertTrue(store.save("task-before-ui"))
        XCTAssertEqual(store.consume(), "task-before-ui")
        XCTAssertNil(store.consume())
    }

    func testDuplicatePendingAndNavigationRoutesAreIgnored() {
        let suite = "PendingTaskStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pending = PendingTaskStore(defaults: defaults)
        XCTAssertTrue(pending.save("same-task"))
        XCTAssertFalse(pending.save("same-task"))

        let state = AppState()
        state.openTask(id: "same-task")
        state.openTask(id: "same-task")
        XCTAssertEqual(state.navigationPath, ["same-task"])
    }

    func testForegroundRefreshChangesRefreshToken() {
        let state = AppState()
        let oldToken = state.refreshToken
        state.requestRefresh()
        XCTAssertNotEqual(state.refreshToken, oldToken)
    }
}
