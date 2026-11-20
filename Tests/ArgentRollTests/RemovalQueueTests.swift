import Foundation
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// The queue's rules (docs/remove-plan.md, section 4.5) on the fake engine and a clock moved by hand: the idle time and the
/// silence limit pass when a test says so, and what waits on the engine waits on a condition, never on a length of time.
@Suite struct RemovalQueueTests {
    private static func job(steps: Int = 4, seed: UInt64 = 7) throws -> RemovalJob {
        let side = 16
        var image = [UInt8](repeating: 90, count: side * side * 3), mask = [UInt8](repeating: 0, count: side * side)
        for p in 0..<(side * 4) {
            mask[p] = 255
            image[p * 3] = 255
        }
        return try RemovalJob(width: side, height: side, image: image, mask: mask, steps: steps, seed: seed)
    }

    private static func steps(_ range: ClosedRange<Int>, of count: Int) -> [RemovalQueue.Progress] {
        range.map { .step($0, of: count) }
    }

    /// A queue on a fake engine and a clock at zero, with the engine's state read every millisecond.
    private static func make(_ engine: FakeRemovalEngine = FakeRemovalEngine(), silenceLimit: TimeInterval = RemovalQueue.silenceLimit)
        -> (queue: RemovalQueue, engine: FakeRemovalEngine, clock: RemovalHandClock) {
        let clock = RemovalHandClock()
        let queue = RemovalQueue(engine: engine, silenceLimit: silenceLimit, clock: clock.clock, statePoll: .milliseconds(1))
        return (queue, engine, clock)
    }

    /// The fake engine reports `.loading` for a moment the suite cannot hold, so a run that began just after a load may or may not
    /// have said so. Everything else a row hears is exact.
    private static func withoutLoading(_ heard: [RemovalQueue.Progress]) -> [RemovalQueue.Progress] {
        heard.filter { $0 != .waiting(.loading, forDevelop: false) }
    }

    // MARK: loading and the idle time

    @Test func aUseLoadsTheEngineAndNothingDoesBeforeIt() async throws {
        let (queue, engine, _) = Self.make()
        #expect(queue.state == .idle && engine.counts.loads == 0, "nothing loads at launch")
        queue.noteUse()
        #expect(engine.counts.loads == 1)
        await RemovalProof.until("the engine is ready") { engine.state == .ready }
        queue.noteUse()
        #expect(engine.counts.loads == 1 && queue.state == .ready, "what is loaded is not loaded again")
    }

    @Test func theEngineGoesAfterTheIdleTimeAndNotBefore() async throws {
        let (queue, engine, clock) = Self.make()
        queue.noteUse()
        await RemovalProof.until("the engine is ready") { engine.state == .ready }
        await clock.waitForSleepers(1)
        #expect(clock.advance(by: RemovalQueue.idleUnload - 1) == 0, "a second short of the idle time nothing has run out")
        #expect(engine.counts.unloads == 0 && engine.state == .ready)
        #expect(clock.advance(by: 1) == 1)
        await RemovalProof.until("the engine is unloaded") { engine.counts.unloads == 1 }
        #expect(engine.state == .idle)
    }

    @Test func aUseStartsTheIdleTimeAgain() async throws {
        let (queue, engine, clock) = Self.make()
        queue.noteUse()
        await RemovalProof.until("the engine is ready") { engine.state == .ready }
        await clock.waitForSleepers(1)
        #expect(clock.advance(by: 100) == 0)
        queue.noteUse()
        await clock.waitForSleepers(1)
        #expect(clock.deadlines == [220], "the first timer is gone and the second runs from the second use")
        #expect(clock.advance(by: 119) == 0 && engine.counts.unloads == 0)
        #expect(clock.advance(by: 1) == 1)
        await RemovalProof.until("the engine is unloaded") { engine.counts.unloads == 1 }
    }

    @Test func theIdleTimeRunsFromTheLastRunAndNeverEndsOneInFlight() async throws {
        // No silence limit here: the run is held at its first step while two minutes pass.
        let (queue, engine, clock) = Self.make(silenceLimit: 1_000_000)
        queue.noteUse()
        await RemovalProof.until("the engine is ready") { engine.state == .ready }
        await clock.waitForSleepers(1)
        let gate = RemovalGate()
        let run = Task { try await queue.run(try Self.job()) { if $0 == .step(1, of: 4) { gate.hold() } } }
        await RemovalProof.until("the run is at its first step") { gate.isReached }
        #expect(clock.advance(by: 500) == 1, "the timer of the use ran out during the run")
        gate.open()
        _ = try await run.value
        await clock.waitForSleepers(1)
        #expect(engine.counts.unloads == 0, "a run in flight keeps the model")
        #expect(clock.deadlines == [500 + RemovalQueue.idleUnload], "and the idle time starts when it ends")
        #expect(clock.advance(by: RemovalQueue.idleUnload - 1) == 0 && engine.counts.unloads == 0)
        #expect(clock.advance(by: 1) == 1)
        await RemovalProof.until("the engine is unloaded") { engine.counts.unloads == 1 }
    }

    // MARK: a develop

    @Test func aDevelopUnloadsAndAUseDuringItDoesNotLoad() async throws {
        let (queue, engine, _) = Self.make()
        queue.noteUse()
        await RemovalProof.until("the engine is ready") { engine.state == .ready }
        await queue.developWillStart()
        #expect(engine.counts.unloads == 1 && engine.state == .idle, "the model is gone when developWillStart returns")
        queue.noteUse()
        #expect(engine.counts.loads == 1 && engine.state == .idle, "nothing loads under a develop")
        queue.developDidEnd()
        #expect(engine.counts.loads == 1, "and nothing waited for its end")
        queue.noteUse()
        #expect(engine.counts.loads == 2)
    }

    @Test func aRunInFlightGoesBackForADevelopAndFinishesAfterIt() async throws {
        let (queue, engine, _) = Self.make()
        queue.noteUse()
        await RemovalProof.until("the engine is ready") { engine.state == .ready }
        let heard = RemovalProgressLog(), gate = RemovalGate()
        let job = try Self.job()
        let run = Task {
            try await queue.run(job) { progress in
                heard.add(progress)
                // The first time round, the second step waits until the develop has stopped the engine's run, so the run is in
                // flight when the develop begins whatever the machine is doing.
                if progress == .step(2, of: 4), heard.count(of: progress) == 1 { gate.holdUntilCancelled() }
            }
        }
        await RemovalProof.until("the run is at its second step") { gate.isReached }
        await queue.developWillStart()
        #expect(engine.counts == .init(loads: 1, unloads: 1, runs: 1, cancelled: 1), "stopped between two steps, then unloaded")
        #expect(engine.state == .idle)
        #expect(heard.all == Self.steps(0...2, of: 4) + [.waiting(.idle, forDevelop: true)], "the row says it waits for the develop")

        queue.developDidEnd()
        let output = try await run.value
        #expect(output == (try await FakeRemovalEngine().run(job) { _, _ in }))
        #expect(engine.counts == .init(loads: 2, unloads: 1, runs: 2, cancelled: 1), "loaded again and run from its first step")
        #expect(Self.withoutLoading(heard.all)
                == Self.steps(0...2, of: 4) + [.waiting(.idle, forDevelop: true)] + Self.steps(0...4, of: 4))
    }

    @Test func aRunAskedForDuringADevelopWaitsForItsEnd() async throws {
        let (queue, engine, _) = Self.make()
        await queue.developWillStart()
        let heard = RemovalProgressLog()
        let run = Task { try await queue.run(try Self.job(steps: 2)) { heard.add($0) } }
        await RemovalProof.until("the row says why it waits") { heard.all == [.waiting(.idle, forDevelop: true)] }
        #expect(engine.counts.loads == 0 && engine.counts.runs == 0)
        queue.developDidEnd()
        _ = try await run.value
        #expect(Self.withoutLoading(heard.all) == [.waiting(.idle, forDevelop: true)] + Self.steps(0...2, of: 2))
        #expect(engine.counts.loads == 1 && engine.counts.runs == 1)
    }

    @Test func aDevelopPutsDownAnEngineThatDoesNotStopAndTheRunStillFinishes() async throws {
        let engine = StubbornRemovalEngine(), clock = RemovalHandClock()
        let queue = RemovalQueue(engine: engine, clock: clock.clock, statePoll: .milliseconds(1))
        let heard = RemovalProgressLog()
        let run = Task { try await queue.run(try Self.job()) { heard.add($0) } }
        await RemovalProof.until("the engine has the run") { engine.isRunning }
        let develop = Task { await queue.developWillStart() }
        await RemovalProof.until("the develop's own limit is being waited") { clock.deadlines == [RemovalQueue.developLimit] }
        #expect(engine.fake.counts.unloads == 0)
        #expect(clock.advance(by: RemovalQueue.developLimit) == 1)
        await develop.value
        #expect(engine.fake.counts.unloads == 1 && engine.state == .idle, "put down after two seconds, not after the silence limit")
        #expect(Self.withoutLoading(heard.all) == [.step(0, of: 4), .waiting(.idle, forDevelop: true)], "and the run is back at the queue's head")
        engine.relent()
        queue.developDidEnd()
        _ = try await run.value
        #expect(Self.withoutLoading(heard.all) == [.step(0, of: 4), .waiting(.idle, forDevelop: true)] + Self.steps(0...4, of: 4))
    }

    // MARK: one at a time

    @Test func threeJobsRunOneAtATimeInTheOrderTheyCame() async throws {
        let (queue, engine, _) = Self.make()
        queue.noteUse()
        await RemovalProof.until("the engine is ready") { engine.state == .ready }
        let events = RemovalEventLog(), gate = RemovalGate()
        let first = Task {
            try await queue.run(try Self.job(steps: 2, seed: 1)) {
                events.add("first", $0)
                if $0 == .step(1, of: 2) { gate.hold() }
            }
        }
        await RemovalProof.until("the first run is at its first step") { gate.isReached }
        let second = Task { try await queue.run(try Self.job(steps: 2, seed: 2)) { events.add("second", $0) } }
        await RemovalProof.until("the second is queued") { events.heard(by: "second") == [.queued] }
        let third = Task { try await queue.run(try Self.job(steps: 2, seed: 3)) { events.add("third", $0) } }
        await RemovalProof.until("the third is queued") { events.heard(by: "third") == [.queued] }
        #expect(engine.counts.runs == 1, "the engine has one run and two wait")

        let idle = Task { await queue.waitUntilIdle() }
        gate.open()
        _ = try await (first.value, second.value, third.value)
        await idle.value
        #expect(engine.counts.runs == 3)
        // Each row's whole account, and across them no step of one run between two steps of another.
        #expect(events.heard(by: "first") == Self.steps(0...2, of: 2))
        #expect(events.heard(by: "second") == [.queued] + Self.steps(0...2, of: 2))
        #expect(events.heard(by: "third") == [.queued] + Self.steps(0...2, of: 2))
        #expect(events.namesInOrderOfSteps == ["first", "second", "third"])
    }

    @Test func waitUntilIdleReturnsAtOnceOnAnEmptyQueue() async {
        let (queue, _, _) = Self.make()
        await queue.waitUntilIdle()
    }

    // MARK: cancelling

    @Test func aQueuedJobIsTakenOutWhenItsTaskIsCancelled() async throws {
        let (queue, engine, _) = Self.make()
        let gate = RemovalGate(), heard = RemovalProgressLog()
        let first = Task { try await queue.run(try Self.job()) { if $0 == .step(1, of: 4) { gate.hold() } } }
        await RemovalProof.until("the first run is at its first step") { gate.isReached }
        let second = Task { try await queue.run(try Self.job()) { heard.add($0) } }
        await RemovalProof.until("the second is queued") { heard.all == [.queued] }
        second.cancel()
        // The first is still held at its step: the second left the queue without waiting for anything.
        await #expect(throws: CancellationError.self) { try await second.value }
        gate.open()
        _ = try await first.value
        await queue.waitUntilIdle()
        #expect(engine.counts.runs == 1 && engine.counts.cancelled == 0 && heard.all == [.queued], "the engine never saw it")
    }

    @Test func aRunningJobStopsBetweenTwoSteps() async throws {
        let (queue, engine, _) = Self.make()
        queue.noteUse()
        await RemovalProof.until("the engine is ready") { engine.state == .ready }
        let heard = RemovalProgressLog(), handle = RemovalTaskBox()
        let run = Task {
            try await queue.run(try Self.job(steps: 50)) { progress in
                heard.add(progress)
                if progress == .step(2, of: 50) { handle.cancelWhenStored() }
            }
        }
        handle.store(run)
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(heard.all == Self.steps(0...2, of: 50), "it stops before the next step")
        #expect(engine.counts == .init(loads: 1, unloads: 0, runs: 1, cancelled: 1) && engine.state == .ready, "stopped, and still loaded")
        // The queue goes on.
        _ = try await queue.run(try Self.job()) { _ in }
        #expect(engine.counts.runs == 2)
    }

    @Test func aTaskCancelledBeforeItAsksNeverReachesTheEngine() async throws {
        let (queue, engine, _) = Self.make()
        let run = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await queue.run(try Self.job()) { _ in }
        }
        await #expect(throws: CancellationError.self) { try await run.value }
        await queue.waitUntilIdle()
        #expect(engine.counts.runs == 0)
    }

    // MARK: silence

    @Test func anEngineSilentForTheLimitIsPutDownAndTheRunSaysSo() async throws {
        // A fake whose first step never comes.
        let (queue, engine, clock) = Self.make(FakeRemovalEngine(stepDelay: .seconds(86_400)))
        let heard = RemovalProgressLog()
        let run = Task { try await queue.run(try Self.job()) { heard.add($0) } }
        await RemovalProof.until("the engine has the run") { engine.state == .running }
        await clock.waitForSleepers(1)
        #expect(clock.deadlines == [RemovalQueue.silenceLimit])
        #expect(clock.advance(by: RemovalQueue.silenceLimit - 1) == 0 && engine.counts.unloads == 0, "not before the limit")
        #expect(clock.advance(by: 1) == 1)
        await #expect(throws: RemovalRunFailure.unresponsive) { try await run.value }
        #expect(engine.counts.unloads == 1 && engine.state == .idle, "put down with unload")
        #expect(Self.withoutLoading(heard.all) == [.step(0, of: 4)])
        await RemovalProof.until("the engine's own run was told to stop") { engine.counts.cancelled == 1 }
    }

    @Test func eachStepStartsTheSilenceAgain() async throws {
        let (queue, engine, clock) = Self.make()
        // Nine seconds pass at each step: 36 in all, and never ten with nothing said.
        let output = try await queue.run(try Self.job()) { progress in
            if case .step(let done, _) = progress, done > 0 { clock.advance(by: RemovalQueue.silenceLimit - 1) }
        }
        #expect(output.engine == FakeRemovalEngine.engineID && clock.now == 4 * (RemovalQueue.silenceLimit - 1))
        #expect(engine.counts.unloads == 0 && engine.counts.runs == 1)
    }

    enum WatchChange: CaseIterable {
        case progress, end, develop
    }

    @Test(arguments: WatchChange.allCases)
    func anInFlightTimerCannotActAfterInvalidation(change: WatchChange) async throws {
        let clock = RemovalHandClock()
        let checkingState = RemovalGate(), timeout = RemovalGate()
        let limit = RemovalQueue.silenceLimit
        let watch = RemovalSilenceWatch(clock: clock.clock) {
            if !checkingState.isReached {
                checkingState.hold()
                if change == .develop { return limit }
            }
            return nil
        } timedOut: {
            timeout.note()
        }
        defer {
            checkingState.open()
            watch.end()
        }

        let stale = try #require(watch.arm(limit))
        await clock.waitForSleepers(1)
        #expect(clock.advance(by: limit) == 1)
        await RemovalProof.until("the old timer is checking engine state") { checkingState.isReached }

        let nextLimit: TimeInterval? = switch change {
        case .progress: limit
        case .end: nil
        case .develop: RemovalQueue.developLimit
        }
        let replacement = nextLimit.flatMap { watch.arm($0) }
        if nextLimit == nil { watch.end() }
        checkingState.open()
        await stale.value
        #expect(!timeout.isReached, "the old timer must not declare the run unresponsive")

        if let nextLimit {
            let replacement = try #require(replacement)
            await clock.waitForSleepers(1)
            let deadlines = clock.deadlines
            try #require(deadlines == [limit + nextLimit], "the old timer must not replace the new deadline")
            #expect(clock.advance(by: nextLimit) == 1)
            await replacement.value
            #expect(timeout.isReached, "the replacement timer must still expire")
        }
        #expect(watch.arm(limit) == nil, "an ended or expired watch cannot be restarted")
    }

    @Test func aLoadingRetryStillExpiresWhenTheEngineIsNoLongerLoading() async throws {
        let clock = RemovalHandClock()
        let loaded = RemovalGate(), timeout = RemovalGate()
        let limit = RemovalQueue.silenceLimit
        let watch = RemovalSilenceWatch(clock: clock.clock) {
            loaded.isReached ? nil : limit
        } timedOut: {
            timeout.note()
        }
        defer { watch.end() }

        let first = try #require(watch.arm(limit))
        await clock.waitForSleepers(1)
        #expect(clock.advance(by: limit) == 1)
        await first.value
        #expect(!timeout.isReached)
        await clock.waitForSleepers(1)
        #expect(clock.deadlines == [2 * limit])
        loaded.note()
        #expect(clock.advance(by: limit) == 1)
        await RemovalProof.until("the retried timer expires") { timeout.isReached }
        #expect(watch.arm(limit) == nil)
    }

    // MARK: before the engine is ready

    @Test func aRunBeforeTheEngineIsReadyWaitsAndSaysWhy() async throws {
        // A fake left in its one-time preparation until the suite ends it.
        let (queue, engine, clock) = Self.make(FakeRemovalEngine(state: .preparing(0.25)))
        let heard = RemovalProgressLog()
        let run = Task { try await queue.run(try Self.job(steps: 3)) { heard.add($0) } }
        await RemovalProof.until("the row says the engine is preparing") { heard.all == [.waiting(.preparing(0.25), forDevelop: false)] }
        #expect(clock.advance(by: 1000) == 0, "a preparation is not a silence: nothing waits on the clock")
        #expect(engine.counts.runs == 0)
        await engine.unload()
        _ = try await run.value
        #expect(heard.all == [.waiting(.preparing(0.25), forDevelop: false)] + Self.steps(0...3, of: 3))
    }

    @Test func anAbsentEngineAndAFailedRunSayWhyAndTheQueueGoesOn() async throws {
        let absent = Self.make(FakeRemovalEngine(state: .absent("no bridge is running")))
        absent.queue.noteUse()
        await #expect(throws: RemovalRunFailure.failed("no bridge is running")) { try await absent.queue.run(try Self.job()) { _ in } }

        let (queue, engine, _) = Self.make()
        engine.failNext(.failed("no memory"))
        await #expect(throws: RemovalRunFailure.failed("no memory")) { try await queue.run(try Self.job()) { _ in } }
        _ = try await queue.run(try Self.job()) { _ in }
        await queue.waitUntilIdle()
        #expect(engine.counts.runs == 2)
    }
}

// MARK: - What the suites of the queue and the folder share

/// Waits for `condition`, looking every millisecond, for twenty seconds at the most: a wait on a state, bounded so a broken queue
/// fails a test and does not hang the suite.
enum RemovalProof {
    static func until(_ what: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: @Sendable () -> Bool) async {
        for _ in 0..<20_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("timed out waiting until \(what)", sourceLocation: sourceLocation)
    }
}

/// A `RemovalClock` moved by hand. It stands at zero until `advance`, and a sleeper wakes when the time passes its deadline.
final class RemovalHandClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var sleepers: [UUID: (deadline: TimeInterval, continuation: CheckedContinuation<Void, any Error>)] = [:]

    var clock: RemovalClock { RemovalClock(now: { [self] in now }, sleep: { [self] in try await sleep(until: $0) }) }
    var now: TimeInterval { lock.withLock { time } }
    /// The deadlines being waited for, the nearest first.
    var deadlines: [TimeInterval] { lock.withLock { sleepers.values.map(\.deadline).sorted() } }

    /// Moves the time on and wakes whoever it passed: how many.
    @discardableResult func advance(by seconds: TimeInterval) -> Int {
        let woken = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            time += seconds
            let due = sleepers.filter { $0.value.deadline <= time }
            for id in due.keys { sleepers[id] = nil }
            return due.values.map(\.continuation)
        }
        for continuation in woken { continuation.resume() }
        return woken.count
    }

    /// Waits until exactly `count` sleepers wait: a timer is started on a task of its own, and a test that moves the clock first
    /// would not know whether it woke it.
    func waitForSleepers(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        await RemovalProof.until("\(count) wait on the clock", sourceLocation: sourceLocation) { [self] in lock.withLock { sleepers.count } == count }
    }

    private func sleep(until deadline: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let answer = lock.withLock { () -> Result<Void, any Error>? in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= time { return .success(()) }
                    sleepers[id] = (deadline, continuation)
                    return nil
                }
                if let answer { continuation.resume(with: answer) }
            }
        } onCancel: {
            lock.withLock { sleepers.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
        }
    }
}

/// What a row heard, from whatever thread told it.
final class RemovalProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [RemovalQueue.Progress] = []
    func add(_ progress: RemovalQueue.Progress) { lock.withLock { heard.append(progress) } }
    var all: [RemovalQueue.Progress] { lock.withLock { heard } }
    func count(of progress: RemovalQueue.Progress) -> Int { lock.withLock { heard.filter { $0 == progress }.count } }
}

/// What several rows heard, in the one order it happened.
private final class RemovalEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(name: String, progress: RemovalQueue.Progress)] = []
    func add(_ name: String, _ progress: RemovalQueue.Progress) { lock.withLock { events.append((name, progress)) } }
    func heard(by name: String) -> [RemovalQueue.Progress] { lock.withLock { events.filter { $0.name == name }.map(\.progress) } }
    /// Whose steps came when, runs of the same name joined: three names when no run's step fell inside another's.
    var namesInOrderOfSteps: [String] {
        lock.withLock {
            var names: [String] = []
            for event in events {
                guard case .step = event.progress, names.last != event.name else { continue }
                names.append(event.name)
            }
            return names
        }
    }
}

/// Holds an engine's step where a test wants it. The step is told on the engine's own task, so holding it holds the run.
final class RemovalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var reached = false
    private let opened = DispatchSemaphore(value: 0)

    var isReached: Bool { lock.withLock { reached } }

    /// Says the step was reached, and holds nothing.
    func note() { lock.withLock { reached = true } }

    /// Holds the caller until `open`.
    func hold() {
        lock.withLock { reached = true }
        opened.wait()
    }

    /// Holds the caller until the task it runs on, the engine's run, is cancelled, and for twenty seconds at the most.
    func holdUntilCancelled() {
        lock.withLock { reached = true }
        for _ in 0..<40_000 where !Task.isCancelled { usleep(500) }
    }

    func open() { opened.signal() }
}

/// A fake that does not stop between two steps: its run ignores its task's cancellation until `relent`, and runs as the fake does
/// after.
private final class StubbornRemovalEngine: RemovalEngine, @unchecked Sendable {
    let fake = FakeRemovalEngine()
    private let lock = NSLock()
    private var stubborn = true
    private var running = false

    var state: RemovalEngineState { fake.state }
    var isRunning: Bool { lock.withLock { running } }
    func load() { fake.load() }
    func unload() async { await fake.unload() }
    func relent() { lock.withLock { stubborn = false } }

    func run(_ job: RemovalJob, step: @escaping @Sendable (Int, Int) -> Void) async throws -> RemovalOutput {
        guard lock.withLock({ stubborn }) else { return try await fake.run(job, step: step) }
        lock.withLock { running = true }
        while lock.withLock({ stubborn }) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(1)) { continuation.resume() }
            }
        }
        throw CancellationError()
    }
}

/// A run's task, for a step of that run to cancel: the step may come before the test has the task in hand, and waits for it.
final class RemovalTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<RemovalOutput, any Error>?
    private let stored = DispatchSemaphore(value: 0)

    func store(_ task: Task<RemovalOutput, any Error>) {
        lock.withLock { self.task = task }
        stored.signal()
    }

    func cancelWhenStored() {
        stored.wait()
        lock.withLock { task }?.cancel()
    }
}
