import ArgentCore
import ArgentRoll
import CoreGraphics
import Foundation

/// What a removal's plan needs to know of its frame: the full-size upright decode's size, and the corrected picture's geometry, `nil`
/// where the lens stage does not warp (`RemovalPipeline.plan`).
struct RemovalFrame: Sendable, Equatable {
    var width: Int
    var height: Int
    var geometry: LensGeometry?
}

/// The steps of a removal, from a selection to a stored patch, and the queue's rules around them (docs/remove-plan.md, sections 4.4
/// and 4.5). The model (`RollModel+Remove.swift`) decides what is asked, in what order and what becomes of the result; these do
/// the work. The app's are `LiveRemovalSteps`, over the pipeline, the previews, the queue, the patch store and the segmenter; a
/// suite gives its own, so the model's rules are tested with no decode, no model and no file.
///
/// Safe to call from any thread: the model calls the pure steps off the main actor.
protocol RemovalSteps: Sendable {
    /// The frame as `lens` corrects it. Throws when its raw cannot be decoded now.
    func frame(_ frame: Frame, lens: LensSettings) async throws -> RemovalFrame
    func plan(_ selection: RemovalPipeline.Selection, on frame: RemovalFrame) throws -> RemovalPipeline.Plan
    /// The plan of a removal made again: its patch's own object over its own box.
    func plan(retrying patch: RemovalPatch, on frame: RemovalFrame) throws -> RemovalPipeline.Plan
    /// The decode over `box` with `lens`'s removals composited: `lens` holds only the removals made before the one being made.
    func crop(_ frame: Frame, lens: LensSettings, box: RemovalPatch.Box) async throws -> RemovalPipeline.Crop
    func prepare(_ crop: RemovalPipeline.Crop, plan: RemovalPipeline.Plan, steps: Int, guidance: Float, seed: UInt64) throws -> RemovalPipeline.Prepared
    /// Runs the job in the queue. `progress` returns once the row says it, so a caption is never behind its run. Cancelling the task
    /// takes the job out of the queue or stops it between two steps.
    func run(_ job: RemovalJob, progress: @escaping @Sendable (RemovalQueue.Progress) async -> Void) async throws -> RemovalOutput
    func finish(_ output: RemovalOutput, prepared: RemovalPipeline.Prepared, faces: [FaceMeasure]) throws -> RemovalPatch
    /// The patch made with no model, where what is round the selection is smooth, or `nil` where the model must draw it
    /// (`RemovalPipeline.healed`).
    func heal(_ prepared: RemovalPipeline.Prepared, faces: [FaceMeasure]) throws -> RemovalPatch?
    /// Returns once the patch is on the disk and flushed: only then does a record name it.
    func store(_ patch: RemovalPatch) throws -> PatchRef
    func load(_ ref: PatchRef) throws -> RemovalPatch

    /// Whether this Mac can snap a stroke to the object under it.
    func snapAvailability() async -> ObjectSelector.Availability
    /// The object under `prompt` in the frame as `lens` shows it, earlier removals composited.
    func snap(_ prompt: ObjectSelector.Prompt, excluded: [CGPoint], on frame: Frame, lens: LensSettings) async throws -> RemovalPipeline.Selection

    /// The decoder the frame's decodes come from now, as a patch's notes record it; `nil` when it cannot be told.
    func decoder(for frame: Frame) -> String?
    /// The corrected picture's geometry for `lens`, without a decode; `nil` where there is no warp to carry an outline through.
    func geometry(for frame: Frame, lens: LensSettings) -> LensGeometry?

    var engineState: RemovalEngineState { get }
    /// The Remove tab opened on a frame, or a stroke began.
    func noteUse()
    /// Something is selected whose job will have this working size (`RemovalQueue.prepare`): the bundled model compiles for a
    /// size at its first call with it, seven to ten seconds, and does it now, while the selection is still being looked at.
    func prepareSize(width: Int, height: Int)
    /// Returns once the model's memory is back, before a develop's gate reads the footprint.
    func developWillStart() async
    func developDidEnd()
}

extension RemovalSteps {
    func prepareSize(width: Int, height: Int) {}
    func heal(_ prepared: RemovalPipeline.Prepared, faces: [FaceMeasure]) throws -> RemovalPatch? { nil }
}

/// One run of the model for a frame, as the model asks for it.
struct RemovalRequest: Sendable {
    enum Source: Sendable {
        case selection(RemovalPipeline.Selection)
        /// Try Again and Better: the removal's patch as it is now.
        case retrying(PatchRef)
    }

    var frame: Frame
    /// The frame's lens settings as it is shown now: the picture the selection was made on, whose decode the frame view may hold.
    var shown: LensSettings
    /// The frame's lens settings with only the removals made before this one.
    var lens: LensSettings
    var source: Source
    var steps: Int
    var guidance: Float
    var seed: UInt64
    /// The frame's faces as its measurement found them, for the note of a face redrawn.
    var faces: [FaceMeasure]
}

extension RemovalSteps {
    /// A request, through every step to a patch in the store. Off the main actor: the plan, the job and the patch are each a pass
    /// over the crop's pixels.
    func patch(for request: RemovalRequest, progress: @escaping @Sendable (RemovalQueue.Progress) async -> Void) async throws -> RemovalPatch {
        // A removal changes neither the picture's size nor its geometry, so they are asked of the picture as shown, which costs
        // no decode where the frame view holds one.
        let frame = try await self.frame(request.frame, lens: request.shown)
        try Task.checkCancellation()
        var seed = request.seed
        let plan: RemovalPipeline.Plan
        switch request.source {
        case .selection(let selection):
            plan = try self.plan(selection, on: frame)
        case .retrying(let ref):
            let old = try load(ref)
            // Try Again is another roll of the dice: never the seed that drew what is there.
            if old.notes.seed == seed { seed &+= 1 }
            plan = try self.plan(retrying: old, on: frame)
        }
        let crop = try await self.crop(request.frame, lens: request.lens, box: plan.box)
        let prepared = try prepare(crop, plan: plan, steps: request.steps, guidance: request.guidance, seed: seed)
        try Task.checkCancellation()
        // A new removal in smooth surroundings, a speck of dust on a sky, is filled from them with no model. Try Again and
        // Better ask the model, so a fill that is wrong has a way out. It goes round the queue: it waits for no develop
        // and for no other removal, and says nothing of its progress, which is a quarter of a second at the largest size.
        if case .selection = request.source, let healed = try heal(prepared, faces: request.faces) {
            // A removal cancelled meanwhile leaves no file behind.
            try Task.checkCancellation()
            _ = try store(healed)
            return healed
        }
        let output = try await run(prepared.job, progress: progress)
        try Task.checkCancellation()
        let patch = try finish(output, prepared: prepared, faces: request.faces)
        _ = try store(patch)
        return patch
    }
}

/// The app's steps: the base's pieces, each called as its package built it.
final class LiveRemovalSteps: RemovalSteps, @unchecked Sendable {
    private let films: FilmPreviews
    private let patches: PatchStore
    private let makeEngine: @Sendable () -> any RemovalEngine
    private let selector = ObjectSelector()
    private let lock = NSLock()
    private var made: RemovalQueue?

    init(films: FilmPreviews, library: URL, makeEngine: @escaping @Sendable () -> any RemovalEngine = LiveRemovalSteps.engine) {
        self.films = films
        patches = PatchStore(library: library)
        self.makeEngine = makeEngine
    }

    /// The engine removals run on: the helper in the bundle (`Contents/MacOS/argent-remove`, the graphs in
    /// `Contents/Resources/Models`), started on `Remove` in the app's Application Support when the model is wanted and gone when it
    /// is not. A bundle with no helper or no graphs has no engine, and Return says how to get one.
    static let engine: @Sendable () -> any RemovalEngine = {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "argent-remove"),
              let models = Bundle.main.resourceURL?.appendingPathComponent("Models", isDirectory: true),
              FileManager.default.fileExists(atPath: models.appendingPathComponent("objectclear-unet.aimodel/main.hash").path) else {
            return FakeRemovalEngine(state: .absent("This build has no Remove model. Convert it with scripts/convert-objectclear.zsh "
                                                    + "and build the app again with scripts/build-app.sh."))
        }
        let root = ApplicationSupport.folder.appendingPathComponent("Remove", isDirectory: true)
        return FolderEngine(root: root, launcher: { root in
            // The helper inherits the app's sandbox and container. Its own lines, which say its times and its footprint, go to a
            // log beside its folder, begun again at each start.
            let log = root.appendingPathComponent("argent-remove.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let process = Process()
            process.executableURL = helper
            process.arguments = ["--root", root.path, "--models", models.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = (try? FileHandle(forWritingTo: log)) ?? FileHandle.nullDevice
            try process.run()
            return process
        })
    }

    /// The queue, made on first use and never at launch: making it is what looks for the engine.
    private var queue: RemovalQueue {
        lock.withLock {
            if let made { return made }
            let queue = RemovalQueue(engine: makeEngine())
            made = queue
            return queue
        }
    }

    func frame(_ frame: Frame, lens: LensSettings) async throws -> RemovalFrame {
        // The frame view's decode says the picture's size for nothing; without one, the picture smart masks are given does.
        if let held = films.brushPicture(for: frame, lens: lens)?.frame {
            return RemovalFrame(width: held.width, height: held.height, geometry: geometry(for: frame, lens: lens))
        }
        guard let picture = await films.maskInputPicture(frame, lens: lens) else {
            throw RemovalRunFailure.failed("The RAW could not be decoded.")
        }
        return RemovalFrame(width: picture.source.pictureWidth, height: picture.source.pictureHeight, geometry: geometry(for: frame, lens: lens))
    }

    func plan(_ selection: RemovalPipeline.Selection, on frame: RemovalFrame) throws -> RemovalPipeline.Plan {
        try RemovalPipeline.plan(selection, geometry: frame.geometry, frameWidth: frame.width, frameHeight: frame.height)
    }

    func plan(retrying patch: RemovalPatch, on frame: RemovalFrame) throws -> RemovalPipeline.Plan {
        try RemovalPipeline.plan(retrying: patch, frameWidth: frame.width, frameHeight: frame.height)
    }

    func crop(_ frame: Frame, lens: LensSettings, box: RemovalPatch.Box) async throws -> RemovalPipeline.Crop {
        try await films.removalInput(frame, lens: lens, box: box)
    }

    func prepare(_ crop: RemovalPipeline.Crop, plan: RemovalPipeline.Plan, steps: Int, guidance: Float, seed: UInt64) throws -> RemovalPipeline.Prepared {
        try RemovalPipeline.prepare(crop, plan: plan, steps: steps, guidance: guidance, seed: seed)
    }

    func run(_ job: RemovalJob, progress: @escaping @Sendable (RemovalQueue.Progress) async -> Void) async throws -> RemovalOutput {
        // The queue reports from its own threads and does not wait; one reader gives the row its words in the order they were said.
        let (said, saying) = AsyncStream.makeStream(of: RemovalQueue.Progress.self)
        let reader = Task { for await word in said { await progress(word) } }
        defer { saying.finish() }
        do {
            let output = try await queue.run(job) { saying.yield($0) }
            saying.finish()
            await reader.value
            return output
        } catch {
            reader.cancel()
            throw error
        }
    }

    func finish(_ output: RemovalOutput, prepared: RemovalPipeline.Prepared, faces: [FaceMeasure]) throws -> RemovalPatch {
        try RemovalPipeline.finish(output, prepared: prepared, faces: faces)
    }

    func heal(_ prepared: RemovalPipeline.Prepared, faces: [FaceMeasure]) throws -> RemovalPatch? {
        try RemovalPipeline.healed(prepared, faces: faces)
    }

    func store(_ patch: RemovalPatch) throws -> PatchRef { try patches.store(patch) }

    func load(_ ref: PatchRef) throws -> RemovalPatch { try patches.load(ref) }

    func snapAvailability() async -> ObjectSelector.Availability { await selector.availability() }

    func snap(_ prompt: ObjectSelector.Prompt, excluded: [CGPoint], on frame: Frame, lens: LensSettings) async throws -> RemovalPipeline.Selection {
        guard let picture = await films.maskInputPicture(frame, lens: lens) else {
            throw RemovalRunFailure.failed("The RAW could not be decoded.")
        }
        return try await selector.select(prompt, excluded: excluded.map { (x: Float($0.x), y: Float($0.y)) }, in: picture.image)
    }

    func decoder(for frame: Frame) -> String? { films.decoderChoices.choice(for: frame.url).decoderVersion }

    func geometry(for frame: Frame, lens: LensSettings) -> LensGeometry? {
        films.lensCorrection(for: frame, settings: lens)?.geometry
    }

    var engineState: RemovalEngineState { queue.state }

    func noteUse() { queue.noteUse() }

    func prepareSize(width: Int, height: Int) { queue.prepare(width: width, height: height) }

    // A develop never makes the queue: a session that removed nothing has no model to send away.
    func developWillStart() async { await lock.withLock { made }?.developWillStart() }

    func developDidEnd() { lock.withLock { made }?.developDidEnd() }
}
