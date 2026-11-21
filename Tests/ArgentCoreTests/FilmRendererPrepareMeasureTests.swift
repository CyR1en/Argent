import CryptoKit
import Foundation
import Metal
import QuartzCore
import Testing
@testable import ArgentCore

/// What preparing every stock's renderer costs, and the bytes each renders, for comparing builds. Runs only with ARGENT_MEASURE=1:
///
///     ARGENT_MEASURE=1 ARGENT_STOCKS=build/stocks swift test -c release --filter FilmRendererPrepareMeasureTests
///
/// `prepare` times making a `FilmRenderer` for every stock in ARGENT_STOCKS (cold, then the median of 20 more on the same GPU, as
/// after a develop). `digests` renders one synthetic frame with each stock under four settings and prints each result's SHA-256.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] == "1"))
struct FilmRendererPrepareMeasureTests {
    private static func stocks() throws -> [Stock] {
        guard let dir = ProcessInfo.processInfo.environment["ARGENT_STOCKS"] else { return (0..<6).map { _ in ToyStock.make(size: 33) } }
        return try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
            .filter(\.hasDirectoryPath).sorted { $0.path < $1.path }.map { try Stock.load(from: $0) }
    }

    private static func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        let start = CACurrentMediaTime()
        try body()
        return (CACurrentMediaTime() - start) * 1000
    }

    @Test func prepare() throws {
        let stocks = try Self.stocks()
        let gpu = try GPU()
        _ = try gpu.shaderLibrary()
        var renderers: [FilmRenderer] = []
        let cold = try Self.milliseconds { renderers = try stocks.map { try FilmRenderer(gpu: gpu, stock: $0) } }
        let warm = try (0..<20).map { _ in
            renderers.removeAll()
            return try Self.milliseconds { renderers = try stocks.map { try FilmRenderer(gpu: gpu, stock: $0) } }
        }.sorted()
        print(String(format: "PREPARE stocks=%d cold_ms=%.2f warm_median_ms=%.2f", stocks.count, cold, (warm[9] + warm[10]) / 2))
    }

    @Test func digests() throws {
        let gpu = try GPU()
        let (width, height) = (384, 256)
        func frame() throws -> LinearFrame {
            let texture = try gpu.makeTexture(width: width, height: height)
            var halves = [Float16](repeating: 1, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4, u = Float(x) / Float(width), v = Float(y) / Float(height)
                    halves[i] = Float16(exp2(u * 14 - 9))
                    halves[i + 1] = Float16(exp2(v * 12 - 8) * (0.5 + u))
                    halves[i + 2] = Float16(exp2((u + v) * 7 - 9))
                }
            }
            halves.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8)
            }
            return LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "measure", scale: 1)
        }
        var full = DevelopSettings(halation: true, sharpen: true)
        full.grain = 1
        full.grainSeed = 1234
        var manual = full
        manual.manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 0.4, highlights: -40, shadows: 30), referenceStops: 0)
        var toned = full
        toned.tone = PrintTone(burn: 0.8, dodge: 0.4)
        let variants = [("default", DevelopSettings()), ("halation+sharpen+grain", full), ("manual-tone-base", manual), ("print-tone", toned)]
        for stock in try Self.stocks() {
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            for (name, settings) in variants {
                let rendered = try renderer.render(try frame(), settings: settings)
                var bytes = [UInt8](repeating: 0, count: width * height * 8)
                bytes.withUnsafeMutableBytes {
                    rendered.image.texture.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                }
                print("DIGEST \(stock.id) \(name) \(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())")
            }
        }
    }
}
