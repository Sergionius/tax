import Foundation
import Observation

enum AppTab: Hashable {
    case tasks
    case settings
}

@MainActor
@Observable
final class AppState {
    var selectedTab: AppTab = .tasks
    var navigationPath: [String] = []
    var refreshToken = UUID()

    func openTask(id: String) {
        guard !id.isEmpty else { return }
        selectedTab = .tasks
        guard navigationPath.last != id else { return }
        navigationPath.append(id)
    }

    func requestRefresh() {
        refreshToken = UUID()
    }
}
