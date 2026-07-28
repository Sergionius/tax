import Foundation
import Observation

@MainActor
@Observable
final class TaskDetailStore {
    private(set) var task: Task?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var isRefreshing = false

    func load(taskID: String, using service: (any TaskServing)?, showOverlay: Bool = true) async {
        guard !isLoading, !isRefreshing else { return }
        guard let service else {
            errorMessage = "Configure API key and server URL in Settings."
            return
        }

        if showOverlay && task == nil {
            isLoading = true
        } else {
            isRefreshing = true
        }
        defer {
            isLoading = false
            isRefreshing = false
        }

        do {
            task = try await service.fetchTask(id: taskID)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func apply(_ updatedTask: Task) {
        task = updatedTask
    }

    func dismissError() {
        errorMessage = nil
    }
}
