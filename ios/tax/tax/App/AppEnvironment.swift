import Foundation

@MainActor
enum AppEnvironment {
    static let arguments = ProcessInfo.processInfo.arguments
    static var isUITesting: Bool { arguments.contains("--ui-testing") }

    static func makeSettingsStore() -> SettingsStore {
        guard isUITesting else { return SettingsStore() }
        let preconfigured = arguments.contains("--mock-configured")
        let preferences = MemoryPreferencesStore(values: [
            "tax.serverURL": argument(after: "--mock-server-url") ?? "https://tax.138-249-127-23.nip.io",
            "tax.hostID": argument(after: "--mock-host-id") ?? "mac-main",
            "tax.remoteDeviceID": argument(after: "--mock-device-id") ?? "iphone-main"
        ])
        return SettingsStore(
            preferences: preferences,
            keychain: MemoryKeychainStore(
                apiKey: preconfigured ? (argument(after: "--mock-api-key") ?? "ui-test-key") : nil,
                e2eeKey: argument(after: "--mock-e2ee-key")
            ),
            serviceFactory: { _, _ in MockDeviceRegistrationService() }
        )
    }

    private static func argument(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

private actor MockDeviceRegistrationService: DeviceRegistering {
    func registerDevice(token: String, pushMode: PushMode) async throws {}
    func health() async throws -> Bool { true }
}

@MainActor
private final class MemoryPreferencesStore: PreferencesStoring {
    private var values: [String: String]

    init(values: [String: String] = [:]) { self.values = values }

    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
}

@MainActor
private final class MemoryKeychainStore: KeychainStoring {
    private var values: [String: String]

    init(apiKey: String? = nil, e2eeKey: String? = nil) {
        values = [:]
        values["tax.apiKey"] = apiKey
        values["tax.remoteE2EEKey"] = e2eeKey
    }

    func save(key: String, value: String) throws { values[key] = value }
    func load(key: String) throws -> String? { values[key] }
    func delete(key: String) throws { values[key] = nil }
}
