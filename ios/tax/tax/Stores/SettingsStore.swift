import Foundation
import Observation
import OSLog

protocol PreferencesStoring {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
}

struct UserDefaultsPreferences: PreferencesStoring {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

struct RemoteConfiguration: Sendable {
    let serverURL: URL
    let apiKey: String
    let hostID: String
    let deviceID: String
    let e2eeKey: String
}

/// Neutral OSLog subsystem derived from the app identity; private overrides
/// in Local.xcconfig change the bundle identifier without touching this code.
enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.example.tax"

    static func logger(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}

@MainActor
@Observable
final class SettingsStore {
    typealias ServiceFactory = (URL, String) -> any DeviceRegistering

    var apiKey: String {
        didSet { if apiKey != oldValue { cachedService = nil } }
    }
    var serverURL: String {
        didSet { if serverURL != oldValue { cachedService = nil } }
    }
    var deviceToken: String
    var pushMode: PushMode
    var hostID: String
    var remoteDeviceID: String
    var e2eeKey: String
    var lastSaveError: String?

    @ObservationIgnored private let apiKeyKey = "tax.apiKey"
    @ObservationIgnored private let serverURLKey = "tax.serverURL"
    @ObservationIgnored private let deviceTokenKey = "tax.deviceToken"
    @ObservationIgnored private let pushModeKey = "tax.pushMode"
    @ObservationIgnored private let hostIDKey = "tax.hostID"
    @ObservationIgnored private let remoteDeviceIDKey = "tax.remoteDeviceID"
    @ObservationIgnored private let e2eeKeyKey = "tax.remoteE2EEKey"
    @ObservationIgnored private let keychain: any KeychainStoring
    @ObservationIgnored private let preferences: any PreferencesStoring
    @ObservationIgnored private let serviceFactory: ServiceFactory
    @ObservationIgnored private var cachedService: (any DeviceRegistering)?
    @ObservationIgnored private let logger = AppLog.logger(category: "SettingsStore")

    private var normalizedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(
        defaults: UserDefaults = .standard,
        keychain: any KeychainStoring = SystemKeychainStore(),
        serviceFactory: @escaping ServiceFactory = { url, key in DeviceRegistrationService(baseURL: url, apiKey: key) }
    ) {
        self.keychain = keychain
        preferences = UserDefaultsPreferences(defaults: defaults)
        self.serviceFactory = serviceFactory
        apiKey = ""
        serverURL = preferences.string(forKey: serverURLKey) ?? ""
        deviceToken = preferences.string(forKey: deviceTokenKey) ?? ""
        pushMode = preferences.string(forKey: pushModeKey).flatMap(PushMode.init(rawValue:)) ?? .taxOnly
        hostID = preferences.string(forKey: hostIDKey) ?? "mac-main"
        remoteDeviceID = preferences.string(forKey: remoteDeviceIDKey) ?? "iphone-main"
        e2eeKey = ""

        do {
            apiKey = try keychain.load(key: apiKeyKey) ?? ""
            e2eeKey = try keychain.load(key: e2eeKeyKey) ?? ""
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
        // Never log the configured server URL: it is part of the owner's
        // private infrastructure.
        logger.info("Loaded settings: apiKeyPresent=\(!self.apiKey.isEmpty), apiKeyLength=\(self.apiKey.count), serverURLPresent=\(!self.serverURL.isEmpty)")
    }

    init(
        preferences: any PreferencesStoring,
        keychain: any KeychainStoring,
        serviceFactory: @escaping ServiceFactory = { url, key in DeviceRegistrationService(baseURL: url, apiKey: key) }
    ) {
        self.keychain = keychain
        self.preferences = preferences
        self.serviceFactory = serviceFactory
        apiKey = ""
        serverURL = preferences.string(forKey: serverURLKey) ?? ""
        deviceToken = preferences.string(forKey: deviceTokenKey) ?? ""
        pushMode = preferences.string(forKey: pushModeKey).flatMap(PushMode.init(rawValue:)) ?? .taxOnly
        hostID = preferences.string(forKey: hostIDKey) ?? "mac-main"
        remoteDeviceID = preferences.string(forKey: remoteDeviceIDKey) ?? "iphone-main"
        e2eeKey = ""

        do {
            apiKey = try keychain.load(key: apiKeyKey) ?? ""
            e2eeKey = try keychain.load(key: e2eeKeyKey) ?? ""
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }

    @discardableResult
    func save() -> Bool {
        do {
            let normalizedAPIKey = self.normalizedAPIKey
            if apiKey != normalizedAPIKey {
                apiKey = normalizedAPIKey
            }

            if normalizedAPIKey.isEmpty {
                try keychain.delete(key: apiKeyKey)
            } else {
                try keychain.save(key: apiKeyKey, value: normalizedAPIKey)
            }
            let normalizedE2EEKey = e2eeKey.trimmingCharacters(in: .whitespacesAndNewlines)
            e2eeKey = normalizedE2EEKey
            if normalizedE2EEKey.isEmpty { try keychain.delete(key: e2eeKeyKey) }
            else { try keychain.save(key: e2eeKeyKey, value: normalizedE2EEKey) }
            preferences.set(serverURL, forKey: serverURLKey)
            preferences.set(pushMode.rawValue, forKey: pushModeKey)
            preferences.set(hostID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: hostIDKey)
            preferences.set(remoteDeviceID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: remoteDeviceIDKey)
            cachedService = nil
            lastSaveError = nil
            logger.info("Saved settings: apiKeyPresent=\(!self.apiKey.isEmpty), apiKeyLength=\(self.apiKey.count)")
            return true
        } catch {
            lastSaveError = error.localizedDescription
            logger.error("Failed to save settings: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func savePushMode() {
        preferences.set(pushMode.rawValue, forKey: pushModeKey)
    }

    func saveDeviceToken(_ token: String) {
        deviceToken = token
        preferences.set(token, forKey: deviceTokenKey)
        logger.info("Saved a device token of length \(token.count)")
    }

    var remoteConfiguration: RemoteConfiguration? {
        guard let serverURL = URL(string: serverURL),
              ["http", "https"].contains(serverURL.scheme?.lowercased() ?? ""),
              serverURL.host != nil,
              !normalizedAPIKey.isEmpty,
              !hostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !remoteDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !e2eeKey.isEmpty else { return nil }
        return RemoteConfiguration(
            serverURL: serverURL,
            apiKey: normalizedAPIKey,
            hostID: hostID.trimmingCharacters(in: .whitespacesAndNewlines),
            deviceID: remoteDeviceID.trimmingCharacters(in: .whitespacesAndNewlines),
            e2eeKey: e2eeKey
        )
    }

    var configuredService: (any DeviceRegistering)? {
        let normalizedAPIKey = self.normalizedAPIKey
        guard !normalizedAPIKey.isEmpty,
              let url = URL(string: serverURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        if let cachedService { return cachedService }
        let service = serviceFactory(url, normalizedAPIKey)
        cachedService = service
        return service
    }

    func registerSavedDeviceToken() async throws {
        guard let service = configuredService, !deviceToken.isEmpty else { return }
        try await service.registerDevice(token: deviceToken, pushMode: pushMode)
    }
}
