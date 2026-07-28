import Foundation

struct PendingTaskStore {
    private let key = "tax.pendingTaskID"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    @discardableResult
    func save(_ taskID: String) -> Bool {
        guard !taskID.isEmpty, defaults.string(forKey: key) != taskID else { return false }
        defaults.set(taskID, forKey: key)
        return true
    }

    func consume() -> String? {
        let taskID = defaults.string(forKey: key)
        defaults.removeObject(forKey: key)
        return taskID
    }
}
