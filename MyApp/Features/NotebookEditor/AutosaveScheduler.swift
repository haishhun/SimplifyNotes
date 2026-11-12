import Foundation

/// Debounced autosave: saves shortly after the user pauses, but never lets unsaved
/// work age beyond `maxDelay` during continuous writing. `flush()` saves immediately
/// (page switches, app backgrounding, closing the editor).
@MainActor
final class AutosaveScheduler {
    private let idleDelay: Duration
    private let maxDelay: TimeInterval
    private var task: Task<Void, Never>?
    private var firstPendingAt: Date?
    private(set) var isPending = false
    private let onSave: () -> Void

    init(idleDelay: Duration = .milliseconds(800), maxDelay: TimeInterval = 4, onSave: @escaping () -> Void) {
        self.idleDelay = idleDelay
        self.maxDelay = maxDelay
        self.onSave = onSave
    }

    func markDirty() {
        isPending = true
        let now = Date.now
        if firstPendingAt == nil { firstPendingAt = now }
        task?.cancel()
        if let first = firstPendingAt, now.timeIntervalSince(first) >= maxDelay {
            flush()
            return
        }
        task = Task { [weak self, idleDelay] in
            try? await Task.sleep(for: idleDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        task?.cancel()
        task = nil
        guard isPending else { return }
        isPending = false
        firstPendingAt = nil
        onSave()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
