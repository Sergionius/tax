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

    private var screenTitle: String {
        path.isEmpty ? "Files" : URL(fileURLWithPath: path).lastPathComponent
    }

    var body: some View {
        List(entries) { entry in
            NavigationLink(value: RemoteFileRoute(workspaceID: workspaceID, path: entry.path, isDirectory: entry.isDirectory)) {
                FileEntryCard(entry: entry, showsPath: !search.isEmpty)
            }
            .buttonStyle(WorkspaceCardButtonStyle())
            .workspaceCardListRow()
        }
        .listStyle(.plain)
        .overlay {
            if entries.isEmpty {
                WorkspaceEmptyState(
                    title: search.isEmpty ? "Empty folder" : "No matching files",
                    icon: search.isEmpty ? "folder" : "magnifyingglass"
                )
            }
        }
        .workspaceScreenTheme()
        .workspaceScreenBackground()
        .navigationTitle(screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .workspacePrincipalTitle(screenTitle)
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
}

/// File or folder card: existing standard icons in the accent palette,
/// name and path in JetBrains Mono. Technical-directory icons are dimmed,
/// but the directories themselves stay visible, unspecial-cased and accessible.
private struct FileEntryCard: View {
    let entry: RemoteFileEntry
    let showsPath: Bool

    /// Technical directories: dot-prefixed and listed service folders.
    /// Affects only the icon styling — not visibility, ordering or accessibility.
    private var isTechnicalDirectory: Bool {
        guard entry.isDirectory else { return false }
        let technicalNames = ["__pycache__", "node_modules", "venv", "config", "configs"]
        return entry.name.hasPrefix(".") || technicalNames.contains(entry.name.lowercased())
    }

    private var iconColor: Color {
        if entry.isDirectory {
            return isTechnicalDirectory ? WorkspaceTheme.textDim : WorkspaceTheme.accent
        }
        return WorkspaceTheme.accentDim
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : icon(for: entry.path))
                .font(.workspaceUI(.title3))
                .foregroundStyle(iconColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.workspaceMono(.body, weight: .medium))
                    .foregroundStyle(WorkspaceTheme.textHi)
                    .lineLimit(1)
                if showsPath {
                    Text(entry.path)
                        .font(.workspaceMono(.caption2))
                        .foregroundStyle(WorkspaceTheme.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
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

    private var fileName: String { URL(fileURLWithPath: path).lastPathComponent }

    var body: some View {
        Group {
            if let document = store.openDocument,
               document.workspaceID == workspaceID,
               document.path == path {
                if document.kind == "image" { RemoteImageView(document: document) }
                else { RemoteTextEditorView(documentID: document.id) }
            } else {
                WorkspaceLoadingState(text: "Loading…", fillsScreen: true)
            }
        }
        .workspaceScreenTheme()
        .workspaceScreenBackground()
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .workspacePrincipalTitle(fileName)
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
                WorkspaceEmptyState(title: "Unsupported image", icon: "photo.badge.exclamationmark")
            }
        }
        .workspaceScreenBackground()
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
                    Text(markdown: text)
                        .font(.workspaceUI(.body))
                        .foregroundStyle(WorkspaceTheme.textHi)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(WorkspaceTheme.cardPadding)
                }
            } else {
                TextEditor(text: $text)
                    .workspaceEditorChrome()
                    .padding(.horizontal, 14)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
        .onAppear { text = document?.text ?? "" }
        .onChange(of: document?.revision) { _, _ in text = document?.text ?? "" }
        .onChange(of: text) { _, value in store.updateOpenDocument(text: value) }
        .navigationBarBackButtonHidden(document?.isModified == true)
        .toolbar {
            if document?.isModified == true {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showDiscard = true
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.workspaceUI(.body, weight: .medium))
                            .foregroundStyle(WorkspaceTheme.accentLight)
                    }
                    .accessibilityLabel("Back")
                }
            }
            if isMarkdown {
                ToolbarItem {
                    Button { showMarkdown.toggle() } label: {
                        Text(showMarkdown ? "Edit" : "Preview")
                            .font(.workspaceUI(.body, weight: .medium))
                            .foregroundStyle(WorkspaceTheme.accentLight)
                    }
                }
            }
            ToolbarItem {
                Button {
                    Swift.Task { await store.saveOpenDocument() }
                } label: {
                    Text("Save")
                        .font(.workspaceUI(.body, weight: .medium))
                        .foregroundStyle(WorkspaceTheme.accentLight)
                }
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
    /// Renders Markdown with native SwiftUI styled to the theme palette: body text
    /// inherits Space Grotesk and `text-hi`, links use the light accent, and monospace
    /// fragments (inline code and code blocks) use JetBrains Mono on the `surface-2` color.
    init(markdown source: String) {
        guard var attributed = try? AttributedString(markdown: source) else {
            self.init(verbatim: source)
            return
        }
        // Collect ranges first, then apply styles — mutation during iteration is invalid.
        var codeRanges: [Range<AttributedString.Index>] = []
        for (intent, range) in attributed.runs[\.inlinePresentationIntent] {
            guard let intent, intent.contains(.code) else { continue }
            codeRanges.append(range)
        }
        for (intent, range) in attributed.runs[\.presentationIntent] {
            guard let intent,
                  intent.components.contains(where: { if case .codeBlock = $0.kind { return true } else { return false } })
            else { continue }
            codeRanges.append(range)
        }
        var linkRanges: [Range<AttributedString.Index>] = []
        for (link, range) in attributed.runs[\.link] {
            guard link != nil else { continue }
            linkRanges.append(range)
        }
        for range in codeRanges {
            attributed[range].swiftUI.font = .workspaceMono(.body)
            attributed[range].swiftUI.foregroundColor = WorkspaceTheme.accentLight
            attributed[range].swiftUI.backgroundColor = WorkspaceTheme.surface2
        }
        for range in linkRanges {
            attributed[range].swiftUI.foregroundColor = WorkspaceTheme.accentLight
        }
        self.init(attributed)
    }
}
