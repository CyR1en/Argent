import AppKit
import ArgentCore
import ArgentRoll
import Foundation
import Observation
import QuartzCore

/// Smart masks in the session: the selections asked for and where each stands, what arrived, and the notes a Keep dismissed. Owned
/// by `RollModel` as its own object, as `MaskEditor` is, so a run's stage reaches only the rows that read it. The masks themselves
/// are the frame's edit, written through `RollModel`'s gestures (`RollModel+SmartMasks.swift`).
///
/// A click is one undo step, at the click: the row appears at once with its selection not yet made, and the result arrives into
/// that mask with no step of its own (plan section 11, "Undo for a smart mask"). So a result is attached to its mask, by id, and
/// an undo state that predates it is filled as it is restored (`arrived`); undoing the click while it runs cancels it, and redoing
/// it asks again.
@MainActor @Observable
final class SmartMasks {
    /// A selection asked for, by the frame and mask that asked.
    struct RunKey: Hashable, Sendable {
        let frame: URL
        let mask: UUID
    }

    /// Where a mask's selection stands, while the row has something to say about it.
    enum State: Equatable {
        /// Asked for and under way, at this stage; `update` for a stale seed being made again, whose old one stays meanwhile.
        case working(SmartStage, update: Bool)
        /// Nothing of the kind in the frame, with the frame it looked at, for a brush in its place.
        case empty(MaskFrame?)
        /// The engine failed, with why.
        case failed(String)
        /// An Update that found nothing: the mask keeps its seed.
        case updateFoundNothing
    }

    struct Run: Equatable {
        var kind: SmartKind
        var state: State
        var ticket: MaskInference.Ticket?
        /// The raw's stamp when asked: a result for another version of it is dropped.
        var source: SourceStamp?
    }

    /// What arrived for a mask: the selection to put back in an undo state that predates it, and its provenance.
    struct Arrival: Equatable {
        let kind: SmartKind
        let selection: SmartSelection
        let provenance: RasterProvenance
    }

    /// The click, the first word the row showed, the result's arrival and the overlay put up with it: click-to-red, for the drive hook.
    struct Timing: Equatable {
        var clicked: CFTimeInterval
        var firstStage: CFTimeInterval?
        var arrived: CFTimeInterval?
        var shown: CFTimeInterval?
        var stages: [String] = []
    }

    /// Where each Keep is remembered: a seed's raster id to the model it was kept against (`SmartModelPins.pin`). A view preference,
    /// as the overlay's colour is, not part of the edit: the note is about a model, and the seed is the pin.
    static let keptKey = "smartMaskStaleKept"

    private(set) var runs: [RunKey: Run] = [:]
    private(set) var kept: [String: String]

    @ObservationIgnored var arrived: [UUID: Arrival] = [:]
    /// The tasks that put each selection into its mask when it comes, by the ask's id, so a develop can wait for them.
    @ObservationIgnored var fills: [RunKey: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored var timings: [UUID: Timing] = [:]
    /// The queue; made on first use from the film previews and the bundled models, or given by a test.
    @ObservationIgnored var inference: MaskInference? {
        didSet { cachedAvailability = [:] }
    }
    /// What makes the engine when none was given: the app's, from the previews and its library.
    @ObservationIgnored var makeInference: (() -> MaskInference?)?
    @ObservationIgnored private var cachedPins: SmartModelPins?
    @ObservationIgnored private var cachedAvailability: [SmartKind: SmartAvailability] = [:]
    /// Where the Keeps are remembered; a test gives its own.
    @ObservationIgnored var defaults: UserDefaults {
        didSet { kept = Self.kept(in: defaults) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        kept = Self.kept(in: defaults)
    }

    private static func kept(in defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: keptKey) as? [String: String] ?? [:]
    }

    /// The queue, made if need be; `nil` without film previews (no stocks), when no tile is live.
    var queue: MaskInference? {
        if inference == nil { inference = makeInference?() }
        return inference
    }

    /// What this build makes each kind with, read once.
    var pins: SmartModelPins? {
        if cachedPins == nil { cachedPins = queue?.pins }
        return cachedPins
    }

    /// Whether this build and this Mac can make `kind`, read once a queue, as `pins` is; `nil` with no queue. The picker asks for
    /// every tile each time it is drawn, and the engine's answer for Sky reads two models' hashes and manifests from the bundle,
    /// which do not change under a running app.
    func availability(of kind: SmartKind) -> SmartAvailability? {
        guard let queue else { return nil }
        if let cached = cachedAvailability[kind] { return cached }
        let found = queue.availability(of: kind)
        cachedAvailability[kind] = found
        return found
    }

    func run(_ key: RunKey) -> Run? { runs[key] }

    func setRun(_ run: Run?, for key: RunKey) {
        if runs[key] != run { runs[key] = run }
    }

    func setStage(_ stage: SmartStage, for key: RunKey) {
        guard var run = runs[key], case .working(let old, let update) = run.state, old != stage else { return }
        run.state = .working(stage, update: update)
        runs[key] = run
        if var timing = timings[key.mask] {
            if timing.firstStage == nil { timing.firstStage = CACurrentMediaTime() }
            timing.stages.append(SmartRowStatus.words(for: stage, kind: run.kind, update: update))
            timings[key.mask] = timing
        }
    }

    func keep(_ raster: RasterID, against pin: String) {
        kept[raster.hex] = pin
        defaults.set(kept, forKey: Self.keptKey)
    }

    /// Stops every run and forgets the session's: another roll, or quitting.
    func reset() {
        inference?.cancelAll()
        for fill in fills.values { fill.task.cancel() }
        fills = [:]
        runs = [:]
        arrived = [:]
        timings = [:]
    }
}

/// What a smart mask's row says while its selection is not simply made: a named stage while it runs, the quiet empty state, a
/// failure, a selection never made, or a seed made with an earlier model; and what can be done about it. Pure, so the words are
/// held by `SmartMaskStateTests`.
struct SmartRowStatus: Equatable, Sendable {
    enum Action: String, Equatable, Sendable, CaseIterable {
        case cancel, paintInstead, remove, retry, update, keep

        var title: String {
            switch self {
            case .cancel: "Cancel"
            case .paintInstead: "Paint It Instead"
            case .remove: "Remove"
            case .retry: "Try Again"
            case .update: "Update"
            case .keep: "Keep"
            }
        }

        var help: String {
            switch self {
            case .cancel: "Stop finding it. The mask goes, as if it had not been added."
            case .paintInstead: "Keep this mask and paint where it should act."
            case .remove: "Remove this mask."
            case .retry: "Look again."
            case .update: "Make this selection again with the current model. Its adjustments stay; Undo puts the old selection back."
            case .keep: "Keep the selection as it is and stop offering the update for this model."
            }
        }
    }

    var text: String
    /// A spinner beside the words, for a wait.
    var isBusy = false
    /// "Preparing masks", 0 to 1.
    var progress: Double?
    var actions: [Action] = []
    /// The longer reason, for the help tag.
    var detail: String?

    /// A second line of buttons under the row's name.
    var hasActionLine: Bool { actions.contains { $0 != .cancel } }

    /// The row's words for a stage: the wait is named from the first frame ("Finding the sky…"), and only the stages that take
    /// long enough to read get words of their own.
    static func words(for stage: SmartStage, kind: SmartKind, update: Bool) -> String {
        switch stage {
        case .queued, .reading, .finding: return update ? "Updating the \(kind.noun)…" : "Finding \(kind.object)…"
        case .waitingForDevelop: return "Waiting for the develop…"
        case .preparing(let fraction): return "Preparing masks… \(Int((fraction * 100).rounded())) %"
        case .checkingWater: return "Leaving out reflections…"
        }
    }

    static func working(_ stage: SmartStage, kind: SmartKind, update: Bool) -> SmartRowStatus {
        var status = SmartRowStatus(text: words(for: stage, kind: kind, update: update), isBusy: true, actions: [.cancel])
        if case .preparing(let fraction) = stage {
            status.progress = fraction
            status.detail = "Argent prepares its mask models for this Mac on first use and after each macOS update. It takes about twenty seconds."
        }
        return status
    }

    static func empty(_ kind: SmartKind) -> SmartRowStatus {
        SmartRowStatus(text: SmartResult.nothingFoundMessage(kind), actions: [.paintInstead, .remove])
    }

    static func failed(_ kind: SmartKind, why: String) -> SmartRowStatus {
        SmartRowStatus(text: "Could not find \(kind.object)", actions: [.retry, .remove], detail: why)
    }

    /// A selection asked for in a session that ended before it arrived, or stopped: nothing runs for it now.
    static func notMade(_ kind: SmartKind) -> SmartRowStatus {
        SmartRowStatus(text: "Not found yet", actions: [.retry, .remove],
                       detail: "Finding \(kind.object) stopped before it finished. Until it is found the mask changes nothing, and the frame cannot be developed.")
    }

    /// A seed Vision made because a Subject model is absent from this build (`AppleSegmentation.fallback`): the row says so, quietly. Once the models are back the seed is stale and Update is offered.
    static func visionFallback(_ kind: SmartKind) -> SmartRowStatus {
        SmartRowStatus(text: "Found by Vision", detail: "This build of Argent was made without the subject models, so Vision found this selection, with the edge it always had.")
    }

    static func stale(_ kind: SmartKind) -> SmartRowStatus {
        SmartRowStatus(text: "Made with an earlier model", actions: [.update, .keep],
                       detail: "A newer model finds \(kind.object) now. Nothing changes until you choose Update.")
    }

    /// A mask whose brushes hold `MaskSet.maximumBrushPoints`: a press on it paints nothing (the stroke's session refuses), so its
    /// row says so, quietly, as an empty selection's does. Flattening a full brush is not built yet.
    static let brushFull = SmartRowStatus(text: "The brush is full",
                                          detail: "A mask's brushes hold \(MaskSet.maximumBrushPoints.formatted()) points at most, and this mask's are spent, so a stroke on it paints nothing. Paint the rest in a new mask.")

    /// Whether `mask`'s brushes leave no point for another stroke.
    static func brushIsFull(_ mask: Mask) -> Bool { mask.brushPointCount >= MaskSet.maximumBrushPoints }

    static func updateFoundNothing(_ kind: SmartKind) -> SmartRowStatus {
        SmartRowStatus(text: "The new model finds no \(kind.noun)", actions: [.keep],
                       detail: "The current model finds no \(kind.noun) in this frame. The mask keeps its selection.")
    }
}

extension SmartKind {
    /// "the sky", "the subject", "people", "the background": what a row says it finds.
    var object: String {
        switch self {
        case .sky: "the sky"
        case .subject: "the subject"
        case .person: "people"
        case .background: "the background"
        }
    }

    /// "sky", "subject", "people", "background".
    var noun: String {
        switch self {
        case .sky: "sky"
        case .subject: "subject"
        case .person: "people"
        case .background: "background"
        }
    }

    /// The tile that makes it.
    var tile: MaskTile {
        switch self {
        case .sky: .sky
        case .subject: .subject
        case .person: .person
        case .background: .background
        }
    }
}
