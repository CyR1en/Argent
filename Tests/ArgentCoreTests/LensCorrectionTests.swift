import Foundation
import Metal
import Testing
@testable import ArgentCore

/// The file's lens corrections and the in-house decoder's distortion correction
/// (docs/decoder.md, section 13).
@Suite(.serialized) struct LensCorrectionTests {
    /// The CC0 sample's distortion curve (FE 50mm F2.5 G at f/5.6): it rises to 37 and ends at 36.
    static let sampleCurve = SonyLensCorrection.Curve(knots: [-2, 0, 3, 5, 9, 13, 17, 22, 26, 30, 33, 35, 37, 37, 37, 36])
    /// Made-up curves of the two kinds that matter: one rising past its corner value and falling
    /// back, so the corner's factor is not the largest, and a strong barrel lens's falling one.
    static let peaked = SonyLensCorrection.Curve(knots: [0, 2, 8, 18, 31, 47, 64, 82, 99, 114, 126, 134, 138, 136, 126, 108])
    static let barrel = SonyLensCorrection.Curve(knots: (0..<16).map { -2 * $0 * $0 })

    // MARK: The tags

    /// Every curve and setting comes out of the raw IFD, full frame and APS-C; a curve whose count
    /// does not fit its tag is left out without refusing the file.
    @Test func readsTheTags() throws {
        let shading: [Int16] = [16, 0, 0, 128, 416, 800, 1248, 1760, 2304, 2848, 3424, 4000, 4544, 5312, 6496, 8288, 9856]
        let colour: [Int16] = [32] + (0..<16).map { Int16(-128 * ($0 / 4)) } + (0..<16).map { Int16(128 * ($0 / 5)) }
        let distortion: [Int16] = [16] + Self.sampleCurve.knots.map(Int16.init)
        let tiles = (0..<6).map { syntheticTile($0 % 3, $0 / 3) }
        let overrides: [(UInt16, TIFFBuilder.Value)] = [
            (0x7031, .signedShort([272])), (0x7032, .signedShort(shading)), (0x7034, .signedShort([1])),
            (0x7035, .signedShort(colour)), (0x7036, .signedShort([17])), (0x7037, .signedShort(distortion)),
        ]
        let url = try temporaryRaw(syntheticLosslessFile(across: 3, down: 2, tiles: tiles, overrides: overrides))
        defer { try? FileManager.default.removeItem(at: url) }
        let lens = try #require(try SonyLosslessRaw.read(from: url).lens)
        #expect(lens == SonyLensCorrection.read(from: url))
        #expect(lens.shadingSetting == 272 && lens.shading?.knots == shading.dropFirst().map(Int.init))
        #expect(lens.lateralColourSetting == 1)
        #expect(lens.red?.knots == colour[1...16].map(Int.init) && lens.blue?.knots == colour[17...32].map(Int.init))
        #expect(lens.distortionSetting == 17 && lens.distortion == Self.sampleCurve && lens.correctsDistortion)

        // APS-C crop mode: 11 knots, the rest of the tag zero; the colour tag's count is both halves.
        let crop: [Int16] = [11] + Self.sampleCurve.knots.prefix(11).map(Int16.init) + [0, 0, 0, 0, 0]
        let cropColour: [Int16] = [22] + (0..<22).map { Int16($0 < 11 ? -128 : 256) } + [Int16](repeating: 0, count: 10)
        let malformed: [Int16] = [20] + [Int16](repeating: 5, count: 16)
        let other = try temporaryRaw(syntheticLosslessFile(across: 3, down: 2, tiles: tiles, overrides: [
            (0x7036, .signedShort([0])), (0x7037, .signedShort(crop)), (0x7035, .signedShort(cropColour)),
            (0x7032, .signedShort(malformed)),
        ]))
        defer { try? FileManager.default.removeItem(at: other) }
        let apsc = try #require(SonyLensCorrection.read(from: other))
        #expect(apsc.distortion?.knots == Array(Self.sampleCurve.knots.prefix(11)) && !apsc.correctsDistortion)
        #expect(apsc.red?.knots == [Int](repeating: -128, count: 11) && apsc.blue?.knots == [Int](repeating: 256, count: 11))
        #expect(apsc.shading == nil && apsc.shadingSetting == nil)

        // A curve past half the radius, or stored unsigned, is not Sony's: left out.
        let folded: [Int16] = [16] + (0..<16).map { Int16($0 == 15 ? -9000 : -$0) }
        let odd = try temporaryRaw(syntheticLosslessFile(across: 3, down: 2, tiles: tiles, overrides: [
            (0x7036, .signedShort([17])), (0x7037, .signedShort(folded)), (0x7032, .short([16] + [UInt16](repeating: 40000, count: 16))),
            (0x7034, .short([1])),
        ]))
        defer { try? FileManager.default.removeItem(at: odd) }
        let rejected = try #require(SonyLensCorrection.read(from: odd))
        #expect(rejected.distortion == nil && rejected.distortionSetting == 17 && rejected.shading == nil)
        #expect(rejected.lateralColourSetting == 1)

        // A file without the tags has no lens data.
        let bare = try temporaryRaw(syntheticLosslessFile(across: 3, down: 2, tiles: tiles))
        defer { try? FileManager.default.removeItem(at: bare) }
        #expect(try SonyLosslessRaw.read(from: bare).lens == nil)
    }

    /// The CC0 sample's own corrections, as the camera wrote them.
    @Test(.enabled(if: SonyLosslessRawTests.hasSample))
    func readsTheSample() throws {
        let lens = try #require(try SonyLosslessRaw.read(from: SonyLosslessRawTests.sample).lens)
        #expect(lens.distortionSetting == 17 && lens.distortion == Self.sampleCurve)
        #expect(lens.shadingSetting == 272 && lens.shading?.knots.last == 9856)
        #expect(lens.lateralColourSetting == 1 && lens.red?.knots.count == 16 && lens.blue?.knots.last == -384)
    }

    // MARK: The plan

    /// Linear between knots, from the centre to the corner.
    @Test func interpolatesTheCurve() {
        #expect(Self.sampleCurve.value(at: 0) == -2 && Self.sampleCurve.value(at: 1) == 36)
        #expect(Self.sampleCurve.value(at: 6.5 / 15) == 19.5)
        #expect(Self.sampleCurve.value(at: 2) == 36 && Self.sampleCurve.value(at: -1) == -2)
    }

    /// Divided by the factor at the corner, as Apple's decoder divides it: the frame's corners stay
    /// put and points inside move by the curve's difference from it, out where it is smaller.
    @Test func keepsTheCornersWhereAppleDoes() throws {
        for curve in [Self.sampleCurve, Self.peaked] {
            let warp = try #require(LensWarp.plan(curve, width: 7008, height: 4672, margin: (12, 8)))
            #expect(warp.scale == 1 + Double(curve.knots.last!) / 16384)
            let corner = warp.source(x: -0.5, y: -0.5)
            #expect(abs(corner.x + 0.5) < 1e-9 && abs(corner.y + 0.5) < 1e-9)
            // Half way out along the diagonal the curve is below the corner's, so the corrected
            // picture there reads nearer the centre: what was there moves out.
            let t = 0.5, inner = warp.source(x: warp.centreX - t * 3504, y: warp.centreY - t * 2336)
            let expected = (1 + curve.value(at: t) / 16384) / warp.scale
            #expect(abs((warp.centreX - inner.x) / (t * 3504) - expected) < 1e-12)
            #expect(expected < 1)
        }
    }

    /// Where the corner's factor would read past the real samples, the scale rises just enough:
    /// a barrel lens's correction at the middle of the long edges.
    @Test func zoomsWhereTheCornersWouldReadPastTheSamples() throws {
        let margin = (x: 12, y: 8), width = 7008, height = 4672
        let warp = try #require(LensWarp.plan(Self.barrel, width: width, height: height, margin: margin))
        #expect(warp.scale > 1 + Double(Self.barrel.knots.last!) / 16384)
        var furthest = 0.0
        warp.forEachReadPoint { x, y in
            let s = warp.source(x: x, y: y)
            let overX = max(-Double(margin.x - 2) - s.x, s.x - Double(width - 1 + margin.x - 2))
            let overY = max(-Double(margin.y - 2) - s.y, s.y - Double(height - 1 + margin.y - 2))
            furthest = max(furthest, overX, overY, -1e9)
            #expect(overX <= 1e-6 && overY <= 1e-6, "reads past the samples at \(x), \(y): \(s)")
        }
        // Just enough: some read lands on the limit.
        #expect(furthest > -1e-6)
        // The curve the sample carries reads inside them at the corner's factor.
        let sample = try #require(LensWarp.plan(Self.sampleCurve, width: width, height: height, margin: margin))
        #expect(sample.scale == 1 + 36.0 / 16384)
    }

    /// A curve that is the same everywhere moves nothing once divided by its corner, so there is no
    /// correction to make.
    @Test func aFlatCurveMovesNothing() {
        #expect(LensWarp.plan(.init(knots: [Int](repeating: 37, count: 16)), width: 7008, height: 4672, margin: (12, 8)) == nil)
    }

    /// A curve within the tag's bounds can still fold the picture, its radius read falling as the
    /// radius grows; the edge no longer holds the furthest read, so the plan refuses it, and so
    /// does the decoder (review 5: this curve read 1.8 px past the samples and seamed the bands).
    @Test func refusesACurveThatFolds() {
        let folds = SonyLensCorrection.Curve(knots: [0, 0, 0, 0, 0, 0, 8191, -8191, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(!LensWarp.readRises(folds))
        #expect(LensWarp.plan(folds, width: 700, height: 467, margin: (12, 8)) == nil)
        for curve in [Self.sampleCurve, Self.peaked, Self.barrel] { #expect(LensWarp.readRises(curve)) }
        // More knots than the kernel holds.
        #expect(LensWarp.plan(.init(knots: Array(0..<17)), width: 700, height: 467, margin: (12, 8)) == nil)
    }

    /// For the curves it takes, every pixel's read stays inside the samples and inside its band's
    /// rows, swept pixel by pixel rather than at the points the plan itself looks at.
    @Test func everyReadStaysInsideForTheCurvesTaken() throws {
        let width = 700, height = 467, margin = (x: 12, y: 8)
        for curve in [Self.sampleCurve, Self.peaked, Self.barrel] {
            var warp = try #require(LensWarp.plan(curve, width: width, height: height, margin: margin))
            warp.bandRows = 64
            for top in stride(from: 0, to: height, by: warp.bandRows) {
                let rows = top..<min(height, top + warp.bandRows)
                let band = warp.sourceRows(rows)
                for y in rows {
                    for x in 0..<width {
                        let s = warp.source(x: Double(x), y: Double(y))
                        #expect(s.x >= Double(2 - margin.x) - 1e-6 && s.x <= Double(width - 1 + margin.x - 2) + 1e-6)
                        #expect(s.y >= Double(2 - margin.y) - 1e-6 && s.y <= Double(height - 1 + margin.y - 2) + 1e-6)
                        let row = Int(s.y.rounded(.down))
                        if row - 1 < band.lowerBound || row + 2 >= band.upperBound { Issue.record("\(x), \(y) reads outside its band"); return }
                    }
                }
            }
        }
    }

    /// Each band of corrected rows is given every uncorrected row its reads touch, with the
    /// interpolation's reach.
    @Test func bandsHoldTheirReads() throws {
        for curve in [Self.peaked, Self.barrel] {
            let warp = try #require(LensWarp.plan(curve, width: 700, height: 467, margin: (12, 8)))
            for top in stride(from: 0, to: 467, by: 64) {
                let rows = top..<min(467, top + 64)
                let source = warp.sourceRows(rows)
                for y in rows {
                    for x in stride(from: 0, to: 700, by: 3) {
                        let s = warp.source(x: Double(x), y: Double(y)).y
                        #expect(Int(s.rounded(.down)) - 1 >= source.lowerBound && Int(s.rounded(.down)) + 2 < source.upperBound)
                    }
                }
            }
        }
    }

    // MARK: On the GPU

    /// The corrected frame is the uncorrected one read at the warp's positions by Catmull-Rom: the
    /// kernel's centre, radius, curve, scale and band offsets agree with `LensWarp`.
    @Test func readsTheUncorrectedFrameWhereTheWarpSays() throws {
        let harness = try DemosaicHarness()
        let width = 216, height = 168, margin = 8
        let samples = mosaic(width: width, height: height) { x, y in
            SIMD3(repeating: Float(0.2 + 0.15 * sin(Double(x) * 0.35) * cos(Double(y) * 0.27)))
        }
        let curve = SonyLensCorrection.Curve(knots: (0..<16).map { -12 * $0 * $0 })
        let lens = SonyLensCorrection(distortionSetting: 17, distortion: curve)
        let plain = try harness.run(samples, width: width, height: height, margin: margin, matrix: DemosaicHarness.cameraRGB)
        let corrected = try harness.run(samples, width: width, height: height, margin: margin, matrix: DemosaicHarness.cameraRGB, lens: lens)
        let crop = (width: width - 2 * margin, height: height - 2 * margin)
        #expect(corrected.width == crop.width && corrected.height == crop.height)
        let warp = try #require(LensWarp.plan(curve, width: crop.width, height: crop.height, margin: (margin, margin)))
        func weights(_ t: Double) -> [Double] {
            let t2 = t * t, t3 = t2 * t
            return [-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1, -1.5 * t3 + 2 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2]
        }
        var checked = 0, worst: Float = 0
        for y in 0..<crop.height {
            for x in 0..<crop.width {
                let s = warp.source(x: Double(x), y: Double(y))
                let bx = Int(s.x.rounded(.down)) - 1, by = Int(s.y.rounded(.down)) - 1
                guard bx >= 0, by >= 0, bx + 3 < crop.width, by + 3 < crop.height else { continue }
                let wx = weights(s.x - s.x.rounded(.down)), wy = weights(s.y - s.y.rounded(.down))
                var expected = SIMD3<Float>(repeating: 0)
                for j in 0..<4 { for i in 0..<4 { expected += Float(wx[i] * wy[j]) * plain.rgb(bx + i, by + j) } }
                worst = max(worst, largest(corrected.rgb(x, y) - expected))
                checked += 1
            }
        }
        #expect(checked > crop.width * crop.height / 2)
        #expect(worst < 1.5e-3, "worst difference \(worst)")
        // And it moved something: by several pixels somewhere.
        var moved = 0.0
        warp.forEachReadPoint { x, y in let s = warp.source(x: x, y: y); moved = max(moved, abs(s.x - x), abs(s.y - y)) }
        #expect(moved > 5)
    }

    /// Bands of any height give the same frame, with and without noise reduction: each pixel's
    /// demosaic and noise reduction depend on its position, not on the band it is rendered in.
    @Test func bandsJoinWithoutSeams() throws {
        let gpu = try GPU()
        let demosaic = try BayerDemosaic(device: gpu.device)
        let width = 157, height = 131, margin = 6
        let samples = noisyMosaic(width: width, height: height, noise: SensorNoise(shot: 4, read: 60), seed: 3) { x, y in
            SIMD3(0.2 + 0.1 * sin(Double(x) * 0.4), 0.3, 0.15 + 0.1 * cos(Double(y) * 0.3))
        }
        let buffer = gpu.device.makeBuffer(length: samples.count * 2, options: .storageModeShared)!
        samples.withUnsafeBytes { _ = memcpy(buffer.contents(), $0.baseAddress!, samples.count * 2) }
        let layout = BayerMosaicLayout(pitch: width, cropOrigin: .init(x: margin, y: margin),
                                       cropSize: .init(width: width - 2 * margin, height: height - 2 * margin),
                                       validSize: .init(width: width, height: height), cfa: [0, 1, 1, 2],
                                       blackLevels: [512, 512, 512, 512], whiteLevel: 16383)
        let lens = SonyLensCorrection(distortionSetting: 1, distortion: Self.barrel)
        let (planned, m) = try #require(InHouseDecoder.lensWarp(lens, layout: layout))
        var region = layout
        region.cropOrigin = .init(x: margin - m.x, y: margin - m.y)
        region.cropSize = .init(width: layout.cropSize.width + 2 * m.x, height: layout.cropSize.height + 2 * m.y)
        let noise = SensorNoise.estimate(buffer.contents().bindMemory(to: UInt16.self, capacity: samples.count), layout: layout)
        let tuning = InHouseNoiseReduction.Tuning(luminanceAmount: 0.4, colourAmount: 0.5, luminance: 1, colour: 2)
        for reduced in [false, true] {
            var parameters = InHouseDecoder.parameters(for: region, orientation: 1, gainStops: 0)
            var levels: [BayerDemosaic.NoiseLevel]?
            if reduced {
                InHouseNoiseReduction.apply(tuning, noise: noise, to: &parameters)
                levels = InHouseNoiseReduction.levels(tuning, noise: noise, parameters: parameters)
            }
            var frames: [Pixels] = []
            for bandRows in [512, 7, 1] {
                var warp = planned
                warp.bandRows = bandRows
                let output = try gpu.texturePool.acquire(width: layout.cropSize.width, height: layout.cropSize.height)
                let commandBuffer = try #require(gpu.queue.makeCommandBuffer())
                let held = try demosaic.encode(mosaic: buffer, parameters: parameters, levels: levels, warp: warp, margin: m,
                                               output: output.texture, pool: gpu.texturePool, into: commandBuffer)
                commandBuffer.commit()
                withExtendedLifetime(held) { commandBuffer.waitUntilCompleted() }
                frames.append(Pixels(output.texture))
            }
            #expect(frames[1].values == frames[0].values, "bands of 7 rows, noise reduction \(reduced)")
            #expect(frames[2].values == frames[0].values, "bands of 1 row, noise reduction \(reduced)")
        }
    }

    /// The correction is made before the frame is turned upright: a turned decode is the plain
    /// one's pixels turned.
    @Test func turnsTheCorrectedFrameUpright() throws {
        let harness = try DemosaicHarness()
        let width = 120, height = 88
        let samples = mosaic(width: width, height: height) { x, y in
            SIMD3(Float(0.1 + 0.002 * Double(x)), Float(0.2 + 0.1 * sin(Double(x + y) * 0.3)), Float(0.1 + 0.003 * Double(y)))
        }
        let lens = SonyLensCorrection(distortionSetting: 17, distortion: Self.peaked)
        let up = try harness.run(samples, width: width, height: height, orientation: 1, lens: lens)
        for orientation in [3, 6, 8] {
            let turned = try harness.run(samples, width: width, height: height, orientation: orientation, lens: lens)
            let w = up.width, h = up.height
            for y in 0..<h {
                for x in 0..<w {
                    let target: (Int, Int)
                    switch orientation {
                    case 3: target = (w - 1 - x, h - 1 - y)
                    case 6: target = (h - 1 - y, x)
                    default: target = (y, w - 1 - x)
                    }
                    #expect(turned.rgb(target.0, target.1) == up.rgb(x, y), "orientation \(orientation) at \(x), \(y)")
                }
            }
        }
    }

    /// The correction follows the option and the camera's setting, and the pins record the option
    /// as Apple's do.
    @Test func followsTheOptionAndTheCameraSetting() throws {
        let harness = try DemosaicHarness()
        let width = 96, height = 72
        let samples = mosaic(width: width, height: height) { x, y in SIMD3(repeating: Float(0.2 + 0.1 * sin(Double(x * y) * 0.01))) }
        let on = SonyLensCorrection(distortionSetting: 17, distortion: Self.peaked)
        let none = try harness.frame(samples, width: width, height: height)
        let corrected = try harness.frame(samples, width: width, height: height, lens: on)
        #expect(Pixels(corrected.texture).values != Pixels(none.texture).values)
        #expect(corrected.pins?.lensCorrection == true && corrected.decoderVersion == InHouseDecoder.version)
        var off = DemosaicHarness.off
        off.lensCorrection = false
        let refused = try harness.frame(samples, width: width, height: height, lens: on, options: off)
        #expect(Pixels(refused.texture).values == Pixels(none.texture).values && refused.pins?.lensCorrection == false)
        // The camera set to leave distortion alone: Apple's decoder leaves it too.
        let cameraOff = SonyLensCorrection(distortionSetting: 0, distortion: Self.peaked)
        let left = try harness.frame(samples, width: width, height: height, lens: cameraOff)
        #expect(Pixels(left.texture).values == Pixels(none.texture).values)
    }
}

extension LensCorrectionTests {
    @Test func manualVignettingMatchesTheFormulaAndLeavesGeometryAlone() throws {
        let picture = try MaskSpace(width: 7008, height: 4672)
        let file = SonyLensCorrection(distortionSetting: 17, distortion: Self.sampleCurve)
        let original = LensResolver.resolve(file, picture: picture, settings: .default)
        var largestError = 0.0
        for amount in [-100, -50, 0, 50, 100] {
            for midpoint in [0, 50, 100] {
                let settings = try LensSettings(arguments: "vignette=\(amount),vignette-midpoint=\(midpoint)")
                let lens = LensResolver.resolve(file, picture: picture, settings: settings)
                #expect(lens.gain.samples[0].bitPattern == Float(1).bitPattern)
                #expect(lens.geometry == original.geometry && lens.scale == original.scale)
                #expect(lens.red == original.red && lens.green == original.green && lens.blue == original.blue)
                if amount == 0 { #expect(lens.gain == .one && lens.digest == original.digest) }
                for i in 0...RadialTable.intervals {
                    let t = Double(i) / Double(RadialTable.intervals)
                    let expected = Double(amount) / 100 * 2 * pow(t, pow(2, (Double(midpoint) - 50) / 25))
                    let error = abs(log2(Double(lens.gain.samples[i])) - expected)
                    largestError = max(largestError, error)
                    #expect(error < 1e-6)
                }
                let withoutFile = LensResolver.resolve(nil, picture: picture, settings: settings)
                #expect(withoutFile.gain == lens.gain)
            }
        }
        print("VIGNETTING_TABLE 15 settings, 961 samples each, max error \(largestError) stops; centre exactly 1")
    }

    @Test func resolvesUsableCurvesWhateverTheCameraSettingAndKeepsFixedFailureReasons() throws {
        let picture = try MaskSpace(width: 7008, height: 4672)
        for setting in [nil, 0, 1, 17, 255] as [Int?] {
            let file = SonyLensCorrection(distortionSetting: setting, distortion: Self.sampleCurve)
            let lens = LensResolver.resolve(file, picture: picture, settings: .default)
            let expected: LensSource = setting == 255 ? .none("none in the file") : .file
            #expect(lens.status.distortion == expected)
            #expect(lens.isIdentity == (expected != .file))
            if expected == .file {
                #expect(lens.red == lens.green && lens.green == lens.blue && lens.gain == .one)
                #expect(lens.red.samples[0] == Float(1 + Double(Self.sampleCurve.knots[0]) / 16384))
            }
        }
        for file in [nil, SonyLensCorrection(), SonyLensCorrection(distortionSetting: 17, distortion: .init(knots: [3, 3]))] {
            #expect(LensResolver.resolve(file, picture: picture, settings: .default) == .uncorrected("none in the file"))
        }
        let invalid: [([Int], String)] = [
            (Array(0..<8), "the file's curve cannot be read"),
            ([0, -8192], "the file's curve folds the picture"),
            ([0, -3000], "the file's curve is too strong for the stage")
        ]
        for (knots, reason) in invalid {
            #expect(LensResolver.resolve(.init(distortionSetting: 17, distortion: .init(knots: knots)), picture: picture, settings: .default)
                    == .uncorrected(reason))
        }
        #expect(LensResolver.correction(for: URL(fileURLWithPath: "/no/raw.ARW"), settings: .default) == .uncorrected("none in the file"))
    }

    @Test(.enabled(if: SonyLosslessRawTests.hasSample))
    func theHeadersPictureHasTheDecodesTwoSidesOnEverySample() throws {
        let folder = SonyLosslessRawTests.sample.deletingLastPathComponent()
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "arw" }
        let gpu = try GPU(), decoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        for url in urls {
            try autoreleasepool {
                let layout = try ARWLayout.read(from: url)
                let picture = try AppleRawDecoder.fullSizePicture(native: CGSize(width: layout.cropSize.width, height: layout.cropSize.height),
                                                                 orientation: .up, layout: layout)
                var options = DecodeOptions()
                options.maxLongSide = 320
                options.lensCorrection = false
                let decoded = try decoder.decode(url, options: options)
                let actual = try #require(decoded.picture)
                #expect([picture.width, picture.height].sorted() == [actual.width, actual.height].sorted(), "\(url.lastPathComponent)")
                #expect(LensResolver.correction(for: url, settings: .default)
                        == LensResolver.resolve(SonyLensCorrection.read(from: url), picture: actual, settings: .default))
            }
        }
    }
}

extension LensCorrectionTests {
    @Test func geometryReadsOnlyGreenAndScale() throws {
        let green = try RadialTable(knots: [1, 0.98])
        let a = try ResolvedLensCorrection(red: green, green: green, blue: green, gain: .one, status: .init(), scale: 1)
        let b = try ResolvedLensCorrection(red: .one, green: green, blue: .one, gain: RadialTable(knots: [1, 2]),
                                          status: .init(distortion: .file, lateralColour: .file, vignetting: .file), scale: 1)
        #expect(a.geometry == b.geometry && a.digest != b.digest)
        let legacy = try LensGeometry(table: RadialTable(knots: [1, 1.01]), scale: 1)
        #expect(try a.remembering(legacy: legacy).reframed(scale: 1.01).legacy == legacy)
    }

    @Test(.enabled(if: SonyLosslessRawTests.hasSample))
    func offRemembersTheFileGeometry() throws {
        let url = SonyLosslessRawTests.sample
        let file = LensResolver.correction(for: url, settings: .default)
        let identity = LensResolver.correction(for: url, settings: try LensSettings(arguments: "distortion=off"))
        #expect(identity.isIdentity && identity.legacy == file.geometry)
    }
}

extension LensCorrectionTests {
    static let rising = SonyLensCorrection.Curve(knots: (0..<16).map { Int((800 * pow(Double($0) / 15, 2)).rounded()) })
    static let moustache = SonyLensCorrection.Curve(knots: [0, 4, 14, 30, 52, 78, 105, 128, 143, 148, 150, 141, 118, 86, 46, 0])
    static var amountCurves: [SonyLensCorrection.Curve] { [sampleCurve, peaked, barrel, rising, moustache] }

    @Test func theAmountScalesEachPointsDisplacement() throws {
        let picture = try MaskSpace(width: 600, height: 400)
        let file = SonyLensCorrection(distortionSetting: 17, distortion: Self.rising)
        let base = LensResolver.resolve(file, picture: picture, settings: .default)
        let centre = SIMD2(Double(picture.width - 1) / 2, Double(picture.height - 1) / 2)
        let radius = hypot(Double(picture.width), Double(picture.height)) / 2
        func source(_ point: SIMD2<Double>, _ lens: ResolvedLensCorrection) -> SIMD2<Double> {
            let v = point - centre
            return centre + v * (lens.green.value(at: hypot(v.x, v.y) / radius) / lens.scale)
        }
        for amount: Float in [50, 150, 200] {
            let made = LensResolver.resolve(file, picture: picture,
                                            settings: try LensSettings.default.setting(.distortion, to: amount))
            #expect(made.status.distortion == .file)
            var worst = 0.0
            for end in [SIMD2(0.0, 0.0), SIMD2(centre.x, 0), SIMD2(0, centre.y), centre * 2] {
                for i in 0...100 {
                    let point = centre + (end - centre) * (Double(i) / 100)
                    let expected = (source(point, base) - point) * (Double(amount) / 100)
                    let error = source(point, made) - point - expected
                    worst = max(worst, hypot(error.x, error.y))
                }
            }
            #expect(worst < 1e-4, "amount \(amount): largest displacement error \(worst) px")
        }
    }

    @Test func amount100WithoutTheShortCutIsTheFileTable() throws {
        let picture = try MaskSpace(width: 7008, height: 4672)
        for curve in Self.amountCurves {
            let base = LensResolver.resolve(.init(distortionSetting: 17, distortion: curve), picture: picture, settings: .default)
            let made = try LensAmount.scaled(base.green, scale: base.scale, amount: 100, picture: picture)
            #expect(made.table.samples.map(\.bitPattern) == base.green.samples.map(\.bitPattern))
            #expect(made.scale.bitPattern == base.scale.bitPattern)
        }
    }

    @Test func theAmountScalesTheDisplacementOfAnIdealPoint() throws {
        let picture = try MaskSpace(width: 7008, height: 4672)
        let file = SonyLensCorrection(distortionSetting: 17, distortion: Self.rising)
        let base = LensResolver.resolve(file, picture: picture, settings: .default)
        for amount in [50, 150, 200] {
            let settings = try LensSettings.default.setting(.distortion, to: Float(amount))
            let made = LensResolver.resolve(file, picture: picture, settings: settings)
            #expect(made.status.distortion == .file)
            for i in 0...960 {
                let t = Double(i) / 960
                let expected = LensAmount.factor(base.green.value(at: t) / base.scale, amount: Double(amount))
                #expect(abs(made.green.value(at: t) / made.scale - expected) < 5e-6)
            }
        }
    }

    @Test func theFrameStaysFilledAtEveryAmount() throws {
        for picture in [try MaskSpace(width: 7008, height: 4672), try MaskSpace(width: 4672, height: 7008),
                        try MaskSpace(width: 6000, height: 6000)] {
            let t0 = Double(min(picture.width, picture.height) - 1) / hypot(Double(picture.width), Double(picture.height))
            let border = [t0] + (0...960).map { Double($0) / 960 }.filter { $0 > t0 }
            for curve in Self.amountCurves {
                let file = SonyLensCorrection(distortionSetting: 17, distortion: curve)
                for amount in 0...200 {
                    let settings = try LensSettings.default.setting(.distortion, to: Float(amount))
                    let made = LensResolver.resolve(file, picture: picture, settings: settings)
                    if amount == 0 { #expect(made.isIdentity) }
                    else { #expect(made.status.distortion == .file) }
                    let factors = border.map { made.green.value(at: $0) }
                    #expect(factors.max() == made.scale)
                    #expect(factors.allSatisfy { $0 <= made.scale })
                }
            }
        }
    }

    @Test func theAmountKeepsTheFileScaleWithinOneFloatUlp() throws {
        let picture = try MaskSpace(width: 7008, height: 4672)
        for curve in Self.amountCurves {
            let file = SonyLensCorrection(distortionSetting: 17, distortion: curve)
            let base = LensResolver.resolve(file, picture: picture, settings: .default)
            for amount: Float in [50, 150, 200] {
                let made = try LensAmount.scaled(base.green, scale: base.scale, amount: amount, picture: picture)
                #expect(abs(made.scale - base.scale) <= Double(Float(base.scale).ulp), "amount \(amount)")
            }
        }
    }

    @Test func amount100KeepsLC6DigestAndZeroEqualsOff() throws {
        let picture = try MaskSpace(width: 7008, height: 4672)
        let file = SonyLensCorrection(distortionSetting: 17, distortion: Self.sampleCurve)
        let table = try RadialTable(knots: Self.sampleCurve.knots.map { 1 + Double($0) / 16384 })
        let lc6 = try ResolvedLensCorrection(red: table, green: table, blue: table, gain: .one,
                                            status: .init(distortion: .file), width: picture.width, height: picture.height)
        let current = LensResolver.resolve(file, picture: picture, settings: .default)
        #expect(current.digest == lc6.digest && current.scale == lc6.scale && current.green == lc6.green)
        #expect(current.legacy == nil)
        for arguments in ["distortion=off", "distortion-amount=0"] {
            let lens = LensResolver.resolve(file, picture: picture, settings: try LensSettings(arguments: arguments))
            #expect(lens.digest == ResolvedLensCorrection.identity.digest && lens.legacy == lc6.geometry)
        }
    }

    @Test func cameraOffCurveIsCorrectedWithIdentityLegacy() throws {
        let picture = try MaskSpace(width: 7008, height: 4672)
        let file = SonyLensCorrection(distortionSetting: 0, distortion: Self.sampleCurve)
        let lens = LensResolver.resolve(file, picture: picture, settings: .default)
        #expect(lens.status.distortion == .file && !lens.isIdentity)
        #expect(lens.legacy == ResolvedLensCorrection.identity.geometry)
        let on = LensResolver.resolve(.init(distortionSetting: 17, distortion: Self.sampleCurve), picture: picture, settings: .default)
        #expect(lens.digest == on.digest && on.legacy == nil)
    }

    @Test func amount200ValidatesAndAnOverstrongAmountIsRefused() throws {
        let picture = try MaskSpace(width: 7008, height: 4672)
        let rising = SonyLensCorrection.Curve(knots: (0..<16).map { Int((800 * pow(Double($0) / 15, 2)).rounded()) })
        let moustache = SonyLensCorrection.Curve(knots: [0, 4, 14, 30, 52, 78, 105, 128, 143, 148, 150, 141, 118, 86, 46, 0])
        for (name, curve) in [("CC0", Self.sampleCurve), ("peaked", Self.peaked), ("barrel", Self.barrel),
                              ("strong rising", rising), ("moustache", moustache)] {
            let file = SonyLensCorrection(distortionSetting: 17, distortion: curve)
            let full = LensResolver.resolve(file, picture: picture, settings: try LensSettings(arguments: "distortion-amount=200"))
            #expect(full.status.distortion == .file, "\(name): \(full.status.distortion)")
            if full.status.distortion != .file {
                let first = try (0...200).first { amount in
                    let settings = try LensSettings.default.setting(.distortion, to: Float(amount))
                    return LensResolver.resolve(file, picture: picture, settings: settings).status.distortion != .file && amount != 0
                }
                print("LC7_CURVE \(name) first refusal at amount \(first.map(String.init) ?? "none")")
            }
            #expect(full.digest != LensResolver.resolve(file, picture: picture, settings: .default).digest)
        }
        let strong = SonyLensCorrection(distortionSetting: 17, distortion: .init(knots: [0, -1966]))
        #expect(LensResolver.resolve(strong, picture: picture, settings: .default).status.distortion == .file)
        let firstRefused = try (1...200).first { amount in
            let settings = try LensSettings.default.setting(.distortion, to: Float(amount))
            return LensResolver.resolve(strong, picture: picture, settings: settings).status.distortion
                == .none("the amount is too strong for this lens")
        }
        #expect(firstRefused == 108)
        #expect(LensResolver.resolve(strong, picture: picture, settings: try LensSettings(arguments: "distortion-amount=108"))
            .status.distortion == .none("the amount is too strong for this lens"))
        #expect(LensResolver.resolve(strong, picture: picture, settings: try LensSettings(arguments: "distortion-amount=200"))
            .status.distortion == .none("the amount is too strong for this lens"))
    }

    @Test func availabilityNamesTheSourceAndMetadataSummaryOmitsMissingParts() throws {
        let picture = try MaskSpace(width: 7008, height: 4672)
        for (setting, line) in [(17, "Distortion, from the file"), (0, "Distortion, from the file, camera set to Off")] {
            let file = LensFile(correction: .init(distortionSetting: setting, distortion: Self.sampleCurve), picture: picture, metadata: nil)
            #expect(LensResolver.availability(file).distortionLine == line)
        }
        #expect(LensResolver.availability(LensFile(correction: nil, picture: picture, metadata: nil)).distortionLine == "Distortion, none in the file")
        var metadata = LensMetadata()
        #expect(metadata.summary == nil)
        metadata.lensModel = "E 28-75mm F2.8 A063"; metadata.focalLength = 75; metadata.fNumber = 2.8
        #expect(metadata.summary == "E 28-75mm F2.8 A063, 75 mm, f/2.8")
        metadata.lensModel = "FE 50mm F2.5 G"; metadata.focalLength = 50; metadata.fNumber = 5.6
        #expect(metadata.summary == "FE 50mm F2.5 G, 50 mm, f/5.6")
        metadata.lensModel = nil; metadata.focalLength = 35.5; metadata.fNumber = 8
        #expect(metadata.summary == "35.5 mm, f/8")
    }

    @Test func settingsValidateRoundTripAndLeaveMasksUnchanged() throws {
        for argument in ["default", "distortion=off", "distortion-amount=0", "distortion=off,distortion-amount=150", "distortion-amount=0.000000001"] {
            let settings = try LensSettings(arguments: argument)
            #expect(try LensSettings(arguments: settings.arguments) == settings)
            #expect(try JSONDecoder().decode(LensSettings.self, from: JSONEncoder().encode(settings)) == settings)
            let values = ManualAdjustments.identity.settingLens(settings)
            #expect(values.masks.digest == ManualAdjustments.identity.masks.digest)
            #expect(values.clearing(.lens) == .identity)
            #expect(ManualAdjustments.identity.setting(.lens, from: values) == values)
            #expect(try values.setting(.lens(.distortion), to: 150).lens.distortion.amount == 150)
        }
        for argument in ["", "unknown=1", "distortion=on,distortion=off", "distortion=yes", "distortion-amount=nan", "distortion-amount=201", "distortion-amount=-1", "distortion=off,"] {
            #expect(throws: (any Error).self) { try LensSettings(arguments: argument) }
        }
        #expect(try LensSettings.Distortion(amount: -0).amount.bitPattern == Float(0).bitPattern)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LensSettings.self, from: Data(#"{"distortion":{"amount":201}}"#.utf8)) }
    }
}

extension LensCorrectionTests {
    @Test func defringeChangesOnlyTheSceneIdentityIncludingWithoutAFileCurve() throws {
        let picture = try MaskSpace(width: 7008, height: 4672)
        let settings = try LensSettings(arguments: "defringe-purple=10")
        let off = LensResolver.resolve(nil, picture: picture, settings: .default)
        let on = LensResolver.resolve(nil, picture: picture, settings: settings)
        #expect(on.defringe != nil && on.isIdentity)
        #expect(on.geometry == off.geometry && on.scale == off.scale && on.status == off.status)
        #expect(on.digest != off.digest)
        #expect(on.defringing(nil) == off)
        #expect(on.defringing(on.defringe) == on)
        let changedInactiveHue = try settings.setting(.greenHueLow, to: 20)
        #expect(LensResolver.resolve(nil, picture: picture, settings: changedInactiveHue).digest == on.digest)
        let activeHue = try settings.setting(.purpleHueLow, to: 20)
        #expect(LensResolver.resolve(nil, picture: picture, settings: activeHue).digest != on.digest)
        #expect(LensResolver.resolve(LensFile(correction: nil, picture: nil, metadata: nil), settings: settings).defringe != nil)
        #expect(try on.reframed(scale: 1).defringe == on.defringe)
        #expect(ResolvedLensCorrection.identity.digest == "e9ce460db9907bbdcdde3a2fc85f4d0f4192bd721a2e2b3714779eb0b41e11a6")
    }
}
