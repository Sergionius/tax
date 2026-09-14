import CryptoKit
import Foundation
import Security

enum RemoteClientError: LocalizedError, Sendable {
    case invalidConfiguration, invalidKey, invalidFrame, disconnected, server(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Configure server URL, API key, host ID, device ID, and encryption key."
        case .invalidKey: "The encryption key must be a 256-bit base64url value."
        case .invalidFrame: "The remote host returned an invalid encrypted frame."
        case .disconnected: "The remote host disconnected."
        case let .server(message): message
        }
    }
}

enum RemoteEvent: Sendable {
    case control(RemoteControlEnvelope)
    case terminal(RemoteTerminalFrame)
}

actor RemoteClient {
    private let task: URLSessionWebSocketTask
    private let session: RemoteCryptoSession

    init(serverURL: URL, apiKey: String, hostID: String, deviceID: String, key: String) throws {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false),
              let secret = Data(base64URLEncoded: key), secret.count == 32 else { throw RemoteClientError.invalidKey }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/relay/device"
        if !components.path.hasPrefix("/") { components.path = "/" + components.path }
        components.queryItems = [URLQueryItem(name: "host_id", value: hostID), URLQueryItem(name: "device_id", value: deviceID)]
        guard let url = components.url else { throw RemoteClientError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        task = URLSession.shared.webSocketTask(with: request)
        let sessionID = Data.random(count: 16)
        let salt = Data.random(count: 32)
        session = try RemoteCryptoSession(secret: secret, hostID: hostID, deviceID: deviceID, sessionID: sessionID, salt: salt)
        task.resume()
        task.send(.data(Data("TAX-E2EE-1\0".utf8) + sessionID + salt)) { _ in }
    }

    func sendControl(type: String, requestID: String = UUID().uuidString, operationID: String? = nil, payload: [String: JSONValue] = [:]) async throws {
        let envelope = RemoteControlEnvelope(version: 1, type: type, requestID: requestID, operationID: operationID, payload: DataValue(payload))
        try await send(channel: 1, data: JSONEncoder().encode(envelope))
    }

    func sendTerminal(_ data: Data) async throws { try await send(channel: 2, data: data) }

    func events() -> AsyncThrowingStream<RemoteEvent, Error> {
        AsyncThrowingStream { continuation in
            let worker = Swift.Task {
                do {
                    while !Swift.Task.isCancelled {
                        let message = try await task.receive()
                        guard case let .data(frame) = message else { throw RemoteClientError.invalidFrame }
                        let (channel, plaintext) = try session.decrypt(frame)
                        if channel == 1 {
                            continuation.yield(.control(try JSONDecoder().decode(RemoteControlEnvelope.self, from: plaintext)))
                        } else if channel == 2 {
                            continuation.yield(.terminal(try RemoteTerminalFrame(data: plaintext)))
                        } else { throw RemoteClientError.invalidFrame }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }

    private func send(channel: UInt8, data: Data) async throws {
        try await task.send(.data(try session.encrypt(channel: channel, plaintext: data)))
    }
}

final class RemoteCryptoSession: @unchecked Sendable {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let hostID: Data
    private let deviceID: Data
    private let sessionID: Data
    private let lock = NSLock()
    private var sendSequence: UInt64 = 0
    private var receiveSequence: UInt64?

    init(secret: Data, hostID: String, deviceID: String, sessionID: Data, salt: Data) throws {
        self.hostID = Data(hostID.utf8)
        self.deviceID = Data(deviceID.utf8)
        self.sessionID = sessionID
        let info = Data("tax-remote-v1\0".utf8) + self.hostID + Data([0]) + self.deviceID + Data([0]) + sessionID
        let material = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt, info: info, outputByteCount: 64)
        let bytes = material.withUnsafeBytes { Data($0) }
        sendKey = SymmetricKey(data: bytes.prefix(32))
        receiveKey = SymmetricKey(data: bytes.suffix(32))
    }

    func encrypt(channel: UInt8, plaintext: Data) throws -> Data {
        lock.lock()
        let sequence = sendSequence
        sendSequence += 1
        lock.unlock()
        let nonce = try ChaChaPoly.Nonce(data: integerData(UInt32(1)) + integerData(sequence))
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: nonce, authenticating: aad(channel: channel, sequence: sequence, direction: 1))
        return Data([1, channel]) + integerData(sequence) + box.ciphertext + box.tag
    }

    func decrypt(_ frame: Data) throws -> (UInt8, Data) {
        guard frame.count >= 26, frame[0] == 1 else { throw RemoteClientError.invalidFrame }
        let channel = frame[1]
        let sequence: UInt64 = frame[2 ..< 10].reduce(0) { ($0 << 8) | UInt64($1) }
        lock.lock()
        defer { lock.unlock() }
        if let receiveSequence, sequence <= receiveSequence { throw RemoteClientError.invalidFrame }
        let nonce = try ChaChaPoly.Nonce(data: integerData(UInt32(2)) + integerData(sequence))
        let ciphertext = frame[10 ..< frame.count - 16]
        let tag = frame.suffix(16)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext = try ChaChaPoly.open(box, using: receiveKey, authenticating: aad(channel: channel, sequence: sequence, direction: 2))
        receiveSequence = sequence
        return (channel, plaintext)
    }

    private func aad(channel: UInt8, sequence: UInt64, direction: UInt8) -> Data {
        Data([1, channel, direction]) + integerData(sequence) + sessionID + hostID + Data([0]) + deviceID
    }

    private func integerData<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: normalized)
    }

    static func random(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
