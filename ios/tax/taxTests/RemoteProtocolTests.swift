import Foundation
import Testing
@testable import tax

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
}
