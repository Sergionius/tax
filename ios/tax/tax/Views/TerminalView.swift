import SwiftUI

struct TerminalView: View {
    let terminal: RemoteTerminal
    @Environment(RemoteWorkspaceStore.self) private var store
    @State private var controlArmed = false

    private var buffer: Data {
        guard let streamID = store.activeStreamID else { return Data() }
        return store.terminalBuffers[streamID] ?? Data()
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalWebView(data: buffer) { text in
                Swift.Task { await store.sendInput(terminalID: terminal.id, text: controlArmed ? control(text) : text); controlArmed = false }
            } onResize: { columns, rows in
                Swift.Task { await store.resize(terminalID: terminal.id, columns: columns, rows: rows) }
            }
            .background(Color(red: 0.06, green: 0.067, blue: 0.08))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    key("esc", "\u{1B}")
                    key("tab", "\t")
                    Button(controlArmed ? "Ctrl ✓" : "Ctrl") { controlArmed.toggle() }.buttonStyle(.bordered)
                    key("C", "\u{3}")
                    key("←", "\u{1B}[D"); key("↑", "\u{1B}[A"); key("↓", "\u{1B}[B"); key("→", "\u{1B}[C")
                    key("enter", "\r")
                }.padding(8)
            }.background(.bar)
        }
        .navigationTitle(terminal.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.subscribe(terminalID: terminal.id) }
    }

    private func key(_ title: String, _ value: String) -> some View {
        Button(title) { Swift.Task { await store.sendInput(terminalID: terminal.id, text: value) } }.buttonStyle(.bordered)
    }

    private func control(_ text: String) -> String {
        guard let scalar = text.lowercased().unicodeScalars.first, scalar.value >= 96, scalar.value <= 127 else { return text }
        return String(UnicodeScalar(scalar.value - 96)!)
    }
}
