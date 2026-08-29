import SwiftUI

struct TerminalRendererHost: View {
    let pipeline: TerminalRenderPipeline

    var body: some View {
        SwiftTermTerminalView(pipeline: pipeline)
    }
}
