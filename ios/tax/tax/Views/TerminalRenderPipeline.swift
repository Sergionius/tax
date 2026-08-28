import Foundation

@MainActor
final class TerminalRenderPipeline: TerminalRendererDelegate {
    weak var surface: TerminalRendererSurface?

    var onInput: (@MainActor (Data) -> Void)?
    var onViewportReady: (@MainActor (TerminalRendererViewport) -> Void)?
    var onViewportChanged: (@MainActor (TerminalRendererViewport) -> Void)?
    var onSnapshotApplied: (@MainActor () -> Void)?

    private(set) var rendererReady = false
    private(set) var snapshotReceived = false
    private(set) var snapshotApplied = false
    private var readyViewport: TerminalRendererViewport?
    private var lastSequence: UInt64 = 0
    private var pendingSnapshot: TerminalRenderUpdate?
    private var queuedOutput = Data()
    private var isApplyingSnapshot = false
    private var applyingSnapshotSequence: UInt64?
    private var viewportTask: Swift.Task<Void, Never>?
    private var pendingViewport: TerminalRendererViewport?

    func enqueue(_ update: TerminalRenderUpdate) {
        guard update.sequence > lastSequence else { return }
        lastSequence = update.sequence
        if update.resetsTerminal {
            pendingSnapshot = update
            queuedOutput.removeAll(keepingCapacity: true)
            snapshotReceived = true
            snapshotApplied = false
        } else {
            queuedOutput.append(update.data)
        }
        flush()
    }

    /// Called whenever a renderer view is mounted. Network state remains in the pipeline,
    /// but the new surface must report its own measured viewport before it is used.
    func rendererDidMount() {
        rendererReady = false
        readyViewport = nil
        pendingViewport = nil
        viewportTask?.cancel()
        viewportTask = nil
        snapshotApplied = false
    }

    func rendererDidBecomeReady(viewport: TerminalRendererViewport) {
        guard viewport.columns > 0, viewport.rows > 0 else { return }
        if rendererReady {
            rendererViewportDidChange(viewport)
            return
        }
        rendererReady = true
        readyViewport = viewport
        onViewportReady?(viewport)
        flush()
    }

    func rendererViewportDidChange(_ viewport: TerminalRendererViewport) {
        guard rendererReady, viewport.columns > 0, viewport.rows > 0 else { return }
        guard viewport != readyViewport || pendingViewport != viewport else { return }
        pendingViewport = viewport
        viewportTask?.cancel()
        viewportTask = Swift.Task { [weak self] in
            try? await Swift.Task.sleep(for: .milliseconds(180))
            guard !Swift.Task.isCancelled, let self else { return }
            pendingViewport = nil
            guard viewport != readyViewport else { return }
            readyViewport = viewport
            onViewportChanged?(viewport)
        }
    }

    func rendererDidReceiveInput(_ data: Data) {
        onInput?(data)
    }

    func rendererDidCompleteSnapshot() {
        isApplyingSnapshot = false
        applyingSnapshotSequence = nil
        // A newer snapshot supersedes this completion. Its output must be the
        // first content reported as applied for the current generation.
        guard pendingSnapshot == nil else {
            snapshotApplied = false
            flush()
            return
        }
        snapshotApplied = true
        onSnapshotApplied?()
        flush()
    }

    private func flush() {
        guard rendererReady else { return }
        guard !isApplyingSnapshot else { return }
        if let snapshot = pendingSnapshot {
            pendingSnapshot = nil
            isApplyingSnapshot = true
            applyingSnapshotSequence = snapshot.sequence
            surface?.apply(update: snapshot) { [weak self] in
                self?.rendererDidCompleteSnapshot()
            }
            return
        }
        if !queuedOutput.isEmpty {
            let data = queuedOutput
            queuedOutput.removeAll(keepingCapacity: true)
            surface?.apply(
                update: TerminalRenderUpdate(sequence: lastSequence, generation: pendingSnapshot?.generation, resetsTerminal: false, data: data),
                completion: nil
            )
        }
    }
}
