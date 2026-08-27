import SwiftUI

private struct RemoteFileRoute: Hashable {
    let workspaceID: String
    let path: String
    let isDirectory: Bool
}

struct FileBrowserView: View {
    let workspaceID: String
    let path: String
    @Environment(RemoteWorkspaceStore.self) private var store
    @State private var search = ""
    @State private var searchTask: Swift.Task<Void, Never>?

    private var entries: [RemoteFileEntry] {
        search.isEmpty ? store.files(workspaceID: workspaceID, path: path) : store.fileSearchResults
    }

    var body: some View {
        List(entries) { entry in
            NavigationLink(value: RemoteFileRoute(workspaceID: workspaceID, path: entry.path, isDirectory: entry.isDirectory)) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).lineLimit(1)
                        if !search.isEmpty { Text(entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                } icon: {
                    Image(systemName: entry.isDirectory ? "folder.fill" : icon(for: entry.path))
                        .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "Empty folder" : "No matching files",
                    systemImage: search.isEmpty ? "folder" : "magnifyingglass"
                )
            }
        }
        .navigationTitle(path.isEmpty ? "Files" : URL(fileURLWithPath: path).lastPathComponent)
        .navigationDestination(for: RemoteFileRoute.self) { route in
            if route.isDirectory {
                FileBrowserView(workspaceID: route.workspaceID, path: route.path)
            } else {
                RemoteFileView(workspaceID: route.workspaceID, path: route.path)
            }
        }
        .searchable(text: $search, prompt: "Search filenames")
        .onChange(of: search) { _, query in
            searchTask?.cancel()
            searchTask = Swift.Task {
                try? await Swift.Task.sleep(for: .milliseconds(250))
                guard !Swift.Task.isCancelled else { return }
                await store.searchFiles(workspaceID: workspaceID, query: query)
            }
        }
        .task { await store.loadFiles(workspaceID: workspaceID, path: path) }
        .refreshable { await store.loadFiles(workspaceID: workspaceID, path: path) }
    }

    private func icon(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "md", "markdown": "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic": "photo"
        case "swift", "py", "js", "ts", "json", "yaml", "yml": "chevron.left.forwardslash.chevron.right"
        default: "doc"
        }
    }
}

private struct RemoteFileView: View {
    let workspaceID: String
    let path: String
    @Environment(RemoteWorkspaceStore.self) private var store

    var body: some View {
        Group {
            if let document = store.openDocument,
               document.workspaceID == workspaceID,
               document.path == path {
                if document.kind == "image" { RemoteImageView(document: document) }
                else { RemoteTextEditorView(documentID: document.id) }
            } else { ProgressView("Loading…") }
        }
        .navigationTitle(URL(fileURLWithPath: path).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.openFile(workspaceID: workspaceID, path: path) }
    }
}

private struct RemoteImageView: View {
    let document: RemoteFileDocument

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            if let image = UIImage(data: document.data) {
                Image(uiImage: image).resizable().scaledToFit().padding()
            } else {
                ContentUnavailableView("Unsupported image", systemImage: "photo.badge.exclamationmark")
            }
        }
    }
}

private struct RemoteTextEditorView: View {
    let documentID: String
    @Environment(RemoteWorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var showMarkdown = false
    @State private var showDiscard = false

    private var document: RemoteFileDocument? {
        guard store.openDocument?.id == documentID else { return nil }
        return store.openDocument
    }

    private var isMarkdown: Bool {
        guard let path = document?.path.lowercased() else { return false }
        return path.hasSuffix(".md") || path.hasSuffix(".markdown")
    }

    var body: some View {
        Group {
            if showMarkdown {
                ScrollView {
                    Text(markdown: text).frame(maxWidth: .infinity, alignment: .leading).padding()
                }
            } else {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 4)
            }
        }
        .onAppear { text = document?.text ?? "" }
        .onChange(of: document?.revision) { _, _ in text = document?.text ?? "" }
        .onChange(of: text) { _, value in store.updateOpenDocument(text: value) }
        .navigationBarBackButtonHidden(document?.isModified == true)
        .toolbar {
            if document?.isModified == true {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showDiscard = true } label: { Label("Back", systemImage: "chevron.left") }
                }
            }
            if isMarkdown {
                ToolbarItem { Button(showMarkdown ? "Edit" : "Preview") { showMarkdown.toggle() } }
            }
            ToolbarItem {
                Button("Save") { Swift.Task { await store.saveOpenDocument() } }
                    .disabled(document?.isModified != true || store.isSavingFile)
            }
        }
        .alert("File changed on the Mac", isPresented: Binding(get: { store.fileConflict }, set: { store.fileConflict = $0 })) {
            Button("Reload", role: .destructive) {
                if let document { Swift.Task { await store.openFile(workspaceID: document.workspaceID, path: document.path) } }
            }
            Button("Overwrite") { Swift.Task { await store.saveOpenDocument(force: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Reload to keep the Mac version, or explicitly overwrite it with this edit.") }
        .confirmationDialog("Discard unsaved changes?", isPresented: $showDiscard) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
    }
}

private extension Text {
    init(markdown: String) {
        if let attributed = try? AttributedString(markdown: markdown) { self.init(attributed) }
        else { self.init(verbatim: markdown) }
    }
}
