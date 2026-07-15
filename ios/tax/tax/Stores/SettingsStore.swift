import Foundation
import Observation

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        apiKey = Keychain.load(key: apiKeyKey) ?? ""
        serverURL = defaults.string(forKey: serverURLKey) ?? "https://tax.138-249-127-23.nip.io"
        deviceToken = defaults.string(forKey: deviceTokenKey) ?? ""
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
        } catch {
            lastSaveError = error.localizedDescription
        }
    }

    func saveDeviceToken(_ token: String) {
        deviceToken = token
        defaults.set(token, forKey: deviceTokenKey)
    }

    var configuredService: TaskService? {
        guard !apiKey.isEmpty, let url = URL(string: serverURL) else { return nil }
        return TaskService(baseURL: url, apiKey: apiKey)
    }
}
