import SwiftUI

struct TerminalView: View {
    let terminal: RemoteTerminal
    @Environment(RemoteWorkspaceStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @State private var pipeline = TerminalRenderPipeline()
    @State private var controlArmed = false

    var body: some View {
        VStack(spacing: 0) {
            TerminalRendererHost(pipeline: pipeline)
                .id(settings.terminalRenderer)
                .background(Color(red: 0.06, green: 0.067, blue: 0.08))
                .onChange(of: store.terminalRenderUpdate) { _, update in
                    pipeline.enqueue(update)
                }
                .overlay {
                    Group {
                        if !store.terminalSnapshotReady {
                            ProgressView("Loading terminal…")
                                .tint(.white)
                                .foregroundStyle(.white)
                                .padding(14)
                                .background(.black.opacity(0.72), in: .rect(cornerRadius: 12))
                        }
                    }
                    .allowsHitTesting(false)
                }

            if settings.terminalRenderer == .xterm {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        key("esc", Data([0x1B]))
                        key("tab", Data([0x09]))
                        Button(controlArmed ? "Ctrl ✓" : "Ctrl") { controlArmed.toggle() }.buttonStyle(.bordered)
                        key("C", Data([0x03]))
                        key("←", Data([0x1B, 0x5B, 0x44]))
                        key("↑", Data([0x1B, 0x5B, 0x41]))
                        key("↓", Data([0x1B, 0x5B, 0x42]))
                        key("→", Data([0x1B, 0x5B, 0x43]))
                        key("enter", Data([0x0D]))
                    }
                    .padding(8)
                }
                .background(.bar)
            }
        }
        .navigationTitle(terminal.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color(red: 0.06, green: 0.067, blue: 0.08), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionStatus(
                    state: store.connectionState,
                    terminalReconnectInProgress: store.terminalReconnectInProgress
                )
            }
        }
        .onChange(of: settings.terminalRenderer) { _, _ in
            store.rendererDidChange()
        }
        .onAppear {
            pipeline.onInput = { data in
                let input = controlArmed ? control(data) : data
                controlArmed = false
                Swift.Task { await store.sendInput(terminalID: terminal.id, data: input) }
            }
            pipeline.onViewportReady = { viewport in
                Swift.Task { await store.activateTerminal(terminalID: terminal.id, viewport: viewport) }
            }
            pipeline.onViewportChanged = { viewport in
                Swift.Task { await store.activateTerminal(terminalID: terminal.id, viewport: viewport) }
            }
            pipeline.onSnapshotApplied = {
                store.setSnapshotReady()
            }
        }
    }

    private func key(_ title: String, _ data: Data) -> some View {
        Button(title) { Swift.Task { await store.sendInput(terminalID: terminal.id, data: data) } }.buttonStyle(.bordered)
    }

    private func control(_ data: Data) -> Data {
        guard data.count == 1, let byte = data.first else { return data }
        switch byte {
        case 0x40 ... 0x5F: return Data([byte - 0x40])
        case 0x60 ... 0x7F: return Data([byte - 0x60])
        default: return data
        }
    }
}
