import XCTest
@testable import tax

final class ModelTests: XCTestCase {
    func testDecodesEveryPushMode() throws {
        for mode in PushMode.allCases {
            let data = try JSONEncoder().encode(mode)
            XCTAssertEqual(try JSONDecoder().decode(PushMode.self, from: data), mode)
        }
    }

    func testPushModeTitlesAreEnglish() {
        XCTAssertEqual(PushMode.all.title, "All")
        XCTAssertEqual(PushMode.taxOnly.title, "Tax only")
        XCTAssertEqual(PushMode.off.title, "Off")
    }

    func testDeviceRegistrationUsesServerKeys() throws {
        let payload = DeviceTokenPayload(deviceToken: "token", preferences: DevicePreferences(pushMode: .taxOnly))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
        XCTAssertEqual(object["device_token"] as? String, "token")
        XCTAssertEqual((object["preferences"] as? [String: Any])?["push_mode"] as? String, "tax")
    }

    func testDecodesQuickCommandTypesFromHostPayload() throws {
        let executed = try JSONDecoder().decode(
            RemoteQuickCommand.self,
            from: Data(#"{"id":"qc-run","label":"Status","scope":"global","repo_id":null,"action":"terminal-command","command":"git status","append_enter":true,"agent":null,"prompt":null}"#.utf8)
        )
        XCTAssertEqual(executed.id, "qc-run")
        XCTAssertFalse(executed.isAgentPrompt)
        XCTAssertTrue(executed.appendsEnter)
        XCTAssertEqual(executed.kindSummary, "Terminal command")

        // appendEnter=false keeps the multi-line text verbatim for pasting.
        let pasted = try JSONDecoder().decode(
            RemoteQuickCommand.self,
            from: Data(#"{"id":"qc-paste","label":"Paste","scope":"repo","repo_id":"repo","action":"terminal-command","command":"echo one\necho two","append_enter":false,"agent":null,"prompt":null}"#.utf8)
        )
        XCTAssertEqual(pasted.command, "echo one\necho two")
        XCTAssertFalse(pasted.appendsEnter)
        XCTAssertEqual(pasted.kindSummary, "Terminal command · pasted without run")

        let agent = try JSONDecoder().decode(
            RemoteQuickCommand.self,
            from: Data(#"{"id":"qc-agent","label":"Review","scope":"repo","repo_id":"repo","action":"agent-prompt","command":null,"append_enter":true,"agent":"pi","prompt":"Review the diff"}"#.utf8)
        )
        XCTAssertTrue(agent.isAgentPrompt)
        XCTAssertEqual(agent.prompt, "Review the diff")
        XCTAssertEqual(agent.kindSummary, "Agent prompt · pi")
    }

    func testQuickCommandVisibilityFiltersByRepositoryKeepingOrcaOrder() {
        let workspace = RemoteWorkspace(
            id: "ws", projectID: "repo", projectName: "tax", path: "/workspace", branch: "main",
            displayName: "tax", terminalCount: 1, agentState: "active"
        )
        let commands = [
            RemoteQuickCommand(id: "a", label: "Global", scope: "global", repoID: nil, action: "terminal-command", command: "git status", appendEnter: nil, agent: nil, prompt: nil),
            RemoteQuickCommand(id: "b", label: "Other repo", scope: "repo", repoID: "other-repo", action: "terminal-command", command: "echo no", appendEnter: nil, agent: nil, prompt: nil),
            RemoteQuickCommand(id: "c", label: "This repo", scope: "repo", repoID: "repo", action: "agent-prompt", command: nil, appendEnter: nil, agent: "pi", prompt: "Review"),
        ]

        XCTAssertEqual(commands.visible(in: workspace).map(\.id), ["a", "c"])
        XCTAssertTrue(commands[0].applies(to: workspace))
        XCTAssertFalse(commands[1].applies(to: workspace))
        XCTAssertTrue(commands[2].applies(to: workspace))
    }
}
