import Foundation

@MainActor
enum AppEnvironment {
    static let arguments = ProcessInfo.processInfo.arguments
    static var isUITesting: Bool { arguments.contains("--ui-testing") }

    #if DEBUG
    static var screenshotScreen: ScreenshotScreen? {
        guard isUITesting, arguments.contains("--screenshot-mode") else { return nil }
        return argument(after: "--screenshot-screen").flatMap(ScreenshotScreen.init(rawValue:)) ?? .workspaces
    }
    #endif

    static var isScreenshotMode: Bool {
        #if DEBUG
        screenshotScreen != nil
        #else
        false
        #endif
    }

    static func makeSettingsStore() -> SettingsStore {
        guard isUITesting else { return SettingsStore() }
        let preconfigured = arguments.contains("--mock-configured") || isScreenshotMode
        let preferences = MemoryPreferencesStore(values: [
            "tax.serverURL": argument(after: "--mock-server-url") ?? (isScreenshotMode ? "https://tax.example.com" : "https://tax.138-249-127-23.nip.io"),
            "tax.hostID": argument(after: "--mock-host-id") ?? (isScreenshotMode ? "studio-mac" : "mac-main"),
            "tax.remoteDeviceID": argument(after: "--mock-device-id") ?? (isScreenshotMode ? "demo-iphone" : "iphone-main")
        ])
        return SettingsStore(
            preferences: preferences,
            keychain: MemoryKeychainStore(
                apiKey: preconfigured ? (argument(after: "--mock-api-key") ?? "demo-api-key") : nil,
                e2eeKey: argument(after: "--mock-e2ee-key") ?? (isScreenshotMode ? String(repeating: "a", count: 64) : nil)
            ),
            serviceFactory: { _, _ in MockDeviceRegistrationService() }
        )
    }

    static func makeRemoteWorkspaceStore() -> RemoteWorkspaceStore {
        RemoteWorkspaceStore(screenshotMode: isScreenshotMode)
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
