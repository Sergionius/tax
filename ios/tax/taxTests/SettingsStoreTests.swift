import XCTest
@testable import tax

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testLoadsPreviouslySavedSettings() {
        let preferences = PreferencesMock(values: [
            "tax.serverURL": "https://saved.example",
            "tax.deviceToken": "saved-token",
            "tax.pushMode": "off"
        ])
        let keychain = KeychainMock(values: ["tax.apiKey": "saved-key"])
        let store = SettingsStore(preferences: preferences, keychain: keychain)

        XCTAssertEqual(store.apiKey, "saved-key")
        XCTAssertEqual(store.serverURL, "https://saved.example")
        XCTAssertEqual(store.deviceToken, "saved-token")
        XCTAssertEqual(store.pushMode, .off)
    }

    func testSavesAPIKeyOnlyToKeychainAndPreferencesSeparately() {
        let preferences = PreferencesMock()
        let keychain = KeychainMock()
        let store = SettingsStore(preferences: preferences, keychain: keychain)
        store.apiKey = "  secret  "
        store.serverURL = "https://server.example"
        store.pushMode = .all

        XCTAssertTrue(store.save())
        XCTAssertEqual(keychain.values["tax.apiKey"], "secret")
        XCTAssertNil(preferences.values["tax.apiKey"])
        XCTAssertEqual(preferences.values["tax.serverURL"], "https://server.example")
        XCTAssertEqual(preferences.values["tax.pushMode"], "all")
    }

    func testInvalidatesCachedServiceWhenSettingsChange() {
        let factory = ServiceFactoryRecorder()
        let store = SettingsStore(
            preferences: PreferencesMock(),
            keychain: KeychainMock(values: ["tax.apiKey": "key"]),
            serviceFactory: factory.make
        )
        let first = store.configuredService as AnyObject?
        let same = store.configuredService as AnyObject?
        XCTAssertTrue(first === same)
        XCTAssertEqual(factory.creationCount, 1)

        store.serverURL = "https://other.example"
        let second = store.configuredService as AnyObject?
        XCTAssertFalse(first === second)
        XCTAssertEqual(factory.creationCount, 2)
    }

    func testHandlesKeychainFailureWithoutLeakingAPIKey() {
        let keychain = KeychainMock()
        keychain.saveError = TestError.keychainUnavailable
        let store = SettingsStore(preferences: PreferencesMock(), keychain: keychain)
        store.apiKey = "never-log-this-key"

        XCTAssertFalse(store.save())
        XCTAssertNotNil(store.lastSaveError)
        XCTAssertFalse(store.lastSaveError?.contains("never-log-this-key") ?? true)
    }

    func testRegistersSavedDeviceAgainAfterSettingsChange() async throws {
        let service = ServiceStub()
        let store = SettingsStore(
            preferences: PreferencesMock(values: ["tax.deviceToken": "token-1"]),
            keychain: KeychainMock(values: ["tax.apiKey": "key"]),
            serviceFactory: { _, _ in service }
        )

        try await store.registerSavedDeviceToken()
        store.serverURL = "https://new.example"
        try await store.registerSavedDeviceToken()

        let registrations = await service.registrations
        XCTAssertEqual(registrations.count, 2)
        XCTAssertEqual(registrations.map(\.0), ["token-1", "token-1"])
    }

    func testRejectsMalformedServerURL() {
        let store = SettingsStore(
            preferences: PreferencesMock(),
            keychain: KeychainMock(values: ["tax.apiKey": "key"])
        )
        store.serverURL = "not a server"
        XCTAssertNil(store.configuredService)
    }
}

@MainActor
private final class PreferencesMock: PreferencesStoring {
    var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
}

@MainActor
private final class KeychainMock: KeychainStoring {
    var values: [String: String]
    var saveError: Error?
    var loadError: Error?

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func save(key: String, value: String) throws {
        if let saveError { throw saveError }
        values[key] = value
    }

    func load(key: String) throws -> String? {
        if let loadError { throw loadError }
        return values[key]
    }

    func delete(key: String) throws {
        values[key] = nil
    }
}

@MainActor
private final class ServiceFactoryRecorder {
    private(set) var creationCount = 0

    func make(url: URL, key: String) -> any TaskServing {
        creationCount += 1
        return ServiceStub()
    }
}

private enum TestError: LocalizedError {
    case keychainUnavailable

    var errorDescription: String? { "Keychain unavailable" }
}
