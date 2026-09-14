import SwiftUI
import SwiftTerm
import UIKit

struct SwiftTermTerminalView: UIViewRepresentable {
    let pipeline: TerminalRenderPipeline

    func makeCoordinator() -> Coordinator {
        Coordinator(pipeline: pipeline)
    }

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        var options = TerminalOptions.default
        options.scrollback = 5000
        let view = SwiftTerm.TerminalView(frame: .zero, font: font, options: options)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.nativeBackgroundColor = UIColor(red: 16 / 255, green: 17 / 255, blue: 20 / 255, alpha: 1)
        view.nativeForegroundColor = .white
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.showsVerticalScrollIndicator = true
        view.isUserInteractionEnabled = true
        view.terminalDelegate = context.coordinator
        context.coordinator.terminalView = view
        pipeline.rendererDidMount()
        pipeline.surface = context.coordinator
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {}

    static func dismantleUIView(_ uiView: SwiftTerm.TerminalView, coordinator: Coordinator) {
        uiView.terminalDelegate = nil
        coordinator.terminalView = nil
        coordinator.pipeline?.surface = nil
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate, TerminalRendererSurface {
        weak var pipeline: TerminalRenderPipeline?
        weak var terminalView: SwiftTerm.TerminalView?

        init(pipeline: TerminalRenderPipeline) {
            self.pipeline = pipeline
        }

        func apply(update: TerminalRenderUpdate, completion: (@MainActor () -> Void)?) {
            guard let terminalView = terminalView else {
                completion?()
                return
            }
            let terminal = terminalView.getTerminal()
            if update.resetsTerminal {
                terminal.resetToInitialState()
                terminal.clearScrollback()
            }
            terminal.feed(byteArray: Array(update.data))
            completion?()
        }

        func requestFocus() {
            _ = terminalView?.becomeFirstResponder()
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            pipeline?.rendererDidReceiveInput(Data(data))
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            let viewport = TerminalRendererViewport(columns: newCols, rows: newRows)
            pipeline?.rendererDidBecomeReady(viewport: viewport)
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
        func bell(source: SwiftTerm.TerminalView) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
        func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
