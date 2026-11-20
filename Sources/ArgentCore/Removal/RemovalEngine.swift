import Foundation

/// What the model that removes an object is doing, as the Remove tab's rows say it (docs/remove-plan.md, section 4.5).
public enum RemovalEngineState: Sendable, Equatable {
    /// There is no engine to run, and why: the bundle has no helper or no graphs, or the helper did not start.
    case absent(String)
    /// Present and not loaded: it holds no memory.
    case idle
    /// The one-time compile after an install or a macOS update, and how far it is where the engine can tell.
    case preparing(Double?)
    case loading
    case ready
    case running
}

/// One run of the model: the crop and the object's mask at the working size, as the pipeline encoded them
/// (`RemovalPipeline.prepare`). It is what `run_oc.py` of the research takes, so the helper's output can be held against PyTorch's.
public struct RemovalJob: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// The crop, 8 bits a channel, red, green and blue: `width * height * 3` values, row 0 the top.
    public let image: [UInt8]
    /// The object, 0 outside and 255 inside: `width * height` values.
    public let mask: [UInt8]
    public let steps: Int
    public let guidance: Float
    public let seed: UInt64

    /// The defaults a removal runs at, and what Better runs at (the repository's own). Twenty steps, not the eight that were the
    /// first default: at eight the leaves round a road sign came out smeared and a ghost of the sign stayed, at twenty they had
    /// their structure, and thirty and forty drew what twenty drew. Guidance 1 against 2.5 at twenty steps made no difference
    /// that could be told on a sign, a letter box and a wall, at half the model's calls; another seed made far more.
    public static let defaultSteps = 20
    public static let defaultGuidance: Float = 1
    public static let betterSteps = 20
    public static let betterGuidance: Float = 2.5

    public init(width: Int, height: Int, image: [UInt8], mask: [UInt8], steps: Int = RemovalJob.defaultSteps,
                guidance: Float = RemovalJob.defaultGuidance, seed: UInt64) throws {
        let multiple = RemovalPatch.sideMultiple
        guard PatchRef.sideRange.contains(width), PatchRef.sideRange.contains(height),
              width.isMultiple(of: multiple), height.isMultiple(of: multiple) else {
            throw RemovalError.invalid("a job's sides are multiples of \(multiple)")
        }
        guard image.count == width * height * 3, mask.count == width * height else {
            throw RemovalError.invalid("a job's picture and mask are its width by its height")
        }
        guard (1...100).contains(steps), guidance.isFinite, guidance >= 1 else {
            throw RemovalError.invalid("a job runs 1 to 100 steps at a guidance of 1 or more")
        }
        self.width = width; self.height = height; self.image = image; self.mask = mask
        self.steps = steps; self.guidance = guidance; self.seed = seed
    }
}

/// What a run gives back: the model's picture and its attention map, the model's estimate of the object and its effects, both at
/// the job's size, and which engine and weights drew them.
public struct RemovalOutput: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let image: [UInt8]
    public let attention: [UInt8]
    public let engine: String
    public let weights: String

    public init(width: Int, height: Int, image: [UInt8], attention: [UInt8], engine: String, weights: String) throws {
        guard image.count == width * height * 3, attention.count == width * height else {
            throw RemovalError.invalid("an output's picture and attention map are its width by its height")
        }
        self.width = width; self.height = height; self.image = image; self.attention = attention
        self.engine = engine; self.weights = weights
    }
}

/// A run that ended without a picture.
public enum RemovalRunFailure: Error, Equatable, LocalizedError {
    /// The engine said why.
    case failed(String)
    /// The engine stopped answering and was put down; the row offers Try Again.
    case unresponsive

    public var errorDescription: String? {
        switch self {
        case .failed(let why): "The removal failed: \(why)"
        case .unresponsive: "The model stopped answering"
        }
    }
}

/// The model, wherever it runs: the bundled helper, behind `FolderEngine`, and a fake in every test. The app is built against this and never against a model (docs/remove-plan.md, section 2). `RemovalQueue` decides when to
/// load and unload; an engine only does as it is told. Safe to call from any thread.
public protocol RemovalEngine: Sendable {
    var state: RemovalEngineState { get }
    /// Starts loading and returns at once; `state` says how far it is. Loading what is loaded does nothing.
    func load()
    /// Returns once the model's memory is back: for the helper, once its process is gone.
    func unload() async
    /// Runs one job, loading first if it must, and calls `step` with each finished step and the job's count. Cancelling the task
    /// stops the run between two steps and throws `CancellationError`.
    func run(_ job: RemovalJob, step: @escaping @Sendable (Int, Int) -> Void) async throws -> RemovalOutput
    /// A job of this working size is likely next: an engine that compiles for a size does it now (`RemovalFolder.prepareFile`).
    /// A hint, which returns at once and which an engine may ignore.
    func prepare(width: Int, height: Int)
}

extension RemovalEngine {
    public func prepare(width: Int, height: Int) {}
}

/// An engine with no model, for every suite: it paints the object's mask with the mean of what lies outside it, and marks as
/// attention the mask grown by `effectReach` pixels, which stands for a shadow. It counts what it was asked, waits as long as it
/// is told to, and fails or stops answering on request, so a queue's rules can be tested in milliseconds.
public final class FakeRemovalEngine: RemovalEngine, @unchecked Sendable {
    public static let engineID = "fake"
    public static let weightsID = String(repeating: "0", count: 64)

    public struct Counts: Sendable, Equatable {
        public var loads = 0, unloads = 0, runs = 0, cancelled = 0
    }

    private let lock = NSLock()
    private var current: RemovalEngineState
    private var tally = Counts()
    private let loadDelay: Duration
    private let stepDelay: Duration
    private let effectReach: Int
    private var failure: RemovalRunFailure?

    public init(state: RemovalEngineState = .idle, loadDelay: Duration = .zero, stepDelay: Duration = .zero, effectReach: Int = 8) {
        current = state
        self.loadDelay = loadDelay; self.stepDelay = stepDelay; self.effectReach = effectReach
    }

    public var state: RemovalEngineState { lock.withLock { current } }
    public var counts: Counts { lock.withLock { tally } }
    /// The next run throws this instead of drawing.
    public func failNext(_ failure: RemovalRunFailure) { lock.withLock { self.failure = failure } }

    public func load() {
        let starts = lock.withLock { () -> Bool in
            guard current == .idle else { return false }
            current = .loading
            tally.loads += 1
            return true
        }
        guard starts else { return }
        Task { [self] in
            try? await Task.sleep(for: loadDelay)
            lock.withLock { if current == .loading { current = .ready } }
        }
    }

    public func unload() async {
        lock.withLock {
            if case .absent = current { return }
            if current != .idle { tally.unloads += 1 }
            current = .idle
        }
    }

    public func run(_ job: RemovalJob, step: @escaping @Sendable (Int, Int) -> Void) async throws -> RemovalOutput {
        if case .absent(let why) = state { throw RemovalRunFailure.failed(why) }
        load()
        while state == .loading { try await Task.sleep(for: .milliseconds(1)) }
        let failure = lock.withLock { () -> RemovalRunFailure? in
            defer { self.failure = nil }
            current = .running
            tally.runs += 1
            return self.failure
        }
        defer { lock.withLock { if current == .running { current = .ready } } }
        if let failure { throw failure }
        do {
            for done in 1...job.steps {
                try await Task.sleep(for: stepDelay)
                try Task.checkCancellation()
                step(done, job.steps)
            }
        } catch {
            lock.withLock { tally.cancelled += 1 }
            throw CancellationError()
        }
        return try Self.drawn(job, effectReach: effectReach)
    }

    private static func drawn(_ job: RemovalJob, effectReach: Int) throws -> RemovalOutput {
        let w = job.width, h = job.height
        var sum = [0, 0, 0], outside = 0
        for p in 0..<(w * h) where job.mask[p] < 128 {
            for c in 0..<3 { sum[c] += Int(job.image[p * 3 + c]) }
            outside += 1
        }
        let fill = sum.map { UInt8(outside == 0 ? 128 : $0 / outside) }
        var image = job.image
        for p in 0..<(w * h) where job.mask[p] >= 128 { for c in 0..<3 { image[p * 3 + c] = fill[c] } }
        // The mask grown by a square: rows, then columns.
        var rows = [UInt8](repeating: 0, count: w * h), attention = rows
        for y in 0..<h {
            for x in 0..<w where job.mask[y * w + x] >= 128 {
                for near in max(0, x - effectReach)...min(w - 1, x + effectReach) { rows[y * w + near] = 255 }
            }
        }
        for y in 0..<h {
            for x in 0..<w where rows[y * w + x] != 0 {
                for near in max(0, y - effectReach)...min(h - 1, y + effectReach) { attention[near * w + x] = 255 }
            }
        }
        return try RemovalOutput(width: w, height: h, image: image, attention: attention, engine: engineID, weights: weightsID)
    }
}
