import Accelerate
import ArgentCore
import Foundation
import Metal
import Testing
@testable import ArgentRoll

/// Where patches of one picture lie in another of the same pixels, by
/// `PreviewOutputMeasureTests/registrationExhaustive`'s method: L* of each picture blurred by σ = 1
/// px, 128-pixel patches on a 4 by 3 grid, every whole shift within `reach` pixels by normalized
/// correlation, then a parabola through the best's neighbours. Only the windows the patches need
/// are blurred and the correlations run on Accelerate, which makes it quick enough for a regular
/// test; on the same pictures it gives that test's own search's numbers to 1e-7 px (verified).
enum PatchRegistration {
    /// The patch of the reference centred at `x`, `y` lies `dx`, `dy` pixels away in the moving
    /// picture, with normalized correlation `r`. Coordinates are a texture's, rows bottom up.
    struct Patch {
        var x: Int, y: Int
        var dx: Double, dy: Double
        var r: Double
    }

    struct Result {
        var patches: [Patch]
        /// Least-squares fits over the matched patches: dx = shift.x + scale.x (x − width / 2), and
        /// likewise dy, in pixels and pixels per pixel.
        var shift: SIMD2<Double>
        var scale: SIMD2<Double>

        /// The patches found with r above 0.8, as `registrationExhaustive` fits them.
        var matched: [Patch] { patches.filter { $0.r > 0.8 } }
        /// The largest |dx| and |dy| over the matched patches, infinite when none matched.
        var largest: SIMD2<Double> {
            let patches = matched
            guard !patches.isEmpty else { return SIMD2<Double>(repeating: .infinity) }
            var x = 0.0, y = 0.0
            for patch in patches {
                x = max(x, abs(patch.dx))
                y = max(y, abs(patch.dy))
            }
            return SIMD2<Double>(x, y)
        }
        var text: String {
            String(format: "shift at centre %+.3f, %+.3f px; scale %+.3f, %+.3f px per 1000 px; largest %.3f, %.3f px (%d of %d patches)",
                   shift.x, shift.y, 1000 * scale.x, 1000 * scale.y, largest.x, largest.y, matched.count, patches.count)
        }
    }

    /// Where `reference`'s patches lie in `moving`, over the pixels the two share from the origin.
    static func register(_ moving: Pixels, against reference: Pixels, side: Int = 128, reach: Int = 16) -> Result {
        let w = min(moving.width, reference.width), h = min(moving.height, reference.height)
        let n = side + 2 * reach
        var patches: [Patch] = []
        for fy in [0.2, 0.5, 0.8] {
            for fx in [0.15, 0.38, 0.62, 0.85] {
                let cx = Int(fx * Double(w)), cy = Int(fy * Double(h))
                // In double precision, as that test has it: a single-precision mean left over in the
                // patch leaks the window's mean into the correlation and tilts a broad peak.
                var patch = lightness(reference, width: w, height: h, x0: cx - side / 2, y0: cy - side / 2, side: side).map(Double.init)
                let mean = patch.reduce(0, +) / Double(patch.count)
                let norm = patch.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }.squareRoot()
                patch = patch.map { ($0 - mean) / max(norm, 1e-9) }
                let window = lightness(moving, width: w, height: h, x0: cx - side / 2 - reach, y0: cy - side / 2 - reach, side: n)
                    .map(Double.init)
                // Each shifted patch's sum and sum of squares, from summed-area tables of the window.
                let stride = n + 1
                var sums = [Double](repeating: 0, count: stride * stride), squares = sums
                for y in 0..<n {
                    for x in 0..<n {
                        let v = window[y * n + x], at = (y + 1) * stride + x + 1
                        sums[at] = v + sums[at - 1] + sums[at - stride] - sums[at - stride - 1]
                        squares[at] = v * v + squares[at - 1] + squares[at - stride] - squares[at - stride - 1]
                    }
                }
                func box(_ table: [Double], _ x: Int, _ y: Int) -> Double {
                    let top = (y + side) * stride, bottom = y * stride
                    let inside: Double = table[top + x + side] - table[bottom + x + side]
                    return inside - table[top + x] + table[bottom + x]
                }
                let count = Double(side * side)
                var scores = [[Double]](repeating: [Double](repeating: 0, count: 2 * reach + 1), count: 2 * reach + 1)
                var best = (dx: 0, dy: 0, r: -2.0)
                window.withUnsafeBufferPointer { moved in
                    patch.withUnsafeBufferPointer { fixed in
                        for dy in -reach...reach {
                            for dx in -reach...reach {
                                let x = reach + dx, y = reach + dy
                                var row = 0.0, product = 0.0
                                for line in 0..<side {
                                    vDSP_dotprD(fixed.baseAddress! + line * side, 1, moved.baseAddress! + (y + line) * n + x, 1,
                                                &row, vDSP_Length(side))
                                    product += row
                                }
                                let sum = box(sums, x, y)
                                let spread = max(box(squares, x, y) - sum * sum / count, 1e-18).squareRoot()
                                let r = product / spread
                                scores[dy + reach][dx + reach] = r
                                if r > best.r { best = (dx, dy, r) }
                            }
                        }
                    }
                }
                func vertex(_ a: Double, _ b: Double, _ c: Double) -> Double {
                    let d = a - 2 * b + c
                    return abs(d) < 1e-12 ? 0 : 0.5 * (a - c) / d
                }
                var dx = Double(best.dx), dy = Double(best.dy)
                if abs(best.dx) < reach {
                    dx += vertex(scores[best.dy + reach][best.dx + reach - 1], best.r, scores[best.dy + reach][best.dx + reach + 1])
                }
                if abs(best.dy) < reach {
                    dy += vertex(scores[best.dy + reach - 1][best.dx + reach], best.r, scores[best.dy + reach + 1][best.dx + reach])
                }
                patches.append(Patch(x: cx, y: cy, dx: dx, dy: dy, r: best.r))
            }
        }
        let matched = patches.filter { $0.r > 0.8 }
        func fit(_ u: [Double], _ v: [Double]) -> (offset: Double, slope: Double) {
            guard !u.isEmpty else { return (.nan, .nan) }
            let mu = u.reduce(0, +) / Double(u.count), mv = v.reduce(0, +) / Double(v.count)
            let suu = zip(u, u).map { ($0 - mu) * ($1 - mu) }.reduce(0, +)
            let suv = zip(u, v).map { ($0 - mu) * ($1 - mv) }.reduce(0, +)
            let slope = suu > 0 ? suv / suu : 0
            return (mv - slope * mu, slope)
        }
        let x = fit(matched.map { Double($0.x) - Double(w) / 2 }, matched.map(\.dx))
        let y = fit(matched.map { Double($0.y) - Double(h) / 2 }, matched.map(\.dy))
        return Result(patches: patches, shift: SIMD2<Double>(x.offset, y.offset), scale: SIMD2<Double>(x.slope, y.slope))
    }

    /// L* of the picture's first `width` by `height` pixels blurred by a sampled Gaussian of σ = 1
    /// px, edges repeated, over the `side` by `side` window from `x0`, `y0`, its coordinates
    /// clamped to the picture: what `Picture.blurred(sigma: 1).lightness` gives there.
    static func lightness(_ p: Pixels, width w: Int, height h: Int, x0: Int, y0: Int, side: Int) -> [Float] {
        let radius = 3
        let raw = (-radius...radius).map { exp(-Float($0 * $0) / 2) }
        let total = raw.reduce(0, +)
        let weights = raw.map { $0 / total }
        func column(_ x: Int) -> Int { min(max(x, 0), w - 1) }
        func row(_ y: Int) -> Int { min(max(y, 0), h - 1) }
        let low = max(0, row(y0) - radius), high = min(h - 1, row(y0 + side - 1) + radius)
        // Across, on every picture row the window's rows reach.
        var across = [SIMD3<Float>](repeating: .zero, count: (high - low + 1) * side)
        for y in low...high {
            for i in 0..<side {
                let x = column(x0 + i)
                var sum = SIMD3<Float>.zero
                for k in -radius...radius {
                    let at = (y * p.width + column(x + k)) * 4
                    let pixel = SIMD3<Float>(Float(p.values[at]), Float(p.values[at + 1]), Float(p.values[at + 2]))
                    sum += weights[k + radius] * pixel
                }
                across[(y - low) * side + i] = sum
            }
        }
        var out = [Float](repeating: 0, count: side * side)
        for j in 0..<side {
            let y = row(y0 + j)
            for i in 0..<side {
                var sum = SIMD3<Float>.zero
                for k in -radius...radius { sum += weights[k + radius] * across[(row(y + k) - low) * side + i] }
                let luminance = 0.2627 * sum.x + 0.6780 * sum.y + 0.0593 * sum.z
                out[j * side + i] = luminance > 0.008856 ? 116 * cbrt(luminance) - 16 : 903.3 * luminance
            }
        }
        return out
    }

    /// The frame view's decode of `url` at `longSide` pixels against the full-size decode
    /// `full` area-resized to the picture's long side, as a develop resizes: where the file's
    /// patches lie in the frame view's picture. A window longer than the raw gets the whole raw.
    static func frameView(_ url: URL, longSide: Int, against full: LinearFrame, decoder: AppleRawDecoder,
                          resize: AreaResize) throws -> (preview: LinearFrame, file: PooledTexture, result: Result) {
        let preview = try decoder.decode(url, options: FilmPreviews.frameDecodeOptions(longSide: longSide))
        let file = try resize.resized(full.texture, scale: Double(max(preview.width, preview.height)) / Double(max(full.width, full.height)))
        return (preview, file, register(Pixels(preview.texture), against: Pixels(file.texture)))
    }
}

/// Runs only where the CC0 sample raws from `scripts/fetch-samples.sh` are present.
@Suite struct FrameViewRegistrationSampleTests {
    private static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples")
    static let small = samples.appendingPathComponent("ILCE-7M4_DSC06676_FullFrame-LossLess-Compressed-Small.ARW")
    static let medium = samples.appendingPathComponent("ILCE-7M4_DSC06675_FullFrame-LossLess-Compressed-Medium.ARW")
    static var hasSamples: Bool { [small, medium].allSatisfy { FileManager.default.fileExists(atPath: $0.path) } }

    /// The frame view's picture of a full-frame lossless S frame lies where the file's pixels do
    /// once the file is resized to it: every patch within 0.3 px. Until 2026-10-16 it showed 0.2
    /// percent less of the frame than the file, magnified to fit, which put patches up to 2.8 px off
    /// at 1690 (docs/M3-auto.md, section 41). The sizes are a draft decode whose rows fall almost
    /// half a pixel between the decode's (1200), the M3 acceptance window, whose rows also end a third
    /// of a pixel off whole (1690), and a decode above half scale (2600).
    @Test(.enabled(if: FrameViewRegistrationSampleTests.hasSamples))
    func losslessSmallPreviewsLieWhereTheFileDoes() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let decoder = AppleRawDecoder(gpu: gpu)
        let resize = try AreaResize(gpu: gpu)
        let full = try decoder.decode(Self.small, options: DecodeOptions())
        #expect(full.width == 3480 && full.height == 2320)
        for longSide in [1200, 1690, 2600] {
            let (preview, file, result) = try PatchRegistration.frameView(Self.small, longSide: longSide, against: full,
                                                                          decoder: decoder, resize: resize)
            print("MEASURE frame view against the file, lossless S at \(longSide): \(result.text)")
            #expect(preview.width == longSide && preview.height == file.height, "\(longSide): \(preview.width) by \(preview.height)")
            #expect(preview.scale == Float(longSide) / 3480)
            #expect(result.matched.count == 12, "\(longSide)")
            #expect(result.largest.x <= 0.3 && result.largest.y <= 0.3, "\(longSide): \(result.text)")
        }
    }

    /// Apple places lossless M's window at its own (4, 4) inside the valid data, so it has no trim
    /// and its frame view lies where the file does as every untrimmed mode's does (docs/M3-auto.md,
    /// section 41). The sizes have whole rows at 3:2; at the others a scaled decode's rows end up to
    /// a third of a pixel off the file's at the top, as uncompressed frames' do.
    @Test(.enabled(if: FrameViewRegistrationSampleTests.hasSamples))
    func losslessMediumPreviewsLieWhereTheFileDoes() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let decoder = AppleRawDecoder(gpu: gpu)
        let resize = try AreaResize(gpu: gpu)
        let full = try decoder.decode(Self.medium, options: DecodeOptions())
        #expect(full.width == 4608 && full.height == 3072 && full.pins?.trimColumns == 0)
        for longSide in [900, 2190] {
            let (preview, _, result) = try PatchRegistration.frameView(Self.medium, longSide: longSide, against: full,
                                                                       decoder: decoder, resize: resize)
            print("MEASURE frame view against the file, lossless M at \(longSide): \(result.text)")
            #expect(preview.width == longSide)
            #expect(result.matched.count == 12, "\(longSide)")
            #expect(result.largest.x <= 0.3 && result.largest.y <= 0.3, "\(longSide): \(result.text)")
        }
    }
}

/// The frame view against the file over the window sizes the frame view takes, for the record
/// (docs/M3-auto.md, section 41). Opt-in with ARGENT_MEASURE=1; FRAME_VIEW_SIZES, comma-separated,
/// replaces the sizes:
///
///     ARGENT_MEASURE=1 swift test -c release -Xswiftc -enable-testing --filter FrameViewRegistrationMeasureTests
@Suite(.serialized) struct FrameViewRegistrationMeasureTests {
    static let sizes = ProcessInfo.processInfo.environment["FRAME_VIEW_SIZES"]?.split(separator: ",").compactMap { Int($0) }
        ?? [900, 1200, 1690, 2190, 2600, 3000, 3400, 3700]

    @Test(.enabled(if: FrameViewMeasureTests.enabled && FrameViewRegistrationSampleTests.hasSamples))
    func appleDecodedModes() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let decoder = AppleRawDecoder(gpu: gpu)
        let resize = try AreaResize(gpu: gpu)
        let uncompressed = FrameViewRegistrationSampleTests.small.deletingLastPathComponent()
            .appendingPathComponent("ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW")
        for (name, url) in [("lossless S", FrameViewRegistrationSampleTests.small), ("lossless M", FrameViewRegistrationSampleTests.medium),
                            ("uncompressed", uncompressed)] {
            let full = try decoder.decode(url, options: DecodeOptions())
            for longSide in Self.sizes {
                let (preview, file, result) = try PatchRegistration.frameView(url, longSide: longSide, against: full,
                                                                              decoder: decoder, resize: resize)
                let pins = try #require(preview.pins)
                print(String(format: "MEASURE %@ at %d: picture %dx%d, file resized %dx%d, scale %.6f, cut %d columns and %d rows; %@",
                             name, longSide, preview.width, preview.height, file.width, file.height, pins.scale,
                             pins.trimColumns, pins.trimRows, result.text))
            }
        }
    }
}
