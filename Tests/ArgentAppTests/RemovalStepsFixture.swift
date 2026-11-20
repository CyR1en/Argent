@testable import ArgentCore
import ArgentRoll
import AppKit
import Foundation
import Testing
@testable import ArgentApp

/// Where a fake run waits until the test lets it go, so a suite sees a run's row on the way without a clock: `arrived` returns
/// once that many runs have reached the engine, and `release` lets the oldest of them finish. A run whose task is cancelled
/// leaves at once, as the queue's does between two steps.
final class RunGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [(id: Int, continuation: CheckedContinuation<Void, any Error>)] = []
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var arrivals = 0, next = 0

    var holding: Int { lock.withLock { held.count } }

    func hold() async throws {
        let id = lock.withLock { () -> Int in next += 1; return next }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    held.append((id, continuation))
                    arrivals += 1
                    let ready = watchers.filter { $0.count <= arrivals }.map(\.continuation)
                    watchers.removeAll { $0.count <= arrivals }
                    return ready
                }
                for watcher in ready { watcher.resume() }
                // Cancelled before it was held: the handler found nothing to stop.
                if Task.isCancelled { leave(id) }
            }
        } onCancel: { leave(id) }
    }

    private func leave(_ id: Int) {
        let found = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard let index = held.firstIndex(where: { $0.id == id }) else { return nil }
            return held.remove(at: index).continuation
        }
        found?.resume(throwing: CancellationError())
    }

    /// Returns once `count` runs have reached the engine since the gate was made.
    func arrived(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let already = lock.withLock { () -> Bool in
                if arrivals >= count { return true }
                watchers.append((count, continuation))
                return false
            }
            if already { continuation.resume() }
        }
    }

    func release() {
        let oldest = lock.withLock { held.isEmpty ? nil : held.removeFirst().continuation }
        oldest?.resume()
    }
}

/// The steps of a removal with no decode, no model and no file: each records what it was asked, the run waits at a gate when the
/// test gives one, and a patch's pixels follow its seed, so Try Again draws another patch.
final class FakeRemovalSteps: RemovalSteps, @unchecked Sendable {
    struct Crop: Equatable {
        var frame: URL
        /// The removals the lens settings held, by id, in order.
        var removals: [UUID]
        var box: RemovalPatch.Box
    }

    struct Run: Equatable {
        var steps: Int
        var guidance: Float
        var seed: UInt64
    }

    struct Snap: Equatable {
        var prompt: ObjectSelector.Prompt
        var excluded: [CGPoint]
        var removals: [UUID]
    }

    enum Event: Equatable { case noteUse, developWillStart, developDidEnd }

    static let frame = RemovalFrame(width: 6000, height: 4000, geometry: nil)
    static let side = 16

    private let lock = NSLock()
    private var patches: [PatchID: RemovalPatch] = [:]
    private var recorded = (crops: [Crop](), runs: [Run](), snaps: [Snap](), events: [Event](), retried: [PatchID](), stored: [PatchID]())
    private var settings = (engine: RemovalEngineState.ready, snap: ObjectSelector.Availability.unavailable("not in this test"),
                            face: [Float]?.none, decoder: "decoder-1", frameDecoder: String?.some("decoder-1"), soft: false,
                            failure: (any Error)?.none, said: [RemovalQueue.Progress](), found: RemovalPipeline.Selection?.none,
                            heard: (@Sendable () async -> Void)?.none, heals: false, cancelsInHeal: false)
    /// Each run waits here before its last step, when a test gives one.
    let gate: RunGate?
    /// A library whose own patch store takes each patch too, for a suite whose edits are saved: the recipe writer refuses a
    /// record whose patch its library does not hold, once it is built (package B).
    let library: URL?

    init(gate: RunGate? = nil, library: URL? = nil) {
        self.gate = gate
        self.library = library
    }

    var crops: [Crop] { lock.withLock { recorded.crops } }
    var runs: [Run] { lock.withLock { recorded.runs } }
    var snaps: [Snap] { lock.withLock { recorded.snaps } }
    var events: [Event] { lock.withLock { recorded.events } }
    /// The patches plans were made again from, and the patches stored, in order.
    var retried: [PatchID] { lock.withLock { recorded.retried } }
    var stored: [PatchID] { lock.withLock { recorded.stored } }

    var engine: RemovalEngineState {
        get { lock.withLock { settings.engine } }
        set { lock.withLock { settings.engine = newValue } }
    }
    var snap: ObjectSelector.Availability {
        get { lock.withLock { settings.snap } }
        set { lock.withLock { settings.snap = newValue } }
    }
    /// What the segmenter finds; `nil` and it throws.
    var found: RemovalPipeline.Selection? {
        get { lock.withLock { settings.found } }
        set { lock.withLock { settings.found = newValue } }
    }
    /// Whether a new selection's surroundings are smooth: its patch is then made with no run.
    var heals: Bool {
        get { lock.withLock { settings.heals } }
        set { lock.withLock { settings.heals = newValue } }
    }
    /// The removal is cancelled while its patch is being made with no model.
    var cancelsInHeal: Bool {
        get { lock.withLock { settings.cancelsInHeal } }
        set { lock.withLock { settings.cancelsInHeal = newValue } }
    }
    /// The face the next patches say they redrew.
    var face: [Float]? {
        get { lock.withLock { settings.face } }
        set { lock.withLock { settings.face = newValue } }
    }
    /// The decoder the next crops come from, and the one the frame goes to now.
    var decoder: String {
        get { lock.withLock { settings.decoder } }
        set { lock.withLock { settings.decoder = newValue } }
    }
    var frameDecoder: String? {
        get { lock.withLock { settings.frameDecoder } }
        set { lock.withLock { settings.frameDecoder = newValue } }
    }
    /// The next patches lie over a box more than twice their raster's size.
    var soft: Bool {
        get { lock.withLock { settings.soft } }
        set { lock.withLock { settings.soft = newValue } }
    }
    /// What the queue says of each run before it reaches the gate.
    var said: [RemovalQueue.Progress] {
        get { lock.withLock { settings.said } }
        set { lock.withLock { settings.said = newValue } }
    }

    /// Called after the row has been told each of `said`, and its last step: where a test reads the row on the way.
    var heard: (@Sendable () async -> Void)? {
        get { lock.withLock { settings.heard } }
        set { lock.withLock { settings.heard = newValue } }
    }

    /// The next run throws this instead of drawing.
    func failNext(_ failure: any Error) { lock.withLock { settings.failure = failure } }

    /// A patch the library holds no more.
    func lose(_ id: PatchID) { lock.withLock { patches[id] = nil } }

    func patch(_ id: PatchID) -> RemovalPatch? { lock.withLock { patches[id] } }

    func frame(_ frame: Frame, lens: LensSettings) async throws -> RemovalFrame { Self.frame }

    /// A small box whose corner is the selection's first pixel, so two selections plan two boxes.
    func plan(_ selection: RemovalPipeline.Selection, on frame: RemovalFrame) throws -> RemovalPipeline.Plan {
        let first = selection.coverage.firstIndex { $0 >= 128 } ?? 0
        let side = soft ? 4 * Self.side : Self.side
        let x = min(frame.width - side, (first % selection.width) * frame.width / selection.width)
        let y = min(frame.height - side, (first / selection.width) * frame.height / selection.height)
        return try RemovalPipeline.Plan(box: try RemovalPatch.Box(x: x, y: y, width: side, height: side),
                                        object: [UInt8](repeating: 255, count: side * side), frameWidth: frame.width, frameHeight: frame.height)
    }

    func plan(retrying patch: RemovalPatch, on frame: RemovalFrame) throws -> RemovalPipeline.Plan {
        lock.withLock { recorded.retried.append(patch.identity) }
        return try RemovalPipeline.Plan(box: patch.box, object: [UInt8](repeating: 255, count: patch.box.width * patch.box.height),
                                        frameWidth: frame.width, frameHeight: frame.height)
    }

    func crop(_ frame: Frame, lens: LensSettings, box: RemovalPatch.Box) async throws -> RemovalPipeline.Crop {
        lock.withLock { recorded.crops.append(Crop(frame: frame.url, removals: lens.removals.map(\.id), box: box)) }
        return try RemovalPipeline.Crop(box: box, rgb: [Float16](repeating: 0.18, count: box.width * box.height * 3), decoder: decoder)
    }

    func prepare(_ crop: RemovalPipeline.Crop, plan: RemovalPipeline.Plan, steps: Int, guidance: Float, seed: UInt64) throws -> RemovalPipeline.Prepared {
        let side = Self.side
        let job = try RemovalJob(width: side, height: side, image: [UInt8](repeating: 118, count: side * side * 3),
                                 mask: [UInt8](repeating: 255, count: side * side), steps: steps, guidance: guidance, seed: seed)
        return RemovalPipeline.Prepared(job: job, plan: plan, crop: crop, gain: 1, original: [Float](repeating: 0.18, count: side * side * 3))
    }

    func run(_ job: RemovalJob, progress: @escaping @Sendable (RemovalQueue.Progress) async -> Void) async throws -> RemovalOutput {
        let (failure, said, heard) = lock.withLock { () -> ((any Error)?, [RemovalQueue.Progress], (@Sendable () async -> Void)?) in
            recorded.runs.append(Run(steps: job.steps, guidance: job.guidance, seed: job.seed))
            defer { settings.failure = nil }
            return (settings.failure, settings.said, settings.heard)
        }
        for word in said {
            await progress(word)
            await heard?()
        }
        try await gate?.hold()
        try Task.checkCancellation()
        if let failure { throw failure }
        await progress(.step(job.steps, of: job.steps))
        await heard?()
        return try RemovalOutput(width: job.width, height: job.height, image: job.image, attention: job.mask,
                                 engine: FakeRemovalEngine.engineID, weights: FakeRemovalEngine.weightsID)
    }

    func finish(_ output: RemovalOutput, prepared: RemovalPipeline.Prepared, faces: [FaceMeasure]) throws -> RemovalPatch {
        let count = output.width * output.height, job = prepared.job
        // The seed is in the pixels, so another seed is another patch.
        let value = Float16(Float(job.seed % 4096) / 4096)
        let notes = RemovalPatch.Notes(engine: output.engine, weights: output.weights, steps: job.steps, guidance: job.guidance, seed: job.seed,
                                       decoder: prepared.crop.decoder, frameWidth: prepared.plan.frameWidth, frameHeight: prepared.plan.frameHeight,
                                       face: face)
        return try RemovalPatch(box: prepared.plan.box, width: output.width, height: output.height, rgb: [Float16](repeating: value, count: count * 3),
                                objectAlpha: [UInt8](repeating: 255, count: count), effectsAlpha: [UInt8](repeating: 255, count: count), notes: notes)
    }

    func heal(_ prepared: RemovalPipeline.Prepared, faces: [FaceMeasure]) throws -> RemovalPatch? {
        guard heals else { return nil }
        if cancelsInHeal { withUnsafeCurrentTask { $0?.cancel() } }
        let job = prepared.job, count = job.width * job.height
        let notes = RemovalPatch.Notes(engine: RemovalPipeline.healEngine, seed: job.seed, decoder: prepared.crop.decoder,
                                       frameWidth: prepared.plan.frameWidth, frameHeight: prepared.plan.frameHeight)
        return try RemovalPatch(box: prepared.plan.box, width: job.width, height: job.height,
                                // Never the pixels `finish` gives any seed, which are under 1: a patch is its pixels' hash.
                                rgb: [Float16](repeating: Float16(2 + Float(job.seed % 4096) / 4096), count: count * 3),
                                objectAlpha: [UInt8](repeating: 255, count: count), effectsAlpha: [UInt8](repeating: 255, count: count), notes: notes)
    }

    func store(_ patch: RemovalPatch) throws -> PatchRef {
        lock.withLock {
            patches[patch.identity] = patch
            recorded.stored.append(patch.identity)
        }
        if let library { _ = try? PatchStore(library: library).store(patch) }
        return patch.ref
    }

    func load(_ ref: PatchRef) throws -> RemovalPatch {
        guard let patch = lock.withLock({ patches[ref.id] }) else { throw PatchStore.Failure.missing(ref.id) }
        return patch
    }

    func snapAvailability() async -> ObjectSelector.Availability { snap }

    func snap(_ prompt: ObjectSelector.Prompt, excluded: [CGPoint], on frame: Frame, lens: LensSettings) async throws -> RemovalPipeline.Selection {
        lock.withLock { recorded.snaps.append(Snap(prompt: prompt, excluded: excluded, removals: lens.removals.map(\.id))) }
        guard let found else { throw RemovalError.notBuilt("Snap to Object", package: "G") }
        return found
    }

    func decoder(for frame: Frame) -> String? { frameDecoder }

    func geometry(for frame: Frame, lens: LensSettings) -> LensGeometry? { nil }

    var engineState: RemovalEngineState { engine }

    func noteUse() { lock.withLock { recorded.events.append(.noteUse) } }

    /// The working sizes the engine was told to expect, in order.
    var sizes: [[Int]] { lock.withLock { announced } }
    private var announced: [[Int]] = []
    func prepareSize(width: Int, height: Int) { lock.withLock { announced.append([width, height]) } }

    func developWillStart() async { lock.withLock { recorded.events.append(.developWillStart) } }

    func developDidEnd() { lock.withLock { recorded.events.append(.developDidEnd) } }
}

/// A roll of two frames whose first is ready to adjust, on fake steps, with an undo manager of its own that groups nothing by
/// itself: what the Remove suites start from.
@MainActor struct RemoveFixture {
    let model: RollModel
    let frame: Frame
    let folder: URL
    let steps: FakeRemovalSteps
    /// What the model writes to the defaults when a suite opens the Remove tab, as it was: a later suite's model must not start
    /// on that tab.
    private let shown = UserDefaults.standard.object(forKey: "manualInspectorShown")
    private let stored = UserDefaults.standard.object(forKey: AdjustInspectorTab.storageKey)

    private static func header(_ url: URL) throws {
        func u16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255)] }
        func u32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(n >> (8 * $0) & 255) } }
        var b: [UInt8] = [0x49, 0x49] + u16(42) + u32(8)
        b += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(26) + u32(0)
        b += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(100) + u16(0) + u32(0)
        try Data(b).write(to: url, options: .atomic)
    }

    /// The first frame holds `adjustments`, pinned on its raw as it is.
    init(_ adjustments: ManualAdjustments = try! ManualAdjustments(exposureEV: 0.5), gate: RunGate? = nil) async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-remove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.header(folder.appendingPathComponent("DSC1.ARW"))
        try Self.header(folder.appendingPathComponent("DSC2.ARW"))
        model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                          stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                          recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        await model.open(folder)
        if let restore = model.manualRestoreTask { await restore.value }
        frame = try #require(model.selectedFrame)
        for each in model.roll?.frames ?? [] { try Self.pin(each, in: model, adjustments: each.url == frame.url ? adjustments : nil) }
        model.manualUndoManager = UndoManager()
        model.manualUndoManager?.groupsByEvent = false
        steps = FakeRemovalSteps(gate: gate)
        model.removalRuns.steps = steps
        model.removalRuns.showsTab = true
    }

    /// `frame` measured and its raw verified, with an edit holding `adjustments` when there are any.
    static func pin(_ frame: Frame, in model: RollModel, adjustments: ManualAdjustments?) throws {
        let verified = try SourceDigests.shared.digest(of: frame.url)
        model.manualReadySources[frame.url] = verified
        model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 0.3, validWeight: 1), source: verified.source), for: frame)
        guard let adjustments else { return }
        let pin = AutomaticBaseline(sourceSHA256: verified.sha256, stockID: "test", stockDigest: "digest",
            controls: .init(), aim: PrintAim(level: -0.65, cast: SIMD3(0.2, -0.1, 0.15)), analysisVersion: ExposureAnalysis.currentVersion,
            baseRender: Recipe.Render(settings: DevelopSettings(labBalance: SIMD3(0.1, 0.2, 0.3)), grain: .off))
        model.manualEdits[frame.url] = ManualEdit(adjustments: adjustments, baseline: pin)
    }

    func close() {
        UserDefaults.standard.set(shown, forKey: "manualInspectorShown")
        UserDefaults.standard.set(stored, forKey: AdjustInspectorTab.storageKey)
        try? FileManager.default.removeItem(at: folder)
    }

    var removals: [Removal] { model.manualAdjustments(for: frame).removals }
    var rows: [RemovalRowState] { model.removalRows(for: frame) }
    var undo: UndoManager { model.manualUndoManager! }
}

@MainActor extension RollModel {
    /// A press, drags and a release of the Remove brush through `points`, fractions of the picture; one point is a click.
    func paintRemoval(_ points: [CGPoint], option: Bool = false, on frame: Frame) {
        func event(_ phase: MaskCanvasEvent.Phase, _ point: CGPoint) -> MaskCanvasEvent {
            MaskCanvasEvent(phase: phase, fractions: point, point: CGPoint(x: point.x * 900, y: point.y * 600),
                            modifiers: option ? .option : [], clickCount: 1)
        }
        guard let first = points.first, let last = points.last else { return }
        removeBrush(event(.press, first), on: frame)
        for point in points.dropFirst() { removeBrush(event(.drag, point), on: frame) }
        removeBrush(event(.release, last), on: frame)
    }

    /// Paints a short stroke at `x` across the picture and presses Return: one removal asked for.
    func removeObject(at x: CGFloat = 0.3, on frame: Frame) {
        removeTabShown(for: frame)
        paintRemoval([CGPoint(x: x, y: 0.4), CGPoint(x: x + 0.05, y: 0.45)], on: frame)
        commitRemoval(on: frame)
    }
}
