@testable import ArgentCore
import CryptoKit
import Foundation
import Metal
import Testing
@testable import ArgentRoll

/// "Grain tolerance, 2026-10-16" (docs/manual-development-validation.md), declared before measuring.
/// C1 to C3 find where the frame view's excess grain comes from, on flat frames through Portra 400, so
/// that neither a decoder nor a scene enters; V1 is C1 and C2 again with the change. Runs only with
/// ARGENT_MEASURE=1 where scripts/build-app.sh has baked the stocks:
///
///     ARGENT_MEASURE=1 swift test -c release -Xswiftc -enable-testing --filter GrainToleranceMeasureTests
///
/// The expectations are V1's declared rule, the frame view's grain within one just-noticeable difference
/// of the develop's (Kodak's four Print Grain Index units, a ratio of 10^(4/100.8) in RMS), on the grain's
/// standard deviation about its mean as amended before V1 ran; and K1 and K2, the cost of a smaller
/// picture's tiles. Before the change the grain rule fails, as the recorded pictures did.
@Suite(.serialized) struct GrainToleranceMeasureTests {
    typealias M = FrameViewMeasureTests
    typealias P = PreviewOutputMeasureTests
    typealias A = AutoMeasureTests

    static let stockURL = M.root.appendingPathComponent("build/stocks/kodak-portra-400")
    static var enabled: Bool { M.enabled && FileManager.default.fileExists(atPath: stockURL.appendingPathComponent("stock.json").path) }

    /// The develop sizes measured on 2026-10-16: the CC0 scene at 7008, the a7C, lossless M and lossless S.
    static let develops = [(width: 7008, height: 4672), (width: 6000, height: 4000), (width: 4608, height: 3072),
                           (width: 3480, height: 2320)]
    /// The frame view's pictures on 2026-10-16: 893 and 800 points wide.
    static let windows = [1690, 1504]
    static let seed: UInt32 = 0x6a1d_2016
    /// One just-noticeable difference in graininess as an RMS ratio.
    static let jnd = pow(10, 4.0 / 100.8)

    /// The model's frame view over develop, computed before measuring: RMS, then the three grain bands.
    static let model: [Int: [Int: (rms: Double, bands: [Double])]] = [
        1690: [7008: (1.164, [1.178, 1.000, 0.945]), 6000: (1.230, [1.246, 1.051, 0.992]),
               4608: (1.297, [1.316, 1.095, 1.028]), 3480: (1.311, [1.334, 1.091, 1.018])],
        1504: [7008: (1.152, [1.163, 1.008, 0.959]), 6000: (1.217, [1.229, 1.060, 1.006]),
               4608: (1.280, [1.295, 1.103, 1.043]), 3480: (1.291, [1.308, 1.098, 1.033])],
    ]
    /// The ratios recorded on the app's pictures: (b) at 1690 pixels, (b′) at 1504.
    static let recorded: [Int: [Int: ClosedRange<Double>]] = [
        1690: [7008: 1.160...1.174, 6000: 1.228...1.250, 4608: 1.309...1.309, 3480: 1.333...1.333],
        1504: [7008: 1.146...1.161, 6000: 1.212...1.238, 4608: 1.292...1.292, 3480: 1.313...1.313],
    ]
    /// The model's develop tile and its own field integrated over pixels, at unit variance: neighbour
    /// correlation, and the RMS of 32-pixel block means times 32.
    static let tileModel: [Int: (tile: (lag1: Double, block: Double), field: (lag1: Double, block: Double))] = [
        7008: ((0.341, 1.946), (0.458, 2.194)), 6000: ((0.259, 1.709), (0.397, 1.986)),
        4608: ((0.160, 1.435), (0.311, 1.715)), 3480: ((0.099, 1.250), (0.237, 1.509)),
    ]
    /// White noise area-resized, its RMS times the ratio, by window and develop size.
    static let whiteModel: [Int: [Int: Double]] = [
        1690: [7008: 0.920, 6000: 0.906, 4608: 0.878, 3480: 0.838],
        1504: [7008: 0.929, 6000: 0.917, 4608: 0.891, 3480: 0.856],
    ]

    /// A flat frame of `value` in every channel, scene-linear, standing for a decode at `scale`.
    static func flat(_ gpu: GPU, width: Int, height: Int, value: Float, scale: Float) throws -> LinearFrame {
        let texture = try gpu.texturePool.acquire(width: width, height: height)
        let v = Float16(value)
        var row = [Float16](repeating: 1, count: width * 4)
        for x in 0..<width { row[4 * x] = v; row[4 * x + 1] = v; row[4 * x + 2] = v }
        row.withUnsafeBytes { bytes in
            for y in 0..<height {
                texture.texture.replace(region: MTLRegionMake2D(0, y, width, 1), mipmapLevel: 0, withBytes: bytes.baseAddress!,
                                        bytesPerRow: width * 8)
            }
        }
        return LinearFrame(image: texture, decoderVersion: "test", scale: scale)
    }

    /// L* of a texture's pixels, from Rec. 2020 luminance with white at 1, as `normalSize` reads them.
    static func lightness(_ texture: MTLTexture) -> [Float] {
        P.Picture(texture, width: texture.width, height: texture.height).lightness
    }

    struct Grain {
        var rms: Double
        var bands: [Double]
        /// Diagnostic, added after C1's first run: the mean of the grain picture and its standard deviation.
        var mean = 0.0, sd = 0.0
        func over(_ other: Grain) -> Grain {
            Grain(rms: rms / other.rms, bands: zip(bands, other.bands).map { $0 / $1 }, mean: mean - other.mean, sd: sd / other.sd)
        }
        var text: String { String(format: "RMS %.3f; bands ", rms) + bands.map { String(format: "%.3f", $0) }.joined(separator: ", ") }
    }

    /// The grain alone, L* with grain minus L* without, as `normalSize` takes it.
    static func grain(on: [Float], off: [Float], width: Int, height: Int) -> Grain {
        let rms = P.rms(on, off, width: width, height: height, border: 8)
        let bands = A.bands(zip(on, off).map(-), width: width).map(Double.init)
        var sum = 0.0, n = 0.0
        for y in 8..<(height - 8) { for x in 8..<(width - 8) { sum += Double(on[y * width + x] - off[y * width + x]); n += 1 } }
        let mean = sum / n
        return Grain(rms: rms, bands: bands, mean: mean, sd: max(rms * rms - mean * mean, 0).squareRoot())
    }

    /// The grain field a render `width` by `height` adds to its dye amounts, in units of the stock's σ48:
    /// the two tiles at the seed's offsets, as the print pass reads them, summed over the square root of
    /// two, times `scale`, in each layer.
    static func field(_ tiles: (MTLTexture, MTLTexture), scale: Float, width: Int, height: Int, gpu: GPU) throws -> PooledTexture {
        let a = ExposureAnalyzer.pixels(of: tiles.0), b = ExposureAnalyzer.pixels(of: tiles.1)
        let wa = tiles.0.width, wb = tiles.1.width
        let ax = Int(seed % UInt32(wa)), ay = Int((seed / 1024) % UInt32(wa))
        let bx = Int((seed / 7) % UInt32(wb)), by = Int((seed / 8191) % UInt32(wb))
        let texture = try gpu.texturePool.acquire(width: width, height: height)
        let k = 0.70710678 * scale
        var row = [Float16](repeating: 1, count: width * 4)
        for y in 0..<height {
            let ra = ((y + ay) % wa) * wa, rb = ((y + by) % wb) * wb
            for x in 0..<width {
                let ia = 4 * (ra + (x + ax) % wa), ib = 4 * (rb + (x + bx) % wb)
                row[4 * x] = Float16((Float(a[ia]) + Float(b[ib])) * k)
                row[4 * x + 1] = Float16((Float(a[ia + 1]) + Float(b[ib + 1])) * k)
                row[4 * x + 2] = Float16((Float(a[ia + 2]) + Float(b[ib + 2])) * k)
            }
            row.withUnsafeBytes { texture.texture.replace(region: MTLRegionMake2D(0, y, width, 1), mipmapLevel: 0,
                                                          withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        }
        return texture
    }

    /// A field's grain in each layer, RMS and bands pooled over the three as root mean squares.
    static func layers(_ texture: MTLTexture) -> Grain {
        let pixels = ExposureAnalyzer.pixels(of: texture), (w, h) = (texture.width, texture.height)
        var rms = 0.0, bands = [0.0, 0.0, 0.0]
        for c in 0..<3 {
            let v = (0..<(w * h)).map { Float(pixels[4 * $0 + c]) }
            let r = P.rms(v, [Float](repeating: 0, count: v.count), width: w, height: h, border: 8)
            rms += r * r / 3
            for (i, b) in A.bands(v, width: w).enumerated() { bands[i] += Double(b * b) / 3 }
        }
        return Grain(rms: rms.squareRoot(), bands: bands.map { $0.squareRoot() })
    }

    /// The frame view's grain for a picture `longSide` pixels long standing for a develop
    /// `developLongSide` long: its tiles and its scale on σ48. Before the change (C2) it was the develop's
    /// tiles at the picture's own pitch, `(tiles(longSide:), GrainModel.pixelRatio(longSide:))`.
    static func frameViewGrain(_ gpu: GPU, longSide: Int, developLongSide: Int) throws -> (tiles: (MTLTexture, MTLTexture), scale: Float) {
        let made = try gpu.grainField.tiles(longSide: longSide, developLongSide: developLongSide)
        return ((made.a, made.b), made.scale)
    }

    static func within(_ ratio: Double, _ band: ClosedRange<Double>, by margin: Double) -> Bool {
        ratio >= band.lowerBound - margin && ratio <= band.upperBound + margin
    }

    /// C1 (and V1): flat frames through Portra 400 with grain Natural and Off, at the develop's size
    /// area-resized to the window's, against the frame view's render at the window's size.
    @Test(.enabled(if: enabled))
    func grainPathEndToEnd() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let renderer = try FilmRenderer(gpu: gpu, stock: try Stock.load(from: Self.stockURL))
        let resize = try AreaResize(gpu: gpu)
        func settings(_ grain: Float) -> DevelopSettings {
            DevelopSettings(grain: grain, grainSeed: Self.seed, halation: true, sharpen: true)
        }
        for develop in Self.develops {
            for stops: Float in [-2, 0, 2] {
                let value = 0.18 * exp2(stops)
                // The develop's grain, resized to each window.
                var developGrain: [Int: Grain] = [:]
                var pictures: [Int: [Float]] = [:]
                for grain: Float in [1, 0] {
                    let frame = try Self.flat(gpu, width: develop.width, height: develop.height, value: value, scale: 1)
                    let rendered = try renderer.render(frame, settings: settings(grain))
                    for window in Self.windows {
                        let resized = try resize.resized(rendered.image.texture, scale: Double(window) / Double(develop.width))
                        let l = Self.lightness(resized.texture)
                        if grain == 1 { pictures[window] = l } else {
                            developGrain[window] = Self.grain(on: pictures[window]!, off: l, width: resized.width, height: resized.height)
                        }
                    }
                }
                for window in Self.windows {
                    let size = AreaResize.size(width: develop.width, height: develop.height, scale: Double(window) / Double(develop.width))
                    let scale = Float(window) / Float(develop.width)
                    let on = try renderer.render(try Self.flat(gpu, width: size.width, height: size.height, value: value, scale: scale),
                                                 settings: settings(1))
                    let off = try renderer.render(try Self.flat(gpu, width: size.width, height: size.height, value: value, scale: scale),
                                                  settings: settings(0))
                    let preview = Self.grain(on: Self.lightness(on.image.texture), off: Self.lightness(off.image.texture),
                                             width: size.width, height: size.height)
                    let develop0 = try #require(developGrain[window])
                    let ratio = preview.over(develop0)
                    let model = try #require(Self.model[window]?[develop.width])
                    let recorded = try #require(Self.recorded[window]?[develop.width])
                    print(String(format: "MEASURE C1 develop %d -> %d px, %+.0f stops: grain L* frame view %.3f develop %.3f; ratio %@",
                                 develop.width, window, stops, preview.rms, develop0.rms, ratio.text))
                    print(String(format: "MEASURE C1   model %.3f; %@ (largest band difference %.3f); recorded %.3f to %.3f",
                                 model.rms, model.bands.map { String(format: "%.3f", $0) }.joined(separator: ", "),
                                 zip(ratio.bands, model.bands).map { abs($0 - $1) }.max() ?? 0, recorded.lowerBound, recorded.upperBound))
                    print("MEASURE C1   within ±0.03: model RMS \(abs(ratio.rms - model.rms) <= 0.03), bands "
                          + "\(zip(ratio.bands, model.bands).allSatisfy { abs($0 - $1) <= 0.03 }), recorded \(Self.within(ratio.rms, recorded, by: 0.03))")
                    print(String(format: "MEASURE C1   diagnostic: mean L* frame view %+.3f develop %+.3f; SD frame view %.3f develop %.3f, ratio %.3f",
                                 preview.mean, develop0.mean, preview.sd, develop0.sd, ratio.sd))
                    // The amended statistic: on a flat frame, the standard deviation about the mean.
                    #expect(ratio.sd >= 1 / Self.jnd && ratio.sd <= Self.jnd, "V1: \(develop.width) -> \(window) px at \(stops) stops")
                }
            }
        }
    }

    /// C2 (and V1): the grain tiles alone, in dye amounts before the print.
    @Test(.enabled(if: enabled))
    func tilesAlone() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        try gpu.grainField.prepare(library: try gpu.shaderLibrary())
        let resize = try AreaResize(gpu: gpu)
        for develop in Self.develops {
            let tiles = try gpu.grainField.tiles(longSide: develop.width)
            let full = try Self.field(tiles, scale: GrainModel.pixelRatio(longSide: develop.width), width: develop.width,
                                      height: develop.height, gpu: gpu)
            for window in Self.windows {
                let resized = try resize.resized(full.texture, scale: Double(window) / Double(develop.width))
                let developGrain = Self.layers(resized.texture)
                let frameView = try Self.frameViewGrain(gpu, longSide: window, developLongSide: develop.width)
                let picture = try Self.field(frameView.tiles, scale: frameView.scale, width: resized.width, height: resized.height, gpu: gpu)
                let previewGrain = Self.layers(picture.texture)
                let ratio = previewGrain.over(developGrain)
                print(String(format: "MEASURE C2 develop %d -> %d px: σ48 units frame view %.4f develop %.4f; ratio %@",
                             develop.width, window, previewGrain.rms, developGrain.rms, ratio.text))
                #expect(ratio.rms >= 1 / Self.jnd && ratio.rms <= Self.jnd, "V1: tiles \(develop.width) -> \(window) px")
            }
        }
    }

    /// Neighbour correlation, across and down, and the RMS of 32-pixel block means times 32, of a
    /// unit-variance tile, pooled over its three layers.
    static func tileStatistics(_ texture: MTLTexture) -> (lag1: Double, block: Double, sd: Double) {
        let v = ExposureAnalyzer.pixels(of: texture), side = texture.width, blocks = side / 32
        var lag = 0.0, block = 0.0, sd = 0.0
        for c in 0..<3 {
            var sum = 0.0, squares = 0.0, across = 0.0, down = 0.0
            for y in 0..<side {
                for x in 0..<side {
                    let p = Double(v[4 * (y * side + x) + c])
                    sum += p; squares += p * p
                    across += p * Double(v[4 * (y * side + (x + 1) % side) + c])
                    down += p * Double(v[4 * (((y + 1) % side) * side + x) + c])
                }
            }
            let n = Double(side * side), mean = sum / n, variance = squares / n - mean * mean
            lag += ((across / n - mean * mean) + (down / n - mean * mean)) / (2 * variance) / 3
            sd += variance.squareRoot() / 3
            var means: [Double] = []
            for by in 0..<blocks {
                for bx in 0..<blocks {
                    var s = 0.0
                    for y in (by * 32)..<(by * 32 + 32) { for x in (bx * 32)..<(bx * 32 + 32) { s += Double(v[4 * (y * side + x) + c]) } }
                    means.append(s / 1024 - mean)
                }
            }
            block += (means.reduce(0) { $0 + $1 * $1 } / Double(means.count)).squareRoot() * 32 / 3
        }
        return (lag, block, sd)
    }

    /// C3: the develop's tile against the model's field integrated over pixels, and white noise through
    /// the area resize. Also prints a digest of each develop size's tiles, so the change can be held to them.
    @Test(.enabled(if: enabled))
    func theTwoParts() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        try gpu.grainField.prepare(library: try gpu.shaderLibrary())
        let resize = try AreaResize(gpu: gpu)
        func digest(_ texture: MTLTexture) -> String {
            let pixels = ExposureAnalyzer.pixels(of: texture)
            return pixels.withUnsafeBytes { SHA256.hash(data: Data($0)) }.prefix(8).map { String(format: "%02x", $0) }.joined()
        }
        for longSide in [7008, 6000, 4608, 3480, 960] {
            let (a, b) = try gpu.grainField.tiles(longSide: longSide)
            print("MEASURE C3 digest of the tiles at \(longSide) px: \(digest(a)) \(digest(b))")
        }
        for develop in Self.develops {
            let (a, b) = try gpu.grainField.tiles(longSide: develop.width)
            let sa = Self.tileStatistics(a), sb = Self.tileStatistics(b)
            let lag = (sa.lag1 + sb.lag1) / 2, block = (sa.block + sb.block) / 2
            let model = try #require(Self.tileModel[develop.width])
            print(String(format: "MEASURE C3 tile at %d px: sd %.3f %.3f; neighbour correlation %.3f (tile computed %.3f, model's field %.3f); "
                         + "32-px block means x32 %.3f (tile computed %.3f, model's field %.3f; measured over the field's %.3f)",
                         develop.width, sa.sd, sb.sd, lag, model.tile.lag1, model.field.lag1, block, model.tile.block,
                         model.field.block, block / model.field.block))
        }
        let white = try gpu.grainField.tiles(longSide: 960)
        for develop in Self.develops {
            let full = try Self.field(white, scale: 1, width: develop.width, height: develop.height, gpu: gpu)
            for window in Self.windows {
                let resized = try resize.resized(full.texture, scale: Double(window) / Double(develop.width))
                let k = Double(develop.width) / Double(window)
                let expected = try #require(Self.whiteModel[window]?[develop.width])
                print(String(format: "MEASURE C3 white noise %d -> %d px: RMS x k %.4f (computed %.3f); unresized RMS %.4f",
                             develop.width, window, Self.layers(resized.texture).rms * k, expected, Self.layers(full.texture).rms))
            }
        }
    }

    /// K1: the time to work out a smaller picture's grain and make its two tiles, for the four develop
    /// sizes at both window sizes in turn, ten rounds. Eight pairs come round and four are kept, so every
    /// request makes its tiles. Declared pass: p95 at most 20 ms. K2: at most four pairs kept.
    @Test(.enabled(if: enabled))
    func makingTiles() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        try gpu.grainField.prepare(library: try gpu.shaderLibrary())
        let clock = ContinuousClock()
        var times: [Double] = []
        for _ in 0..<10 {
            for develop in Self.develops {
                for window in Self.windows {
                    let start = clock.now
                    _ = try gpu.grainField.tiles(longSide: window, developLongSide: develop.width)
                    let elapsed = clock.now - start
                    times.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
                    #expect(gpu.grainField.keptCount <= 4, "K2")
                }
            }
        }
        let sorted = times.sorted()
        let p95 = sorted[Int((0.95 * Double(sorted.count - 1)).rounded(.up))]
        print(String(format: "MEASURE K1 making a picture's tiles, %d makes: median %.2f ms, p95 %.2f ms, max %.2f ms; first round %@",
                     sorted.count, sorted[sorted.count / 2], p95, sorted.last ?? 0,
                     times.prefix(8).map { String(format: "%.1f", $0) }.joined(separator: ", ")))
        print("MEASURE K2 tile pairs kept: \(gpu.grainField.keptCount)")
        #expect(p95 <= 20, "K1")
    }
}
