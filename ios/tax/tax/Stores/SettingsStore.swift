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

@MainActor
@Observable
final class SettingsStore {
    typealias ServiceFactory = (URL, String) -> any TaskServing

    var apiKey: String {
        didSet { if apiKey != oldValue { cachedService = nil } }
    }
    var serverURL: String {
        didSet { if serverURL != oldValue { cachedService = nil } }
    }
    var deviceToken: String
    var pushMode: PushMode
    var lastSaveError: String?

    @ObservationIgnored private let apiKeyKey = "tax.apiKey"
    @ObservationIgnored private let serverURLKey = "tax.serverURL"
    @ObservationIgnored private let deviceTokenKey = "tax.deviceToken"
    @ObservationIgnored private let pushModeKey = "tax.pushMode"
    @ObservationIgnored private let keychain: any KeychainStoring
    @ObservationIgnored private let preferences: any PreferencesStoring
    @ObservationIgnored private let serviceFactory: ServiceFactory
    @ObservationIgnored private var cachedService: (any TaskServing)?
    @ObservationIgnored private let logger = Logger(subsystem: "ru.madmaximuus.yandexmapstestapp.YandexMapsTestApp", category: "SettingsStore")

    private var normalizedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(
        defaults: UserDefaults = .standard,
        keychain: any KeychainStoring = SystemKeychainStore(),
        serviceFactory: @escaping ServiceFactory = { url, key in TaskService(baseURL: url, apiKey: key) }
    ) {
        self.keychain = keychain
        preferences = UserDefaultsPreferences(defaults: defaults)
        self.serviceFactory = serviceFactory
        apiKey = ""
        serverURL = preferences.string(forKey: serverURLKey) ?? "https://tax.138-249-127-23.nip.io"
        deviceToken = preferences.string(forKey: deviceTokenKey) ?? ""
        pushMode = preferences.string(forKey: pushModeKey).flatMap(PushMode.init(rawValue:)) ?? .taxOnly

        do {
            apiKey = try keychain.load(key: apiKeyKey) ?? ""
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
        logger.info("Loaded settings: apiKeyPresent=\(!self.apiKey.isEmpty), apiKeyLength=\(self.apiKey.count), serverURL=\(self.serverURL, privacy: .public)")
    }

    init(
        preferences: any PreferencesStoring,
        keychain: any KeychainStoring,
        serviceFactory: @escaping ServiceFactory = { url, key in TaskService(baseURL: url, apiKey: key) }
    ) {
        self.keychain = keychain
        self.preferences = preferences
        self.serviceFactory = serviceFactory
        apiKey = ""
        serverURL = preferences.string(forKey: serverURLKey) ?? "https://tax.138-249-127-23.nip.io"
        deviceToken = preferences.string(forKey: deviceTokenKey) ?? ""
        pushMode = preferences.string(forKey: pushModeKey).flatMap(PushMode.init(rawValue:)) ?? .taxOnly

        do {
            apiKey = try keychain.load(key: apiKeyKey) ?? ""
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
            preferences.set(serverURL, forKey: serverURLKey)
            preferences.set(pushMode.rawValue, forKey: pushModeKey)
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

    var configuredService: (any TaskServing)? {
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
