import UIKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var taskService: (any TaskServing)?

    private let router = PushRouter()
    private let pendingTasks = PendingTaskStore()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        configureNotificationCategories(center: center)
        if !AppEnvironment.isUITesting {
            requestPushAuthorization(application: application)
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        NotificationCenter.default.post(name: .taxDeviceTokenUpdated, object: token)

        let savedSettings = SettingsStore()
        guard let service = taskService ?? savedSettings.configuredService else { return }
        let pushMode = savedSettings.pushMode
        Swift.Task {
            try? await service.registerDevice(token: token, pushMode: pushMode)
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
        refreshTasks()
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        let action = router.action(
            from: response.notification.request.content.userInfo,
            actionIdentifier: response.actionIdentifier,
            replyText: replyText
        )
        handle(action)
        completionHandler()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        refreshTasks()
        completionHandler(.newData)
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    private func handle(_ action: PushRouter.Action) {
        switch action {
        case .none:
            break
        case let .openTask(taskID):
            openTask(taskID)
        case let .reply(taskID, text):
            sendInlineReply(taskID: taskID, text: text)
        }
    }

    private func openTask(_ taskID: String) {
        pendingTasks.save(taskID)
        NotificationCenter.default.post(name: .taxOpenTask, object: taskID)
    }

    private func refreshTasks() {
        NotificationCenter.default.post(name: .taxRefreshTasks, object: nil)
    }

    private func sendInlineReply(taskID: String, text: String) {
        pendingTasks.save(taskID)
        let service = taskService ?? SettingsStore().configuredService
        Swift.Task {
            _ = try? await service?.sendReply(taskID: taskID, text: text)
            await MainActor.run {
                NotificationCenter.default.post(name: .taxOpenTask, object: taskID)
                NotificationCenter.default.post(name: .taxRefreshTasks, object: nil)
            }
        }
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
}
