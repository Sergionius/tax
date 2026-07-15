import Foundation
import Observation
import OSLog

@Observable
final class SettingsStore {
    var apiKey: String
    var serverURL: String
    var deviceToken: String
    var lastSaveError: String?

    @ObservationIgnored private let apiKeyKey = "tax.apiKey"
    @ObservationIgnored private let serverURLKey = "tax.serverURL"
    @ObservationIgnored private let deviceTokenKey = "tax.deviceToken"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let logger = Logger(subsystem: "com.sergionius.tax", category: "SettingsStore")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        apiKey = Keychain.load(key: apiKeyKey) ?? ""
        serverURL = defaults.string(forKey: serverURLKey) ?? "https://tax.138-249-127-23.nip.io"
        deviceToken = defaults.string(forKey: deviceTokenKey) ?? ""
        logger.info("Loaded settings: apiKey prefix=\(String(apiKey.prefix(8)), privacy: .public), length=\(apiKey.count), serverURL=\(serverURL, privacy: .public)")
    }

    func save() {
        do {
            if apiKey.isEmpty {
                Keychain.delete(key: apiKeyKey)
            } else {
                try Keychain.save(key: apiKeyKey, value: apiKey)
            }
            defaults.set(serverURL, forKey: serverURLKey)
            lastSaveError = nil
            logger.info("Saved settings: apiKey prefix=\(String(apiKey.prefix(8)), privacy: .public), length=\(apiKey.count)")
        } catch {
            lastSaveError = error.localizedDescription
            logger.error("Failed to save settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    func saveDeviceToken(_ token: String) {
        deviceToken = token
        defaults.set(token, forKey: deviceTokenKey)
        logger.info("Saved device token: \(token.prefix(16))...")
    }

    var configuredService: TaskService? {
        guard !apiKey.isEmpty, let url = URL(string: serverURL) else { return nil }
        return TaskService(baseURL: url, apiKey: apiKey)
    }
}
