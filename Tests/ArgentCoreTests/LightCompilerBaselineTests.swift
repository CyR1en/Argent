import CryptoKit
import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Recorded compilers stay as they rendered before a later one joined them: the GPU's bytes for a
/// fixed frame and fixed edits, through the toy stock and each baked stock, against digests taken
/// from main before any change for the later compiler. 2026-10-09-1's are from 81e029d, before
/// 2026-10-29-1. 2026-10-29-1's, and a frame's with no edit, are from 3f67969, before 2026-11-06-1. A
/// re-baked stock has another digest and is skipped; the toy stock is built in code and always checked.
@Suite struct LightCompilerBaselineTests {
    static let width = 64, height = 48

    /// A spread of light from 12 stops under to 6 over 0.18, coloured, with zero, signed and
    /// near-zero pixels and a few bright enough for halation.
    static func pixels() -> [SIMD3<Float>] {
        (0..<(width * height)).map { i -> SIMD3<Float> in
            switch i % 97 {
            case 0: return .zero
            case 1: return SIMD3(-0.05, 0.02, 0.4)
            case 2: return SIMD3(1e-7, 2e-7, -1e-7)
            case 3: return SIMD3(repeating: 40)
            default:
                let stops = -12 + 18 * Float((i * 37) % 1009) / 1008
                let v = 0.18 * exp2(stops)
                return SIMD3(v * (0.8 + 0.4 * Float(i % 5) / 4), v, v * (1.2 - 0.4 * Float(i % 7) / 6))
            }
        }
    }

    static func edits() throws -> [ManualRenderSettings] {
        let old = "2026-10-09-1"
        let curves = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve)
        return [
            try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 0.65, contrast: 40, highlights: -70,
                shadows: 55, whites: -30, blacks: 20), referenceStops: 1.25, version: old),
            try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: -1.5, contrast: -100, highlights: 100,
                shadows: -100, whites: 100, blacks: -100), referenceStops: -2, version: old),
            try ManualRenderSettings(adjustments: ManualAdjustments(highlights: -35, curves: curves), referenceStops: 0.4, version: old),
            try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 2), referenceStops: 0, version: old),
            try ManualRenderSettings(adjustments: ManualAdjustments(contrast: 65), referenceStops: 0, version: old),
        ]
    }

    /// Compiler 2026-10-29-1's edits: every control, Exposure with Highlights or Shadows, which is
    /// what 2026-11-06-1 reads differently, and the edits it should read the same.
    static func exposedBaseEdits() throws -> [ManualRenderSettings] {
        func edit(_ values: ManualAdjustments, reference: Float) throws -> ManualRenderSettings {
            try ManualRenderSettings(adjustments: values, referenceStops: reference, version: "2026-10-29-1")
        }
        let curves = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve)
        return [
            try edit(ManualAdjustments(exposureEV: 0.65, contrast: 40, highlights: -70, shadows: 55, whites: -30, blacks: 20), reference: 1.25),
            try edit(ManualAdjustments(exposureEV: -1.5, contrast: -100, highlights: 100, shadows: -100, whites: 100, blacks: -100), reference: -2),
            try edit(ManualAdjustments(exposureEV: 0.5, highlights: -50), reference: 0.4),
            try edit(ManualAdjustments(exposureEV: -0.5, highlights: -50), reference: 0.4),
            try edit(ManualAdjustments(exposureEV: 1, highlights: -100), reference: -0.3),
            try edit(ManualAdjustments(exposureEV: -1, highlights: -100), reference: -0.3),
            try edit(ManualAdjustments(exposureEV: 1.5, shadows: 100), reference: 0),
            try edit(ManualAdjustments(exposureEV: -1.5, shadows: 50), reference: 0),
            try edit(ManualAdjustments(highlights: -65, shadows: 35), reference: 0.6),
            try edit(ManualAdjustments(contrast: 65, whites: 45, blacks: -20), reference: 0),
            try edit(ManualAdjustments(exposureEV: 2), reference: 0),
            try edit(ManualAdjustments(exposureEV: -0.4, highlights: -35, curves: curves), reference: 0.4),
        ]
    }

    /// The tone step the digests with one use: Auto's burn and dodge at a reference of its own.
    static let toneStep = PrintTone(burn: 0.6, dodge: 0.4, referenceStops: -0.3)

    /// Each stock the checkout has baked. `build/stocks` is resolved first, since listing a symbolic
    /// link to a folder fails (ENOTDIR) and a worktree's is one: without that, this is silently empty.
    static var bakedStocks: [URL] {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/stocks").resolvingSymlinksInPath()
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(Stock.manifestName).path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func toyStock() -> Stock {
        let toy = ToyStock.make()
        return Stock(id: "light-toy", displayName: "Light", status: "synthetic", boxSpeed: toy.boxSpeed,
            densityRange: toy.densityRange, exposurePerUnit: toy.exposurePerUnit, negative: toy.negative,
            print: toy.print, grain: GrainTable(amounts: [[0, 0, 0], [1, 1, 1]],
                sigma48: [[0.01, 0.02, 0.015], [0.005, 0.01, 0.02]]),
            halation: Stock.Halation(strength: 0.02, greenShare: 0.3, radiusMicrometres: 180))
    }

    static func frame(_ gpu: GPU) throws -> LinearFrame {
        let texture = try gpu.makeTexture(width: width, height: height)
        var values = [Float16](repeating: 1, count: width * height * 4)
        for (i, rgb) in pixels().enumerated() {
            values[i * 4] = Float16(rgb.x); values[i * 4 + 1] = Float16(rgb.y); values[i * 4 + 2] = Float16(rgb.z)
        }
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        return LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "light-baseline", scale: 1)
    }

    /// One digest of every edit's output bytes, in order: `edits`, by default 2026-10-09-1's.
    static func digest(stock: Stock, gpu: GPU, edits: [ManualRenderSettings]? = nil, tone: PrintTone = .identity) throws -> String {
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        var hash = SHA256()
        for manual in try edits ?? Self.edits() {
            let settings = DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, -0.05, 0.03), printExposure: 0.3,
                                           grain: 1, grainSeed: 37, halation: stock.halation != nil, sharpen: true,
                                           manual: manual, tone: tone)
            let output = try renderer.render(try frame(gpu), settings: settings).image.texture
            var bytes = [UInt8](repeating: 0, count: width * height * 8)
            bytes.withUnsafeMutableBytes {
                output.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The stock's tables and the numbers the render reads from it, so a re-baked stock is told apart.
    static func fingerprint(_ stock: Stock) -> String {
        var hash = SHA256()
        hash.update(data: stock.negative.binaryData())
        hash.update(data: stock.print.binaryData())
        let numbers = [stock.boxSpeed, stock.densityRange, stock.exposurePerUnit.x, stock.exposurePerUnit.y,
                       stock.exposurePerUnit.z, stock.halation?.strength ?? 0, stock.halation?.greenShare ?? 0,
                       stock.halation?.radiusMicrometres ?? 0]
        numbers.withUnsafeBufferPointer { hash.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        if let grain = stock.grain {
            let sampled = grain.sampled(count: 256).flatMap { [$0.x, $0.y, $0.z] }
            sampled.withUnsafeBufferPointer { hash.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        }
        return hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Output digests by stock fingerprint, recorded on main at 81e029d.
    static let recorded: [String: String] = [
        "c57831f42cf2fff7": "62d6ef1d8e4cf711040c7b331d9adc32a0ca395872897311a3b81f1f57ddcad8", // light-toy
        "283c7d2116353dcc": "0873e7df5e9b63208fadea5e48a81a2afa47fdfede8e93dd4de49414879d0a0a", // kodak-ektar-100
        "97b86033aaefe487": "f450a25e619d1e6d2d11171cac4b4bd509c4540f80156fd65824c6cf7ff61ff4", // kodak-gold-200
        "04984bdf6c444942": "1d2df9594cca77ea5c8aecef776c4bad43d1cc6444199d7b8c05097681b7d0de", // kodak-portra-160
        "d32896bc5189e32c": "2ebc8e2d1d6a4f3e4098bed7b9f832b6c70e13b6615da21cba7b32a6ceef52a9", // kodak-portra-400
        "af8472bc46ac6b41": "74046211e5515dfa402ad82947ed6969280dc5a9ae26c67fbc91d2f43000f4d2", // kodak-portra-800
        "11ba69882c255851": "a2fddc350eee989164488ccd6d8fb533ee1c8ecdcfd0b3b6b40bc847c6ee38bf", // kodak-ultramax-400
    ]

    /// `exposedBaseEdits()`'s digests by stock fingerprint, without the tone step and with `toneStep`, and
    /// the digests of a frame with no edit, recorded on main at 3f67969.
    static let recordedExposedBase: [String: String] = [
        "c57831f42cf2fff7": "183100f05f928c2d40179aae7988bf87a98718e519beb4368d4688aefcab1c39", // light-toy
        "283c7d2116353dcc": "90a1b177b57c37d462ee49fc29ebf42df568d47ada6a7461f79bd3b11f3fdc9c", // kodak-ektar-100
        "97b86033aaefe487": "fad1b80353133c0c999b380c3075febe8f9e9c62d9ad5605448ced33a6aadf28", // kodak-gold-200
        "04984bdf6c444942": "a356f3d7ea9fb02deb73169e2cdbe285ca614b6828079a5374f9f31221732f7e", // kodak-portra-160
        "d32896bc5189e32c": "97245ad5b70329331c897148a9a0561bbc543aa5144299e90db819e3b8d9a200", // kodak-portra-400
        "af8472bc46ac6b41": "2a0793af02e042ee4264a429eec56fe72d619acb7f8b6ffa61d092d95748ffda", // kodak-portra-800
        "11ba69882c255851": "3afbaa03340130d753a727ca813ea0a2923b04c23f12204ae94919cb20b5be13", // kodak-ultramax-400
    ]
    static let recordedExposedBaseWithToneStep: [String: String] = [
        "c57831f42cf2fff7": "d25d67c4321cd13d451f2b470d675dcb7c3316197e53803a142436fe4c0cb01d", // light-toy
        "283c7d2116353dcc": "603f2fd1422360f7edf1fe3498903f37eed8f55e0324a0a40416e7462504d65f", // kodak-ektar-100
        "97b86033aaefe487": "562a9d6e0d71663fcc9117ca5d5e97ef563c82abf3b5785a215b404b18d4fcba", // kodak-gold-200
        "04984bdf6c444942": "f87b7d31bfe73634b1fe7008708b755c52d100e3c7d4436499f513d4b6c38920", // kodak-portra-160
        "d32896bc5189e32c": "495e4e493481215d1492adfccc02c9ee45113bc96f2c5d5de8e6ded055011e51", // kodak-portra-400
        "af8472bc46ac6b41": "f2c497c7ace548c701379f4c7eda479eb5ebb5efcd6e4312b7d7c95f8bf6a780", // kodak-portra-800
        "11ba69882c255851": "5349e7e330004ad33f1cb33e2df39aadd3a11d247d39caa14df6f9654ddc2341", // kodak-ultramax-400
    ]
    static let recordedNoEdit: [String: String] = [
        "c57831f42cf2fff7": "c9073d9c35e1fa5dafe904633ca25c353b6bebec2d6660d3bdb3f4115a47e83d", // light-toy
        "283c7d2116353dcc": "8b1d520f855a69a0ccc4ee3d4816fbc7d21100c2204682b4ad5323645b399bd8", // kodak-ektar-100
        "97b86033aaefe487": "8911e951c4ae79ff8b1dc202800ddf37f37cb5ac904ac5a03b8738d7e5548d72", // kodak-gold-200
        "04984bdf6c444942": "00cf76b0b86c712711f656082e0c2f2cec85096946eb038911085e84b9b107bd", // kodak-portra-160
        "d32896bc5189e32c": "f06ae63f3313d39d8060cb835dd6979b5c3ef9525f21250f1f495ce4d86aae1b", // kodak-portra-400
        "af8472bc46ac6b41": "099d15b5881f24051f0c5c867ff31c5ee790526aeb1411e64b85960be1272f86", // kodak-portra-800
        "11ba69882c255851": "9203f8f4ba583c62b75a5a6693fe77b40483e4248cc2803e502a05c548e85876", // kodak-ultramax-400
    ]
    static let recordedNoEditWithToneStep: [String: String] = [
        "c57831f42cf2fff7": "a04058c8ae3592870b621141b97e8296626690bca8957d8817f4f7deca5d62fd", // light-toy
        "283c7d2116353dcc": "10d33e3f7c863c22fcd49cc16e38b3af7ea1443487003f75b964c3b675683927", // kodak-ektar-100
        "97b86033aaefe487": "e3ecc3ffbf16df952c4d882f9064201c2c340c881381c5cd9e6e001fdf5ae089", // kodak-gold-200
        "04984bdf6c444942": "7c52376f84e6d09cd8587116711c2667f957dca0504baa9ecd2da436ef403e37", // kodak-portra-160
        "d32896bc5189e32c": "66a1b6a207b90bb01e2773bdf0b99566d25ef769f09b1e1d3d7765fbf76dac51", // kodak-portra-400
        "af8472bc46ac6b41": "e9f627825775ba1b457b0ddd52af36a02b18412f710e75deba6a81fc49de4c78", // kodak-portra-800
        "11ba69882c255851": "04b8a2851ae0e272c25fd83128244c792b35542e0459789cb2ebee391e5404d3", // kodak-ultramax-400
    ]

    @Test func recordedCompilerRendersTheBytesItRenderedBefore() throws {
        let gpu = try GPU()
        var stocks = [Self.toyStock()]
        for url in Self.bakedStocks { stocks.append(try Stock.load(from: url)) }
        var checked = 0
        for stock in stocks {
            guard let expected = Self.recorded[Self.fingerprint(stock)] else { continue }
            #expect(try Self.digest(stock: stock, gpu: gpu) == expected, "\(stock.id)")
            checked += 1
        }
        #expect(checked >= 1)
    }

    /// Every stock with a recorded digest renders it. Which stocks those are depends on the checkout, so
    /// at least the toy's is required, and the baked stocks count toward it when they are the recorded bake.
    private func check(_ recorded: [String: String], edits: () throws -> [ManualRenderSettings], tone: PrintTone = .identity) throws {
        let gpu = try GPU()
        var stocks = [Self.toyStock()]
        for url in Self.bakedStocks { stocks.append(try Stock.load(from: url)) }
        var checked = 0
        for stock in stocks {
            guard let expected = recorded[Self.fingerprint(stock)] else { continue }
            #expect(try Self.digest(stock: stock, gpu: gpu, edits: edits(), tone: tone) == expected, "\(stock.id)")
            checked += 1
        }
        #expect(checked >= 1)
    }

    @Test func compilerReadingTheExposedBaseRendersTheBytesItRenderedBefore() throws {
        try check(Self.recordedExposedBase, edits: Self.exposedBaseEdits)
    }

    @Test func compilerReadingTheExposedBaseWithTheToneStepRendersTheBytesItRenderedBefore() throws {
        try check(Self.recordedExposedBaseWithToneStep, edits: Self.exposedBaseEdits, tone: Self.toneStep)
    }

    /// A frame with no edit goes down the automatic path whatever the current compiler is.
    @Test func aFrameWithNoEditRendersTheBytesItRenderedBefore() throws {
        try check(Self.recordedNoEdit, edits: { [.identity] })
        try check(Self.recordedNoEditWithToneStep, edits: { [.identity] }, tone: Self.toneStep)
    }
}
