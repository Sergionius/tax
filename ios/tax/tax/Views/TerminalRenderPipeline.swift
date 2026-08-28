import Foundation

@MainActor
final class TerminalRenderPipeline: TerminalRendererDelegate {
    weak var surface: TerminalRendererSurface?

    var onInput: (@MainActor (Data) -> Void)?
    var onViewportReady: (@MainActor (TerminalRendererViewport) -> Void)?
    var onViewportChanged: (@MainActor (TerminalRendererViewport) -> Void)?
    var onSnapshotApplied: (@MainActor () -> Void)?

    private var isReady = false
    private var readyViewport: TerminalRendererViewport?
    private var lastSequence: UInt64 = 0
    private var pendingSnapshot: TerminalRenderUpdate?
    private var queuedOutput = Data()
    private var isApplyingSnapshot = false

    func enqueue(_ update: TerminalRenderUpdate) {
        guard update.sequence > lastSequence else { return }
        lastSequence = update.sequence
        if update.resetsTerminal {
            pendingSnapshot = update
            queuedOutput.removeAll(keepingCapacity: true)
        } else {
            queuedOutput.append(update.data)
        }
        flush()
    }

    func rendererDidBecomeReady(viewport: TerminalRendererViewport) {
        guard !isReady else {
            if viewport != readyViewport {
                readyViewport = viewport
                onViewportChanged?(viewport)
            }
            return
        }
        isReady = true
        readyViewport = viewport
        onViewportReady?(viewport)
        flush()
    }

    func rendererViewportDidChange(_ viewport: TerminalRendererViewport) {
        guard isReady else { return }
        readyViewport = viewport
        onViewportChanged?(viewport)
    }

    func rendererDidReceiveInput(_ data: Data) {
        onInput?(data)
    }

    func rendererDidCompleteSnapshot() {
        isApplyingSnapshot = false
        onSnapshotApplied?()
        flush()
    }

    private func flush() {
        guard isReady else { return }
        guard !isApplyingSnapshot else { return }
        if let snapshot = pendingSnapshot {
            pendingSnapshot = nil
            isApplyingSnapshot = true
            surface?.apply(update: snapshot) { [weak self] in
                self?.rendererDidCompleteSnapshot()
            }
            return
        }
        if !queuedOutput.isEmpty {
            let data = queuedOutput
            queuedOutput.removeAll(keepingCapacity: true)
            surface?.apply(
                update: TerminalRenderUpdate(sequence: lastSequence, resetsTerminal: false, data: data),
                completion: nil
            )
        }
    }
}
