import CryptoKit
import Foundation
import Metal
import Testing
@testable import ArgentCore

/// The Light mapping has one source. `manual_scene_at` keeps its text, and the two-input form Presence's Dehaze calls is made from it
/// by exact edits checked when the library is built (`ShaderSource.manualSceneOf`, `manualSceneMaskedOf`).
@Suite struct PresenceLightMappingTests {
    private static func sha256(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// `name`'s text in `source`, from its declaration to its closing brace.
    private static func function(_ name: String, in source: String) throws -> String {
        let start = try #require(source.range(of: "static inline float3 \(name)("))
        let end = try #require(source.range(of: "\n}", range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.upperBound])
    }

    /// The two one-input mappings as e33bc6f compiled them, by SHA-256 of their text: every render without Presence still compiles them.
    @Test func todaysLightMappingsKeepTheirText() throws {
        #expect(Self.sha256(try Self.function("manual_scene_at", in: ShaderSource.lut3D))
                == "55b4679af02a59aea5793ec26d52ee20dccb3d8387a8b5a2b3dd1151f2b4329d")
        #expect(Self.sha256(try Self.function("manual_scene_masked_at", in: try ShaderSource.localMaskLibrary()))
                == "461f9342f079e10118ab87252c18d1f0c78a0d5cfe1ee1ac8a75e88443514217")
        #expect(try Self.function("manual_scene_at", in: ShaderSource.lut3D) == ShaderSource.manualSceneAt)
    }

    @Test func theTwoInputFormsAreMadeFromThem() throws {
        #expect(try Self.function("manual_scene_of", in: ShaderSource.lut3D) == ShaderSource.manualSceneOf)
        #expect(try Self.function("manual_scene_masked_of", in: try ShaderSource.localMaskLibrary()) == ShaderSource.manualSceneMaskedOf)
        // Spelled out once, so a reader sees what the edits make: the light is mapped, the local base read at the untouched pixel.
        #expect(ShaderSource.manualSceneOf.contains("float3 exposed = light * p.exposureGain;"))
        #expect(ShaderSource.manualSceneOf.contains("tone_base_log2(untouched, uv, base) + p.baseOffset"))
        #expect(ShaderSource.manualSceneOf.contains("manual_table(tables, guide + p.guideOffset + local, p)"))
        #expect(ShaderSource.manualSceneMaskedOf.contains("local_coverage_at(rgb, uv, coverage"))
    }

    /// A change of the one-input text that the edits no longer find, or a new read of the untouched pixel, fails the library's build.
    @Test func aDriftedLightMappingFailsTheDerivation() {
        let reordered = ShaderSource.manualSceneAt.replacingOccurrences(of: "float3 exposed = rgb * p.exposureGain;",
                                                                         with: "float3 exposed = p.exposureGain * rgb;")
        #expect(throws: PresenceShaderError.editDidNotApply(function: "manual_scene_at", text: "float3 exposed = rgb * p.exposureGain;", count: 0)) {
            try ShaderSource.twoInputs(reordered, function: "manual_scene_at", edits: ShaderSource.manualSceneOfEdits, untouchedReads: 2)
        }
        let newRead = ShaderSource.manualSceneAt.replacingOccurrences(of: "    return exposed * exp2(local + global);",
                                                                       with: "    exposed += 0.0f * rgb;\n    return exposed * exp2(local + global);")
        #expect(throws: PresenceShaderError.untouchedReads(function: "manual_scene_at", count: 3, expected: 2)) {
            try ShaderSource.twoInputs(newRead, function: "manual_scene_at", edits: ShaderSource.manualSceneOfEdits, untouchedReads: 2)
        }
    }

    /// On the GPU, `manual_scene_of(rgb, rgb, …)` is `manual_scene_at(rgb, …)` for every recorded Light compiler, on a spread of light
    /// and a base field that varies across the frame.
    @Test func withTheSameLightTheTwoFormsAgreeOnEveryRecordedCompiler() throws {
        let gpu = try GPU()
        let stock = LightCompilerBaselineTests.toyStock()
        let settings = DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, -0.05, 0.03), printExposure: 0.3)
        let current = try [ManualAdjustments(exposureEV: 0.65, contrast: 40, highlights: -70, shadows: 55, whites: -30, blacks: 20),
                           ManualAdjustments(exposureEV: -1.5, highlights: 100, shadows: -100), ManualAdjustments(exposureEV: 2)]
            .map { try ManualRenderSettings(adjustments: $0, referenceStops: 0.4) }
        let edits = try LightCompilerBaselineTests.edits() + LightCompilerBaselineTests.exposedBaseEdits() + current
        #expect(Set(edits.map(\.version)) == [ManualRenderSettings.regionsVersion, ManualRenderSettings.exposedBaseVersion,
                                                ManualRenderSettings.currentVersion])
        let source = [ShaderSource.toneBase, ShaderSource.lut3D].joined(separator: "\n") + """

        kernel void light_pair(texture2d<float, access::sample> base [[texture(0)]], device const float *tables [[buffer(0)]],
                               constant ManualCurveParameters &p [[buffer(1)]], device const float4 *inputs [[buffer(2)]],
                               device float4 *outputs [[buffer(3)]], uint gid [[thread_position_in_grid]]) {
            float3 rgb = inputs[gid].rgb;
            float2 uv = float2(fract(float(gid) * 0.618034f), fract(float(gid) * 0.381966f));
            outputs[2 * gid] = float4(manual_scene_at(rgb, uv, base, tables, p), 0.0f);
            outputs[2 * gid + 1] = float4(manual_scene_of(rgb, rgb, uv, base, tables, p), 0.0f);
        }
        """
        let library = try gpu.device.makeLibrary(source: source, options: nil)
        let pipeline = try gpu.device.makeComputePipelineState(function: try #require(library.makeFunction(name: "light_pair")))
        let pixels = LightCompilerBaselineTests.pixels().map { SIMD4<Float>($0, 0) }
        let field = try GPU.makeTexture(device: gpu.device, width: 8, height: 6, usage: .shaderRead, pixelFormat: .rg32Float)
        let coefficients = (0..<48).flatMap { i -> [Float] in [Float(i % 8) / 8, -3 + Float(i / 8) / 2] }
        coefficients.withUnsafeBytes { field.replace(region: MTLRegionMake2D(0, 0, 8, 6), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64) }
        var compared = 0
        for manual in edits {
            let tables = try manual.toneTables(stock: stock, settings: settings)
            var p = try manual.parameters(tables: tables)
            let values = tables.map { $0.global + $0.local } ?? [0, 0]
            let tableBuffer = try #require(values.withUnsafeBytes { gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
            let input = try #require(pixels.withUnsafeBytes { gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
            let output = try #require(gpu.device.makeBuffer(length: pixels.count * 32, options: .storageModeShared))
            let commandBuffer = try #require(gpu.queue.makeCommandBuffer())
            let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(field, index: 0)
            encoder.setBuffer(tableBuffer, offset: 0, index: 0)
            encoder.setBytes(&p, length: MemoryLayout<ManualCurveParameters>.stride, index: 1)
            encoder.setBuffer(input, offset: 0, index: 2)
            encoder.setBuffer(output, offset: 0, index: 3)
            encoder.dispatchThreads(MTLSize(width: pixels.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            let results = UnsafeBufferPointer(start: output.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * pixels.count),
                                              count: 2 * pixels.count)
            for i in pixels.indices {
                let at = results[2 * i], of = results[2 * i + 1]
                #expect(at.x.bitPattern == of.x.bitPattern && at.y.bitPattern == of.y.bitPattern && at.z.bitPattern == of.z.bitPattern,
                        "\(manual.version) \(manual.adjustments) pixel \(i): \(at) against \(of)")
                compared += 1
            }
        }
        #expect(compared == edits.count * pixels.count)
    }

    /// With the light Dehaze leaves apart from the untouched pixel, the two-input form is the CPU reference's mapping of the light given
    /// the base at the untouched pixel, on every recorded compiler. On the gain-table compilers Highlights and Shadows read that base, so
    /// their result moves away from `manual_scene_at(light, …)`, whose base reads the light. `2026-10-09-1` has no base: its Highlights and
    /// Shadows weigh the mapped light's own level, so there the two-input form is `manual_scene_at(light, …)` bit for bit.
    @Test func highlightsAndShadowsReadTheUntouchedBaseWhereTheCompilerHasOne() throws {
        let gpu = try GPU()
        let pipeline = try Self.unequalPipeline(gpu)
        let stock = LightCompilerBaselineTests.toyStock()
        let settings = DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, -0.05, 0.03), printExposure: 0.3)
        let current = try [ManualAdjustments(exposureEV: 0.65, contrast: 40, highlights: -70, shadows: 55, whites: -30, blacks: 20),
                           ManualAdjustments(exposureEV: -1.5, highlights: 100, shadows: -100), ManualAdjustments(exposureEV: 2)]
            .map { try ManualRenderSettings(adjustments: $0, referenceStops: 0.4) }
        let edits = try LightCompilerBaselineTests.edits() + LightCompilerBaselineTests.exposedBaseEdits() + current
        let pixels = Self.dehazedPixels
        var readingTheBase: Set<String> = []
        for manual in edits {
            let tables = try manual.toneTables(stock: stock, settings: settings)
            let (of, atLight) = try Self.mapUnequal(manual, tables: tables, pixels: pixels, gpu: gpu, pipeline: pipeline)
            var worst: Float = 0
            for (i, pixel) in pixels.enumerated() {
                let ab = ToneBaseField.interpolated(Self.baseCoefficients, width: 8, height: 6, uv: pixel.uv)
                let base = ab.x * ManualRenderSettings.guideLog2(pixel.untouched) + ab.y
                worst = max(worst, Self.relativeDifference(of[i], try manual.applyingScene(to: pixel.light, baseLog2: base, tables: tables)))
            }
            #expect(worst < 1e-4, "\(manual.version) \(manual.adjustments): \(worst) from the CPU reference")
            if manual.version == ManualRenderSettings.regionsVersion {
                #expect(zip(of, atLight).allSatisfy { a, b in (0..<3).allSatisfy { a[$0].bitPattern == b[$0].bitPattern } },
                        "\(manual.adjustments)")
            } else if manual.needsToneBase {
                let moved = zip(of, atLight).filter { Self.relativeDifference($0, $1) > 1e-3 }.count
                #expect(moved > pixels.count / 2, "\(manual.version) \(manual.adjustments): \(moved) of \(pixels.count) moved")
                readingTheBase.insert(manual.version)
            }
        }
        #expect(readingTheBase == [ManualRenderSettings.exposedBaseVersion, ManualRenderSettings.currentVersion])
    }

    /// On `2026-10-09-1`, a neutral pixel at the reference, 0.18, that Dehaze took to 0.36, with Highlights at +100: Highlights weigh
    /// the dehazed level, a stop over the reference, for 1.5 × logistic(0) = 0.75 stops. The untouched level would give
    /// 1.5 × logistic(-0.5), about 0.566.
    @Test func onTheOldestCompilerHighlightsWeighTheDehazedLevel() throws {
        let gpu = try GPU()
        let manual = try ManualRenderSettings(adjustments: ManualAdjustments(highlights: 100), referenceStops: 0,
                                              version: ManualRenderSettings.regionsVersion)
        let pixel = (untouched: SIMD3<Float>(repeating: 0.18), light: SIMD3<Float>(repeating: 0.36), uv: SIMD2<Float>(0.5, 0.5))
        let (of, _) = try Self.mapUnequal(manual, tables: nil, pixels: [pixel], gpu: gpu, pipeline: try Self.unequalPipeline(gpu))
        #expect(abs(log2(of[0].y / 0.36) - 0.75) < 1e-5, "\(log2(of[0].y / 0.36)) stops")
    }

    /// `LightCompilerBaselineTests`' pixels as the untouched frame, each with the light a Dehaze could leave of it, `A + (I - A) G` at
    /// a gain that varies from pixel to pixel, and the uv of its place in that frame.
    private static let dehazedPixels: [(untouched: SIMD3<Float>, light: SIMD3<Float>, uv: SIMD2<Float>)] = {
        let airlight = SIMD3<Float>(0.3, 0.32, 0.36), width = LightCompilerBaselineTests.width, height = LightCompilerBaselineTests.height
        return LightCompilerBaselineTests.pixels().enumerated().map { i, rgb in
            let gain = 0.6 + 1.6 * Float(i % 11) / 10
            let uv = (SIMD2<Float>(Float(i % width), Float(i / width)) + 0.5) / SIMD2(Float(width), Float(height))
            return (untouched: rgb, light: airlight + (rgb - airlight) * gain, uv: uv)
        }
    }()

    private static let baseCoefficients = (0..<48).map { SIMD2<Float>(Float($0 % 8) / 8, -3 + Float($0 / 8) / 2) }

    private static func relativeDifference(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        (0..<3).map { abs(a[$0] - b[$0]) / max(abs(b[$0]), 1e-6) }.max()!
    }

    private static func unequalPipeline(_ gpu: GPU) throws -> MTLComputePipelineState {
        let source = [ShaderSource.toneBase, ShaderSource.lut3D].joined(separator: "\n") + """

        kernel void light_unequal(texture2d<float, access::sample> base [[texture(0)]], device const float *tables [[buffer(0)]],
                                  constant ManualCurveParameters &p [[buffer(1)]], device const float4 *untouched [[buffer(2)]],
                                  device const float4 *light [[buffer(3)]], device const float2 *uv [[buffer(4)]],
                                  device float4 *outputs [[buffer(5)]], uint gid [[thread_position_in_grid]]) {
            outputs[2 * gid] = float4(manual_scene_of(light[gid].rgb, untouched[gid].rgb, uv[gid], base, tables, p), 0.0f);
            outputs[2 * gid + 1] = float4(manual_scene_at(light[gid].rgb, uv[gid], base, tables, p), 0.0f);
        }
        """
        let library = try gpu.device.makeLibrary(source: source, options: nil)
        return try gpu.device.makeComputePipelineState(function: try #require(library.makeFunction(name: "light_unequal")))
    }

    /// `manual_scene_of(light, untouched, …)` and `manual_scene_at(light, …)` on the GPU for each pixel, with `manual`'s block and tables
    /// and `baseCoefficients` as the base field.
    private static func mapUnequal(_ manual: ManualRenderSettings, tables: ManualToneTables?,
                                   pixels: [(untouched: SIMD3<Float>, light: SIMD3<Float>, uv: SIMD2<Float>)], gpu: GPU,
                                   pipeline: MTLComputePipelineState) throws -> (of: [SIMD3<Float>], atLight: [SIMD3<Float>]) {
        func buffer<T>(_ values: [T]) throws -> MTLBuffer {
            try #require(values.withUnsafeBytes { gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
        }
        let field = try GPU.makeTexture(device: gpu.device, width: 8, height: 6, usage: .shaderRead, pixelFormat: .rg32Float)
        baseCoefficients.withUnsafeBytes { field.replace(region: MTLRegionMake2D(0, 0, 8, 6), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64) }
        var p = try manual.parameters(tables: tables)
        let inputs = try [buffer(tables.map { $0.global + $0.local } ?? [0, 0]), buffer(pixels.map { SIMD4($0.untouched, 0) }),
                          buffer(pixels.map { SIMD4($0.light, 0) }), buffer(pixels.map(\.uv))]
        let output = try #require(gpu.device.makeBuffer(length: pixels.count * 32, options: .storageModeShared))
        let commandBuffer = try #require(gpu.queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(field, index: 0)
        encoder.setBuffer(inputs[0], offset: 0, index: 0)
        encoder.setBytes(&p, length: MemoryLayout<ManualCurveParameters>.stride, index: 1)
        for (index, input) in inputs.dropFirst().enumerated() { encoder.setBuffer(input, offset: 0, index: index + 2) }
        encoder.setBuffer(output, offset: 0, index: 5)
        encoder.dispatchThreads(MTLSize(width: pixels.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(64, pixels.count), height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let results = UnsafeBufferPointer(start: output.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * pixels.count),
                                          count: 2 * pixels.count).map { SIMD3($0.x, $0.y, $0.z) }
        return (stride(from: 0, to: results.count, by: 2).map { results[$0] }, stride(from: 1, to: results.count, by: 2).map { results[$0] })
    }
}
