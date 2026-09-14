import Foundation

struct PushRouter {
    func destination(from userInfo: [AnyHashable: Any]) -> RemoteDeepLink? {
        let nested = userInfo["remote"] as? [String: Any]
        guard let hostID = string("host_id", in: userInfo, nested: nested), !hostID.isEmpty else { return nil }
        let workspaceID = string("workspace_id", in: userInfo, nested: nested)
        let terminalID = string("terminal_id", in: userInfo, nested: nested)
        guard terminalID == nil || workspaceID != nil else { return nil }
        return RemoteDeepLink(hostID: hostID, workspaceID: workspaceID, terminalID: terminalID)
    }

    private func string(_ key: String, in userInfo: [AnyHashable: Any], nested: [String: Any]?) -> String? {
        let value = (userInfo[key] as? String) ?? (nested?[key] as? String)
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }
}
