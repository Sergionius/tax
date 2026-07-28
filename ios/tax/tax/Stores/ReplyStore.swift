import Foundation
import Observation

@MainActor
@Observable
final class ReplyStore {
    var replyText = ""
    private(set) var errorMessage: String?
    private(set) var isSending = false

    var canSend: Bool {
        !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    func send(taskID: String, using service: (any TaskServing)?) async -> Task? {
        guard !isSending else { return nil }
        guard let service else {
            errorMessage = "Configure API key and server URL in Settings."
            return nil
        }
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        isSending = true
        defer { isSending = false }
        do {
            let task = try await service.sendReply(taskID: taskID, text: text)
            errorMessage = nil
            return task
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func dismissError() {
        errorMessage = nil
    }
}
