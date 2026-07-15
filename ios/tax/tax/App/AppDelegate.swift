import UIKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var taskService: TaskService?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        configureNotificationCategories(center: center)
        requestPushAuthorization(application: application)
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        NotificationCenter.default.post(name: .taxDeviceTokenUpdated, object: token)

        guard let taskService else { return }
        Swift.Task {
            try? await taskService.registerDevice(token: token)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        print("Failed to register for remote notifications: \(error.localizedDescription)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let taskID = extractTaskID(from: userInfo) {
            if response.actionIdentifier == "REPLY",
               let textResponse = response as? UNTextInputNotificationResponse,
               !textResponse.userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sendInlineReply(taskID: taskID, text: textResponse.userText)
            } else {
                openTask(taskID)
            }
        }
        completionHandler()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if let taskID = extractTaskID(from: userInfo) {
            openTask(taskID)
        } else {
            NotificationCenter.default.post(name: .taxRefreshTasks, object: nil)
        }
        completionHandler(.newData)
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    private func openTask(_ taskID: String) {
        PendingTaskStore.save(taskID)
        NotificationCenter.default.post(name: .taxOpenTask, object: taskID)
    }

    private func sendInlineReply(taskID: String, text: String) {
        PendingTaskStore.save(taskID)
        let service = taskService ?? savedTaskService()
        Swift.Task {
            _ = try? await service?.sendReply(taskID: taskID, text: text)
            await MainActor.run {
                NotificationCenter.default.post(name: .taxOpenTask, object: taskID)
                NotificationCenter.default.post(name: .taxRefreshTasks, object: nil)
            }
        }
    }

    private func savedTaskService() -> TaskService? {
        let settings = SettingsStore()
        return settings.configuredService
    }

    private func requestPushAuthorization(application: UIApplication) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error {
                print("Push authorization failed: \(error.localizedDescription)")
            }
            guard granted else { return }
            Swift.Task { @MainActor in
                application.registerForRemoteNotifications()
            }
        }
    }

    private func configureNotificationCategories(center: UNUserNotificationCenter) {
        let reply = UNTextInputNotificationAction(
            identifier: "REPLY",
            title: "Reply",
            options: [.foreground],
            textInputButtonTitle: "Open",
            textInputPlaceholder: "Type a reply"
        )
        let category = UNNotificationCategory(identifier: "TASK", actions: [reply], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    private func extractTaskID(from userInfo: [AnyHashable: Any]) -> String? {
        if let taskID = userInfo["task_id"] as? String { return taskID }
        if let taskID = userInfo["taskId"] as? String { return taskID }
        if let aps = userInfo["aps"] as? [String: Any], let taskID = aps["task_id"] as? String { return taskID }
        return nil
    }
}
