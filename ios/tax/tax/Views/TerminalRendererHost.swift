import SwiftUI

struct TerminalRendererHost: View {
    @Environment(SettingsStore.self) private var settings
    let pipeline: TerminalRenderPipeline

    var body: some View {
        switch settings.terminalRenderer {
        case .swiftTerm:
            SwiftTermTerminalView(pipeline: pipeline)
        case .xterm:
            TerminalWebView(pipeline: pipeline)
        }
    }
}
