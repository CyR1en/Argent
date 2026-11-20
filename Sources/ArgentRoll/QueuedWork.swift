import Foundation

/// Runs blocking work on an `OperationQueue` from async code, so a bounded number of decodes
/// run at once and the cooperative thread pool never blocks.
///
/// Cancelling the awaiting task cancels the operation if it has not started, which is what
/// lets a contact sheet drop the decodes of frames scrolled past. The caller always gets an
/// answer: the work's result, or `nil` when it was cancelled before it ran.
enum QueuedWork {
    private final class Slot<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ newValue: T?) { lock.withLock { value = newValue } }
        /// The result, handed over once: a finished operation can outlive its caller in a
        /// dependency or a table of pending work, and must not keep a decode alive.
        func take() -> T? {
            lock.withLock {
                defer { value = nil }
                return value
            }
        }
    }

    /// `prepare` sees the operation just before it is queued, so a caller can make it wait for
    /// another job, such as a decode of the same frame already queued, and record it for later
    /// jobs to wait on, under one lock. A cancelled job stops waiting.
    static func run<T>(on queue: OperationQueue, priority: Operation.QueuePriority = .normal,
                       prepare: ((Operation) -> Void)? = nil,
                       _ work: @escaping @Sendable () -> T?) async -> T? {
        await runStoppable(on: queue, priority: priority, prepare: prepare) { _ in work() }
    }

    /// The same, for work that can stop part way: `stopped` says when the awaiting task has been
    /// cancelled since the work began, so a long read can stop between its pieces.
    static func runStoppable<T>(on queue: OperationQueue, priority: Operation.QueuePriority = .normal,
                                prepare: ((Operation) -> Void)? = nil,
                                _ work: @escaping @Sendable (_ stopped: () -> Bool) -> T?) async -> T? {
        let slot = Slot<T>()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in slot.set(work { operation?.isCancelled ?? true }) }
        operation.queuePriority = priority
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                // A cancelled operation still finishes, so this runs exactly once either way.
                operation.completionBlock = { continuation.resume(returning: slot.take()) }
                prepare?(operation)
                queue.addOperation(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }
}
