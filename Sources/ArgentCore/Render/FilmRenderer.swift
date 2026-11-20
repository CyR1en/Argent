import Foundation
import Metal

/// A frame after the film model: display-linear light in the working primaries.
public struct RenderedFrame {
    public let image: PooledTexture
    public let gpuSeconds: Double
}

/// The render graph after the decode, as a develop records it: halation, the two LUT passes,
/// capture sharpening, grain, lab balance and the resize to the output's size. A develop made
/// under another version is made again (`Recipe.lastDevelopMatches`), as one made under other
/// decoder pins is. Bumped whenever a pass changes a develop's pixels with no change to the
/// recipe's settings or the stock's digest. 2026-10-06-1: the area resize for long-edge
/// develops, and the halation kernels rounding to the nearest half. 2026-10-07-1: capture
/// sharpening's constants chosen on the CC0 samples (docs/provenance.md). 2026-10-07-2: the
/// halation kernel weighted to the base's reflection geometry, and grain at amount 1 rather
/// than 0.6 (docs/research/film.md). 2026-10-09-1: grain generated at each cache bucket's
/// canonical pitch, so earlier renders cannot change a frame's grain. A frame with a tone step
/// (`PrintTone`) names its version too, so a develop without one keeps its version, and a frame
/// with masks names their compiler (`MaskSet.currentVersion`), and a frame with Presence its constants' version
/// (`Presence.version`), so a develop without it keeps its version. 2026-11-19-1: scene gamut
/// compression before Negative LUT log encoding, preserving extreme-color detail without a print-side mapping.
public enum RenderGraph {
    public static let version = "2026-11-19-1"

    /// A bypassed extension must not invalidate an unchanged automatic develop.
    public static func version(for settings: DevelopSettings, lens: ResolvedLensCorrection? = nil) -> String {
        var base = settings.tone.isActive ? version + "+tone-" + settings.tone.version : version
        if !settings.manual.isIdentity {
            let manual = base + "+manual-" + settings.manual.version
            let curved = settings.manual.adjustments.curves.isIdentity ? manual
                : manual + "+" + settings.manual.adjustments.curves.version
            let masks = settings.manual.adjustments.masks
            let masked = masks.isEmpty ? curved : curved + "+masks-" + masks.version
            let presence = settings.manual.adjustments.presence
            base = presence.isIdentity ? masked : masked + "+presence-" + presence.version
        }
        return lens.map { base + "+lens-" + $0.digest } ?? base
    }

    public static func namesLens(_ version: String?) -> Bool { version?.contains("+lens-") == true }
}

/// What the scene mapping reads on the GPU, in the Negative LUT pass and the halation source: the
/// parameter block, and for a gain-table Light compiler's tone controls its tables (global
/// samples, then local, in one buffer: 4 KB, past `setBytes`' limit) and the local base field.
struct ManualSceneInputs {
    var parameters: ManualCurveParameters
    var adjustments: ManualAdjustments
    var tables: MTLBuffer?
    var base: MTLTexture?
    /// The largest gain the tables add, in stops.
    var maximumGain: Float = 0
    /// A frame's masks that change something: then the two passes take the masked kernels (`LocalMaskPipelines`), and holding this holds
    /// the coverage. `nil` takes today's kernels, whatever the edit's mask list holds.
    var masks: LocalMaskInputs?
    /// Dehaze, Clarity and Texture: their block, weights and the decode's fields, bound by every pass that maps the scene. Holding this
    /// holds their analysis.
    var presence = PresenceSceneInputs.bypass

    /// Without tone tables: `ManualRenderSettings.regionsVersion`, identity, or Exposure alone.
    init(_ manual: ManualRenderSettings, masks: LocalMaskInputs? = nil) throws {
        precondition(!manual.needsToneTables, "\(manual.version)'s tone controls need FilmRenderer's tables")
        precondition(masks != nil || !manual.hasEffectiveMasks, "a frame's masks need FilmRenderer's inputs")
        parameters = try manual.parameters
        adjustments = manual.adjustments
        self.masks = masks
    }

    init(_ manual: ManualRenderSettings, tables: ManualToneTables, buffer: MTLBuffer, base: MTLTexture?, masks: LocalMaskInputs? = nil) throws {
        precondition(!manual.needsToneBase || base != nil, "Highlights and Shadows need the local base field")
        precondition(masks != nil || !manual.hasEffectiveMasks, "a frame's masks need FilmRenderer's inputs")
        parameters = try manual.parameters(tables: tables)
        adjustments = manual.adjustments
        self.tables = buffer
        self.base = base
        maximumGain = tables.maximumGain
        self.masks = masks
    }

    /// What the kernels bind for a base field or tables they do not read.
    struct Placeholders {
        let base: MTLTexture
        let tables: MTLBuffer

        init(gpu: GPU) throws {
            base = try GPU.makeTexture(device: gpu.device, width: 1, height: 1, usage: .shaderRead, pixelFormat: .rg32Float)
            guard let buffer = gpu.device.makeBuffer(length: 2 * MemoryLayout<Float>.stride, options: .storageModeShared)
            else { throw GPUError.textureAllocation }
            tables = buffer
        }
    }
}

/// The film half of the render graph for one stock: halation, Negative LUT, capture
/// sharpening, grain, lab balance, Print LUT.
///
/// Both passes go into one command buffer per frame. The density texture between them
/// comes from the pool and returns to it as soon as the buffer has run.
public final class FilmRenderer {
    public let stock: Stock
    private let gpu: GPU
    private let negativePass: LUTPass
    private let printPass: PrintPass
    private let halationField: HalationField
    private let toneBaseField: ToneBaseField
    private let negativeTexture: MTLTexture
    private let printTexture: MTLTexture
    /// The stock's grain sigma per layer over normalized dye amounts, when it has grain.
    private let sigmaTexture: MTLTexture?
    private static let sigmaCount = 256
    /// Capture sharpening's constants: `CaptureSharpening`'s, which every render in the app uses.
    /// The measurements that choose them set others (docs/provenance.md).
    var sharpeningConstants = (sensor: CaptureSharpening.sensor, draftScaling: CaptureSharpening.draftScaling,
                               threshold: CaptureSharpening.threshold)
    /// What a gain-table Light compiler's tables depend on: the five tone controls, the reference,
    /// the compiler, the rating and the print offset. Exposure and curves do not change them.
    private struct ToneKey: Equatable {
        let values: [Float]
        let referenceStops: Float
        let version: String
        let exposureStops: Float
        let printOffset: SIMD3<Float>
    }
    private let toneLock = NSLock()
    /// The latest tables and their buffer, so a drag of Exposure or a curve, or a render of the same
    /// edit again, builds none. Command buffers retain the buffer they encode.
    private var toneCache: (key: ToneKey, tables: ManualToneTables, buffer: MTLBuffer)?
    /// What `LocalScene`'s tables depend on besides the stock: the reference, the rating and the print offset, which holds lab balance
    /// and print exposure. No slider of any mask or of the panel.
    private struct LocalTablesKey: Equatable {
        let referenceStops: Float
        let exposureStops: Float
        let printOffset: SIMD3<Float>
    }
    /// The latest masks' tables, so a slider or Amount only writes the parameter block. Built at most once a key, 182 KB and about 1 ms.
    private var localTables: (key: LocalTablesKey, tables: LocalMaskTables)?
    /// How many times this renderer has built them, to prove that a slider does not.
    private(set) var localTablesBuilt = 0
    /// The bytes the masks' tables hold on the GPU, 182 KB once a frame with masks has rendered, for the develop's memory gate.
    public var localTableBytes: Int { toneLock.withLock { localTables?.tables.buffer.length ?? 0 } }
    private struct PrintToneKey: Equatable {
        let tone: PrintTone
        let ratedAt: Float?
        let labBalance: SIMD3<Float>
        let printExposure: Float
    }
    private var printToneCache: (key: PrintToneKey, table: [SIMD4<Float>])?
    /// What Presence's tone weights depend on: the transfer's inputs and the constants' version. No slider and not Exposure.
    private struct PresenceWeightsKey: Equatable {
        let referenceStops: Float
        let exposureStops: Float
        let printOffset: SIMD3<Float>
        let version: String
    }
    /// The latest weights and their buffer, so a slider step or an Exposure drag builds none.
    private var presenceWeightsCache: (key: PresenceWeightsKey, tables: PresenceToneWeights, buffer: MTLBuffer)?
    /// How many times this renderer has built them, to prove that a step does not.
    private(set) var presenceWeightsBuilt = 0

    public init(gpu: GPU, stock: Stock) throws {
        self.gpu = gpu
        self.stock = stock
        self.negativePass = try LUTPass(gpu: gpu)
        self.printPass = try PrintPass(gpu: gpu)
        self.halationField = try HalationField(gpu: gpu)
        self.toneBaseField = try ToneBaseField(gpu: gpu)
        self.negativeTexture = try stock.negative.makeTexture(device: gpu.device)
        self.printTexture = try stock.print.makeTexture(device: gpu.device)
        try gpu.grainField.prepare(library: try gpu.shaderLibrary())
        if let grain = stock.grain {
            let texture = try gpu.makeTexture(width: Self.sigmaCount, height: 1, usage: .shaderRead)
            var values: [Float16] = []
            values.reserveCapacity(Self.sigmaCount * 4)
            for sigma in grain.sampled(count: Self.sigmaCount) {
                values += [Float16(sigma.x), Float16(sigma.y), Float16(sigma.z), Float16(1)]
            }
            values.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, Self.sigmaCount, 1), mipmapLevel: 0,
                                                     withBytes: $0.baseAddress!, bytesPerRow: Self.sigmaCount * 8) }
            sigmaTexture = texture
        } else {
            sigmaTexture = nil
        }
    }

    /// `frame` through the film with `settings`. With `inPlace` the print is written over the
    /// frame's own texture, which the Negative LUT has finished reading by then, and the frame
    /// must not be used again: a full-size develop then holds two frame-sized textures instead of
    /// three, 262 MB less at 33 MP, for the same pixels (tested; docs/M2-shell.md section 10).
    ///
    /// A smart mask's seeds come from `seeds` where given, as a develop gives what its lane loaded and checked (`MaskSeeds`), and from
    /// `GPU.maskRefiner.seeds` otherwise, as the previews set it.
    public func render(_ frame: LinearFrame, settings: DevelopSettings, inPlace: Bool = false,
                       seeds: (any MaskSeedProvider)? = nil, densities: PooledTexture? = nil) throws -> RenderedFrame {
        try render(frame, settings: settings, inPlace: inPlace, seeds: seeds, presence: nil, densities: densities)
    }

    /// The same with Presence's inputs given rather than made (`presenceInputs`): a stage package's test renders its stage with fields,
    /// weights and a block it made by hand, and nothing of another package's.
    func render(_ frame: LinearFrame, settings: DevelopSettings, inPlace: Bool = false, seeds: (any MaskSeedProvider)? = nil,
                presence given: PresenceRenderInputs?, densities: PooledTexture? = nil) throws -> RenderedFrame {
        try settings.manual.validateSupportedVersion()
        let densities = try densities.flatMap {
            $0 !== frame.image && $0.width == frame.width && $0.height == frame.height
                && $0.texture.pixelFormat == frame.texture.pixelFormat ? $0 : nil
        } ?? gpu.texturePool.acquire(width: frame.width, height: frame.height)
        let output = inPlace ? frame.image : try gpu.texturePool.acquire(width: frame.width, height: frame.height)

        var negativeParams = stock.negative.params
        negativeParams.exposureStops = settings.exposureStops(boxSpeed: stock.boxSpeed)
        var printParams = PrintParams(offset: settings.printOffset(densityRange: stock.densityRange,
                                                                   exposurePerUnit: stock.exposurePerUnit),
                                      lutSize: stock.print.size)
        // Grain at a develop's own pixel pitch, and a picture smaller than its develop with the grain of
        // that develop area-resized to it, so a picture and a long-edge develop at its size match
        // (docs/manual-development-validation.md, "Grain tolerance, 2026-10-16").
        var grain: GrainInputs?
        if settings.grain > 0, let sigmas = sigmaTexture {
            let longSide = max(frame.width, frame.height)
            let (a, b, scale) = try gpu.grainField.tiles(longSide: longSide,
                                                         developLongSide: GrainModel.developLongSide(longSide: longSide, scale: frame.scale))
            grain = GrainInputs(tileA: a, tileB: b, sigmas: sigmas)
            let seed = settings.grainSeed
            printParams.grainScale = settings.grain * GrainModel.amount * scale
            printParams.grainAX = seed % UInt32(a.width)
            printParams.grainAY = (seed / 1024) % UInt32(a.height)
            printParams.grainBX = (seed / 7) % UInt32(b.width)
            printParams.grainBY = (seed / 8191) % UInt32(b.height)
            printParams.sigmaCount = UInt32(Self.sigmaCount)
        }

        // Capture sharpening, in the print pass before grain: the sensor's mask at this decode's
        // scale against the sensor's pixels, and for a decode Apple scaled, the mask that takes
        // its scaling's blur out, so every size looks as sharp as the full-size develop resized.
        var sharpening: [Float]?
        if settings.sharpen {
            let masks = CaptureSharpening.masks(for: frame, sensor: sharpeningConstants.sensor,
                                                draftScaling: sharpeningConstants.draftScaling)
            let sensor = CaptureSharpening.kernel(sigma: masks.sensor.sigma)
            let scaling = masks.scaling.map { CaptureSharpening.kernel(sigma: $0.sigma) } ?? [1]
            if sensor.count > 1 || scaling.count > 1 {
                sharpening = sensor + scaling
                printParams.sharpenAmount = masks.sensor.amount
                printParams.sharpenRadius = UInt32(sensor.count / 2)
                printParams.scalingAmount = masks.scaling?.amount ?? 0
                printParams.scalingRadius = UInt32(scaling.count / 2)
                printParams.sharpenThreshold = sharpeningConstants.threshold
                // The luminance the mask sees: the print's Rec. 2020 luminance weights on the
                // layers each one prints through.
                let luma = Rec2020.luma
                printParams.lumaR = luma.x
                printParams.lumaG = luma.y
                printParams.lumaB = luma.z
            }
        }

        // The tone step: the Negative LUT pass, which has the frame's light, leaves each pixel's local base in the
        // density's alpha, and the print pass looks up its offset there.
        let toneTable = settings.tone.isActive ? try printToneTable(settings) : nil

        // The scene mapping: for a gain-table Light compiler's tone controls, its tables for this
        // stock and these settings, and for Highlights and Shadows the frame's local base field, at
        // low resolution and from the frame before Exposure, so preview and file agree. The field is
        // made once here and read by both the halation source and the Negative LUT pass.
        let printOffset = SIMD3(printParams.offsetR, printParams.offsetG, printParams.offsetB)
        var (scene, toneBase) = try sceneInputs(frame, settings: settings, exposureStops: negativeParams.exposureStops, seeds: seeds,
                                                printOffset: printOffset)
        // Presence's analysis is made from the untouched decode, so it is asked for before any pass writes over the frame.
        let presence = try given ?? presenceInputs(frame, settings: settings, exposureStops: negativeParams.exposureStops,
                                                   printOffset: printOffset)
        scene.presence = presence.scene

        // Halation from the frame's own light, at the field's low resolution, added before the
        // Negative LUT; the field is made from the frame whatever its size, so preview and file agree.
        var halation: PooledTexture?
        if settings.halation, let stockHalation = stock.halation {
            halation = try halationField.field(for: frame, exposureStops: negativeParams.exposureStops,
                                              halation: stockHalation, scene: scene)
        }

        guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        try negativePass.encode(input: frame.texture, output: densities.texture, lut: negativeTexture,
                            params: negativeParams, halation: halation?.texture, scene: scene, toneTable: toneTable, into: commandBuffer)
        try printPass.encode(input: densities.texture, output: output.texture, lut: printTexture,
                         params: printParams, grain: grain, sharpening: sharpening, manual: settings.manual,
                         toneTable: toneTable, presence: presence.print, into: commandBuffer)
        commandBuffer.commit()
        // The GPU reads these textures until the buffer finishes, so ARC must not hand
        // them back to the pool before then. `scene` holds a frame with masks' coverage, so a field cannot be written over under this
        // render; it lets go here (`MaskCoverage`).
        withExtendedLifetime((frame, densities, halation, toneBase, scene)) { commandBuffer.waitUntilCompleted() }
        if let error = commandBuffer.error { throw error }

        return RenderedFrame(image: output, gpuSeconds: commandBuffer.gpuEndTime - commandBuffer.gpuStartTime)
    }

    /// What the Negative LUT pass and the halation source read of the scene for `frame` under `settings`, and the base field they share.
    func sceneInputs(_ frame: LinearFrame, settings: DevelopSettings, exposureStops: Float, seeds: (any MaskSeedProvider)? = nil,
                     printOffset: SIMD3<Float>) throws -> (scene: ManualSceneInputs, base: PooledTexture?) {
        var toneBase: PooledTexture?
        if settings.manual.needsToneBase || settings.tone.isActive {
            toneBase = try toneBaseField.field(for: frame, parameters: .compiler2026_10_29_1)
        }
        let tone = try toneInputs(settings, exposureStops: exposureStops, printOffset: printOffset)
        let masks = try maskInputs(frame, settings: settings, exposureStops: exposureStops, printOffset: printOffset, seeds: seeds,
                                   tone: tone?.tables)
        var scene: ManualSceneInputs
        if let tone {
            scene = try ManualSceneInputs(settings.manual, tables: tone.tables, buffer: tone.buffer, base: toneBase?.texture, masks: masks)
        } else {
            scene = try ManualSceneInputs(settings.manual, masks: masks)
        }
        scene.base = toneBase?.texture
        return (scene, toneBase)
    }

    /// A frame's masks ready to bind, or `nil` when none changes a pixel, so the render takes today's kernels and asks for no coverage.
    /// The coverage comes from the full-size picture wherever the frame knows it, so a preview and the develop read one field. A smart
    /// selection is refined on this frame's own decode (`MaskRefiner`): tier 1 in its slice, and tier 2 per pixel where the plan's rule
    /// says (`LocalMaskInputs.refinePerPixel`). The refinement's guide frame goes when this returns. A Follow edges stroke's measured shape
    /// is read through the same session's seeds when its brush's canvas must be laid; the session makes no guide frame for it.
    private func maskInputs(_ frame: LinearFrame, settings: DevelopSettings, exposureStops: Float, printOffset: SIMD3<Float>, seeds: (any MaskSeedProvider)?,
                            tone: ManualToneTables?) throws -> LocalMaskInputs? {
        let manual = settings.manual
        guard manual.hasEffectiveMasks else { return nil }
        let masks = manual.adjustments.masks, picture = try frame.maskPicture
        let refinement = masks.masks.contains(where: { $0.readsSmartSelection || $0.readsMeasuredStroke })
            ? gpu.maskRefiner.session(for: frame, picture: picture, seeds: seeds) : nil
        guard let coverage = try gpu.maskFields.coverage(for: masks, picture: picture, lens: frame.maskLens, refinement: refinement) else { return nil }
        let tables = try localMaskTables(settings, exposureStops: exposureStops, printOffset: printOffset)
        let panel = try LocalScene.Panel(manual, tables: tone)
        var inputs = LocalMaskInputs(pipelines: try gpu.localMaskPipelines(), coverage: coverage, tables: tables.buffer,
                                     parameters: LocalMaskParameters(masks: masks, sliceCount: coverage.sliceCount, start: tables.start,
                                                                     step: tables.step, referenceOffset: tables.referenceOffset, panel: panel,
                                                                     printUnits: DevelopSettings.printUnits(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)),
                                     maximumExposure: LocalMaskBounds.maximumExposure(masks: masks.masks),
                                     maximumGain: tables.bounds.maximumGain(masks: masks.masks, panel: panel, panelGain: tone?.maximumGain ?? 0))
        if let refinement { try inputs.refinePerPixel(masks, session: refinement) }
        return inputs
    }

    /// `LocalScene`'s tables for this stock and key, built once a key, as `toneInputs` builds the panel's: under the lock, so two lanes
    /// asking for one key build it once.
    private func localMaskTables(_ settings: DevelopSettings, exposureStops: Float, printOffset: SIMD3<Float>) throws -> LocalMaskTables {
        let key = LocalTablesKey(referenceStops: settings.manual.referenceStops, exposureStops: exposureStops, printOffset: printOffset)
        toneLock.lock(); defer { toneLock.unlock() }
        if let cached = localTables, cached.key == key { return cached.tables }
        let scene = LocalScene(referenceStops: key.referenceStops, stock: stock, settings: settings)
        guard let buffer = scene.tables.withUnsafeBytes({
            gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }) else { throw GPUError.textureAllocation }
        let made = LocalMaskTables(buffer: buffer, start: scene.start, step: scene.step, referenceOffset: scene.referenceOffset, bounds: LocalMaskBounds(scene))
        localTables = (key, made)
        localTablesBuilt += 1
        return made
    }

    /// The tone step's table for `settings` on this stock, from the cache when what it depends on is unchanged, as it is
    /// when a frame is rendered again at another size.
    private func printToneTable(_ settings: DevelopSettings) throws -> [SIMD4<Float>] {
        let key = PrintToneKey(tone: settings.tone, ratedAt: settings.ratedAt, labBalance: settings.labBalance, printExposure: settings.printExposure)
        if let cached = toneLock.withLock({ printToneCache }), cached.key == key { return cached.table }
        // Solved outside the lock: 2 ms, and a renderer's lanes may each be on another frame.
        let table = try settings.tone.table(stock: stock, settings: settings)
        toneLock.withLock { printToneCache = (key, table) }
        return table
    }

    /// Presence for `settings` on `frame`: the scene inputs the Negative LUT pass and the halation source bind, and the print block.
    /// The decode's analysis comes from `gpu.presenceAnalyses`, made only at the first render that needs each part; the tone weights from
    /// `presenceWeights`, made only when what the transfer reads or the constants change. So a slider step fills two small blocks and
    /// builds nothing. `.bypass` while Presence is identity. A part not built yet stops the render with `PresenceError.notBuilt`.
    func presenceInputs(_ frame: LinearFrame, settings: DevelopSettings, exposureStops: Float,
                        printOffset: SIMD3<Float>) throws -> PresenceRenderInputs {
        let manual = settings.manual, presence = manual.adjustments.presence
        guard !presence.isIdentity else { return .bypass }
        let constants = try PresenceConstants.required(presence.version)
        var inputs = PresenceRenderInputs.bypass
        let parts = PresenceAnalysis.Parts.needed(by: presence)
        if !parts.isEmpty {
            let analysis = try gpu.presenceAnalyses.analysis(of: frame, parts: parts, constants: constants)
            let weights = parts.isDisjoint(with: [.clarity, .texture]) ? nil
                : try presenceWeights(settings, constants: constants, exposureStops: exposureStops, printOffset: printOffset)
            inputs.scene = try PresenceScene.inputs(manual, constants: constants, analysis: analysis, weights: weights)
        }
        if presence.acts(in: .print) {
            inputs.print = try PresencePrint.parameters(presence, constants: constants, stockID: stock.id)
        }
        return inputs
    }

    /// Presence's tone weights for `settings` on this stock, from the cache when the transfer's inputs and the constants are unchanged.
    func presenceWeights(_ settings: DevelopSettings, constants: PresenceConstants, exposureStops: Float,
                         printOffset: SIMD3<Float>) throws -> (tables: PresenceToneWeights, buffer: MTLBuffer) {
        let key = PresenceWeightsKey(referenceStops: settings.manual.referenceStops, exposureStops: exposureStops,
                                     printOffset: printOffset, version: constants.version)
        toneLock.lock(); defer { toneLock.unlock() }
        if let cached = presenceWeightsCache, cached.key == key { return (cached.tables, cached.buffer) }
        let tables = try PresenceToneWeights(constants: constants, referenceStops: key.referenceStops, stock: stock, settings: settings)
        guard let buffer = tables.samples.withUnsafeBytes({
            gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }) else { throw GPUError.textureAllocation }
        presenceWeightsCache = (key, tables, buffer)
        presenceWeightsBuilt += 1
        return (tables, buffer)
    }

    /// A gain-table Light compiler's tables for `settings` on this stock, from the cache when the
    /// controls they depend on are unchanged; `nil` when the render needs none.
    func toneInputs(_ settings: DevelopSettings, exposureStops: Float,
                    printOffset: SIMD3<Float>) throws -> (tables: ManualToneTables, buffer: MTLBuffer)? {
        let manual = settings.manual
        guard manual.needsToneTables else { return nil }
        let a = manual.adjustments
        let key = ToneKey(values: [a.contrast, a.highlights, a.shadows, a.whites, a.blacks],
                          referenceStops: manual.referenceStops, version: manual.version,
                          exposureStops: exposureStops, printOffset: printOffset)
        toneLock.lock(); defer { toneLock.unlock() }
        if let cached = toneCache, cached.key == key { return (cached.tables, cached.buffer) }
        guard let tables = try manual.toneTables(stock: stock, settings: settings) else { return nil }
        let values = tables.global + tables.local
        guard let buffer = values.withUnsafeBytes({
            gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }) else { throw GPUError.textureAllocation }
        toneCache = (key, tables, buffer)
        return (tables, buffer)
    }
}
