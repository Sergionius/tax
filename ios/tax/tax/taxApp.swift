import SwiftUI

@main
struct TaxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsStore = AppEnvironment.makeSettingsStore()
    @State private var appState = AppState()
    @State private var remoteStore = RemoteWorkspaceStore()
    private let pendingDestinations = PendingRemoteDestinationStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settingsStore)
                .environment(appState)
                .environment(remoteStore)
                .onAppear {
                    configureDelegateService()
                    if let destination = pendingDestinations.consume() { appState.open(destination) }
                }
                .onChange(of: settingsStore.apiKey) { _, _ in configureDelegateService() }
                .onChange(of: settingsStore.serverURL) { _, _ in configureDelegateService() }
                .onChange(of: settingsStore.e2eeKey) { _, _ in remoteStore.disconnect() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: Swift.Task { await remoteStore.resume(settings: settingsStore) }
                    case .background: remoteStore.suspend()
                    default: break
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .taxDeviceTokenUpdated)) { notification in
                    if let token = notification.object as? String { settingsStore.saveDeviceToken(token) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .taxOpenRemoteDestination)) { notification in
                    if let destination = notification.object as? RemoteDeepLink {
                        appState.open(destination)
                        _ = pendingDestinations.consume()
                    }
                }
        }
    }

    private func configureDelegateService() {
        appDelegate.registrationService = settingsStore.configuredService
    }
}
