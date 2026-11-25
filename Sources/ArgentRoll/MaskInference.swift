import ArgentCore
import Foundation

// Smart masks' selections, made when a tile is clicked and never before (masking-plan section 11, "When to run inference"): the
// input picture, Vision's requests and the bundled models, one selection at a time on a queue of their own, taking their turns
// with a develop's frames, so a develop's decode goes first and a develop never runs a model (plan section 4, rule 5; R6 section 9).
// What a selection finds is a measurement stored with the edit; the app stores it and names it in the mask (`RollModel+SmartMasks`).

/// Where a selection stands, for the row that waits on it: a wait names what it waits for (SPEC, "a wait names what it waits for").
public enum SmartStage: Sendable, Equatable {
    /// Behind another selection on the queue.
    case queued
    /// A develop's frame holds the turn; the selection goes when it is written.
    case waitingForDevelop
    /// The frame's input picture: its neutral print at 2560 pixels, from a decode of its own on this display (0.4 s, A).
    case reading
    /// "Preparing masks": the bundled models compiled for this Mac and macOS, on first use and after a macOS update (about 17 s for the four, measured in the sandboxed app). Runs before a Sky click and a Subject click.
    case preparing(Double)
    /// The model or Vision request runs; Subject's region, gate and matting all say this.
    case finding
    /// Sky only, behind Vision's water gate: EoMT loaded, run and unloaded for the reflection veto (+0.3 s).
    case checkingWater
}

/// Whether a kind can be asked for in this build and on this Mac, and if not, why, in the photographer's words.
public enum SmartAvailability: Sendable, Equatable {
    case available
    case unavailable(String)
    /// Not until the mask models are downloaded (`MaskModelPack`): why, in the tile's words. The tile offers the download.
    case needsModels(String)

    public var isAvailable: Bool { self == .available }
    public var reason: String? {
        switch self {
        case .available: return nil
        case .unavailable(let why), .needsModels(let why): return why
        }
    }
}

/// What a selection came to.
public enum SmartOutcome: Sendable, Equatable {
    /// A seed to store, and the frame it was made on (`MaskFrame`), which the mask records with it.
    case found(SmartSeed, MaskFrame)
    /// Nothing of the kind in the frame: a quiet state in the row, never an error (plan section 5). With the frame it looked at,
    /// for a brush painted in its place.
    case nothingFound(SmartKind, RasterProvenance, MaskFrame)
    /// The engine failed, with why. Never read as "nothing found".
    case failed(String)
    /// Stopped before it finished: undone, deleted, another roll, quit, or the raw changed under it.
    case cancelled

    /// The same outcome for `kind`: Background is Subject's seed read as `1 − v` (`AppleSegmentation.background(from:)`).
    func `as`(_ kind: SmartKind) -> SmartOutcome {
        guard kind == .background else { return self }
        switch self {
        case .found(let seed, let frame):
            return .found(SmartSeed(kind: .background, raster: seed.raster, provenance: seed.provenance, edge: seed.edge), frame)
        case .nothingFound(_, let provenance, let frame): return .nothingFound(.background, provenance, frame)
        case .failed, .cancelled: return self
        }
    }
}

/// What this build would make each kind with now, to tell a seed made with an earlier model (plan section 2, step 6): the
/// row then offers Update and Keep, and nothing changes by itself. A converted model is named by its recipe and weights, never its
/// file's hash, since conversions are not byte-deterministic (plan section 7).
public struct SmartModelPins: Sendable, Equatable {
    /// DA3 and EoMT, `nil` in a build without them, where no newer Sky model exists to offer. EoMT is also Subject's gate.
    public var sky: ModelProvenance?
    public var water: ModelProvenance?
    public var vetoVersion = WaterVeto.version
    public var gateRevision = String(WaterScore.revision)
    public var subjectRevision = String(AppleSegmentation.subjectRevision)
    public var personRevision = String(AppleSegmentation.personRevision)
    /// S3OD and ViTMatte, `nil` in a build without them, where no newer Subject model exists to offer, so a Vision seed is not stale.
    public var subject: ModelProvenance?
    public var matte: ModelProvenance?
    public var subjectDesign = SubjectDesign.version
    /// The square DA3 is given (`SkyModelRunner.squareRecipe`), `nil` where it is not compared. A Sky seed that records none
    /// (`model.square`) was cut from the edge-repeated square every seed was before task H, whose outer columns came out low.
    public var skySquare: String?

    /// What a Sky seed without `model.square` was cut from.
    public static let edgeSkySquare = ModelSquare.recipe(side: SkyModelRunner.side, padding: .edge)

    public init(sky: ModelProvenance? = nil, water: ModelProvenance? = nil, skySquare: String? = nil, subject: ModelProvenance? = nil, matte: ModelProvenance? = nil) {
        self.sky = sky
        self.water = water
        self.skySquare = skySquare
        self.subject = subject
        self.matte = matte
    }

    /// Whether `provenance`, a `kind` seed's, was made by something other than what this build makes it with now. A provenance
    /// that cannot say (an older field missing) is not called stale: Update is offered only when a newer model is known to exist.
    public func isStale(_ provenance: RasterProvenance, kind: SmartKind) -> Bool {
        let p = provenance.parameters
        switch kind {
        case .subject, .background:
            if provenance.engine == AppleSegmentation.subjectEngine {
                // A Vision seed an earlier Argent made, in an existing record or where the models were absent: offered Update once this build has the new Subject; nothing changes it silently.
                return provenance.engineRevision != subjectRevision || subject != nil
            }
            guard let subject, let recipe = p["model.recipe"], let weights = p["model.weights"] else { return false }
            if recipe != subject.recipeID || weights != subject.weightsSHA256 { return true }
            if let design = p["design"], design != subjectDesign { return true }
            // EoMT and ViTMatte shaped the seed only where the gate and the rule let them.
            if p["gate.ran"] == "true", let water, let recipe = p["eomt.recipe"], let weights = p["eomt.weights"], recipe != water.recipeID || weights != water.weightsSHA256 { return true }
            if p["edge"] == "matte", let matte, let recipe = p["matte.recipe"], let weights = p["matte.weights"], recipe != matte.recipeID || weights != matte.weightsSHA256 { return true }
            return false
        case .person:
            return provenance.engine == AppleSegmentation.personEngine && provenance.engineRevision != personRevision
        case .sky:
            guard let sky, let recipe = p["model.recipe"], let weights = p["model.weights"] else { return false }
            if recipe != sky.recipeID || weights != sky.weightsSHA256 { return true }
            if let skySquare, (p["model.square"] ?? Self.edgeSkySquare) != skySquare { return true }
            if let veto = p["veto"], veto != vetoVersion { return true }
            if let gate = p["gate.revision"], gate != gateRevision { return true }
            // EoMT shaped the seed only where the gate let it run.
            if p["veto.ran"] == "true", let water, let recipe = p["eomt.recipe"], let weights = p["eomt.weights"] {
                return recipe != water.recipeID || weights != water.weightsSHA256
            }
            return false
        }
    }

    /// One line naming what makes `kind` now, for a Keep to remember which model it kept the old seed against.
    public func pin(for kind: SmartKind) -> String {
        switch kind {
        case .subject, .background:
            guard let subject else { return "\(AppleSegmentation.subjectEngine)@\(subjectRevision)" }
            return ["\(subject.recipeID)@\(subject.weightsSHA256)", matte.map { "\($0.recipeID)@\($0.weightsSHA256)" } ?? "none",
                    water.map { "\($0.recipeID)@\($0.weightsSHA256)" } ?? "none", subjectDesign].joined(separator: "|")
        case .person: return "\(AppleSegmentation.personEngine)@\(personRevision)"
        case .sky:
            return [sky.map { "\($0.recipeID)@\($0.weightsSHA256)" } ?? "none", water.map { "\($0.recipeID)@\($0.weightsSHA256)" } ?? "none",
                    vetoVersion, "gate@\(gateRevision)"].joined(separator: "|") + (skySquare.map { "|\($0)" } ?? "")
        }
    }
}

/// A frame's input picture as an engine made it, handed back to the same engine to find in. Opaque to the queue.
public final class SmartPictureHandle: @unchecked Sendable {
    public let frame: URL
    /// The engine's own picture; immutable once made.
    public let content: Any
    public init(frame: URL, content: Any) {
        self.frame = frame
        self.content = content
    }
}

/// What makes selections: the input picture and the models. `BundledSmartMasks` is the app's; tests give their own. Called from the
/// inference queue's thread, one call at a time, except `picture(of:)`, which a Masks tab opening may call beside a run.
public protocol SmartMaskEngine: AnyObject, Sendable {
    func availability(of kind: SmartKind) -> SmartAvailability
    /// What it would make each kind with now.
    var pins: SmartModelPins { get }
    /// The frame's input picture, made or found made; `nil` when its raw changed or `stopped` says so. It takes its own decode
    /// turn, so the queue asks for it before it takes a turn of its own. The tab's ask ahead (`MaskInference.tabShows`) is on a task
    /// that is cancelled when the tab leaves the frame: an engine should then give the picture up unless a click waits for it too.
    func picture(of frame: Frame, lens: LensSettings, stopped: @escaping @Sendable () -> Bool) async -> SmartPictureHandle?
    /// The selection of `kind` (never `.background`, which is Subject's) on `picture`, inside a turn the queue holds.
    func find(_ kind: SmartKind, on picture: SmartPictureHandle, frame: Frame, sourceSHA256: String,
              stage: @escaping @Sendable (SmartStage) -> Void) async throws -> (SmartResult, MaskFrame)
    /// Lets the Sky model go: whether it was loaded.
    func unloadSky() async -> Bool
    /// Lets go the pictures it keeps for the next click.
    func releasePictures()
    /// Whether the last `find` loaded a bundled model and let it go, so the footprint needs its settle before a develop's gate reads its floor (`MaskInference.settle`). Asking clears it.
    func takeReleasedModels() -> Bool
}

extension SmartMaskEngine {
    /// An engine that loads no bundled model has none to let go.
    public func takeReleasedModels() -> Bool { false }
}

/// The smart masks' queue: one selection at a time on a single-width `OperationQueue` of its own (R6 section 9: not an actor, since
/// the project's cancellation is operation based), each taking a preview turn with a develop's frames (`DecodeTurns.beginPreview`),
/// so a develop's frames go first and never run beside a model, and counted as a render, so the develop's memory gate reads its
/// floor only once a model is done (`DecodeTurns.beginRender`).
///
/// - **On demand**: nothing runs until a tile is clicked, except the input picture, which `tabShows` makes ahead for the frame the
///   Masks tab shows (about 0.4 s; plan section 11 rules out running at a frame's opening) and lets go of when it shows another.
/// - **Coalesced**: a selection is keyed by its frame, the raw's stamp and its kind (Background is Subject's), so a second click on
///   the same frame and kind while one runs joins it, and one already made is answered at once from `kept`.
/// - **Cancellable**: each asker holds a `Ticket`; when the last one goes the run stops between its steps. A Vision request or a
///   model's inference cannot be stopped inside, so its result is dropped.
/// - **Keyed by the source**: the result goes to the frame and the raw it was asked of, whatever frame is on screen by then.
/// - **Memory** (plan section 4, rule 5): DA3 stays loaded while the Masks tab is open (`tabOpened`), and goes with the tab
///   (`tabClosed`), before a develop (`developWillStart`), and after any Sky click made while a develop runs. EoMT, S3OD and ViTMatte are loaded and let
///   go inside the click. After a model goes the footprint settles over about 2 s (task A; V4), so the queue holds a render's count that long
///   and a develop's gate reads its floor after it.
///
/// Safe to call from any thread.
public final class MaskInference: @unchecked Sendable {
    /// How long the footprint takes to settle after a model is let go (task A: 83 to 90 MB two seconds after).
    public static let unloadSettle: TimeInterval = 2
    /// Selections kept made, by frame, stamp and kind, so a second mask of the same kind is immediate: a few hundred bytes of
    /// provenance and one seed each, at most 5 MB (a low-light Subject's 2560 px alpha).
    public static let keptOutcomes = 8

    public struct Key: Hashable, Sendable {
        public let frame: URL
        public let source: SourceStamp?
        /// The run's kind: Background asks for Subject.
        public let kind: SmartKind
    }

    /// One asker's hold on a run.
    public struct Ticket: Hashable, Sendable {
        public let id: UUID
        public let key: Key
        public let kind: SmartKind
    }

    /// What `ask` hands back: the ticket to cancel with, and the outcome, as the ticket's kind.
    public struct Asked: Sendable {
        public let ticket: Ticket
        public let outcome: Task<SmartOutcome, Never>
    }

    private final class Run: @unchecked Sendable {
        let key: Key
        var tickets: [UUID: @Sendable (SmartStage) -> Void] = [:]
        var task: Task<SmartOutcome, Never>?
        var stage: SmartStage = .queued
        var isCancelled = false
        init(key: Key) { self.key = key }
    }

    public let engine: any SmartMaskEngine
    private let turns: DecodeTurns
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var runs: [Key: Run] = [:]
    private var kept: [(key: Key, outcome: SmartOutcome)] = []
    /// How many Masks tabs are open (a window's inspector, one at a time today): DA3 is kept loaded after a Sky click only then.
    /// Counted, not a flag, since SwiftUI may show the next frame's tab before the last one's has gone.
    private var openTabs = 0
    private var keepsSky: Bool { openTabs > 0 }
    /// The picture being made ahead for the frame the Masks tab shows, one at a time, the frame it is for, and how many the tab has
    /// asked for: `nil` again once it is made.
    private var ahead: Task<Void, Never>?
    private var aheadFrame: URL?
    private var aheadGeneration = 0
    /// For the tests and the drive hook: selections run, and those answered from what was kept or joined to a run.
    private var counts = (runs: 0, joined: 0, kept: 0, unloads: 0)

    public init(engine: any SmartMaskEngine, turns: DecodeTurns) {
        self.engine = engine
        self.turns = turns
        queue.name = "camera.argent.masks.inference"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    public func availability(of kind: SmartKind) -> SmartAvailability { engine.availability(of: kind) }
    public var pins: SmartModelPins { engine.pins }

    /// Runs made, asks joined to one under way, asks answered from what was kept, and Sky models let go.
    public var statistics: (runs: Int, joined: Int, kept: Int, unloads: Int) { lock.withLock { counts } }

    // MARK: Asking

    /// Asks for `kind` on `frame`, whose raw is `sourceSHA256` as the caller verified it. `stage` is told where the run stands, at
    /// once and as it moves, on no particular thread. The outcome is `.cancelled` if the ticket is cancelled first.
    public func ask(_ kind: SmartKind, on frame: Frame, sourceSHA256: String, lens: LensSettings,
                    stage: @escaping @Sendable (SmartStage) -> Void = { _ in }) -> Asked {
        let key = Key(frame: frame.url, source: SourceStamp.of(frame.url), kind: kind == .background ? .subject : kind)
        let ticket = Ticket(id: UUID(), key: key, kind: kind)
        let (run, made, first): (Run?, SmartOutcome?, SmartStage) = lock.withLock {
            if let found = kept.first(where: { $0.key == key })?.outcome {
                counts.kept += 1
                return (nil, found, .finding)
            }
            if let running = runs[key], !running.isCancelled {
                running.tickets[ticket.id] = stage
                counts.joined += 1
                return (running, nil, running.stage)
            }
            let run = Run(key: key)
            run.tickets[ticket.id] = stage
            runs[key] = run
            counts.runs += 1
            run.task = Task.detached(priority: .userInitiated) { [self] in await perform(run, frame: frame, sourceSHA256: sourceSHA256, lens: lens) }
            return (run, nil, .queued)
        }
        stage(first)
        if let made { return Asked(ticket: ticket, outcome: Task { made.as(kind) }) }
        let task = run!.task!
        return Asked(ticket: ticket, outcome: Task { [self] in
            let outcome = await task.value
            let wanted = lock.withLock { run!.tickets.removeValue(forKey: ticket.id) != nil }
            return wanted ? outcome.as(kind) : .cancelled
        })
    }

    /// Lets go of a ticket; the run stops once no ticket holds it.
    public func cancel(_ ticket: Ticket) {
        let task: Task<SmartOutcome, Never>? = lock.withLock {
            guard let run = runs[ticket.key], run.tickets.removeValue(forKey: ticket.id) != nil, run.tickets.isEmpty else { return nil }
            run.isCancelled = true
            runs[ticket.key] = nil
            return run.task
        }
        task?.cancel()
    }

    /// Stops every run and forgets what was kept: another roll, or quitting.
    public func cancelAll() {
        let (tasks, left): ([Task<SmartOutcome, Never>], Task<Void, Never>?) = lock.withLock {
            let all = runs.values.compactMap(\.task)
            for run in runs.values { run.isCancelled = true; run.tickets = [:] }
            runs = [:]
            kept = []
            return (all, leaveAhead())
        }
        for task in tasks { task.cancel() }
        left?.cancel()
    }

    /// Whether a run for `frame` is under way.
    public func isRunning(on frame: URL) -> Bool { lock.withLock { runs.keys.contains { $0.frame == frame } } }

    /// Forgets what was kept for `frame`, so its next click asks the models again: an Update of a stale selection.
    public func forget(_ frame: URL) { lock.withLock { kept.removeAll { $0.key.frame == frame } } }

    // MARK: The Masks tab and the develop

    /// A Masks tab opened: DA3, once loaded by a Sky click, stays loaded until the last one closes. Each `tabOpened` is followed by
    /// one `tabClosed`.
    public func tabOpened() { lock.withLock { openTabs += 1 } }

    /// The Masks tab shows `frame`: its input picture is made now, so a click waits only for the model (A: 0.4 s on this display).
    /// It is this frame's alone: the one being made for the frame shown before is let go, as is this one when the tab closes, so
    /// arrowing through a roll with the tab open leaves no decode behind for a frame already left. A click on a frame joins the
    /// picture being made for it and keeps it (`SmartMaskEngine.picture`).
    public func tabShows(_ frame: Frame, lens: LensSettings) {
        let engine = engine
        let left = lock.withLock { () -> Task<Void, Never>? in
            // The same frame shown again while its picture is still being made: that one goes on.
            if ahead != nil, aheadFrame == frame.url { return nil }
            let left = ahead
            aheadGeneration += 1
            let generation = aheadGeneration
            aheadFrame = frame.url
            ahead = Task.detached(priority: .utility) { [self] in
                _ = await engine.picture(of: frame, lens: lens, stopped: { [self] in lock.withLock { aheadGeneration != generation } })
                lock.withLock {
                    guard aheadGeneration == generation else { return }
                    ahead = nil
                    aheadFrame = nil
                }
            }
            return left
        }
        left?.cancel()
    }

    /// Lets go of the picture being made ahead. Under `lock`; the caller cancels what it returns once outside it.
    private func leaveAhead() -> Task<Void, Never>? {
        defer {
            ahead = nil
            aheadFrame = nil
        }
        aheadGeneration += 1
        return ahead
    }

    /// A Masks tab closed: once none is open, DA3 goes, after any run under way, and so do the pictures kept for a click.
    public func tabClosed() {
        let (none, left) = lock.withLock { () -> (Bool, Task<Void, Never>?) in
            openTabs = max(0, openTabs - 1)
            return openTabs == 0 ? (true, leaveAhead()) : (false, nil)
        }
        left?.cancel()
        if none { unloadSky(releasingPictures: true) }
    }

    /// Whether a Masks tab is open, for the tests and the drive hook.
    public var isTabOpen: Bool { lock.withLock { keepsSky } }

    /// A develop is about to admit its first frame: DA3 goes, after any run under way. The tab may stay open; the next Sky click
    /// loads it again (0.14 s) and, while the develop runs, lets it go after.
    public func developWillStart() { unloadSky(releasingPictures: true) }

    private func unloadSky(releasingPictures: Bool) {
        let engine = engine, turns = turns
        queue.addOperation { [self] in
            let wasLoaded = Self.wait { await engine.unloadSky() } ?? false
            if releasingPictures { engine.releasePictures() }
            if wasLoaded { settle(turns) }
        }
    }

    /// Holds a render's count while the footprint settles after a model went, so a develop's gate reads its floor after it.
    private func settle(_ turns: DecodeTurns) {
        lock.withLock { counts.unloads += 1 }
        turns.beginRender()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.unloadSettle) { turns.endRender() }
    }

    /// Waits for the queue's work so far, the unloads included. For the tests.
    public func waitUntilIdle() async {
        await QueuedWork.run(on: queue) { () }
    }

    // MARK: A run

    private func perform(_ run: Run, frame: Frame, sourceSHA256: String, lens: LensSettings) async -> SmartOutcome {
        let outcome = await QueuedWork.runStoppable(on: queue, priority: .high) { [self] stopped in
            withoutActuallyEscaping(stopped) { stopped in work(run, frame: frame, sourceSHA256: sourceSHA256, lens: lens, stopped: stopped) }
        } ?? .cancelled
        lock.withLock {
            if runs[run.key] === run { runs[run.key] = nil }
            switch outcome {
            case .found, .nothingFound:
                // A raw that changed meanwhile has another stamp, so its next click is a new key.
                kept.removeAll { $0.key == run.key }
                kept.append((run.key, outcome))
                if kept.count > Self.keptOutcomes { kept.removeFirst(kept.count - Self.keptOutcomes) }
            case .failed, .cancelled: break
            }
        }
        return outcome
    }

    /// The run, on the queue's one thread: the picture, then a turn, then the engine.
    private func work(_ run: Run, frame: Frame, sourceSHA256: String, lens: LensSettings, stopped: @escaping () -> Bool) -> SmartOutcome {
        let halted: @Sendable () -> Bool = { [self] in lock.withLock { run.isCancelled } }
        let tell: @Sendable (SmartStage) -> Void = { [self] stage in
            let observers: [@Sendable (SmartStage) -> Void] = lock.withLock {
                run.stage = stage
                return Array(run.tickets.values)
            }
            for observer in observers { observer(stage) }
        }
        guard !stopped(), !halted() else { return .cancelled }
        tell(.reading)
        guard let picture = Self.wait({ [engine] in await engine.picture(of: frame, lens: lens, stopped: halted) }) ?? nil else {
            return halted() ? .cancelled : .failed("the frame could not be read; its RAW may have changed")
        }
        guard !stopped(), !halted() else { return .cancelled }
        // A develop's frames go first: the queue waits for them, as the previews' decodes do, says so once it waits, and holds its
        // turn while it runs.
        var told = false
        guard turns.beginPreview(stopped: {
            if !told { told = true; tell(.waitingForDevelop) }
            return stopped() || halted()
        }) else { return .cancelled }
        turns.beginRender()
        defer {
            turns.endRender()
            turns.endPreview()
        }
        tell(.finding)
        let kind = run.key.kind, engine = engine
        let result: Result<(SmartResult, MaskFrame), any Error>? = Self.wait {
            do { return .success(try await engine.find(kind, on: picture, frame: frame, sourceSHA256: sourceSHA256, stage: tell)) }
            catch { return .failure(error) }
        }
        // DA3 stays loaded only while the Masks tab is open and no develop runs.
        if kind == .sky, !lock.withLock({ keepsSky }) || turns.isDevelopRunning {
            if Self.wait({ await engine.unloadSky() }) == true { settle(turns) }
        }
        // S3OD and ViTMatte went inside the click; the render's count holds for their settle.
        if kind == .subject, engine.takeReleasedModels() { settle(turns) }
        guard !halted() else { return .cancelled }
        switch result {
        case .success((.seed(let seed), let maskFrame))?: return .found(seed, maskFrame)
        case .success((.nothingFound(let kind, let provenance), let maskFrame))?: return .nothingFound(kind, provenance, maskFrame)
        case .failure(let error)?: return .failed(String(describing: error))
        case nil: return .cancelled
        }
    }

    /// Waits on this thread, one of the queue's and never the cooperative pool's, for async work: the models' inference is async,
    /// and the queue's turn is a blocking wait (`DecodeTurns`).
    private static func wait<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T? {
        let box = WaitBox<T>(), done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value
    }
}

/// What `MaskInference.wait` hands from the task to the waiting thread, after the semaphore.
private final class WaitBox<T>: @unchecked Sendable {
    var value: T?
}
