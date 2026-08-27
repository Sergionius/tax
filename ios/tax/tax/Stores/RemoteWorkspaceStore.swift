import Foundation
import Observation

@MainActor
@Observable
final class RemoteWorkspaceStore {
    var connectionState: RemoteConnectionState = .macOffline
    var workspaces: [RemoteWorkspace] = []
    var terminals: [String: [RemoteTerminal]] = [:]
    var terminalBuffers: [UInt32: Data] = [:]
    var errorMessage: String?
    var activeStreamID: UInt32?
    var activeGeneration: UInt64?

    @ObservationIgnored private var client: RemoteClient?
    @ObservationIgnored private var eventTask: Swift.Task<Void, Never>?
    @ObservationIgnored private var configuration: RemoteConfiguration?
    @ObservationIgnored private var activeTerminalID: String?

    func connect(settings: SettingsStore) async {
        disconnect()
        guard let configuration = settings.remoteConfiguration else {
            connectionState = .macOffline
            errorMessage = RemoteClientError.invalidConfiguration.localizedDescription
            return
        }
        self.configuration = configuration
        await establish(configuration: configuration)
    }

    private func establish(configuration: RemoteConfiguration) async {
        connectionState = connectionState == .macOffline ? .connecting : .reconnecting
        do {
            let client = try RemoteClient(
                serverURL: configuration.serverURL,
                apiKey: configuration.apiKey,
                hostID: configuration.hostID,
                deviceID: configuration.deviceID,
                key: configuration.e2eeKey
            )
            self.client = client
            eventTask = Swift.Task { [weak self] in await self?.consume(client: client) }
            try await client.sendControl(type: "workspace.list")
        } catch {
            connectionState = .macOffline
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        guard let client else { return }
        do {
            try await client.sendControl(type: "workspace.list")
            for workspace in workspaces { try await client.sendControl(type: "terminal.list", payload: ["workspace_id": .string(workspace.id)]) }
        } catch { errorMessage = error.localizedDescription }
    }

    func loadTerminals(workspaceID: String) async {
        do { try await client?.sendControl(type: "terminal.list", payload: ["workspace_id": .string(workspaceID)]) }
        catch { errorMessage = error.localizedDescription }
    }

    func subscribe(terminalID: String) async {
        activeTerminalID = terminalID
        activeStreamID = nil
        activeGeneration = nil
        do { try await client?.sendControl(type: "terminal.subscribe", payload: ["terminal_id": .string(terminalID)]) }
        catch { errorMessage = error.localizedDescription }
    }

    func sendInput(terminalID: String, text: String) async {
        let encoded = Data(text.utf8).base64EncodedString()
        do {
            try await client?.sendControl(
                type: "terminal.input",
                operationID: UUID().uuidString,
                payload: ["terminal_id": .string(terminalID), "data_b64": .string(encoded)]
            )
        } catch { errorMessage = "Input delivery is ambiguous and was not repeated: \(error.localizedDescription)" }
    }

    func resize(terminalID: String, columns: Int, rows: Int) async {
        do {
            try await client?.sendControl(
                type: "terminal.resize",
                payload: ["terminal_id": .string(terminalID), "columns": .int(columns), "rows": .int(rows)]
            )
        } catch { errorMessage = error.localizedDescription }
    }

    func createTerminal(workspaceID: String, title: String?) async {
        var payload: [String: JSONValue] = ["workspace_id": .string(workspaceID)]
        if let title, !title.isEmpty { payload["title"] = .string(title) }
        do {
            try await client?.sendControl(type: "terminal.create", operationID: UUID().uuidString, payload: payload)
            try await Swift.Task.sleep(for: .milliseconds(150))
            await loadTerminals(workspaceID: workspaceID)
        } catch { errorMessage = error.localizedDescription }
    }

    func renameTerminal(_ terminal: RemoteTerminal, title: String) async {
        do {
            try await client?.sendControl(type: "terminal.rename", operationID: UUID().uuidString, payload: ["terminal_id": .string(terminal.id), "title": .string(title)])
            await loadTerminals(workspaceID: terminal.workspaceID)
        } catch { errorMessage = error.localizedDescription }
    }

    func closeTerminal(_ terminal: RemoteTerminal) async {
        do {
            try await client?.sendControl(type: "terminal.close", operationID: UUID().uuidString, payload: ["terminal_id": .string(terminal.id)])
            await loadTerminals(workspaceID: terminal.workspaceID)
        } catch { errorMessage = error.localizedDescription }
    }

    func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        if let client { Swift.Task { await client.close() } }
        client = nil
        configuration = nil
        activeTerminalID = nil
        activeStreamID = nil
        activeGeneration = nil
    }

    private func consume(client: RemoteClient) async {
        do {
            for try await event in await client.events() {
                switch event {
                case let .control(message): apply(message)
                case let .terminal(frame): apply(frame)
                }
            }
            if !Swift.Task.isCancelled { connectionState = .macOffline }
        } catch {
            if !Swift.Task.isCancelled {
                connectionState = .reconnecting
                errorMessage = error.localizedDescription
                await client.close()
                self.client = nil
                if let configuration {
                    try? await Swift.Task.sleep(for: .seconds(1))
                    guard !Swift.Task.isCancelled else { return }
                    await establish(configuration: configuration)
                }
            }
        }
    }

    private func apply(_ message: RemoteControlEnvelope) {
        if message.type == "host.hello" {
            connectionState = .online
            Swift.Task {
                try? await client?.sendControl(type: "workspace.list")
                if let activeTerminalID { await subscribe(terminalID: activeTerminalID) }
            }
            return
        }
        guard message.type == "operation.result" else {
            if message.type == "protocol.error" { errorMessage = message.payload.value["message"]?.string }
            return
        }
        let payload = message.payload.value
        if let values = payload["workspaces"]?.array { workspaces = decode(values, as: RemoteWorkspace.self) }
        if let values = payload["terminals"]?.array {
            let decoded = decode(values, as: RemoteTerminal.self)
            if let workspaceID = payload["workspace_id"]?.string ?? decoded.first?.workspaceID {
                terminals[workspaceID] = decoded
            }
        }
        if let streamID = payload["stream_id"]?.int, let generation = payload["generation"]?.int {
            activeStreamID = UInt32(streamID)
            activeGeneration = UInt64(generation)
            terminalBuffers[UInt32(streamID)] = Data()
        }
    }

    private func apply(_ frame: RemoteTerminalFrame) {
        guard frame.streamID == activeStreamID, frame.generation == activeGeneration else { return }
        switch frame.opcode {
        case .snapshot: terminalBuffers[frame.streamID] = frame.payload
        case .output: terminalBuffers[frame.streamID, default: Data()].append(frame.payload)
        default: break
        }
    }

    private func decode<T: Decodable>(_ values: [JSONValue], as type: T.Type) -> [T] {
        values.compactMap { value in
            guard case let .object(object) = value,
                  let data = try? JSONEncoder().encode(DataValue(object)) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
    }
}
