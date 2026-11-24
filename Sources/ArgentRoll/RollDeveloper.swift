import ArgentCore
import CoreGraphics
import Foundation
import os

/// Develops a roll to files: each frame's raw at full size through the stock and settings its
/// recipe names, resized and encoded, with the recipe written back beside the raw.
///
/// Each frame is decoded by the decoder `DecoderChoices` gives it, RAW 9 for the a7 IV's Bayer modes
/// and RAW 8 for the rest (docs/decoder.md, section 18; the in-house decoder on M8's route), and a
/// frame developed by another decoder is developed again.
///
/// Memory decides the shape (docs/M2-shell.md sections 5 and 10). Apple's decoder keeps working
/// surfaces in its Core Image context, so each decode gets a context of its own and renders in
/// tiles: RAW 8 in 768-pixel tiles, 212 MB of surfaces beside its frame, RAW 9 in 1024-pixel tiles,
/// 630 MB beside it. Two frames decode at once, one of them at
/// most in-house; the film passes and the picture run one frame at a time, the print written over
/// the decode's own texture, and hand the frame back before the encode, which overlaps the next
/// decodes; two finished pictures wait at most at 8 bits, one at 16. A frame starts only when its
/// format's plan has room for another in flight and the app's footprint has room for its decode under
/// the target, 2 GB or an eighth of the memory, less what the app holds beyond the idle sheet's floor
/// (`DevelopBudget`, `MemoryGate`), and while none of the previews' decodes waits or runs
/// (`DecodeTurns`); a frame with masks is weighed with their coverage, which goes with its render (`DevelopBudget.maskCost`).
/// That kept the running app with its
/// sheet under 1.9 GB for every format, at 3.1 frames a second for a mixed roll to JPEG and 10.2 for
/// lossless L frames (measured on the M4). A develop stops at frame boundaries: frames already
/// decoding finish, the rest are left for the next develop, which skips every frame whose file is
/// there from the same recipe and the same raw, byte for byte (`checkingSource`).
public final class RollDeveloper: @unchecked Sendable {
    private static let log = Logger(subsystem: "camera.argent.Argent", category: "develop")
    public static let lanes = 2
    /// How many frames decode and render at once, `lanes` unless a measurement says otherwise.
    public let laneCount: Int
    /// Finished pictures waiting for their encode, at 8 and at 16 bits a channel.
    public let picturesInFlight: (eight: Int, sixteen: Int)
    /// The decode's tile size; see `DecodeOptions.tileSize`. 768 pixels: Apple's decode holds 212 MB of
    /// surfaces beside its frame, against 387 at 1024, for 19 to 21 percent more time (measured,
    /// docs/M2-shell.md section 10), so two decodes at once fit beside the sheet under 2 GB.
    public static let decodeTile: Int? = 768
    /// RAW 9's default-target tile size: 1024 pixels, used when a develop's memory target is under
    /// 3000 MiB; develops at 3000 MiB and above use 2048 (`DevelopBudget.learnedDecodeTile(forMemoryTarget:)`).
    /// Over 60 lossless L frames at the 2000 MiB default on the M5 Pro (2026-11-22), 2048-pixel tiles
    /// lost 5 to 10 percent on HEIC and 16-bit TIFF against 1024, while at 3000 and 4000 MiB 2048 raised
    /// throughput across all three formats. A frame RAW 9 fails on decodes with RAW 8 in RAW 8's tiles
    /// (`DecodeOptions.learnedTileSize`), weighed still as RAW 9's.
    public static let learnedDecodeTile: Int? = 1024
    /// In-house decodes at once among the lanes, so the second lane decodes an Apple frame or waits.
    /// Two at once share the GPU and gained nothing (11.6 to 11.8 frames a second on a roll of
    /// lossless L frames against 12.0 to 12.3 one at a time), and one at a time peaked 0.05 to 0.1 GB
    /// lower (measured, docs/decoder.md, section 14).
    public static let inHouseDecodesAtOnce: Int? = 1
    public let decodeTile: Int?
    /// Explicit RAW 9 tile override given at init (`.some(nil)` for decodes rendered whole), or `nil`
    /// to follow each develop's memory target (`DevelopBudget.learnedDecodeTile(forMemoryTarget:)`).
    private let explicitLearnedDecodeTile: Int??
    /// RAW 9's tile size for this developer's default `memoryTarget`, or the explicit override given at init.
    public var learnedDecodeTile: Int? { learnedDecodeTile(forMemoryTarget: memoryTarget) }

    /// One frame to develop, with the recipe it is developed from.
    public struct Job: Sendable {
        public var frame: Frame
        public var recipe: Recipe
        /// The version of the raw the recipe's measurement was made from, when the caller measured
        /// it; a raw no longer at that version fails rather than print from another raw's measurement.
        public var measuredFrom: SourceStamp?
        /// The version of the raw its frame header was read from, when the caller captured it.
        /// Checked even without a measurement, so another raw cannot inherit its grain seed or header.
        public var frameSource: SourceStamp?
        /// The revision of the roll's settled Auto decision the recipe's aim is from, recorded in the
        /// receipt and compared by the next develop (`Recipe.lastDevelopMatches`).
        public var autoRevision: String?

        public init(frame: Frame, recipe: Recipe, measuredFrom: SourceStamp? = nil, frameSource: SourceStamp? = nil,
                    autoRevision: String? = nil) {
            self.frame = frame
            self.recipe = recipe
            self.measuredFrom = measuredFrom
            self.frameSource = frameSource
            self.autoRevision = autoRevision
        }
    }

    /// Raws read whole at once to check them before a develop: their reads, not their hashing,
    /// are the cost, and a card reads no faster for more.
    public static let checkLanes = 3
    /// The raws' SHA-256, shared with the recipes and the sheet's disk cache.
    public let digests: SourceDigests
    /// Called as each frame's raw begins its check, for tests.
    var observeCheck: (@Sendable (Int) -> Void)?

    public enum Outcome: Sendable, Equatable {
        /// Written, with its recipe.
        case developed(URL)
        /// Its file was already there from the same recipe and settings.
        case alreadyDeveloped(URL)
        case failed(String)
        /// Not started before the develop was stopped.
        case stopped

        public var file: URL? {
            switch self {
            case .developed(let url), .alreadyDeveloped(let url): return url
            case .failed, .stopped: return nil
            }
        }
    }

    /// The app and version recorded in each file and recipe, for example "Argent 0.1.0".
    public let software: String
    public let library: URL
    public let recipeWriter: RecipeWriter
    private let gpu: GPU
    private let decoder: ChosenDecoder
    /// Which decoder each file goes to, shared with the sheet's previews.
    public let decoderChoices: DecoderChoices
    private let encoder: ImageEncoder
    private let lensStage: LensStage
    /// Where the lens stage reads a frame's removals' patches: the library's store behind its cache (`PatchStore.source`), kept
    /// here by its own type so `trim` can empty it. It holds nothing until a frame with a removal develops.
    private let patches: PatchStore.Cache
    private let stocks: [String: (stock: Stock, digest: String)]
    /// Each stock's film passes, made the first time a develop uses the stock: each holds its two
    /// LUTs on the GPU, 12 MB, so a develop of one stock does not carry the five others'.
    private var renderers: [String: FilmRenderer] = [:]
    private let renderersLock = NSLock()
    /// The default footprint a develop keeps the app under when `develop(...)` is not given one; see `DevelopBudget`.
    public let memoryTarget: Int
    /// The turns its frames take with the previews' decodes, the previews' own (`DecodeTurns`).
    private let decodeTurns: DecodeTurns
    private let laneQueue = OperationQueue()
    private let encodeQueue = OperationQueue()
    /// A frame's stages as they begin and end, by its index in the develop, for measuring memory.
    public enum Stage: String, Sendable { case admit, decode, waitPicture, render, encode }
    public var observeStage: (@Sendable (Int, Stage, Bool) -> Void)?
    private let reportLock = NSLock()
    /// Under `reportLock`: the last develop's frames let in, its floor, its budget, its RAW 9 tile,
    /// its gate's ceiling and the last frame's weighed decode cost.
    private var _lastAdmissions: (admitted: Int, waited: Int, alone: Int)?
    private var _lastFloor: (floor: Int?, readAfter: TimeInterval?, quiet: Bool, largestExcess: Int)?
    private var _lastMemoryTarget: Int?
    private var _lastLearnedDecodeTile: Int??
    private var _lastGateCeiling: Int?
    private var _lastWeighedDecodeCost: Int?
    /// The last develop's frames let in, and how many waited first, for measuring.
    var lastAdmissions: (admitted: Int, waited: Int, alone: Int)? { reportLock.withLock { _lastAdmissions } }
    /// The last develop's floor, when it was read and the largest excess, for measuring.
    var lastFloor: (floor: Int?, readAfter: TimeInterval?, quiet: Bool, largestExcess: Int)? { reportLock.withLock { _lastFloor } }
    /// The memory target the last develop ran with, in bytes; `nil` before any develop starts.
    public var lastMemoryTarget: Int? { reportLock.withLock { _lastMemoryTarget } }
    /// RAW 9's decode tile size the last develop ran with (`nil` for whole decodes or before any develop starts).
    public var lastLearnedDecodeTile: Int? { reportLock.withLock { _lastLearnedDecodeTile ?? nil } }
    /// The ceiling the last develop's memory gate enforced, in bytes, for tests.
    var lastGateCeiling: Int? { reportLock.withLock { _lastGateCeiling } }
    /// The decode cost the last develop weighed a frame at before admitting it to the gate, in bytes, for tests.
    var lastWeighedDecodeCost: Int? { reportLock.withLock { _lastWeighedDecodeCost } }
    /// The film passes and the picture, one frame at a time.
    private let renderLock = NSLock()

    public init(stocks: [Stock], software: String, library: URL = RecipeStore.defaultLibrary, digests: SourceDigests = .shared,
                lanes: Int = RollDeveloper.lanes, picturesInFlight: (eight: Int, sixteen: Int) = (2, 1),
                maxIdlePoolBytes: Int = 0, decodeTile: Int? = RollDeveloper.decodeTile,
                learnedDecodeTile: Int?? = nil,
                decoderChoices: DecoderChoices = DecoderChoices(),
                inHouseDecodesAtOnce: Int? = RollDeveloper.inHouseDecodesAtOnce,
                memoryTarget: Int = DevelopBudget.target(), recipeWriter: RecipeWriter = .shared,
                decodeTurns: DecodeTurns = DecodeTurns()) throws {
        self.software = software
        self.memoryTarget = memoryTarget
        self.decodeTurns = decodeTurns
        self.library = library
        self.recipeWriter = recipeWriter
        self.digests = digests
        laneCount = lanes
        self.picturesInFlight = picturesInFlight
        self.decodeTile = decodeTile
        self.explicitLearnedDecodeTile = learnedDecodeTile
        self.decoderChoices = decoderChoices
        // Its own GPU context, apart from the sheet's. Its pool keeps no texture between frames by
        // default: a frame-sized texture kept idle peaked 0.06 to 0.1 GB higher than one let go and made
        // again, for 6 percent of the speed of a roll of lossless L frames (docs/M2-shell.md section 10).
        let gpu = try GPU(maxIdlePoolBytes: maxIdlePoolBytes)
        // And it keeps no masks' coverage between frames: a frame's array, 21 to 85 MB on a 3:2 frame, goes with its render, so it is
        // never held beside the next frame's decode, where a develop peaks. Another frame's masks rarely share a field, and a bake
        // takes a millisecond or two (`DevelopBudget.maskCost`).
        gpu.maskFields.maximumBytes = 0
        // Nor smart masks' refinements: a frame's coefficients, 2 to 6 MB a seed, are built on its own decode and are another frame's
        // never (`DevelopBudget.maskCost` counts them while they live).
        gpu.maskRefiner.maximumBytes = 0
        // Nor Presence's analyses: a frame's is made from its own decode and is another frame's never
        // (`DevelopBudget.presenceCost` counts it while it lives).
        gpu.presenceAnalyses.maximumBytes = 0
        self.gpu = gpu
        decoder = ChosenDecoder(gpu: gpu, choices: decoderChoices, contextPerDecode: true, inHouseAtOnce: inHouseDecodesAtOnce)
        encoder = try ImageEncoder(gpu: gpu)
        // Compiled here, on one thread: the shader library compiles lazily and is not thread-safe.
        _ = try gpu.shaderLibrary()
        // The patches come from the library the seeds are in, so a test's develop reads its own.
        patches = PatchStore.Cache(PatchStore(library: library))
        lensStage = try LensStage(gpu: gpu, patches: patches)
        self.stocks = Dictionary(stocks.map { ($0.id, ($0, $0.digest)) }, uniquingKeysWith: { first, _ in first })
        laneQueue.maxConcurrentOperationCount = lanes
        laneQueue.qualityOfService = .userInitiated
        laneQueue.name = "Argent develop: decode and render"
        encodeQueue.maxConcurrentOperationCount = ProcessInfo.processInfo.activeProcessorCount
        encodeQueue.qualityOfService = .userInitiated
        encodeQueue.name = "Argent develop: encode"
    }

    /// The digest a recipe records for the stock with `id`, if it is installed.
    public func digest(ofStock id: String) -> String? { stocks[id]?.digest }

    /// The film passes for the stock with `id`, made on first use; `nil` when it is not installed.
    private func renderer(_ id: String) throws -> FilmRenderer? {
        try renderersLock.withLock {
            if let made = renderers[id] { return made }
            guard let stock = stocks[id]?.stock else { return nil }
            let made = try FilmRenderer(gpu: gpu, stock: stock)
            renderers[id] = made
            return made
        }
    }

    /// The pixels of the raw at `url` as its header gives them, or a full-frame a7 IV's when it
    /// cannot be read, the largest the app opens.
    static func pixelSize(of url: URL) -> (width: Int, height: Int) {
        guard let layout = try? ARWLayout.read(from: url), layout.cropSize.width > 0, layout.cropSize.height > 0
        else { return (7008, 4672) }
        return (layout.cropSize.width, layout.cropSize.height)
    }

    /// The last develop's memory gate: the floor it read, when and whether the previews were quiet,
    /// the largest excess it weighed a frame against, and the frames it let in and how many waited,
    /// for the drive hook's memory measurements.
    public var lastGateReport: String? {
        let (floor, admissions) = reportLock.withLock { (_lastFloor, _lastAdmissions) }
        guard let floor, let admissions else { return nil }
        let read = floor.readAfter.map { String(format: "%.3f s", $0) } ?? "never"
        return "gate floor \(floor.floor.map { "\($0 >> 20) MB" } ?? "none") read after \(read)"
            + (floor.quiet ? " quiet" : " not quiet") + ", largest excess \(floor.largestExcess >> 20) MB,"
            + " admitted \(admissions.admitted), waited \(admissions.waited), alone \(admissions.alone)"
    }

    /// What the developer holds between develops, for the drive hook's memory measurements.
    public var heldReport: String {
        "developer pool idle \(gpu.texturePool.idleByteCount >> 20) MB, in-house kept \(decoder.inHouseKeptBytes >> 20) MB,"
            + " film passes \(renderersLock.withLock { renderers.count }), mask fields \(gpu.maskFields.residentBytes >> 20) MB"
            + " (\(gpu.maskFields.statistics.allocations) made), patches \(patches.residentBytes >> 20) MB"
    }

    /// Frees the full-size textures, the decoders' buffers and the removals' patches kept for reuse, once a develop is over.
    public func trim() {
        gpu.texturePool.trim()
        decoder.trim()
        patches.trim()
    }

    /// The file each job develops to in `destination`: its newest recorded name there in this
    /// format, or its raw's name with the format's extension. Recorded names are reserved first,
    /// even where their file is missing, so another frame cannot take them. A stamped output
    /// replaced since its receipt is unrelated too. A new name already taken by another frame
    /// or an unrelated file gets a number, "DSC00601 2.jpg".
    public static func files(for jobs: [Job], in destination: URL, output: OutputSettings) -> [URL] {
        let ext = output.encoding.fileExtension
        var taken = Set<String>()
        let folder = destination.canonicalPath
        let recorded: [URL?] = jobs.map { job in
            for develop in latestOutputs(of: job) where develop.output.format == output.format {
                let file = URL(fileURLWithPath: develop.file)
                guard file.deletingLastPathComponent().canonicalPath == folder,
                      file.pathExtension.lowercased() == ext, isNamed(file, after: job.frame),
                      canReuseOutput(develop),
                      taken.insert(file.lastPathComponent.lowercased()).inserted else { continue }
                return destination.appendingPathComponent(file.lastPathComponent)
            }
            return nil
        }
        return zip(jobs, recorded).map { job, recorded in
            if let recorded { return recorded }
            let own = Set(latestOutputs(of: job).filter(canReuseOutput).map(\.file.canonicalPath))
            var number = 1
            while true {
                let name = number == 1 ? job.frame.name : "\(job.frame.name) \(number)"
                let url = destination.appendingPathComponent(name).appendingPathExtension(ext)
                let free = !FileManager.default.fileExists(atPath: url.path) || own.contains(url.canonicalPath)
                if free, taken.insert(url.lastPathComponent.lowercased()).inserted { return url }
                number += 1
            }
        }
    }

    /// Whether `file` has a name a develop of `frame` gives: the frame's, numbered or not, but not a
    /// raw's beside it, as a twin "DSC1 2" is. A receipt of another name is another raw's, as one a
    /// build before 2026-10-22 merged into a twin's record is.
    private static func isNamed(_ file: URL, after frame: Frame) -> Bool {
        let stem = file.deletingPathExtension().lastPathComponent
        if stem == frame.name { return true }
        guard stem.hasPrefix(frame.name + " "), let number = Int(stem.dropFirst(frame.name.count + 1)), number > 1 else { return false }
        let raw = frame.url.deletingLastPathComponent().appendingPathComponent(stem).appendingPathExtension(frame.url.pathExtension)
        return !FileManager.default.fileExists(atPath: raw.path)
    }

    private static func latestOutputs(of job: Job) -> [Recipe.Develop] {
        var seen = Set<String>()
        return job.recipe.develops.reversed().filter { $0.belongs(to: job.frame) && seen.insert($0.file.canonicalPath).inserted }
    }

    private static func canReuseOutput(_ develop: Recipe.Develop) -> Bool {
        let file = URL(fileURLWithPath: develop.file)
        guard FileManager.default.fileExists(atPath: file.path), let recorded = develop.outputSource else { return true }
        return SourceStamp.of(file).map(recorded.isSameVersion(atSamePathAs:)) == true
    }

    /// The output `job` develops with: `output` with the frame's own grain and halation (`FrameControls.grain`, `.halation`),
    /// which its render has, in place of the roll's, and halation at the stock's own (`OutputSettings.defaultHalation`) where
    /// the frame's stock has none (`render.halation != "on"`). Its receipt records that, and the next develop compares it, so a
    /// change to the roll's grain or halation does not make again a frame whose own it does not reach, nor one on a stock
    /// without halation.
    static func output(_ output: OutputSettings, for job: Job) -> OutputSettings {
        var own = output
        if let grain = job.recipe.frame.grain { own.grain = grain }
        if job.recipe.render.halation == "on" {
            if let halation = job.recipe.frame.halation { own.halation = halation }
        } else {
            own.halation = OutputSettings.defaultHalation
        }
        return own
    }

    /// RAW 9's decode tile size for a develop running with `target` bytes: the explicit override given
    /// at init when one was passed, otherwise `DevelopBudget.learnedDecodeTile(forMemoryTarget:)`.
    func learnedDecodeTile(forMemoryTarget target: Int) -> Int? {
        if let explicitLearnedDecodeTile { return explicitLearnedDecodeTile }
        return DevelopBudget.learnedDecodeTile(forMemoryTarget: target)
    }

    /// Develops `jobs` into `destination` in order and returns what came of each, calling
    /// `progress` as each frame finishes. `memoryTarget`, when given, sets the budget for this
    /// develop in place of the developer's default. Cancelling the task stops the develop at frame
    /// boundaries.
    public func develop(_ jobs: [Job], to destination: URL, output: OutputSettings,
                        memoryTarget: Int? = nil,
                        progress: @escaping @Sendable (Int, Outcome) -> Void = { _, _ in }) async -> [Outcome] {
        let target = memoryTarget ?? self.memoryTarget
        let learnedTile = learnedDecodeTile(forMemoryTarget: target)
        reportLock.withLock {
            _lastMemoryTarget = target
            _lastLearnedDecodeTile = .some(learnedTile)
            _lastGateCeiling = nil
            _lastWeighedDecodeCost = nil
            _lastAdmissions = nil
            _lastFloor = nil
        }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return jobs.map { _ in .failed("Could not create \(destination.path): \(error.localizedDescription)") }
        }
        // A folder the sandbox does not let the app write fails every frame at its encode;
        // say so before decoding any of them.
        guard FileManager.default.isWritableFile(atPath: destination.path) else {
            return jobs.map { _ in .failed("Cannot write to \(destination.path)") }
        }
        // A develop record is the raw's only while the raw is the file it was made from: checked
        // before the names, so the develop of a raw since replaced is neither skipped nor written over.
        var checks = await checkingSources(jobs)
        if Task.isCancelled {
            return checks.map { if case .failed(let reason) = $0 { .failed(reason) } else { .stopped } }
        }
        // A future or conflicting saved recipe is a read error, never an absent record that
        // an export may silently overwrite. Jobs keep their immutable captured settings.
        for index in checks.indices {
            if Task.isCancelled { break }
            guard case .ready(var job, let source) = checks[index] else { continue }
            do {
                let latest = try await recipeWriter.load(for: job.frame, library: library)
                // A job captured before an earlier develop's receipts were saved, as a second develop
                // in one session is, still owns the outputs they record: their history joins the job's,
                // never their settings, so a replaced output of its own is not taken for another file's.
                if let latest, latest.raw.sha256 == job.recipe.raw.sha256 {
                    job.recipe.develops = RecipeWriter.mergedDevelops(job.recipe.develops, latest.develops)
                    checks[index] = .ready(job, source)
                }
                if job.recipe.editRevision == nil {
                    // The pre-v2 API captures choices without a revision. Acknowledge that
                    // intent before rendering; otherwise a receipt could preserve an earlier
                    // automatic render under the same revision. It cannot reset protected edits.
                    if latest?.manual != nil || latest?.heldManual != nil {
                        throw RecipeWriter.Failure.conflict("an unrevisioned develop cannot replace saved manual adjustments")
                    }
                    if let latest, latest.raw.sha256 == job.recipe.raw.sha256,
                       latest.render == job.recipe.render, latest.stock.id == job.recipe.stock.id,
                       latest.stock.digest == job.recipe.stock.digest, latest.roll == job.recipe.roll,
                       latest.frame == job.recipe.frame {
                        // An unchanged legacy resume must not rewrite its sidecar merely to
                        // introduce a revision, especially when stopping during source checks.
                        job.recipe.editRevision = latest.editRevision
                        job.recipe.editLineage = latest.editLineage
                    } else {
                        job.recipe = try await recipeWriter.commit(recipe: job.recipe, for: job.frame, library: library)
                    }
                    checks[index] = .ready(job, source)
                }
            } catch { checks[index] = .failed("\(jobs[index].frame.name): \(error.localizedDescription)") }
        }
        // Stopped before decode: no output has been written. Any acknowledged legacy
        // recipe migration remains saved for the next develop.
        if Task.isCancelled {
            return checks.map { if case .failed(let reason) = $0 { .failed(reason) } else { .stopped } }
        }
        let jobs = zip(jobs, checks).map { job, check in check.job ?? job }
        let files = Self.files(for: jobs, in: destination, output: output)
        let outputSources = files.map { SourceStamp.of($0) }
        let results = Results(count: jobs.count)
        let group = DispatchGroup()
        // Finished pictures waiting for their encode: 131 MB each at 8 bits, 262 MB at 16.
        let slots = output.format == .tiff16 ? picturesInFlight.sixteen : picturesInFlight.eight
        let pictures = DispatchSemaphore(value: slots)
        // Frames in flight as the format's plan allows and the app's footprint has room for.
        let plan = DevelopBudget.plan(for: output.format, lanes: laneCount, pictures: slots,
                                      allInHouse: jobs.allSatisfy { decoderChoices.choice(for: $0.frame.url) == .inHouse })
        decoder.keepsInHouseBuffers = plan.keepsInHouseBuffers
        let gate = MemoryGate(ceiling: target - DevelopBudget.margin, maxInFlight: plan.framesInFlight, turns: decodeTurns)
        reportLock.withLock { _lastGateCeiling = gate.ceiling }
        let operations: [Operation] = jobs.indices.compactMap { index in
            guard case .ready(_, let source) = checks[index] else {
                let outcome = checks[index].outcome ?? .stopped
                results.set(index, outcome)
                if outcome != .stopped { progress(index, outcome) }
                return nil
            }
            group.enter()
            let started = Flag()
            let operation = BlockOperation()
            operation.addExecutionBlock { [self, weak operation] in
                started.set()
                let finish: @Sendable (Outcome) -> Void = { outcome in
                    results.set(index, outcome)
                    // A frame stopped before it began is not one done.
                    if outcome != .stopped { progress(index, outcome) }
                    group.leave()
                }
                developOne(jobs[index], index: index, to: files[index], output: Self.output(output, for: jobs[index]), source: source,
                           outputSource: outputSources[index], learnedTile: learnedTile,
                           pictures: pictures, gate: gate, stopped: { operation?.isCancelled ?? true }, finish: finish)
            }
            operation.completionBlock = {
                if !started.value {
                    results.set(index, .stopped)
                    group.leave()
                }
            }
            return operation
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                laneQueue.addOperations(operations, waitUntilFinished: false)
                group.notify(queue: .global()) { continuation.resume() }
            }
        } onCancel: {
            for operation in operations { operation.cancel() }
        }
        reportLock.withLock {
            _lastAdmissions = (gate.counts.admitted, gate.counts.waited, gate.loneCount)
            _lastFloor = gate.floorReport
        }
        return results.all
    }

    /// What a frame's check before the develop found.
    enum SourceCheck: Sendable {
        /// The job, with its develops kept only if its raw is the one they were made from and the
        /// raw's SHA-256 recorded, and the raw's version it was read at.
        case ready(Job, SourceStamp)
        case failed(String)
        case stopped

        var job: Job? {
            if case .ready(let job, _) = self { return job }
            return nil
        }

        var outcome: Outcome? {
            switch self {
            case .ready: return nil
            case .failed(let reason): return .failed(reason)
            case .stopped: return .stopped
            }
        }
    }

    /// Each job's `checkingSource`, `checkLanes` raws at once. Cancelling the task stops it between
    /// megabytes of the raws being read and leaves the frames not yet checked stopped.
    func checkingSources(_ jobs: [Job]) async -> [SourceCheck] {
        let checks = Slots<SourceCheck>(jobs.map { _ in .stopped })
        let stop = Flag()
        let next = Ticket()
        let digests = digests, observe = observeCheck
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    DispatchQueue.concurrentPerform(iterations: max(1, min(Self.checkLanes, jobs.count))) { _ in
                        while !stop.value, let index = next.take(below: jobs.count) {
                            observe?(index)
                            checks.set(index, Self.checkingSource(jobs[index], digests: digests, stopped: { stop.value }))
                        }
                    }
                    continuation.resume()
                }
            }
        } onCancel: {
            stop.set()
        }
        return checks.all
    }

    /// `job` checked against its raw, read whole unless `digests` knows the raw's version: its
    /// develops, and the SHA-256 they were made with, are kept only while the raw is the file they
    /// were made from, and the raw's SHA-256 is recorded for the develop to write. A recipe whose
    /// measurement was made from another raw fails: the one it records, when the raw is no longer
    /// it, or the version `measuredFrom` names. So does a raw that cannot be read whole.
    static func checkingSource(_ job: Job, digests: SourceDigests = .shared, stopped: () -> Bool = { false }) -> SourceCheck {
        var job = job
        let now: SourceDigests.Verified
        do {
            now = try digests.digest(of: job.frame.url, stopped: stopped)
        } catch SourceDigests.Failure.stopped {
            return .stopped
        } catch {
            return .failed("\(job.frame.name): \(error)")
        }
        if let frameSource = job.frameSource, frameSource != now.source {
            return .failed("\(job.frame.name): the raw changed after its header was read; develop again to read it again")
        }
        do { try job.recipe.validate() }
        catch { return .failed("\(job.frame.name): \(error.localizedDescription)") }
        if let manual = job.recipe.manual, manual.baseline.sourceSHA256 != now.sha256 {
            return .failed("\(job.frame.name): the raw changed after its adjustments were made; reapply adjustments first")
        }
        let recorded = job.recipe.raw
        let isOther = recorded.sha256.map { $0 != now.sha256 || recorded.byteCount != Int(now.source.size) } ?? false
        if job.recipe.isMeasured {
            // Measured from this version by the caller, or recorded with the raw it was measured from.
            let vouched = job.measuredFrom.map { $0 == now.source } ?? !isOther
            guard vouched else {
                return .failed("\(job.frame.name): the raw changed after it was measured; develop again to measure it again")
            }
        }
        // Develops no SHA-256 vouches for are not this raw's.
        if isOther || recorded.sha256 == nil { job.recipe = job.recipe.forgettingDevelops() }
        job.recipe.raw.sha256 = now.sha256
        job.recipe.raw.byteCount = Int(now.source.size)
        return .ready(job, now.source)
    }

    /// Develops one frame, let in by `gate` when it has room for the frame's decode; a frame still
    /// waiting to be let in when `stopped` says so is stopped. `source` is the raw's version its
    /// check read; a raw changed by the end of its decode fails.
    private func developOne(_ job: Job, index: Int, to file: URL, output: OutputSettings, source: SourceStamp, outputSource: SourceStamp?,
                            learnedTile: Int?,
                            pictures: DispatchSemaphore, gate: MemoryGate, stopped: () -> Bool,
                            finish: @escaping @Sendable (Outcome) -> Void) {
        let observe = observeStage
        let recipe = job.recipe
        guard !stopped() else {
            finish(.stopped)
            return
        }
        guard SourceStamp.of(job.frame.url) == source else {
            finish(.failed("\(job.frame.name): the raw changed after it was checked; develop again to read it again"))
            return
        }
        guard let stockDigest = stocks[recipe.stock.id]?.digest else {
            finish(.failed("\(job.frame.name): the stock \(recipe.stock.displayName) is not installed"))
            return
        }
        guard recipe.stock.digest == stockDigest else {
            let recovery = recipe.manual != nil ? "update the automatic baseline first" : "develop again to use its current version"
            finish(.failed("\(job.frame.name): the stock changed; \(recovery)"))
            return
        }
        // Skipped only if the decoder the frame goes to now made it, or failed on it last time.
        let lens = LensResolver.correction(for: job.frame.url, settings: recipe.render.settings.lens)
        Self.log.info("\(job.frame.name, privacy: .public): lens \(lens.status.distortion.description, privacy: .public)")
        let meant = decoderChoices.decoderVersion(for: job.frame.url)
        if recipe.lastDevelopMatches(file: file, output: output, decoderVersion: meant, autoRevision: job.autoRevision, lens: lens),
           FileManager.default.fileExists(atPath: file.path) {
            finish(.alreadyDeveloped(file))
            return
        }
        // Every seed the frame's masks read is in the library before its decode, so a lost one fails the frame in milliseconds, not
        // after a decode; a selection never made fails it too, rather than print the mask as covering nothing. A develop never runs a
        // model (masking-plan section 7; R6 section 8).
        let seedStore = MaskRasterStore(library: library)
        let seedsNeeded = MaskSeeds.needs(recipe.render.settings.manual)
        if let failure = Self.seedFailure(seedsNeeded, store: seedStore) {
            finish(.failed("\(job.frame.name): \(failure)"))
            return
        }
        // And every patch a removal that is on puts in the picture, read whole and checked against its name here, for the same
        // reason: a lost or damaged one fails the frame before its decode, rather than print the object back (docs/remove-plan.md,
        // section 4.7).
        let removals = recipe.render.settings.lens.removals
        if let failure = Self.patchFailure(removals, store: patches.store) {
            finish(.failed("\(job.frame.name): \(failure)"))
            return
        }
        let renderer: FilmRenderer
        do {
            guard let made = try self.renderer(recipe.stock.id) else {
                finish(.failed("\(job.frame.name): the stock \(recipe.stock.displayName) is not installed"))
                return
            }
            renderer = made
        } catch {
            finish(.failed("\(job.frame.name): \(error)"))
            return
        }
        // Let in once the plan allows another frame and the footprint has room for its decode.
        let size = Self.pixelSize(of: job.frame.url)
        let choice = decoderChoices.choice(for: job.frame.url)
        let tile = choice == .raw9 ? learnedTile : decodeTile
        let decodeCost = DevelopBudget.decodeCost(width: size.width, height: size.height, decoder: choice,
                                                  tile: tile, inHouseKept: decoder.inHouseKeptBytes)
        reportLock.withLock { _lastWeighedDecodeCost = decodeCost }
        // HEIC's two frames in flight peak as one's film passes meet the other's decode. JPEG's
        // develops stay far under the target, and counting 16-bit TIFF's film passes halved its speed
        // (docs/manual-development-validation.md, "fix⁗").
        let filmPasses = output.format == .heic
            ? DevelopBudget.filmPassesCost(width: size.width, height: size.height, format: output.format) : 0
        // A frame's masks in every format: the margin was set on frames without them.
        let masks = DevelopBudget.maskCost(settings: recipe.render.settings, width: size.width, height: size.height)
        // Presence's analysis is made and let go inside the film passes, as the masks' coverage is, so it is weighed with them.
        let presence = DevelopBudget.presenceCost(settings: recipe.render.settings, width: size.width, height: size.height)
        // Its removals' patches, which the stage's source holds unpacked from the frame's decode to its render: no more than that
        // source keeps, and nothing for a frame with none.
        let patchesNeeded = removals.filter(\.isOn).patches
        let patchBytes = min(patchesNeeded.reduce(0) { $0 + PatchStore.byteCount(of: $1) }, patches.maximumBytes)
        observe?(index, .admit, true)
        let admitted = gate.admit(decode: decodeCost, filmPasses: filmPasses, masks: masks + presence + patchBytes, frame: index,
                                  showsOver: choice == .raw9 ? DevelopBudget.learnedShowsOver : nil, stopped: stopped)
        observe?(index, .admit, false)
        guard admitted else {
            finish(.stopped)
            return
        }
        guard !stopped() else {
            gate.leave(frame: index)
            finish(.stopped)
            return
        }
        guard SourceStamp.of(job.frame.url) == source else {
            gate.leave(frame: index)
            finish(.failed("\(job.frame.name): the raw changed after it was checked; develop again to read it again"))
            return
        }
        // A recipe developed before keeps its decode settings, so it develops the same again; its noise
        // reduction on the scale of the decoder that recorded it, RAW 9's own or RAW 8's, which the
        // in-house decoder shares, so it reaches only a decode on the same scale.
        var options = DecodeOptions()
        options.tileSize = decodeTile
        options.learnedTileSize = learnedTile
        if let pins = recipe.develops.last?.decode {
            if pins.decoderVersion == AppleRawDecoder.learnedDecoderVersion {
                options.learnedLuminanceNoiseReduction = pins.luminanceNoiseReduction
            } else {
                options.luminanceNoiseReduction = pins.luminanceNoiseReduction
                if let colour = pins.colorNoiseReduction { options.colorNoiseReduction = colour }
            }
        }
        options.lensCorrection = false
        let format = output.encoding
        var decoded: LinearFrame!
        do {
            observe?(index, .decode, true)
            defer { observe?(index, .decode, false) }
            decoded = try decoder.decode(job.frame.url, options: options)
        } catch {
            gate.leave(frame: index)
            finish(.failed("\(job.frame.name): \(error)"))
            return
        }
        // The SHA-256 the recipe records is of the raw as checked, so the decode must be of it too.
        guard SourceStamp.of(job.frame.url) == source else {
            gate.leave(frame: index)
            finish(.failed("\(job.frame.name): the raw changed while it was developed"))
            return
        }
        // What the encode records of the decode, taken now so its texture can go before the encode.
        let pins = decoded.pins, readback = decoded.readback, decodedBy = decoded.decoderVersion
        // The seeds, loaded and each checked against its name, outside the render lock so one lane's load overlaps another's render:
        // a file damaged since the check above fails the frame here, never printed as something else. The lane holds them until its
        // render is done; the gate counted them (`DevelopBudget.maskCost`). A frame decoded when a Stop comes still finishes, as
        // every frame in flight does: a develop stops at frame boundaries.
        let seeds: MaskSeeds
        do {
            seeds = seedsNeeded.rasters.isEmpty ? .none : try seedStore.seeds(seedsNeeded.rasters)
        } catch {
            gate.leave(frame: index)
            finish(.failed("\(job.frame.name): \(error); remove the mask or make its selection again"))
            return
        }
        // The patches, unpacked into the source the stage reads, outside the render lock as the seeds are. The stage leaves out a
        // patch its source does not give, which is right for a preview and would print the object back here, so one damaged or
        // gone since the check before the decode fails the frame now.
        if patchesNeeded.contains(where: { patches.patch($0) == nil }) {
            gate.leave(frame: index)
            let failure = Self.patchFailure(removals, store: patches.store) ?? "a removal’s pixels could not be read; develop again"
            finish(.failed("\(job.frame.name): \(failure)"))
            return
        }
        observe?(index, .waitPicture, true)
        pictures.wait()
        observe?(index, .waitPicture, false)
        let picture: CGImage
        do {
            observe?(index, .render, true)
            defer { observe?(index, .render, false) }
            picture = try renderLock.withLock {
                // The scene takes the decode's place; its texture becomes the film's densities, keeping two frame-sized textures.
                let rendered: RenderedFrame
                do {
                    let (scene, spare) = try lensStage.correct(decoded, with: lens, reusingDecode: true)
                    rendered = try renderer.render(scene, settings: recipe.render.settings, inPlace: true, seeds: seeds,
                                                   densities: spare)
                }
                // The render waited for the GPU; return its densities before making the picture.
                decoded = nil
                return try encoder.picture(rendered.image.texture, colorSpace: gpu.workingColorSpace, format: format,
                                           space: output.space, longEdge: output.size.longEdge)
            }
        } catch {
            pictures.signal()
            gate.leave(frame: index)
            finish(.failed("\(job.frame.name): \(error)"))
            return
        }
        gate.filmPassesDone(frame: index)
        withExtendedLifetime(seeds) {}
        encodeQueue.addOperation { [self] in
            observe?(index, .encode, true)
            defer {
                observe?(index, .encode, false)
                gate.leave(frame: index)
                pictures.signal()
            }
            do {
                // Written beside the final name and moved over it, so a stopped or failed
                // develop never leaves half a file under a frame's name.
                let partial = file.deletingLastPathComponent()
                    .appendingPathComponent(".\(file.lastPathComponent).partial-\(UUID().uuidString.prefix(8))")
                defer { try? FileManager.default.removeItem(at: partial) }
                guard SourceStamp.of(job.frame.url) == source else {
                    finish(.failed("\(job.frame.name): the raw changed while it was developed"))
                    return
                }
                try encoder.write(picture, to: partial, format: format, metadataFrom: job.frame.url, software: software)
                guard SourceStamp.of(job.frame.url) == source else {
                    finish(.failed("\(job.frame.name): the raw changed while it was developed"))
                    return
                }
                if let outputSource {
                    guard SourceStamp.of(file) == outputSource else {
                        finish(.failed("\(job.frame.name): the output changed while it was developed; develop again to choose a safe file name"))
                        return
                    }
                    _ = try FileManager.default.replaceItemAt(file, withItemAt: partial)
                } else {
                    guard !FileManager.default.fileExists(atPath: file.path) else {
                        finish(.failed("\(job.frame.name): another file took the output name while it was developed; develop again to choose a safe file name"))
                        return
                    }
                    try FileManager.default.moveItem(at: partial, to: file)
                }
                // The raw's SHA-256 is the one its check read (checkingSource).
                var written = recipe
                written.develops.append(Recipe.Develop(
                    date: Date(), software: software, output: output, file: file.path,
                    width: picture.width, height: picture.height, render: recipe.render, decode: pins, readback: readback,
                    stockDigest: stockDigest, renderVersion: RenderGraph.version(for: recipe.render.settings, lens: lens),
                    fallbackFrom: decodedBy == meant ? nil : meant, outputSource: SourceStamp.of(file),
                    autoRevision: job.autoRevision, rawFile: job.frame.url.path, rawSource: source))
                written.develops = Array(written.develops.suffix(Recipe.keptDevelops))
                written.version = max(written.version, written.requiredVersion)
                let receipt = written
                Task { [recipeWriter, library] in
                    do {
                        _ = try await recipeWriter.mergeExport(recipe: receipt, for: job.frame, library: library)
                        finish(.developed(file))
                    } catch {
                        finish(.failed("\(job.frame.name): the image was written to \(file.path), but its recipe could not be saved: \(error.localizedDescription)"))
                    }
                }
            } catch {
                finish(.failed("\(job.frame.name): \(error.localizedDescription)"))
            }
        }
    }

    /// Why a frame cannot print its masks, found before its decode: a selection a mask that is on has not made, or a seed the
    /// library does not hold. `nil` when every seed `needs` names is there.
    static func seedFailure(_ needs: MaskSeeds.Needs, store: MaskRasterStore) -> String? {
        if let kind = needs.pending.first {
            return "its \(kind.rawValue.capitalized) mask’s selection has not been made; make it or remove the mask"
        }
        if let lost = store.missing(needs.rasters).first {
            return "\(MaskRasterStore.Failure.missing(lost.id)); remove the mask or make its selection again"
        }
        return nil
    }

    /// Why a frame cannot print what was removed from it, found before its decode: a patch of a removal that is on which the
    /// library does not hold, or holds as a file that does not unpack to the pixels its name is the hash of. The removal is named
    /// by its row. `nil` when every such patch is there and sound; a removal that is off is not looked for, as its patch is never
    /// read.
    static func patchFailure(_ removals: [Removal], store: PatchStore) -> String? {
        var checked = Set<PatchID>()
        for (row, removal) in removals.enumerated() where removal.isOn && checked.insert(removal.patch.id).inserted {
            do {
                _ = try store.load(removal.patch)
            } catch {
                return "\(error) (Removal \(row + 1)); delete it and remove the object again"
            }
        }
        return nil
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [Outcome]
        init(count: Int) { outcomes = Array(repeating: .stopped, count: count) }
        func set(_ index: Int, _ outcome: Outcome) { lock.withLock { outcomes[index] = outcome } }
        var all: [Outcome] { lock.withLock { outcomes } }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var isSet = false
        func set() { lock.withLock { isSet = true } }
        var value: Bool { lock.withLock { isSet } }
    }
}
