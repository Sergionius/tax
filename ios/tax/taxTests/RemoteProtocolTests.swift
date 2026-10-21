import Foundation
import Testing
@testable import tax

@MainActor
private final class MockTerminalSurface: TerminalRendererSurface {
    private(set) var appliedUpdates: [TerminalRenderUpdate] = []
    private var pendingCompletions: [(@MainActor () -> Void)?] = []

    func apply(update: TerminalRenderUpdate, completion: (@MainActor () -> Void)?) {
        appliedUpdates.append(update)
        pendingCompletions.append(completion)
    }

    func complete(at index: Int) {
        guard pendingCompletions.indices.contains(index) else { return }
        let completion = pendingCompletions[index]
        pendingCompletions[index] = nil
        completion?()
    }

    func requestFocus() {}
}

struct RemoteProtocolTests {
    @Test func cryptoMatchesPythonContractFixture() throws {
        let secret = Data(base64Encoded: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")!
        let sessionID = Data(base64Encoded: "AAECAwQFBgcICQoLDA0ODw==")!
        let salt = Data(base64Encoded: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=")!
        let session = try RemoteCryptoSession(secret: secret, hostID: "mac", deviceID: "phone", sessionID: sessionID, salt: salt)

        let encrypted = try session.encrypt(channel: 1, plaintext: Data("hello".utf8))
        #expect(encrypted.base64EncodedString() == "AQEAAAAAAAAAAHsQ2uO95kMq2fPCu3n5MHwVQM0Rpg==")

        let hostFrame = Data(base64Encoded: "AQEAAAAAAAAAAP5DcaO4tdwqQGPIXbld2wZcRMh56A==")!
        let (channel, plaintext) = try session.decrypt(hostFrame)
        #expect(channel == 1)
        #expect(String(decoding: plaintext, as: UTF8.self) == "world")
        #expect(throws: (any Error).self) { try session.decrypt(hostFrame) }
    }

    @Test func fileEntryAndDocumentTrackRemoteRevisionAndLocalChanges() throws {
        let encoded = Data(#"{"name":"README.md","path":"docs/README.md","is_directory":false,"size":12}"#.utf8)
        let entry = try JSONDecoder().decode(RemoteFileEntry.self, from: encoded)
        #expect(entry.id == "docs/README.md")
        #expect(!entry.isDirectory)
        #expect(entry.size == 12)

        let original = Data("first".utf8)
        var document = RemoteFileDocument(
            workspaceID: "workspace", path: entry.path, kind: "text", data: original, revision: "abc", savedData: original
        )
        #expect(!document.isModified)
        document.data = Data("second".utf8)
        #expect(document.isModified)
        #expect(document.text == "second")
    }

    @Test func clientTerminalFrameRoundTripsBinaryInput() throws {
        let frame = RemoteTerminalFrame(
            opcode: .input,
            streamID: 7,
            generation: 3,
            sequence: 42,
            payload: Data("echo fast".utf8)
        )
        let decoded = try RemoteTerminalFrame(data: frame.encoded())
        #expect(decoded.opcode == .input)
        #expect(decoded.streamID == 7)
        #expect(decoded.generation == 3)
        #expect(decoded.sequence == 42)
        #expect(decoded.payload == Data("echo fast".utf8))
    }

    @Test func terminalFrameRejectsWrongVersionAndDecodesHeader() throws {
        var frame = Data([1, 2, 0, 0])
        frame.append(contentsOf: [0, 0, 0, 7])
        frame.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 3])
        frame.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 42])
        frame.append(Data("ansi".utf8))

        let decoded = try RemoteTerminalFrame(data: frame)
        #expect(decoded.opcode == .output)
        #expect(decoded.streamID == 7)
        #expect(decoded.generation == 3)
        #expect(decoded.sequence == 42)
        #expect(decoded.payload == Data("ansi".utf8))

        frame[0] = 2
        #expect(throws: RemoteClientError.self) { try RemoteTerminalFrame(data: frame) }
    }

    @Test func pipelineDoesNotApplySnapshotBeforeRendererReadiness() {
        let surface = MockTerminalSurface()
        let pipeline = TerminalRenderPipeline()
        pipeline.surface = surface

        pipeline.enqueue(TerminalRenderUpdate(sequence: 1, resetsTerminal: true, data: Data("snapshot".utf8)))
        #expect(pipeline.snapshotReceived)
        #expect(!pipeline.snapshotApplied)
        #expect(surface.appliedUpdates.isEmpty)

        pipeline.rendererDidBecomeReady(viewport: TerminalRendererViewport(columns: 80, rows: 25))
        #expect(surface.appliedUpdates.count == 1)
    }

    @Test func pipelineDropsStaleSequenceUpdates() {
        let surface = MockTerminalSurface()
        let pipeline = TerminalRenderPipeline()
        pipeline.surface = surface

        let first = TerminalRenderUpdate(sequence: 1, resetsTerminal: true, data: Data("first".utf8))
        let stale = TerminalRenderUpdate(sequence: 1, resetsTerminal: false, data: Data("stale".utf8))
        pipeline.enqueue(first)
        pipeline.rendererDidBecomeReady(viewport: TerminalRendererViewport(columns: 80, rows: 25))

        #expect(surface.appliedUpdates.count == 1)
        pipeline.enqueue(stale)
        #expect(surface.appliedUpdates.count == 1)
    }

    @Test func pipelineReplacesPendingSnapshotWithNewerOne() {
        let surface = MockTerminalSurface()
        let pipeline = TerminalRenderPipeline()
        pipeline.surface = surface

        let first = TerminalRenderUpdate(sequence: 1, generation: 10, resetsTerminal: true, data: Data("first".utf8))
        let second = TerminalRenderUpdate(sequence: 2, generation: 11, resetsTerminal: true, data: Data("second".utf8))
        pipeline.enqueue(first)
        pipeline.enqueue(second)
        pipeline.rendererDidBecomeReady(viewport: TerminalRendererViewport(columns: 80, rows: 25))

        #expect(surface.appliedUpdates.count == 1)
        #expect(surface.appliedUpdates.first?.data == Data("second".utf8))
    }

    @Test func pipelinePreservesOutputOrderDuringSnapshotApplication() {
        let surface = MockTerminalSurface()
        let pipeline = TerminalRenderPipeline()
        pipeline.surface = surface
        pipeline.rendererDidBecomeReady(viewport: TerminalRendererViewport(columns: 80, rows: 25))

        let snapshot = TerminalRenderUpdate(sequence: 1, resetsTerminal: true, data: Data("snapshot".utf8))
        let outputA = TerminalRenderUpdate(sequence: 2, resetsTerminal: false, data: Data("a".utf8))
        let outputB = TerminalRenderUpdate(sequence: 3, resetsTerminal: false, data: Data("b".utf8))

        var snapshotApplied = false
        pipeline.onSnapshotApplied = { snapshotApplied = true }

        pipeline.enqueue(snapshot)
        #expect(surface.appliedUpdates.count == 1)
        #expect(!snapshotApplied)

        pipeline.enqueue(outputA)
        pipeline.enqueue(outputB)
        #expect(surface.appliedUpdates.count == 1)

        surface.complete(at: 0)
        #expect(snapshotApplied)
        #expect(surface.appliedUpdates.count == 2)
        #expect(surface.appliedUpdates[1].data == Data("ab".utf8))
        #expect(!surface.appliedUpdates[1].resetsTerminal)
        #expect(pipeline.snapshotApplied)
    }

    @Test func pipelineSuppressesDuplicateViewportChanges() async throws {
        let surface = MockTerminalSurface()
        let pipeline = TerminalRenderPipeline()
        pipeline.surface = surface
        var changes = [TerminalRendererViewport]()
        pipeline.onViewportReady = { _ in }
        pipeline.onViewportChanged = { changes.append($0) }
        pipeline.rendererDidBecomeReady(viewport: TerminalRendererViewport(columns: 80, rows: 25))
        pipeline.rendererViewportDidChange(TerminalRendererViewport(columns: 100, rows: 30))
        pipeline.rendererViewportDidChange(TerminalRendererViewport(columns: 100, rows: 30))
        try await Swift.Task.sleep(for: .milliseconds(250))
        #expect(changes == [TerminalRendererViewport(columns: 100, rows: 30)])
    }

    @MainActor
    @Test func quickCommandListResultRoutesPerWorkspaceInOrcaOrder() {
        let store = RemoteWorkspaceStore()
        store.pendingQuickCommandListID = "op-list"
        store.apply(Self.message(
            type: "operation.result",
            operationID: "op-list",
            payload: ["workspace_id": .string("ws"), "commands": Self.commandObjects()]
        ))

        #expect(store.quickCommands["ws"]?.map(\.id) == ["qc-run", "qc-other", "qc-paste"])
        #expect(!store.isLoadingQuickCommands)
        #expect(store.quickCommandError == nil)

        // Filtering keeps the Orca order and hides other repositories' commands.
        let workspace = Self.workspace(projectID: "repo")
        #expect(store.quickCommands["ws"]?.visible(in: workspace).map(\.id) == ["qc-run", "qc-paste"])
    }

    @MainActor
    @Test func staleQuickCommandListResultCannotReplaceCurrentHostCommands() {
        let store = RemoteWorkspaceStore()
        store.pendingQuickCommandListID = "new-list"
        store.isLoadingQuickCommands = true
        store.apply(Self.message(
            type: "operation.result", operationID: "old-list",
            payload: ["workspace_id": .string("ws"), "commands": Self.commandObjects()]
        ))
        #expect(store.quickCommands.isEmpty)
        #expect(store.isLoadingQuickCommands)
        #expect(store.pendingQuickCommandListID == "new-list")
    }

    @MainActor
    @Test func quickCommandListFailureShowsMessageWithLoadingCleared() {
        let store = RemoteWorkspaceStore()
        store.pendingQuickCommandListID = "op-list"
        store.isLoadingQuickCommands = true
        store.apply(Self.message(
            type: "protocol.error",
            operationID: "op-list",
            payload: ["ok": .bool(false), "code": .string("invalid_runtime_response"), "message": .string("Orca returned an unexpected Quick Commands response")]
        ))

        #expect(store.quickCommandError == "Orca returned an unexpected Quick Commands response")
        #expect(!store.isLoadingQuickCommands)
        #expect(store.quickCommands.isEmpty)
    }

    @MainActor
    @Test func quickCommandRunResultOpensTerminalAfterHostHandlesPaste() {
        let store = RemoteWorkspaceStore()
        store.pendingQuickCommandRun = PendingQuickCommandRun(operationID: "op-1")
        store.runningQuickCommandID = "qc-paste"
        store.apply(Self.message(
            type: "operation.result",
            operationID: "op-1",
            payload: [
                "terminal": Self.terminalObject(id: "created"),
            ]
        ))

        #expect(store.runningQuickCommandID == nil)
        #expect(store.pendingQuickCommandRun == nil)
        #expect(store.launchedQuickCommandTerminal?.id == "created")
        #expect(store.terminals["ws"]?.map(\.id) == ["created"])
    }

    @MainActor
    @Test func quickCommandRunWithoutInsertOnlyOpensTerminal() {
        let store = RemoteWorkspaceStore()
        store.pendingQuickCommandRun = PendingQuickCommandRun(operationID: "op-2")
        store.runningQuickCommandID = "qc-run"
        store.apply(Self.message(
            type: "operation.result",
            operationID: "op-2",
            payload: ["terminal": Self.terminalObject(id: "created")]
        ))

        #expect(store.launchedQuickCommandTerminal?.id == "created")
    }

    @MainActor
    @Test func unrelatedOperationResultDoesNotCompleteQuickCommandRun() {
        let store = RemoteWorkspaceStore()
        store.pendingQuickCommandRun = PendingQuickCommandRun(operationID: "op-quick")
        store.runningQuickCommandID = "qc-run"
        // A plain terminal.create result carries a different operation ID.
        store.apply(Self.message(
            type: "operation.result",
            operationID: "op-create",
            payload: ["terminal": Self.terminalObject(id: "manual")]
        ))

        #expect(store.runningQuickCommandID == "qc-run")
        #expect(store.launchedQuickCommandTerminal == nil)
    }

    @MainActor
    @Test func quickCommandRunRejectionShowsFullMessageWithoutTerminalFallback() {
        let store = RemoteWorkspaceStore()
        store.pendingQuickCommandRun = PendingQuickCommandRun(operationID: "op-3")
        store.runningQuickCommandID = "qc-agent"
        let rejection = "unknown method session.tabs.createTerminal\nagent prompt is not supported by this Orca build"
        store.apply(Self.message(
            type: "protocol.error",
            operationID: "op-3",
            payload: ["ok": .bool(false), "code": .string("method_not_found"), "message": .string(rejection)]
        ))

        // The Runtime rejection is shown verbatim, never truncated.
        #expect(store.quickCommandRunError == rejection)
        #expect(store.runningQuickCommandID == nil)
        #expect(store.pendingQuickCommandRun == nil)
    }

    @MainActor
    @Test func connectionChangeClearsCommandsAndAbortsPendingWorkWithoutRepeat() {
        let store = RemoteWorkspaceStore()
        store.pendingQuickCommandListID = "op-list"
        store.apply(Self.message(
            type: "operation.result",
            operationID: "op-list",
            payload: ["workspace_id": .string("ws"), "commands": Self.commandObjects()]
        ))
        store.pendingQuickCommandRun = PendingQuickCommandRun(operationID: "op-4")
        store.runningQuickCommandID = "qc-run"

        store.disconnect()

        // Commands of the old host are dropped and nothing is repeated automatically.
        #expect(store.quickCommands.isEmpty)
        #expect(store.pendingQuickCommandRun == nil)
        #expect(store.runningQuickCommandID == nil)
        #expect(store.quickCommandRunError != nil)
    }

    private static func message(type: String, operationID: String? = nil, payload: [String: JSONValue]) -> RemoteControlEnvelope {
        RemoteControlEnvelope(version: 1, type: type, requestID: "request", operationID: operationID, payload: DataValue(payload))
    }

    private static func workspace(projectID: String) -> RemoteWorkspace {
        RemoteWorkspace(
            id: "ws", projectID: projectID, projectName: "tax", path: "/workspace", branch: "main",
            displayName: "tax", terminalCount: 1, agentState: "active"
        )
    }

    private static func terminalObject(id: String) -> JSONValue {
        .object([
            "id": .string(id),
            "workspace_id": .string("ws"),
            "title": .string("Terminal"),
            "connected": .bool(true),
            "writable": .bool(true),
        ])
    }

    private static func commandObjects() -> [JSONValue] {
        [
            .object([
                "id": .string("qc-run"), "label": .string("Status"), "scope": .string("global"), "repo_id": .null,
                "action": .string("terminal-command"), "command": .string("git status"), "append_enter": .bool(true),
                "agent": .null, "prompt": .null,
            ]),
            .object([
                "id": .string("qc-other"), "label": .string("Other"), "scope": .string("repo"), "repo_id": .string("other-repo"),
                "action": .string("terminal-command"), "command": .string("echo no"), "append_enter": .bool(true),
                "agent": .null, "prompt": .null,
            ]),
            .object([
                "id": .string("qc-paste"), "label": .string("Paste"), "scope": .string("repo"), "repo_id": .string("repo"),
                "action": .string("terminal-command"), "command": .string("echo one\necho two"), "append_enter": .bool(false),
                "agent": .null, "prompt": .null,
            ]),
        ]
    }
}
