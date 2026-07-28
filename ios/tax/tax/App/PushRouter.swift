import Foundation

struct PushRouter {
    enum Action: Equatable {
        case none
        case openTask(String)
        case reply(taskID: String, text: String)
    }

    func action(
        from userInfo: [AnyHashable: Any],
        actionIdentifier: String? = nil,
        replyText: String? = nil
    ) -> Action {
        guard let taskID = taskID(from: userInfo), !taskID.isEmpty else { return .none }
        if actionIdentifier == "REPLY",
           let replyText,
           !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .reply(taskID: taskID, text: replyText)
        }
        return .openTask(taskID)
    }

    func taskID(from userInfo: [AnyHashable: Any]) -> String? {
        if let taskID = userInfo["task_id"] as? String { return taskID }
        if let taskID = userInfo["taskId"] as? String { return taskID }
        if let aps = userInfo["aps"] as? [String: Any], let taskID = aps["task_id"] as? String { return taskID }
        return nil
    }
}
