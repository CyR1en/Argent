import Foundation
import Metal
import Testing
@testable import ArgentCore

@Suite struct CaptureSharpeningMathTests {
    /// Lindeberg's discrete Gaussian keeps its variance at any sigma, so a mask a fraction of a
    /// pixel wide at the contact sheet's scale is the same filter, not a rounding of it.
    @Test func theKernelIsADiscreteGaussianOfTheGivenVariance() {
        for sigma: Float in [0.05, 0.14, 0.3, 0.55, 1.0, 1.4] {
            let kernel = CaptureSharpening.kernel(sigma: sigma)
            let radius = kernel.count / 2
            #expect(kernel.count % 2 == 1 && radius <= CaptureSharpening.maxRadius)
            #expect(abs(kernel.reduce(0, +) - 1) < 1e-5)
            #expect(zip(kernel, kernel.reversed()).allSatisfy { abs($0 - $1) < 1e-7 })
            let variance = kernel.enumerated().reduce(Float(0)) { $0 + $1.element * Float(($1.offset - radius) * ($1.offset - radius)) }
            #expect(abs(variance - sigma * sigma) < 0.03 * sigma * sigma + 1e-4, "sigma \(sigma): variance \(variance)")
        }
        #expect(CaptureSharpening.kernel(sigma: 0.005) == [1])
    }

    /// The sensor's mask is fixed in sensor pixels; the mask for Apple's scaling is fixed in a
    /// draft decode's own pixels and shrinks when that decode is resized again. A decode above
    /// draft mode matches the area-resized develop without it.
    @Test func theMasksFollowTheDecodesScale() throws {
        let gpu = try GPU()
        func frame(scale: Float, decodedAt: Float?, draft: Bool = false) throws -> LinearFrame {
            LinearFrame(image: try gpu.texturePool.acquire(width: 8, height: 8), decoderVersion: "test", scale: scale,
                        pins: decodedAt.map { pins(scale: $0, draft: draft) })
        }
        let full = CaptureSharpening.masks(for: try frame(scale: 1, decodedAt: 1))
        #expect(full.sensor == CaptureSharpening.sensor && full.scaling == nil)
        let sheet = CaptureSharpening.masks(for: try frame(scale: 0.137, decodedAt: 0.137, draft: true))
        #expect(abs(sheet.sensor.sigma - 0.137 * CaptureSharpening.sensor.sigma) < 1e-6)
        #expect(sheet.sensor.amount == CaptureSharpening.sensor.amount && sheet.scaling == CaptureSharpening.draftScaling)
        let frameView = CaptureSharpening.masks(for: try frame(scale: 0.584, decodedAt: 0.584))
        #expect(frameView.sensor.sigma > 0 && frameView.scaling == nil)
        // The sheet's picture made from a frame view decode at 0.438, resized to 0.137.
        let resized = try #require(CaptureSharpening.masks(for: try frame(scale: 0.137, decodedAt: 0.438, draft: true)).scaling)
        #expect(abs(resized.sigma - CaptureSharpening.draftScaling.sigma * 0.137 / 0.438) < 1e-6)
        // A frame that did not come through the decoder has only the sensor's mask.
        #expect(CaptureSharpening.masks(for: try frame(scale: 0.25, decodedAt: nil)).scaling == nil)
    }

    @Test func theThresholdLeavesSmallDetailAndPassesEdges() {
        let t = CaptureSharpening.threshold
        #expect(abs(CaptureSharpening.cored(10 * t) - 10 * t) < 0.011 * 10 * t)
        #expect(abs(CaptureSharpening.cored(-10 * t) + 10 * t) < 0.011 * 10 * t)
        #expect(abs(CaptureSharpening.cored(t / 10)) < 0.011 * t / 10)
        #expect(CaptureSharpening.cored(0) == 0)
    }
}

/// The mask on the GPU through a stock whose two tables are identities, so the render's output
/// is the dye amounts themselves, sharpened and with grain added.
@Suite struct CaptureSharpeningRenderTests {
    static let constantSigma: Float = 0.02

    /// `varyingGrain` makes the grain's strength triple across the dye range, as a real stock's
    /// table varies, so a lookup from the wrong amounts shows.
    private func stock(grain: Bool = false, varyingGrain: Bool = false) -> Stock {
        let s = Self.constantSigma
        let table = varyingGrain
            ? GrainTable(amounts: [[0, 0, 0], [1, 1, 1]], sigma48: [[s / 2, s / 2, s / 2], [s * 1.5, s * 1.5, s * 1.5]])
            : GrainTable(amounts: [[0, 0, 0], [1, 1, 1]], sigma48: [[s, s, s], [s, s, s]])
        return Stock(id: "identity", displayName: "Identity", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                     negative: LUT3D.identity(size: 17), print: LUT3D.identity(size: 17), grain: grain ? table : nil)
    }

    /// A frame whose dye amounts through the identity Negative LUT are `amounts(x, y)`.
    private func frame(_ gpu: GPU, width: Int, height: Int, scale: Float = 1, pins: DecodePins? = nil,
                       amounts: (Int, Int) -> SIMD3<Float>) throws -> LinearFrame {
        let texture = try gpu.texturePool.acquire(width: width, height: height)
        let encoding = LogEncoding()
        var pixels = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let a = amounts(x, y), i = (y * width + x) * 4
                for c in 0..<3 { pixels[i + c] = Float16(encoding.decode(a[c])) }
            }
        }
        pixels.withUnsafeBytes { texture.texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                                         withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        return LinearFrame(image: texture, decoderVersion: "test", scale: scale, pins: pins)
    }

    private func render(_ renderer: FilmRenderer, _ frame: LinearFrame, sharpen: Bool, grain: Float = 0) throws -> [Float] {
        let out = try renderer.render(frame, settings: DevelopSettings(grain: grain, grainSeed: 3, sharpen: sharpen))
        return ExposureAnalyzer.pixels(of: out.image.texture).map { Float($0) }
    }

    /// The mask on the CPU: both masks' detail on the luminance, summed, softly thresholded and
    /// added to every layer, edges repeated beyond the frame.
    private func reference(_ amounts: [Float], width: Int, height: Int, masks: (sensor: CaptureSharpening.Mask, scaling: CaptureSharpening.Mask?)) -> [Float] {
        let w = Rec2020.luma
        var luma = [Float](repeating: 0, count: width * height)
        for i in luma.indices { luma[i] = w.x * amounts[4 * i] + w.y * amounts[4 * i + 1] + w.z * amounts[4 * i + 2] }
        func blur(_ sigma: Float) -> [Float] {
            let k = CaptureSharpening.kernel(sigma: sigma), r = k.count / 2
            var across = luma, out = luma
            for y in 0..<height { for x in 0..<width {
                var sum: Float = 0
                for j in -r...r { sum += k[j + r] * luma[y * width + min(max(x + j, 0), width - 1)] }
                across[y * width + x] = sum } }
            for y in 0..<height { for x in 0..<width {
                var sum: Float = 0
                for j in -r...r { sum += k[j + r] * across[min(max(y + j, 0), height - 1) * width + x] }
                out[y * width + x] = sum } }
            return out
        }
        let sensor = blur(masks.sensor.sigma)
        let scaling = masks.scaling.map { blur($0.sigma) }
        var out = amounts
        for i in luma.indices {
            var detail = masks.sensor.amount * (luma[i] - sensor[i])
            if let scaling, let mask = masks.scaling { detail += mask.amount * (luma[i] - scaling[i]) }
            let d = CaptureSharpening.cored(detail)
            for c in 0..<3 { out[4 * i + c] = min(max(amounts[4 * i + c] + d, 0), 1) }
        }
        return out
    }

    private func pattern(_ x: Int, _ y: Int) -> SIMD3<Float> {
        let block: Float = (x / 9 + y / 7) % 2 == 0 ? 0.3 : 0.62
        let ripple = 0.04 * sin(Float(x) * 1.3) * cos(Float(y) * 0.7)
        let green: Float = block * 0.9 + 0.05, blue: Float = 0.7 - block * 0.5 + ripple
        return SIMD3<Float>(block + ripple, green, blue)
    }

    /// The shader matches the CPU mask, at full size with the sensor's mask alone and on a draft
    /// decode with both, across tile boundaries and the frame's edges (70 by 45 is no multiple
    /// of the 16-pixel tile).
    @Test func theShaderMatchesTheMaskOnTheCPU() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: stock())
        let width = 70, height = 45
        for (scale, decodePins) in [(Float(1), pins(scale: 1, draft: false)), (Float(0.25), pins(scale: 0.25, draft: true))] {
            let input = try frame(gpu, width: width, height: height, scale: scale, pins: decodePins, amounts: pattern)
            let amounts = try render(renderer, input, sharpen: false)
            let sharpened = try render(renderer, input, sharpen: true)
            let expected = reference(amounts, width: width, height: height, masks: CaptureSharpening.masks(for: input))
            var worst: Float = 0, moved: Float = 0
            for i in amounts.indices where i % 4 != 3 {
                worst = max(worst, abs(sharpened[i] - expected[i]))
                moved = max(moved, abs(sharpened[i] - amounts[i]))
            }
            #expect(worst < 2e-3, "scale \(scale): worst difference \(worst)")
            #expect(moved > 0.05, "scale \(scale): the mask moved nothing")
        }
    }

    @Test func aFlatFieldIsUnchanged() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: stock())
        let input = try frame(gpu, width: 64, height: 40, pins: pins(scale: 0.3, draft: true)) { _, _ in SIMD3(0.45, 0.5, 0.55) }
        let plain = try render(renderer, input, sharpen: false), sharpened = try render(renderer, input, sharpen: true)
        #expect(zip(plain, sharpened).allSatisfy { abs($0 - $1) < 1e-4 })
    }

    /// A step gains contrast on both sides, by less than a third of the step, over a few pixels;
    /// away from it nothing moves and the row keeps its mean.
    @Test func anEdgeGainsContrastWithinABound() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: stock())
        let width = 64, height = 32, low: Float = 0.35, high: Float = 0.65
        let input = try frame(gpu, width: width, height: height) { x, _ in SIMD3(repeating: x < 32 ? low : high) }
        let plain = try render(renderer, input, sharpen: false), sharpened = try render(renderer, input, sharpen: true)
        let row = 16
        func green(_ v: [Float], _ x: Int) -> Float { v[(row * width + x) * 4 + 1] }
        let undershoot = green(plain, 31) - green(sharpened, 31), overshoot = green(sharpened, 32) - green(plain, 32)
        let step = high - low
        #expect(undershoot > 0.05 * step && undershoot < step / 3)
        #expect(overshoot > 0.05 * step && overshoot < step / 3)
        for x in Array(0..<24) + Array(40..<width) { #expect(abs(green(sharpened, x) - green(plain, x)) < 1e-3) }
        let mean = { (v: [Float]) in (0..<width).reduce(Float(0)) { $0 + green(v, $1) } / Float(width) }
        #expect(abs(mean(sharpened) - mean(plain)) < 1e-3)
    }

    /// Grain goes in after the mask and takes its strength from the film's own amounts: the
    /// noise a render adds is the same with sharpening and without, pixel for pixel, on a frame
    /// full of edges, with a grain table that varies across the dye range (a flat one could not
    /// show a lookup from the sharpened amounts, which review found).
    @Test func grainIsNotSharpened() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: stock(grain: true, varyingGrain: true))
        let width = 96, height = 64
        // Edges gentle enough that nothing reaches the ends of the dye range, where the print
        // pass clips.
        let middle = SIMD3<Float>(repeating: 0.5)
        let input = try frame(gpu, width: width, height: height, pins: pins(scale: 0.3, draft: true)) { x, y in
            let offset: SIMD3<Float> = self.pattern(x, y) - middle
            return middle + offset * 0.3
        }
        // Ten times the stock's grain, since at this tiny frame's pitch one would be under the
        // output's half-float resolution.
        let plain = try render(renderer, input, sharpen: false), grainy = try render(renderer, input, sharpen: false, grain: 10)
        let sharpened = try render(renderer, input, sharpen: true)
        let both = try render(renderer, input, sharpen: true, grain: 10)
        var worst: Float = 0, squares: Float = 0
        for i in plain.indices where i % 4 != 3 {
            let noise = grainy[i] - plain[i]
            worst = max(worst, abs((both[i] - sharpened[i]) - noise))
            squares += noise * noise
        }
        let sd = (squares / Float(width * height * 3)).squareRoot()
        #expect(sd > 0.01, "the grain is there: sd \(sd)")
        #expect(worst < 2e-3, "worst difference in the grain \(worst)")
    }
}

/// Decode pins as Apple's decoder records them for a decode at `scale`.
func pins(scale: Float, draft: Bool) -> DecodePins {
    DecodePins(version: DecodePins.currentVersion, decoderVersion: "8", baselineExposure: 0, shadowBias: 0, sharpness: 0,
               boost: 0, boostShadow: 0, gamutMapping: false, highlightRecovery: true, extendedDynamicRange: 1,
               neutralChromaticity: .init(x: 0.33243, y: 0.34744), moireReduction: 1, contrast: 0, detail: 0,
               anchorDecodedMidTone: 0.08, anchorVersion: "1", exposureGainStops: 1.17, luminanceNoiseReduction: 0.4,
               colorNoiseReduction: 0.5, lensCorrection: true, scale: scale, draftMode: draft)
}

/// The Swift side's tile and margin are the shader's `#define`s, which nothing else ties together.
@Suite struct SharpeningConstantsTests {
    @Test func matchTheShader() throws {
        func defined(_ name: String) -> Int? {
            ShaderSource.lut3D.split(separator: "\n").lazy
                .compactMap { line -> Int? in
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    return parts.count == 3 && parts[0] == "#define" && parts[1] == name ? Int(parts[2]) : nil
                }.first
        }
        #expect(defined("SHARPEN_TILE") == PrintPass.sharpenTile)
        #expect(defined("SHARPEN_MAX_RADIUS") == CaptureSharpening.maxRadius)
        #expect(try PrintPass(gpu: GPU()).canSharpen)
    }
}

