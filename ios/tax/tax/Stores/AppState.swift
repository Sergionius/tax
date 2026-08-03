import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var navigationPath: [String] = []
    var refreshToken = UUID()

    func openTask(id: String) {
        guard !id.isEmpty else { return }
        guard navigationPath.last != id else { return }
        navigationPath.append(id)
    }

    func requestRefresh() {
        refreshToken = UUID()
    }
}
