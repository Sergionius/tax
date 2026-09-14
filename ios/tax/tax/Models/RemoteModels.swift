import Foundation

struct RemoteDeepLink: Codable, Equatable, Sendable {
    let hostID: String
    let workspaceID: String?
    let terminalID: String?
}

enum RemoteNavigationRoute: Hashable, Sendable {
    case workspace(RemoteWorkspace)
    case terminal(RemoteTerminal)
}

enum RemoteConnectionState: String, Sendable {
    case connecting
    case online
    case macOffline = "mac_offline"
    case orcaOffline = "orca_offline"
    case incompatible
    case reconnecting
}

struct RemoteWorkspace: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let projectID: String
    let projectName: String
    let path: String
    let branch: String
    let displayName: String
    let terminalCount: Int
    let agentState: String

    enum CodingKeys: String, CodingKey {
        case id, path, branch
        case projectID = "project_id"
        case projectName = "project_name"
        case displayName = "display_name"
        case terminalCount = "terminal_count"
        case agentState = "agent_state"
    }
}

struct RemoteTerminal: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let workspaceID: String
    let title: String
    let connected: Bool
    let writable: Bool
    let columns: Int?
    let rows: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, connected, writable, columns, rows
        case workspaceID = "workspace_id"
    }
}

struct RemoteFileEntry: Codable, Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int?

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name, path, size
        case isDirectory = "is_directory"
    }
}

struct RemoteFileDocument: Identifiable, Equatable, Sendable {
    let workspaceID: String
    let path: String
    let kind: String
    var data: Data
    var revision: String
    var savedData: Data

    var id: String { "\(workspaceID):\(path)" }
    var isModified: Bool { data != savedData }
    var text: String { String(data: data, encoding: .utf8) ?? "" }
}

struct RemoteControlEnvelope: Codable, Sendable {
    let version: Int
    let type: String
    let requestID: String
    let operationID: String?
    let payload: DataValue

    enum CodingKeys: String, CodingKey {
        case version, type, payload
        case requestID = "request_id"
        case operationID = "operation_id"
    }
}

struct DataValue: Codable, Sendable {
    let value: [String: JSONValue]

    init(_ value: [String: JSONValue] = [:]) { self.value = value }

    init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

indirect enum JSONValue: Codable, Sendable {
    case string(String), int(Int), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? { if case let .string(value) = self { value } else { nil } }
    var int: Int? { if case let .int(value) = self { value } else { nil } }
    var bool: Bool? { if case let .bool(value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case let .object(value) = self { value } else { nil } }
    var array: [JSONValue]? { if case let .array(value) = self { value } else { nil } }
}

struct TerminalRendererViewport: Equatable, Sendable {
    let columns: Int
    let rows: Int
}

@MainActor
protocol TerminalRendererSurface: AnyObject {
    func apply(update: TerminalRenderUpdate, completion: (@MainActor () -> Void)?)
    func requestFocus()
}

@MainActor
protocol TerminalRendererDelegate: AnyObject {
    func rendererDidBecomeReady(viewport: TerminalRendererViewport)
    func rendererViewportDidChange(_ viewport: TerminalRendererViewport)
    func rendererDidReceiveInput(_ data: Data)
    func rendererDidCompleteSnapshot()
}

struct TerminalRenderUpdate: Equatable, Sendable {
    let sequence: UInt64
    let generation: UInt64?
    let resetsTerminal: Bool
    let data: Data

    init(sequence: UInt64, generation: UInt64? = nil, resetsTerminal: Bool, data: Data) {
        self.sequence = sequence
        self.generation = generation
        self.resetsTerminal = resetsTerminal
        self.data = data
    }

    static let empty = TerminalRenderUpdate(sequence: 0, resetsTerminal: true, data: Data())
}

struct RemoteTerminalFrame: Sendable {
    enum Opcode: UInt8, Sendable { case snapshot = 1, output, input, resize, ack, error }
    let opcode: Opcode
    let streamID: UInt32
    let generation: UInt64
    let sequence: UInt64
    let payload: Data

    init(opcode: Opcode, streamID: UInt32, generation: UInt64, sequence: UInt64, payload: Data) {
        self.opcode = opcode
        self.streamID = streamID
        self.generation = generation
        self.sequence = sequence
        self.payload = payload
    }

    init(data: Data) throws {
        guard data.count >= 24, data[0] == 1, let opcode = Opcode(rawValue: data[1]) else {
            throw RemoteClientError.invalidFrame
        }
        self.opcode = opcode
        streamID = data.readInteger(at: 4)
        generation = data.readInteger(at: 8)
        sequence = data.readInteger(at: 16)
        payload = data.dropFirst(24)
    }

    func encoded() -> Data {
        Data([1, opcode.rawValue, 0, 0])
            + streamID.bigEndianData
            + generation.bigEndianData
            + sequence.bigEndianData
            + payload
    }
}

private extension FixedWidthInteger {
    var bigEndianData: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}

private extension Data {
    func readInteger<T: FixedWidthInteger>(at offset: Int) -> T {
        self[offset ..< offset + MemoryLayout<T>.size].reduce(T.zero) { ($0 << 8) | T($1) }
    }
}
