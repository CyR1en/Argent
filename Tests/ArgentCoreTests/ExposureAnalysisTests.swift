import Foundation
import CoreGraphics
import Testing
@testable import ArgentCore

@Suite struct ExposureAnalysisTests {
    /// A frame of `width` by `height` whose light is `value(x, y)` in every channel.
    private func frame(_ width: Int, _ height: Int, _ value: (Int, Int) -> Float) -> [Float16] {
        var pixels = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = Float16(value(x, y))
                let i = (y * width + x) * 4
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v
            }
        }
        return pixels
    }

    @Test(arguments: [-4, -2, -1, 0, 1, 2, 3, 4] as [Float])
    func aFlatFrameMeasuresAtItsOwnLevel(stops: Float) {
        let pixels = frame(96, 64) { _, _ in 0.18 * exp2(stops) }
        let analysis = ExposureAnalyzer.analyze(pixels: pixels, width: 96, height: 64)
        #expect(abs(analysis.meanStops - stops) < 0.01)
    }

    /// A stop more light on the same scene measures a stop more, while it stays under the
    /// decoder's clip.
    @Test func aStopOfLightIsAStop() {
        // From two stops under to just over two stops over mid-gray, and a stop more of it.
        let scene: (Int, Int) -> Float = { x, y in 0.18 * exp2(Float(x % 17) / 4 - 2 + Float(y % 5) / 10) }
        let base = ExposureAnalyzer.analyze(pixels: frame(240, 160, scene), width: 240, height: 160)
        let brighter = ExposureAnalyzer.analyze(pixels: frame(240, 160) { scene($0, $1) * 2 }, width: 240, height: 160)
        #expect(abs(brighter.meanStops - base.meanStops - 1) < 0.02)
        #expect(base.isCurrent)
    }

    /// A clipped sky does not pull the level up: pixels at the frame's brightest value are
    /// left out.
    @Test func leavesClippedLightOut() {
        // Eight is past every raw mode's clip; the frame's brightest light sits there.
        let pixels = frame(240, 160) { _, y in y < 60 ? 8 : 0.18 }
        let analysis = ExposureAnalyzer.analyze(pixels: pixels, width: 240, height: 160)
        #expect(abs(analysis.meanStops) < 0.01)
        #expect(analysis.validWeight < 0.8)
    }

    /// The middle of the frame counts for more than its edges.
    @Test func weighsTheCentre() {
        // A bright middle third and a dark surround, half a stop apart each way of the edges' mean.
        let pixels = frame(240, 160) { x, y in
            let dx = Float(x) / 119.5 - 1, dy = Float(y) / 79.5 - 1
            return (dx * dx + dy * dy).squareRoot() < 1.0 / 3 ? 0.18 * 2 : 0.18 / 2
        }
        let analysis = ExposureAnalyzer.analyze(pixels: pixels, width: 240, height: 160)
        // By area the bright middle is under a tenth of the frame and the level would be about
        // -0.96 stops; weighted, the middle holds about a quarter of the weight, -0.65.
        #expect(analysis.meanStops > -0.8 && analysis.meanStops < -0.5)
    }

    /// A frame whose pixels are `rgb(x, y)`.
    private func coloured(_ width: Int, _ height: Int, _ rgb: (Int, Int) -> SIMD3<Float>) -> [Float16] {
        var pixels = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = rgb(x, y), i = (y * width + x) * 4
                pixels[i] = Float16(v.x); pixels[i + 1] = Float16(v.y); pixels[i + 2] = Float16(v.z)
            }
        }
        return pixels
    }

    /// A mid-gray under a light `redBlue` stops warm and `green` stops green, through the D55 pin.
    private func gray(redBlue: Float, green: Float) -> SIMD3<Float> {
        SIMD3(0.18 * exp2(redBlue / 2 - green / 3), 0.18 * exp2(2 * green / 3), 0.18 * exp2(-redBlue / 2 - green / 3))
    }

    /// The gray gamut reaches the lights measured on Cube++'s gray cubes from a clear sky's shade
    /// to deep tungsten, and leaves out a yellow flower's colour (docs/M3-auto.md section 12).
    @Test func theGrayGamutHoldsSkyShadeToTungsten() {
        let gamut = GrayGamut.plausibleLight
        #expect(gamut.redBlue == -1.3...2.1 && gamut.greenMagenta == 0.35)
        #expect(gamut.contains(gray(redBlue: -1.2, green: -0.25)))
        #expect(gamut.contains(gray(redBlue: 2.0, green: 0.3)))
        #expect(!gamut.contains(gray(redBlue: -1.5, green: 0)))
        #expect(!gamut.contains(gray(redBlue: 3.6, green: 1.4)))
    }

    /// Half the frame a gray under daylight, half a strongly coloured surface: the estimate is the
    /// gray's. A frame lit by sodium lamps has no pixel in the gamut, and every mid-tone then
    /// estimates the light, where before there was no estimate and so no filtration.
    @Test func aLightOutsideTheGamutIsStillEstimated() {
        let surface = coloured(240, 160) { x, _ in x < 120 ? self.gray(redBlue: 0.2, green: 0) : self.gray(redBlue: 3.6, green: 1.4) }
        let mixed = ExposureAnalyzer.analyze(pixels: surface, width: 240, height: 160).grayEstimate
        #expect(mixed.count == 3 && abs(mixed[0] - mixed[2] - 0.2) < 0.01)

        let sodium = coloured(240, 160) { x, y in self.gray(redBlue: 4.7, green: 1.2) * exp2(Float((x + y) % 7) / 3 - 1) }
        let estimate = ExposureAnalyzer.analyze(pixels: sodium, width: 240, height: 160).grayEstimate
        #expect(estimate.count == 3 && abs(estimate[0] - estimate[2] - 4.7) < 0.02)
        #expect(ExposureAnalyzer.analyze(pixels: sodium, width: 240, height: 160, grayGamutFallback: false).grayEstimate.isEmpty)
    }

    /// Fine texture does not pull the level down: each sample is its cell's mean light, so a frame
    /// of one-pixel stripes a stop either side of a level measures what its cells hold, as a flat
    /// frame of that light would; one pixel a sample reads the log of whichever stripe it lands on.
    @Test func cellsReadTheirMeanLight() {
        let striped = frame(960, 640) { x, _ in 0.18 * (x % 2 == 0 ? 2 : 0.5) }
        let cells = ExposureAnalyzer.analyze(pixels: striped, width: 960, height: 640)
        #expect(abs(cells.meanStops - log2(1.25)) < 0.01)
        let points = ExposureAnalyzer.analyze(pixels: striped, width: 960, height: 640, sampling: .points)
        #expect(abs(points.meanStops - 1) < 0.01)
        // On a grid of one pixel a cell the two are the same.
        let small = frame(240, 160) { x, _ in 0.18 * (x % 2 == 0 ? 2 : 0.5) }
        #expect(ExposureAnalyzer.analyze(pixels: small, width: 240, height: 160).meanStops
                == ExposureAnalyzer.analyze(pixels: small, width: 240, height: 160, sampling: .points).meanStops)
    }

    /// A cell keeps its light that is not clipped, weighted by its share: a frame whose every
    /// cell has one clipped pixel in four measures the rest.
    @Test func cellsLeaveClippedPixelsOut() {
        let pixels = frame(960, 640) { x, y in x % 4 == 0 && y % 4 == 0 ? 8 : 0.18 }
        let analysis = ExposureAnalyzer.analyze(pixels: pixels, width: 960, height: 640)
        #expect(abs(analysis.meanStops) < 0.01)
        #expect(abs(analysis.validWeight - 15.0 / 16) < 0.01)
    }

    /// The decoder's lift of dark noise and its inverse: light comes back from its average decode,
    /// no light decodes to the noise's half-normal mean, and bright light is left as it is.
    @Test func decodedNoiseRoundTrips() throws {
        let noise = DecodedNoise(read: SIMD3(4e-4, 1e-4, 2e-4), shot: SIMD3(2e-4, 5e-5, 1e-4))
        for t: Float in [0.002, 0.01, 0.03, 0.1] {
            let v = SIMD3((0..<3).map { noise.lifted(t, channel: $0) })
            #expect(v.min() >= t)
            if t <= 0.03 { #expect(v.min() > t) }
            let back = noise.unlifted(v)
            for c in 0..<3 { #expect(abs(back[c] - t) < 1e-4 + 1e-3 * t) }
        }
        #expect(abs(noise.lifted(0, channel: 0) - 0.02 * 0.3989423) < 1e-6)
        #expect(noise.unlifted(SIMD3(repeating: 0.001)) == .zero)
        #expect(noise.unlifted(SIMD3(repeating: 2)) == SIMD3(repeating: 2))
    }

    /// A pixel that is not a number or is infinite is left out, wherever it falls; a frame
    /// thinner than half a step still has a row of cells; a face box off the frame or not a
    /// number meters nothing (review 5: each of these trapped).
    @Test func degenerateFramesAndBoxes() {
        let width = 240, height = 160
        var pixels = [Float16](repeating: Float16(0.18), count: width * height * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 1 }
        pixels[(1 * width + 1) * 4] = .infinity
        pixels[(5 * width + 7) * 4 + 1] = .nan
        let analysis = ExposureAnalyzer.analyze(pixels: pixels, width: width, height: height)
        #expect(abs(analysis.meanStops) < 0.01 && analysis.meanStops.isFinite)
        let finiteHistogram = analysis.histogram.allSatisfy { $0.isFinite }
        #expect(finiteHistogram)

        let thin = [Float16](repeating: Float16(0.36), count: 960 * 2 * 4)
        let line = ExposureAnalyzer.analyze(pixels: thin, width: 960, height: 2)
        #expect(abs(line.meanStops - 1) < 0.02 && line.validWeight > 0)

        let boxes = [CGRect(x: -0.5, y: 0.2, width: 0.1, height: 0.1), CGRect(x: 1.4, y: 0.2, width: 0.2, height: 0.2),
                     CGRect(x: CGFloat.nan, y: 0.2, width: 0.1, height: 0.1), CGRect(x: 0.2, y: 0.2, width: 0, height: 0.1)]
        #expect(FaceMeter.meter(boxes, pixels: pixels, width: width, height: height).isEmpty)
    }

    /// The a7 IV's noise in a pinned Apple decode: none for a body without a profile, a mode that
    /// is not a Bayer mosaic or another decoder; and at base ISO it changes nothing the level can
    /// see, while at ISO 102400 a cell two stops under the floor reads well over it.
    @Test func decodedNoiseOfTheA7IV() throws {
        let pins = DecodePins(version: DecodePins.currentVersion, decoderVersion: AppleRawDecoder.pinnedDecoderVersion,
                              baselineExposure: 0, shadowBias: 0, sharpness: 0, boost: 0, boostShadow: 0, gamutMapping: false,
                              highlightRecovery: true, extendedDynamicRange: 1, neutralChromaticity: AppleRawDecoder.daylightNeutral,
                              moireReduction: 1, contrast: 0, detail: 0, anchorDecodedMidTone: ExposureAnchor.decodedMidTone,
                              anchorVersion: AppleRawDecoder.anchorVersion, exposureGainStops: ExposureAnchor.gainStops(),
                              luminanceNoiseReduction: 0.4, colorNoiseReduction: 0.5, lensCorrection: true, scale: 0.137,
                              draftMode: true, rawMode: "uncompressed", modeExposureStops: 0, trimColumns: 0, trimRows: 0, tileSize: nil)
        #expect(DecodedNoise.appleDecode(model: "MODEL-NAME", iso: 250, pins: pins) == nil)
        var ycbcr = pins
        ycbcr.rawMode = "lossless S"
        #expect(DecodedNoise.appleDecode(model: "ILCE-7M4", iso: 250, pins: ycbcr) == nil)
        var other = pins
        other.decoderVersion = "argent-3"
        #expect(DecodedNoise.appleDecode(model: "ILCE-7M4", iso: 250, pins: other) == nil)
        // Lossless L stores the samples uncompressed does; the lossy mode was not measured (review 5).
        var lossless = pins, lossy = pins
        lossless.rawMode = "lossless L"
        lossy.rawMode = "compressed"
        #expect(DecodedNoise.appleDecode(model: "ILCE-7M4", iso: 250, pins: lossless) != nil)
        #expect(DecodedNoise.appleDecode(model: "ILCE-7M4", iso: 250, pins: lossy) == nil)
        let base = try #require(DecodedNoise.appleDecode(model: "ILCE-7M4", iso: 250, pins: pins))
        let floor = 0.18 * exp2(ExposureAnalyzer.floorStops)
        #expect(base.unlifted(SIMD3(repeating: floor)) == SIMD3(repeating: floor))
        let high = try #require(DecodedNoise.appleDecode(model: "ILCE-7M4", iso: 102400, pins: pins))
        let lifted = SIMD3((0..<3).map { high.lifted(floor / 4, channel: $0) })
        #expect(lifted.x > floor && lifted.z > floor)
        // Red and blue carry more noise than green, by about the white balance and the second green.
        #expect(high.read.x > 4 * high.read.y && high.read.z > 2 * high.read.y)
    }
}
