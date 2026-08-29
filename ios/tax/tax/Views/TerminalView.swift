import SwiftUI

struct TerminalView: View {
    let terminal: RemoteTerminal
    @Environment(RemoteWorkspaceStore.self) private var store
    @State private var pipeline = TerminalRenderPipeline()

    var body: some View {
        VStack(spacing: 0) {
            TerminalRendererHost(pipeline: pipeline)
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
}
