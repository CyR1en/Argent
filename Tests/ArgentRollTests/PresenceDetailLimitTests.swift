import Foundation
import Metal
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// Clarity's and Texture's summed stops are held to `detailLimitStops`, a limit both design candidates guessed. Pixels of F1b's held-out
/// photographs do pass it, so the suite holds what the limit does to their scores. Each held-out photograph (round 1's seven, round 2's
/// twenty) is developed as the scorecard develops it: under the explicit aim of `fit_clarity_round2.aim_flags`, which is Auto's rating
/// and lab balance with the reference at the aim's level and no tone step, at full size with no lens correction, on both stocks. At each
/// value a bar scores, the test counts the pixels whose unclamped stops pass the limit. Where any do, it renders the print with the limit
/// and with the limit out of reach. The rms of the two prints' L* difference over the grid the bar scores (the 4 x 4 blocks for Clarity,
/// the central 2048 crop's pixels for Texture) is the scorer's `apart` of the two prints, so it is the most the limit can move that run's
/// parity. The test holds it to `runChange` on each run, and to `barChange` averaged over each bar's runs. Both controls together at
/// ±100, which no bar scores, are counted and measured but not held. It reads the probe's photographs from the main checkout's
/// `references/` (restricted data, never in Git), so it runs only when asked:
///
///     ARGENT_PRESENCE_HELD_OUT=1 swift test --filter PresenceDetailLimitTests
@Suite(.serialized) struct PresenceDetailLimitTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["ARGENT_PRESENCE_HELD_OUT"] != nil }
    static let probe = URL(fileURLWithPath: "/Users/cyr1en/Documents/ArgentResearch/presence-20261111.noindex/probe")
    /// `fit_clarity_round2.py`'s `HELD`; round 2's are its manifest's photographs.
    static let roundOne = ["p-photo-hazy", "p-photo-skin", "p-photo-saturated", "p-photo-foliage", "p-photo-night", "p-photo-flat", "p-photo-contrast"]
    static let stocks = ["kodak-portra-400", "kodak-ektar-100"]
    /// A tenth of an L* step, on any one run.
    static let runChange: Float = 0.1
    /// The precision the bars are written to (`validate/detail/bars.json`), on a bar's mean over its runs.
    static let barChange: Float = 0.01
    /// Each bar's runs in `bars.json`: every frame on both stocks, and round 1's alone for Texture at ±50.
    static let barRuns = ["clarity -100": 54, "clarity -50": 54, "clarity 50": 54, "clarity 100": 54,
                          "texture -100": 54, "texture -50": 14, "texture 50": 14, "texture 100": 54]

    /// The values a bar scores on `frame`, each control alone: Clarity's four, and Texture's ±100 and, on round 1's frames, ±50, since
    /// round 2 has Texture at ±100 only. Then both controls together at ±100.
    static func cases(_ frame: String) -> [[Presence.Control: Float]] {
        let values: [Float] = [-100, -50, 50, 100]
        return values.map { [.clarity: $0] } + values.filter { abs($0) == 100 || roundOne.contains(frame) }.map { [.texture: $0] }
            + [[.clarity: 100, .texture: 100], [.clarity: -100, .texture: -100]]
    }

    struct Job: Decodable { let name: String; let source: String; let kind: String }

    static func frames() throws -> [(name: String, raw: URL)] {
        func jobs(_ path: String) throws -> [Job] {
            struct Manifest: Decodable { let jobs: [Job] }
            return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: probe.appendingPathComponent(path))).jobs
        }
        let first = try jobs("manifest.json").filter { roundOne.contains($0.name) }
        let second = try jobs("round2/manifest.json").filter { $0.kind == "photo" }
        return (first + second).map { ($0.name, URL(fileURLWithPath: $0.source)) }
    }

    static let kernels = """

    /// The largest positive and negative unclamped stops over every pixel of `frame`, as `presence_detail_stops` sums them, and how
    /// many pixels pass `limit` either way.
    kernel void presence_detail_extremes(texture2d<half, access::read> frame [[texture(0)]], device atomic_uint *extremes [[buffer(0)]],
                                         constant float &limit [[buffer(1)]],
                                         \(ShaderSource.presenceSceneSignature)
                                         uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= frame.get_width() || gid.y >= frame.get_height()) { return; }
        float2 uv = (float2(gid) + 0.5f) / float2(frame.get_width(), frame.get_height());
        float stops = presence_detail_stops(manual_guide(float3(frame.read(gid).rgb)), uv, presence, presenceWeights, clarityField, textureField);
        atomic_fetch_max_explicit(&extremes[0], as_type<uint>(max(stops, 0.0f)), memory_order_relaxed);
        atomic_fetch_max_explicit(&extremes[1], as_type<uint>(max(-stops, 0.0f)), memory_order_relaxed);
        if (abs(stops) > limit) { atomic_fetch_add_explicit(&extremes[2], 1u, memory_order_relaxed); }
    }

    /// The scorer's print L*: CIE L* of the print's D50 luminance (`fit_texture_clarity.PRINT_Y`), white 1 (`probe.lstar`).
    static float limit_lstar(float3 rgb) {
        float y = max(dot(rgb, float3(0.2790425847f, 0.6753444959f, 0.0456129194f)), 0.0f);
        return 116.0f * (y > 216.0f / 24389.0f ? pow(y, 1.0f / 3.0f) : y * (841.0f / 108.0f) + 4.0f / 29.0f) - 16.0f;
    }

    /// One row of the two prints' 4 x 4 blocks: the sum of the squared L* difference of the blocks' mean luminance, and its largest size.
    kernel void presence_limit_blocks(texture2d<half, access::read> a [[texture(0)]], texture2d<half, access::read> b [[texture(1)]],
                                      device float2 *rows [[buffer(0)]], uint row [[thread_position_in_grid]]) {
        if (row >= a.get_height() / 4) { return; }
        float sum = 0.0f, largest = 0.0f;
        for (uint x = 0; x < a.get_width() / 4; x++) {
            float3 ma = 0.0f, mb = 0.0f;
            for (uint j = 0; j < 16; j++) {
                uint2 p = uint2(4 * x + j % 4, 4 * row + j / 4);
                ma += float3(a.read(p).rgb);
                mb += float3(b.read(p).rgb);
            }
            float d = limit_lstar(ma / 16.0f) - limit_lstar(mb / 16.0f);
            sum += d * d;
            largest = max(largest, abs(d));
        }
        rows[row] = float2(sum, largest);
    }

    /// One row of the two prints' central 2048 crop, per pixel, as `presence_limit_blocks`.
    kernel void presence_limit_crop(texture2d<half, access::read> a [[texture(0)]], texture2d<half, access::read> b [[texture(1)]],
                                    device float2 *rows [[buffer(0)]], uint row [[thread_position_in_grid]]) {
        if (row >= 2048) { return; }
        uint2 origin = (uint2(a.get_width(), a.get_height()) - 2048) / 2;
        float sum = 0.0f, largest = 0.0f;
        for (uint x = 0; x < 2048; x++) {
            uint2 p = origin + uint2(x, row);
            float d = limit_lstar(float3(a.read(p).rgb)) - limit_lstar(float3(b.read(p).rgb));
            sum += d * d;
            largest = max(largest, abs(d));
        }
        rows[row] = float2(sum, largest);
    }
    """

    struct Change {
        let blocks: Float, largestBlock: Float, crop: Float, largestPixel: Float
        /// No pixel passes the limit, so clamping changes no pixel's stops and the two prints are the same.
        static let none = Change(blocks: 0, largestBlock: 0, crop: 0, largestPixel: 0)
    }

    @Test(.enabled(if: enabled)) func theLimitMovesNoHeldOutScoreByMoreThanATenthOfAnLStep() throws {
        let gpu = try GPU()
        let library = try gpu.device.makeLibrary(source: [ShaderSource.toneBase, ShaderSource.lut3D].joined(separator: "\n") + Self.kernels, options: nil)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            try gpu.device.makeComputePipelineState(function: try #require(library.makeFunction(name: name)))
        }
        let kernels = (extremes: try pipeline("presence_detail_extremes"), blocks: try pipeline("presence_limit_blocks"),
                       crop: try pipeline("presence_limit_crop"))
        let placeholders = try ManualSceneInputs.Placeholders(gpu: gpu)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let stocks = try Self.stocks.map { try Stock.load(from: root.appendingPathComponent("build/stocks/\($0)").resolvingSymlinksInPath()) }
        let decoder = AppleRawDecoder(gpu: gpu)
        var options = DecodeOptions()
        options.lensCorrection = false
        var sheet = DecodeOptions()
        sheet.maxLongSide = FilmPreviews.previewLongSide
        let limit = try #require(PresenceConstants.named(Presence.currentVersion)).detailLimitStops
        var bars: [String: [Float]] = [:]
        var largest: (change: Float, at: String) = (0, "")
        var pixels = 0, reaching = 0
        let frames = try Self.frames()
        #expect(frames.count == 27)
        for (name, raw) in frames {
            try autoreleasepool {
                // As fit_dehaze.aim_flags: --auto's aim from the sheet decode, its rating and lab balance, the reference at its level,
                // and no tone step.
                let aim = AutoPrint.aim(ExposureAnalyzer.measure(try decoder.decode(raw, options: sheet), workingSpace: gpu.workingColorSpace,
                                                                 info: try? ARWFrameInfo.read(from: raw)).analysis)
                let frame = try decoder.decode(raw, options: options)
                for stock in stocks {
                    let renderer = try FilmRenderer(gpu: gpu, stock: stock)
                    let automatic = RollControls().settings(for: stock, aim: aim)
                    var settings = DevelopSettings()
                    (settings.ratedAt, settings.labBalance) = (automatic.ratedAt, automatic.labBalance)
                    var row: [String] = []
                    for values in Self.cases(name) {
                        settings.manual = try ManualRenderSettings(adjustments: ManualAdjustments(presence: try Presence(values)), referenceStops: aim.level)
                        let limited = try renderer.presenceInputs(frame, settings: settings, exposureStops: settings.exposureStops(boxSpeed: stock.boxSpeed),
                                                                  printOffset: settings.printOffset(densityRange: stock.densityRange,
                                                                                                    exposurePerUnit: stock.exposurePerUnit))
                        var unlimited = limited
                        unlimited.scene.parameters.detailLimit = .greatestFiniteMagnitude
                        let found = try Self.extremes(gpu, kernels.extremes, frame, unlimited.scene, limit, placeholders)
                        var change = Change.none
                        if found.count > 0 {
                            // Both prints are held until they are compared, so the pool cannot hand the first one's texture to the second.
                            let prints = (try renderer.render(frame, settings: settings, presence: limited),
                                          try renderer.render(frame, settings: settings, presence: unlimited))
                            change = try withExtendedLifetime(prints) {
                                try Self.change(gpu, kernels.blocks, kernels.crop, prints.0.image.texture, prints.1.image.texture)
                            }
                        }
                        let label = values.map { "\($0.key.rawValue) \(Int($0.value))" }.sorted().joined(separator: " ")
                        row.append(label + String(format: " %+.2f/-%.2f %d px, blocks %.5f (largest %.3f), crop %.5f (largest %.3f)", found.positive,
                                                  found.negative, found.count, change.blocks, change.largestBlock, change.crop, change.largestPixel))
                        guard values.count == 1, let control = values.keys.first else { continue }
                        let moved = control == .clarity ? change.blocks : change.crop
                        bars[label, default: []].append(moved)
                        (pixels, reaching) = (pixels + found.count, reaching + (found.count > 0 ? 1 : 0))
                        if moved > largest.change { largest = (moved, "\(name) \(stock.id) \(label)") }
                        #expect(moved <= Self.runChange, "\(name) \(stock.id) \(label): \(found.count) pixels past the limit move the print \(change)")
                    }
                    print("[evidence] detail limit \(name) \(stock.id): " + row.joined(separator: ", "))
                }
            }
        }
        #expect(bars.mapValues(\.count) == Self.barRuns)
        for (label, moved) in bars.sorted(by: { $0.key < $1.key }) {
            let mean = moved.reduce(0, +) / Float(moved.count)
            print("[evidence] detail limit \(label): \(moved.count) runs, \(moved.filter { $0 > 0 }.count) moved, the largest by \(moved.max() ?? 0) "
                  + "and the mean by \(mean) L* rms")
            #expect(mean <= Self.barChange, "\(label): the limit moves its runs by \(mean) L* rms on average")
        }
        print("[evidence] detail limit: \(pixels) pixels pass it over \(reaching) of \(bars.values.map(\.count).reduce(0, +)) scored runs; the largest "
              + "move is \(largest.change) L* rms (\(largest.at)), against \(Self.runChange) a run and \(Self.barChange) a bar")
    }

    static func extremes(_ gpu: GPU, _ pipeline: MTLComputePipelineState, _ frame: LinearFrame, _ inputs: PresenceSceneInputs, _ limit: Float,
                         _ placeholders: ManualSceneInputs.Placeholders) throws -> (positive: Float, negative: Float, count: Int) {
        let buffer = try #require(gpu.device.makeBuffer(length: 12, options: .storageModeShared))
        memset(buffer.contents(), 0, 12)
        var limit = limit
        let commandBuffer = try #require(gpu.queue.makeCommandBuffer()), encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(frame.texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes(&limit, length: MemoryLayout<Float>.size, index: 1)
        inputs.bind(to: encoder, placeholders: placeholders)
        encoder.dispatchPixels(pipeline, width: frame.width, height: frame.height)
        encoder.endEncoding()
        commandBuffer.commit()
        withExtendedLifetime((frame, inputs)) { commandBuffer.waitUntilCompleted() }
        let bits = buffer.contents().bindMemory(to: UInt32.self, capacity: 3)
        return (Float(bitPattern: bits[0]), Float(bitPattern: bits[1]), Int(bits[2]))
    }

    /// The L* difference of two prints: rms and largest over the 4 x 4 blocks, and over the central 2048 crop's pixels.
    static func change(_ gpu: GPU, _ blocks: MTLComputePipelineState, _ crop: MTLComputePipelineState, _ a: MTLTexture, _ b: MTLTexture) throws -> Change {
        func rows(_ pipeline: MTLComputePipelineState, _ count: Int, width: Int) throws -> (rms: Float, largest: Float) {
            let buffer = try #require(gpu.device.makeBuffer(length: count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared))
            let commandBuffer = try #require(gpu.queue.makeCommandBuffer()), encoder = try #require(commandBuffer.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(a, index: 0)
            encoder.setTexture(b, index: 1)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            encoder.dispatchPixels(pipeline, width: count, height: 1)
            encoder.endEncoding()
            commandBuffer.commit()
            withExtendedLifetime((a, b)) { commandBuffer.waitUntilCompleted() }
            let sums = UnsafeBufferPointer(start: buffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: count), count: count)
            return (Float((sums.reduce(0) { $0 + Double($1.x) } / Double(count * width)).squareRoot()), sums.map(\.y).max() ?? 0)
        }
        let (b, c) = (try rows(blocks, a.height / 4, width: a.width / 4), try rows(crop, 2048, width: 2048))
        return Change(blocks: b.rms, largestBlock: b.largest, crop: c.rms, largestPixel: c.largest)
    }
}
