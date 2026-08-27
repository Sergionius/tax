import Foundation

struct PendingRemoteDestinationStore {
    private let key = "tax.pendingRemoteDestination"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    @discardableResult
    func save(_ destination: RemoteDeepLink) -> Bool {
        guard let data = try? JSONEncoder().encode(destination) else { return false }
        if let existing = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(RemoteDeepLink.self, from: existing),
           decoded == destination { return false }
        defaults.set(data, forKey: key)
        return true
    }

    func consume() -> RemoteDeepLink? {
        defer { defaults.removeObject(forKey: key) }
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RemoteDeepLink.self, from: data)
    }
}
