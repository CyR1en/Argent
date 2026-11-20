import Foundation
import Metal
import Testing
@testable import ArgentCore

@Suite struct GrainModelTests {
    @Test func looksASigmaUpByTheLayersOwnAmount() {
        let table = GrainTable(amounts: [[0.1, 0.2, 0.3], [0.5, 0.6, 0.7]], sigma48: [[0.002, 0.004, 0.006], [0.004, 0.008, 0.010]])
        #expect(abs(table.sigma(layer: 0, amount: 0.3) - 0.003) < 1e-6)
        #expect(table.sigma(layer: 1, amount: 0) == 0.004)      // held flat below
        #expect(table.sigma(layer: 2, amount: 1) == 0.010)      // and above
        let sampled = table.sampled(count: 11)
        #expect(sampled.count == 11 && abs(sampled[5].x - 0.004) < 1e-6)
    }

    @Test func thePixelRatioFollowsTheResearchTable() {
        for (pitch, ratio) in GrainModel.pitchRatios {
            let longSide = Int((GrainModel.filmLongEdgeMicrometres / pitch).rounded())
            #expect(abs(GrainModel.pixelRatio(longSide: longSide) - ratio) < 0.01, "\(pitch)")
        }
        // Coarser pixels average more grain away.
        #expect(GrainModel.pixelRatio(longSide: 960) < GrainModel.pixelRatio(longSide: 2048))
        #expect(GrainModel.pixelRatio(longSide: 9504) > GrainModel.pixelRatio(longSide: 7008))
    }

    @Test func aPictureStandsForTheDevelopItsScaleSays() {
        #expect(GrainModel.developLongSide(longSide: 7008, scale: 1) == 7008)
        #expect(GrainModel.developLongSide(longSide: 1504, scale: 1504.0 / 7008) == 7008)
        #expect(GrainModel.developLongSide(longSide: 960, scale: 2) == 960)
        #expect(GrainModel.developLongSide(longSide: 960, scale: 0) == 960)
    }

    /// White noise area-resized by a whole ratio is an exact box: a quarter of the variance each way at 4 to
    /// 1, neighbours apart. At 7008 to 1504 the pixels the footprints cut are taken whole, so each way it
    /// keeps 0.9285 of the box's variance, and both ways together 0.9285 of its RMS (computed; C3 measured
    /// 0.9277 on the white tile).
    @Test func theResizesAutocorrelationOfWhiteNoise() {
        let whole = GrainModel.resizedAutocorrelation([1], from: 6016, to: 1504)
        #expect(abs(whole[0] - 0.25) < 1e-12 && whole.dropFirst().allSatisfy { abs($0) < 1e-12 })
        let cut = GrainModel.resizedAutocorrelation([1], from: 7008, to: 1504)
        #expect(abs(cut[0] * 7008 / 1504 - 0.9285) < 0.0005)
        #expect(cut[1] > 0 && cut.dropFirst(2).allSatisfy { abs($0) < 1e-12 })
    }

    /// The kernel a smaller picture's noise is blurred by has the develop's resized autocorrelation.
    @Test(arguments: [(7008, 1504), (3480, 1690), (6000, 1504), (6016, 1504), (4608, 960)])
    func aResizedKernelHasTheResizedAutocorrelation(from: Int, to: Int) {
        let develop = GrainField.developKernels(bucket: GrainField.bucket(longSide: from))
        let resized = GrainModel.resized(kernels: develop, from: from, to: to)
        for (kernel, root) in zip(develop, resized.kernels) {
            let target = GrainModel.resizedAutocorrelation(kernel, from: from, to: to)
            for lag in 0..<root.count {
                let own = (0..<(root.count - lag)).reduce(0.0) { $0 + Double(root[$1]) * Double(root[$1 + lag]) }
                #expect(abs(own - (lag < target.count ? target[lag] : 0)) < 1e-4 * target[0], "\(from) -> \(to), lag \(lag)")
            }
        }
        // The resized grain is weaker than the develop tile's, by more than the box's area alone.
        #expect(resized.sigma > 0.2 && resized.sigma < 0.6)
    }

    @Test func eachFrameHasItsOwnGrainAndKeepsIt() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.25)
        #expect(GrainModel.seed(name: "DSC00601.ARW", captureDate: date) == GrainModel.seed(name: "DSC00601.ARW", captureDate: date))
        #expect(GrainModel.seed(name: "DSC00601.ARW", captureDate: date) != GrainModel.seed(name: "DSC00602.ARW", captureDate: date))
    }
}

@Suite struct GrainFieldTests {
    private func statistics(_ texture: MTLTexture) -> (mean: Float, sd: Float, lag1: Float) {
        let values = ExposureAnalyzer.pixels(of: texture)
        let side = texture.width
        var sum: Float = 0, squares: Float = 0, products: Float = 0
        for y in 0..<side {
            for x in 0..<side {
                let v = Float(values[(y * side + x) * 4 + 1]), right = Float(values[(y * side + (x + 1) % side) * 4 + 1])
                sum += v; squares += v * v; products += v * right
            }
        }
        let n = Float(side * side), mean = sum / n, variance = squares / n - mean * mean
        return (mean, variance.squareRoot(), (products / n - mean * mean) / variance)
    }

    /// Unit-variance noise in every layer; at full-size pitch the dye clouds span neighbouring
    /// pixels, at the contact sheet's pitch they do not.
    @Test func makesUnitNoiseShapedByThePitch() throws {
        let gpu = try GPU()
        try gpu.grainField.prepare(library: try gpu.shaderLibrary())
        let (fine, other) = try gpu.grainField.tiles(longSide: 7008)
        let (coarse, _) = try gpu.grainField.tiles(longSide: 960)
        #expect(fine.width == GrainField.sides.0 && other.width == GrainField.sides.1)
        let f = statistics(fine), c = statistics(coarse)
        print(String(format: "MEASURE grain tile: neighbour correlation %.2f at 7008 px, %.2f at 960 px", f.lag1, c.lag1))
        #expect(abs(f.mean) < 0.01 && abs(f.sd - 1) < 0.01)
        #expect(f.lag1 > 0.3 && abs(c.lag1) < 0.02)
        // The same pitch is the same tile, made once.
        #expect(try gpu.grainField.tiles(longSide: 7008).0 === fine)
    }
}

@Suite struct ResizedGrainTests {
    /// The field a picture `width` by `height` adds to its dye amounts in units of σ48, as the print pass
    /// reads the tiles: both at the seed's offsets, summed over the square root of two, times `scale`.
    private func field(_ a: MTLTexture, _ b: MTLTexture, scale: Float, width: Int, height: Int, gpu: GPU) throws -> PooledTexture {
        let pa = ExposureAnalyzer.pixels(of: a), pb = ExposureAnalyzer.pixels(of: b)
        let (wa, wb, seed) = (a.width, b.width, 5)
        let texture = try gpu.texturePool.acquire(width: width, height: height)
        var row = [Float16](repeating: 1, count: width * 4)
        for y in 0..<height {
            for x in 0..<width {
                let ia = 4 * (((y + seed / 1024) % wa) * wa + (x + seed) % wa), ib = 4 * (((y + seed / 8191) % wb) * wb + (x + seed / 7) % wb)
                for c in 0..<3 { row[4 * x + c] = Float16((Float(pa[ia + c]) + Float(pb[ib + c])) * 0.70710678 * scale) }
            }
            row.withUnsafeBytes { texture.texture.replace(region: MTLRegionMake2D(0, y, width, 1), mipmapLevel: 0,
                                                          withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        }
        return texture
    }

    private func rms(_ texture: MTLTexture) -> [Double] {
        let pixels = ExposureAnalyzer.pixels(of: texture), n = texture.width * texture.height
        return (0..<3).map { c in ((0..<n).reduce(0.0) { $0 + Double(pixels[4 * $1 + c]) * Double(pixels[4 * $1 + c]) } / Double(n)).squareRoot() }
    }

    /// A develop's own tiles are what they were. A smaller picture gets tiles of its own carrying the
    /// develop's grain area-resized to it: in each layer the same RMS within 1.5 percent, where the
    /// develop's own tiles at the picture's pitch would carry about a fifth more (C2).
    @Test func aSmallerPictureCarriesItsDevelopsResizedGrain() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        try gpu.grainField.prepare(library: try gpu.shaderLibrary())
        let (width, height, longSide) = (3480, 2320, 1504)
        let develop = try gpu.grainField.tiles(longSide: width)
        let own = try gpu.grainField.tiles(longSide: width, developLongSide: width)
        #expect(own.a === develop.0 && own.b === develop.1 && own.scale == GrainModel.pixelRatio(longSide: width))
        let full = try field(develop.0, develop.1, scale: GrainModel.pixelRatio(longSide: width), width: width, height: height, gpu: gpu)
        let resized = try AreaResize(gpu: gpu).resized(full.texture, scale: Double(longSide) / Double(width))
        let picture = try gpu.grainField.tiles(longSide: longSide, developLongSide: width)
        #expect(picture.a !== develop.0)
        let drawn = try field(picture.a, picture.b, scale: picture.scale, width: resized.width, height: resized.height, gpu: gpu)
        let ratios = zip(rms(drawn.texture), rms(resized.texture)).map { $0 / $1 }
        print("MEASURE a 1504-pixel picture's grain over its 3480-pixel develop's resized, by layer:", ratios.map { String(format: "%.4f", $0) })
        #expect(ratios.allSatisfy { abs($0 - 1) < 0.015 })
    }

    @Test func atMostFourTilePairsAreKept() throws {
        let gpu = try GPU()
        let field = GrainField(device: gpu.device, queue: gpu.queue)
        try field.prepare(library: gpu.shaderLibrary())
        for (from, to) in [(7008, 1504), (6000, 1504), (4608, 1504), (3480, 1504), (7008, 960), (7008, 7008)] {
            _ = try field.tiles(longSide: to, developLongSide: from)
            #expect(field.keptCount <= 4)
        }
    }
}

/// Runs where scripts/build-app.sh has baked the stocks.
@Suite struct GrainRenderTests {
    static let baked = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("build/stocks/kodak-portra-400")
    static var hasStock: Bool { FileManager.default.fileExists(atPath: baked.appendingPathComponent("stock.json").path) }

    /// A frame of flat bands at the given stops from mid-gray, rendered through Portra 400 at
    /// 4096 px; each band's relative luminance noise.
    private func bandNoise(_ stops: [Float], grain: Float, seed: UInt32 = 7) throws -> (noise: [Float], pixels: [Float16]) {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: try Stock.load(from: Self.baked))
        let width = 4096, band = 128, height = band * stops.count
        let texture = try gpu.texturePool.acquire(width: width, height: height)
        var pixels = [Float16](repeating: 1, count: width * height * 4)
        for (index, stop) in stops.enumerated() {
            let value = Float16(0.18 * exp2(stop))
            for i in (index * band * width)..<((index + 1) * band * width) {
                pixels[i * 4] = value; pixels[i * 4 + 1] = value; pixels[i * 4 + 2] = value
            }
        }
        pixels.withUnsafeBytes { texture.texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                                         withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        let out = try renderer.render(LinearFrame(image: texture, decoderVersion: "test", scale: 1),
                                      settings: DevelopSettings(grain: grain, grainSeed: seed))
        let values = ExposureAnalyzer.pixels(of: out.image.texture)
        var noise: [Float] = []
        for index in stops.indices {
            var sum: Double = 0, squares: Double = 0, n: Double = 0
            for y in (index * band + 8)..<((index + 1) * band - 8) {
                for x in stride(from: 0, to: width, by: 2) {
                    let i = (y * width + x) * 4
                    let luminance = 0.2627 * Double(values[i]) + 0.6780 * Double(values[i + 1]) + 0.0593 * Double(values[i + 2])
                    sum += luminance; squares += luminance * luminance; n += 1
                }
            }
            let mean = sum / n
            noise.append(Float((max(squares / n - mean * mean, 0)).squareRoot() / mean))
        }
        return (noise, values)
    }

    /// Grain through the paper: a band from about two stops under mid-gray to one over, peaking
    /// at -2 to 0, and gone in a clipped white. The M1 follow-ups measured the peak at -1 to 0 through
    /// the optical Endura model; through the Portras' tone stage since 2026-10-08 (print.md) -2 and -1 are
    /// level (14.2 and 13.9 percent, measured).
    @Test(.enabled(if: GrainRenderTests.hasStock))
    func printsInABandAroundGrayAndNotInAClippedWhite() throws {
        let stops: [Float] = [-2, -1, 0, 2, 5]
        let (noise, _) = try bandNoise(stops, grain: 1)
        print("MEASURE Portra 400 grain at 4096 px, relative luminance noise at", zip(stops, noise).map { String(format: "%+.0f: %.2f%%", $0, $1 * 100) })
        let peak = stops[noise.firstIndex(of: noise.max()!)!]
        #expect(peak >= -2 && peak <= 0)
        #expect(noise[0] > 3 * noise[3] && noise[2] > 3 * noise[3])
        #expect(noise[4] < noise[2] / 20)
        #expect(noise[2] > 0.01 && noise[2] < 0.15)
        let off = try bandNoise(stops, grain: 0).noise
        #expect(off.allSatisfy { $0 < 1e-3 })
    }

    @Test(.enabled(if: GrainRenderTests.hasStock))
    func theSameSeedIsTheSameGrain() throws {
        let a = try bandNoise([0], grain: 1, seed: 11).pixels
        let b = try bandNoise([0], grain: 1, seed: 11).pixels
        let c = try bandNoise([0], grain: 1, seed: 12).pixels
        #expect(a == b && a != c)
    }
}
