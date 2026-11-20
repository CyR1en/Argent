import Foundation
import Metal

/// Four slices of one control: a mask slot's value at `[k]`, in slice `k / 4`, channel `k % 4`, as the kernels dot it with the coverage.
struct LocalMaskSlices: Sendable, Equatable {
    var slice0 = SIMD4<Float>.zero
    var slice1 = SIMD4<Float>.zero
    var slice2 = SIMD4<Float>.zero
    var slice3 = SIMD4<Float>.zero

    subscript(slot: Int) -> Float {
        get {
            switch slot / MaskCoverage.masksPerSlice {
            case 0: slice0[slot % MaskCoverage.masksPerSlice]
            case 1: slice1[slot % MaskCoverage.masksPerSlice]
            case 2: slice2[slot % MaskCoverage.masksPerSlice]
            default: slice3[slot % MaskCoverage.masksPerSlice]
            }
        }
        set {
            switch slot / MaskCoverage.masksPerSlice {
            case 0: slice0[slot % MaskCoverage.masksPerSlice] = newValue
            case 1: slice1[slot % MaskCoverage.masksPerSlice] = newValue
            case 2: slice2[slot % MaskCoverage.masksPerSlice] = newValue
            default: slice3[slot % MaskCoverage.masksPerSlice] = newValue
            }
        }
    }
}

/// Mirrors `LocalMaskParameters` in `LocalMaskShaders.swift`, 592 bytes: what a slider or Amount move writes, and all it writes (plan
/// section 4, rule 2). `localAny` and `toneAny` sit in what T3's block left as tail padding, so an Exposure mask reads no tone control.
struct LocalMaskParameters: Sendable, Equatable {
    var exposure = LocalMaskSlices()
    var highlights = LocalMaskSlices()
    var shadows = LocalMaskSlices()
    var contrast = LocalMaskSlices()
    var whites = LocalMaskSlices()
    var blacks = LocalMaskSlices()
    var maskCount: UInt32 = 0
    var sliceCount: UInt32 = 0
    var referenceOffset: Float = 0
    var tableStart: Float = 0
    var tableScale: Float = 0
    var panelHighlights: Float = 0
    var panelShadows: Float = 0
    var highlightsFade: Float = 0
    var shadowsFade: Float = 0
    var localAny: UInt32 = 0
    var toneAny: UInt32 = 0
    /// Some mask carries a balance: only then does the Negative LUT pass read the coverage a second time.
    var balanceAny: UInt32 = 0
    var warmth = LocalMaskSlices()
    var magenta = LocalMaskSlices()
    /// One unit of each slider in the Print LUT's dye units, per channel: `MaskBalance`'s axes through the stock's `printUnits`.
    var warmthAxis = SIMD4<Float>.zero
    var magentaAxis = SIMD4<Float>.zero

    /// A block for a kernel that reads only the coverage (`local_mask_coverage_region`): the slices, and no slider.
    init(coverageOnly sliceCount: Int) { self.sliceCount = UInt32(sliceCount) }

    /// The block for `masks`, whose slot k is `masks.masks[k]`, over `panel`, with tables of that geometry.
    init(masks: MaskSet, sliceCount: Int, start: Float, step: Float, referenceOffset: Float, panel: LocalScene.Panel, printUnits: SIMD3<Float> = .zero) {
        for (slot, mask) in masks.masks.enumerated() {
            exposure[slot] = mask.scaledValue(for: .exposure)
            highlights[slot] = mask.scaledValue(for: .highlights)
            shadows[slot] = mask.scaledValue(for: .shadows)
            contrast[slot] = mask.scaledValue(for: .contrast)
            whites[slot] = mask.scaledValue(for: .whites)
            blacks[slot] = mask.scaledValue(for: .blacks)
            if highlights[slot] != 0 || shadows[slot] != 0 { localAny = 1 }
            if contrast[slot] != 0 || whites[slot] != 0 || blacks[slot] != 0 { toneAny = 1 }
            let balance = mask.scaledBalance
            warmth[slot] = balance.warmth
            magenta[slot] = balance.magenta
            if !balance.isNeutral { balanceAny = 1 }
        }
        maskCount = UInt32(masks.count)
        self.sliceCount = UInt32(sliceCount)
        self.referenceOffset = referenceOffset
        tableStart = start
        tableScale = 1 / step
        panelHighlights = panel.highlights
        panelShadows = panel.shadows
        highlightsFade = panel.highlightsFade
        shadowsFade = panel.shadowsFade
        warmthAxis = SIMD4(MaskBalance.warmthAxis * printUnits, 0)
        magentaAxis = SIMD4(MaskBalance.magentaAxis * printUnits, 0)
    }
}

/// Mirrors `LocalMaskRefinement`: which of the four coefficient textures tier 2 reads, and whose coverage each takes. Bit i of `refined`:
/// coefficient texture i gives mask slot `slot[i]` its coverage, the refined value v, inverted where `invert`'s bit i is set; or, where
/// `composed`'s bit i is set, `c0 + (c1 − c0) · v` from the composed fields in slots `low` and `low + 1`, `low` in bits 4i to 4i + 3 of
/// `composedSlots` (`MaskSlots.composed`). More refined masks than four take tier 1 (`MaskRefiner.perPixelLimit`).
struct LocalMaskRefinement: Sendable, Equatable {
    var refined: UInt32 = 0
    var invert: UInt32 = 0
    var composed: UInt32 = 0
    var composedSlots: UInt32 = 0
    var slot = SIMD4<UInt32>.zero
}

/// The second library's pipelines (plan section 4, rule 4), compiled the first time a frame has masks and not before, so a frame without
/// them pays nothing and takes today's kernels by choice of pipeline. `GPU.localMaskPipelines()` makes one, shared by every renderer.
final class LocalMaskPipelines: @unchecked Sendable {
    let negative: MTLComputePipelineState
    let negativeHalation: MTLComputePipelineState
    let negativeToned: MTLComputePipelineState
    let negativeHalationToned: MTLComputePipelineState
    let halationSource: MTLComputePipelineState
    let halationMix: MTLComputePipelineState
    /// `local_mask_core`, for tests.
    let core: MTLComputePipelineState
    /// `local_mask_coverage_probe`: each pixel's coverage as the masked kernels read it, tier 2 included, for tests.
    let coverageProbe: MTLComputePipelineState
    /// `local_mask_coverage_region`: the probe's reading over one region of the decode, for the overlay's sharp raster (`GPU.regionCoverage`).
    let coverageRegion: MTLComputePipelineState
    /// What tier 2's coefficient slots bind while no mask is refined.
    let refinedPlaceholder: MTLTexture

    init(device: MTLDevice) throws {
        let library = try device.makeLibrary(source: try ShaderSource.localMaskLibrary(), options: nil)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw GPUError.shaderFunctionMissing(name) }
            return try device.makeComputePipelineState(function: function)
        }
        negative = try pipeline(ShaderSource.localMaskName("apply_lut3d"))
        negativeHalation = try pipeline(ShaderSource.localMaskName("apply_lut3d_halation"))
        negativeToned = try pipeline(ShaderSource.localMaskName("apply_lut3d_toned"))
        negativeHalationToned = try pipeline(ShaderSource.localMaskName("apply_lut3d_halation_toned"))
        halationSource = try pipeline(ShaderSource.localMaskName("halation_source"))
        halationMix = try pipeline(ShaderSource.localMaskName("halation_mix"))
        core = try pipeline("local_mask_core")
        coverageProbe = try pipeline("local_mask_coverage_probe")
        coverageRegion = try pipeline("local_mask_coverage_region")
        refinedPlaceholder = try GPU.makeTexture(device: device, width: 1, height: 1, usage: .shaderRead)
    }

    func negative(halation: Bool, toned: Bool) -> MTLComputePipelineState {
        toned ? (halation ? negativeHalationToned : negativeToned) : (halation ? negativeHalation : negative)
    }
}

/// `LocalScene`'s tables ready to bind for one stock and key, kept by `FilmRenderer` so a slider builds none: the buffer, the geometry the
/// parameter block repeats, and the rows' extremes, from which a render bounds its gain. The floats themselves stay only in the buffer.
struct LocalMaskTables {
    let buffer: MTLBuffer
    let start: Float
    let step: Float
    let referenceOffset: Float
    let bounds: LocalMaskBounds
}

/// The most and the least each of `LocalScene`'s five tables gives at each of its knots, over every level. `G` is linear between knots,
/// so these bound every value a slider between two knots can read: what the halation source's storage scale needs to know.
struct LocalMaskBounds: Sendable, Equatable {
    private var highest: [Float] = []
    private var lowest: [Float] = []

    init(_ scene: LocalScene) {
        typealias L = LocalScene.Layout
        for table in LocalScene.Table.allCases {
            for knot in 0..<L.knots {
                let row = scene.tables[(table.offset + knot * L.samples)..<(table.offset + (knot + 1) * L.samples)]
                highest.append(row.max() ?? 0)
                lowest.append(row.min() ?? 0)
            }
        }
    }

    private static func index(_ table: LocalScene.Table) -> Int { LocalScene.Table.allCases.firstIndex(of: table) ?? 0 }

    /// The most `table` gives for a slider anywhere in `low...high`.
    private func most(_ table: LocalScene.Table, from low: Float, to high: Float) -> Float {
        typealias L = LocalScene.Layout
        let axis = table.axis, last = Float(L.knots - 1), base = Self.index(table) * L.knots
        let first = Int(min(max((low - axis.start) / axis.spacing, 0), last).rounded(.down))
        let final = Int(min(max((high - axis.start) / axis.spacing, 0), last).rounded(.up))
        return highest[(base + first)...(base + final)].max() ?? 0
    }

    /// The least `table` gives for a slider at `value`.
    private func least(_ table: LocalScene.Table, at value: Float) -> Float {
        typealias L = LocalScene.Layout
        let axis = table.axis, last = Float(L.knots - 1), base = Self.index(table) * L.knots
        let position = min(max((value - axis.start) / axis.spacing, 0), last)
        return min(lowest[base + Int(position.rounded(.down))], lowest[base + Int(position.rounded(.up))])
    }

    /// A bound on `LocalScene.gain` for these sliders at any coverage from 0 to 1 and any level. Each mask's value sums to a pixel's slider
    /// by a coverage in 0...1, so that slider lies between the sum of the negative values and the sum of the positive ones. Every read in
    /// the evaluation is bounded by its own table's rows wherever earlier reads moved the level, and they add. `panelGain` is what the
    /// panel's own tables can add. The result never exceeds the evaluation's own clamp.
    func maximumGain(masks: [Mask], panel: LocalScene.Panel, panelGain: Float) -> Float {
        func range(_ control: ManualAdjustments.Control) -> (low: Float, high: Float) {
            masks.reduce((Float(0), Float(0))) { sum, mask in
                let value = mask.scaledValue(for: control)
                return (sum.0 + min(value, 0), sum.1 + max(value, 0))
            }
        }
        func move(_ table: LocalScene.Table, _ control: ManualAdjustments.Control, panel value: Float, fade: Float) -> Float {
            let reach = range(control)
            guard reach.low != 0 || reach.high != 0 else { return 0 }
            var gain = max(0, most(table, from: value + reach.low, to: value + reach.high))
            if value != 0 { gain += max(0, -least(table, at: value)) * max(1, 1 + fade) }
            return gain
        }
        func plain(_ table: LocalScene.Table, _ control: ManualAdjustments.Control) -> Float {
            let reach = range(control)
            guard reach.low != 0 || reach.high != 0 else { return 0 }
            return max(0, most(table, from: reach.low, to: reach.high))
        }
        let whites = range(.whites), blacks = range(.blacks)
        var ends = plain(.whites, .whites) + plain(.blacks, .blacks)
        // Whites with Blacks below 0 can take the stretch, whose soft limit is this. Between it and the tables is a convex mix of the two.
        if (whites.low != 0 || whites.high != 0) && blacks.low < 0 { ends = max(ends, ManualToneTables.gainLimit) }
        let total = panelGain + move(.highlights, .highlights, panel: panel.highlights, fade: panel.highlightsFade)
            + move(.shadows, .shadows, panel: panel.shadows, fade: panel.shadowsFade) + plain(.contrast, .contrast) + ends
        return min(total, LocalScene.gainLimit)
    }

    /// The most the masks' Exposure can raise a pixel, in stops: a pixel's sum, by coverages in 0...1, is at most the positive values'.
    static func maximumExposure(masks: [Mask]) -> Float {
        min(masks.reduce(0) { $0 + max($1.scaledValue(for: .exposure), 0) }, LocalScene.exposureLimit)
    }
}

/// What a render with masks hands the two passes that read the scene: the coverage's lease, the tables, the parameter block and the
/// masked pipelines. Holding this holds the lease, so it lives until the render's command buffer has completed, and no longer.
struct LocalMaskInputs {
    /// The halation source's storage scale, in stops, at most. The summed gain can reach +40, and a half float cannot hold both that and a
    /// pixel with no gain, so past this a source holds the light with no gain and clips what the gain took past 2^32 × 2^-rating, far
    /// past white: at the blur kernel's reach (3 sigma, about 2^-19 of a texel's light on the baked stocks) such a texel still whites out
    /// the film. A pixel with no gain beside it keeps 8 bits at the knee. No render at or under it clips anything (`LocalMaskRenderTests`).
    static let storageStopsLimit: Float = 16

    let pipelines: LocalMaskPipelines
    let coverage: MaskCoverage
    let tables: MTLBuffer
    var parameters: LocalMaskParameters
    /// Tier 2: Phase 2 sets `refinement` and the textures in its slots.
    var refinement = LocalMaskRefinement()
    var refinedCoefficients: [MTLTexture?] = [nil, nil, nil, nil]
    /// The most a pixel's masks and panel tables together can raise it, in stops, Exposure and tone apart.
    let maximumExposure: Float
    let maximumGain: Float

    /// Binds everything a masked kernel adds to today's: slots no kernel of today's reads.
    func bind(to encoder: MTLComputeCommandEncoder) {
        var block = parameters, refine = refinement
        encoder.setTexture(coverage.texture, index: 5)
        for (index, texture) in refinedCoefficients.enumerated() {
            encoder.setTexture(texture ?? pipelines.refinedPlaceholder, index: 6 + index)
        }
        encoder.setBuffer(tables, offset: 0, index: 5)
        encoder.setBytes(&block, length: MemoryLayout<LocalMaskParameters>.stride, index: 6)
        encoder.setBytes(&refine, length: MemoryLayout<LocalMaskRefinement>.stride, index: 7)
    }
}

extension LocalMaskInputs {
    /// Tier 2 (plan section 4's rule): the masks `MaskRefiner.perPixelPlan` names evaluate their refined coverage per pixel, from the
    /// pixel's own light, in place of their slice, a composed one with its composed fields; the rest read their slice (tier 1). Nothing
    /// on a frame under the per-pixel size.
    mutating func refinePerPixel(_ masks: MaskSet, session: MaskRefinementSession) throws {
        guard session.perPixel else { return }
        let composed = coverage.slots.composed
        for (index, plan) in MaskRefiner.perPixelPlan(masks.masks).enumerated() {
            refinedCoefficients[index] = try session.coefficients(for: plan.selection)
            refinement.refined |= 1 << UInt32(index)
            refinement.slot[index] = UInt32(plan.slot)
            if plan.composedLow != nil {
                guard let fields = composed.first(where: { $0.mask == plan.slot }) else { preconditionFailure("MaskSlots placed it") }
                refinement.composed |= 1 << UInt32(index)
                refinement.composedSlots |= UInt32(fields.low) << UInt32(4 * index)
            } else if plan.inverted {
                refinement.invert |= 1 << UInt32(index)
            }
        }
    }
}

extension MaskRefiner {
    /// How a mask takes tier 2: its slot, its selection, and either inverted (a selection alone, under Invert or as Background) or
    /// composed, with the slot its composed fields begin at.
    public struct PerPixel: Sendable, Equatable {
        public let slot: Int
        public let selection: SmartSelection
        public let inverted: Bool
        /// The first of the two slots after the masks' that hold its composed fields; `nil` for a selection alone.
        public let composedLow: Int?
    }

    /// The selection `mask` evaluates per pixel, whether it is alone (then whether inverted), or `nil` when the mask reads its slice. A
    /// mask takes tier 2 when it is on, carries Exposure or a balance after Amount, and holds exactly one smart selection: alone, added; or composed
    /// with gradients and brushes in any order, since the composite is then affine in the refined value (`MaskSlots.Composed`). Two
    /// selections in one mask are not affine and take tier 1, as a tone-only mask does, which differs from tier 2 by under 0.3 L* on
    /// average there (R9). A feathered selection takes tier 1 too, alone or composed: its blur has no per-pixel form (`MaskFeather`).
    public static func perPixelSelection(_ mask: Mask) -> (selection: SmartSelection, inverted: Bool, alone: Bool)? {
        // A balance puts colour on the wrong side of an edge where a tone mask's Highlights would pass unseen, so it reads per pixel as Exposure does.
        guard mask.isEnabled, mask.scaledValue(for: .exposure) != 0 || !mask.scaledBalance.isNeutral else { return nil }
        let smart = mask.components.indices.filter { if case .smart = mask.components[$0].shape { return true } else { return false } }
        guard smart.count == 1, case .smart(let selection) = mask.components[smart[0]].shape, selection.raster != nil,
              selection.feather == 0 else { return nil }
        let component = mask.components[smart[0]]
        let alone = mask.components.count == 1 && component.operation == .add
        return (selection, component.invert != selection.kind.invertsSeed, alone)
    }

    /// The masks a frame at or over `perPixelMinimumLongSide` evaluates per pixel: the first `perPixelLimit` that qualify, in list order,
    /// a composed one only while its two composed fields still fit in the array's sixteen slots after the masks'. A mask's tier then
    /// depends on its own Exposure, its shape and its place in the list, never on another mask's slider value.
    public static func perPixelPlan(_ masks: [Mask]) -> [PerPixel] {
        var plan: [PerPixel] = [], next = masks.count
        for (slot, mask) in masks.enumerated() where plan.count < perPixelLimit {
            guard let made = perPixelSelection(mask) else { continue }
            if made.alone {
                plan.append(PerPixel(slot: slot, selection: made.selection, inverted: made.inverted, composedLow: nil))
            } else if next + 2 <= MaskSet.maximumMasks {
                plan.append(PerPixel(slot: slot, selection: made.selection, inverted: false, composedLow: next))
                next += 2
            }
        }
        return plan
    }

    /// The slots of `masks` that take tier 2 (`perPixelPlan`).
    public static func perPixelSlots(_ masks: [Mask]) -> [Int] { perPixelPlan(masks).map(\.slot) }
}

extension Mask {
    /// Whether a render of this mask reads a smart selection's refinement: it is on and has one.
    public var readsSmartSelection: Bool {
        isEnabled && components.contains { if case .smart = $0.shape { return true } else { return false } }
    }

    /// Whether a render of this mask may read a Follow edges stroke's measured shape: it is on and a brush of it has one.
    public var readsMeasuredStroke: Bool {
        isEnabled && components.contains { if case .brush(let paint) = $0.shape { return paint.strokes.contains(where: \.followEdges) } else { return false } }
    }
}

/// `picture`, or the frame's own size where it has none: what a render asks `GPU.maskFields` for.
extension LinearFrame {
    public var maskPicture: MaskSpace {
        get throws { try picture ?? MaskSpace(width: width, height: height) }
    }
}
