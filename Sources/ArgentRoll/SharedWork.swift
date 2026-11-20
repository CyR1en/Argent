import Foundation

/// Work shared by everyone who asks for the same thing while it is being made, and given up once nobody waits for it: one task a
/// key, joined by each asker, and cancelled when the last asker's own task is. An asker that arrives after that starts it again.
///
/// `BundledSmartMasks` makes a frame's input picture this way. The Masks tab asks ahead for the frame it shows and a click joins
/// that, so a click never decodes a second time; and a frame the tab has left, which nobody clicked on, is not decoded for nothing
/// (`MaskInference.tabShows`). Safe to call from any thread.
final class SharedWork<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    /// One key's work, under `lock`.
    private final class Entry: @unchecked Sendable {
        let task: Task<Value?, Never>
        var waiters = 1
        init(task: Task<Value?, Never>) { self.task = task }
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    /// `make`'s value for `key`: from the work under way for it, or from `make`, started now on a task of its own. `nil` when
    /// `make` gives none, which it does once cancelled if it heeds its task's cancellation.
    func value(for key: Key, priority: TaskPriority? = nil, _ make: @escaping @Sendable () async -> Value?) async -> Value? {
        let entry: Entry = lock.withLock {
            if let entry = entries[key] {
                entry.waiters += 1
                return entry
            }
            let entry = Entry(task: Task.detached(priority: priority) { await make() })
            entries[key] = entry
            return entry
        }
        let made = await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            // This asker let go. The work stops with its last asker, and is no longer there to join: whoever asks next starts it again.
            let wasLast = lock.withLock { () -> Bool in
                entry.waiters -= 1
                guard entry.waiters == 0 else { return false }
                if entries[key] === entry { entries[key] = nil }
                return true
            }
            if wasLast { entry.task.cancel() }
        }
        lock.withLock { if entries[key] === entry { entries[key] = nil } }
        return made
    }

    /// How many askers wait for `key`'s work, 0 when none is under way to join. For the tests.
    func askers(of key: Key) -> Int { lock.withLock { entries[key]?.waiters ?? 0 } }
}
