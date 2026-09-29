import Foundation

/// Completion of an actual producer, not a descriptor's published UI state.
/// Cancelling one waiter never cancels the producer or another waiter.
final class DownloadWorkCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// Returns false when this caller cancelled before observing completion.
    func wait() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                // Check and registration share the cancellation handler's lock,
                // so cancellation before registration cannot lose its wakeup.
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: false)
                } else if isFinished {
                    lock.unlock()
                    continuation.resume(returning: true)
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancelWaiter(id)
        }
    }

    /// The producer calls this after its final publication and registry cleanup.
    func finish() {
        lock.lock()
        isFinished = true
        let continuations = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(returning: false)
    }
}
