import SwiftUI

struct ReplyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings

    let task: Task
    let onSent: (Task) -> Void

    @State private var replyText = ""
    @State private var errorMessage: String?
    @State private var isSending = false

    var body: some View {
        Form {
            Section("Task") {
                Text(task.title)
                Text(task.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Reply") {
                TextEditor(text: $replyText)
                    .frame(minHeight: 180)
                    .accessibilityLabel("Reply text")
            }
        }
        .navigationTitle("Reply")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(isSending)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSending ? "Sending…" : "Send") {
                    Swift.Task { await send() }
                }
                .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func send() async {
        guard let service = settings.configuredService else {
            errorMessage = "Configure API key and server URL in Settings."
            return
        }

        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isSending = true
        defer { isSending = false }

        do {
            let updatedTask = try await service.sendReply(taskID: task.id, text: text)
            onSent(updatedTask)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
