import UIKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var registrationService: (any DeviceRegistering)?

    private let router = PushRouter()
    private let pendingDestinations = PendingRemoteDestinationStore()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        #if !targetEnvironment(simulator)
        if !AppEnvironment.isUITesting { requestPushAuthorization(application: application) }
        #endif
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        NotificationCenter.default.post(name: .taxDeviceTokenUpdated, object: token)
        let settings = SettingsStore()
        guard let service = registrationService ?? settings.configuredService else { return }
        Swift.Task { try? await service.registerDevice(token: token, pushMode: settings.pushMode) }
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
        open(router.destination(from: response.notification.request.content.userInfo))
        completionHandler()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let destination = router.destination(from: userInfo) else {
            completionHandler(.noData)
            return
        }
        pendingDestinations.save(destination)
        NotificationCenter.default.post(name: .taxOpenRemoteDestination, object: destination)
        completionHandler(.newData)
    }

    func registerForRemoteNotifications() { UIApplication.shared.registerForRemoteNotifications() }

    private func open(_ destination: RemoteDeepLink?) {
        guard let destination else { return }
        pendingDestinations.save(destination)
        NotificationCenter.default.post(name: .taxOpenRemoteDestination, object: destination)
    }

    private func requestPushAuthorization(application: UIApplication) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error { print("Push authorization failed: \(error.localizedDescription)") }
            guard granted else { return }
            Swift.Task { @MainActor in application.registerForRemoteNotifications() }
        }
    }
}
