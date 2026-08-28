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
                    if !store.terminalSnapshotReady {
                        ProgressView("Loading terminal…")
                            .tint(.white)
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(.black.opacity(0.72), in: .rect(cornerRadius: 12))
                    } else if store.terminalReconnectInProgress {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Reconnecting…")
                        }
                        .tint(.white)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.72), in: .capsule)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 8)
                    }
                }
                .allowsHitTesting(false)

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
                }.padding(8)
            }.background(.bar)
        }
        .navigationTitle(terminal.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings.terminalRenderer) { _, _ in
            store.rendererDidChange()
        }
        .onAppear {
            pipeline.onInput = { data in
                Swift.Task { await store.sendInput(terminalID: terminal.id, data: data) }
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

    private func control(_ text: String) -> Data {
        guard let scalar = text.lowercased().unicodeScalars.first, scalar.value >= 96, scalar.value <= 127 else { return Data(text.utf8) }
        return Data([UInt8(scalar.value - 96)])
    }
}
