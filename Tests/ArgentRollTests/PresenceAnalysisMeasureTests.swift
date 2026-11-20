import Foundation
import Metal
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// What Presence's analysis builds hold and take at a develop's size, against the develop's memory gate
/// (`PresenceAnalyses.developBytes`, docs/presence-plan.md section 4.3). Like `DevelopBudgetMeasureTests` they need the samples and
/// run only with ARGENT_MEASURE=1, in a release build with testing on, one process a test:
///
///     ARGENT_MEASURE=1 swift test -c release -Xswiftc -enable-testing --filter PresenceAnalysisMeasureTests/textureBand
@Suite(.serialized) struct PresenceAnalysisMeasureTests {
    static var enabled: Bool { FrameViewMeasureTests.enabled }
    static let sample = FrameViewMeasureTests.root.appendingPathComponent("samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")
    static let constants = PresenceConstants.named(Presence.currentVersion)!

    static func megabytes(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1e6) }

    /// How many texels of two `rg32Float` textures of one size differ in any bit.
    static func differing(_ a: MTLTexture, _ b: MTLTexture) -> Int {
        func texels(_ texture: MTLTexture) -> [UInt64] {
            var values = [UInt64](repeating: 0, count: texture.width * texture.height)
            values.withUnsafeMutableBytes { buffer in
                texture.getBytes(buffer.baseAddress!, bytesPerRow: texture.width * 8,
                                 from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            }
            return values
        }
        return zip(texels(a), texels(b)).filter { $0 != $1 }.count
    }

    /// One part built after a pause that lets Metal give back what the last build freed: the build's record, its wall time, and the
    /// kernel's peak footprint during it and what is held after it, above the footprint before it.
    static func measured<T>(_ builder: PresenceAnalysisBuilder, _ build: () throws -> T) async throws
        -> (made: T, build: PresenceAnalysisBuilder.Build, ms: Double, peak: Int, held: Int) {
        try await Task.sleep(for: .milliseconds(400))
        let base = physicalFootprint()
        resetFootprintPeak()
        let start = ContinuousClock.now
        let made = try build()
        let ms = FrameViewMeasureTests.ms(ContinuousClock.now - start)
        let peak = footprintPeakSinceReset() - base, held = physicalFootprint() - base
        return (made, try #require(builder.lastBuild), ms, peak, held)
    }

    /// Texture's band from the full-size decode, 3504 by 2336 at radius 10, built in bands of rows: what Metal allocated for it, the
    /// footprint's rise while it is made, and its time, five builds after one that compiles, against `developBytes`' Texture term.
    /// Then the band against the base's unbanded field, to the bit.
    @Test(.enabled(if: enabled))
    func textureBand() async throws {
        let gpu = try GPU(maxIdlePoolBytes: 300 << 20)
        let frame = try AppleRawDecoder(gpu: gpu).decode(Self.sample, options: DecodeOptions())
        let builder = PresenceAnalysisBuilder(device: gpu.device, queue: gpu.queue)
        let term = PresenceAnalyses.developBytes(try Presence([.texture: 30]), width: frame.width, height: frame.height)
        _ = try builder.texture(of: frame, constants: Self.constants)
        var times: [Double] = [], gpuTimes: [Double] = [], peaks: [Int] = []
        for _ in 0..<5 {
            let run = try await Self.measured(builder) { try builder.texture(of: frame, constants: Self.constants) }
            let allocated = run.build.workingBytes + run.build.keptBytes
            times.append(run.ms)
            gpuTimes.append(run.build.gpuSeconds * 1000)
            peaks.append(run.peak)
            print("MEASURE Presence Texture band \(frame.width)x\(frame.height): \(run.build.bands) bands of \(run.build.bandRows) rows, "
                  + "allocated \(Self.megabytes(allocated)) (working \(Self.megabytes(run.build.workingBytes)), kept "
                  + "\(Self.megabytes(run.build.keptBytes))), footprint peak +\(Self.megabytes(run.peak)), held +\(Self.megabytes(run.held)), "
                  + "term \(Self.megabytes(term))")
            #expect(run.build.workingBytes <= PresenceAnalyses.textureWorkingSetBudget && allocated <= term && run.peak <= term)
            withExtendedLifetime(run.made) {}
        }
        print("MEASURE Presence Texture band \(frame.width)x\(frame.height): wall \(FrameViewMeasureTests.summary(times)); "
              + "GPU \(FrameViewMeasureTests.summary(gpuTimes)); footprint peaks \(peaks.sorted().map(Self.megabytes))")

        let band = try builder.texture(of: frame, constants: Self.constants)
        let unbanded = try ToneBaseField(gpu: gpu).field(for: frame, parameters: band.field)
        let differing = Self.differing(band.coefficients, unbanded.texture)
        print("MEASURE Presence Texture band \(frame.width)x\(frame.height) against the unbanded field: \(differing) texels differ")
        #expect(differing == 0)
    }

    /// Dehaze's airlight at its 1024 field from the full-size decode: the CPU's wait for the field's light and its eroded least channel
    /// (the area average reads every frame pixel), and the CPU's quantile and median after it, seven builds after one that compiles.
    @Test(.enabled(if: enabled))
    func airlight() async throws {
        let gpu = try GPU(maxIdlePoolBytes: 300 << 20)
        let frame = try AppleRawDecoder(gpu: gpu).decode(Self.sample, options: DecodeOptions())
        let builder = PresenceAnalysisBuilder(device: gpu.device, queue: gpu.queue)
        let term = PresenceAnalyses.developBytes(try Presence([.dehaze: 30]), width: frame.width, height: frame.height)
        _ = try builder.haze(of: frame, constants: Self.constants)
        var waits: [Double] = [], quantiles: [Double] = [], times: [Double] = [], gpuTimes: [Double] = []
        for _ in 0..<7 {
            let run = try await Self.measured(builder) { try builder.haze(of: frame, constants: Self.constants) }
            waits.append(run.build.airlightWaitSeconds * 1000)
            quantiles.append(run.build.airlightSeconds * 1000)
            times.append(run.ms)
            gpuTimes.append(run.build.gpuSeconds * 1000)
            let allocated = run.build.workingBytes + run.build.keptBytes
            print("MEASURE Presence Dehaze \(frame.width)x\(frame.height): airlight \(run.made.airlight), allocated "
                  + "\(Self.megabytes(allocated)) (working \(Self.megabytes(run.build.workingBytes))), footprint peak "
                  + "+\(Self.megabytes(run.peak)), term \(Self.megabytes(term))")
            #expect(allocated <= term && run.peak <= term)
            #expect(run.made.airlight.min() > 0 && run.made.airlight.max().isFinite)
        }
        print("MEASURE Presence Dehaze airlight at 1024 from \(frame.width)x\(frame.height): wait \(FrameViewMeasureTests.summary(waits)); "
              + "quantile and median \(FrameViewMeasureTests.summary(quantiles)); whole build \(FrameViewMeasureTests.summary(times)); "
              + "GPU \(FrameViewMeasureTests.summary(gpuTimes))")
    }

    /// Dehaze on a field of one colour, as a backdrop or a chart can fill a frame: the airlight's quantile chooses every pixel.
    @Test(.enabled(if: enabled))
    func dehazeOnASquareFieldOfOneColour() async throws {
        let colour = SIMD3<Float>(0.3, 0.32, 0.35)
        try await Self.dehazeInAFreshProcess(width: 1024, height: 1024, airlight: colour) { _, _ in colour }
    }

    @Test(.enabled(if: enabled))
    func dehazeOnAThreeTwoFieldOfOneColour() async throws {
        let colour = SIMD3<Float>(0.3, 0.32, 0.35)
        try await Self.dehazeInAFreshProcess(width: 1024, height: 683, airlight: colour) { _, _ in colour }
    }

    /// A 3:2 field whose upper half is a sky clipped to one colour, over ground in a gradient with texture, every channel darker than
    /// the sky's least. The 12-pixel erosion leaves the sky's least channel on its first 329 rows, so the airlight chooses 336,896
    /// pixels, nearly half the field.
    @Test(.enabled(if: enabled))
    func dehazeOnAGradientHalfClipped() async throws {
        let sky = SIMD3<Float>(0.95, 1.0, 1.08), width = 1024, height = 683, horizon = height / 2
        try await Self.dehazeInAFreshProcess(width: width, height: height, airlight: sky) { x, y in
            guard y >= horizon else { return sky }
            let u = Float(x) / Float(width), depth = Float(y - horizon) / Float(height - horizon)
            let grain = Float((x &* 73_856_093 ^ y &* 19_349_663) & 1023) / 1023
            return SIMD3<Float>(0.42, 0.40, 0.36) * (1 - 0.8 * depth) * (0.85 + 0.3 * u) * (0.9 + 0.2 * grain)
        }
    }

    /// Dehaze built from a frame its field's own size, so the area average copies it, as the process's first large work: the frame is
    /// filled a row at a time and the kernels are compiled on a 16 by 16 frame first, so no memory the process freed before can hide
    /// what the build takes. Run one process a test. Each build's peak footprint is held under `developBytes`' Dehaze term, the first
    /// and seven more, and the seven give the airlight's CPU time. The airlight is the chosen colour, as a half float.
    static func dehazeInAFreshProcess(width: Int, height: Int, airlight chosen: SIMD3<Float>,
                                      pixel: (Int, Int) -> SIMD3<Float>) async throws {
        let gpu = try GPU(maxIdlePoolBytes: 300 << 20)
        func frame(_ width: Int, _ height: Int) throws -> LinearFrame {
            let texture = try gpu.makeTexture(width: width, height: height)
            var row = [Float16](repeating: 1, count: 4 * width)
            for y in 0..<height {
                for x in 0..<width {
                    let colour = pixel(x, y)
                    for channel in 0..<3 { row[4 * x + channel] = Float16(colour[channel]) }
                }
                row.withUnsafeBytes {
                    texture.replace(region: MTLRegionMake2D(0, y, width, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8 * width)
                }
            }
            return LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "measure", scale: 1)
        }
        let builder = PresenceAnalysisBuilder(device: gpu.device, queue: gpu.queue)
        _ = try builder.haze(of: try frame(16, 16), constants: Self.constants)
        let large = try frame(width, height)
        let term = PresenceAnalyses.developBytes(try Presence([.dehaze: 30]), width: width, height: height)
        let expected = SIMD3<Float>(Float(Float16(chosen.x)), Float(Float16(chosen.y)), Float(Float16(chosen.z)))
        var times: [Double] = []
        for build in 0..<8 {
            let run = try await Self.measured(builder) { try builder.haze(of: large, constants: Self.constants) }
            let recorded = run.build.workingBytes + run.build.keptBytes
            print("MEASURE Presence Dehaze \(width)x\(height), build \(build + 1)\(build == 0 ? " (the process's first)" : ""): recorded "
                  + "\(Self.megabytes(recorded)) (working \(Self.megabytes(run.build.workingBytes))), footprint peak "
                  + "+\(Self.megabytes(run.peak)), held +\(Self.megabytes(run.held)), term \(Self.megabytes(term)); airlight "
                  + "\(run.made.airlight), its CPU " + String(format: "%.2f ms", run.build.airlightSeconds * 1000))
            #expect(run.peak <= term, "footprint peak \(Self.megabytes(run.peak)) against \(Self.megabytes(term))")
            #expect(run.made.airlight == expected)
            if build > 0 { times.append(run.build.airlightSeconds * 1000) }
        }
        print("MEASURE Presence Dehaze \(width)x\(height): the airlight's CPU \(FrameViewMeasureTests.summary(times))")
    }

    /// A develop's whole analysis of the full-size decode, Texture's band, Clarity's fields and Dehaze's, built in the cache's order
    /// through the cache a develop runs (it keeps none), five times after one that compiles: the footprint's peak rise against
    /// `developBytes` for all three, and what each part's build allocated, from the builder alone in the same order.
    @Test(.enabled(if: enabled))
    func wholeAnalysis() async throws {
        let gpu = try GPU(maxIdlePoolBytes: 300 << 20)
        let frame = try AppleRawDecoder(gpu: gpu).decode(Self.sample, options: DecodeOptions())
        let builder = PresenceAnalysisBuilder(device: gpu.device, queue: gpu.queue)
        let develop = PresenceAnalyses(builder: builder, maximumBytes: 0)
        let presence = try Presence([.texture: 40, .clarity: -30, .dehaze: 60])
        let parts = PresenceAnalysis.Parts.needed(by: presence)
        let term = PresenceAnalyses.developBytes(presence, width: frame.width, height: frame.height)
        _ = try develop.analysis(of: frame, parts: parts, constants: Self.constants)
        var peaks: [Int] = [], times: [Double] = []
        for _ in 0..<5 {
            let run = try await Self.measured(builder) { try develop.analysis(of: frame, parts: parts, constants: Self.constants) }
            peaks.append(run.peak)
            times.append(run.ms)
            #expect(run.made.parts == parts && develop.residentBytes == 0)
            #expect(run.peak <= term, "footprint peak \(Self.megabytes(run.peak)) against \(Self.megabytes(term))")
            withExtendedLifetime(run.made) {}
        }
        var allocated: [String] = [], sum = 0
        try await Task.sleep(for: .milliseconds(400))
        for (name, build) in [("Texture", { _ = try builder.texture(of: frame, constants: Self.constants) }),
                              ("Clarity", { _ = try builder.clarity(of: frame, constants: Self.constants) }),
                              ("Dehaze", { _ = try builder.haze(of: frame, constants: Self.constants) })] as [(String, () throws -> Void)] {
            try build()
            let made = try #require(builder.lastBuild)
            sum += made.workingBytes + made.keptBytes
            allocated.append("\(name) \(Self.megabytes(made.workingBytes)) working and \(Self.megabytes(made.keptBytes)) kept")
        }
        print("MEASURE Presence whole analysis \(frame.width)x\(frame.height): footprint peaks \(peaks.sorted().map(Self.megabytes)), "
              + "wall \(FrameViewMeasureTests.summary(times)); allocated \(Self.megabytes(sum)) (\(allocated.joined(separator: ", "))); "
              + "developBytes \(Self.megabytes(term))")
        #expect(sum <= term)
    }

    /// F2 Q9 on the CC0 sample (the probe's p-raw): a quarter-size decode's airlight against the full-size decode's, each made from its
    /// own decode's 1024 field, as the frame view's preview and the develop make theirs. The bar is F2's table for this frame, made by
    /// `fit_dehaze.py`: every channel within 0.25 %, where the table's furthest, blue, is 0.2225 % apart and F2's text rounded that to
    /// 0.2 %. Beside it, within 0.0003 in u'v', where the table has 0.00027, and 0.25 % in luminance.
    @Test(.enabled(if: enabled))
    func aQuarterDecodesAirlightIsTheFullDecodes() throws {
        let gpu = try GPU(maxIdlePoolBytes: 300 << 20)
        let decoder = AppleRawDecoder(gpu: gpu)
        let builder = PresenceAnalysisBuilder(device: gpu.device, queue: gpu.queue)
        let full = try builder.haze(of: try decoder.decode(Self.sample, options: DecodeOptions()), constants: Self.constants).airlight
        var options = DecodeOptions()
        options.scale = 0.25
        let small = try decoder.decode(Self.sample, options: options)
        let quarter = try builder.haze(of: small, constants: Self.constants).airlight
        /// CIE XYZ of linear Rec. 2020 light (D65).
        func xyz(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3((SIMD3<Float>(0.636958, 0.144617, 0.168881) * rgb).sum(), (SIMD3<Float>(0.2627, 0.677998, 0.059302) * rgb).sum(),
                  (SIMD3<Float>(0, 0.028073, 1.060985) * rgb).sum())
        }
        func chromaticity(_ rgb: SIMD3<Float>) -> SIMD2<Float> {
            let c = xyz(rgb), d = c.x + 15 * c.y + 3 * c.z
            return SIMD2(4 * c.x / d, 9 * c.y / d)
        }
        let uv = chromaticity(quarter) - chromaticity(full), distance = (uv * uv).sum().squareRoot()
        let luminance = abs(xyz(quarter).y - xyz(full).y) / xyz(full).y
        let share = (quarter - full) / full, channels = max(abs(share.x), abs(share.y), abs(share.z))
        print(String(format: "MEASURE Presence Dehaze airlight, full size (%.4f, %.4f, %.4f), quarter %dx%d (%.4f, %.4f, %.4f): %.5f apart "
                     + "in u'v', luminance %.3f %% apart, the furthest channel %.3f %%", full.x, full.y, full.z, small.width, small.height,
                     quarter.x, quarter.y, quarter.z, distance, luminance * 100, channels * 100))
        #expect(channels <= 0.0025 && distance <= 0.0003 && luminance <= 0.0025)
    }
}
