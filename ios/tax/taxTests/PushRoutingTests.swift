import XCTest
@testable import tax

@MainActor
final class PushRoutingTests: XCTestCase {
    private let router = PushRouter()

    func testRoutesHostWorkspaceAndTerminal() {
        XCTAssertEqual(
            router.destination(from: ["host_id": "mac-main", "workspace_id": "worktree-1", "terminal_id": "term-1"]),
            RemoteDeepLink(hostID: "mac-main", workspaceID: "worktree-1", terminalID: "term-1")
        )
        XCTAssertEqual(
            router.destination(from: ["remote": ["host_id": "mac-main", "workspace_id": "worktree-1"]]),
            RemoteDeepLink(hostID: "mac-main", workspaceID: "worktree-1", terminalID: nil)
        )
    }

    func testRejectsLegacyTaskAndTerminalWithoutWorkspace() {
        XCTAssertNil(router.destination(from: ["task_id": "task-42"]))
        XCTAssertNil(router.destination(from: ["host_id": "mac-main", "terminal_id": "term-1"]))
    }

    func testPendingDestinationSurvivesUntilConsumed() {
        let suite = "PushRoutingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pending = PendingRemoteDestinationStore(defaults: defaults)
        let destination = RemoteDeepLink(hostID: "mac", workspaceID: "workspace", terminalID: "terminal")
        XCTAssertTrue(pending.save(destination))
        XCTAssertFalse(pending.save(destination))
        XCTAssertEqual(pending.consume(), destination)
        XCTAssertNil(pending.consume())
    }

    func testAppStateReplacesRouteForHostDestination() {
        let state = AppState()
        let destination = RemoteDeepLink(hostID: "mac", workspaceID: nil, terminalID: nil)
        state.open(destination)
        XCTAssertEqual(state.pendingDestination, destination)
        XCTAssertTrue(state.navigationPath.isEmpty)
        state.finishRouting()
        XCTAssertNil(state.pendingDestination)
    }
}
