import CoreGraphics
import Foundation
import Metal
import simd
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// Whether a mask's balance can read a baked slice (tier 1), or needs the pixel's own coverage (tier 2) as Exposure does, on real frames and real
/// sky seeds through the film. Colour on the wrong side of an edge is what it measures: the band is the tier 2 coverage's edge, dilated 6 px; the
/// number is ΔE*ab between the tier 1 and the tier 2 print there, against the size of the change itself inside the sky. Grain is off, the harder case
/// for a rim. It runs only when asked:
///
///     ARGENT_MEASURE=1 ARGENT_BALANCE_OUT=<folder> swift test -c release -Xswiftc -enable-testing --filter MaskBalanceEdgeTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] != nil))
struct MaskBalanceEdgeTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let probe = root.appendingPathComponent("references/lightroom-probe/inputs/auto-a7iv")
    static let corpus = root.appendingPathComponent("references/corpus/imaging-resource-a7iv-gallery")
    static let seeds = root.appendingPathComponent("references/masks/water-veto-golden")
    static let frames: [(stem: String, raw: URL)] = ["DSC04064", "DSC04073", "DSC04074", "DSC04091", "DSC04100"].map { ($0, probe.appendingPathComponent($0 + ".ARW")) }
        + [("Y-JG-A7-IV-FE-24-105-4908", corpus.appendingPathComponent("Y-JG-A7-IV-FE-24-105-4908.ARW"))]
    static var out: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARGENT_BALANCE_OUT"] ?? NSTemporaryDirectory() + "argent-balance") }

    static func halves(_ texture: MTLTexture) -> [Float16] {
        var values = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        values.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return values
    }

    /// CIELAB of display-linear Rec. 2020 at D65.
    static func lab(_ values: [Float16], _ i: Int) -> SIMD3<Float> {
        let r = max(Float(values[i * 4]), 0), g = max(Float(values[i * 4 + 1]), 0), b = max(Float(values[i * 4 + 2]), 0)
        let x = (0.636958 * r + 0.144617 * g + 0.168881 * b) / 0.95047
        let y = 0.262700 * r + 0.677998 * g + 0.059302 * b
        let z = (0.028073 * g + 1.060985 * b) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856 ? pow(t, 1 / 3) : 7.787 * t + 16 / 116 }
        return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    static func percentile(_ sorted: [Float], _ p: Int) -> Float { sorted.isEmpty ? 0 : sorted[min(sorted.count * p / 100, sorted.count - 1)] }

    static func masked(_ base: DevelopSettings, _ component: MaskComponent, balance: MaskBalance?, exposure: Float = 0, tierOne: Bool) throws -> DevelopSettings {
        var s = base
        let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let nothing = MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: MaskRefinerSurfaceTests.emptySeed.ref, frame: frame)))
        let mask = Mask(components: tierOne ? [component, nothing] : [component], adjustments: try ManualAdjustments(exposureEV: exposure), balance: balance ?? .neutral)
        s.manual = try ManualRenderSettings(adjustments: ManualAdjustments.identity.settingMasks(try MaskSet(masks: [mask])), referenceStops: base.manual.referenceStops)
        return s
    }

    @Test func theBaseAndThePixelsCoverageAgainstEachOther() throws {
        let c = try MaskRefinerSurfaceTests.context()
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var report = "frame, slider, sky change median ΔE*ab, band pixels, tier 1 against tier 2 band p95 ΔE*ab, p99, coverage p99\n"
        var worst: Float = 0
        for entry in Self.frames {
            var options = DecodeOptions()
            options.tileSize = RollDeveloper.decodeTile
            options.learnedTileSize = RollDeveloper.learnedDecodeTile
            let frame = try c.decoder.decode(entry.raw, options: options)
            let (w, h) = (frame.width, frame.height)
            let seed = MaskRefinerSurfaceTests.Entry(stem: entry.stem, raw: entry.raw.path, kind: "sky",
                                                     seed: Self.seeds.appendingPathComponent(entry.stem + ".out.f32").path, format: "f32", seedWidth: nil, seedHeight: nil, surfaces: nil, proof: nil)
            let raster = try MaskRefinerSurfaceTests.seed(seed, frameWidth: w, frameHeight: h)
            c.seeds.add(raster)
            let base = try MaskRefinerSurfaceTests.settings(c, entry.raw, grain: false)
            let selection = try MaskRefinerSurfaceTests.component("sky", raster, background: false, width: w, height: h)

            let plainImage = try c.renderer.render(frame, settings: base).image
            let plain = Self.halves(plainImage.texture)
            for (name, balance) in [("Warmth -100", MaskBalance(warmth: -100)), ("Warmth +100", MaskBalance(warmth: 100)), ("Magenta +100", MaskBalance(magenta: 100))] {
                let two = try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, frame, try Self.masked(base, selection, balance: balance, tierOne: false), coverage: true)
                let coverage2 = try #require(two.coverage)
                let values2 = Self.halves(two.image.texture)
                let one = try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, frame, try Self.masked(base, selection, balance: balance, tierOne: true), coverage: true)
                let coverage1 = try #require(one.coverage)
                let values1 = Self.halves(one.image.texture)
                let band = MaskRefinerSurfaceTests.band(coverage2, width: w, height: h)
                var apart: [Float] = [], cover: [Float] = [], change: [Float] = []
                for y in stride(from: 0, to: h, by: 1) {
                    for x in stride(from: 0, to: w, by: 1) {
                        let i = y * w + x
                        if band[i] {
                            let a = Self.lab(values1, i), b = Self.lab(values2, i)
                            apart.append(simd_length(SIMD2(a.y - b.y, a.z - b.z)))
                            cover.append(abs(coverage1[i] - coverage2[i]))
                        } else if coverage2[i] > 0.98, (x % 16 == 0) && (y % 16 == 0) {
                            let a = Self.lab(plain, i), b = Self.lab(values2, i)
                            change.append(simd_length(SIMD2(a.y - b.y, a.z - b.z)))
                        }
                    }
                }
                apart.sort(); cover.sort(); change.sort()
                let p99 = Self.percentile(apart, 99)
                worst = max(worst, p99)
                report += "\(entry.stem), \(name), \(Self.percentile(change, 50)), \(apart.count), \(Self.percentile(apart, 95)), \(p99), \(Self.percentile(cover, 99))\n"

                // The window with the most edge, at 100 %, for the eye.
                if name == "Warmth -100", let (x, y) = MaskRefinerSurfaceTests.windows(coverage2, width: w, height: h, count: 1).first {
                    for (suffix, texture) in [("0-none", plainImage.texture), ("1-tier1", one.image.texture), ("2-tier2", two.image.texture)] {
                        try MaskRefinerSurfaceTests.crop(c.gpu, texture, x: x, y: y, width: 640, height: 480, to: Self.out.appendingPathComponent("\(entry.stem)-\(suffix).png"))
                    }
                }
            }
            try Data(report.utf8).write(to: Self.out.appendingPathComponent("rim.csv"))
        }
        Swift.print(report)
        Swift.print("worst band p99 ΔE*ab: \(worst)")
    }
}
