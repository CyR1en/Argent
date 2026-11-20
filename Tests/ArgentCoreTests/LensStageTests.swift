import Foundation
import Metal
import Testing
@testable import ArgentCore

@Suite struct LensStageTests {
    private func frame(_ gpu: GPU, width: Int = 19, height: Int = 13) throws -> LinearFrame {
        let image = try gpu.texturePool.acquire(width: width, height: height)
        var pixels = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = Float16(Double(x) / 32)
                pixels[i + 1] = Float16(Double(y) / 32)
                pixels[i + 2] = Float16(Double(x + y) / 64)
            }
        }
        pixels.withUnsafeBytes { image.texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                                       withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        return LinearFrame(image: image, decoderVersion: "lens-test", scale: 0.25,
                           picture: try MaskSpace(width: width * 4, height: height * 4))
    }

    private func correction(_ knots: [Double] = [1, 1.04], green: [Double]? = nil, blue: [Double]? = nil,
                            gain: [Double] = [1, 1]) throws -> ResolvedLensCorrection {
        try ResolvedLensCorrection(red: RadialTable(knots: knots), green: RadialTable(knots: green ?? knots),
                                   blue: RadialTable(knots: blue ?? knots), gain: RadialTable(knots: gain),
                                   status: .init(distortion: .file), width: 76, height: 52)
    }

    private func weights(_ t: Double) -> [Double] {
        let t2 = t * t, t3 = t2 * t
        return [-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1,
                -1.5 * t3 + 2 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2]
    }

    private func reference(_ frame: LinearFrame, _ correction: ResolvedLensCorrection) -> [Double] {
        let source = ExposureAnalyzer.pixels(of: frame.texture)
        let width = frame.width, height = frame.height
        let cx = Double(width - 1) / 2, cy = Double(height - 1) / 2
        let rMax = hypot(Double(width), Double(height)) / 2
        var out = [Double](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let vx = Double(x) - cx, vy = Double(y) - cy, t = hypot(vx, vy) / rMax
                for (ch, table) in [correction.red, correction.green, correction.blue].enumerated() {
                    let factor = table.value(at: t) / correction.scale
                    let px = cx + vx * factor, py = cy + vy * factor
                    let bx = Int(floor(px)), by = Int(floor(py))
                    let wx = weights(px - Double(bx)), wy = weights(py - Double(by))
                    var sum = 0.0, all: [Double] = [], near: [Double] = []
                    for j in 0..<4 {
                        for i in 0..<4 {
                            let sx = min(max(bx - 1 + i, 0), width - 1), sy = min(max(by - 1 + j, 0), height - 1)
                            let s = Double(source[(sy * width + sx) * 4 + ch])
                            sum += wy[j] * wx[i] * s
                            all.append(s)
                            if (1...2).contains(i) && (1...2).contains(j) { near.append(s) }
                        }
                    }
                    let lo = all.min()!, hi = all.max()!
                    let ratio = Double(LensStage.limiterRatio)
                    if hi - lo > ((ratio - 1) / (ratio + 1)) * (abs(hi) + abs(lo)) { sum = min(max(sum, near.min()!), near.max()!) }
                    out[(y * width + x) * 4 + ch] = sum * correction.gain.value(at: hypot(px - cx, py - cy) / rMax)
                }
            }
        }
        return out
    }

    private func compare(_ correction: ResolvedLensCorrection) throws {
        let gpu = try GPU(), stage = try LensStage(gpu: gpu), input = try frame(gpu)
        let expected = reference(input, correction)
        let result = try stage.correct(input, with: correction)
        let pixels = ExposureAnalyzer.pixels(of: result.texture)
        for i in pixels.indices {
            #expect(abs(Double(pixels[i]) - expected[i]) < 0.0005)
        }
        #expect(result.image !== input.image)
        #expect(result.decoderVersion == input.decoderVersion)
        #expect(result.scale == input.scale)
        #expect(result.pins == input.pins)
        #expect(result.readback == input.readback)
        #expect(result.picture == input.picture)
    }

    @Test func identityReturnsTheSameLease() throws {
        let gpu = try GPU(), stage = try LensStage(gpu: gpu), input = try frame(gpu)
        let allocations = gpu.texturePool.allocationCount
        let result = try stage.correct(input, with: .identity)
        #expect(result.image === input.image)
        #expect(gpu.texturePool.allocationCount == allocations)
        let flat = try correction([1.04, 1.04])
        #expect(flat.isIdentity)
        #expect(try stage.correct(input, with: flat).image === input.image)
    }

    @Test func radialWarpWithinOneHundredthPixel() throws {
        let gpu = try GPU(), stage = try LensStage(gpu: gpu), input = try frame(gpu)
        let map = try correction(), expected = reference(input, map)
        let result = ExposureAnalyzer.pixels(of: try stage.correct(input, with: map).texture)
        let error = stride(from: 0, to: result.count, by: 4).map { abs(Double(result[$0]) - expected[$0]) * 32 }.max()!
        #expect(error < 0.01)
    }

    @Test func differentChannelTables() throws {
        try compare(correction([1, 1.02], green: [1, 1.04], blue: [1, 1.06]))
    }

    @Test func gainAtTheSourceRadius() throws {
        try compare(correction(gain: [1, 1.5]))
    }

    @Test func offCentreStepsExerciseTheLimiter() throws {
        let gpu = try GPU(), stage = try LensStage(gpu: gpu)
        let input = try frame(gpu, width: 127, height: 95)
        var source = [Float16](repeating: 1, count: input.width * input.height * 4)
        for y in 0..<input.height {
            for x in 0..<input.width {
                let coverage = x < 29 ? 0.0 : x == 29 ? 0.953125 : 1.0
                for (ch, bright) in [1.125, 16, 4096].enumerated() {
                    source[(y * input.width + x) * 4 + ch] = Float16(1 + (bright - 1) * coverage)
                }
            }
        }
        source.withUnsafeBytes {
            input.texture.replace(region: MTLRegionMake2D(0, 0, input.width, input.height), mipmapLevel: 0,
                                  withBytes: $0.baseAddress!, bytesPerRow: input.width * 8)
        }
        let map = try correction(), expected = reference(input, map)
        let actual = ExposureAnalyzer.pixels(of: try stage.correct(input, with: map).texture)
        let red = stride(from: 0, to: actual.count, by: 4).map { actual[$0] }
        #expect(red.min()! >= Float16(1).nextDown)
        #expect(red.max()! <= Float16(1.125).nextUp)
        var largestHalfSteps = 0.0
        for i in actual.indices {
            let rounded = Float16(expected[i])
            let step = Double(rounded.nextUp - rounded)
            largestHalfSteps = max(largestHalfSteps, abs(Double(actual[i]) - expected[i]) / step)
        }
        #expect(largestHalfSteps <= 1)
    }

    @Test func bandsHaveIdenticalBytes() throws {
        let gpu = try GPU(), stage = try LensStage(gpu: gpu), input = try frame(gpu, width: 31, height: 23)
        let map = try correction([1, 1.02], green: [1, 1.04], blue: [1, 1.06], gain: [1, 1.3])
        var results: [[UInt16]] = []
        for rows in [512, 7, 1] {
            stage.bandRows = rows
            results.append(ExposureAnalyzer.pixels(of: try stage.correct(input, with: map).texture).map(\.bitPattern))
        }
        #expect(results[0] == results[1])
        #expect(results[0] == results[2])
    }

    @Test func fileKnotsLandExactlyOnSamples() throws {
        for count in [16, 11] {
            let knots = (0..<count).map { 1 + Double($0 * $0 - 3) / 16384 }
            let table = try RadialTable(knots: knots), step = RadialTable.intervals / (count - 1)
            for i in knots.indices {
                #expect(table.samples[i * step] == Float(knots[i]))
                #expect(table.value(at: Double(i * step) / Double(RadialTable.intervals)) == Double(Float(knots[i])))
            }
            #expect(table.value(at: 2) == Double(Float(knots.last!)))
        }
    }

    @Test func rejectsMalformedTables() throws {
        for knots in [[], [1], [1, 1, 1, 1, 1, 1, 1, 1], [1, .nan], [1, .infinity], [1, Double.greatestFiniteMagnitude]] {
            #expect(throws: LensCorrectionError.malformedTable) { try RadialTable(knots: knots) }
        }
    }

    @Test func rejectsFoldingAndScaleAndGain() throws {
        do {
            _ = try correction(Array(repeating: 1, count: 960) + [0.5])
            Issue.record("accepted a folded read radius")
        } catch LensCorrectionError.readRadiusFalls(let t) { #expect((0...1).contains(t)) }
        do {
            _ = try correction([1, 1.3])
            Issue.record("accepted an excessive local scale")
        } catch LensCorrectionError.localScale(let scale, let t) {
            #expect(!(0.8...1.25).contains(scale))
            #expect((0...1).contains(t))
        }
        for gain in [[0.9, 1], [1, 0], [1, -1]] {
            #expect(throws: LensCorrectionError.gain) { try correction(gain: gain) }
        }
        for scale in [0.5, 2] {
            do {
                _ = try ResolvedLensCorrection.identity.reframed(scale: scale)
                Issue.record("accepted an invalid framing scale")
            } catch LensCorrectionError.localScale { }
        }
    }

    @Test func rejectsFactorsOutsideAbsoluteBounds() throws {
        for factor in [1e-45, 0, -1, 0.499, 2.001] {
            #expect(throws: LensCorrectionError.malformedTable) {
                try correction([factor, factor], gain: [1, 2])
            }
            for channel in 0..<3 {
                var factors = [RadialTable.one, .one, .one]
                factors[channel] = try RadialTable(knots: [1, factor])
                #expect(throws: LensCorrectionError.malformedTable) {
                    try ResolvedLensCorrection(red: factors[0], green: factors[1], blue: factors[2], gain: .one,
                                               status: .init(), width: 76, height: 52)
                }
            }
        }
        for factor in [0.5, 2] {
            let map = try correction([factor, factor])
            #expect(map.isIdentity)
            #expect(try map.reframed(scale: factor) == map)
        }
    }

    @Test func rejectsFramingOutsideAbsoluteBounds() throws {
        for scale in [1e-45, 0, -1, -.infinity, .infinity, .nan, 0.499, 2.001] {
            #expect(throws: LensCorrectionError.malformedTable) {
                try ResolvedLensCorrection.identity.reframed(scale: scale)
            }
        }
    }

    @Test func rejectsGainAboveSixStops() throws {
        for gain in [[1, 64.01], [1, 65, 1]] {
            #expect(throws: LensCorrectionError.gain) { try correction(gain: gain) }
        }
        #expect(try correction(gain: [1, 64]).gain.samples.last == 64)
    }

    @Test func framingAndDigestCoverTheResolvedValue() throws {
        let map = try correction([1.03, 1.03, 1.03, 1.04, 1.02])
        #expect(map.scale == Double(Float(1.04)))
        #expect(map.digest.count == 64)
        #expect(map.digest == (try correction([1.03, 1.03, 1.03, 1.04, 1.02])).digest)
        #expect(map.digest != (try map.reframed(scale: 1.03)).digest)
        #expect(map.digest != (try correction([1.03, 1.03, 1.03, 1.04, 1.02], gain: [1, 1.1])).digest)
        let status = try ResolvedLensCorrection(red: map.red, green: map.green, blue: map.blue, gain: map.gain,
                                              status: .init(distortion: .none("missing")), width: 76, height: 52)
        #expect(status.digest != map.digest)
        #expect(ResolvedLensCorrection.identity.status == .init())
    }

    @Test func rejectsOtherPixelFormats() throws {
        let gpu = try GPU(), stage = try LensStage(gpu: gpu)
        let image = try gpu.texturePool.acquire(width: 3, height: 3, pixelFormat: .rg32Float)
        let input = LinearFrame(image: image, decoderVersion: "test", scale: 1)
        #expect(throws: NSError(domain: "LensStage", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "LensStage requires rgba16Float."])) {
            try stage.correct(input, with: correction())
        }
    }
}

extension LensStageTests {
    @Test func tagsEverySceneAndRefusesDecoderOrStageCorrectedFrames() throws {
        let gpu = try GPU(), stage = try LensStage(gpu: gpu), input = try frame(gpu)
        let scene = try stage.correct(input, with: .identity)
        #expect(scene.image === input.image && scene.lens == .identity)
        #expect(throws: LensCorrectionError.decoderCorrected) { try stage.correct(scene, with: .identity) }
        let pins = DecodePins(version: DecodePins.currentVersion, decoderVersion: "8", baselineExposure: 0, shadowBias: 0, sharpness: 0,
            boost: 0, boostShadow: 0, gamutMapping: false, highlightRecovery: true, extendedDynamicRange: 1,
            neutralChromaticity: .init(x: 0.33, y: 0.35), moireReduction: 1, contrast: 0, detail: 0,
            anchorDecodedMidTone: 0.08, anchorVersion: "1", exposureGainStops: 1, luminanceNoiseReduction: 0.4,
            colorNoiseReduction: 0.5, lensCorrection: true, scale: 1, draftMode: false)
        let decoded = LinearFrame(image: input.image, decoderVersion: "8", scale: 1, pins: pins)
        #expect(throws: LensCorrectionError.decoderCorrected) { try stage.correct(decoded, with: .identity) }
        #expect(throws: LensCorrectionError.decoderCorrected) { try stage.correct(decoded, with: correction()) }
        #expect(throws: LensCorrectionError.decoderCorrected) {
            try stage.correct(decoded, with: .uncorrected("none in the file"))
        }
        #expect(try stage.correct(input, with: correction()).lens == correction())
    }

    @Test func theDecodeCanBecomeDensitiesWithoutAnAllocationOrAChangedPixel() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0), stage = try LensStage(gpu: gpu)
        var decoded: LinearFrame! = try frame(gpu)
        weak var densities = decoded.image
        let stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                          exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let settings = DevelopSettings(printExposure: 0.3, halation: false)
        let scene = try stage.correct(decoded, with: correction())
        let expected = ExposureAnalyzer.pixels(of: try renderer.render(scene, settings: settings).image.texture)
        let before = gpu.texturePool.allocationCount
        let rendered = try renderer.render(scene, settings: settings, inPlace: true, densities: decoded.image)
        #expect(gpu.texturePool.allocationCount == before)
        decoded = nil
        // Before picture conversion, the completed render no longer owns the decode's pool lease.
        #expect(densities == nil)
        #expect(gpu.texturePool.idleCount == 0)
        #expect(ExposureAnalyzer.pixels(of: rendered.image.texture) == expected)
    }

    @Test(.enabled(if: SonyLosslessRawTests.hasSample))
    func thePipelineUsesAsManyTexturesWithTheStageAsWithNoLens() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("lc5-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: output) }
        let stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                          exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
        var counts: [Int] = []
        for enabled in [true, false] {
            let gpu = try GPU(maxIdlePoolBytes: 0)
            let pipeline = try DevelopPipeline(gpu: gpu, decoder: AppleRawDecoder(gpu: gpu), stock: stock,
                                               settings: DevelopSettings(halation: false))
            var options = DecodeOptions()
            options.maxLongSide = 320
            options.lensCorrection = enabled
            let timings = try pipeline.develop(SonyLosslessRawTests.sample, to: output, options: options)
            #expect(timings.lens != nil && timings.pins?.lensCorrection == false)
            #expect(timings.lens?.isIdentity == !enabled)
            counts.append(gpu.texturePool.allocationCount)
        }
        #expect(counts[0] == counts[1])
    }
}

extension LensStageTests {
    @Test func identityWarpStillRunsDefringeAndTagsTheScene() throws {
        let gpu = try GPU(), stage = try LensStage(gpu: gpu)
        let input = try frame(gpu, width: 127, height: 95)
        let parameters = try #require(DefringeParameters(try LensSettings.Defringe(purpleAmount: 10)))
        let correction = ResolvedLensCorrection.identity.defringing(parameters)
        let result = try stage.correct(input, with: correction)
        #expect(result.image !== input.image)
        #expect(result.lens == correction && result.lens?.isIdentity == true)
        let expected = try gpu.texturePool.acquire(width: input.width, height: input.height)
        try Defringe(gpu: gpu).repair(input.texture, into: expected.texture, with: parameters, scale: input.scale)
        #expect(ExposureAnalyzer.pixels(of: result.texture) == ExposureAnalyzer.pixels(of: expected.texture))
    }
}

extension LensStageTests {
    @Test func theReturnedDensitiesAreReleasedBeforeMakingThePictureInAllFourCases() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0), stage = try LensStage(gpu: gpu), warp = try correction()
        let parameters = try #require(DefringeParameters(try LensSettings.Defringe(purpleAmount: 10)))
        let stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                          exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        for warped in [false, true] { for repaired in [false, true] {
            var decoded: LinearFrame! = try frame(gpu, width: 127, height: 95)
            weak var densities: PooledTexture?
            let map = (warped ? warp : .identity).defringing(repaired ? parameters : nil)
            let rendered: RenderedFrame
            do {
                let (scene, spare) = try stage.correct(decoded, with: map, reusingDecode: true)
                densities = spare
                rendered = try renderer.render(scene, settings: DevelopSettings(halation: false), inPlace: true, densities: spare)
            }
            decoded = nil
            #expect(densities == nil)
            #expect(gpu.texturePool.idleCount == 0)
            #expect(ExposureAnalyzer.pixels(of: rendered.image.texture).allSatisfy { $0.isFinite })
        } }
    }
}
