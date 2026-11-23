import CryptoKit
import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Recorded compilers stay as they rendered before a later one joined them: the GPU's bytes for a
/// fixed frame and fixed edits, through the toy stock and each baked stock, against digests taken
/// from main before any change for the later compiler. Originally taken at 81e029d (2026-10-09-1)
/// and 3f67969 (2026-10-29-1 and no edit); re-recorded for the toy stock and the 14 baked stocks
/// on `main` at `e5bca7c7` on 2026-11-23 (macOS 27.2 build 26B123), after scene gamut compression,
/// `RenderGraph.version` 2026-11-19-1. The toy stock is built in code and always checked; when
/// `build/stocks` is present, every baked stock must have a recorded digest so a bake change cannot
/// silently drop stock coverage.
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

    /// The tone step the digests with one use: Auto's burn and dodge at a reference of its own, on the version they were
    /// recorded on, which a frame saved before 2026-11-23 holds and must go on rendering.
    static let toneStep = PrintTone(burn: 0.6, dodge: 0.4, referenceStops: -0.3, version: "2026-11-05-2")

    /// The same tone step on 2026-11-23-1, whose table differs only where the print is at the paper's white
    /// (`PrintTone.WhiteHold`).
    static let correctedToneStep = PrintTone(burn: 0.6, dodge: 0.4, referenceStops: -0.3, version: "2026-11-23-1")

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
    static func digest(stock: Stock, gpu: GPU, edits: [ManualRenderSettings]? = nil, tone: PrintTone = .identity,
                       renderer: FilmRenderer? = nil) throws -> String {
        let renderer = try renderer ?? FilmRenderer(gpu: gpu, stock: stock)
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

    /// Output digests for `edits()` (compiler `2026-10-09-1`) by stock fingerprint, recorded on `main`
    /// at `e5bca7c7` on 2026-11-23 (macOS 27.2 build 26B123), after scene gamut compression,
    /// `RenderGraph.version` 2026-11-19-1.
    static let recorded: [String: String] = [
        "c57831f42cf2fff7": "9d5bc606d360bcc3a1c61216d705edc2f85d96bb5566513fedd02d0a66c8cf2e", // light-toy
        "949d6164d3351a62": "6fb78014f9135c562cf2a4a83015df270c2f38b6380bc5cd6b0cbf0eb3b6db3b", // cinestill-800t
        "a6da1896b2b4f9b5": "60f8157ffbe5d729f86ab12f037a99fc46016a54249dcae6d1a04dfddbbb36ff", // fujifilm-c200
        "ab3fc45ad153d406": "edbc4e0ba18af384c84c4cb8fe4eabbb109655f2e478e0f7f1d3ce9c95ab1797", // fujifilm-pro-400h
        "034d966e7021564d": "60bf1d9765215192d448aaa00e8e6f5940d55d0c487563d3723854b5760f43a5", // fujifilm-superia-400
        "99e292f723e67e6c": "11515b04e1ef0288495d167b3b74babe9a1bbe3a9be812b92a1011d5941cd321", // kodak-colorplus-200
        "41dd35cf8baec974": "bed448318b5dba374cfa445ba335b83147f2f8b7b653a4a0593101e1ec14ae9c", // kodak-ektar-100
        "b4fa9fe6f7e0e06f": "406d2cc4a8b1cbf8465d0c2b35f80ab96298bc438e6393cdbf47d72adada87d0", // kodak-gold-200
        "ef2f5ccafa11838d": "d20a6f852ba68af5a74005940925fa3c50c05c419f97b1ccd2ad7b2b0e5c0fd2", // kodak-portra-160
        "e92abdcb666a21d9": "150d39cfc0e60b219d3f9141ef1cc63df69886b4a9cd29d765d40d5987bb8f31", // kodak-portra-160-natural
        "fc81ea0b270e96f3": "4e04d30a88c1ac7bc7b03527734112956806afa1cfbb8655d0d216b2bd3db9b4", // kodak-portra-400
        "fdfd3cce8c35fb37": "ca36a70cefc4b683ac54852ba73a2f6cd9e3aea220493c07d1a1864257551dac", // kodak-portra-800
        "46b68f5377170d20": "800baad5d2e070117b9bcbf5b971ff425edf1ae6fa764085f88369acb567dbc5", // kodak-ultramax-400
        "d0334068916dcff7": "8df9faad3e573389f05597436b945bb68bef2d1f3f664f15b383b438fcd62901", // kodak-vision3-500t
        "712fa666980b0174": "30b44bd864823ca29a344e76521f5d365361594222768c3cbcbe28c3cd3e4601", // kodak-vision3-500t-cinema
    ]

    /// Output digests for `exposedBaseEdits()` (compiler `2026-10-29-1`) without the tone step by stock
    /// fingerprint, recorded on `main` at `e5bca7c7` on 2026-11-23 (macOS 27.2 build 26B123), after
    /// scene gamut compression, `RenderGraph.version` 2026-11-19-1.
    static let recordedExposedBase: [String: String] = [
        "c57831f42cf2fff7": "d945764d7355cc3147352f73e2c508085c63d855eaaf7bf8bce2cc9b8df80e0d", // light-toy
        "949d6164d3351a62": "d0e3c5ed89c38e92cde87b58e702b5abe8b00f4d950a941b3febf5f0e0c972a5", // cinestill-800t
        "a6da1896b2b4f9b5": "16c0d1174b7a91ba8a7e66189b9b323a041fdefe475b5916f709d6688032cc6a", // fujifilm-c200
        "ab3fc45ad153d406": "43bdf542815fe527ddcc80d772073f9e99b0243ed662baf85ccea2c6061e68c8", // fujifilm-pro-400h
        "034d966e7021564d": "f49a217f0a4019f1df34c1c9d28ca7da6855bfb2426cd97b3bbf60fae755c23a", // fujifilm-superia-400
        "99e292f723e67e6c": "2d64b577e163f7580157dccdebe40b4740eae7bc878059117e2cb480e9d281d6", // kodak-colorplus-200
        "41dd35cf8baec974": "8c887f1ed64fdd8198811dcf5316304a929b4c8c424ae447ab15d507cd5223ff", // kodak-ektar-100
        "b4fa9fe6f7e0e06f": "175ed62e8979cd3d71488ff73b7176b6fa80f163e39b0916065ba48af83fc918", // kodak-gold-200
        "ef2f5ccafa11838d": "e4d949d651c26203c86a104c993017e003a3dfee9b5e21994ca743b588811bde", // kodak-portra-160
        "e92abdcb666a21d9": "4955248a1317aa3dd1056ee4cd0be512f7a1aab633071a74b12a97e8cdb8c340", // kodak-portra-160-natural
        "fc81ea0b270e96f3": "b09151c2fa70c30f9d5a699c6a49bb62ccd507b4bd511d02618765b8c2e2ef51", // kodak-portra-400
        "fdfd3cce8c35fb37": "30242e5357455631168b0f9d11f929ecb020b7bcd93951c388eb656f4285d898", // kodak-portra-800
        "46b68f5377170d20": "cd6857b4e78c59bb38f238983c6ae82919163e3e445b50e593352366c07665e7", // kodak-ultramax-400
        "d0334068916dcff7": "51f5b7689349bf19a1d8ec34369ae2f00b9a7f88d1792c3d85bfac16d94fad31", // kodak-vision3-500t
        "712fa666980b0174": "9a297c57770a7f83deb50ab892f0f754c7dda5e516cd9d94dcfac73ed68bf52b", // kodak-vision3-500t-cinema
    ]

    /// Output digests for `exposedBaseEdits()` (compiler `2026-10-29-1`) with `toneStep` by stock
    /// fingerprint, recorded on `main` at `e5bca7c7` on 2026-11-23 (macOS 27.2 build 26B123), after
    /// scene gamut compression, `RenderGraph.version` 2026-11-19-1.
    static let recordedExposedBaseWithToneStep: [String: String] = [
        "c57831f42cf2fff7": "0ac03155db114803c3f52b3562b4faa488e919a4f87e29ca1d28cfa87697ec4e", // light-toy
        "949d6164d3351a62": "540e4da31f3152efd47057258a68a9feaa825219f4bd80cb915c6e56344e5e28", // cinestill-800t
        "a6da1896b2b4f9b5": "83bacf4936f98c0b7a6f94e14f5172deeddce0f194547f98b32801faa52ed97a", // fujifilm-c200
        "ab3fc45ad153d406": "6f5a97be8a19d44ec54abade2236b7723eb6797160998828c9ae3b36b879194c", // fujifilm-pro-400h
        "034d966e7021564d": "f96341df8f84bab8749cd7b7c6085e9e8cbae63d5b3ac6dc37e376096b05a62a", // fujifilm-superia-400
        "99e292f723e67e6c": "b6034edb16fb994d5abae4f3c1da41dc79973bba37d6cccfa6bc4b1c0e8912d3", // kodak-colorplus-200
        "41dd35cf8baec974": "2f77d916e74b9e67d955b496884b0f13f9485f0c49af724353bde64ef8fd5fbd", // kodak-ektar-100
        "b4fa9fe6f7e0e06f": "07091907ed5203277b6eec13bf8c645753a3ddffa4ff601be5ad2c642180ddea", // kodak-gold-200
        "ef2f5ccafa11838d": "dfb0188330b33d1f942dc7c7d58719293a63391b9c7838776199793202e21f5a", // kodak-portra-160
        "e92abdcb666a21d9": "592edb79e0e1ae90756fd32d0ed1bf670c97b080f44d9cb431f8b93b5eba0d4c", // kodak-portra-160-natural
        "fc81ea0b270e96f3": "6fda60b93b8a0e9bf4adcd1d9b1d60a9fd90c6a4f8c367fdd755b369766cec79", // kodak-portra-400
        "fdfd3cce8c35fb37": "4c53490b2b47b868de30734b9e9995a04bf124052459252540071a51b0557d8a", // kodak-portra-800
        "46b68f5377170d20": "ecd55518e40be7929ecad3491845b481c3ba8df0bdf08e772dadd6a569871ff7", // kodak-ultramax-400
        "d0334068916dcff7": "3fa634f8fba2fbe99a1b534397df804fc4f997c8a597a7de8f23bba7a1ce2649", // kodak-vision3-500t
        "712fa666980b0174": "1c2189af5dbdf4bb632b8a594af5ee4664912a275c588de6289aea87e57f8a91", // kodak-vision3-500t-cinema
    ]

    /// Output digests for `exposedBaseEdits()` with `correctedToneStep`, only where they differ from
    /// `recordedExposedBaseWithToneStep`: every other stock renders its bytes under either version. Recorded on
    /// `fix/print-tone-at-print-white` on 2026-11-23 (macOS 27.2 build 26B123), `RenderGraph.version` 2026-11-19-1.
    static let recordedExposedBaseWithCorrectedToneStep: [String: String] = [
        "949d6164d3351a62": "e9c26d53c9057813fd35d4d031313cee4ab0eb87629acaea923e128542db509c", // cinestill-800t
        "a6da1896b2b4f9b5": "18ddc4e7a553c552a5c0a9c259d5636bacfbcf10fa357d49016fa3f2618e0c72", // fujifilm-c200
        "ab3fc45ad153d406": "fb8ce045f5c2cd65153666a19f4342fde6d6b9845817a0f0389fa6976fe532f3", // fujifilm-pro-400h
        "034d966e7021564d": "3c4ef1bae138a3b32da7d36f39912c2431a6d6ef2a2af83132b6dcedbef73f21", // fujifilm-superia-400
        "99e292f723e67e6c": "0da6f7e3f51b918e84daac7be518aec8e3faabbbcf9e861f52618f0f6be70a68", // kodak-colorplus-200
        "41dd35cf8baec974": "ed6f526c77b7d0d1507f31bb22c4469407c7133ade3e7fba0107c5c02f021d39", // kodak-ektar-100
        "b4fa9fe6f7e0e06f": "ae1c7a8652fb689a65acf6dbd8cc90f37eeee35948a1a0772b8e4ce90415f51e", // kodak-gold-200
        "46b68f5377170d20": "8ed5dc7456afc70f4fefb31262f40a888f0268965399c8630331009385492455", // kodak-ultramax-400
        "712fa666980b0174": "425199bd3504a684831056a39c7f63e2cadddc84600e5a94fc4c52edadebc482", // kodak-vision3-500t-cinema
    ]

    /// Output digests for a frame with no edit (`.identity`) without the tone step by stock fingerprint,
    /// recorded on `main` at `e5bca7c7` on 2026-11-23 (macOS 27.2 build 26B123), after scene gamut
    /// compression, `RenderGraph.version` 2026-11-19-1.
    static let recordedNoEdit: [String: String] = [
        "c57831f42cf2fff7": "4aef9fea6862a349d52a527d8d077a07a4a40480abed138caf0ee26da79a23e1", // light-toy
        "949d6164d3351a62": "c35913735486376cbcb3eb6eaa7b4a01d8b77a6b236338b59c26c40fd1228657", // cinestill-800t
        "a6da1896b2b4f9b5": "da45f8ea218c25c64626140a05d1105338de8097231be0b389fb4495687a6c21", // fujifilm-c200
        "ab3fc45ad153d406": "4da2182c999dd79a3b44a60cc8801fbb81efe613bdbc618089349c7ea411100e", // fujifilm-pro-400h
        "034d966e7021564d": "050bafc243036da4d166b73e3a5e1322f4c7012095d3254f5602418ffc795a38", // fujifilm-superia-400
        "99e292f723e67e6c": "2521467049de0d6b899fe54cd4db01aea8f20b72eaee4e1a5f402c27c23fcf6c", // kodak-colorplus-200
        "41dd35cf8baec974": "899b9f92f129322b6d878471c5fd6538d60a8d84a049fdea495e389850c83f00", // kodak-ektar-100
        "b4fa9fe6f7e0e06f": "2fe4f97813aecb56ecbc30e12ace0971f8889cbbea854ed654e4d65f45551df9", // kodak-gold-200
        "ef2f5ccafa11838d": "94b0474eac86aba1e71dc1cafabe36125ff4b4f451ac1e91d135e085f084802c", // kodak-portra-160
        "e92abdcb666a21d9": "955fc9d406a2537683e6cf64ca410fe16cb100ba3149b54c948ebda4ed99d80d", // kodak-portra-160-natural
        "fc81ea0b270e96f3": "5bfeb591425eee0fdbac0017f085716d4279f74fc393e0c030e6d5ad1cbaa58a", // kodak-portra-400
        "fdfd3cce8c35fb37": "0a2e11934b993ce3ba5cb91ed1c18774b320a2fb318171cdcddfbf826de408c1", // kodak-portra-800
        "46b68f5377170d20": "7df152bb56b537730a598505ab125a0e6b3aea17031742d73292f41fab741f6a", // kodak-ultramax-400
        "d0334068916dcff7": "78479d7ac8bacb64b27511e1d80b3285f495c31ad6932faf6a4f3e3c6b8bb15e", // kodak-vision3-500t
        "712fa666980b0174": "ace8b5354592f4ad179050cb7e688e5653daa5f39ca276f34e6dca3e85e48b85", // kodak-vision3-500t-cinema
    ]

    /// Output digests for a frame with no edit (`.identity`) with `toneStep` by stock fingerprint,
    /// recorded on `main` at `e5bca7c7` on 2026-11-23 (macOS 27.2 build 26B123), after scene gamut
    /// compression, `RenderGraph.version` 2026-11-19-1.
    static let recordedNoEditWithToneStep: [String: String] = [
        "c57831f42cf2fff7": "d43ee5ca8ce83830af7031cd165f787d7498bef52bbe9f05f0148cb84276cb56", // light-toy
        "949d6164d3351a62": "7c6d6b0d05544381722f2373f5c907791df40287c06e23fa090fc934961fac0e", // cinestill-800t
        "a6da1896b2b4f9b5": "3961080f41523f26ba6095b0fe879fb726c6e835721d03dd31a6243df9d13a65", // fujifilm-c200
        "ab3fc45ad153d406": "3fbabdf6d1623dbcb249778aa07b4ecd905f71ea27651e734e2d454b43b4319d", // fujifilm-pro-400h
        "034d966e7021564d": "d562a546f22e0f82af9214735ddd3ae018db8266d05e4ff2a85cd903fad460e1", // fujifilm-superia-400
        "99e292f723e67e6c": "21dc55e43eb816e718b507c95a733364def775a580cc80d68642a5a36257ffe9", // kodak-colorplus-200
        "41dd35cf8baec974": "cadca5aef04168745c44f93ab7d1f6412b4ebd6f5e4569b294fb026dbf2df2bb", // kodak-ektar-100
        "b4fa9fe6f7e0e06f": "8458a11f9f8eb44c6b5d95aac02cd313ae86f86fb4dc2dc209359e94dbf9d683", // kodak-gold-200
        "ef2f5ccafa11838d": "9ddc2abcc80b6dd19f257361139ee88bd076a9fd9f776c908b3cfe5d7ff8e759", // kodak-portra-160
        "e92abdcb666a21d9": "ceebffc2f5bd25a582241ab546fe87efb86404677cc2199e4d8bacdd8400e106", // kodak-portra-160-natural
        "fc81ea0b270e96f3": "06abd911df41c053108bd54a167f2033b80f19b87e95f43535dd6235874d04a8", // kodak-portra-400
        "fdfd3cce8c35fb37": "6422ee47cabc4ea41912183dd14a67c606b269dc68260777e96ee730803ac6a3", // kodak-portra-800
        "46b68f5377170d20": "d8b12655e10ef9456ca8c74291682861bd528bb9e1e652ae262583f50c0a52da", // kodak-ultramax-400
        "d0334068916dcff7": "8e1c838b45780c68b4ec156e57456603f0d8732c1a7e3ea41f3766b1b47eb740", // kodak-vision3-500t
        "712fa666980b0174": "6659018f6a2b5f62df04d136a980ee8170ad20ef5d3c6c7c66d232b8a31de767", // kodak-vision3-500t-cinema
    ]

    /// Output digests for a frame with no edit with `correctedToneStep`, only where they differ from
    /// `recordedNoEditWithToneStep`. Recorded as `recordedExposedBaseWithCorrectedToneStep` was.
    static let recordedNoEditWithCorrectedToneStep: [String: String] = [
        "949d6164d3351a62": "a2a8c63623ff03c319625e8b9730cbdef0469731bdf41ebde604c5966dda49bd", // cinestill-800t
        "a6da1896b2b4f9b5": "39d23c5aaa370506e8763b13047c1087031046c95eb90f03fa84677866330177", // fujifilm-c200
        "ab3fc45ad153d406": "f05ff8039fcbaaf4d003ba4970b87d49a1203bb0cd4905a0e5e975a014604351", // fujifilm-pro-400h
        "034d966e7021564d": "082185cf82bad3d5dee2dc20eeb88953ca553f94b29be4cd728ff8850a5e3808", // fujifilm-superia-400
    ]

    @Test func recordedCompilerRendersTheBytesItRenderedBefore() throws {
        try check(Self.recorded, edits: Self.edits)
    }

    /// The toy stock and every baked stock in `build/stocks` render their recorded digests. A fresh
    /// checkout with no `build/stocks` checks the toy stock alone; when baked stocks are present, any
    /// whose fingerprint is missing from `recorded` fails rather than silently skipping coverage.
    private func check(_ recorded: [String: String], edits: () throws -> [ManualRenderSettings], tone: PrintTone = .identity) throws {
        let gpu = try GPU()
        let resolvedEdits = try edits()
        let toy = Self.toyStock()
        let toyExpected = try #require(recorded[Self.fingerprint(toy)], "missing recorded digest for \(toy.id) (\(Self.fingerprint(toy)))")
        #expect(try Self.digest(stock: toy, gpu: gpu, edits: resolvedEdits, tone: tone) == toyExpected, "\(toy.id)")

        var unrecorded: [String] = []
        for url in Self.bakedStocks {
            let stock = try Stock.load(from: url)
            let fingerprint = Self.fingerprint(stock)
            guard let expected = recorded[fingerprint] else {
                unrecorded.append("\(stock.id) (\(fingerprint))")
                continue
            }
            #expect(try Self.digest(stock: stock, gpu: gpu, edits: resolvedEdits, tone: tone) == expected, "\(stock.id)")
        }
        #expect(unrecorded.isEmpty, """
                Baked stocks have no recorded baseline digest: \(unrecorded.joined(separator: ", ")). \
                Re-record the digests in LightCompilerBaselineTests after an intended change of the bake, \
                or re-bake build/stocks if this checkout's bake is out of date.
                """)
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

    /// The tone step's second version renders the first's bytes on every stock but those recorded apart.
    @Test func theCorrectedToneStepRendersTheFirstsBytesButWhereItsTableDiffers() throws {
        try check(Self.recordedExposedBaseWithToneStep.merging(Self.recordedExposedBaseWithCorrectedToneStep) { $1 },
                  edits: Self.exposedBaseEdits, tone: Self.correctedToneStep)
        try check(Self.recordedNoEditWithToneStep.merging(Self.recordedNoEditWithCorrectedToneStep) { $1 },
                  edits: { [.identity] }, tone: Self.correctedToneStep)
    }

    /// A renderer keeps one tone table at a time, so a frame on either version after the other renders that version's bytes.
    @Test func oneRendererRendersEachToneVersionsOwnBytes() throws {
        let gpu = try GPU()
        let edits = try Self.exposedBaseEdits()
        for url in Self.bakedStocks {
            let stock = try Stock.load(from: url)
            let fingerprint = Self.fingerprint(stock)
            guard let corrected = Self.recordedExposedBaseWithCorrectedToneStep[fingerprint],
                  let first = Self.recordedExposedBaseWithToneStep[fingerprint] else { continue }
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            for (tone, expected) in [(Self.toneStep, first), (Self.correctedToneStep, corrected), (Self.toneStep, first)] {
                #expect(try Self.digest(stock: stock, gpu: gpu, edits: edits, tone: tone, renderer: renderer) == expected, "\(stock.id) \(tone.version)")
            }
        }
    }
}
