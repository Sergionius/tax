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
    @ObservationIgnored private let logger = Logger(subsystem: "ru.madmaximuus.yandexmapstestapp.YandexMapsTestApp", category: "SettingsStore")
    @ObservationIgnored private var normalizedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        apiKey = Keychain.load(key: apiKeyKey) ?? ""
        serverURL = defaults.string(forKey: serverURLKey) ?? "https://tax.138-249-127-23.nip.io"
        deviceToken = defaults.string(forKey: deviceTokenKey) ?? ""
        logger.info("Loaded settings: apiKey=\(self.apiKey, privacy: .public), length=\(self.apiKey.count), serverURL=\(self.serverURL, privacy: .public)")
    }

    func save() {
        do {
            let normalizedAPIKey = self.normalizedAPIKey
            if apiKey != normalizedAPIKey {
                apiKey = normalizedAPIKey
            }

            if normalizedAPIKey.isEmpty {
                Keychain.delete(key: apiKeyKey)
            } else {
                try Keychain.save(key: apiKeyKey, value: normalizedAPIKey)
            }
            defaults.set(serverURL, forKey: serverURLKey)
            lastSaveError = nil
            logger.info("Saved settings: apiKey=\(self.apiKey, privacy: .public), length=\(self.apiKey.count)")
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
        let normalizedAPIKey = self.normalizedAPIKey
        guard !normalizedAPIKey.isEmpty, let url = URL(string: serverURL) else { return nil }
        return TaskService(baseURL: url, apiKey: normalizedAPIKey)
    }
}
