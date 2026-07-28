import SwiftUI

struct TaskDetailView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppState.self) private var appState
    let taskID: String

    @State private var store = TaskDetailStore()
    @State private var showsReply = false

    var body: some View {
        Group {
            if let task = store.task {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header(task)
                        DetailSection(title: "Body", text: task.body)
                        DetailSection(title: "Context", text: task.context)
                        DetailSection(title: "Logs", text: task.logs, monospaced: true)
                        DetailSection(title: "Reply", text: task.reply)
                    }
                    .padding()
                }
            } else if store.isLoading {
                ProgressView("Loading task…")
            } else {
                ContentUnavailableView("Task Not Loaded", systemImage: "doc.text.magnifyingglass")
            }
        }
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reply") { showsReply = true }
                    .disabled(store.task == nil)
                    .accessibilityIdentifier("task.reply")
            }
        }
        .task { await load() }
        .refreshable { await load(showOverlay: false) }
        .onChange(of: appState.refreshToken) { _, _ in
            Swift.Task { await load(showOverlay: store.task == nil) }
        }
        .sheet(isPresented: $showsReply) {
            if let task = store.task {
                NavigationStack {
                    ReplyView(task: task) { updatedTask in
                        store.apply(updatedTask)
                        appState.requestRefresh()
                    }
                }
            }
        }
        .alert("Error", isPresented: errorBinding) {
            Button("Retry") { Swift.Task { await load() } }
            Button("OK", role: .cancel) { store.dismissError() }
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

    private func header(_ task: Task) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(task.title)
                .font(.title2.bold())
            LabeledContent("Status", value: task.displayStatus)
            if !task.createdAt.isEmpty { LabeledContent("Created", value: task.displayCreatedAt) }
            if !task.updatedAt.isEmpty { LabeledContent("Updated", value: task.displayUpdatedAt) }
            Text(task.id)
                .font(.caption)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load(showOverlay: Bool = true) async {
        await store.load(taskID: taskID, using: settings.configuredService, showOverlay: showOverlay)
    }
}

private struct DetailSection: View {
    let title: String
    let text: String?
    var monospaced = false

    var body: some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
