import ArgentCore
import CoreGraphics
import CoreImage
import Foundation
import Metal
import QuartzCore

/// Film renders of a roll's frames: at contact-sheet size for the sheet and the stock strip,
/// and at the frame view's size with the neutral raw beside them.
///
/// The raw decode is the cost: RAW 9, which takes the a7 IV's Bayer frames (`DecoderChoices`),
/// about half a second a frame at the sheet's and the frame view's sizes, RAW 8 about 110 ms
/// whatever the preview scale (docs/decoder.md section 18, docs/M2-shell.md); the in-house decoder,
/// on its route, decodes the whole frame and area-resizes it (docs/decoder.md, section 14). So each
/// frame is decoded once, to `previewLongSide` pixels, and the
/// scene-linear result is kept; a stock switch, a new thumbnail size or new settings re-run
/// only the film passes, about a millisecond on the GPU. Decodes run two at a time and the
/// film passes on every core, and both are cancelled with the task that asked for them.
/// Everything kept is keyed by the decoder that made it, so a frame from one decoder is never
/// shown as the other's, and by the raw's version (`SourceStamp`), so a raw written over or
/// replaced while its roll is open is decoded and measured again; a decode during which the raw
/// changed is not kept.
///
/// The frame view decodes its frame again at the view's own pixel size, which costs Apple's
/// decoder little more (170 ms at 2560 pixels against 154 ms at 960, measured), renders it
/// without a resize, and keeps the few frames around it. A sheet-size picture of a frame the
/// frame view is decoding waits for that decode and scales it down rather than running a
/// second decode beside it, which would slow both.
///
/// A frame is measured from the sheet's own decode alone, the direct 960-pixel decode or its copy
/// on disk, never from a frame view's decode scaled to 960, so its measurement, and the roll's
/// settled decision made from it, do not depend on which view asked for the frame first
/// (docs/research/auto/sequence-consistency.md, section 1 and stage 4). A scaled decode serves
/// pictures only. A frame whose raw cannot be decoded or whose header cannot be read is a failure
/// (`MeasurementOutcome.failed`), told apart from a request given up on.
///
/// Apple's scaled decode, RAW 8's or RAW 9's, resolves fine texture differently from its full decode
/// area-resized, which is what a develop resized to the same pixels shows. So once its film is up,
/// the frame on screen is decoded again the develop's way and that decode replaces the scaled one
/// (`refineFrame`); the in-house decoder's scaled decodes are made that way already.
///
/// A develop shares the app's memory with the previews (`isDevelopRunning`): its trim lets go what
/// they can make again, and while it runs their decodes take turns with its frames and leave nothing
/// behind them, and they keep only what is on screen. Their renders and trims are told to the turns
/// too, and what they hold, so the develop's memory gate reads the floor it starts from once they are
/// quiet (`MemoryGate`).
public final class FilmPreviews: @unchecked Sendable {
    /// Long side of the decoded linear preview: the largest contact-sheet cell is 336 points,
    /// 672 pixels on a Retina display, with room for the frame view's first paint.
    public static let previewLongSide = 960
    /// Apple's decoder gains nothing from a third concurrent decode (measured).
    public static let concurrentDecodes = 2
    /// In-house decodes at once, of the two: each holds a full-size frame and its pyramid levels,
    /// about half a gigabyte, however small the decode.
    public static let inHouseDecodesAtOnce: Int? = 1

    public let stocks: [Stock]

    private final class LinearEntry: @unchecked Sendable {
        let frame: LinearFrame
        let input: LinearFrame?
        /// The long side the decode was asked for. The result can be a few pixels short of it,
        /// from rounding and from a raw mode's trim, so requests compare against this.
        let requested: Int
        /// The raw's version before and after the decode; `nil` when it changed during it, and then
        /// nothing made from it is kept.
        let source: SourceStamp?
        /// Header read from that same version, for the noise model of a measurement.
        let info: ARWFrameInfo?
        /// The develop's own decode area-resized, which replaced a scaled decode (`refineFrame`).
        let refined: Bool
        /// A frame view's decode scaled to the sheet's size: a picture, never measured.
        let scaled: Bool
        init(_ frame: LinearFrame, requested: Int, source: SourceStamp?, info: ARWFrameInfo?, refined: Bool = false,
             scaled: Bool = false, input: LinearFrame? = nil) {
            assert(frame.lens != nil)
            self.frame = frame
            self.input = input
            self.requested = requested
            self.source = source
            self.info = info
            self.refined = refined
            self.scaled = scaled
        }

        var heldBytes: Int {
            frame.width * frame.height * 8 + (input.map { $0.image === frame.image ? 0 : $0.width * $0.height * 8 } ?? 0)
        }

        var longSide: Int { max(frame.width, frame.height) }

        /// Whether this decode serves a request for `longSide` pixels scaled down from it: it
        /// was asked for at least that many, or it is the whole raw and nothing larger exists.
        func serves(_ longSide: Int) -> Bool { requested >= longSide || frame.scale >= 1 }

        /// Whether this decode is the frame view's picture at `longSide` pixels as it is, with no
        /// resize: it was asked for exactly that, or it is the whole raw and no larger than that.
        func fits(_ longSide: Int) -> Bool { requested == longSide || (frame.scale >= 1 && longSide >= self.longSide) }
    }

    private let gpu: GPU
    private let decoder: ChosenDecoder
    /// Which decoder each file goes to; a develop shares it, so preview and file agree.
    public let decoderChoices: DecoderChoices
    /// Each stock's film passes, by index, made up front so a stock switch never waits for them, let go
    /// for a develop, whose sheet makes a stock's again on first use, and made again after it: their
    /// LUTs are 12 MB on the GPU a stock.
    private var renderers: [Int: FilmRenderer] = [:]
    private let renderersLock = NSLock()
    /// The latest stocks' and settings' `printLimits`, under `renderersLock`; a few dozen at most.
    private var printLimitsMade: [PrintLimitsKey: PrintLimits] = [:]
    private let resize: AreaResize
    private let lensStage: LensStage
    private struct LensRecord {
        var source: SourceStamp?
        var file: LensFile
        var decoder: DecoderChoice?
        var applied: [(settings: LensSettings, lens: ResolvedLensCorrection)]
    }
    private var lenses: [String: LensRecord] = [:]
    private let lensLock = NSLock()
    let decodeQueue = OperationQueue()
    private let renderQueue = OperationQueue()
    private let linear = NSCache<NSString, LinearEntry>()
    private let renderedImages: RenderedImageCache
    /// The rendered pictures' budget outside a develop.
    private let renderedBytes: Int
    /// The frame view's decodes, least recently used first, at most `framesKept`, keyed like
    /// `linear`; under `lock`. A plain list rather than an `NSCache`, which may evict the entry it
    /// has just stored and so decode the frame on screen twice.
    private var frameLinear: [(key: String, entry: LinearEntry)] = []
    private let framesKept: Int
    /// The last smart masks' input picture made (`maskInputPicture`), keyed like `frameLinear`; under `lock`.
    private var maskInput: (key: String, picture: MaskInputPicture)?
    /// Smart selections' refined coverage at the overlay's sizes (`refinedSelection`), newest last, at most `refinedOverlaysKept`;
    /// under `lock`.
    private var refinedOverlays: [(key: RefinedOverlayKey, values: [UInt8])] = []
    static let refinedOverlaysKept = 4
    /// Overlay-sized refined selections made and found kept (`refinedSelection`), for the drive hook and tests; under `lock`.
    private var refinedOverlayCounts = (made: 0, kept: 0)
    /// Why the last overlay region could not be read, for the drive hook; under `lock`.
    private var regionCoverageFailure: String?
    /// The latest renders' GPU time and their whole time to a picture (the film pass, then the resize and the picture's read
    /// back), with when each ended, newest last, at most 256: for the drive hook, which reads those of a drag. Under `lock`.
    private var renderTimes: [(ended: CFTimeInterval, gpu: Double, whole: Double)] = []
    /// Makes those pictures, one at a time; made on first use, under its own lock.
    private var maskInputMaker: MaskInputPictureMaker?
    private let maskInputLock = NSLock()
    /// Taken after the decode turns' lock, never before it (`DecodeTurns`).
    private let lock = NSLock()
    /// Invalidates work started before a roll reset or develop trim, including running decodes.
    private var decodeGeneration: UInt64 = 0
    private var decodes = 0
    private var diskHits = 0
    /// Each frame's auto-development measurement, from its sheet decode, the first one made
    /// this session of each version of its raw (`measurementKey`); kept for the roll, a few bytes
    /// each. Under `lock`.
    private var analyses: [String: ExposureAnalysis] = [:]
    /// Each frame's sequence descriptor, made with its measurement from the same decode
    /// (`ExposureAnalyzer.measure`), or from the sheet's decode alone for a measurement a recipe
    /// gave (`descriptor`); 55 KB each at 64 by 43 cells, 19 MB for a roll of 340. Under `lock`.
    private var descriptors: [String: SequenceDescriptor] = [:]
    /// The sheet's decodes on disk, so a roll opened again does not decode them again.
    private let diskCache: LinearDiskCache?
    /// The raws' SHA-256, which name their decodes on disk.
    private let digests: SourceDigests
    /// The latest frame-size decode queued for each file, by path, for later requests to wait on.
    private var frameDecodes: [String: Operation] = [:]
    /// The same for the sheet's decodes: a cell and the strip ask for the selected frame at
    /// once, and the second waits for the first rather than decoding it again.
    private var sheetDecodes: [String: Operation] = [:]
    /// Decodes finished, under `lock`; a trim scheduled after one runs only if none followed.
    private var decodesFinished = 0
    /// How long the decoders keep what they hold for the next decode after the last one: the
    /// in-house decoder's mosaic and pyramid levels, about half a gigabyte, cost 6 to 22 ms a decode
    /// to make again (measured), so a burst keeps them and an idle sheet does not.
    public static let idleTrimDelay: Duration = .seconds(2)
    /// How long a frame stays on screen with its film up before its decode is refined: the decode
    /// ahead of the next frame, about 170 ms, goes first, and a frame passed through on the arrow
    /// keys is never refined (decision; docs/manual-development-validation.md, "Apple-decoded
    /// previews, 2026-10-16").
    public static let refineSettle: Duration = .milliseconds(300)
    /// The rendered pictures kept while a develop runs: the frame view's film, neutral raw and Auto
    /// picture are 13 MB each at 2227 pixels, and frames opened during a develop kept theirs, 0.1 GB
    /// over ten frames, under the develop's frames (docs/manual-development-validation.md, "Develops
    /// started with the frame view open").
    public static let developRenderedBytes = 64 << 20
    /// The masks' coverage kept while a develop runs: one array of 16 masks on a 3:2 frame, 89 MB, so a slider on the frame on screen
    /// bakes nothing, where the default keeps two for a drag beside a render in flight. The memory gate counts it (`heldBytes`).
    public static let developMaskFieldBytes = MaskFieldCache.defaultMaximumBytes / 2
    /// Smart masks' coefficients kept while a develop runs: one decode's three, 11 MB, so a slider on the frame on screen rebuilds
    /// nothing; the default keeps two decodes', the frame view's scaled decode and its refined one.
    public static let developRefinerBytes = MaskRefiner.defaultMaximumBytes / 2
    /// Removals' patches kept on the GPU while a develop runs: two of the model's largest, 24 MB each, or ten of 640 by 640, so
    /// a Lens slider on the frame on screen uploads none again; the default keeps the frames' around it too. The memory gate
    /// counts them (`heldBytes`).
    public static let developPatchBytes = LensStage.defaultKeptPatchBytes / 2

    /// Apple's decoder as a develop runs it, a Core Image context a decode, for `refineFrame`.
    private let fullDecoder: AppleRawDecoder
    /// The turns every decode here takes with a develop's frames while one runs; the model hands it to
    /// its developer, whose memory gate keeps the frames' side.
    public let decodeTurns = DecodeTurns()
    /// One refinement at a time, behind the decodes the frame view waits for.
    private let refineQueue = OperationQueue()
    /// Under `lock`: refinement on (the drive hook turns it off to measure), paused for a develop,
    /// and what it has done.
    private var refines = true
    private var refinementPaused = false
    private var refinementsStarted = 0, refinementsInstalled = 0, refinementsDropped = 0
    /// Told as decodes, refinements, renders and trims begin and end, for the drive hook's memory
    /// timeline; under `observerLock`.
    private var observer: (@Sendable (String) -> Void)?
    private let observerLock = NSLock()

    /// `linearCacheBytes` holds the decoded previews, 7 MB each at 960 by 640 (about 70
    /// frames at the default). `filmCacheBytes` and `frameImageBytes` together bound all
    /// rendered images, with a hard maximum of 256 MiB. The frame view keeps its
    /// last `framesKept` decodes, the frame on screen, the one decoded ahead and the one just
    /// left: 26 MB each at 2190 by 1460, 77 MB at 3800 by 2533. Its renders share the rendered
    /// image budget, 15 MB each at 2190 by 1460. `decoderChoices` says which decoder each file goes to;
    /// `inHouseDecodesAtOnce` bounds the in-house decodes among the `concurrentDecodes`. `digests`
    /// gives the raws' SHA-256 for the disk cache.
    public init(stocks: [Stock], linearCacheBytes: Int = 512 << 20, filmCacheBytes: Int = 192 << 20,
                framesKept: Int = 3, frameImageBytes: Int = 128 << 20, diskCache: LinearDiskCache? = nil,
                decoderChoices: DecoderChoices = DecoderChoices(),
                inHouseDecodesAtOnce: Int? = FilmPreviews.inHouseDecodesAtOnce, digests: SourceDigests = .shared,
                patches: (any RemovalPatchSource)? = nil) throws {
        self.stocks = stocks
        self.diskCache = diskCache
        self.digests = digests
        self.decoderChoices = decoderChoices
        renderedBytes = RenderedImageCache.budget(filmBytes: filmCacheBytes, frameBytes: frameImageBytes)
        renderedImages = RenderedImageCache(byteLimit: renderedBytes)
        // Its own GPU context, so the sheet's small textures never mix with a develop's
        // full-size ones, and a small idle pool, since evicted previews recycle into it.
        let gpu = try GPU(maxIdlePoolBytes: 64 << 20)
        self.gpu = gpu
        // Every Apple decode in a Core Image context of its own: one rendered through a shared context
        // makes a later decode in a context of its own, as the frame view's refinement, 1.6 to 3.2 times
        // as slow while that shared context lives (measured, docs/decoder.md section 18), at no cost to
        // the sheet's own decodes.
        decoder = ChosenDecoder(gpu: gpu, choices: decoderChoices, contextPerDecode: true, inHouseAtOnce: inHouseDecodesAtOnce)
        fullDecoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        // Compiled here, on one thread: the shader library compiles lazily and is not thread-safe.
        _ = try gpu.shaderLibrary()
        resize = try AreaResize(gpu: gpu)
        // The removals' pixels, which the stage composites before its warp (docs/remove-plan.md, section 4.3).
        lensStage = try LensStage(gpu: gpu, patches: patches)
        linear.totalCostLimit = linearCacheBytes
        self.framesKept = max(1, framesKept)
        decodeQueue.maxConcurrentOperationCount = Self.concurrentDecodes
        decodeQueue.qualityOfService = .userInitiated
        decodeQueue.name = "Argent film previews: decode"
        renderQueue.maxConcurrentOperationCount = ProcessInfo.processInfo.activeProcessorCount
        renderQueue.qualityOfService = .userInitiated
        renderQueue.name = "Argent film previews: render"
        refineQueue.maxConcurrentOperationCount = 1
        refineQueue.qualityOfService = .utility
        refineQueue.name = "Argent film previews: refine"
        try prepareStocks()
        decodeTurns.previewsHeld = { [weak self] in self?.heldBytes ?? 0 }
    }

    /// Where smart masks' seeds come from (`MaskRefiner.seeds`): the app's store of pinned rasters. A frame with a smart mask that
    /// changes a pixel refuses while there is none, as one whose seed the store does not hold does (`MaskRefinerError`).
    public var maskSeeds: MaskSeedProvider? {
        get { gpu.maskRefiner.seeds }
        set { gpu.maskRefiner.seeds = newValue }
    }

    /// Raw decodes run so far, for tests and the log.
    public var decodeCount: Int { lock.withLock { decodes } }

    /// Corrections resolved so far, for tests.
    var lensCount: Int { lensLock.withLock { lenses.count } }

    /// Sheet decodes read back from the disk cache instead, for tests and the log.
    public var diskHitCount: Int { lock.withLock { diskHits } }

    /// Actual retained rendered pixel storage, counted by bytesPerRow × height.
    public var renderedCacheBytes: Int { renderedImages.storedBytes }
    public var renderedCacheCount: Int { renderedImages.count }
    public var renderedCacheLimit: Int { renderedImages.byteLimit }

    /// Prefer the displayed frame and its automatic comparison over nonvisible pictures.
    /// Moving away releases its adjusted full-size image; sheet-size thumbnails remain LRU.
    public func setFocusedFrame(_ frame: Frame?) { renderedImages.focus(on: frame?.url.path) }

    /// The frame view's decode size for a picture whose longer side is `pixels` on screen: the
    /// same, so the film is rendered at the picture's own pixels from a decode of them. A decode
    /// rounded up to a multiple of 512 and the render area-resized to the window kept only 0.78
    /// to 0.87 of the develop's amplitude in the finest detail (docs/M3-auto.md, section 11).
    public static func frameDecodeSide(forPixels pixels: Int) -> Int { max(1, pixels) }

    /// The frame view's decode of a frame `longSide` pixels long. It fills them: a lossless S
    /// frame's trim would otherwise leave it a few pixels short, to be stretched on screen, and
    /// it shows the file's own area, lying where the file's pixels do (`RawMode.filled`).
    public static func frameDecodeOptions(longSide: Int) -> DecodeOptions {
        var options = DecodeOptions()
        options.maxLongSide = longSide
        options.fillsMaxLongSide = true
        return options
    }

    private func lens(_ frame: Frame, _ source: SourceStamp?, _ settings: LensSettings) -> ResolvedLensCorrection {
        let path = frame.url.path
        let kept = lensLock.withLock { lenses[path] }
        let file = kept.flatMap { $0.source == source ? $0.file : nil } ?? LensFile(reading: frame.url)
        return lensLock.withLock {
            if lenses[path]?.source != source || lenses[path] == nil {
                lenses[path] = LensRecord(source: source, file: file, decoder: nil, applied: [])
            }
            if let index = lenses[path]!.applied.firstIndex(where: { $0.settings == settings }) {
                let found = lenses[path]!.applied.remove(at: index)
                lenses[path]!.applied.append(found)
                return found.lens
            }
            let made = LensResolver.resolve(lenses[path]!.file, settings: settings)
            lenses[path]!.applied.append((settings, made))
            if lenses[path]!.applied.count > 4 { lenses[path]!.applied.removeFirst() }
            return made
        }
    }

    public func lensCorrection(for frame: Frame, settings: LensSettings) -> ResolvedLensCorrection? {
        guard let source = SourceStamp.of(frame.url) else { return nil }
        return lens(frame, source, settings)
    }

    public func lensFile(for frame: Frame) async -> LensFile? {
        await Task.detached { [self] in
            guard let source = SourceStamp.of(frame.url) else { return nil }
            _ = lens(frame, source, .default)
            return lensLock.withLock { lenses[frame.url.path]?.file }
        }.value
    }

    /// The raw's path, version, decoder and scene identity.
    private static func key(_ frame: Frame, _ source: SourceStamp?, _ decoder: DecoderChoice,
                            _ lens: ResolvedLensCorrection?) -> String {
        "\(frame.url.path)|\(source?.key ?? "none")|\(decoder.rawValue)|\(lens?.digest ?? "no-scene")"
    }

    /// Resolves the scene identity for background work such as the smart masks' picture.
    func key(_ frame: Frame, lens: LensSettings) -> String {
        let source = SourceStamp.of(frame.url)
        return Self.key(frame, source, decoderChoices.choice(for: frame.url), self.lens(frame, source, lens))
    }

    private func cachedKey(_ frame: Frame, lens settings: LensSettings) -> String {
        let source = SourceStamp.of(frame.url)
        guard let kept = lensLock.withLock({ lenses[frame.url.path] }), kept.source == source,
              let decoder = kept.decoder else { return Self.key(frame, source, .apple, nil) }
        return Self.key(frame, source, decoder, lens(frame, source, settings))
    }

    /// The key of what is kept of `frame` made from `entry`, by the decoder that made it, which is
    /// Apple's where the in-house decoder failed. Kept with the correction for synchronous lookups.
    private func keepKey(_ frame: Frame, madeFrom entry: LinearEntry) -> String {
        let key = Self.key(frame, entry.source, DecoderChoice.of(entry.frame), entry.frame.lens)
        lensLock.withLock {
            if let kept = lenses[frame.url.path], kept.source == entry.source { lenses[frame.url.path]?.decoder = DecoderChoice.of(entry.frame) }
        }
        return key
    }

    /// The key of a measurement of `frame`'s raw at version `source`.
    private static func measurementKey(_ frame: Frame, _ source: SourceStamp) -> String { "\(frame.url.path)|\(source.key)" }

    /// The key of a render of the decode kept under `decode`, refined or not.
    private func filmKey(_ decode: String, _ stock: Int, _ settings: DevelopSettings, _ space: OutputSpace,
                         _ maxPixelSize: Int, frameSized: Bool = false, refined: Bool = false) -> RenderedImageKey {
        .film(decode, stock: stock, stockID: stocks[stock].id, settings: settings, space: space,
              pixels: maxPixelSize, frameSized: frameSized, refined: refined,
              familyDecode: decode.lastIndex(of: "|").map { String(decode[..<$0]) })
    }

    private func neutralKey(_ decode: String, space: OutputSpace, pixels: Int, refined: Bool = false) -> RenderedImageKey {
        .neutral(decode, space: space, pixels: pixels, refined: refined,
                 familyDecode: decode.lastIndex(of: "|").map { String(decode[..<$0]) })
    }

    /// The render if it is already made.
    public func cachedFilm(_ frame: Frame, stock: Int, settings: DevelopSettings, space: OutputSpace,
                           maxPixelSize: Int) -> CGImage? {
        guard stocks.indices.contains(stock) else { return nil }
        return renderedImages.image(for: filmKey(cachedKey(frame, lens: settings.lens), stock, settings, space, maxPixelSize))
    }

    /// Whether the frame's raw is already decoded, so a render needs no decode.
    public func hasLinearPreview(_ frame: Frame, lens: LensSettings) -> Bool {
        linear.object(forKey: cachedKey(frame, lens: lens) as NSString) != nil
    }

    /// The frame through `stocks[stock]` with `settings`, upright, its longer side at most
    /// `maxPixelSize`, in `space`, the colour space a develop is to write, so the picture shows the
    /// colours the file will hold. `nil` when the raw cannot be decoded or the task was cancelled first.
    ///
    /// `frameViewSide`, for the frame the frame view is showing, is the frame view's decode
    /// size: the picture then comes from the frame view's decode, scaled down, so the two
    /// requests share one decode whichever comes first. A frame view smaller than the sheet's
    /// decode is not shared, so the sheet's decode keeps its size. The scaled decode is a
    /// picture only: the frame's measurement is always the sheet's own (`measure`).
    public func film(_ frame: Frame, stock: Int, settings: DevelopSettings, space: OutputSpace, maxPixelSize: Int,
                     priority: Operation.QueuePriority = .normal, frameViewSide: Int? = nil) async -> CGImage? {
        guard !Task.isCancelled, stocks.indices.contains(stock) else { return nil }
        let generation = lock.withLock { decodeGeneration }
        let requestedKey = filmKey(cachedKey(frame, lens: settings.lens), stock, settings, space, maxPixelSize)
        let ticket = renderedImages.beginRequest(for: requestedKey)
        if let cached = renderedImages.image(for: requestedKey, ticket: ticket) { return isCurrentDecode(generation) ? cached : nil }
        guard let preview = await linearPreview(frame, lens: settings.lens, priority: priority, frameViewSide: frameViewSide, generation: generation),
              !Task.isCancelled, isCurrentDecode(generation), renderedImages.isCurrent(ticket) else { return nil }
        // Kept under the decoder that made it.
        let key = filmKey(keepKey(frame, madeFrom: preview), stock, settings, space, maxPixelSize)
        return await QueuedWork.runStoppable(on: renderQueue, priority: priority, prepare: { operation in
            self.renderedImages.attach(operation, to: ticket)
        }) { [self] stopped in
            guard !stopped(), isCurrentDecode(generation), renderedImages.isCurrent(ticket) else { return nil }
            if let cached = renderedImages.image(for: key, ticket: ticket) { return cached }
            note("sheet-render \(frame.name) \(maxPixelSize) +")
            decodeTurns.beginRender()
            defer {
                decodeTurns.endRender()
                note("sheet-render \(frame.name) \(maxPixelSize) -")
            }
            guard let renderer = try? renderer(stock),
                  let image = try? render(preview.frame, with: renderer, settings: settings, space: space, maxPixelSize: maxPixelSize)
            else { return nil }
            guard !stopped(), isCurrentDecode(generation), renderedImages.isCurrent(ticket) else { return nil }
            if let source = preview.source, SourceStamp.of(frame.url) == source {
                renderedImages.store(image, for: key, ticket: ticket)
            }
            return image
        }
    }

    // MARK: Auto development

    /// What measuring a frame came to (`measure`).
    public enum MeasurementOutcome: Sendable, Equatable {
        /// Measured from its sheet decode, with the descriptor made from the same decode; none for a
        /// measurement a recipe gave (`seedAnalysis`) until one is asked for (`descriptor`).
        case measured(FrameMeasurement, SequenceDescriptor?)
        /// The raw at this version, `nil` when the file is gone, could not be decoded or its header
        /// read: measured again it would fail again, until the raw changes.
        case failed(SourceStamp?)
        /// Given up on before an answer: the caller was cancelled, a roll reset or a develop's trim
        /// let the work go, or the raw changed while it was decoded. Nothing is known of the frame.
        case stopped
    }

    /// The frame's auto-development measurement with the version of the raw it was made from, if
    /// it has been made of its raw as it is now.
    public func cachedMeasurement(_ frame: Frame) -> FrameMeasurement? {
        guard let source = SourceStamp.of(frame.url) else { return nil }
        return lock.withLock { analyses[Self.measurementKey(frame, source)] }.map { FrameMeasurement(analysis: $0, source: source) }
    }

    /// The frame's sequence descriptor from its sheet decode, if made of its raw as it is now.
    public func cachedDescriptor(_ frame: Frame) -> SequenceDescriptor? {
        guard let source = SourceStamp.of(frame.url) else { return nil }
        return lock.withLock { descriptors[Self.measurementKey(frame, source)] }
    }

    /// The frame's auto-development measurement, from its sheet decode alone: read from memory or
    /// disk, or decoded. `nil` when the raw cannot be decoded, changes while it is, or the task was
    /// cancelled first; `measure` tells these apart.
    public func analysis(_ frame: Frame, priority: Operation.QueuePriority = .normal) async -> ExposureAnalysis? {
        await measurement(frame, priority: priority)?.analysis
    }

    /// The same, with the version of the raw it was made from.
    public func measurement(_ frame: Frame, priority: Operation.QueuePriority = .normal) async -> FrameMeasurement? {
        guard case .measured(let measured, _) = await measure(frame, priority: priority) else { return nil }
        return measured
    }

    /// Measures the frame from its sheet decode, the direct decode at `previewLongSide` or its copy on
    /// disk, decoding it if need be, and never from a frame view's decode: its measurement and
    /// descriptor, or why there is none.
    public func measure(_ frame: Frame, priority: Operation.QueuePriority = .normal) async -> MeasurementOutcome {
        guard !Task.isCancelled else { return .stopped }
        let generation = lock.withLock { decodeGeneration }
        if let known = cachedMeasurement(frame) {
            let key = Self.measurementKey(frame, known.source)
            return lock.withLock { decodeGeneration == generation ? .measured(known, descriptors[key]) : .stopped }
        }
        let decode = await sheetDecode(frame, lens: .default, priority: priority, generation: generation, measuring: true)
        guard !Task.isCancelled, isCurrentDecode(generation) else { return .stopped }
        switch decode {
        case .stopped:
            return .stopped
        case .failed(let source):
            return SourceStamp.of(frame.url) == source ? .failed(source) : .stopped
        case .decoded(let entry):
            guard let source = entry.source, SourceStamp.of(frame.url) == source else { return .stopped }
            let key = Self.measurementKey(frame, source)
            return lock.withLock {
                guard decodeGeneration == generation, let analysis = analyses[key] else { return .stopped }
                return .measured(FrameMeasurement(analysis: analysis, source: source), descriptors[key])
            }
        }
    }

    /// The frame's sequence descriptor, from its sheet decode, made from that decode if need be for a
    /// frame whose measurement a recipe gave (`seedAnalysis`), its measurement left as it is. `nil`
    /// when the raw cannot be decoded, changes while it is, or the task was cancelled first.
    public func descriptor(_ frame: Frame, priority: Operation.QueuePriority = .normal) async -> SequenceDescriptor? {
        guard !Task.isCancelled else { return nil }
        let generation = lock.withLock { decodeGeneration }
        if let known = cachedDescriptor(frame) { return isCurrentDecode(generation) ? known : nil }
        guard case .decoded(let entry) = await sheetDecode(frame, lens: .default, priority: priority, generation: generation, measuring: true),
              !Task.isCancelled, isCurrentDecode(generation), let source = entry.source, let info = entry.info,
              SourceStamp.of(frame.url) == source else { return nil }
        let key = Self.measurementKey(frame, source)
        if let made = lock.withLock({ descriptors[key] }) { return made }
        let described = await QueuedWork.run(on: renderQueue, priority: priority) { Self.describe(entry.frame, info: info) }
        guard let described, SourceStamp.of(frame.url) == source else { return nil }
        return lock.withLock {
            guard decodeGeneration == generation else { return nil }
            if descriptors[key] == nil { descriptors[key] = described }
            return descriptors[key]
        }
    }

    /// The descriptor `ExposureAnalyzer.measure` makes of `decoded`, from the same grid, without
    /// measuring it again.
    private static func describe(_ decoded: LinearFrame, info: ARWFrameInfo) -> SequenceDescriptor {
        let noise = DecodedNoise.appleDecode(model: info.model, iso: info.iso, pins: decoded.pins)
        return SequenceDescriptor(grid: ExposureAnalyzer.grid(pixels: ExposureAnalyzer.pixels(of: decoded.texture),
                                                              width: decoded.width, height: decoded.height, noise: noise))
    }

    /// Sets a frame's measurement from its recipe, checked against the raw at version `source`,
    /// so a roll developed before is printed as it was then. A measurement made this session is
    /// not replaced, and a raw no longer at that version is measured again.
    public func seedAnalysis(_ analysis: ExposureAnalysis, for frame: Frame, source: SourceStamp) {
        guard analysis.isCurrent else { return }
        let key = Self.measurementKey(frame, source)
        lock.withLock { if analyses[key] == nil { analyses[key] = analysis } }
    }

    // MARK: The frame view

    /// The frame view's film render, if it is already made at this size: the one from a refined
    /// decode first, kept or not, since it is the develop's own picture (`refineFrame`).
    public func cachedFrameFilm(_ frame: Frame, stock: Int, settings: DevelopSettings, space: OutputSpace,
                                pixels: Int) -> CGImage? {
        guard stocks.indices.contains(stock) else { return nil }
        let decode = cachedKey(frame, lens: settings.lens)
        return renderedImages.image(for: filmKey(decode, stock, settings, space, pixels, frameSized: true, refined: true))
            ?? renderedImages.image(for: filmKey(decode, stock, settings, space, pixels, frameSized: true))
    }

    /// The frame view's neutral raw, if it is already made at this size, the refined one first.
    public func cachedFrameNeutral(_ frame: Frame, lens: LensSettings, space: OutputSpace, pixels: Int) -> CGImage? {
        let decode = cachedKey(frame, lens: lens)
        return renderedImages.image(for: neutralKey(decode, space: space, pixels: pixels, refined: true))
            ?? renderedImages.image(for: neutralKey(decode, space: space, pixels: pixels))
    }

    /// Whether `image` is the frame view's film of `frame` rendered from a refined decode, for the
    /// drive hook's measurements.
    public func isRefinedFrameFilm(_ image: CGImage, frame: Frame, stock: Int, settings: DevelopSettings, space: OutputSpace,
                                   pixels: Int) -> Bool {
        guard stocks.indices.contains(stock) else { return false }
        return renderedImages.image(for: filmKey(cachedKey(frame, lens: settings.lens), stock, settings, space, pixels, frameSized: true, refined: true)) === image
    }

    /// Compiles the brush's library, Follow edges' and the refiner's kernels off the caller's thread, for the Masks tab's opening: they are the slowest
    /// compiles the masks have (0.5, 1.7 and about 0.6 s on a cold compile cache, measured), and a press waits for the first two and a Follow edges
    /// stroke's release for the last. A few milliseconds once the system's compile cache holds them, as it does from the second launch on (measured).
    public func prepareMaskKernels() async {
        let cache = gpu.maskFields, refiner = gpu.maskRefiner
        await Task.detached(priority: .userInitiated) {
            try? cache.prepareBrushLibrary()
            try? cache.prepareFollowEdges()
            try? refiner.prepare()
        }.value
    }

    /// Holds the frame view's decode of `frame` for `pixels`, made if it was let go while its film stayed (a film outlives its decode, so a frame seen
    /// earlier can show its film with no decode held): what a brush needs, whose press refuses without it (`brushPicture`). No-op when one is held.
    public func holdFrameDecode(_ frame: Frame, lens: LensSettings, pixels: Int) async {
        guard peekFrameEntry(cachedKey(frame, lens: lens)) == nil else { return }
        let generation = lock.withLock { decodeGeneration }
        _ = await frameDecode(frame, lens: lens, longSide: Self.frameDecodeSide(forPixels: pixels), priority: .veryHigh, generation: generation)
    }

    /// `holdFrameDecode`, begun and not waited for.
    public func wantFrameDecode(_ frame: Frame, lens: LensSettings, pixels: Int) { Task { await holdFrameDecode(frame, lens: lens, pixels: pixels) } }

    /// Whether the frame view keeps a decode of `frame` for `pixels`, without marking it used.
    public func keepsFrameDecode(_ frame: Frame, lens: LensSettings, pixels: Int) -> Bool {
        peekFrameEntry(cachedKey(frame, lens: lens))?.fits(Self.frameDecodeSide(forPixels: pixels)) == true
    }

    /// Whether the frame is decoded for a frame view `pixels` wide, so its film is a render away.
    public func hasFrameDecode(_ frame: Frame, lens: LensSettings, pixels: Int) -> Bool {
        frameEntry(cachedKey(frame, lens: lens))?.fits(Self.frameDecodeSide(forPixels: pixels)) == true
    }

    /// Whether the frame view's decode of `frame` for `pixels` is the refined one, the develop's own
    /// decode area-resized (`refineFrame`).
    public func isFrameDecodeRefined(_ frame: Frame, lens: LensSettings, pixels: Int) -> Bool {
        guard let entry = peekFrameEntry(cachedKey(frame, lens: lens)) else { return false }
        return entry.refined && entry.fits(Self.frameDecodeSide(forPixels: pixels))
    }

    /// The frame for the frame view: through `stocks[stock]` with `settings`, upright, its
    /// longer side `pixels` or the raw's own if that is smaller, in `space`, the colour space a
    /// develop is to write. `nil` when the raw cannot be decoded or the task was cancelled first.
    public func frameFilm(_ frame: Frame, stock: Int, settings: DevelopSettings, space: OutputSpace, pixels: Int,
                          priority: Operation.QueuePriority = .veryHigh) async -> CGImage? {
        guard !Task.isCancelled, stocks.indices.contains(stock) else { return nil }
        let generation = lock.withLock { decodeGeneration }
        let decode = cachedKey(frame, lens: settings.lens), refined = isFrameDecodeRefined(frame, lens: settings.lens, pixels: pixels)
        // A refined render outlives its decode; looked for before the request, which would let it go.
        if !refined, let kept = renderedImages.image(for: filmKey(decode, stock, settings, space, pixels, frameSized: true, refined: true)) {
            return isCurrentDecode(generation) ? kept : nil
        }
        let requestedKey = filmKey(decode, stock, settings, space, pixels, frameSized: true, refined: refined)
        let ticket = renderedImages.beginRequest(for: requestedKey)
        if let cached = renderedImages.image(for: requestedKey, ticket: ticket) { return isCurrentDecode(generation) ? cached : nil }
        guard let entry = await frameDecode(frame, lens: settings.lens, longSide: Self.frameDecodeSide(forPixels: pixels), priority: priority,
                                           generation: generation),
              !Task.isCancelled, isCurrentDecode(generation), renderedImages.isCurrent(ticket) else { return nil }
        let key = filmKey(keepKey(frame, madeFrom: entry), stock, settings, space, pixels, frameSized: true, refined: entry.refined)
        return await QueuedWork.runStoppable(on: renderQueue, priority: priority, prepare: { operation in
            self.renderedImages.attach(operation, to: ticket)
        }) { [self] stopped in
            guard !stopped(), isCurrentDecode(generation), renderedImages.isCurrent(ticket) else { return nil }
            if let cached = renderedImages.image(for: key, ticket: ticket) { return cached }
            note("frame-render \(frame.name) \(pixels) +")
            decodeTurns.beginRender()
            defer {
                decodeTurns.endRender()
                note("frame-render \(frame.name) \(pixels) -")
            }
            guard let renderer = try? renderer(stock),
                  let image = try? render(entry.frame, with: renderer, settings: settings, space: space, maxPixelSize: pixels)
            else { return nil }
            guard !stopped(), isCurrentDecode(generation), renderedImages.isCurrent(ticket) else { return nil }
            if let source = entry.source, SourceStamp.of(frame.url) == source {
                renderedImages.store(image, for: key, ticket: ticket)
            }
            return image
        }
    }

    /// The neutral raw for the frame view: the film's own decode with no film, scene-linear
    /// light shown as display-linear light, so a metered mid-gray shows at 0.18 as it does
    /// through every stock's print (measured, 0.180 to 0.182) and light more than 2.47 stops
    /// over it clips at display white. In `space`, as the film beside it is, so comparing the two
    /// shows what the film does and no difference between colour spaces.
    public func frameNeutral(_ frame: Frame, lens: LensSettings, space: OutputSpace, pixels: Int,
                             priority: Operation.QueuePriority = .veryHigh) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let generation = lock.withLock { decodeGeneration }
        let decode = cachedKey(frame, lens: lens), refined = isFrameDecodeRefined(frame, lens: lens, pixels: pixels)
        if !refined, let kept = renderedImages.image(for: neutralKey(decode, space: space, pixels: pixels, refined: true)) {
            return isCurrentDecode(generation) ? kept : nil
        }
        let requestedKey = neutralKey(decode, space: space, pixels: pixels, refined: refined)
        let ticket = renderedImages.beginRequest(for: requestedKey)
        if let cached = renderedImages.image(for: requestedKey, ticket: ticket) { return isCurrentDecode(generation) ? cached : nil }
        guard let entry = await frameDecode(frame, lens: lens, longSide: Self.frameDecodeSide(forPixels: pixels), priority: priority,
                                           generation: generation),
              !Task.isCancelled, isCurrentDecode(generation), renderedImages.isCurrent(ticket) else { return nil }
        let key = neutralKey(keepKey(frame, madeFrom: entry), space: space, pixels: pixels, refined: entry.refined)
        return await QueuedWork.runStoppable(on: renderQueue, priority: priority, prepare: { operation in
            self.renderedImages.attach(operation, to: ticket)
        }) { [self] stopped in
            guard !stopped(), isCurrentDecode(generation), renderedImages.isCurrent(ticket) else { return nil }
            if let cached = renderedImages.image(for: key, ticket: ticket) { return cached }
            note("neutral-render \(frame.name) \(pixels) +")
            decodeTurns.beginRender()
            defer {
                decodeTurns.endRender()
                note("neutral-render \(frame.name) \(pixels) -")
            }
            guard let image = try? displayImage(entry.frame.texture, space: space, maxPixelSize: pixels) else { return nil }
            guard !stopped(), isCurrentDecode(generation), renderedImages.isCurrent(ticket) else { return nil }
            if let source = entry.source, SourceStamp.of(frame.url) == source {
                renderedImages.store(image, for: key, ticket: ticket)
            }
            return image
        }
    }

    /// Decodes the frame for the frame view at exactly `longSide`, or waits for a decode of it
    /// already queued, and returns the result; `nil` when the raw cannot be decoded or the task
    /// was cancelled first. A window resized to a new size decodes again.
    private func frameDecode(_ frame: Frame, lens: LensSettings, longSide: Int, priority: Operation.QueuePriority,
                             generation: UInt64) async -> LinearEntry? {
        guard isCurrentDecode(generation) else { return nil }
        let path = frame.url.path
        if let entry = frameEntry(cachedKey(frame, lens: lens)), entry.fits(longSide) { return entry }
        return await QueuedWork.runStoppable(on: decodeQueue, priority: priority, prepare: { operation in
            // Waiting on the decode before and becoming the one after it, under one lock, so
            // requests that arrive together queue one decode between them.
            self.lock.withLock {
                guard self.decodeGeneration == generation else { operation.cancel(); return }
                if let pending = self.pendingFrameDecode(path, raisingTo: priority) { operation.addDependency(pending) }
                self.frameDecodes[path] = operation
                if self.frameDecodes.count > 64 { self.frameDecodes = self.frameDecodes.filter { !$0.value.isFinished } }
            }
        }) { [self] stopped in
            guard !stopped(), isCurrentDecode(generation) else { return nil }
            guard let snapshot = FrameHeaders.shared.current(frame) else { return nil }
            let source = snapshot.source
            if let entry = frameEntry(Self.key(frame, source, decoderChoices.choice(for: frame.url), self.lens(frame, source, lens))), entry.fits(longSide) {
                return entry
            }
            let previous = lock.withLock { frameLinear.last(where: { $0.key.hasPrefix(path + "|") })?.entry }
            let input: LinearFrame
            let refined: Bool
            if let previous, previous.source == source, previous.fits(longSide), let kept = previous.input {
                input = kept
                refined = previous.refined
            } else {
                note("frame-turn \(frame.name) \(longSide) +")
                guard decodeTurns.beginPreview(stopped: { stopped() || !self.isCurrentDecode(generation) }) else {
                    note("frame-turn \(frame.name) \(longSide) -")
                    return nil
                }
                note("frame-turn \(frame.name) \(longSide) -")
                note("frame-decode \(frame.name) \(longSide) +")
                var options = Self.frameDecodeOptions(longSide: longSide)
                options.lensCorrection = false
                let result = try? decoder.decode(frame.url, options: options)
                decodeTurns.endPreview()
                note("frame-decode \(frame.name) \(longSide) -")
                trimWhenIdle()
                guard let decoded = result else { return nil }
                lock.withLock { decodes += 1 }
                input = decoded
                refined = false
            }
            guard !stopped(), isCurrentDecode(generation),
                  let decoded = try? lensStage.correct(input, with: self.lens(frame, source, lens)) else { return nil }
            let valid = SourceStamp.of(frame.url) == source
            let entry = LinearEntry(decoded, requested: longSide, source: valid ? source : nil,
                                    info: valid ? snapshot.frame.info : nil, refined: refined, input: input)
            guard entry.source != nil else { return entry }
            let key = keepKey(frame, madeFrom: entry)
            // While a develop runs, only the frame on screen. Read before the lock: the turns' lock comes
            // first (`DecodeTurns`).
            let kept = decodeTurns.isDevelopRunning ? 1 : framesKept
            return lock.withLock {
                guard !stopped(), decodeGeneration == generation else { return nil }
                frameLinear.removeAll { $0.key.hasPrefix(path + "|") }
                frameLinear.append((key, entry))
                if frameLinear.count > kept { frameLinear.removeFirst(frameLinear.count - kept) }
                return entry
            }
        }
    }

    /// Replaces the frame view's scaled decode of `frame` for `pixels` with the develop's own decode,
    /// full size in the develop's tiles, area-resized to the same pixels, so the frame view shows
    /// what a develop resized to them shows, as the in-house decoder's previews already do
    /// (docs/manual-development-validation.md, "Apple-decoded previews, 2026-10-16"). The tiles are
    /// resized as they come, so the 250 MB full-size frame is never held (route (b′)). Only a decode
    /// Apple made below full size is refined, RAW 8's by RAW 8 and RAW 9's by RAW 9. Apple's full
    /// decode takes three to four times its
    /// scaled one, so the frame view asks once the scaled decode's film is up and the frame has
    /// stayed on screen `refineSettle`. One runs at a time; it stops between tiles once its caller
    /// is cancelled, the frame view's decodes are let go or a develop pauses refinement, and the
    /// in-house decoder's idle buffers go first, as before any Apple decode. `true` when the frame
    /// view's decode for `pixels` is the refined one, now or already; renders made from the scaled
    /// decode give way to the refined ones in the rendered-image budget.
    public func refineFrame(_ frame: Frame, lens: LensSettings, pixels: Int) async -> Bool {
        guard !Task.isCancelled else { return false }
        let longSide = Self.frameDecodeSide(forPixels: pixels)
        let generation = lock.withLock { decodeGeneration }
        let entryKey = cachedKey(frame, lens: lens)
        guard let base = peekFrameEntry(entryKey), base.fits(longSide) else { return false }
        if base.refined { return true }
        // Apple's scaled decodes, RAW 8's or RAW 9's, each refined by the decoder that made it.
        let madeBy = DecoderChoice.of(base.frame)
        guard base.frame.scale < 1, madeBy != .inHouse, let source = base.source,
              lock.withLock({ refines && !refinementPaused }) else { return false }
        let (width, height) = (base.frame.width, base.frame.height)
        return await QueuedWork.runStoppable(on: refineQueue) { [self] stopped in
            func halted() -> Bool {
                stopped() || lock.withLock { decodeGeneration != generation || !refines || refinementPaused }
            }
            guard !halted(), lock.withLock({ frameLinear.contains { $0.entry.input?.image === base.input?.image && $0.entry.source == source } }) else { return false }
            // None starts while a develop runs; one under way as it starts holds its first frame back.
            guard decodeTurns.beginPreview(stopped: halted) else { return false }
            defer { decodeTurns.endPreview() }
            lock.withLock { refinementsStarted += 1 }
            note("refine \(frame.name) \(width) +")
            defer { note("refine \(frame.name) \(width) -") }
            decoder.trim()
            var options = DecodeOptions()
            // In the develop's tiles for the decoder.
            options.tileSize = madeBy == .raw9 ? RollDeveloper.learnedDecodeTile : RollDeveloper.decodeTile
            options.appleDecoder = madeBy == .raw9 ? .learned : .classic
            options.lensCorrection = false
            let refined: LinearFrame
            do {
                refined = try fullDecoder.decode(frame.url, options: options, areaResizedTo: (width, height),
                                                using: resize, stopped: halted)
            } catch {
                lock.withLock { refinementsDropped += 1 }
                return false
            }
            while true {
                // A raw that changed during the decode or stage gives a picture of neither version.
                let unchanged = SourceStamp.of(frame.url) == source
                let correction = lock.withLock { () -> ResolvedLensCorrection? in
                    guard unchanged, !stopped(), decodeGeneration == generation, refines, !refinementPaused,
                          let entry = frameLinear.first(where: { $0.entry.input?.image === base.input?.image && $0.entry.source == source }),
                          let correction = entry.entry.frame.lens else {
                        refinementsDropped += 1
                        return nil
                    }
                    return correction
                }
                guard let correction else { return false }
                guard let scene = try? lensStage.correct(refined, with: correction) else {
                    lock.withLock { refinementsDropped += 1 }
                    return false
                }
                let stillUnchanged = SourceStamp.of(frame.url) == source
                let installed = lock.withLock { () -> Bool? in
                    guard stillUnchanged, !stopped(), decodeGeneration == generation, refines, !refinementPaused,
                          let index = frameLinear.firstIndex(where: { $0.entry.input?.image === base.input?.image && $0.entry.source == source }) else {
                        refinementsDropped += 1
                        return false
                    }
                    // The film can change Lens while the stage runs. Stage its newest lens before installing.
                    guard frameLinear[index].entry.frame.lens == correction else { return nil }
                    let entry = LinearEntry(scene, requested: base.requested, source: source, info: base.info, refined: true, input: refined)
                    frameLinear[index] = (keepKey(frame, madeFrom: entry), entry)
                    refinementsInstalled += 1
                    return true
                }
                if let installed { return installed }
            }
        } ?? false
    }

    /// Whether frame decodes are refined (`refineFrame`); on unless the drive hook turns it off to
    /// measure. Turning it off stops a refinement under way at its next tile.
    public var refinesFrameDecodes: Bool {
        get { lock.withLock { refines } }
        set { lock.withLock { refines = newValue } }
    }

    /// Set while a develop runs, whose memory gate does not count a refinement: none starts, and
    /// one under way stops at its next tile.
    public var pausesRefinement: Bool {
        get { lock.withLock { refinementPaused } }
        set { lock.withLock { refinementPaused = newValue } }
    }

    /// Set while a develop runs, from the moment it is asked for to its end. A decode here adds 0.3 to
    /// 0.84 GB at the frame view's sizes, and the develop's memory gate, reading the footprint before each
    /// frame, cannot see it coming (docs/manual-development-validation.md, "Develops started with the
    /// frame view open"). So meanwhile no refinement starts (`pausesRefinement`), each decode waits for its
    /// turn with the develop's frames (`decodeTurns`), and none leaves anything behind: Apple's decodes
    /// have a Core Image context each at all times, which gives their surfaces back within 0.1 s where a
    /// shared one keeps them 1 to 2 s, the renders get one each too, the in-house decoder lets its buffers
    /// go after each, and the texture pool keeps nothing idle. And the previews keep what is on screen, not what was: the frame
    /// view the decode of its frame, the rendered pictures `developRenderedBytes`, the masks' coverage
    /// `developMaskFieldBytes`, the removals' patches `developPatchBytes`, and the sheet's decodes stay on disk.
    public var isDevelopRunning: Bool {
        get { decodeTurns.isDevelopRunning }
        set {
            pausesRefinement = newValue
            decoder.keepsInHouseBuffers = !newValue
            gpu.texturePool.keepsIdleTextures = !newValue
            renderedImages.byteLimit = newValue ? min(renderedBytes, Self.developRenderedBytes) : renderedBytes
            gpu.maskFields.maximumBytes = newValue ? Self.developMaskFieldBytes : MaskFieldCache.defaultMaximumBytes
            gpu.maskRefiner.maximumBytes = newValue ? Self.developRefinerBytes : MaskRefiner.defaultMaximumBytes
            gpu.presenceAnalyses.maximumBytes = newValue ? PresenceAnalyses.developRunningMaximumBytes
                : PresenceAnalyses.defaultMaximumBytes
            lensStage.maximumKeptPatchBytes = newValue ? Self.developPatchBytes : LensStage.defaultKeptPatchBytes
            decodeTurns.isDevelopRunning = newValue
        }
    }

    /// Refinements started, installed in place of a scaled decode, and dropped (stopped, failed or
    /// overtaken), for the drive hook's measurements and the tests.
    public var refinementCounts: (started: Int, installed: Int, dropped: Int) {
        lock.withLock { (refinementsStarted, refinementsInstalled, refinementsDropped) }
    }

    private func isCurrentDecode(_ generation: UInt64) -> Bool { lock.withLock { decodeGeneration == generation } }

    // MARK: Measuring

    /// Told as the previews' decodes, refinements, renders and develop trims begin ("+") and end
    /// ("-"), for the drive hook's memory timeline.
    public var observeWork: (@Sendable (String) -> Void)? {
        get { observerLock.withLock { observer } }
        set { observerLock.withLock { observer = newValue } }
    }

    private func note(_ what: @autoclosure () -> String) {
        guard let observer = observerLock.withLock({ observer }) else { return }
        observer(what())
    }

    /// Asks the sheet's Core Image context to let its caches go (`clear`) or its resources
    /// (`reclaim`), or replaces it (`renew`), for the drive hook's memory measurements.
    public func releaseCoreImageMemory(_ how: String) {
        switch how {
        case "reclaim": gpu.ciContext.reclaimResources()
        case "renew": gpu.renewContext()
        default: gpu.ciContext.clearCaches()
        }
    }

    /// The frame view's decodes, the rendered pictures, the smart masks' input picture, the masks' coverage arrays and tables,
    /// Presence's kept analyses and the removals' patches the lens stage keeps, the bytes the develop's memory gate counts apart from
    /// its floor (`DecodeTurns.previewsHeld`).
    var heldBytes: Int {
        lock.withLock {
            frameLinear.reduce(0) { $0 + $1.entry.heldBytes } + (maskInput?.picture.byteCount ?? 0)
                + refinedOverlays.reduce(0) { $0 + $1.values.count }
        }
            + renderedImages.storedBytes + maskBytes.coverage + maskBytes.tables + maskBytes.refinements
            + gpu.presenceAnalyses.residentBytes + lensStage.keptPatchBytes
    }

    /// Removals' patches uploaded to the lens stage and laid into a decode so far, for tests.
    var removalStatistics: (uploads: Int, composites: Int) { lensStage.removalStatistics }
    /// The most the lens stage keeps of them, for the tests: half while a develop runs.
    var keptPatchLimit: Int { lensStage.maximumKeptPatchBytes }

    /// The masks' coverage arrays the cache keeps (`MaskFieldCache.residentBytes`), the renderers' tables for them, 182 KB a stock
    /// that rendered a frame with masks, and smart masks' coefficients (`MaskRefiner.residentBytes`). An array or coefficients a render
    /// still holds after the cache let them go are in none, for the moments they are.
    var maskBytes: (coverage: Int, tables: Int, refinements: Int) {
        (gpu.maskFields.residentBytes, renderersLock.withLock { renderers.values.reduce(0) { $0 + $1.localTableBytes } },
         gpu.maskRefiner.residentBytes)
    }

    /// What the masks' field cache has done, for the tests and the drive hook.
    public var maskFieldStatistics: MaskFieldCache.Statistics { gpu.maskFields.statistics }
    /// What smart masks' refinement has built and found kept, for tests and the drive hook.
    public var maskRefinerStatistics: MaskRefiner.Statistics { gpu.maskRefiner.statistics }
    /// Why the last region coverage could not be read, for the drive hook.
    public var regionCoverageFailureDescription: String? { lock.withLock { regionCoverageFailure } }

    /// The frame view's held decode size and whether refined, for the drive hook.
    public var frameDecodeStatistic: String {
        lock.withLock { frameLinear.map { "\($0.entry.frame.width)x\($0.entry.frame.height)\($0.entry.refined ? " refined" : "")" }.joined(separator: ", ") }
    }

    /// The overlay's refined selections made and found kept (`refinedSelection`).
    public var refinedOverlayStatistics: (made: Int, kept: Int) { lock.withLock { refinedOverlayCounts } }

    /// The most the masks' field cache keeps, for the tests: two 16-mask arrays, one while a develop runs.
    var maskFieldLimit: Int { gpu.maskFields.maximumBytes }
    /// The same for Presence's analyses.
    var presenceAnalysisLimit: Int { gpu.presenceAnalyses.maximumBytes }

    /// What the previews hold now, for the drive hook's memory measurements: the frame view's
    /// decodes, the rendered images, the sheet's idle pool, the in-house decoder's buffers, and what
    /// Metal has allocated for the whole process.
    public var heldReport: String {
        let (count, bytes, refined) = lock.withLock {
            (frameLinear.count, frameLinear.reduce(0) { $0 + $1.entry.heldBytes },
             frameLinear.filter { $0.entry.refined }.count)
        }
        let masks = maskBytes
        return "frame decodes \(count) (\(bytes >> 20) MB, \(refined) refined), rendered \(renderedImages.storedBytes >> 20) MB"
            + " in \(renderedImages.count), mask fields \(masks.coverage >> 20) MB, mask tables \(masks.tables >> 10) KB, refinements \(masks.refinements >> 20) MB,"
            + " sheet pool idle \(gpu.texturePool.idleByteCount >> 20) MB,"
            + " in-house kept \(decoder.inHouseKeptBytes >> 20) MB, metal \(gpu.device.currentAllocatedSize >> 20) MB"
    }

    /// Frees what the decoder keeps for its next decode `idleTrimDelay` after this decode, unless
    /// another has finished by then or is queued.
    private func trimWhenIdle() {
        let finished = lock.withLock { () -> Int in
            decodesFinished += 1
            return decodesFinished
        }
        Task.detached(priority: .utility) { [self] in
            try? await Task.sleep(for: Self.idleTrimDelay)
            guard lock.withLock({ decodesFinished == finished }), decodeQueue.operationCount == 0 else { return }
            decoder.trim()
        }
    }

    /// The frame view's decode kept under `key`, marked as just used.
    private func frameEntry(_ key: String) -> LinearEntry? {
        lock.withLock {
            guard let index = frameLinear.firstIndex(where: { $0.key == key }) else { return nil }
            let item = frameLinear.remove(at: index)
            frameLinear.append(item)
            return item.entry
        }
    }

    /// The same, left where it is in the order of use.
    private func peekFrameEntry(_ key: String) -> LinearEntry? {
        lock.withLock { frameLinear.first { $0.key == key }?.entry }
    }

    /// The frame view's decode of `frame` for `pixels`, for tests.
    func frameDecode(of frame: Frame, lens: LensSettings, pixels: Int) -> LinearFrame? {
        guard let entry = peekFrameEntry(cachedKey(frame, lens: lens)), entry.fits(Self.frameDecodeSide(forPixels: pixels)) else { return nil }
        return entry.frame
    }

    /// The frame-size decode of the file at `path` still queued or running, if any; call it holding `lock`.
    /// A request that waits on it lends it its priority, so a decode queued ahead at low
    /// priority runs next once the frame view reaches its frame.
    private func pendingFrameDecode(_ path: String, raisingTo priority: Operation.QueuePriority) -> Operation? {
        guard let operation = frameDecodes[path], !operation.isFinished else { return nil }
        if !operation.isExecuting, operation.queuePriority.rawValue < priority.rawValue {
            operation.queuePriority = priority
        }
        return operation
    }

    /// Makes every stock's film passes not already made: up front, and again after a develop.
    public func prepareStocks() throws {
        for index in stocks.indices { _ = try renderer(index) }
    }

    /// The film passes for `stocks[index]`, made on first use.
    private func renderer(_ index: Int) throws -> FilmRenderer {
        try renderersLock.withLock {
            if let made = renderers[index] { return made }
            let made = try FilmRenderer(gpu: gpu, stock: stocks[index])
            renderers[index] = made
            return made
        }
    }

    /// The print's own white and black as the frame view's pictures show them (8-bit codes in `space`,
    /// `displayImage`) for `stock` and `settings`: what a uniform frame of scene light far past any
    /// negative's range, and one of none, come out as, without grain, halation or sharpening, which
    /// a uniform frame does not need. A film print's highlights end at its paper white and its
    /// shadows at its deepest black, which can sit inside the display's codes (Portra 400's at 251 and
    /// 17 in Display P3, measured 2026-10-29), so the app's clipping views compare a film's codes to
    /// these as Lightroom's compare to its output's ends. Two 8-pixel renders, kept per stock, settings
    /// and space; a frame's masks play no part (`printLimitsProbe`).
    public func printLimits(stock: Int, settings: DevelopSettings, space: OutputSpace) async -> PrintLimits? {
        guard stocks.indices.contains(stock), let probe = Self.printLimitsProbe(settings) else { return nil }
        let key = PrintLimitsKey(stock: stock, settings: probe, space: space)
        if let made = renderersLock.withLock({ printLimitsMade[key] }) { return made }
        let limits = await Task.detached(priority: .userInitiated) { [self] () -> PrintLimits? in
            guard let renderer = try? renderer(stock),
                  let white = try? probeCodes(Self.printWhiteLight, renderer: renderer, settings: probe, space: space),
                  let black = try? probeCodes(0, renderer: renderer, settings: probe, space: space) else { return nil }
            return PrintLimits(white: white, black: black)
        }.value
        if let limits {
            renderersLock.withLock {
                if printLimitsMade.count >= 32 { printLimitsMade.removeAll() }
                printLimitsMade[key] = limits
            }
        }
        return limits
    }

    /// What `printLimits` renders and keys on: `settings` without grain, halation or sharpening, which a uniform frame does not need,
    /// and without masks. A mask moves a frame's light where its coverage lies, which a uniform frame has no place for, and the print's
    /// own white and black are the stock's and the panel's, whatever the masks do. With them the probe would render through them, asking
    /// for a field of its own at its square aspect (a slice of 32 MiB) and a probe for every move of a mask's slider, since the settings
    /// key the probe. `nil` for settings that cannot be made without their masks.
    static func printLimitsProbe(_ settings: DevelopSettings) -> DevelopSettings? {
        var probe = settings
        probe.grain = 0
        probe.grainSeed = 0
        probe.halation = false
        probe.sharpen = false
        let manual = settings.manual
        if !manual.adjustments.masks.isEmpty || !manual.adjustments.lens.isDefault {
            // The removals go too: `settingLens` keeps them, and a probe that renders no frame must not be made again for each.
            guard let unmasked = try? ManualRenderSettings(adjustments: manual.adjustments.settingMasks(.empty).settingLens(.default).withoutRemovals,
                                                           referenceStops: manual.referenceStops, version: manual.version)
            else { return nil }
            probe.manual = unmasked
        }
        return probe
    }

    /// Sixteen stops over a metered mid-gray, past every stock's negative even at Exposure −5 EV.
    static let printWhiteLight: Float = 0.18 * 65536

    /// The display codes of a uniform frame of scene-linear `light` through the film.
    private func probeCodes(_ light: Float, renderer: FilmRenderer, settings: DevelopSettings,
                            space: OutputSpace) throws -> SIMD3<UInt8> {
        let side = 8
        let texture = try gpu.makeTexture(width: side, height: side)
        var values = [Float16](repeating: 1, count: side * side * 4)
        for i in 0..<(side * side) { for c in 0..<3 { values[i * 4 + c] = Float16(light) } }
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: side * 8)
        }
        let frame = LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "print-limits", scale: 1)
        let rendered = try renderer.render(frame, settings: settings)
        let image = try withExtendedLifetime(rendered) { try displayImage(rendered.image.texture, space: space, maxPixelSize: side) }
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space.colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let pixel = context.data?.assumingMemoryBound(to: UInt8.self),
              let centre = image.cropping(to: CGRect(x: side / 2, y: side / 2, width: 1, height: 1))
        else { throw EncodeError.imageCreation }
        context.setBlendMode(.copy)
        context.draw(centre, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return SIMD3(pixel[0], pixel[1], pixel[2])
    }

    /// Frees what is quick to make again, so a develop's full-size textures have room: the
    /// renders, the frame view's decodes, and the sheet's decodes too when they are on disk,
    /// since reading one back costs 0.7 ms (up to 512 MB on a long roll), the textures they
    /// leave in the pool, up to 64 MB, the masks' coverage, up to 179 MB, and the stocks' film passes,
    /// 74 MB for the six, with their masks' tables. Without a
    /// disk cache the sheet's decodes stay, as each would cost a decode. The shared Core Image
    /// context is replaced, since it keeps a frame view decode's 0.3 to 0.84 GB of surfaces for 1 to 2 s
    /// and gives them back only with the context (measured; `GPU.renewContext`).
    public func trimForDevelop() {
        note("trim +")
        defer { note("trim -") }
        refineQueue.cancelAllOperations()
        lock.withLock {
            decodeGeneration &+= 1
            for operation in frameDecodes.values { operation.cancel() }
            for operation in sheetDecodes.values { operation.cancel() }
            frameDecodes.removeAll()
            sheetDecodes.removeAll()
            renderedImages.removeAll()
            if diskCache != nil { linear.removeAllObjects() }
            frameLinear.removeAll()
            maskInput = nil
            refinedOverlays.removeAll()
        }
        decoder.trim()
        gpu.texturePool.trim()
        // Masks' coverage, up to two arrays of 89 MB, baked again in a millisecond or two; their tables go with the renderers. Smart
        // masks' coefficients, up to 32 MB, built again in under 10 ms a seed.
        gpu.maskFields.removeAll()
        gpu.maskRefiner.removeAll()
        // Presence's analyses, up to 168 MiB, made again at the next render that needs them.
        gpu.presenceAnalyses.removeAll()
        // The removals' patches on the GPU, up to 64 MB, uploaded again from the store when a frame is next staged.
        lensStage.removeKeptPatches()
        gpu.renewContext()
        renderersLock.withLock { renderers.removeAll() }
        decodeTurns.trimmed()
    }

    /// Empties every cache, for a new roll, and rejects work begun for the previous roll.
    public func removeAll() {
        refineQueue.cancelAllOperations()
        lensLock.withLock { lenses.removeAll() }
        lock.withLock {
            decodeGeneration &+= 1
            for operation in frameDecodes.values { operation.cancel() }
            for operation in sheetDecodes.values { operation.cancel() }
            analyses.removeAll()
            descriptors.removeAll()
            linear.removeAllObjects()
            renderedImages.removeAll()
            frameLinear.removeAll()
            maskInput = nil
            refinedOverlays.removeAll()
            frameDecodes.removeAll()
            sheetDecodes.removeAll()
        }
        // The previous roll's masks: another roll's frames never share a field, nor a refinement, nor an analysis.
        gpu.maskFields.removeAll()
        gpu.maskRefiner.removeAll()
        gpu.presenceAnalyses.removeAll()
        renderersLock.withLock { renderers.values.forEach { $0.clearToneBase() } }
        // Nor do they name its patches.
        lensStage.removeKeptPatches()
    }

    /// What a sheet decode came to.
    private enum SheetDecode {
        case decoded(LinearEntry)
        /// The raw at this version, `nil` when the file is gone, could not be decoded or its header read.
        case failed(SourceStamp?)
        case stopped
    }

    /// The sheet's decode of `frame` for a picture: the frame view's decode scaled down when
    /// `frameViewSide` names one at least as large, so the two share it, else the sheet's own.
    private func linearPreview(_ frame: Frame, lens: LensSettings, priority: Operation.QueuePriority, frameViewSide: Int?,
                               generation: UInt64) async -> LinearEntry? {
        guard isCurrentDecode(generation) else { return nil }
        if let entry = linear.object(forKey: cachedKey(frame, lens: lens) as NSString) { return entry }
        // A frame view smaller than the sheet's decode would hand the sheet a smaller one.
        if let frameViewSide, frameViewSide >= Self.previewLongSide {
            guard let large = await frameDecode(frame, lens: lens, longSide: frameViewSide, priority: priority, generation: generation),
                  !Task.isCancelled, isCurrentDecode(generation)
            else { return nil }
            return await QueuedWork.runStoppable(on: renderQueue, priority: priority) { [self] stopped in
                guard !stopped(), isCurrentDecode(generation) else { return nil }
                if let entry = linear.object(forKey: keepKey(frame, madeFrom: large) as NSString) { return entry }
                decodeTurns.beginRender()
                defer { decodeTurns.endRender() }
                return try? storePreview(downscaled(large.frame, longSide: Self.previewLongSide), lens: nil, of: frame,
                                         source: large.source, info: large.info, generation: generation, stopped: stopped)
            }
        }
        guard case .decoded(let entry) = await sheetDecode(frame, lens: lens, priority: priority, generation: generation, measuring: false)
        else { return nil }
        return entry
    }

    /// The sheet's own decode of `frame`: kept in memory, read from disk, or decoded at
    /// `previewLongSide`, and measured. For a picture (not `measuring`), a frame view's decode of the
    /// frame, queued or kept, is scaled down instead when it is large enough; a measurement never
    /// takes one, nor waits for it.
    private func sheetDecode(_ frame: Frame, lens: LensSettings, priority: Operation.QueuePriority, generation: UInt64,
                             measuring: Bool) async -> SheetDecode {
        guard isCurrentDecode(generation) else { return .stopped }
        let path = frame.url.path
        if let entry = linear.object(forKey: cachedKey(frame, lens: lens) as NSString), !(measuring && entry.scaled) { return .decoded(entry) }
        return await QueuedWork.runStoppable(on: decodeQueue, priority: priority, prepare: { operation in
            // The frame view may be decoding this frame already, or another request for the
            // sheet; a picture waits for it rather than run a second decode beside it, which would
            // slow both. A measurement waits only for the sheet's.
            self.lock.withLock {
                guard self.decodeGeneration == generation else { operation.cancel(); return }
                if !measuring, let pending = self.pendingFrameDecode(path, raisingTo: priority) { operation.addDependency(pending) }
                if let pending = self.sheetDecodes[path], !pending.isFinished {
                    if !pending.isExecuting, pending.queuePriority.rawValue < priority.rawValue { pending.queuePriority = priority }
                    operation.addDependency(pending)
                }
                self.sheetDecodes[path] = operation
                if self.sheetDecodes.count > 256 { self.sheetDecodes = self.sheetDecodes.filter { !$0.value.isFinished } }
            }
        }) { [self] stopped -> SheetDecode in
            guard !stopped(), isCurrentDecode(generation) else { return .stopped }
            // Another request may have decoded it while this one waited.
            let choice = decoderChoices.choice(for: frame.url)
            let source = SourceStamp.of(frame.url)
            if let entry = linear.object(forKey: Self.key(frame, source, choice, self.lens(frame, source, lens)) as NSString), !(measuring && entry.scaled) {
                return .decoded(entry)
            }
            if !measuring, let large = frameEntry(Self.key(frame, source, choice, self.lens(frame, source, lens))), large.serves(Self.previewLongSide) {
                decodeTurns.beginRender()
                let scaled = try? downscaled(large.frame, longSide: Self.previewLongSide)
                decodeTurns.endRender()
                if let scaled {
                    return storePreview(scaled, lens: nil, of: frame, source: large.source, info: large.info,
                                        generation: generation, stopped: stopped).map { .decoded($0) } ?? .stopped
                }
            }
            // The disk cache is keyed by the raw's whole content, read at the version this decode is of;
            // a request given up on stops the read between megabytes, and decodes nothing.
            var content: SourceDigests.Verified?
            if diskCache != nil {
                do {
                    content = try digests.digest(of: frame.url, stopped: { stopped() || !self.isCurrentDecode(generation) })
                } catch SourceDigests.Failure.stopped {
                    return .stopped
                } catch {}
                if content?.source != source { content = nil }
            }
            let lens = self.lens(frame, source, lens)
            func diskKey(_ decoder: DecoderChoice) -> String? {
                content.map { LinearDiskCache.key(sha256: $0.sha256, longSide: Self.previewLongSide,
                                                 decoderVersion: decoder.decoderVersion, lensCorrection: false) }
            }
            guard !stopped(), isCurrentDecode(generation) else { return .stopped }
            // No raw there, or one whose header cannot be read: a failure of this version, unless it
            // changed meanwhile.
            guard let snapshot = FrameHeaders.shared.current(frame, matching: source) else {
                return SourceStamp.of(frame.url) == source ? .failed(source) : .stopped
            }
            if let key = diskKey(choice), let kept = diskCache?.load(key, pool: gpu.texturePool) {
                lock.withLock { diskHits += 1 }
                return storePreview(kept, lens: lens, of: frame, source: snapshot.source, info: snapshot.frame.info,
                                    generation: generation, stopped: stopped).map { .decoded($0) } ?? .stopped
            }
            guard !stopped() else { return .stopped }
            var options = DecodeOptions()
            options.maxLongSide = Self.previewLongSide
            options.lensCorrection = false
            guard decodeTurns.beginPreview(stopped: { stopped() || !self.isCurrentDecode(generation) }) else { return .stopped }
            note("sheet-decode \(frame.name) +")
            let result = try? decoder.decode(frame.url, options: options)
            decodeTurns.endPreview()
            note("sheet-decode \(frame.name) -")
            trimWhenIdle()
            guard let decoded = result else {
                return !stopped() && isCurrentDecode(generation) && SourceStamp.of(frame.url) == source ? .failed(source) : .stopped
            }
            lock.withLock { decodes += 1 }
            guard !stopped(), isCurrentDecode(generation) else { return .stopped }
            // A raw that changed during its decode gives a picture of neither version: shown, not kept.
            guard let source, SourceStamp.of(frame.url) == source else {
                return (try? lensStage.correct(decoded, with: lens)).map {
                    .decoded(LinearEntry($0, requested: Self.previewLongSide, source: nil, info: nil))
                } ?? .stopped
            }
            // Kept on disk under the decoder that made it, Apple's where the in-house decoder failed.
            if let key = diskKey(DecoderChoice.of(decoded)) { diskCache?.store(decoded, key: key) }
            return storePreview(decoded, lens: lens, of: frame, source: source, info: snapshot.frame.info,
                                generation: generation, stopped: stopped).map { .decoded($0) } ?? .stopped
        } ?? .stopped
    }

    /// Keeps `decoded`, the sheet's decode of `frame`'s raw at version `source`, under the decoder
    /// that made it, and measures it unless it is a frame view's decode `scaled` down, which is kept
    /// for pictures only; keeps neither for a raw that changed during its decode.
    private func storePreview(_ decoded: LinearFrame, lens: ResolvedLensCorrection?, of frame: Frame,
                              source: SourceStamp?, info: ARWFrameInfo?, generation: UInt64, stopped: () -> Bool) -> LinearEntry? {
        guard !stopped(), isCurrentDecode(generation) else { return nil }
        let scaled = lens == nil
        guard let scene = try? lens.map({ try lensStage.correct(decoded, with: $0) }) ?? decoded else { return nil }
        guard let source, let info, SourceStamp.of(frame.url) == source else {
            return LinearEntry(scene, requested: Self.previewLongSide, source: nil, info: nil, scaled: scaled)
        }
        let entry = LinearEntry(scene, requested: Self.previewLongSide, source: source, info: info, scaled: scaled)
        let key = Self.measurementKey(frame, source)
        // Measured once per version of the raw, from the first sheet decode, so every later render agrees,
        // with its descriptor from the same grid.
        if !scaled, lock.withLock({ analyses[key] == nil }) {
            let measured = ExposureAnalyzer.measure(decoded, workingSpace: gpu.workingColorSpace, info: info)
            guard SourceStamp.of(frame.url) == source else {
                return LinearEntry(scene, requested: Self.previewLongSide, source: nil, info: nil)
            }
            let stored = lock.withLock {
                guard !stopped(), decodeGeneration == generation else { return false }
                if analyses[key] == nil {
                    analyses[key] = measured.analysis
                    descriptors[key] = measured.descriptor
                }
                return true
            }
            guard stored else { return nil }
        }
        if !scaled, scene.image !== decoded.image, lock.withLock({ descriptors[key] == nil }) {
            let described = Self.describe(decoded, info: info)
            lock.withLock { if descriptors[key] == nil { descriptors[key] = described } }
        }
        // While a develop runs, a decode on disk is read again when wanted rather than kept.
        let keeps = !(diskCache != nil && decodeTurns.isDevelopRunning)
        return lock.withLock {
            guard !stopped(), decodeGeneration == generation else { return nil }
            if keeps {
                linear.setObject(entry, forKey: keepKey(frame, madeFrom: entry) as NSString, cost: decoded.width * decoded.height * 8)
            }
            return entry
        }
    }

    /// `frame` area-resized so its longer side is `longSide`, still scene-linear, as a long-edge
    /// develop is resized. A frame already that small comes back as it is.
    private func downscaled(_ frame: LinearFrame, longSide: Int) throws -> LinearFrame {
        let scale = Double(longSide) / Double(max(frame.width, frame.height))
        guard scale < 1 else { return frame }
        let texture = try withExtendedLifetime(frame) { try resize.resized(frame.texture, scale: scale) }
        return LinearFrame(image: texture, decoderVersion: frame.decoderVersion, scale: frame.scale * Float(scale),
                           pins: frame.pins, readback: frame.readback, picture: try frame.maskPicture, lens: frame.lens)
    }

    private func render(_ frame: LinearFrame, with renderer: FilmRenderer, settings: DevelopSettings,
                        space: OutputSpace, maxPixelSize: Int) throws -> CGImage {
        let began = CACurrentMediaTime()
        let rendered = try renderer.render(frame, settings: settings, reuseToneBase: true)
        let image = try withExtendedLifetime(rendered) { try displayImage(rendered.image.texture, space: space, maxPixelSize: maxPixelSize) }
        let ended = CACurrentMediaTime()
        lock.withLock {
            renderTimes.append((ended, rendered.gpuSeconds, ended - began))
            if renderTimes.count > 256 { renderTimes.removeFirst(renderTimes.count - 256) }
        }
        return image
    }

    /// The GPU time and the whole time of the renders that ended since `since` (`CACurrentMediaTime`), oldest first.
    public func renderTimes(since: CFTimeInterval) -> [(gpu: Double, whole: Double)] {
        lock.withLock { renderTimes.filter { $0.ended >= since }.map { ($0.gpu, $0.whole) } }
    }

    /// Linear light in the working primaries as an 8-bit picture in `space`, its longer side at
    /// most `maxPixelSize`, area-resized in linear light as a long-edge develop is. Light above
    /// display white clips, and so do colours `space` cannot hold, as a develop into it clips them.
    func displayImage(_ texture: MTLTexture, space: OutputSpace, maxPixelSize: Int) throws -> CGImage {
        let scale = Double(maxPixelSize) / Double(max(texture.width, texture.height))
        let resized = scale < 1 ? try resize.resized(texture, scale: scale) : nil
        guard let image = CIImage(mtlTexture: resized?.texture ?? texture, options: [.colorSpace: gpu.workingColorSpace])
        else { throw EncodeError.imageCreation }
        // While a develop runs, a context of its own, whose surfaces go with it.
        let context = decodeTurns.isDevelopRunning ? gpu.makeContext() : gpu.ciContext
        let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space.colorSpace,
                                            deferred: false)
        withExtendedLifetime(resized) {}
        guard let cgImage else { throw EncodeError.imageCreation }
        return cgImage
    }
}

// MARK: Smart masks' input

extension FilmPreviews {
    /// What the model is given to take an object out of `frame` (docs/remove-plan.md, section 4.3): the full-size decode before the
    /// lens warp, with `lens`'s removals that are on composited, cut to `box`, its top row first. `lens` holds the removals made
    /// before the one being made or made again, so a removal never sees a later one; its lens values play no part, since nothing
    /// is warped.
    ///
    /// Cut from the decode the frame view holds of the whole raw when it has one, as at 100 %, and otherwise from a decode of its
    /// own in the develop's tiles, which nothing keeps: 262 MB at 33 MP for as long as the cut takes, while a develop runs after
    /// its frames (`DecodeTurns`). Only the crop is copied, so the frame view's decode stays as it was. Throws
    /// `CancellationError` when the task was cancelled or a roll reset or a develop's trim let the work go, the decoder's error
    /// when the raw cannot be decoded, and `RemovalError.invalid` for a box outside the frame or a raw that changed meanwhile.
    public func removalInput(_ frame: Frame, lens: LensSettings, box: RemovalPatch.Box) async throws -> RemovalPipeline.Crop {
        try Task.checkCancellation()
        let generation = lock.withLock { decodeGeneration }
        let path = frame.url.path, removals = lens.removals
        // The decode before the stage is one whatever the lens settings, so the frame view's is found by its file, not its key.
        let held = lock.withLock { frameLinear.last(where: { $0.key.hasPrefix(path + "|") })?.entry }.flatMap { entry in
            entry.source != nil && entry.input.map { $0.lens == nil && LensStage.isFullSize($0) } == true ? entry : nil
        }
        let made: Result<RemovalPipeline.Crop, any Error>? = await QueuedWork.runStoppable(on: held == nil ? decodeQueue : renderQueue,
                                                                                         priority: .high) { [self] stopped in
            func halted() -> Bool { stopped() || !isCurrentDecode(generation) }
            guard !halted() else { return nil }
            let decoded: LinearFrame, source: SourceStamp
            if let held, let input = held.input, let stamp = held.source {
                (decoded, source) = (input, stamp)
            } else {
                guard let snapshot = FrameHeaders.shared.current(frame) else { return .failure(RemovalError.invalid("the raw cannot be read")) }
                note("removal-input-turn \(frame.name) +")
                guard decodeTurns.beginPreview(stopped: halted) else {
                    note("removal-input-turn \(frame.name) -")
                    return nil
                }
                note("removal-input-turn \(frame.name) -")
                note("removal-input-decode \(frame.name) +")
                // The develop's own decode, in its tiles, since its pixels are the ones the patch is laid into.
                var options = DecodeOptions()
                options.tileSize = RollDeveloper.decodeTile
                options.learnedTileSize = RollDeveloper.learnedDecodeTile
                options.lensCorrection = false
                let result = Result { try decoder.decode(frame.url, options: options) }
                decodeTurns.endPreview()
                note("removal-input-decode \(frame.name) -")
                trimWhenIdle()
                switch result {
                case .failure(let error): return .failure(error)
                case .success(let whole): (decoded, source) = (whole, snapshot.source)
                }
            }
            guard !halted() else { return nil }
            note("removal-input \(frame.name) +")
            decodeTurns.beginRender()
            let crop = Result {
                try RemovalPipeline.Crop(box: box, rgb: lensStage.removalInput(decoded, removals: removals, box: box),
                                         decoder: decoded.decoderVersion)
            }
            decodeTurns.endRender()
            note("removal-input \(frame.name) -")
            // A raw that changed during its decode gives pixels of neither version: no removal is made from them.
            guard SourceStamp.of(frame.url) == source else { return .failure(RemovalError.invalid("the raw changed while it was read")) }
            return crop
        }
        guard let made else { throw CancellationError() }
        return try made.get()
    }

    /// The picture smart masks are made from for `frame` (`MaskInputPicture`, docs/masking-plan.md section 3): made from the decode the
    /// frame view holds of it when that is at least `MaskInputPicture.longSide` long or the whole raw, and otherwise from a decode of
    /// its own at that size, which nothing keeps, so the frame view's decode stays as it was. The last one made is kept for the next
    /// mask on the frame (17.5 MB at 2560 × 1707, counted by the develop's gate and let go by `trimForDevelop`). From a held decode
    /// it costs the print's pass, the resize and the read back (S1b: 3 to 5 ms of GPU and 2 ms); a decode of its own adds the
    /// decode, while a develop runs after its frames (`DecodeTurns`). `nil` when the raw cannot be decoded, changed meanwhile, or the
    /// task was cancelled.
    public func maskInputPicture(_ frame: Frame, lens: LensSettings, priority: Operation.QueuePriority = .high) async -> MaskInputPicture? {
        guard !Task.isCancelled else { return nil }
        let generation = lock.withLock { decodeGeneration }
        let decodeKey = cachedKey(frame, lens: lens)
        if let kept = lock.withLock({ maskInput }), kept.key == decodeKey { return kept.picture }
        let held = peekFrameEntry(decodeKey).flatMap { entry in
            MaskInputPicture.canBeMade(fromDecodeLongSide: entry.longSide, scale: entry.frame.scale) && entry.source != nil ? entry : nil
        }
        return await QueuedWork.runStoppable(on: held == nil ? decodeQueue : renderQueue, priority: priority) { [self] stopped in
            func halted() -> Bool { stopped() || !isCurrentDecode(generation) }
            guard !halted() else { return nil }
            let entry: LinearEntry
            if let held {
                entry = held
            } else {
                guard let snapshot = FrameHeaders.shared.current(frame) else { return nil }
                note("mask-input-turn \(frame.name) +")
                guard decodeTurns.beginPreview(stopped: halted) else {
                    note("mask-input-turn \(frame.name) -")
                    return nil
                }
                note("mask-input-turn \(frame.name) -")
                note("mask-input-decode \(frame.name) +")
                let lens = self.lens(frame, snapshot.source, lens)
                var options = Self.frameDecodeOptions(longSide: MaskInputPicture.longSide)
                options.lensCorrection = false
                let result = try? lensStage.correct(decoder.decode(frame.url, options: options), with: lens)
                decodeTurns.endPreview()
                note("mask-input-decode \(frame.name) -")
                trimWhenIdle()
                // A raw that changed during its decode gives a picture of neither version: no mask is made from it.
                guard let result, !halted(), SourceStamp.of(frame.url) == snapshot.source else { return nil }
                entry = LinearEntry(result, requested: MaskInputPicture.longSide, source: snapshot.source, info: nil)
            }
            note("mask-input \(frame.name) +")
            decodeTurns.beginRender()
            let picture = try? maskInputLock.withLock { () throws -> MaskInputPicture in
                if maskInputMaker == nil { maskInputMaker = try MaskInputPictureMaker(gpu: gpu) }
                return try maskInputMaker!.make(from: entry.frame)
            }
            decodeTurns.endRender()
            note("mask-input \(frame.name) -")
            guard let picture, !halted(), let source = entry.source, SourceStamp.of(frame.url) == source else { return nil }
            lock.withLock {
                guard decodeGeneration == generation else { return }
                maskInput = (keepKey(frame, madeFrom: entry), picture)
            }
            return picture
        }
    }
}

/// A print's own white and black in the frame view's 8-bit codes (`FilmPreviews.printLimits`).
public struct PrintLimits: Sendable, Equatable {
    public var white: SIMD3<UInt8>
    public var black: SIMD3<UInt8>

    public init(white: SIMD3<UInt8>, black: SIMD3<UInt8>) {
        self.white = white
        self.black = black
    }

    /// The display's own ends, for a picture without a print.
    public static let display = PrintLimits(white: SIMD3(repeating: 255), black: .zero)
}

private struct PrintLimitsKey: Hashable {
    var stock: Int
    var settings: DevelopSettings
    var space: OutputSpace
}

// MARK: The brush

extension FilmPreviews {
    /// What a brush painted on `frame` is laid over: the picture its canvas covers, the full-size upright picture every render of the
    /// frame asks its coverage by, and the `MaskFrame` its strokes record. From the frame view's decode held for the raw as it is now,
    /// so the canvas a stroke paints is the one the print reads; `nil` until one is held.
    public func brushPicture(for frame: Frame, lens: LensSettings) -> (picture: MaskSpace, frame: MaskFrame)? {
        guard let entry = peekFrameEntry(cachedKey(frame, lens: lens)), entry.source != nil, let picture = try? entry.frame.maskPicture,
              let made = try? Self.maskFrame(of: frame, pictureWidth: picture.width, pictureHeight: picture.height,
                                             decoderVersion: entry.frame.decoderVersion,
                                             lensCorrection: entry.frame.pins?.lensCorrection ?? true, geometry: entry.frame.lens?.geometry)
        else { return nil }
        return (picture, made)
    }

    /// The frame a mask is drawn or found on, as its components record it (`MaskFrame`): `frame`'s orientation, the decode's
    /// full-size upright picture, the decoder that made it and whether it corrected the lens. The brush (`brushPicture`) and smart
    /// masks (`BundledSmartMasks`, from the input picture's `source`) both take it from here, so a selection painted instead and a
    /// brush beside it on one frame record the same frame.
    public static func maskFrame(of frame: Frame, pictureWidth: Int, pictureHeight: Int, decoderVersion: String,
                                 lensCorrection: Bool, geometry: LensGeometry?) throws -> MaskFrame {
        try MaskFrame(orientation: Int(frame.info.orientation.rawValue), width: pictureWidth, height: pictureHeight,
                      decoder: DecoderChoice.of(decoderVersion: decoderVersion), lensCorrection: lensCorrection, geometry: geometry)
    }

    /// A stroke on `mask`'s brush `component` on `frame`, on this previews' own GPU: its canvas registers with the field cache the frame
    /// view's renders read, so the print follows the stroke without laying it (`BrushStrokeSession`). A mask holding a smart selection,
    /// as Sky with a Subtract brush, is refined on the frame view's held decode with the library's seeds, as its print is, so the
    /// stroke's overlay shows what the print will (D); without that decode the session refuses at the press. A Follow edges stroke reads
    /// that decode too, for its colour test and the refinement it measures with as it ends (L), and a brush with Follow edges strokes reads
    /// their measured shapes through the same seeds, whether the mask is on or off (`BrushStrokeSession.needsRefinement`). The UI's
    /// thread only.
    public func brushStrokeSession(frame: Frame, lens: LensSettings, picture: MaskSpace, mask: Mask, component: Int, settings: BrushSettings,
                                   constraint: StrokeSampler.Constraint) throws -> BrushStrokeSession {
        var refinement: MaskRefinementSession?
        if BrushStrokeSession.needsRefinement(mask: mask, settings: settings), let entry = peekFrameEntry(cachedKey(frame, lens: lens)), entry.source != nil {
            refinement = gpu.maskRefiner.session(for: entry.frame, picture: picture, seeds: maskSeeds)
        }
        return try BrushStrokeSession(gpu: gpu, picture: picture, mask: mask, component: component, settings: settings,
                                      constraint: constraint, refinement: refinement)
    }

    /// `selection`'s refined coverage on `frame`, as the print reads it (D: the field the bake reads, refined on the frame view's held
    /// decode with the library's seeds, blurred by its Feather), sampled bilinearly at each pixel's centre of a `width` by `height` picture, 0 to 255, top row
    /// first, Background not yet turned over (the caller's composition does that, as the bake's does). The refiner builds the field
    /// once a seed and decode and keeps it; the few sizes the overlay asks for are kept here too, so a refresh, a hover back or a
    /// gradient moving beside the selection reads no GPU. `nil` while no decode of `frame` is held or the seed cannot be read: the
    /// overlay then shows the seed as stored. Any thread.
    public func refinedSelection(_ selection: SmartSelection, on frame: Frame, lens: LensSettings, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0, let raster = selection.raster, let entry = peekFrameEntry(cachedKey(frame, lens: lens)), entry.source != nil,
              let picture = try? entry.frame.maskPicture else { return nil }
        let key = RefinedOverlayKey(guide: entry.frame.maskGuide, raster: raster.id, kind: selection.kind, feather: selection.feather,
                                    edge: selection.edge, width: width, height: height)
        if let kept = lock.withLock({ () -> [UInt8]? in
            guard let index = refinedOverlays.lastIndex(where: { $0.key == key }) else { return nil }
            let found = refinedOverlays.remove(at: index)
            refinedOverlays.append(found)
            refinedOverlayCounts.kept += 1
            return found.values
        }) { return kept }
        let session = gpu.maskRefiner.session(for: entry.frame, picture: picture, seeds: maskSeeds)
        guard let field = try? withExtendedLifetime(entry.frame, { try session.field(for: selection) }) else { return nil }
        let values = Self.sampled(field, width: width, height: height)
        lock.withLock {
            refinedOverlayCounts.made += 1
            refinedOverlays.removeAll { $0.key == key }
            refinedOverlays.append((key, values))
            if refinedOverlays.count > Self.refinedOverlaysKept { refinedOverlays.removeFirst(refinedOverlays.count - Self.refinedOverlaysKept) }
        }
        return values
    }

    /// `mask`'s coverage over `fractions` of the picture on `frame`, as the print reads it on the decode the film `pixels` long was made from
    /// (`GPU.regionCoverage`: the same kernel code the render runs, tier 2 included), for the overlay's sharp raster at a settled zoom; its
    /// pixels are that decode's own texels, up to `MaskRegion.maximumLongSide`. A film outlives its decode, so a film taken from the render cache
    /// can be up with a smaller decode held: this then waits for that film's decode, which a next render there needs anyway, rather than read
    /// another picture's edge. `nil` when it cannot be made or `fractions` covers nothing.
    public func regionCoverage(of mask: Mask, version: String, on frame: Frame, lens: LensSettings, pixels: Int, fractions: CGRect) async -> RegionCoverage? {
        let side = Self.frameDecodeSide(forPixels: pixels)
        var held = peekFrameEntry(cachedKey(frame, lens: lens))
        if held?.fits(side) != true {
            let generation = lock.withLock { decodeGeneration }
            held = await frameDecode(frame, lens: lens, longSide: side, priority: .high, generation: generation)
        }
        guard let entry = held, entry.fits(side), entry.source != nil,
              let region = MaskRegion(frameWidth: entry.frame.width, frameHeight: entry.frame.height, left: fractions.minX, top: fractions.minY,
                                      right: fractions.maxX, bottom: fractions.maxY),
              let values = regionCoverageValues(of: mask, version: version, on: entry.frame, region: region) else { return nil }
        let placed = region.fractions(frameWidth: entry.frame.width, frameHeight: entry.frame.height)
        return RegionCoverage(values: values, width: region.width, height: region.height,
                              fractions: CGRect(x: placed.left, y: placed.top, width: placed.width, height: placed.height))
    }

    private func regionCoverageValues(of mask: Mask, version: String, on frame: LinearFrame, region: MaskRegion) -> [UInt8]? {
        do {
            let values = try gpu.regionCoverage(of: mask, version: version, on: frame, region: region, seeds: maskSeeds)
            lock.withLock { regionCoverageFailure = nil }
            return values
        } catch {
            lock.withLock { regionCoverageFailure = "\(error)" }
            return nil
        }
    }

    /// A refined field (`r16Float`, the picture's bottom row first, as every slice) read back and sampled bilinearly at each pixel's
    /// centre of `width` by `height`, top row first, in 8 bits.
    static func sampled(_ field: MTLTexture, width: Int, height: Int) -> [UInt8] {
        let fw = field.width, fh = field.height
        var halves = [Float16](repeating: 0, count: fw * fh)
        halves.withUnsafeMutableBytes {
            field.getBytes($0.baseAddress!, bytesPerRow: fw * 2, from: MTLRegionMake2D(0, 0, fw, fh), mipmapLevel: 0)
        }
        var out = [UInt8](repeating: 0, count: width * height)
        halves.withUnsafeBufferPointer { plane in
            for y in 0..<height {
                // The picture's row y is the field's row fh - 1 - y.
                let fy = min(max(Float(fh) - (Float(y) + 0.5) / Float(height) * Float(fh) - 0.5, 0), Float(fh - 1))
                let y0 = Int(fy), y1 = min(y0 + 1, fh - 1), ty = fy - Float(y0)
                for x in 0..<width {
                    let fx = min(max((Float(x) + 0.5) / Float(width) * Float(fw) - 0.5, 0), Float(fw - 1))
                    let x0 = Int(fx), x1 = min(x0 + 1, fw - 1), tx = fx - Float(x0)
                    let a = Float(plane[y0 * fw + x0]) * (1 - tx) + Float(plane[y0 * fw + x1]) * tx
                    let b = Float(plane[y1 * fw + x0]) * (1 - tx) + Float(plane[y1 * fw + x1]) * tx
                    out[y * width + x] = UInt8(min(255, max(0, (a * (1 - ty) + b * ty) * 255 + 0.5)))
                }
            }
        }
        return out
    }

    /// Compiles the brush's kernels off the caller's thread, so the first press does not wait for them: an empty canvas for
    /// `picture`, which costs a clear once compiled; with `followEdges`, Follow edges' library and the refiner's kernels too, which its
    /// strokes need at their press and their release.
    public func prepareBrush(picture: MaskSpace, followEdges: Bool = false) async {
        let cache = gpu.maskFields, refiner = gpu.maskRefiner
        await Task.detached(priority: .userInitiated) {
            _ = try? cache.canvas(for: BrushCanvasKey(size: MaskFieldSize(picture: picture), version: MaskSet.currentVersion, strokes: []))
            if followEdges {
                try? cache.prepareFollowEdges()
                try? refiner.prepare()
            }
        }.value
    }
}

/// A mask's coverage over a part of a picture (`FilmPreviews.regionCoverage`): 0 to 255, top row first, `width` by `height`, and the fractions
/// of the picture it covers, on the decode's own texels.
public struct RegionCoverage: Sendable, Equatable {
    public var values: [UInt8]
    public var width: Int
    public var height: Int
    public var fractions: CGRect

    public init(values: [UInt8], width: Int, height: Int, fractions: CGRect) {
        self.values = values
        self.width = width
        self.height = height
        self.fractions = fractions
    }
}

/// One refined selection at one of the overlay's sizes, on one decode (`FilmPreviews.refinedSelection`).
struct RefinedOverlayKey: Hashable {
    var guide: MaskGuideID
    var raster: RasterID
    var kind: SmartKind
    /// The selection's Feather: the field the overlay samples is the blurred one.
    var feather: Float
    /// The selection's edge: a raster refined as `crisp` is not the one the same pixels make as `guided`.
    var edge: SmartEdge
    var width: Int
    var height: Int
}
