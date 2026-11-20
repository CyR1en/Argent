import Foundation
import Metal

/// What Presence reads of one decode, made from its untouched light before Exposure and never from a slider: Clarity's two fields,
/// Texture's band and Dehaze's transmission and airlight. Immutable once made. A render holds the one it was given until its command
/// buffer has run; a part made later for the same decode goes into a new analysis that shares the parts already made.
///
/// Every part is made from the frame's own light at a size fixed against the full-size picture, so the frame view's analysis and the
/// develop's agree (fits F1 section 6, F2 Q9): Clarity's and Dehaze's at their constants' long side, Texture's at its share of the
/// full-size picture's long side or the decode's own, whichever is less (`PresenceConstants.Texture.field`).
final class PresenceAnalysis: @unchecked Sendable {
    /// Which parts an analysis holds, and which a render needs.
    struct Parts: OptionSet, Sendable, Hashable {
        let rawValue: Int
        static let texture = Parts(rawValue: 1 << 0)
        static let clarity = Parts(rawValue: 1 << 1)
        static let haze = Parts(rawValue: 1 << 2)

        /// The part `control` reads; Vibrance and Saturation read none.
        static func read(by control: Presence.Control) -> Parts {
            switch control {
            case .texture: .texture
            case .clarity: .clarity
            case .dehaze: .haze
            case .vibrance, .saturation: []
            }
        }

        /// What `presence`'s set controls read.
        static func needed(by presence: Presence) -> Parts {
            Presence.Control.allCases.reduce(into: []) { parts, control in
                if presence.value(for: control) != 0 { parts.formUnion(read(by: control)) }
            }
        }
    }

    /// Clarity's two fields, each `ToneBaseField`'s layout (`rg32Float`, box(a) and box(b) of log2 luminance), read by `tone_base_log2`.
    /// Made together from one guide pass, so Clarity crossing zero builds nothing.
    struct ClarityFields {
        let positive: MTLTexture
        let negative: MTLTexture
    }

    /// Texture's band coefficients, the same layout, on the field `field` describes.
    struct TextureBand {
        let coefficients: MTLTexture
        let field: ToneBaseParameters
    }

    /// Dehaze's transmission coefficients (a, b), `t = a g + b`, the same layout, and the frame's airlight in its light before Exposure.
    struct HazeEstimate {
        let transmission: MTLTexture
        let airlight: SIMD3<Float>
    }

    /// The decode by its pooled texture's lease serial (`MaskGuideID`, which no other lease shares), and the constants' version.
    struct Key: Hashable {
        let decode: MaskGuideID
        let version: String
    }

    let key: Key
    let clarity: ClarityFields?
    let texture: TextureBand?
    let haze: HazeEstimate?

    init(key: Key, clarity: ClarityFields? = nil, texture: TextureBand? = nil, haze: HazeEstimate? = nil) {
        self.key = key
        self.clarity = clarity
        self.texture = texture
        self.haze = haze
    }

    var parts: Parts {
        var parts: Parts = []
        if clarity != nil { parts.insert(.clarity) }
        if texture != nil { parts.insert(.texture) }
        if haze != nil { parts.insert(.haze) }
        return parts
    }

    /// The textures' bytes as Metal allocated them.
    var bytes: Int {
        [clarity?.positive, clarity?.negative, texture?.coefficients, haze?.transmission].compactMap { $0 }
            .reduce(0) { $0 + $1.allocatedSize }
    }

    /// This analysis with `made`'s parts added: the same textures, shared, for the parts this one already holds.
    func adding(_ made: PresenceAnalysis) -> PresenceAnalysis {
        PresenceAnalysis(key: key, clarity: clarity ?? made.clarity, texture: texture ?? made.texture, haze: haze ?? made.haze)
    }
}

/// What makes an analysis's parts on the GPU: `PresenceAnalysisBuilder`, or a test's hand-made fields.
protocol PresenceAnalysisBuilding: Sendable {
    func clarity(of frame: LinearFrame, constants: PresenceConstants) throws -> PresenceAnalysis.ClarityFields
    func texture(of frame: LinearFrame, constants: PresenceConstants) throws -> PresenceAnalysis.TextureBand
    func haze(of frame: LinearFrame, constants: PresenceConstants) throws -> PresenceAnalysis.HazeEstimate
}

/// Presence's analyses, kept per decode: a slider step never rebuilds one, and neither does an Exposure drag, an undo or a stock
/// switch, since an analysis depends on the frame and the constants alone. One per `GPU` (`GPU.presenceAnalyses`), shared by every
/// renderer. Nothing is made until a frame has Texture, Clarity or Dehaze set.
///
/// A request is answered by the first of these that applies:
/// 1. A kept analysis of this decode and version holds every part asked for. Nothing is built: a slider step, Clarity crossing
///    zero, an undo, another stock.
/// 2. A kept analysis lacks some. Only the missing parts are built, and a new analysis sharing the old one's parts replaces it.
/// 3. None is kept: the first nonzero scene control on a decode, an eviction, a new constants version. The parts asked for are built.
///
/// A decode shorter than `keptMinimumLongSide` (the sheet's and the strip's) has its parts built for each request and never kept, as
/// smart masks' coefficients are not. A develop sets the limit to 0 and keeps none between frames. The parts are built in a fixed
/// order, Texture's band first, then Clarity's fields, then Dehaze's, each build's working textures let go before the next.
///
/// Safe to call from any thread: one lock, held through a build's GPU wait, so two lanes asking for one analysis build it once.
public final class PresenceAnalyses: @unchecked Sendable {
    /// What the cache has done since it was made, to prove what a step did not do.
    public struct Statistics: Sendable, Equatable {
        public var hits = 0
        public var clarityBuilds = 0
        public var textureBuilds = 0
        public var hazeBuilds = 0
        /// Analyses handed to a render and not kept: a small decode, or a limit too low to hold it.
        public var unkept = 0
        public var evictions = 0
        public var builds: Int { clarityBuilds + textureBuilds + hazeBuilds }
    }

    /// The frame view's analysis at its largest decode, 4912 pixels on the long side (Texture's band at 3504 by 2336 and three 1024
    /// fields, 82 MB), twice: the scaled decode's and the refined one's while one replaces the other.
    public static let defaultMaximumBytes = 168 << 20
    /// While a develop runs the previews keep only the frame view's (`FilmPreviews.isDevelopRunning`).
    public static let developRunningMaximumBytes = 84 << 20
    public static let keptMinimumLongSide = 1024
    /// Texture's band is built in bands of rows: its working textures stay under this whatever the decode.
    public static let textureWorkingSetBudget = 28 << 20
    /// Clarity's build holds four textures of its field at once: the two fields, the shared guide and one scratch.
    static let clarityTexturesWhileMade = 4
    /// Dehaze's build, bytes a texel of its field beside the kept coefficients. It is the base's count, made before the build, of the
    /// light in `rgba16Float`, two `r32Float`, three `rgba32Float` and 4 for a CPU readback. The build uses 56. Its light is a `float4`
    /// buffer, so the airlight matches `fit_dehaze.py` to 1e-7. The least channel and its erosion are two `float` buffers, the guided
    /// filter takes two `rg32Float` and one `rgba32Float`, and the CPU reads the buffers in place, with no readback. The airlight keeps
    /// the pixels it chooses, every pixel of a field of one colour, in the least channel's buffer, so the CPU allocates only its
    /// quantile's top `1 - airlightQuantile` of the field, 17 KB at 1024 by 1024 with its sorted copy. The count stays as the ceiling
    /// the develop's gate reads. At a 3:2 frame's 1024 by 683 field the build allocates 40.0 MB of the 47.6 MB it counts, and its peak
    /// footprint stays under the count where the airlight chooses the whole field (`PresenceAnalysisMeasureTests`).
    static let hazeWorkingBytesPerTexel = 8 + 2 * 4 + 3 * 16 + 4

    private let builder: any PresenceAnalysisBuilding
    private let lock = NSLock()
    /// Oldest first.
    private var entries: [PresenceAnalysis] = []
    private var limit: Int
    private var counts = Statistics()

    init(builder: any PresenceAnalysisBuilding, maximumBytes: Int = PresenceAnalyses.defaultMaximumBytes) {
        self.builder = builder
        self.limit = maximumBytes
    }

    /// `frame`'s analysis holding at least `parts`, made under `constants`. `frame` must be the untouched decode: a render asks before
    /// anything writes over it.
    func analysis(of frame: LinearFrame, parts: PresenceAnalysis.Parts, constants: PresenceConstants) throws -> PresenceAnalysis {
        try lock.withLock {
            let key = PresenceAnalysis.Key(decode: frame.maskGuide, version: constants.version)
            let index = entries.firstIndex { $0.key == key }
            if let index, entries[index].parts.isSuperset(of: parts) {
                counts.hits += 1
                let hit = entries.remove(at: index)
                entries.append(hit)
                return hit
            }
            let kept = index.map { entries[$0] } ?? PresenceAnalysis(key: key)
            let missing = parts.subtracting(kept.parts)
            let texture = missing.contains(.texture) ? try builder.texture(of: frame, constants: constants) : nil
            if texture != nil { counts.textureBuilds += 1 }
            let clarity = missing.contains(.clarity) ? try builder.clarity(of: frame, constants: constants) : nil
            if clarity != nil { counts.clarityBuilds += 1 }
            let haze = missing.contains(.haze) ? try builder.haze(of: frame, constants: constants) : nil
            if haze != nil { counts.hazeBuilds += 1 }
            let made = kept.adding(PresenceAnalysis(key: key, clarity: clarity, texture: texture, haze: haze))
            if let index { entries.remove(at: index) }
            if max(frame.width, frame.height) >= Self.keptMinimumLongSide {
                entries.append(made)
                evict(to: limit)
            }
            if !entries.contains(where: { $0 === made }) { counts.unkept += 1 }
            return made
        }
    }

    public var statistics: Statistics { lock.withLock { counts } }
    /// The bytes of the analyses kept. Those a render still holds after they were let go are not among them.
    public var residentBytes: Int { lock.withLock { entries.reduce(0) { $0 + $1.bytes } } }
    /// Changing it evicts at once if it must. A develop keeps none between frames (0).
    public var maximumBytes: Int {
        get { lock.withLock { limit } }
        set { lock.withLock { limit = newValue; evict(to: newValue) } }
    }

    /// Frees every kept analysis, for `FilmPreviews.trimForDevelop` and a new roll.
    public func removeAll() { lock.withLock { evict(to: 0) } }

    private func evict(to bytes: Int) {
        var held = entries.reduce(0) { $0 + $1.bytes }
        while held > bytes, !entries.isEmpty {
            held -= entries.removeFirst().bytes
            counts.evictions += 1
        }
    }

    /// What making and holding `presence`'s analysis adds to a develop of a `width` by `height` picture at its peak, for the develop's
    /// memory gate (`DevelopBudget.presenceCost`): each part kept through the render and each part's working textures, all counted,
    /// since Metal gives a texture back 0.1 to 0.25 s after its release, and a sixteenth more for Metal's rounding of each allocation.
    /// 0 for a frame whose Texture, Clarity and Dehaze are 0, or whose constants this build does not have, which fails before a build.
    /// About 181 MB at 7008 by 4672 with all three. `PresenceAnalysisBuilder`'s measured peak is held under it (package B).
    public static func developBytes(_ presence: Presence, width: Int, height: Int) -> Int {
        let parts = PresenceAnalysis.Parts.needed(by: presence)
        guard !parts.isEmpty, let constants = PresenceConstants.named(presence.version) else { return 0 }
        func texels(_ field: ToneBaseParameters) -> Int {
            let size = field.fieldSize(width: width, height: height)
            return size.width * size.height
        }
        var bytes = 0
        if parts.contains(.texture) {
            let long = max(width, height)
            bytes += texels(constants.texture.field(decodeLongSide: long, fullLongSide: long)) * 8 + textureWorkingSetBudget
        }
        if parts.contains(.clarity) {
            let field = max(texels(constants.clarity.positiveField), texels(constants.clarity.negativeField))
            bytes += clarityTexturesWhileMade * field * 8
        }
        if parts.contains(.haze) {
            bytes += texels(constants.dehaze.guide) * (8 + hazeWorkingBytesPerTexel)
        }
        return bytes + bytes / 16
    }
}
