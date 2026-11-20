import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Gaussian samples from a seed, so a synthetic mosaic is the same on every run.
struct SeededNoise {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func uniform() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return (Double((z ^ (z >> 31)) >> 11) + 0.5) / Double(1 << 53)
    }

    mutating func gaussian() -> Double {
        (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
    }
}

/// A mosaic of `width` by `height` samples, RGGB, black 512 and white 16383, whose white-balanced
/// camera RGB at each position is `colour(x, y)` under the committed D55 gains, with sensor noise
/// `noise` drawn from `seed`.
func noisyMosaic(width: Int, height: Int, noise: SensorNoise, seed: UInt64 = 1,
                 _ colour: (Int, Int) -> SIMD3<Double>) -> [UInt16] {
    var random = SeededNoise(seed: seed)
    let gains = InHouseColor.daylightGains
    var out = [UInt16](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let c = colour(x, y)
            let channel = (y & 1) == 0 ? ((x & 1) == 0 ? 0 : 1) : ((x & 1) == 0 ? 1 : 2)
            let level = c[channel] / gains[channel] * Double(16383 - 512)
            let value = 512 + level + noise.variance(at: level).squareRoot() * random.gaussian()
            out[y * width + x] = UInt16(max(0, min(16383, value.rounded())))
        }
    }
    return out
}

@Suite(.serialized) struct InHouseNoiseReductionTests {
    /// The blind estimate finds the shot and read noise a synthetic mosaic was made with, on a
    /// ramp from black to near white, with half the frame covered in texture far above the noise.
    @Test func estimatesTheSensorNoise() throws {
        for truth in [SensorNoise(shot: 0.6, read: 9), SensorNoise(shot: 4, read: 400), SensorNoise(shot: 30, read: 6000)] {
            let side = 2048
            var texture = SeededNoise(seed: 7)
            let bumps = (0..<(side * side / 256)).map { _ in texture.uniform() }
            let samples = noisyMosaic(width: side, height: side, noise: truth) { x, y in
                let level = 0.8 * Double(x) / Double(side)
                // Texture in every other 32-pixel square of the top half.
                let textured = y < side / 2 && ((x / 32 + y / 32) & 1) == 0
                let bump = textured ? 0.3 * bumps[(y / 16) * (side / 16) + x / 16] * level : 0
                return SIMD3(repeating: level + bump * Double((x ^ y) & 1))
            }
            let layout = BayerMosaicLayout(pitch: side, cropOrigin: .init(x: 0, y: 0), cropSize: .init(width: side, height: side),
                                           validSize: .init(width: side, height: side), cfa: [0, 1, 1, 2],
                                           blackLevels: [512, 512, 512, 512], whiteLevel: 16383)
            let estimate = samples.withUnsafeBufferPointer { SensorNoise.estimate($0.baseAddress!, layout: layout) }
            print(String(format: "MEASURE noise estimate: shot %.3f (made with %.3f), read %.2f (made with %.2f)",
                         estimate.shot, truth.shot, estimate.read, truth.read))
            #expect(abs(estimate.shot / truth.shot - 1) < 0.08)
            #expect(abs(estimate.read / truth.read - 1) < 0.15)
        }
    }

    /// The selection finds the same element as a sort, duplicates and all.
    @Test func selectsLikeASort() {
        var random = SeededNoise(seed: 3)
        for count in [1, 2, 3, 10, 97, 1000] {
            var values = (0..<count).map { _ in Float((random.uniform() * 20).rounded()) }
            let sorted = values.sorted()
            for k in Set([0, count / 10, count / 2, count - 1]) {
                let picked = values.withUnsafeMutableBufferPointer { SensorNoise.select($0, k) }
                #expect(picked == sorted[k], "count \(count), k \(k)")
            }
        }
    }

    /// What each detail level carries per unit of shot and read noise, simulated through the
    /// kernels on flat neutral mosaics, against `InHouseNoiseReduction.shotNoise` and `readNoise`.
    /// ARGENT_SIM_MATRIX, nine numbers row by row, simulates another matrix instead and only prints,
    /// at ARGENT_SIM_SIDE pixels (2048); the a7C's tables in `InHouseNoiseMeasureTests` come from it,
    /// and `committed` simulates the committed matrix, which wrote the tables at 4096.
    @Test func levelNoise() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        if let text = ProcessInfo.processInfo.environment["ARGENT_SIM_MATRIX"] {
            // "committed" gives no numbers and simulates the committed matrix.
            let v = text.split(whereSeparator: { $0 == "," || $0 == ";" }).compactMap { Double($0) }
            let side = Int(ProcessInfo.processInfo.environment["ARGENT_SIM_SIDE"] ?? "") ?? 2048
            let matrix = v.count == 9 ? [Array(v[0..<3]), Array(v[3..<6]), Array(v[6..<9])] : nil
            let measured = try Self.simulateLevelNoise(device: device, matrix: matrix, side: side)
            func table(_ v: [SIMD3<Float>]) -> String { v.map { String(format: "SIMD3(%.4f, %.4f, %.4f)", $0.x, $0.y, $0.z) }.joined(separator: ", ") }
            print("MEASURE level noise for \(text), shot: \(table(measured.shot))")
            print("MEASURE level noise for \(text), read: \(table(measured.read))")
            return
        }
        // 4096 pixels a side wrote the table; 1024 is within a few percent where a level has
        // 64 pixels a side or more, and sixteen times quicker.
        let measured = try Self.simulateLevelNoise(device: device, side: 1024)
        func table(_ v: [SIMD3<Float>]) -> String { v.map { String(format: "SIMD3(%.4f, %.4f, %.4f)", $0.x, $0.y, $0.z) }.joined(separator: ", ") }
        print("MEASURE level noise, shot: \(table(measured.shot))")
        print("MEASURE level noise, read: \(table(measured.read))")
        let pairs = zip(measured.shot, InHouseNoiseReduction.shotNoise).enumerated().map { ($0.offset, $0.element) }
            + zip(measured.read, InHouseNoiseReduction.readNoise).enumerated().map { ($0.offset, $0.element) }
        for (level, (m, c)) in pairs {
            let tolerance: Float = level <= 4 ? 0.04 : 0.15
            for i in 0..<3 { #expect(abs(m[i] / c[i] - 1) < tolerance, "level \(level): measured \(m), committed \(c)") }
        }
    }

    /// The strengths follow `NoiseReduction`'s tiers: the tier's table at the frame's ISO at the
    /// tier's own amount, scaled by any other amount; impulses only in the extreme tier; a frame
    /// with no ISO gets the least.
    @Test func strengthsFollowTheTiers() {
        typealias N = InHouseNoiseReduction
        let at250 = N.tuning(luminance: NoiseReduction.luminanceAmount(iso: 250), colour: 0.5, iso: 250)
        #expect(abs(at250.luminance - N.strength(at: 250, N.lowTier)) < 1e-6 && at250.impulse == 0)
        #expect(abs(at250.colour - N.strength(at: 250, N.colourByISO)) < 1e-6)
        let at3200 = N.tuning(luminance: NoiseReduction.luminanceAmount(iso: 3200), colour: 0.5, iso: 3200)
        #expect(abs(at3200.luminance - N.strength(at: 3200, N.highTier)) < 1e-6 && at3200.impulse == 0)
        // The colour raised near neutral from the high tier up, and not below it.
        #expect(at250.colourNeutral == 0 && N.colourGain(at250) == nil)
        let at1250 = N.tuning(luminance: NoiseReduction.luminanceAmount(iso: 1250), colour: 0.5, iso: 1250)
        #expect(at1250.colourNeutral == 0 && N.colourGain(at1250) == nil)
        #expect(at3200.colourNeutral == N.neutralGain && at3200.colourWidth == N.neutralWidth)
        #expect(N.colourGain(at3200) == BayerDemosaic.ColourGain(neutral: N.neutralGain, width: N.neutralWidth))
        #expect(N.colourGain(N.tuning(luminance: 0.6, colour: 0, iso: 3200)) == nil)
        let at51200 = N.tuning(luminance: NoiseReduction.luminanceAmount(iso: 51200), colour: 0.5, iso: 51200)
        #expect(abs(at51200.luminance - N.strength(at: 51200, N.extremeTier)) < 1e-6 && at51200.impulse == N.extremeImpulse)
        // Interpolated in stops: a third of the way from 25600 to 51200 at 32254.
        let between = N.tuning(luminance: NoiseReduction.luminanceAmount(iso: 32254), colour: 0.5, iso: 32254)
        let a = N.extremeTier.first { $0.iso == 25600 }!.strength, b = N.extremeTier.first { $0.iso == 51200 }!.strength
        #expect(abs(between.luminance - (a + (b - a) * log2(Float(32254) / 25600))) < 1e-5)
        // Twice the amount, twice the strength; off is off and leaves the plain demosaic.
        let doubled = N.tuning(luminance: 0.8, colour: 1, iso: 250)
        #expect(abs(doubled.luminance - 2 * at250.luminance) < 1e-6 && abs(doubled.colour - 2 * at250.colour) < 1e-6)
        let off = N.tuning(luminance: 0, colour: 0, iso: 51200)
        #expect(off.luminance == 0 && off.colour == 0 && off.impulse == 0)
        #expect(N.levels(off, noise: SensorNoise(shot: 1, read: 1), parameters: BayerDemosaic.Parameters()) == nil)
        let unknown = N.tuning(luminance: NoiseReduction.luminanceAmount(iso: nil), colour: 0.5, iso: nil)
        #expect(abs(unknown.luminance - N.lowTier[0].strength) < 1e-6)
    }

    /// With thresholds near zero the pyramid gives back the plain demosaic to half-float precision,
    /// across tile edges, at an odd size and turned upright, so the noise reduction changes only what
    /// it means to.
    @Test func withoutThresholdsThePyramidIsTheDemosaic() throws {
        let harness = try DemosaicHarness()
        let width = 157, height = 98
        let samples = noisyMosaic(width: width, height: height, noise: SensorNoise(shot: 0, read: 0)) { x, y in
            let wave = 0.5 + 0.4 * sin(Double(x) * 0.31) * cos(Double(y) * 0.17)
            return SIMD3(0.3 * wave, x > 70 ? 0.6 : 0.15, 0.2 + 0.1 * Double(y) / Double(height))
        }
        for orientation in [1, 6] {
            let plain = try harness.run(samples, width: width, height: height, orientation: orientation)
            let tuning = InHouseNoiseReduction.Tuning(luminanceAmount: 1, colourAmount: 1, luminance: 1e-4, colour: 1e-4)
            let pyramid = try harness.run(samples, width: width, height: height, orientation: orientation, tuning: tuning)
            #expect(plain.width == pyramid.width && plain.height == pyramid.height)
            var worst: Float = 0
            for y in 0..<plain.height {
                for x in 0..<plain.width {
                    let a = plain.rgb(x, y), b = pyramid.rgb(x, y)
                    worst = max(worst, largest(a - b) / max(largest(a), 0.01))
                }
            }
            #expect(worst < 4e-3, "orientation \(orientation): worst relative difference \(worst)")
        }
    }

    /// A noisy grey field comes out several times quieter at the same mean, and a noisy step
    /// between two greys keeps its rise.
    @Test func flattensNoiseAndKeepsAnEdge() throws {
        let harness = try DemosaicHarness()
        let side = 256, noise = SensorNoise(shot: 8, read: 200)
        let samples = noisyMosaic(width: side, height: side, noise: noise, seed: 5) { x, _ in SIMD3(repeating: x < side / 2 ? 0.08 : 0.32) }
        let tuning = InHouseNoiseReduction.Tuning(luminanceAmount: 1, colourAmount: 1, luminance: 1, colour: 2)
        let plain = try harness.run(samples, width: side, height: side, matrix: [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
        let denoised = try harness.run(samples, width: side, height: side, matrix: [[1, 0, 0], [0, 1, 0], [0, 0, 1]], tuning: tuning)
        func stats(_ p: Pixels, _ columns: Range<Int>) -> (mean: Float, deviation: Float) {
            var values: [Float] = []
            for y in 20..<(p.height - 20) { for x in columns { values.append(p.rgb(x, y).y) } }
            let mean = values.reduce(0, +) / Float(values.count)
            return (mean, (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot())
        }
        for columns in [20..<100, 150..<230] {
            let before = stats(plain, columns), after = stats(denoised, columns)
            #expect(abs(after.mean / before.mean - 1) < 0.005, "\(columns): mean \(before.mean) to \(after.mean)")
            #expect(after.deviation < before.deviation / 3, "\(columns): deviation \(before.deviation) to \(after.deviation)")
        }
        // The step's 10 to 90 percent rise, averaged over rows, within a pixel of the plain one's.
        func rise(_ p: Pixels) -> Float {
            var profile = [Float](repeating: 0, count: 16)
            for y in 20..<(p.height - 20) { for i in 0..<16 { profile[i] += p.rgb(side / 2 - 12 + i, y).y } }
            let lo = profile[0], hi = profile[15]
            let q = profile.map { ($0 - lo) / (hi - lo) }
            func crossing(_ level: Float) -> Float {
                let i = (0..<15).first { q[$0] < level && q[$0 + 1] >= level } ?? 0
                return Float(i) + (level - q[i]) / (q[i + 1] - q[i])
            }
            return crossing(0.9) - crossing(0.1)
        }
        #expect(abs(rise(denoised) - rise(plain)) < 1, "rise \(rise(plain)) px plain, \(rise(denoised)) denoised")
    }

    /// A hot pixel in a flat field is pulled in with the impulse clamp on and left with it off.
    @Test func pullsInImpulses() throws {
        let harness = try DemosaicHarness()
        var samples = noisyMosaic(width: 64, height: 64, noise: SensorNoise(shot: 1, read: 20), seed: 9) { _, _ in SIMD3(repeating: 0.1) }
        samples[32 * 64 + 33] = 16000  // a green site
        let identity: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        var tuning = InHouseNoiseReduction.Tuning(luminanceAmount: 1, colourAmount: 1, luminance: 1e-4, colour: 1e-4)
        let kept = try harness.run(samples, width: 64, height: 64, matrix: identity, tuning: tuning)
        tuning.impulse = 4
        let pulled = try harness.run(samples, width: 64, height: 64, matrix: identity, tuning: tuning)
        // The crop starts 4 samples in.
        #expect(kept.rgb(29, 28).y > 0.5)
        #expect(pulled.rgb(29, 28).y < 0.12)
        #expect(abs(pulled.rgb(10, 10).y - kept.rgb(10, 10).y) < 1e-3)
    }

    /// The standard deviation of each detail level of a flat neutral field over the reference noise,
    /// for shot noise alone and read noise alone, with `matrix` (white-balanced camera RGB to the
    /// working space; the committed one when nil) and the default tuning's flat-area green.
    static func simulateLevelNoise(device: MTLDevice, matrix: [[Double]]? = nil, side: Int = 2048)
        throws -> (shot: [SIMD3<Float>], read: [SIMD3<Float>]) {
        let gpu = try GPU()
        let demosaic = try BayerDemosaic(device: device)
        let margin = 8, width = side + 2 * margin
        let layout = BayerMosaicLayout(pitch: width, cropOrigin: .init(x: margin, y: margin), cropSize: .init(width: side, height: side),
                                       validSize: .init(width: width, height: width), cfa: [0, 1, 1, 2],
                                       blackLevels: [512, 512, 512, 512], whiteLevel: 16383)
        var base = InHouseDecoder.parameters(for: layout, orientation: 1, gainStops: 0)
        if let matrix {
            let m = matrix.map { $0.map(Float.init) }
            base.matrix = (m[0][0], m[0][1], m[0][2], m[1][0], m[1][1], m[1][2], m[2][0], m[2][1], m[2][2])
        }
        // Any thresholds will do: the levels are read as reduced, before the rebuild.
        let unit = [SIMD3<Float>](repeating: SIMD3(1, 1, 1), count: InHouseNoiseReduction.shotNoise.count)
        let tuning = InHouseNoiseReduction.Tuning(luminanceAmount: 1, colourAmount: 1, luminance: 1, colour: 1,
                                                  shotNoise: unit, readNoise: unit)
        var result: [[SIMD3<Float>]] = []
        let offset = UInt64(ProcessInfo.processInfo.environment["ARGENT_SIM_SEED"] ?? "") ?? 0
        for (seed, noise) in [(11 + offset, SensorNoise(shot: 4, read: 0)), (12 + offset, SensorNoise(shot: 0, read: 1600))] {
            let samples = noisyMosaic(width: width, height: width, noise: noise, seed: seed) { _, _ in SIMD3(repeating: 0.1) }
            let buffer = device.makeBuffer(length: samples.count * 2, options: .storageModeShared)!
            samples.withUnsafeBytes { _ = memcpy(buffer.contents(), $0.baseAddress!, samples.count * 2) }
            var p = base
            InHouseNoiseReduction.apply(tuning, noise: noise, to: &p)
            let levels = try #require(InHouseNoiseReduction.levels(tuning, noise: noise, parameters: p))
            let full = try gpu.texturePool.acquire(width: side, height: side)
            let denoised = try gpu.texturePool.acquire(width: side, height: side)
            let commandBuffer = gpu.queue.makeCommandBuffer()!
            try demosaic.encode(mosaic: buffer, parameters: p, output: full.texture, into: commandBuffer)
            let pyramid = try demosaic.encode(mosaic: buffer, parameters: p, levels: levels, output: denoised.texture,
                                              pool: gpu.texturePool, into: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            // The full-size level in luminance and colour ratios, rows turned top down.
            let frame = OpponentLevel(full.texture, flip: true, lift: (p.liftShot, p.liftRead))
            let reduced = pyramid.prefix(levels.count).map { OpponentLevel($0.texture, flip: false, lift: nil) }
            let all = [frame] + reduced
            let (a, b) = InHouseNoiseReduction.reference(noise: noise, parameters: p)
            let y0 = frame.mean.x
            let reference = noise.shot > 0 ? (a * y0).squareRoot() : b.squareRoot()
            // Back to colour differences: the ratios' noise is the differences' over the base.
            let base = OpponentLevel.base(y0, p.liftShot, p.liftRead)
            let unit = SIMD3<Float>(reference, reference / base, reference / base)
            result.append((0..<levels.count).map { l in all[l].detailDeviation(coarser: all[l + 1]) / unit })
        }
        return (result[0], result[1])
    }
}

/// One pyramid level read back, in luminance and the two colour ratios, top down.
struct OpponentLevel {
    let width: Int
    let height: Int
    let values: [SIMD3<Float>]

    /// The colour ratios' denominator, as the shader's `nr_base`.
    static func base(_ y: Float, _ shot: Float, _ read: Float) -> Float {
        let lum = max(y, 0)
        return max(lum + (shot * lum + read).squareRoot(), 1e-6)
    }

    /// `lift`, when given, converts RGB to the pyramid's channels as the shader does.
    init(_ texture: MTLTexture, flip: Bool, lift: (shot: Float, read: Float)?) {
        let w = texture.width, h = texture.height
        var raw = [Float16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
        var out = [SIMD3<Float>](repeating: .zero, count: w * h)
        for y in 0..<h {
            let source = flip ? h - 1 - y : y
            for x in 0..<w {
                let i = (source * w + x) * 4
                let c = SIMD3(Float(raw[i]), Float(raw[i + 1]), Float(raw[i + 2]))
                if let lift {
                    let l = 0.2627 * c.x + 0.6780 * c.y + 0.0593 * c.z, d = Self.base(l, lift.shot, lift.read)
                    out[y * w + x] = SIMD3(l, (c.x - l) / d, (c.z - l) / d)
                } else {
                    out[y * w + x] = c
                }
            }
        }
        width = w
        height = h
        values = out
    }

    var mean: SIMD3<Float> { SIMD3<Float>(values.reduce(SIMD3<Double>.zero) { $0 + SIMD3<Double>($1) } / Double(values.count)) }

    /// The coarser level expanded to (x, y) as the shader does: binomial taps, edges repeated.
    func expanded(_ coarse: OpponentLevel, _ x: Int, _ y: Int) -> SIMD3<Float> {
        func taps(_ f: Int) -> (Int, [Float]) {
            let k = f >= 0 ? f / 2 : -((1 - f) / 2)
            return f & 1 == 0 ? (k - 1, [0.125, 0.75, 0.125]) : (k, [0.5, 0.5, 0])
        }
        let (bx, wx) = taps(x), (by, wy) = taps(y)
        var sum = SIMD3<Float>.zero
        for j in 0..<3 {
            let cy = min(max(by + j, 0), coarse.height - 1)
            for i in 0..<3 {
                let cx = min(max(bx + i, 0), coarse.width - 1)
                sum += wy[j] * wx[i] * coarse.values[cy * coarse.width + cx]
            }
        }
        return sum
    }

    /// The standard deviation of this level's detail against `coarser`, away from the edges.
    func detailDeviation(coarser: OpponentLevel) -> SIMD3<Float> {
        let margin = max(4, width / 32)
        var sum = SIMD3<Double>.zero, squares = SIMD3<Double>.zero, n = 0.0
        for y in margin..<(height - margin) {
            for x in margin..<(width - margin) {
                let d = SIMD3<Double>(values[y * width + x] - expanded(coarser, x, y))
                sum += d
                squares += d * d
                n += 1
            }
        }
        let mean = sum / n
        return SIMD3<Float>((squares / n - mean * mean).squareRoot())
    }
}
