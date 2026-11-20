import ArgentCore
import Foundation

/// The time the queue's two long waits run on, the 120 seconds before an idle model goes and the 10 an engine may say nothing: the
/// system's in the app, a suite's own, moved by hand, in a test, so none waits two minutes. Deadlines are moments, not lengths: a
/// wait that begins late still ends when it should.
public struct RemovalClock: Sendable {
    /// Seconds since any fixed moment.
    public let now: @Sendable () -> TimeInterval
    /// Returns once `now` has reached `deadline`, at once if it has. Throws `CancellationError` when its task is cancelled first.
    public let sleep: @Sendable (_ deadline: TimeInterval) async throws -> Void

    public init(now: @escaping @Sendable () -> TimeInterval, sleep: @escaping @Sendable (_ deadline: TimeInterval) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    /// The system's clock, which goes on counting while the Mac sleeps: a model left loaded is let go on waking.
    public static let system: RemovalClock = {
        let clock = ContinuousClock(), start = clock.now
        return RemovalClock(
            now: {
                let passed = (clock.now - start).components
                return TimeInterval(passed.seconds) + TimeInterval(passed.attoseconds) * 1e-18
            },
            sleep: { deadline in try await Task.sleep(until: start + .seconds(deadline), clock: clock) })
    }()
}

/// Removals waiting for the model, and when the model is held (docs/remove-plan.md, section 4.5). The engine does as it is told;
/// these are the rules that tell it:
///
/// - **Load** when the Remove tab opens on a frame or a stroke begins (`noteUse`), never at launch.
/// - **Unload** `idleUnload` after the last stroke or run, tab open or not, and at once when a develop is about to start
///   (`developWillStart`), which returns only when the engine's process is gone.
/// - **One run at a time,** first come first served. A run asked for before the engine is ready waits for it.
/// - **Cancel** stops between two steps. An engine that says nothing for `silenceLimit` is put down, and the run throws
///   `RemovalRunFailure.unresponsive`.
///
/// One task serves the queue: it alone runs the engine and lets an idle one go, so a run never meets an unload half done. A develop
/// stops that task, and starts it again when it ends.
///
/// Safe to call from any thread.
public final class RemovalQueue: @unchecked Sendable {
    /// How long the model is held after the last use.
    public static let idleUnload: TimeInterval = 120
    /// How long an engine may say nothing during a run before it is put down.
    public static let silenceLimit: TimeInterval = 10
    /// How long a develop waits for the run in flight to stop between two steps before the engine is put down under it
    /// (docs/remove-plan.md, section 4.5: "2 s at most"). The run is not lost: it goes back to the queue's head.
    public static let developLimit: TimeInterval = 2
    /// How often a run that waits for the engine reads its state. An engine has no way to say that it changed, so this one wait is
    /// on the system's clock whatever `RemovalClock` the queue was given.
    public static let statePoll: Duration = .milliseconds(50)

    /// What a waiting or running removal's row shows.
    public enum Progress: Sendable, Equatable {
        /// Behind the engine, which is preparing or loading, or behind a develop.
        case waiting(RemovalEngineState, forDevelop: Bool)
        /// Behind another removal.
        case queued
        /// The engine has the run: the steps it has finished, none when it has just been given it, and the job's count.
        case step(Int, of: Int)
    }

    public let engine: any RemovalEngine
    private let idleUnload: TimeInterval
    private let silenceLimit: TimeInterval
    private let developLimit: TimeInterval
    private let clock: RemovalClock
    private let statePoll: Duration

    private let lock = NSLock()
    /// The runs not yet begun, the next one first, and the one the serving task has.
    private var waiting: [Entry] = []
    private var current: Entry?
    /// The engine's run for `current` and the wait on its silence, while the engine has it.
    private var flight: Task<RemovalOutput, any Error>?
    private var watch: RemovalSilenceWatch?
    /// The task that serves the queue, `nil` when there is nothing to serve or a develop holds it.
    private var server: Task<Void, Never>?
    /// Between `developWillStart` and `developDidEnd`. A switch and not a count: the app develops one roll at a time, and a second
    /// `developWillStart` before the end must not need a second end.
    private var isHeld = false
    /// The idle timer ran out and the serving task has not yet let the engine go; then, that it is letting it go, and that a use
    /// came meanwhile and wants it back.
    private var wantsUnload = false
    private var isUnloading = false
    private var reloads = false
    private var idleTimer: Task<Void, Never>?
    private var idleGeneration = 0
    private var idlers: [CheckedContinuation<Void, Never>] = []

    public init(engine: any RemovalEngine, idleUnload: TimeInterval = RemovalQueue.idleUnload,
                silenceLimit: TimeInterval = RemovalQueue.silenceLimit, developLimit: TimeInterval = RemovalQueue.developLimit,
                clock: RemovalClock = .system, statePoll: Duration = RemovalQueue.statePoll) {
        self.engine = engine
        self.idleUnload = idleUnload
        self.silenceLimit = silenceLimit
        self.developLimit = developLimit
        self.clock = clock
        self.statePoll = statePoll
    }

    deinit { idleTimer?.cancel() }

    public var state: RemovalEngineState { engine.state }

    /// The Remove tab opened on a frame, or a stroke began: the model is wanted soon.
    public func noteUse() {
        lock.withLock {
            restartIdleTimer()
            if isUnloading {
                reloads = true
            } else if !isHeld {
                // Under the lock, as every load is: a develop's unload then comes wholly before it or wholly after, never between
                // the check and the load. An engine's `load` returns at once.
                engine.load()
            }
        }
    }

    /// Something is selected whose job will have this working size: the model is wanted, and for this size.
    public func prepare(width: Int, height: Int) {
        noteUse()
        engine.prepare(width: width, height: height)
    }

    /// Runs `job` in its turn and returns the engine's output. Cancelling the task takes the job out of the queue, or stops its run
    /// between two steps.
    public func run(_ job: RemovalJob, progress: @escaping @Sendable (Progress) -> Void) async throws -> RemovalOutput {
        let entry = Entry(job: job, progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in enqueue(entry, continuation) }
        } onCancel: {
            cancel(entry)
        }
    }

    /// A develop is about to start (`RollModel.trimForDevelop`): the model's memory goes back before the develop's gate reads the
    /// footprint. Runs wait, and start again by themselves when the develop ends.
    public func developWillStart() async {
        let (serving, flying, watching) = lock.withLock {
            () -> (Task<Void, Never>?, Task<RemovalOutput, any Error>?, RemovalSilenceWatch?) in
            isHeld = true
            return (server, flight, watch)
        }
        // The run in flight stops between two steps and goes back to the queue's head; the serving task ends once it has.
        watching?.arm(developLimit)
        flying?.cancel()
        await serving?.value
        await engine.unload()
        let head = lock.withLock { waiting.first }
        head?.tell(.waiting(engine.state, forDevelop: true))
    }

    public func developDidEnd() {
        lock.withLock {
            guard isHeld else { return }
            isHeld = false
            startServer()
        }
    }

    /// Returns when no removal is waiting or running.
    public func waitUntilIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = lock.withLock { () -> Bool in
                if current == nil, waiting.isEmpty { return true }
                idlers.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }

    // MARK: The queue

    /// One removal asked for: its job, its row, and whoever waits for it.
    private final class Entry: @unchecked Sendable {
        let job: RemovalJob
        private let progress: @Sendable (Progress) -> Void
        /// Held while the row is told, so what it hears is in the order it happened whichever thread says it.
        let telling = NSLock()
        private var told: Progress?
        /// Under the queue's lock.
        var continuation: CheckedContinuation<RemovalOutput, any Error>?
        var isCancelled = false

        init(job: RemovalJob, progress: @escaping @Sendable (Progress) -> Void) {
            self.job = job
            self.progress = progress
        }

        func tell(_ next: Progress) { telling.withLock { tellHoldingTheLock(next) } }

        func tellHoldingTheLock(_ next: Progress) {
            guard told != next else { return }
            told = next
            progress(next)
        }
    }

    private func enqueue(_ entry: Entry, _ continuation: CheckedContinuation<RemovalOutput, any Error>) {
        // The row hears where it stands before the serving task, which may take the run at once, can tell it anything later.
        entry.telling.lock()
        defer { entry.telling.unlock() }
        let (refused, behind, held) = lock.withLock { () -> (Bool, Bool, Bool) in
            // A task cancelled before it asked: its handler has run already and found nothing to take out.
            guard !entry.isCancelled else { return (true, false, false) }
            let behind = current != nil || !waiting.isEmpty
            entry.continuation = continuation
            waiting.append(entry)
            startServer()
            return (false, behind, isHeld)
        }
        if refused {
            continuation.resume(throwing: CancellationError())
        } else if behind {
            entry.tellHoldingTheLock(.queued)
        } else if held {
            entry.tellHoldingTheLock(.waiting(engine.state, forDevelop: true))
        }
    }

    private func cancel(_ entry: Entry) {
        let (continuation, flying, idle, head) = lock.withLock {
            () -> (CheckedContinuation<RemovalOutput, any Error>?, Task<RemovalOutput, any Error>?, [CheckedContinuation<Void, Never>], Entry?) in
            entry.isCancelled = true
            if let index = waiting.firstIndex(where: { $0 === entry }) {
                waiting.remove(at: index)
                let continuation = entry.continuation
                entry.continuation = nil
                // The one behind it is the head now, and waits for the develop and no longer for a removal.
                return (continuation, nil, emptied(), isHeld && index == 0 ? waiting.first : nil)
            }
            // The serving task has it: it ends the run and answers when the engine has stopped.
            return (nil, current === entry ? flight : nil, [], nil)
        }
        flying?.cancel()
        continuation?.resume(throwing: CancellationError())
        for waiter in idle { waiter.resume() }
        head?.tell(.waiting(engine.state, forDevelop: true))
    }

    /// The queue has nothing left, if it has not: the idle timer starts again and whoever waits for that is let go. Under the lock.
    private func emptied() -> [CheckedContinuation<Void, Never>] {
        guard current == nil, waiting.isEmpty else { return [] }
        restartIdleTimer()
        defer { idlers = [] }
        return idlers
    }

    // MARK: The idle timer

    /// Under the lock.
    private func restartIdleTimer() {
        idleGeneration += 1
        wantsUnload = false
        let mine = idleGeneration, deadline = clock.now() + idleUnload, clock = clock
        idleTimer?.cancel()
        idleTimer = Task.detached(priority: .utility) { [weak self] in
            guard (try? await clock.sleep(deadline)) != nil else { return }
            self?.idleElapsed(mine)
        }
    }

    private func idleElapsed(_ mine: Int) {
        lock.withLock {
            // A run starts the timer again when the queue empties, and a develop has let the engine go already.
            guard mine == idleGeneration, !isHeld, current == nil, waiting.isEmpty else { return }
            wantsUnload = true
            startServer()
        }
    }

    // MARK: Serving

    private enum Work {
        case unload
        case run(Entry)
    }

    private enum Served {
        case finished(Result<RemovalOutput, any Error>)
        /// Stopped for a develop: it goes back to the queue's head.
        case putBack
    }

    /// Under the lock.
    private func startServer() {
        guard server == nil, !isHeld, wantsUnload || !waiting.isEmpty else { return }
        server = Task.detached(priority: .userInitiated) { [self] in await serve() }
    }

    private func serve() async {
        while true {
            let work = lock.withLock { () -> Work? in
                guard !isHeld else { server = nil; return nil }
                if wantsUnload {
                    wantsUnload = false
                    if waiting.isEmpty {
                        isUnloading = true
                        return .unload
                    }
                }
                guard !waiting.isEmpty else { server = nil; return nil }
                let entry = waiting.removeFirst()
                current = entry
                engine.load()
                return .run(entry)
            }
            switch work {
            case nil: return
            case .unload?:
                await engine.unload()
                lock.withLock {
                    isUnloading = false
                    if reloads, !isHeld { engine.load() }
                    reloads = false
                }
            case .run(let entry)?:
                finish(entry, await perform(entry))
            }
        }
    }

    private func finish(_ entry: Entry, _ served: Served) {
        let (continuation, result, idle) = lock.withLock {
            () -> (CheckedContinuation<RemovalOutput, any Error>?, Result<RemovalOutput, any Error>, [CheckedContinuation<Void, Never>]) in
            current = nil
            flight = nil
            watch = nil
            var result: Result<RemovalOutput, any Error> = .failure(CancellationError())
            switch served {
            case .putBack:
                if !entry.isCancelled {
                    waiting.insert(entry, at: 0)
                    return (nil, result, [])
                }
            case .finished(let finished):
                // A run cancelled as its last step ended has an output nobody waits for.
                if !entry.isCancelled { result = finished }
            }
            let continuation = entry.continuation
            entry.continuation = nil
            return (continuation, result, emptied())
        }
        continuation?.resume(with: result)
        for waiter in idle { waiter.resume() }
    }

    private func isStopped(_ entry: Entry) -> (cancelled: Bool, held: Bool) {
        lock.withLock { (entry.isCancelled, isHeld) }
    }

    /// One run, on the serving task: the engine ready first, then its run under the watch for silence.
    private func perform(_ entry: Entry) async -> Served {
        // The engine was told to load as the run was taken. While it prepares or loads, the row says which, and the wait for
        // silence has not begun: a first preparation may take minutes and is not a run that stopped answering.
        waitingForTheEngine: while true {
            let stopped = isStopped(entry)
            if stopped.cancelled { return .finished(.failure(CancellationError())) }
            if stopped.held { return .putBack }
            let state = engine.state
            switch state {
            case .absent(let why): return .finished(.failure(RemovalRunFailure.failed(why)))
            case .preparing, .loading:
                entry.tell(.waiting(state, forDevelop: false))
                try? await Task.sleep(for: statePoll)
            case .idle, .ready, .running:
                // An engine that says it is idle after being told to load is left to `run`, which loads first if it must.
                break waitingForTheEngine
            }
        }

        let verdict = Verdict()
        let limit = silenceLimit, engine = engine
        let watch = RemovalSilenceWatch(clock: clock) { [weak self] in
            // An engine busy loading has not gone silent in a run, unless a develop waits for it to go.
            if let self, !self.lock.withLock({ self.isHeld }) {
                switch engine.state {
                case .preparing, .loading: return limit
                case .absent, .idle, .ready, .running: break
                }
            }
            return nil
        } timedOut: {
            verdict.give(nil)
        }
        watch.arm(limit)
        entry.tell(.step(0, of: entry.job.steps))
        let flying = Task.detached(priority: .userInitiated) {
            try await engine.run(entry.job) { done, of in
                // A step from a run already given up is not this row's news.
                guard watch.arm(limit) != nil else { return }
                entry.tell(.step(done, of: of))
            }
        }
        Task.detached(priority: .userInitiated) { verdict.give(await flying.result) }
        let stopped = lock.withLock { () -> (cancelled: Bool, held: Bool) in
            flight = flying
            self.watch = watch
            return (entry.isCancelled, isHeld)
        }
        // Cancelled, or a develop began, between the last look and the run: the run has to hear of it here.
        if stopped.cancelled || stopped.held { flying.cancel() }
        if stopped.held { watch.arm(developLimit) }

        let result = await verdict.wait()
        watch.end()
        let after = isStopped(entry)
        guard let result else {
            // Silent for too long: the engine is put down, and its run left to end as it may.
            flying.cancel()
            await engine.unload()
            return after.held && !after.cancelled ? .putBack : .finished(.failure(RemovalRunFailure.unresponsive))
        }
        if case .failure(let error) = result, error is CancellationError, after.held, !after.cancelled { return .putBack }
        return .finished(result)
    }
}

/// The wait for a run's engine to say something: armed when the run begins and again at each step, and elapsed when a limit has
/// passed with nothing said since.
final class RemovalSilenceWatch: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: RemovalClock
    private let retryDelay: @Sendable () -> TimeInterval?
    private let timedOut: @Sendable () -> Void
    private var generation = 0
    private var timer: Task<Void, Never>?
    private var isOver = false

    init(clock: RemovalClock, retryDelay: @escaping @Sendable () -> TimeInterval?, timedOut: @escaping @Sendable () -> Void) {
        self.clock = clock
        self.retryDelay = retryDelay
        self.timedOut = timedOut
    }

    /// Starts the wait again, `limit` from now. Returns the timer, or nil once the run is over.
    @discardableResult func arm(_ limit: TimeInterval) -> Task<Void, Never>? {
        lock.withLock { restart(limit) }
    }

    /// Under the lock.
    private func restart(_ limit: TimeInterval) -> Task<Void, Never>? {
        guard !isOver else { return nil }
        generation += 1
        let mine = generation, deadline = clock.now() + limit, clock = clock
        timer?.cancel()
        timer = Task.detached(priority: .utility) { [weak self] in
            guard (try? await clock.sleep(deadline)) != nil else { return }
            self?.fire(mine)
        }
        return timer
    }

    private func fire(_ mine: Int) {
        guard lock.withLock({ !isOver && mine == generation }) else { return }
        // Reading engine state takes the queue's lock: do it outside this lock, then validate again before committing.
        let delay = retryDelay()
        lock.withLock {
            guard !isOver && mine == generation else { return }
            if let delay {
                _ = restart(delay)
            } else {
                isOver = true
                timer = nil
                timedOut()
            }
        }
    }

    func end() {
        lock.withLock {
            isOver = true
            timer?.cancel()
            timer = nil
        }
    }
}

/// How a run ended, from whichever comes first: the engine's answer, or `nil` for its silence. Given once; later answers are
/// dropped.
private final class Verdict: @unchecked Sendable {
    private let lock = NSLock()
    private var isGiven = false
    private var value: Result<RemovalOutput, any Error>?
    private var waiter: CheckedContinuation<Result<RemovalOutput, any Error>?, Never>?

    func give(_ result: Result<RemovalOutput, any Error>?) {
        let waiter = lock.withLock { () -> CheckedContinuation<Result<RemovalOutput, any Error>?, Never>? in
            guard !isGiven else { return nil }
            isGiven = true
            value = result
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: result)
    }

    func wait() async -> Result<RemovalOutput, any Error>? {
        await withCheckedContinuation { continuation in
            let given = lock.withLock { () -> Bool in
                if !isGiven { waiter = continuation }
                return isGiven
            }
            if given { continuation.resume(returning: lock.withLock { value }) }
        }
    }
}
