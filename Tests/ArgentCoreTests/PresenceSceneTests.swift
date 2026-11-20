import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Presence's scene stages with nothing of another package's: fields and tone weights made by hand for `LightCompilerBaselineTests`'
/// 64 by 48 frame, each varying across it, and a probe that runs `scene_at` and `scene_masked_at` on buffered pixels as every Negative
/// kernel and the halation source call them (`ShaderSource.sceneArguments`).
final class PresenceSceneRig {
    /// A field of coefficients (a, b) in `ToneBaseField`'s layout, and the same numbers on the CPU.
    struct Field {
        let width: Int, height: Int
        let coefficients: [SIMD2<Float>]
        let texture: MTLTexture

        func at(_ uv: SIMD2<Float>) -> SIMD2<Float> { ToneBaseField.interpolated(coefficients, width: width, height: height, uv: uv) }
    }

    static let width = LightCompilerBaselineTests.width, height = LightCompilerBaselineTests.height
    static let airlight = SIMD3<Float>(0.42, 0.45, 0.5)

    let gpu: GPU
    let constants = PresenceConstants.named(Presence.currentVersion)!
    let clarityPositive: Field, clarityNegative: Field, texture: Field, dehaze: Field
    /// The Light mapping's own base field, as `PresenceLightMappingTests` makes it.
    let base: Field
    let analysis: PresenceAnalysis
    let weights: PresenceToneWeights
    let weightBuffer: MTLBuffer
    let placeholders: ManualSceneInputs.Placeholders
    let scene: MTLComputePipelineState, masked: MTLComputePipelineState, dehazedBaseProbe: MTLComputePipelineState

    init(_ gpu: GPU) throws {
        self.gpu = gpu
        let device = gpu.device
        // Dehaze's (a, b) under log2 luminance: t's slope either way, its mean from deep haze to none, so t meets both clamps.
        dehaze = try Self.field(device, width: 10, height: 8) { u, v in
            let a = 0.06 * sin(6 * u + 3 * v), mean = 0.15 + 0.85 * (0.5 + 0.5 * cos(5 * u - 4 * v)), guide = -6 + 6 * u
            return SIMD2(a, mean - a * guide)
        }
        // Self-guided filters: base = a g + (1 - a) mu, a from flat to edge, mu across the frame's levels.
        func guided(_ phase: Float) -> (Float, Float) -> SIMD2<Float> {
            { u, v in
                let a = 0.15 + 0.8 * (0.5 + 0.5 * sin(4 * u + 7 * v + phase)), mean = -8 + 9 * (0.5 + 0.5 * cos(3 * u + 5 * v - phase))
                return SIMD2(a, (1 - a) * mean)
            }
        }
        clarityPositive = try Self.field(device, width: 12, height: 9, guided(0))
        clarityNegative = try Self.field(device, width: 12, height: 9, guided(1.3))
        texture = try Self.field(device, width: 20, height: 15, guided(2.1))
        base = try Self.field(device, width: 8, height: 6) { u, v in SIMD2((u * 8 - 0.5).rounded(.down) / 8, -3 + (v * 6 - 0.5).rounded(.down) / 2) }
        analysis = PresenceAnalysis(key: .init(decode: try LightCompilerBaselineTests.frame(gpu).maskGuide, version: constants.version),
                                    clarity: .init(positive: clarityPositive.texture, negative: clarityNegative.texture),
                                    texture: .init(coefficients: texture.texture, field: constants.texture.field(decodeLongSide: 64, fullLongSide: 7008)),
                                    haze: .init(transmission: dehaze.texture, airlight: Self.airlight))
        // Four tables unlike each other, past 3 and below 0 as the fitted weights are, over 25 stops.
        let count = PresenceToneWeights.samplesPerTable
        weights = PresenceToneWeights(start: -14, step: 0.05, tables: Dictionary(uniqueKeysWithValues: PresenceToneWeights.Table.allCases.map { table in
            let k = Float(table.rawValue)
            return (table, (0..<count).map { i in 1.2 + (0.9 + 0.3 * k) * sin(0.02 * Float(i) + k) + 0.4 * cos(0.11 * Float(i) * (1 + k)) })
        }))
        weightBuffer = try #require(weights.samples.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
        placeholders = try ManualSceneInputs.Placeholders(gpu: gpu)
        let library = try device.makeLibrary(source: try ShaderSource.localMaskLibrary() + Self.probes, options: nil)
        scene = try device.makeComputePipelineState(function: try #require(library.makeFunction(name: "presence_scene_probe")))
        masked = try device.makeComputePipelineState(function: try #require(library.makeFunction(name: "presence_scene_masked_probe")))
        dehazedBaseProbe = try device.makeComputePipelineState(function: try #require(library.makeFunction(name: "presence_dehazed_base_probe")))
    }

    /// `value(u, v)` at each texel's centre, u and v from 0 to 1 across the frame.
    static func field(_ device: MTLDevice, width: Int, height: Int, _ value: (Float, Float) -> SIMD2<Float>) throws -> Field {
        try field(device, width: width, height: height, coefficients: (0..<(width * height)).map { i in
            value((Float(i % width) + 0.5) / Float(width), (Float(i / width) + 0.5) / Float(height))
        })
    }

    /// `coefficients`, row by row, as a field.
    static func field(_ device: MTLDevice, width: Int, height: Int, coefficients: [SIMD2<Float>]) throws -> Field {
        let texture = try GPU.makeTexture(device: device, width: width, height: height, usage: .shaderRead, pixelFormat: .rg32Float)
        coefficients.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        return Field(width: width, height: height, coefficients: coefficients, texture: texture)
    }

    /// The baseline frame's pixels as its texture holds them, in half floats, each with the uv of its place.
    static let pixels = placed(LightCompilerBaselineTests.pixels(), width: width)

    /// Light that frame does not hold, the floor cases' (`PresenceSceneFitTests.floorCases`), across the frame: luminance below 0, at 0
    /// and near the floor of Dehaze's guide, where Light's guide reads another level.
    static let floorPixels = placed(PresenceSceneFitTests.floorCases.map(\.rgb), width: 8)

    /// `values` row by row as a frame of `width` holds them, in half floats, each with the uv of its place.
    static func placed(_ values: [SIMD3<Float>], width: Int) -> [(rgb: SIMD3<Float>, uv: SIMD2<Float>)] {
        let height = values.count / width
        return values.enumerated().map { i, rgb in
            (MaskRender.half(rgb), (SIMD2(Float(i % width), Float(i / width)) + 0.5) / SIMD2(Float(width), Float(height)))
        }
    }

    /// `manual` with `values` as its Presence, at the same compiler and reference.
    static func with(_ manual: ManualRenderSettings, _ values: [Presence.Control: Float]) throws -> ManualRenderSettings {
        try ManualRenderSettings(adjustments: manual.adjustments.settingPresence(try Presence(values)), referenceStops: manual.referenceStops,
                                 version: manual.version)
    }

    func inputs(_ manual: ManualRenderSettings) throws -> PresenceSceneInputs {
        try PresenceScene.inputs(manual, constants: constants, analysis: analysis, weights: (weights, weightBuffer))
    }

    /// What the GPU reads at `uv` for `inputs`: Clarity's field for the side bound.
    func sample(_ inputs: PresenceSceneInputs, at uv: SIMD2<Float>) -> PresenceScene.FieldSample {
        PresenceScene.FieldSample(clarity: inputs.clarity.map { $0 === clarityPositive.texture ? clarityPositive.at(uv) : clarityNegative.at(uv) },
                                  texture: inputs.texture.map { _ in texture.at(uv) }, dehaze: inputs.dehaze.map { _ in dehaze.at(uv) })
    }

    /// `applying` for each pixel, the Light mapping `manual`'s on the CPU with its base read at the untouched pixel from `base`, and the
    /// scale its float error has (`scale`).
    func reference(_ manual: ManualRenderSettings, tables: ManualToneTables?, inputs: PresenceSceneInputs,
                   pixels: [(rgb: SIMD3<Float>, uv: SIMD2<Float>)] = PresenceSceneRig.pixels) throws -> (values: [SIMD3<Float>], scales: [Float]) {
        try reference(inputs: inputs, pixels: pixels) { light, untouched, uv in
            let ab = self.base.at(uv)
            return try manual.applyingScene(to: light, baseLog2: ab.x * ManualRenderSettings.guideLog2(untouched) + ab.y, tables: tables)
        }
    }

    /// `applying` for each pixel with `light`, the Light mapping of the light Dehaze leaves given the untouched pixel and its uv.
    func reference(inputs: PresenceSceneInputs, pixels: [(rgb: SIMD3<Float>, uv: SIMD2<Float>)],
                   light: (SIMD3<Float>, SIMD3<Float>, SIMD2<Float>) throws -> SIMD3<Float>) throws -> (values: [SIMD3<Float>], scales: [Float]) {
        let rows = try pixels.map { pixel -> (SIMD3<Float>, Float) in
            let at = sample(inputs, at: pixel.uv)
            let value = try PresenceScene.applying(to: pixel.rgb, inputs: inputs, at: at, weights: weights) { try light($0, $1, pixel.uv) }
            let dehazed = PresenceScene.dehazed(pixel.rgb, inputs.parameters, at: at.dehaze)
            return (value, Self.scale(value, dehazed: dehazed, inputs.parameters))
        }
        return (rows.map(\.0), rows.map(\.1))
    }

    /// What a pixel's float error is measured against: its largest channel, and with Dehaze set the size of Dehaze's two terms, A and
    /// (I - A) G, which can cancel to near 0, carried through the gain the Light mapping and the detail give all three channels.
    static func scale(_ value: SIMD3<Float>, dehazed: SIMD3<Float>, _ q: PresenceSceneParameters) -> Float {
        let largest = (0..<3).map { abs(value[$0]) }.max()!
        guard q.dehaze != 0, let light = (0..<3).map({ abs(dehazed[$0]) }).max(), light > 0 else { return max(largest, 1e-6) }
        let airlight = SIMD3(q.airlightR, q.airlightG, q.airlightB)
        let terms = (0..<3).map { abs(airlight[$0]) + abs(dehazed[$0] - airlight[$0]) }.max()!
        return max(largest / light * terms, 1e-6)
    }

    /// `scene_at` on the GPU for each pixel, with `manual`'s block and tables, `base` as the Light mapping's field, and `inputs`.
    func sceneAt(_ manual: ManualRenderSettings, tables: ManualToneTables?, inputs: PresenceSceneInputs,
                 pixels: [(rgb: SIMD3<Float>, uv: SIMD2<Float>)] = PresenceSceneRig.pixels) throws -> [SIMD3<Float>] {
        var p = try manual.parameters(tables: tables)
        let values = try buffer(tables.map { $0.global + $0.local } ?? [0, 0])
        return try run(scene, pixels: pixels, outputs: 1) { encoder in
            encoder.setTexture(self.base.texture, index: 0)
            encoder.setBuffer(values, offset: 0, index: 0)
            encoder.setBytes(&p, length: MemoryLayout<ManualCurveParameters>.stride, index: 1)
            inputs.bind(to: encoder, placeholders: self.placeholders)
        }
    }

    /// `scene_at` for each pixel bound as a render's Negative pass binds `scene` and `inputs`.
    func sceneAt(_ scene: ManualSceneInputs, inputs: PresenceSceneInputs, pixels: [(rgb: SIMD3<Float>, uv: SIMD2<Float>)]) throws -> [SIMD3<Float>] {
        var p = scene.parameters
        return try run(self.scene, pixels: pixels, outputs: 1) { encoder in
            encoder.setTexture(scene.base ?? self.placeholders.base, index: 0)
            encoder.setBuffer(scene.tables ?? self.placeholders.tables, offset: 0, index: 0)
            encoder.setBytes(&p, length: MemoryLayout<ManualCurveParameters>.stride, index: 1)
            inputs.bind(to: encoder, placeholders: self.placeholders)
        }
    }

    /// For each pixel: `scene_masked_at`, the light Dehaze leaves (`presence_dehaze`), and `manual_scene_masked_at` of that light, whose
    /// coverage and base read the dehazed light rather than the untouched pixel. `scene` binds as a render's Negative pass does.
    func maskedAt(_ scene: ManualSceneInputs, inputs: PresenceSceneInputs,
                  pixels: [(rgb: SIMD3<Float>, uv: SIMD2<Float>)]) throws -> (scene: [SIMD3<Float>], dehazed: [SIMD3<Float>], atDehazed: [SIMD3<Float>]) {
        var p = scene.parameters
        let masks = try #require(scene.masks)
        let out = try run(masked, pixels: pixels, outputs: 3) { encoder in
            encoder.setTexture(scene.base ?? self.placeholders.base, index: 0)
            encoder.setBuffer(scene.tables ?? self.placeholders.tables, offset: 0, index: 0)
            encoder.setBytes(&p, length: MemoryLayout<ManualCurveParameters>.stride, index: 1)
            masks.bind(to: encoder)
            inputs.bind(to: encoder, placeholders: self.placeholders)
        }
        return (stride(from: 0, to: out.count, by: 3).map { out[$0] }, stride(from: 1, to: out.count, by: 3).map { out[$0] },
                stride(from: 2, to: out.count, by: 3).map { out[$0] })
    }

    /// `presence_dehazed_base` on the GPU for each base at its uv, with `inputs` bound as a render's Negative pass binds them.
    func dehazedBase(_ inputs: PresenceSceneInputs, bases: [(base: Float, uv: SIMD2<Float>)]) throws -> [Float] {
        try run(dehazedBaseProbe, pixels: bases.map { (SIMD3($0.base, 0, 0), $0.uv) }, outputs: 1) { encoder in
            inputs.bind(to: encoder, placeholders: self.placeholders)
        }.map(\.x)
    }

    func buffer<T>(_ values: [T]) throws -> MTLBuffer {
        try #require(values.withUnsafeBytes { gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
    }

    private func run(_ pipeline: MTLComputePipelineState, pixels: [(rgb: SIMD3<Float>, uv: SIMD2<Float>)], outputs: Int,
                     bind: (MTLComputeCommandEncoder) throws -> Void) throws -> [SIMD3<Float>] {
        let input = try buffer(pixels.map { SIMD4($0.rgb, 0) }), uvs = try buffer(pixels.map(\.uv))
        let output = try #require(gpu.device.makeBuffer(length: pixels.count * outputs * 16, options: .storageModeShared))
        let commandBuffer = try #require(gpu.queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        try bind(encoder)
        encoder.setBuffer(input, offset: 0, index: 2)
        encoder.setBuffer(uvs, offset: 0, index: 3)
        encoder.setBuffer(output, offset: 0, index: 4)
        encoder.dispatchThreads(MTLSize(width: pixels.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(64, pixels.count), height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return UnsafeBufferPointer(start: output.contents().bindMemory(to: SIMD4<Float>.self, capacity: pixels.count * outputs),
                                   count: pixels.count * outputs).map { SIMD3($0.x, $0.y, $0.z) }
    }

    /// The probes, after the masked library, which holds `lut3D`'s functions and the masked mapping's.
    static let probes = """

    kernel void presence_scene_probe(texture2d<float, access::sample> toneBase [[texture(0)]],
                                     device const float *toneTables [[buffer(0)]], constant ManualCurveParameters &manual [[buffer(1)]],
                                     device const float4 *pixels [[buffer(2)]], device const float2 *uvs [[buffer(3)]],
                                     device float4 *out [[buffer(4)]],
                                     \(ShaderSource.presenceSceneSignature)
                                     uint gid [[thread_position_in_grid]]) {
        float2 uv = uvs[gid];
        out[gid] = float4(scene_at(pixels[gid].rgb, \(ShaderSource.sceneArguments)), 0.0f);
    }

    kernel void presence_scene_masked_probe(texture2d<float, access::sample> toneBase [[texture(0)]],
                                            device const float *toneTables [[buffer(0)]], constant ManualCurveParameters &manual [[buffer(1)]],
                                            device const float4 *pixels [[buffer(2)]], device const float2 *uvs [[buffer(3)]],
                                            device float4 *out [[buffer(4)]],
                                            texture2d_array<float, access::sample> maskCoverage [[texture(5)]],
                                            device const float *maskTables [[buffer(5)]], constant LocalMaskParameters &masks [[buffer(6)]],
                                            constant LocalMaskRefinement &maskRefinement [[buffer(7)]],
                                            texture2d<float, access::sample> maskRefined0 [[texture(6)]],
                                            texture2d<float, access::sample> maskRefined1 [[texture(7)]],
                                            texture2d<float, access::sample> maskRefined2 [[texture(8)]],
                                            texture2d<float, access::sample> maskRefined3 [[texture(9)]],
                                            \(ShaderSource.presenceSceneSignature)
                                            uint gid [[thread_position_in_grid]]) {
        float2 uv = uvs[gid];
        float3 rgb = pixels[gid].rgb;
        out[3 * gid] = float4(scene_masked_at(rgb, \(ShaderSource.sceneArguments), maskCoverage, maskTables, masks, maskRefinement,
                                              maskRefined0, maskRefined1, maskRefined2, maskRefined3), 0.0f);
        float3 dehazed = presence_dehaze(rgb, manual_guide(rgb), uv, presence, dehazeField);
        out[3 * gid + 1] = float4(dehazed, 0.0f);
        out[3 * gid + 2] = float4(manual_scene_masked_at(dehazed, uv, toneBase, toneTables, manual, maskCoverage, maskTables, masks,
                                                         maskRefinement, maskRefined0, maskRefined1, maskRefined2, maskRefined3), 0.0f);
    }

    kernel void presence_dehazed_base_probe(device const float4 *bases [[buffer(2)]], device const float2 *uvs [[buffer(3)]],
                                            device float4 *out [[buffer(4)]],
                                            \(ShaderSource.presenceSceneSignature)
                                            uint gid [[thread_position_in_grid]]) {
        out[gid] = float4(presence_dehazed_base(bases[gid].x, uvs[gid], presence, dehazeField), 0.0f, 0.0f, 0.0f);
    }

    """

    /// The worst difference of `a` from `b` over the pixels, each against its scale.
    static func worst(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>], scales: [Float]) -> (difference: Float, pixel: Int) {
        zip(a, b).enumerated().reduce((0, -1)) { worst, item in
            let (i, (x, y)) = item
            let d = (0..<3).map { abs(x[$0] - y[$0]) }.max()! / scales[i]
            return d > worst.0 || d.isNaN ? (d, i) : worst
        }
    }
}

/// The risk the plan names first: the stages composed with every recorded Light compiler and with masks, the GPU against `applying`.
@Suite struct PresenceSceneCompositionTests {
    /// Every recorded compiler's edits, as `PresenceLightMappingTests` has them.
    static func compilers() throws -> [ManualRenderSettings] {
        let current = try [ManualAdjustments(exposureEV: 0.65, contrast: 40, highlights: -70, shadows: 55, whites: -30, blacks: 20),
                           ManualAdjustments(exposureEV: -1.5, highlights: 100, shadows: -100), ManualAdjustments(exposureEV: 2), .identity]
            .map { try ManualRenderSettings(adjustments: $0, referenceStops: 0.4) }
        return try LightCompilerBaselineTests.edits() + LightCompilerBaselineTests.exposedBaseEdits() + current
    }

    /// Each control at both signs, at a knot and between knots, and the three together.
    static let cases: [[Presence.Control: Float]] = [
        [.dehaze: 100], [.dehaze: 40], [.dehaze: -100], [.dehaze: -63],
        [.clarity: 100], [.clarity: -60], [.texture: 70], [.texture: -100],
        [.dehaze: 60, .clarity: -40, .texture: 100], [.dehaze: -30, .clarity: 85, .texture: -45],
    ]

    @Test func theKernelIsTheReferenceOnEveryCompilerForEachControlAndSign() throws {
        let rig = try PresenceSceneRig(try GPU())
        let stock = LightCompilerBaselineTests.toyStock()
        let settings = DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, -0.05, 0.03), printExposure: 0.3)
        let pixels = PresenceSceneRig.pixels + PresenceSceneRig.floorPixels
        var compared = 0, worstOverall: Float = 0
        for light in try Self.compilers() {
            let tables = try light.toneTables(stock: stock, settings: settings)
            for values in Self.cases {
                let manual = try PresenceSceneRig.with(light, values)
                let inputs = try rig.inputs(manual)
                let gpu = try rig.sceneAt(manual, tables: tables, inputs: inputs, pixels: pixels)
                let (cpu, scales) = try rig.reference(manual, tables: tables, inputs: inputs, pixels: pixels)
                let (worst, pixel) = PresenceSceneRig.worst(gpu, cpu, scales: scales)
                worstOverall = max(worstOverall, worst)
                #expect(worst < 1e-4, "\(light.version) \(light.adjustments) \(values): \(worst) at pixel \(pixel), \(gpu[max(pixel, 0)]) against \(cpu[max(pixel, 0)])")
                compared += gpu.count
            }
        }
        MaskRender.report("scene_at against applying: \(compared) pixels, worst \(worstOverall) of the pixel's scale")
        #expect(compared == (try Self.compilers()).count * Self.cases.count * pixels.count)
    }

    /// The masked Light mapping with the stages round it: two masks over the whole frame, so each pixel's coverage is 1 and `LocalScene`
    /// is the reference, on the current compiler, the only one masks render with.
    @Test func theMaskedKernelIsTheReferenceForEachControlAndSign() throws {
        let gpu = try GPU()
        let rig = try PresenceSceneRig(gpu)
        let stock = LightCompilerBaselineTests.toyStock()
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let frame = try LightCompilerBaselineTests.frame(gpu)
        let masks = [MaskRender.mask(MaskRender.everywhere, try ManualAdjustments(exposureEV: 1, highlights: -60, shadows: 30)),
                     MaskRender.mask(MaskRender.everywhere, try ManualAdjustments(contrast: 50, whites: -40, blacks: 25), amount: 0.7)]
        var sliders = LocalSliders.zero
        for mask in masks {
            let a = mask.adjustments
            sliders.add(LocalSliders(exposureEV: a.exposureEV, contrast: a.contrast, highlights: a.highlights, shadows: a.shadows, whites: a.whites,
                                     blacks: a.blacks), coverage: 1, amount: mask.amount)
        }
        var compared = 0, worstOverall: Float = 0
        for values in Self.cases {
            let manual = try PresenceSceneRig.with(try MaskRender.manual(try ManualAdjustments(exposureEV: 0.3, highlights: -40, shadows: 55),
                                                                         masks: masks, reference: 0.4), values)
            var settings = DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, -0.05, 0.03), printExposure: 0.3)
            settings.manual = manual
            let (scene, base) = try renderer.sceneInputs(frame, settings: settings, exposureStops: settings.exposureStops(boxSpeed: stock.boxSpeed),
                                                         printOffset: settings.printOffset(densityRange: stock.densityRange,
                                                                                           exposurePerUnit: stock.exposurePerUnit))
            let field = try #require(base)
            let coefficients = ToneBaseField.coefficients(of: field)
            let tables = try manual.toneTables(stock: stock, settings: settings)
            let local = LocalScene(referenceStops: manual.referenceStops, stock: stock, settings: settings)
            let panel = try LocalScene.Panel(manual, tables: tables)
            let inputs = try rig.inputs(manual)
            let pixels = PresenceSceneRig.pixels + PresenceSceneRig.floorPixels
            let gpu = try rig.maskedAt(scene, inputs: inputs, pixels: pixels).scene
            let (cpu, scales) = try rig.reference(inputs: inputs, pixels: pixels) { light, untouched, uv in
                let ab = ToneBaseField.interpolated(coefficients, width: field.width, height: field.height, uv: uv)
                return local.applying(to: light, baseLog2: ab.x * ManualRenderSettings.guideLog2(untouched) + ab.y, sliders: sliders, panel: panel)
            }
            let (worst, pixel) = PresenceSceneRig.worst(gpu, cpu, scales: scales)
            worstOverall = max(worstOverall, worst)
            #expect(worst < 1e-4, "\(values): \(worst) at pixel \(pixel), \(gpu[max(pixel, 0)]) against \(cpu[max(pixel, 0)])")
            compared += gpu.count
        }
        MaskRender.report("scene_masked_at against applying: \(compared) pixels, worst \(worstOverall) of the pixel's scale")
    }
}

/// What `PresenceScene.inputs` binds and how far it lets the stages raise light.
@Suite struct PresenceSceneInputsTests {
    @Test func nothingOnTheSceneSideIsTheBypass() throws {
        let rig = try PresenceSceneRig(try GPU())
        for values: [Presence.Control: Float] in [[:], [.saturation: 40], [.vibrance: -100, .saturation: 20]] {
            let inputs = try rig.inputs(try PresenceSceneRig.with(.identity, values))
            #expect(inputs.parameters.active == 0 && inputs.maximumGainStops == 0 && inputs.analysis == nil, "\(values)")
            #expect(inputs.weights == nil && inputs.clarity == nil && inputs.texture == nil && inputs.dehaze == nil, "\(values)")
        }
    }

    /// A slider step, a sign crossing zero and a second control bind what the analysis and the weights already hold: the sign picks
    /// Clarity's field and each side's table, and a stage left at 0 binds nothing of its own.
    @Test func eachStepBindsWhatTheAnalysisAndTheWeightsHold() throws {
        let rig = try PresenceSceneRig(try GPU())
        let light = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 0.5), referenceStops: 0.3)
        for clarity: Float in [30, 31, 100, -1, -100] {
            let inputs = try rig.inputs(try PresenceSceneRig.with(light, [.clarity: clarity]))
            let side: PresenceToneWeights.Table = clarity > 0 ? .clarityPositive : .clarityNegative
            #expect(inputs.clarity === (clarity > 0 ? rig.clarityPositive.texture : rig.clarityNegative.texture))
            #expect(inputs.parameters.clarityWeights == UInt32(rig.weights.offset(of: side)))
            #expect(inputs.weights === rig.weightBuffer && inputs.analysis === rig.analysis)
            #expect(inputs.texture == nil && inputs.dehaze == nil && inputs.parameters.textureStrength == 0 && inputs.parameters.dehaze == 0)
            #expect(inputs.parameters.clarityStrength.sign == (clarity > 0 ? .plus : .minus))
        }
        for texture: Float in [12, -12] {
            let inputs = try rig.inputs(try PresenceSceneRig.with(light, [.texture: texture, .dehaze: -20]))
            #expect(inputs.texture === rig.texture.texture && inputs.dehaze === rig.dehaze.texture && inputs.clarity == nil)
            #expect(inputs.parameters.textureWeights == UInt32(rig.weights.offset(of: texture > 0 ? .texturePositive : .textureNegative)))
            #expect(inputs.parameters.clarityStrength == 0 && inputs.parameters.dehaze == 2)
        }
        let dehaze = try rig.inputs(try PresenceSceneRig.with(light, [.dehaze: 55]))
        #expect(dehaze.weights == nil && dehaze.clarity == nil && dehaze.texture == nil && dehaze.dehaze === rig.dehaze.texture)
    }

    /// The tone weights are read at the base's stops from the reference after Exposure, as the Light tables' are, so moving Exposure or
    /// the reference moves where they are read and builds nothing.
    @Test func theWeightsAreReadAfterExposureFromTheReference() throws {
        let rig = try PresenceSceneRig(try GPU())
        for (exposure, reference) in [(Float(0), Float(0)), (1.5, 0), (-2, 0.7), (0.25, -1.1)] {
            let light = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: exposure), referenceStops: reference)
            let manual = try PresenceSceneRig.with(light, [.texture: 40])
            let q = try rig.inputs(manual).parameters
            #expect(q.weightOffset == (try manual.parameters).guideOffset, "\(exposure) \(reference)")
            #expect(abs(q.weightOffset - (exposure + reference - log2(Float(0.18)))) < 1e-6)
            #expect(q.weightStart == rig.weights.start && q.weightScale == 1 / rig.weights.step)
            #expect(q.weightCount == UInt32(PresenceToneWeights.samplesPerTable) && q.detailLimit == rig.constants.detailLimitStops)
        }
    }

    /// The halation source's storage scale adds `maximumGainStops`, so every pixel the stages map stays within the brighter of its own
    /// light and the airlight times that scale: Dehaze's largest gain, `t^-kappa` at the least transmission, and the detail's limit. On
    /// every compiler, each control and sign.
    @Test func theHalationStoreHoldsWhatTheStagesMake() throws {
        let rig = try PresenceSceneRig(try GPU())
        let stock = LightCompilerBaselineTests.toyStock()
        let settings = DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, -0.05, 0.03), printExposure: 0.3)
        var closest: Float = 0
        for light in try PresenceSceneCompositionTests.compilers() {
            let tables = try light.toneTables(stock: stock, settings: settings)
            let buffer = try rig.buffer(tables.map { $0.global + $0.local } ?? [0, 0])
            for values in PresenceSceneCompositionTests.cases {
                let manual = try PresenceSceneRig.with(light, values)
                var scene = try tables.map { try ManualSceneInputs(manual, tables: $0, buffer: buffer, base: rig.base.texture) } ?? ManualSceneInputs(manual)
                scene.presence = try rig.inputs(manual)
                let q = scene.presence.parameters
                let kappa = values[.dehaze].map { $0 > 0 ? rig.constants.dehaze.kappa.at($0) : 0 } ?? 0
                let detail = values[.clarity] != nil || values[.texture] != nil ? rig.constants.detailLimitStops : 0
                #expect(abs(scene.presence.maximumGainStops - (kappa * -log2(rig.constants.dehaze.minimumTransmission) + detail)) < 1e-5)
                let room = exp2(HalationField.storageStops(exposureStops: 0, scene: scene))
                let out = try rig.sceneAt(manual, tables: tables, inputs: scene.presence)
                for (pixel, value) in zip(PresenceSceneRig.pixels, out) {
                    let level = max(pixel.rgb.max(), q.dehaze == 0 ? 0 : max(q.airlightR, q.airlightG, q.airlightB))
                    closest = max(closest, value.max() / (level * room))
                    #expect(value.max() <= level * room * 1.0001, "\(light.version) \(values) \(pixel.rgb): \(value)")
                }
            }
        }
        MaskRender.report("the stages' light against the halation store's room: at most \(closest) of it")
    }
}

/// With Dehaze set, Highlights and Shadows read their base from the untouched frame on the gain-table compilers and weigh the dehazed
/// pixel's own level on `2026-10-09-1`, which has no base (plan section 2, Dehaze): through `scene_at` and in `applying`.
@Suite struct PresenceSceneHighlightsAndShadowsTests {
    @Test func theGainTableCompilersReadTheUntouchedBaseAndTheOldestWeighsTheDehazedPixel() throws {
        let rig = try PresenceSceneRig(try GPU())
        let stock = LightCompilerBaselineTests.toyStock()
        let settings = DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, -0.05, 0.03), printExposure: 0.3)
        let edits = try PresenceSceneCompositionTests.compilers().filter { $0.adjustments.highlights != 0 || $0.adjustments.shadows != 0 }
        var readers: Set<String> = []
        for light in edits {
            let tables = try light.toneTables(stock: stock, settings: settings)
            for value: Float in [100, -100] {
                let manual = try PresenceSceneRig.with(light, [.dehaze: value])
                let inputs = try rig.inputs(manual)
                let gpu = try rig.sceneAt(manual, tables: tables, inputs: inputs)
                let (untouched, scales) = try rig.reference(manual, tables: tables, inputs: inputs)
                #expect(PresenceSceneRig.worst(gpu, untouched, scales: scales).difference < 1e-4, "\(manual.version) \(light.adjustments) \(value)")
                // The reading the compiler does not take: the base at the dehazed light, or the untouched pixel's level for the oldest.
                let other = try rig.reference(inputs: inputs, pixels: PresenceSceneRig.pixels) { light, untouched, uv in
                    if manual.version == ManualRenderSettings.regionsVersion {
                        let level = ManualRenderSettings.luminance(untouched)
                        guard level > 0 else { return light }
                        return light * (try manual.applyingScene(to: SIMD3(repeating: level)).x / level)
                    }
                    let ab = rig.base.at(uv)
                    return try manual.applyingScene(to: light, baseLog2: ab.x * ManualRenderSettings.guideLog2(light) + ab.y, tables: tables)
                }.values
                let moved = zip(gpu, zip(other, scales)).filter { a, b in (0..<3).map { abs(a[$0] - b.0[$0]) }.max()! > 1e-3 * b.1 }.count
                #expect(moved > PresenceSceneRig.pixels.count / 4, "\(manual.version) \(light.adjustments) \(value): \(moved) moved")
                readers.insert(manual.version)
            }
        }
        #expect(readers == [ManualRenderSettings.regionsVersion, ManualRenderSettings.exposedBaseVersion, ManualRenderSettings.currentVersion])
    }

    /// Auto's tone step reads the untouched base through Dehaze's map, and Highlights and Shadows do not: on the gain-table compilers
    /// `scene_at` is the reference given the untouched base, and given the tone step's base (`PresenceScene.dehazedBase`) it would move.
    @Test func theToneStepsDehazedBaseDoesNotReachHighlightsAndShadows() throws {
        let rig = try PresenceSceneRig(try GPU())
        let stock = LightCompilerBaselineTests.toyStock()
        let settings = DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, -0.05, 0.03), printExposure: 0.3)
        let edits = try PresenceSceneCompositionTests.compilers().filter { $0.needsToneBase && ($0.adjustments.highlights != 0 || $0.adjustments.shadows != 0) }
        var readers: Set<String> = []
        for light in edits {
            let tables = try light.toneTables(stock: stock, settings: settings)
            for value: Float in [100, -100] {
                let manual = try PresenceSceneRig.with(light, [.dehaze: value])
                let inputs = try rig.inputs(manual)
                let gpu = try rig.sceneAt(manual, tables: tables, inputs: inputs)
                let (untouched, scales) = try rig.reference(manual, tables: tables, inputs: inputs)
                #expect(PresenceSceneRig.worst(gpu, untouched, scales: scales).difference < 1e-4, "\(manual.version) \(light.adjustments) \(value)")
                let toneSteps = try rig.reference(inputs: inputs, pixels: PresenceSceneRig.pixels) { light, untouched, uv in
                    let ab = rig.base.at(uv)
                    let base = PresenceScene.dehazedBase(ab.x * ManualRenderSettings.guideLog2(untouched) + ab.y, inputs.parameters, at: rig.dehaze.at(uv))
                    return try manual.applyingScene(to: light, baseLog2: base, tables: tables)
                }.values
                let moved = zip(gpu, zip(toneSteps, scales)).filter { a, b in (0..<3).map { abs(a[$0] - b.0[$0]) }.max()! > 1e-3 * b.1 }.count
                #expect(moved > PresenceSceneRig.pixels.count / 4, "\(manual.version) \(light.adjustments) \(value): \(moved) moved")
                readers.insert(manual.version)
            }
        }
        #expect(readers == [ManualRenderSettings.exposedBaseVersion, ManualRenderSettings.currentVersion])
    }
}
