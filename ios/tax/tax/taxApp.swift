import SwiftUI

@main
struct TaxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settingsStore = AppEnvironment.makeSettingsStore()
    @State private var appState = AppState()
    @State private var remoteStore = RemoteWorkspaceStore()
    private let pendingTasks = PendingTaskStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settingsStore)
                .environment(appState)
                .environment(remoteStore)
                .onAppear {
                    configureDelegateService()
                    consumePendingTaskIfNeeded()
                    consumeMockTaskIfNeeded()
                }
                .onChange(of: settingsStore.apiKey) { _, _ in configureDelegateService() }
                .onChange(of: settingsStore.serverURL) { _, _ in configureDelegateService() }
                .onChange(of: settingsStore.e2eeKey) { _, _ in remoteStore.disconnect() }
                .onReceive(NotificationCenter.default.publisher(for: .taxDeviceTokenUpdated)) { notification in
                    if let token = notification.object as? String {
                        settingsStore.saveDeviceToken(token)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .taxOpenTask)) { notification in
                    if let taskID = notification.object as? String {
                        appState.openTask(id: taskID)
                        _ = pendingTasks.consume()
                    }
                    appState.requestRefresh()
                }
                .onReceive(NotificationCenter.default.publisher(for: .taxRefreshTasks)) { _ in
                    appState.requestRefresh()
                }
        }
    }

    private func configureDelegateService() {
        appDelegate.taskService = settingsStore.configuredService
    }

    private func consumePendingTaskIfNeeded() {
        if let taskID = pendingTasks.consume() {
            appState.openTask(id: taskID)
            appState.requestRefresh()
        }
    }

    private func consumeMockTaskIfNeeded() {
        guard let taskID = AppEnvironment.mockTaskID else { return }
        appState.openTask(id: taskID)
    }
}
