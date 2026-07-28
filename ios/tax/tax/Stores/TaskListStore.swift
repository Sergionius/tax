import Foundation
import Observation

@MainActor
@Observable
final class TaskListStore {
    enum State: Equatable {
        case idle
        case loading
        case empty
        case content
        case error(String)
    }

    private(set) var tasks: [Task] = []
    private(set) var state: State = .idle
    private(set) var isRefreshing = false

    func dismissError() {
        guard case .error = state else { return }
        state = tasks.isEmpty ? .empty : .content
    }

    func load(using service: (any TaskServing)?, showOverlay: Bool = true) async {
        guard state != .loading, !isRefreshing else { return }
        guard let service else {
            tasks = []
            state = .error("Configure API key and server URL in Settings.")
            return
        }

        if showOverlay && tasks.isEmpty {
            state = .loading
        } else {
            isRefreshing = true
        }
        defer { isRefreshing = false }

        do {
            tasks = try await service.fetchTasks()
            state = tasks.isEmpty ? .empty : .content
        } catch is CancellationError {
            if tasks.isEmpty { state = .idle }
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
