import SwiftUI

struct TaskDetailView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppState.self) private var appState
    let taskID: String

    @State private var store = TaskDetailStore()
    @State private var replyStore = ReplyStore()
    @State private var showsMetadata = false
    @State private var showsExecutionDetails = false

    var body: some View {
        content
        .background(Color.white)
        .navigationTitle("Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.task != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsMetadata = true
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Conversation details")
                    .accessibilityIdentifier("task.metadata")
                }
            }
        }
        .task { await load() }
        .onChange(of: appState.refreshToken) { _, _ in
            Swift.Task { await load(showOverlay: store.task == nil) }
        }
        .sheet(isPresented: $showsMetadata) {
            if let task = store.task {
                TaskMetadataView(task: task)
            }
        }
        .alert("Could Not Load Conversation", isPresented: loadErrorBinding) {
            Button("Retry") { Swift.Task { await load() } }
            Button("OK", role: .cancel) { store.dismissError() }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .alert("Could Not Send Reply", isPresented: replyErrorBinding) {
            Button("OK") { replyStore.dismissError() }
        } message: {
            Text(replyStore.errorMessage ?? "")
        }
    }

    private var content: AnyView {
        if let task = store.task {
            return conversation(task)
        }
        if store.isLoading {
            return AnyView(ProgressView("Loading conversation…"))
        }
        return AnyView(ContentUnavailableView("Conversation Not Loaded", systemImage: "bubble.left.and.exclamationmark.bubble.right"))
    }

    private func conversation(_ task: Task) -> AnyView {
        AnyView(
            conversationScroll(task)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    replyInset(for: task)
                }
        )
    }

    private func conversationScroll(_ task: Task) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                conversationHeader(task)
                requestMessage(for: task)
                agentMessage(for: task)
                logMessage(for: task)
                userMessage(for: task)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await load(showOverlay: false) }
    }

    @ViewBuilder
    private func requestMessage(for task: Task) -> some View {
        if let context = task.context, !context.isEmpty {
            ConversationMessage(role: "Request", systemImage: "person.fill", text: context)
        }
    }

    @ViewBuilder
    private func agentMessage(for task: Task) -> some View {
        if !task.body.isEmpty {
            ConversationMessage(role: "Agent", systemImage: "sparkles", text: task.body)
        }
    }

    @ViewBuilder
    private func logMessage(for task: Task) -> some View {
        if let logs = task.logs, !logs.isEmpty {
            executionDetails(logs)
        }
    }

    @ViewBuilder
    private func userMessage(for task: Task) -> some View {
        if let reply = task.reply, !reply.isEmpty {
            ConversationMessage(role: "You", systemImage: "person.fill", text: reply, isUser: true)
        }
    }

    @ViewBuilder
    private func replyInset(for task: Task) -> some View {
        if task.reply == nil {
            ReplyComposer(store: replyStore) {
                await sendReply(for: task)
            }
        }
    }

    private func conversationHeader(_ task: Task) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title)
                .font(.largeTitle.bold())
                .foregroundStyle(Color.black)
                .textSelection(.enabled)

            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor(for: task))
                    .frame(width: 7, height: 7)
                Text(task.displayStatus.capitalized)
                if !task.updatedAt.isEmpty {
                    Text("·")
                    Text(task.displayListTimestamp)
                }
            }
            .font(.subheadline)
            .foregroundStyle(Color.black.opacity(0.5))
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func executionDetails(_ logs: String) -> some View {
        DisclosureGroup(isExpanded: $showsExecutionDetails) {
            ScrollView(.horizontal) {
                Text(logs)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.72))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 14)
            }
        } label: {
            Label("Execution details", systemImage: "terminal")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.black.opacity(0.7))
        }
        .padding(16)
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var loadErrorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.dismissError() } }
        )
    }

    private var replyErrorBinding: Binding<Bool> {
        Binding(
            get: { replyStore.errorMessage != nil },
            set: { if !$0 { replyStore.dismissError() } }
        )
    }

    private func load(showOverlay: Bool = true) async {
        await store.load(taskID: taskID, using: settings.configuredService, showOverlay: showOverlay)
    }

    private func sendReply(for task: Task) async {
        guard let updatedTask = await replyStore.send(taskID: task.id, using: settings.configuredService) else { return }
        store.apply(updatedTask)
        appState.requestRefresh()
    }

    private func statusColor(for task: Task) -> Color {
        switch task.statusKind {
        case .pending: .blue
        case .success: .green
        case .failure: .red
        case .unknown: Color.black.opacity(0.3)
        }
    }
}

private struct ConversationMessage: View {
    let role: String
    let systemImage: String
    let text: String
    var isUser = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(role, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.black.opacity(0.68))

            Text(text)
                .font(.body)
                .foregroundStyle(Color.black.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(isUser ? 16 : 0)
        .background {
            if isUser {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.045))
            }
        }
    }
}

private struct ReplyComposer: View {
    @Bindable var store: ReplyStore
    let send: () async -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Reply to the agent", text: $store.replyText, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .accessibilityIdentifier("reply.text")

            Button {
                Swift.Task { await send() }
            } label: {
                ZStack {
                    Circle()
                        .fill(store.canSend ? Color.black : Color.black.opacity(0.16))
                        .frame(width: 38, height: 38)

                    if store.isSending {
                        ProgressView()
                            .tint(.white)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .disabled(!store.canSend)
            .accessibilityLabel(store.isSending ? "Sending reply" : "Send reply")
            .accessibilityIdentifier("reply.send")
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.shadow(color: Color.black.opacity(0.06), radius: 8, y: -3))
    }
}

private struct TaskMetadataView: View {
    @Environment(\.dismiss) private var dismiss
    let task: Task

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    LabeledContent("Status", value: task.displayStatus)
                    if !task.createdAt.isEmpty {
                        LabeledContent("Created", value: task.displayCreatedAt)
                    }
                    if !task.updatedAt.isEmpty {
                        LabeledContent("Updated", value: task.displayUpdatedAt)
                    }
                }

                Section("Identifier") {
                    Text(task.id)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.light)
    }
}
