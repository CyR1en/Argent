import CryptoKit
import Foundation
import Testing
@testable import ArgentCore

/// The panel's tables are what every recorded edit on Light compiler 2026-10-29-1 renders through.
/// `ManualToneTables` was split so `LocalScene` could reuse its transfer and its gain construction;
/// the toy stock's digest was taken on main at 3f67969, before that split, and still holds. The
/// baked stocks' were taken again after the bake changed every stock (see `recorded`).
@Suite struct ManualToneTablesBaselineTests {
    static func edits() throws -> [(ManualAdjustments, Float)] {
        [
            (try ManualAdjustments(contrast: 100), 0),
            (try ManualAdjustments(contrast: -100), 0.4),
            (try ManualAdjustments(highlights: 100), -2),
            (try ManualAdjustments(highlights: -100), 1.25),
            (try ManualAdjustments(shadows: 100), 0),
            (try ManualAdjustments(shadows: -37), 0.8),
            (try ManualAdjustments(whites: 100), 0),
            (try ManualAdjustments(whites: -62.5), 2.5),
            (try ManualAdjustments(blacks: 100), 0),
            (try ManualAdjustments(blacks: -12.5), -0.7),
            (try ManualAdjustments(exposureEV: 0.65, contrast: 40, highlights: -70, shadows: 55, whites: -30, blacks: 20), 1.25),
            (try ManualAdjustments(exposureEV: -1.5, contrast: -100, highlights: 100, shadows: -100, whites: 100, blacks: -100), -2),
        ]
    }

    static let settings = [
        DevelopSettings(),
        DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, -0.05, 0.03), printExposure: 0.3),
        DevelopSettings(ratedAt: 1600, printExposure: -0.6),
    ]

    /// Every float the tables hold, for every edit under every setting, in order.
    static func digest(_ stock: Stock) throws -> String {
        var hash = SHA256()
        func add(_ values: [Float]) {
            values.withUnsafeBufferPointer { hash.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        }
        for settings in Self.settings {
            for (adjustments, reference) in try edits() {
                let tables = ManualToneTables(adjustments: adjustments, referenceStops: reference, stock: stock, settings: settings)
                add([tables.start, tables.step, tables.globalActive ? 1 : 0, tables.localActive ? 1 : 0])
                add(tables.global); add(tables.local); add(tables.transfer); add(tables.regularized)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Digests by stock fingerprint (`LightCompilerBaselineTests.fingerprint`). The toy stock's is from main at 3f67969 and
    /// is unchanged. The 14 baked stocks' were recorded on `main` at `e5bca7c7` on 2026-11-23 (macOS 27.2 build 26B123),
    /// with `build/stocks` as baked then. The bake had changed every stock: no fingerprint of the six stocks recorded at
    /// 3f67969 is among today's 14, so those entries were dropped. Scene gamut compression (2026-11-19) acts in the shader
    /// and leaves these tables alone, which the toy stock's unchanged digest shows. Two pairs of stocks, told apart by other
    /// numbers, make the same tables and so the same digest: kodak-colorplus-200 and kodak-gold-200, and kodak-portra-160
    /// and kodak-portra-160-natural.
    static let recorded: [String: String] = [
        "c57831f42cf2fff7": "d642e2514e54f24fc14ddafaa7083ee56cfbde83bb9a482b6afadfc3247c1c3f", // light-toy
        "949d6164d3351a62": "7140cd3b597a8315df722f3f50f35c0a3e4d4b96ccd3809be8d027673bbf9535", // cinestill-800t
        "a6da1896b2b4f9b5": "e4229da01bf19067e5f78c740d4c379947d3003945fd4320388271ad685958de", // fujifilm-c200
        "ab3fc45ad153d406": "cb845170bba8755f8c3b33cc5248e2c5cc66e53f6deb1ae1336c30453022a62f", // fujifilm-pro-400h
        "034d966e7021564d": "a6ca77545632788f6d31413ff02c67e554e08a7f82b653c8036c69d3e143292d", // fujifilm-superia-400
        "99e292f723e67e6c": "51de96c086c83c085580241dd038adc54e30f780582587c86706965da6ba3224", // kodak-colorplus-200
        "41dd35cf8baec974": "dc9534e4b049cd704d1a51ddd1e2f070c8f8aa19d0f96dd16f8f4ff099205c15", // kodak-ektar-100
        "b4fa9fe6f7e0e06f": "51de96c086c83c085580241dd038adc54e30f780582587c86706965da6ba3224", // kodak-gold-200
        "ef2f5ccafa11838d": "4fe54d13d868c525e2f6e6ef6681ca3d0a571f9e445498f4ea99d942701d5978", // kodak-portra-160
        "e92abdcb666a21d9": "4fe54d13d868c525e2f6e6ef6681ca3d0a571f9e445498f4ea99d942701d5978", // kodak-portra-160-natural
        "fc81ea0b270e96f3": "ad5e8428ec088e5715009c4569125c58811de1e4e654d1dad4377ac024ffee39", // kodak-portra-400
        "fdfd3cce8c35fb37": "030dd592cd0caab10ee7492cdb5126e3c64a42790740370e5a17d8b51183919f", // kodak-portra-800
        "46b68f5377170d20": "560b39ae15b342990e5cbcd80b54ed106111358c4b4446a36b0b1fe79299c047", // kodak-ultramax-400
        "d0334068916dcff7": "98ad2732ce6f49f4a5c874a0a413a64b9a67ab2df005d5ffbf38b11686e32a0a", // kodak-vision3-500t
        "712fa666980b0174": "1e250e6d55bb53e201de3e30968738fdb645558928984285184a5e117b05bc5c", // kodak-vision3-500t-cinema
    ]

    @Test func thePanelsTablesStayBitIdentical() throws {
        var stocks = [LightCompilerBaselineTests.toyStock()]
        for url in LightCompilerBaselineTests.bakedStocks { stocks.append(try Stock.load(from: url)) }
        var checked = 0
        for stock in stocks {
            guard let expected = Self.recorded[LightCompilerBaselineTests.fingerprint(stock)] else { continue }
            #expect(try Self.digest(stock) == expected, "\(stock.id)")
            checked += 1
        }
        #expect(checked >= 1)
    }
}
