import Foundation
import Observation

enum AppTab: Hashable {
    case tasks
    case settings
}

@Observable
final class AppState {
    var selectedTab: AppTab = .tasks
    var selectedTaskID: String?
    var refreshToken = UUID()

    func openTask(id: String) {
        selectedTab = .tasks
        selectedTaskID = id
    }

    func clearSelectedTask() {
        selectedTaskID = nil
    }

    func requestRefresh() {
        refreshToken = UUID()
    }
}
