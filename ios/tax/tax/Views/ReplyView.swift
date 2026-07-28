import SwiftUI

struct ReplyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings

    let task: Task
    let onSent: (Task) -> Void

    @State private var store = ReplyStore()

    var body: some View {
        @Bindable var store = store

        Form {
            Section("Task") {
                Text(task.title)
                Text(task.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Reply") {
                TextEditor(text: $store.replyText)
                    .frame(minHeight: 180)
                    .accessibilityLabel("Reply text")
                    .accessibilityIdentifier("reply.text")
            }
        }
        .navigationTitle("Reply")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(store.isSending)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(store.isSending ? "Sending…" : "Send") {
                    Swift.Task { await send() }
                }
                .disabled(!store.canSend)
                .accessibilityIdentifier("reply.send")
            }
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { store.dismissError() }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.dismissError() } }
        )
    }

    private func send() async {
        guard let updatedTask = await store.send(taskID: task.id, using: settings.configuredService) else { return }
        onSent(updatedTask)
        dismiss()
    }
}
