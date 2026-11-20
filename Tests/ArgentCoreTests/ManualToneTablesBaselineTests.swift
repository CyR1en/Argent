import CryptoKit
import Foundation
import Testing
@testable import ArgentCore

/// The panel's tables are what every recorded edit on Light compiler 2026-10-29-1 renders through.
/// `ManualToneTables` was split so `LocalScene` could reuse its transfer and its gain construction;
/// the digests here were taken on main at 3f67969, before that split.
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

    static let recorded: [String: String] = [
        "c57831f42cf2fff7": "d642e2514e54f24fc14ddafaa7083ee56cfbde83bb9a482b6afadfc3247c1c3f", // light-toy
        "283c7d2116353dcc": "e712b9c7e8171a1bf5233fb3e8e72b2f5b54f4242c08fc34d6b7e5a5878b9e75", // kodak-ektar-100
        "97b86033aaefe487": "804a0dc1d0b5e8ba64f3fe64b5b1bb9fabc17e4f16a44daa0284d9b094414da0", // kodak-gold-200
        "04984bdf6c444942": "30ad5e1ca72566ab6d6af1f8f1b461d9d8c3b8eb96f736d310dc7d76f34681da", // kodak-portra-160
        "d32896bc5189e32c": "340e706140e2d8ed78c7d3c819f885a0f2835771378343b9bb276c129cf78dbe", // kodak-portra-400
        "af8472bc46ac6b41": "ed188069b878bb0f1ac4c2a5b2c9b29fd7076087707e3496a76268b0a228f477", // kodak-portra-800
        "11ba69882c255851": "1c583a3130841880dc8e2259f1a859fbff9e91c3e678629e1524a4f92156d60f", // kodak-ultramax-400
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
