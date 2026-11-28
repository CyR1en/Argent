import ArgentCore
import Foundation

/// What a develop may hold, so the app stays under the spec's 2 GB while it develops, whatever the
/// roll, the format and what the sheet holds (docs/M2-shell.md, section 10).
///
/// Two things bound it. Each format's plan caps the frames in flight, from a decode's start to the
/// file written, where its encoder is slow enough that a frame decoded ahead only waits holding a
/// full-size frame (`Plan`). And a frame is let in only when the app's footprint now with the frame's
/// decode fits under the target, less a margin for what the decode's frames in flight add after it,
/// so a Mac with less memory, or an app holding more than the sheet usually does, develops fewer
/// frames at once; a frame with none in flight waits at most `loneWait`, so a develop never stalls. The previews'
/// decodes, which the footprint cannot show before they allocate, take turns with the frames
/// (`DecodeTurns`). The margin was set from develops that start from the idle sheet; what the app holds
/// beyond that floor raises a develop's peak one for one, so the ceiling comes down by it (`MemoryGate`).
///
/// The footprint is the kernel's, which counts memory let go only once it is gone: Metal returns a
/// texture the GPU has used 0.1 to 0.25 s after its last release (measured), so the gate waits for
/// that too. The costs are measured on the M4 for 33 MP frames and scale with the pixels
/// (`DevelopBudgetMeasureTests`); they depend on sizes and code, not on what a picture shows.
public enum DevelopBudget {
    /// The environment variable and the user default that replace the develop memory target for
    /// measuring, in megabytes. The Settings choice uses a separate key of its own in the app and
    /// sits below both of these.
    public static let overrideEnvironmentKey = "ARGENT_DEVELOP_MEMORY_MB"
    public static let overrideDefaultsKey = "ArgentDevelopMemoryMB"

    /// A choice offered in Settings for how much memory a develop may hold: the default rule, or a
    /// higher target in the footprint's megabytes (`N * 1000 << 20`, matching `specTarget`'s 2000 MiB "2 GB").
    public enum Choice: String, CaseIterable, Sendable, Equatable, Hashable {
        case `default`
        case gb3 = "3gb"
        case gb4 = "4gb"
        case gb6 = "6gb"

        /// The target in bytes for an explicit choice, or `nil` for the default rule.
        public var bytes: Int? {
            switch self {
            case .default: nil
            case .gb3: 3000 << 20
            case .gb4: 4000 << 20
            case .gb6: 6000 << 20
            }
        }

        /// The label shown in Settings.
        public var title: String {
            switch self {
            case .default: "Default"
            case .gb3: "3 GB"
            case .gb4: "4 GB"
            case .gb6: "6 GB"
            }
        }
    }

    /// The choices offered on a Mac with `physicalMemory` bytes of RAM: `.default` always, and each
    /// larger choice that is at most a quarter of physical memory (12 GB offers 3 GB; 16 GB offers 3
    /// and 4 GB; 24 GB and above offer 3, 4 and 6 GB; 8 GB offers only the default).
    public static func choices(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> [Choice] {
        let quarter = physicalMemory / 4
        return Choice.allCases.filter { choice in
            guard let bytes = choice.bytes else { return true }
            return UInt64(bytes) <= quarter
        }
    }

    /// `choice` when a Mac with `physicalMemory` bytes of RAM offers it, else `.default`.
    public static func effectiveChoice(_ choice: Choice,
                                       physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Choice {
        choices(physicalMemory: physicalMemory).contains(choice) ? choice : .default
    }

    /// Resolves the measuring overrides, the user's `choice` and the default rule into a budget in
    /// bytes, in order: `ARGENT_DEVELOP_MEMORY_MB`, `ArgentDevelopMemoryMB`, `choice` if a Mac with
    /// `physicalMemory` bytes offers it, and the default rule (`min(specTarget, physicalMemory / 8)`).
    public static func resolve(choice: Choice = .default,
                               environmentOverride: String? = nil,
                               defaultsOverride: Any? = nil,
                               physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        if let mb = environmentOverride.flatMap(Int.init), mb > 0, mb <= Int.max >> 20 { return mb << 20 }
        if let mb = positiveOverrideMB(defaultsOverride) { return mb << 20 }
        if let bytes = effectiveChoice(choice, physicalMemory: physicalMemory).bytes { return bytes }
        return min(specTarget, Int(min(UInt64(Int.max), physicalMemory / 8)))
    }

    /// The footprint a develop keeps the whole app under: the spec's 2 GB, or an eighth of the memory
    /// on a Mac with less than 16 GB, the spec's proportion ("runs beside Lightroom on 16 GB").
    /// `ARGENT_DEVELOP_MEMORY_MB` or the user default `ArgentDevelopMemoryMB` replaces it, for
    /// measuring; a user `choice` sits between those overrides and the default rule.
    public static func target(choice: Choice = .default,
                              physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              defaults: UserDefaults = .standard) -> Int {
        resolve(choice: choice,
                environmentOverride: environment[overrideEnvironmentKey],
                defaultsOverride: defaults.object(forKey: overrideDefaultsKey),
                physicalMemory: physicalMemory)
    }

    private static func positiveOverrideMB(_ value: Any?) -> Int? {
        if value is Bool { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        guard let mb = value as? Int, mb > 0, mb <= Int.max >> 20 else { return nil }
        return mb
    }

    /// The spec's "under 2 GB by default", in the footprint's megabytes.
    public static let specTarget = 2000 << 20
    /// The memory target at and above which RAW 9 develops in `largeLearnedDecodeTile`-pixel tiles
    /// instead of 1024-pixel tiles (owner's decision, 2026-11-23).
    public static let largeLearnedTileTarget = 3000 << 20
    /// RAW 9's develop tile size at `largeLearnedTileTarget` and above: 2048 pixels. On 60 lossless L
    /// frames on the M5 Pro (2026-11-22), 2048-pixel tiles raised throughput at 3000 MiB from
    /// 0.76 / 0.70 / 0.70 to 0.85 / 0.80 / 0.80 frames a second (JPEG / HEIC / 16-bit TIFF) and at
    /// 4000 MiB from 0.76 / 0.69 / 0.69 to 0.86 / 0.77 / 0.77, while losing 5 to 10 percent on HEIC
    /// and 16-bit TIFF at the 2000 MiB default.
    public static let largeLearnedDecodeTile = 2048

    /// RAW 9's develop tile size for a develop whose memory target is `bytes`: 1024 pixels below
    /// 3000 MiB, 2048 pixels at 3000 MiB or more. RAW 8 keeps `RollDeveloper.decodeTile` (768).
    public static func learnedDecodeTile(forMemoryTarget bytes: Int) -> Int {
        bytes >= largeLearnedTileTarget ? largeLearnedDecodeTile : (RollDeveloper.learnedDecodeTile ?? 1024)
    }
    /// Kept below the target when a frame is let in, for what the frames already in flight add after:
    /// their film passes' second frame and their pictures. A lower ceiling, 1750 MB, did not lower the
    /// peaks of HEIC develops and cost speed (measured, docs/M2-shell.md section 10).
    public static let margin = 150 << 20
    /// The floor the margin was set on: what the app holds besides the previews' decodes and pictures
    /// once a develop's trim is done, 216 to 220 MB from the idle sheet at the windows the budget was
    /// measured at, rounded up (decision; docs/manual-development-validation.md, "Develops started with
    /// the frame view open"). The gate lowers its ceiling by how far a develop's floor is above it.
    public static let floorReference = 250 << 20
    /// How long the previews stay quiet, no decode or render under way or ended and nothing trimmed,
    /// before the gate reads the floor: Metal gives back what the GPU used 0.1 to 0.25 s after its
    /// release, and a replaced Core Image context its surfaces 0.1 to 0.25 s after, 0.5 s once (measured).
    public static let floorQuiet: TimeInterval = 0.3
    /// The longest the gate waits for that from a develop's first frame, so browsing cannot hold the
    /// develop back; a floor read too high only makes the develop slower.
    public static let floorWaitLimit: TimeInterval = 2
    /// How long a frame's decode is counted beside the footprint after it goes in: a develop's decode
    /// shows in the footprint 0.17 to 0.42 s after it starts, 90 percent of it (measured).
    public static let pendingWindow: TimeInterval = 0.5
    /// How long a RAW 9 decode takes to show in the footprint: half its rise 0.16 to 0.37 s after it
    /// starts and nine tenths 0.52 to 1.52 s after, of a 1.65 to 1.8 s decode, where RAW 8's shows nine
    /// tenths in 0.16 to 0.27 s (measured on the M5 Pro in 1024-pixel tiles, 2026-10-19,
    /// `DevelopBudgetMeasureTests/stages`). So the gate counts a RAW 9 frame's decode beside the footprint
    /// for what of it has not shown yet, from all of it to none over this time, however its frame went in
    /// (`MemoryGate.admit`'s `showsOver`): two RAW 9 frames let in 0.14 s apart, the second weighed blind to
    /// the first, took 16-bit TIFF develops with frames opened during them to 2090 and 2114 MB
    /// (docs/manual-development-validation.md, "RAW 9 on the M5 Pro").
    public static let learnedShowsOver: TimeInterval = 1.5
    /// The longest a frame with none in flight waits for the footprint with its decode to fit: the frame
    /// before it gives its memory back 0.1 to 0.25 s after letting it go (measured).
    public static let loneWait: TimeInterval = 0.3

    /// How a develop to `format` is shaped: how many frames may be in flight at once, decoding,
    /// waiting, in the film passes or being encoded, and whether the in-house decoder keeps its
    /// buffers between decodes.
    public struct Plan: Sendable, Equatable {
        public var framesInFlight: Int
        public var keepsInHouseBuffers: Bool
    }

    /// JPEG encodes in about 60 ms, quicker than any decode, and runs as the lanes and picture slots
    /// allow. HEIC's encoder takes 90 MB more an encode, and 16-bit TIFF's picture is 250 MB, so they
    /// keep two frames in flight: 1.87 to 1.91 GB for HEIC instead of 2.00 to 2.13 at 12 to 17 percent
    /// of its speed, 1.69 to 1.85 GB for TIFF instead of 1.79 to 1.89 within the spread of its
    /// disk-bound speed (measured in the app).
    ///
    /// The in-house decoder keeps its 271 MB of buffers between decodes only on a roll it decodes
    /// whole, to JPEG or HEIC, where they save 6 to 22 ms of a 100 ms decode. Beside Apple's decodes
    /// they sat idle through Apple's 460 MB decode at the peaks of mixed rolls: letting them go took a
    /// mixed HEIC develop from 1.59 to 1.79 GB to 1.44 to 1.51 at the same speed (harness, its target
    /// lowered by the sheet's share). A TIFF develop is bound by its writes: letting them go lowered an
    /// in-house TIFF develop's peak by 0.2 GB for 6 percent of its speed (measured; docs/M2-shell.md
    /// section 10).
    public static func plan(for format: OutputSettings.Format, lanes: Int, pictures: Int, allInHouse: Bool) -> Plan {
        let keeps = allInHouse && format != .tiff16
        switch format {
        case .jpeg: return Plan(framesInFlight: lanes + pictures, keepsInHouseBuffers: keeps)
        case .heic, .tiff16: return Plan(framesInFlight: 2, keepsInHouseBuffers: keeps)
        }
    }

    /// Apple's working memory beside its frame for a decode in `tile`-pixel tiles: 387 MB at 1024,
    /// 341 at 960, 317 at 896, 275 at 832, 212 at 768 and 158 at 512 whatever the frame, since each
    /// tile is rendered with its own surfaces; about 1.4 GB for a full-size frame decoded whole.
    static func appleWorking(tile: Int?) -> Int {
        guard let tile else { return 1400 << 20 }
        let measured = [(512, 158), (768, 212), (832, 275), (896, 317), (960, 341), (1024, 387)]
        return (measured.first { tile <= $0.0 }?.1 ?? 1400) << 20
    }

    /// The in-house decoder's buffers: the mosaic, the noise reduction's pyramid and the lens
    /// correction's band, 271 MB at 33 MP.
    static func inHouseWorking(pixels: Int) -> Int { pixels * 87 / 10 }

    /// RAW 9's working memory beside its frame for a decode in `tile`-pixel tiles: 530 MB at 768, 630 at
    /// 1024, 760 at 1536 and 850 at 2048, and 1080 MB for a decode rendered whole, the larger of the lossless
    /// L and uncompressed samples' kernel peaks during the decode, less the frame, across the formats,
    /// rounded up (measured on the M5 Pro, 2026-10-19, `DevelopBudgetMeasureTests/stages`; docs/decoder.md
    /// section 18). Its network's tiles and the Neural Engine's buffers add to what RAW 8 holds.
    static func learnedWorking(tile: Int?) -> Int {
        guard let tile else { return 1080 << 20 }
        let measured = [(768, 530), (1024, 630), (1536, 760), (2048, 850)]
        return (measured.first { tile <= $0.0 }?.1 ?? 1080) << 20
    }

    /// What decoding a frame of `width` by `height` with `decoder` adds to the footprint: the frame in
    /// half floats, 250 MB at 33 MP, and the decoder's working memory, Apple's in `tile`-pixel tiles,
    /// the in-house decoder's less the `inHouseKept` bytes it kept from its last decode.
    public static func decodeCost(width: Int, height: Int, decoder: DecoderChoice, tile: Int?, inHouseKept: Int = 0) -> Int {
        let pixels = width * height
        let working: Int
        switch decoder {
        case .apple: working = appleWorking(tile: tile)
        case .raw9: working = learnedWorking(tile: tile)
        case .inHouse: working = max(0, inHouseWorking(pixels: pixels) - inHouseKept)
        }
        return pixels * 8 + working
    }

    /// What a frame's film passes add beside its decoded frame until it hands the frame back: a second
    /// frame-sized texture in half floats and the picture, 8 bits a channel or 16 for 16-bit TIFF; 394 MB
    /// at 33 MP to HEIC, 524 to 16-bit TIFF. The lens stage adds no texture: the decode becomes the film's densities.
    public static func filmPassesCost(width: Int, height: Int, format: OutputSettings.Format) -> Int {
        let pixels = width * height
        return pixels * 8 + pixels * (format == .tiff16 ? 8 : 4)
    }

    /// What a frame's masks add to its film passes, in every format: their coverage array, the slices the frame's masks take at 2048
    /// pixels on the picture's long side, eight bytes a texel and four masks a slice (21 MB for 1 to 4 masks on a 3:2 frame, 85 MB for
    /// 13 to 16, 32 MB a slice on a square one), baked into an array of its own as the frame renders and let go with its render, since a
    /// develop keeps none between frames (`RollDeveloper`); `LocalScene`'s tables, 182 KB; and the local base field, three textures of
    /// up to 1024 pixels in `rg32Float` while it is made (17 MB on a 3:2 frame), when only a mask's Highlights or Shadows asks for it;
    /// its brush canvases, 5.3 MiB each on a 3:2 frame, laid for the bake and let go after it (`MaskSlots.brushCanvasBytes`), with a
    /// Follow edges stroke's measured shape in a buffer while its canvas is laid, a byte a texel of its crop (`measuredShapeBytes`);
    /// and the smart masks' seeds, a byte a pixel each (2.9 MiB for a 2016 × 1512 matte, 16 MiB at the 4096 cap; `MaskSeeds`), which
    /// the lane loads after the decode and holds through the render. Nothing for a frame whose masks change no pixel, which renders with
    /// today's kernels and asks for no coverage, nor for masks that cannot render, which fail the frame before any of this (`MaskSlots`
    /// refuses them; their seeds are still counted). A smart mask adds its refinement on the frame's decode at its peak: the 2048 guide
    /// frame, the coefficients, the refined fields the bake reads and one build's working set, about 83 MB for Sky, Person and Subject
    /// together (`MaskRefiner.developBytes`), all of it let go with the render; a composed one taking tier 2 adds two slots to the array
    /// (`MaskSlots.composed`). `width` by `height` is the full-size picture's, either way up.
    public static func maskCost(settings: DevelopSettings, width: Int, height: Int) -> Int {
        let manual = settings.manual
        guard manual.hasEffectiveMasks else { return 0 }
        // The smart masks' seeds, a byte a pixel each, which the frame's lane holds from its decode to its render.
        let seeds = MaskSeeds.byteCount(of: MaskSeeds.needs(manual).rasters)
        guard let picture = try? MaskSpace(width: width, height: height),
              let slots = try? MaskSlots(masks: manual.adjustments.masks, picture: picture) else { return seeds }
        var cost = seeds + slots.sliceCount * slots.size.bytesPerSlice + LocalScene.Layout.count * MemoryLayout<Float>.stride
            + slots.brushCanvasBytes + slots.measuredShapeBytes + MaskRefiner.developBytes(masks: manual.adjustments.masks, picture: picture)
        let panel = manual.adjustments.highlights != 0 || manual.adjustments.shadows != 0
        if manual.needsToneBase, !panel, !settings.tone.isActive {
            let field = ToneBaseParameters.compiler2026_10_29_1.fieldSize(width: width, height: height)
            cost += 3 * field.width * field.height * 8
        }
        return cost
    }

    /// What a frame's Presence adds to its film passes, in every format: its analysis, made from the frame's decode and let go with its
    /// render, since a develop keeps none between frames (`PresenceAnalyses.developBytes`, about 181 MB at 33 MP with Texture, Clarity
    /// and Dehaze set). The stages run inside the existing passes and add no frame-sized texture, and Saturation and Vibrance read no
    /// analysis. Nothing for a frame whose Texture, Clarity and Dehaze are 0. `width` by `height` is the full-size picture's.
    public static func presenceCost(settings: DevelopSettings, width: Int, height: Int) -> Int {
        PresenceAnalyses.developBytes(settings.effectivePresence, width: width, height: height)
    }

    /// The process's footprint now, as Activity Monitor and `footprint` report it.
    public static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}

/// Lets frames into a develop: at most `maxInFlight` at once, and another only when the footprint
/// with its decode fits under `ceiling` less the floor's excess; see `DevelopBudget`. The frames take
/// turns with the previews' decodes through `turns`, a frame starting only while none of those waits or
/// runs. Safe to use from any thread.
///
/// The floor is what the app holds besides the develop and the previews' decodes and pictures, read once
/// before the first frame, when the previews have been quiet `floorQuiet` seconds (at most
/// `floorWaitLimit` after the first frame asks). The excess is how far the floor, with what the previews
/// hold now, is above `floorReference`: the frame view open at 2227 pixels held 0.1 GB more than the
/// idle sheet after the trim, and a develop's peak rose with it one for one, over the target
/// (docs/manual-development-validation.md, "Develops started with the frame view open").
///
/// A frame with none in flight is weighed too, but waits at most `loneWait`, for memory on its way back.
/// A frame's decode shows in the footprint only 0.17 to 0.42 s after it starts, so for `pendingWindow` the
/// decode of a frame let in alone, and while the floor is above the reference of every frame let in, is
/// counted beside the footprint when another frame is weighed: two frames let in together, the second
/// weighed blind to the first, took a develop with frames opened during it over the target. A decode that
/// shows gradually, RAW 9's, is counted for what of it has not shown yet however its frame went in. And while the
/// floor is above the reference, the film passes still to come of the frames in flight it was told of
/// count too: a frame let in as another's decode lets its surfaces go meets that frame's film passes.
/// A frame's masks are weighed with it and counted for the frames after it until its film passes are done, always.
final class MemoryGate: @unchecked Sendable {
    let ceiling: Int
    let maxInFlight: Int
    private let footprint: @Sendable () -> Int
    private let turns: DecodeTurns
    private let floorReference: Int
    private let floorQuiet: TimeInterval
    private let floorWaitLimit: TimeInterval
    private let created = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    /// Held by the frame that reads the floor, so the others wait for its reading.
    private let floorLock = NSLock()
    private var admissions = 0
    private var waits = 0
    /// Under `lock`: the floor once read, when and whether the previews were quiet then, and the largest
    /// excess a frame was weighed against.
    private var floor: Int?
    private var floorRead: (after: TimeInterval, quiet: Bool)?
    private var largestExcess = 0
    /// Under `lock`: when the frames let in within their windows went in, their decodes, whether each
    /// went in alone, how long each is counted and whether it shows gradually (`admit`'s `showsOver`), and
    /// how many went in alone.
    private var recent: [(at: TimeInterval, decode: Int, alone: Bool, window: TimeInterval, gradual: Bool)] = []
    private var lone = 0
    /// Under `lock`: what the film passes still to come of the frames in flight will add, by frame.
    private var filmPassesToCome: [Int: Int] = [:]
    /// Under `lock`: what the masks of the frames in flight will add when their film passes run, by frame (`DevelopBudget.maskCost`).
    private var masksToCome: [Int: Int] = [:]
    private let pendingWindow: TimeInterval
    private let loneWait: TimeInterval

    init(ceiling: Int, maxInFlight: Int, turns: DecodeTurns = DecodeTurns(),
         floorReference: Int = DevelopBudget.floorReference, floorQuiet: TimeInterval = DevelopBudget.floorQuiet,
         floorWaitLimit: TimeInterval = DevelopBudget.floorWaitLimit, pendingWindow: TimeInterval = DevelopBudget.pendingWindow,
         loneWait: TimeInterval = DevelopBudget.loneWait, footprint: @escaping @Sendable () -> Int = DevelopBudget.footprint) {
        self.ceiling = ceiling
        self.maxInFlight = max(1, maxInFlight)
        self.turns = turns
        self.floorReference = floorReference
        self.floorQuiet = floorQuiet
        self.floorWaitLimit = floorWaitLimit
        self.pendingWindow = pendingWindow
        self.loneWait = loneWait
        self.footprint = footprint
    }

    /// Waits until a frame whose decode adds `decode` bytes may start, and counts it in; `false`,
    /// counting nothing, when `stopped` says so first. The footprint is read again every 20 ms, since
    /// memory let go comes back without a signal. `filmPasses` is what the frame's film passes will add
    /// (`DevelopBudget.filmPassesCost`), counted beside the footprint for the frames weighed after it,
    /// while the floor is above the reference, until `filmPassesDone(frame:)`. With `showsOver`, the frame's
    /// decode shows in the footprint gradually over that time, as RAW 9's does
    /// (`DevelopBudget.learnedShowsOver`), and is counted beside it for what of it has not shown yet, from all
    /// of it to none over that time, whether its frame went in alone or not. `masks` is what the frame's masks will add when its film
    /// passes run (`DevelopBudget.maskCost`): weighed with it, and counted beside the footprint for every frame weighed after it until
    /// `filmPassesDone(frame:)`, in every format and whatever the floor, since the margin was set on frames without them.
    func admit(decode: Int, filmPasses: Int = 0, masks: Int = 0, frame: Int? = nil, showsOver: TimeInterval? = nil,
               stopped: () -> Bool) -> Bool {
        guard let floor = readFloor(stopped: stopped) else { return false }
        let (ceiling, maxInFlight, footprint, turns, reference) = (ceiling, maxInFlight, footprint, turns, floorReference)
        var aloneSince: TimeInterval?
        var alone = false
        guard let waited = turns.admitFrame(fits: { inFlight in
            let now = ProcessInfo.processInfo.systemUptime
            let excess = max(0, floor + turns.previewsHeldNow() - reference)
            lock.withLock { largestExcess = max(largestExcess, excess) }
            alone = inFlight == 0
            let fits: Bool
            if alone {
                // Weighed too, but it waits only for memory on its way back, so a develop never stalls.
                let since = aloneSince ?? now
                aloneSince = since
                fits = now - since >= loneWait || footprint() + decode + masks <= ceiling - excess
            } else {
                aloneSince = nil
                let toCome = lock.withLock {
                    (excess > 0 ? filmPassesToCome.values.reduce(0, +) : 0) + masksToCome.values.reduce(0, +)
                }
                fits = inFlight < maxInFlight
                    && footprint() + pending(at: now, everyFrame: excess > 0) + toCome + decode + masks <= ceiling - excess
            }
            // Counted under the turns' lock, before another frame can be weighed beside it.
            if fits {
                lock.withLock {
                    recent.append((now, decode, alone, showsOver ?? pendingWindow, showsOver != nil))
                    if let frame, filmPasses > 0 { filmPassesToCome[frame] = filmPasses }
                    if let frame, masks > 0 { masksToCome[frame] = masks }
                }
            }
            return fits
        }, stopped: stopped) else { return false }
        lock.withLock {
            admissions += 1
            if waited { waits += 1 }
            if alone { lone += 1 }
        }
        return true
    }

    /// The decodes the footprint may not show yet: those of the frames let in alone within
    /// `pendingWindow`, and with `everyFrame` those of the frames let in beside others too; and of a decode
    /// that shows gradually, what has not shown yet, however its frame went in. Counting every frame cost 2
    /// to 11 percent of the speed (measured), so the gate does so only while the floor is above the
    /// reference, where the margin was not set.
    private func pending(at now: TimeInterval, everyFrame: Bool) -> Int {
        lock.withLock {
            recent.removeAll { now - $0.at >= $0.window }
            return recent.reduce(0) { total, entry in
                if entry.gradual { return total + Int(Double(entry.decode) * (1 - (now - entry.at) / entry.window)) }
                return entry.alone || everyFrame ? total + entry.decode : total
            }
        }
    }

    /// The floor, read by the first frame to ask once the previews are quiet; `nil` when `stopped` says
    /// so before it is read.
    private func readFloor(stopped: () -> Bool) -> Int? {
        floorLock.lock()
        defer { floorLock.unlock() }
        if let floor = lock.withLock({ floor }) { return floor }
        guard let quiet = turns.waitForQuiet(quiet: floorQuiet, atMost: floorWaitLimit, stopped: stopped) else { return nil }
        let read = max(0, footprint() - turns.previewsHeldNow())
        lock.withLock {
            floor = read
            floorRead = (ProcessInfo.processInfo.systemUptime - created, quiet)
        }
        return read
    }

    /// `frame`'s film passes are done: what they add shows in the footprint now, and its masks' coverage has gone with them.
    func filmPassesDone(frame: Int) {
        lock.withLock {
            _ = filmPassesToCome.removeValue(forKey: frame)
            _ = masksToCome.removeValue(forKey: frame)
        }
    }

    /// What the masks of the frames in flight will still add, for the tests.
    var masksStillToCome: Int { lock.withLock { masksToCome.values.reduce(0, +) } }

    /// A frame is written, or failed.
    func leave(frame: Int? = nil) {
        if let frame { filmPassesDone(frame: frame) }
        turns.frameLeft()
    }

    /// Frames let in, and how many of them waited first, for measurements.
    var counts: (admitted: Int, waited: Int) { lock.withLock { (admissions, waits) } }

    /// Frames let in with none in flight, for measurements.
    var loneCount: Int { lock.withLock { lone } }

    /// The floor, how long after the gate was made it was read and whether the previews were quiet then,
    /// and the largest excess a frame was weighed against, for measurements.
    var floorReport: (floor: Int?, readAfter: TimeInterval?, quiet: Bool, largestExcess: Int) {
        lock.withLock { (floor, floorRead?.after, floorRead?.quiet ?? false, largestExcess) }
    }
}

/// Takes turns between a develop's frames and the previews' decodes, the frame view's, the sheet's and a
/// refinement's. One such decode adds 0.3 to 0.84 GB at the frame view's sizes, and the memory gate, which
/// reads the footprint before each frame, cannot see it coming; started during a develop, beside the
/// frames the gate let in, it took 16-bit TIFF develops to 2244 to 2348 MB
/// (docs/manual-development-validation.md, "Develops started with the frame view open"). So while a
/// develop runs a preview decode waits until none of its frames and no other preview decode is under way,
/// and no frame starts while a preview decode waits or runs. Outside a develop a preview decode only
/// counts itself in, so one under way as a develop starts holds its first frame back. The previews'
/// renders and trims are told too, and what they hold, for the memory gate's floor. Safe to use from
/// any thread.
///
/// Its lock comes before the previews' (`FilmPreviews`): holding it, the turns call `stopped`, the memory
/// gate's `fits` and `previewsHeld`, which take the previews' lock, so nothing may ask the turns anything
/// while holding the previews' lock, `isDevelopRunning` included, or the two wait on each other for good.
public final class DecodeTurns: @unchecked Sendable {
    private let condition = NSCondition()
    private var developing = false
    private var frames = 0
    private var previewsWaiting = 0
    private var previewsRunning = 0
    private var rendersRunning = 0
    /// When a preview decode or render last ended or the previews were last trimmed, in seconds of
    /// system uptime.
    private var lastBreak = -TimeInterval.infinity
    /// Under its own lock, since the gate asks for it while it holds the turns'.
    private var held: (@Sendable () -> Int)?
    private let heldLock = NSLock()

    public init() {}

    /// What the previews hold that they would let go for a develop: the frame view's decodes and the
    /// rendered pictures. The memory gate calls it holding the turns' lock.
    public var previewsHeld: (@Sendable () -> Int)? {
        get { heldLock.withLock { held } }
        set { heldLock.withLock { held = newValue } }
    }

    func previewsHeldNow() -> Int { (heldLock.withLock { held })?() ?? 0 }

    /// Whether a develop runs, from the moment it is asked for to its end.
    public var isDevelopRunning: Bool {
        get { condition.withLock { developing } }
        set {
            condition.withLock { developing = newValue }
            condition.broadcast()
        }
    }

    /// Before a preview decode: while a develop runs, waits until none of its frames and no other
    /// preview decode is under way, asking `stopped` every 20 ms; `false`, counting nothing, once it
    /// says so. Each `true` is followed by `endPreview` once the decode is done.
    public func beginPreview(stopped: () -> Bool) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        previewsWaiting += 1
        defer { previewsWaiting -= 1 }
        while developing, frames > 0 || previewsRunning > 0 {
            if stopped() { return false }
            condition.wait(until: Date(timeIntervalSinceNow: 0.02))
        }
        previewsRunning += 1
        return true
    }

    /// A preview decode `beginPreview` let in is done.
    public func endPreview() {
        condition.withLock {
            previewsRunning -= 1
            lastBreak = ProcessInfo.processInfo.systemUptime
        }
        condition.broadcast()
    }

    /// A preview render begins; it takes no turn, but the gate reads the floor only once none runs.
    public func beginRender() {
        condition.withLock { rendersRunning += 1 }
    }

    /// A render `beginRender` counted is done.
    public func endRender() {
        condition.withLock {
            rendersRunning -= 1
            lastBreak = ProcessInfo.processInfo.systemUptime
        }
        condition.broadcast()
    }

    /// The previews let go what they hold for a develop.
    public func trimmed() {
        condition.withLock { lastBreak = ProcessInfo.processInfo.systemUptime }
        condition.broadcast()
    }

    /// Waits until no preview decode waits or runs, no render runs, and none has ended and nothing has
    /// been trimmed for `quiet` seconds, or `atMost` seconds have passed: whether the previews were quiet,
    /// or `nil` once `stopped` says so first.
    func waitForQuiet(quiet: TimeInterval, atMost: TimeInterval, stopped: () -> Bool) -> Bool? {
        let deadline = ProcessInfo.processInfo.systemUptime + atMost
        condition.lock()
        defer { condition.unlock() }
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if previewsWaiting == 0, previewsRunning == 0, rendersRunning == 0, now - lastBreak >= quiet { return true }
            if now >= deadline { return false }
            if stopped() { return nil }
            condition.wait(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    /// Waits until no preview decode waits or runs and `fits`, given the frames in flight, lets a frame
    /// start, and counts it in: whether it waited, or `nil`, counting nothing, once `stopped` says so first.
    /// `fits` reads the footprint, so the wait is timed, 20 ms, as well as woken.
    func admitFrame(fits: (Int) -> Bool, stopped: () -> Bool) -> Bool? {
        condition.lock()
        defer { condition.unlock() }
        var waited = false
        while previewsWaiting > 0 || previewsRunning > 0 || !fits(frames) {
            if stopped() { return nil }
            waited = true
            condition.wait(until: Date(timeIntervalSinceNow: 0.02))
        }
        frames += 1
        return waited
    }

    /// A frame is written, or failed.
    func frameLeft() {
        condition.withLock { frames -= 1 }
        condition.broadcast()
    }

    /// The develop's frames in flight and the preview decodes waiting and running, for the tests.
    var counts: (frames: Int, previewsWaiting: Int, previewsRunning: Int) {
        condition.withLock { (frames, previewsWaiting, previewsRunning) }
    }
}
