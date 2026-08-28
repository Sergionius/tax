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
}
