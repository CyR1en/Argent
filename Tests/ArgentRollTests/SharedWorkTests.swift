import Foundation
import Testing
@testable import ArgentRoll

/// `SharedWork`: one piece of work a key, joined by whoever asks for it meanwhile, given up when its last asker lets go, and started
/// again by whoever asks next. What `BundledSmartMasks` makes a frame's input picture with.
@Suite struct SharedWorkTests {
    /// Work that waits until it is let through, counts its starts, and notes each time it was cancelled while it waited.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0, stopped = 0, isOpen = false
        var starts: Int { lock.withLock { started } }
        var cancelled: Int { lock.withLock { stopped } }
        func open() { lock.withLock { isOpen = true } }

        /// Its own number, the first 1, or `nil` if it was cancelled first.
        func work() async -> Int? {
            let number = lock.withLock { () -> Int in started += 1; return started }
            while !lock.withLock({ isOpen }) {
                if Task.isCancelled {
                    lock.withLock { stopped += 1 }
                    return nil
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return number
        }
    }

    private func settled(_ condition: @Sendable () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func askersOfOneKeyShareOneMaking() async {
        let shared = SharedWork<String, Int>(), gate = Gate()
        let first = Task { await shared.value(for: "a") { await gate.work() } }
        let second = Task { await shared.value(for: "a") { await gate.work() } }
        let other = Task { await shared.value(for: "b") { await gate.work() } }
        await settled { shared.askers(of: "a") == 2 && shared.askers(of: "b") == 1 && gate.starts == 2 }
        #expect(shared.askers(of: "a") == 2 && shared.askers(of: "b") == 1 && gate.starts == 2, "one making a key")
        gate.open()
        let values = await [first.value, second.value, other.value]
        #expect(values[0] != nil && values[0] == values[1] && values[2] != nil && values[2] != values[0])
        #expect(gate.starts == 2 && gate.cancelled == 0 && shared.askers(of: "a") == 0 && shared.askers(of: "b") == 0)
        // Made, it is no longer there to join: the next asker makes it again (a caller keeps what it wants kept).
        #expect(await shared.value(for: "a") { await gate.work() } == 3)
    }

    /// One asker letting go leaves the work to the others: the tab's ask ahead cancelled while a click waits for the same picture.
    @Test func anAskerLettingGoLeavesTheWorkToTheOthers() async {
        let shared = SharedWork<String, Int>(), gate = Gate()
        let ahead = Task { await shared.value(for: "a") { await gate.work() } }
        let click = Task { await shared.value(for: "a") { await gate.work() } }
        await settled { shared.askers(of: "a") == 2 }
        ahead.cancel()
        await settled { shared.askers(of: "a") == 1 }
        #expect(shared.askers(of: "a") == 1 && gate.cancelled == 0)
        gate.open()
        #expect(await click.value == 1 && gate.starts == 1 && gate.cancelled == 0)
        _ = await ahead.value
    }

    /// The last asker letting go gives the work up, and whoever asks next starts it again rather than joining what was given up.
    @Test func theLastAskerLettingGoGivesItUpAndTheNextStartsItAgain() async {
        let shared = SharedWork<String, Int>(), gate = Gate()
        let ahead = Task { await shared.value(for: "a") { await gate.work() } }
        await settled { shared.askers(of: "a") == 1 && gate.starts == 1 }
        ahead.cancel()
        #expect(await ahead.value == nil)
        #expect(gate.cancelled == 1 && shared.askers(of: "a") == 0)
        let click = Task { await shared.value(for: "a") { await gate.work() } }
        await settled { gate.starts == 2 }
        gate.open()
        #expect(await click.value == 2 && gate.cancelled == 1)
        // An asker already cancelled as it asks gives up what it started.
        let late = Gate()
        let gone = Task { () -> Int? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await shared.value(for: "c") { await late.work() }
        }
        #expect(await gone.value == nil && late.cancelled == 1 && shared.askers(of: "c") == 0)
    }
}
