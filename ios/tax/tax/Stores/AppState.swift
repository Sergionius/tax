import Observation

@MainActor
@Observable
final class AppState {
    var navigationPath: [RemoteNavigationRoute] = []
    var pendingDestination: RemoteDeepLink?

    func open(_ destination: RemoteDeepLink) {
        pendingDestination = destination
        if destination.workspaceID == nil { navigationPath = [] }
    }

    func finishRouting() { pendingDestination = nil }
}
