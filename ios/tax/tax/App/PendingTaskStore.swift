import Foundation

enum PendingTaskStore {
    private static let key = "tax.pendingTaskID"

    static func save(_ taskID: String) {
        UserDefaults.standard.set(taskID, forKey: key)
    }

    static func consume() -> String? {
        let taskID = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return taskID
    }
}
