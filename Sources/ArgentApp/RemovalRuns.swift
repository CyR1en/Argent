import ArgentCore
import ArgentRoll
import CoreGraphics
import Foundation
import Observation

/// Remove in the session, beyond what the tab reads from `RemoveSession`: the steps that do the work, the runs under way, and what
/// each patch says of itself. Owned by `RollModel` as its own object, as `SmartMasks` is; the removals themselves are the frame's
/// edit, written through `RollModel`'s gestures (`RollModel+Remove.swift`).
@MainActor @Observable
final class RemovalRuns {
    /// What a removal's row and outline need of its patch, read from the patch once.
    struct PatchFacts: Equatable, Sendable {
        /// The library has no file for it, or one that does not hold its pixels.
        var isMissing = false
        /// The box of a face it drew new pixels in, as fractions of the upright frame.
        var face: [Float]?
        /// The decoder its crop was cut from.
        var decoder: String?
        var isSoft = false
        /// No model drew it: its surroundings were smooth and it was filled from them (`RemovalPipeline.healed`).
        var isHealed = false
        var box: RemovalPatch.Box?
        /// The full-size decode it was cut from, which places `box` in the picture.
        var frameWidth: Int?
        var frameHeight: Int?

        static let missing = PatchFacts(isMissing: true)

        init(isMissing: Bool = false) { self.isMissing = isMissing }

        init(_ patch: RemovalPatch) {
            face = patch.notes.face
            decoder = patch.notes.decoder
            isSoft = patch.isSoftAtFullSize
            isHealed = patch.notes.engine == RemovalPipeline.healEngine
            box = patch.box
            frameWidth = patch.notes.frameWidth
            frameHeight = patch.notes.frameHeight
        }
    }

    /// A patch's object as its outline draws it: the alpha at the patch's own size.
    struct Outline: Equatable, Sendable {
        var width: Int
        var height: Int
        var values: [UInt8]

        init(_ patch: RemovalPatch) {
            width = patch.width; height = patch.height; values = patch.objectAlpha
        }
    }

    /// A run under way: a removal with no patch yet, or one being made again.
    struct Run {
        /// The removal's id: the one it takes when its patch arrives, or the one it has.
        let id: UUID
        /// This run and no other of the same removal: Try Again after a cancel is another.
        let token = UUID()
        let frame: URL
        let isRemake: Bool
        /// The selection as it was at Return, for a run with no patch to outline.
        var outline: RemoveCoverage?
        var task: Task<Void, Never>?
    }

    /// How many outlines are kept: a frame's rows the pointer has been over.
    static let outlinesKept = 16

    private(set) var facts: [PatchID: PatchFacts] = [:]
    private(set) var outlines: [PatchID: Outline] = [:]
    /// Whether the selection can be removed, and the frames with a run under way: what the menu bar asks, each written only when
    /// it changes, so a stroke's points do not rebuild the menus (`RollModel.followMenuState`).
    private(set) var canRemove = false
    private(set) var busyFrames: Set<URL> = []

    /// Whether the Adjust inspector has its Remove tab: the build's switch, which a suite turns on for itself.
    @ObservationIgnored var showsTab = AdjustInspectorTab.showsRemove
    /// The steps; made on first use from the film previews and the library, or given by a test.
    @ObservationIgnored var steps: (any RemovalSteps)?
    /// What makes the steps when none were given: the app's.
    @ObservationIgnored var makeSteps: (() -> (any RemovalSteps)?)?

    @ObservationIgnored private var runs: [UUID: Run] = [:]
    /// The runs under way, oldest first.
    @ObservationIgnored private var order: [UUID] = []
    /// Each frame's newest run's task, which the next run of the frame goes after.
    @ObservationIgnored private var chain: [URL: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var outlineOrder: [PatchID] = []
    @ObservationIgnored private var reading: [PatchID: Task<Void, Never>] = [:]
    /// Arrivals waiting for a gesture open on their frame to end.
    @ObservationIgnored private var waiting: [URL: [CheckedContinuation<Void, Never>]] = [:]
    /// Told when an arrival begins to wait for a frame's gesture, for tests.
    @ObservationIgnored var observeGestureWait: ((URL) -> Void)?
    /// Each frame's decoder as the rows last asked for it.
    @ObservationIgnored private var decoders: [URL: String] = [:]
    /// The stroke under the pointer: where it was pressed in the frame view's area, and how far the pointer has been from there,
    /// which tells a click from a stroke.
    struct Stroke {
        var start: CGPoint
        var travel: CGFloat = 0
    }

    /// The object the last stroke snapped to: what was asked, what was selected before it, and the places said not to be it.
    /// An Option-click adds a place and asks again, so an object the segmenter joined to another comes apart.
    struct Snapped {
        var prompt: ObjectSelector.Prompt
        var before: RemoveCoverage?
        var excluded: [CGPoint] = []
    }

    @ObservationIgnored var stroke: Stroke?
    @ObservationIgnored var snapped: Snapped?
    /// Strokes being snapped to their objects, in the order they were drawn, and how many have not landed.
    @ObservationIgnored var snapTask: Task<Void, Never>?
    @ObservationIgnored var snapsWaiting = 0
    /// Advances when the selection is dropped: a snap that lands after is for a selection that has gone.
    @ObservationIgnored var snapGeneration = 0
    /// The plan being made of what is selected, to tell the engine the size its job will have (`RollModel.announceRemoveSize`).
    @ObservationIgnored var sizeTask: Task<Void, Never>?
    @ObservationIgnored var availabilityTask: Task<Void, Never>?

    /// The steps, made if need be; `nil` without film previews (no stocks), when nothing can be removed.
    var work: (any RemovalSteps)? {
        if steps == nil { steps = makeSteps?() }
        return steps
    }

    // MARK: runs

    func run(_ id: UUID) -> Run? { runs[id] }

    /// Whether `token` is still the run of its removal: not cancelled, ended or replaced.
    func isCurrent(_ id: UUID, _ token: UUID) -> Bool { runs[id]?.token == token }

    /// The frame's runs under way, oldest first.
    func runs(on frame: URL) -> [Run] { order.compactMap { runs[$0] }.filter { $0.frame == frame } }

    /// The task the frame's next run goes after.
    func last(on frame: URL) -> Task<Void, Never>? { chain[frame]?.task }

    func begin(_ run: Run) {
        runs[run.id] = run
        order.append(run.id)
        if !busyFrames.contains(run.frame) { busyFrames.insert(run.frame) }
    }

    func setTask(_ task: Task<Void, Never>, for id: UUID) {
        guard var run = runs[id] else { return }
        run.task = task
        runs[id] = run
        chain[run.frame] = (run.token, task)
    }

    /// The run is over, however it ended. Its task is left to finish by itself.
    @discardableResult
    func end(_ id: UUID) -> Run? {
        guard let run = runs.removeValue(forKey: id) else { return nil }
        order.removeAll { $0 == id }
        if !runs.values.contains(where: { $0.frame == run.frame }), busyFrames.contains(run.frame) { busyFrames.remove(run.frame) }
        return run
    }

    /// The frame's chain is let go once its newest run's task has ended.
    func finished(_ token: UUID, on frame: URL) {
        if chain[frame]?.token == token { chain[frame] = nil }
    }

    /// Every task still working for `frames`, or for every frame: what `RollModel.removalsSettled` waits for.
    func tasks(on frames: Set<URL>? = nil) -> [Task<Void, Never>] {
        let chained = chain.filter { frames?.contains($0.key) ?? true }.map(\.value.task)
        return chained + Array(reading.values) + [snapTask, availabilityTask].compactMap { $0 }
    }

    // MARK: gestures

    /// Returns once the gesture open on `frame` has ended: `gestureEnded` says when.
    func waitForGesture(on frame: URL) async {
        await withCheckedContinuation { waiter in
            waiting[frame, default: []].append(waiter)
            observeGestureWait?(frame)
        }
    }

    func gestureEnded(on frame: URL) {
        for waiter in waiting.removeValue(forKey: frame) ?? [] { waiter.resume() }
    }

    // MARK: patches

    func note(_ patch: RemovalPatch) {
        set(PatchFacts(patch), for: patch.identity)
        keep(Outline(patch), for: patch.identity)
    }

    func set(_ found: PatchFacts, for id: PatchID) {
        if facts[id] != found { facts[id] = found }
    }

    func keep(_ outline: Outline, for id: PatchID) {
        outlineOrder.removeAll { $0 == id }
        outlineOrder.append(id)
        outlines[id] = outline
        while outlineOrder.count > Self.outlinesKept { outlines[outlineOrder.removeFirst()] = nil }
    }

    func isReading(_ id: PatchID) -> Bool { reading[id] != nil }

    func setReading(_ task: Task<Void, Never>?, for id: PatchID) { reading[id] = task }

    func decoder(for frame: Frame) -> String? {
        if let known = decoders[frame.url] { return known }
        let found = work?.decoder(for: frame)
        decoders[frame.url] = found
        return found
    }

    /// The frame's decoder is asked again: the tab came to show it, and a session can send a file to another decoder.
    func forgetDecoder(for frame: URL) { decoders[frame] = nil }

    // MARK: the menu bar's facts

    func noteSelection(canRemove: Bool) {
        if self.canRemove != canRemove { self.canRemove = canRemove }
    }

    /// Stops every run and forgets the session's: another roll, or this one again.
    func reset() {
        for run in runs.values { run.task?.cancel() }
        snapTask?.cancel()
        snapTask = nil
        sizeTask?.cancel()
        sizeTask = nil
        availabilityTask?.cancel()
        availabilityTask = nil
        snapGeneration += 1
        snapsWaiting = 0
        stroke = nil; snapped = nil
        runs = [:]; order = []; chain = [:]
        for waiters in waiting.values { for waiter in waiters { waiter.resume() } }
        waiting = [:]
        for task in reading.values { task.cancel() }
        facts = [:]; outlines = [:]; outlineOrder = []; reading = [:]; decoders = [:]
        if canRemove { canRemove = false }
        if !busyFrames.isEmpty { busyFrames = [] }
    }
}
