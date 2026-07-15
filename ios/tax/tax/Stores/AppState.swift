import Foundation
import Observation

@Observable
final class AppState {
    var selectedTaskID: String?
    var refreshToken = UUID()

    func openTask(id: String) {
        selectedTaskID = id
    }

    func requestRefresh() {
        refreshToken = UUID()
    }
}
