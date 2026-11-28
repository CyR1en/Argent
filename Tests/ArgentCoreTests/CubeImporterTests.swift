import ArgentCore
import Foundation
import Testing

@Suite struct CubeImporterTests {
    private let identity = LUT3D.identity(size: 2)

    @Test func displayIdentityMatchesNeutralForInGamutColors() throws {
        let stock = try CubeImporter.bake(identity, id: "user-neutral-look", name: "Neutral Look")
        #expect(stock.print.size == 65)
        #expect(stock.negative.encoding == LogEncoding(stopsBelowMidGray: 8, stopsAboveMidGray: 5, midGray: 0.18))
        #expect(stock.negative.sample(encoded: SIMD3(0.25, 0.5, 0.75)) == SIMD3(0.25, 0.5, 0.75))
        #expect(stock.exposurePerUnit == SIMD3(repeating: 1))
        #expect(abs(stock.densityRange - 13 * log10(Float(2))) < 1e-6)
        #expect(stock.boxSpeed == 400)
        #expect(stock.origin == .userImported)
        #expect(stock.grain == nil && stock.halation == nil)

        // Reference values from argent_bake.neutral.develop.
        expectSample(stock, at: SIMD3(repeating: 0.25), near: SIMD3(repeating: 0.00389710))
        expectSample(stock, at: SIMD3(repeating: 0.75), near: SIMD3(repeating: 0.62319238))
        expectSample(stock, at: SIMD3(0.625, 0.625, 0.5), near: SIMD3(0.19817199, 0.19817199, 0.06424932))
    }

    @Test func sonyModeTransformsGamutAndBothLogSegments() throws {
        let stock = try CubeImporter.bake(identity, id: "user-sony", name: "Sony",
                                          options: .init(inputSpace: .sonySLog3), size: 9)
        expectSample(stock, at: SIMD3(repeating: 0.25), near: SIMD3(repeating: 0.01678752))
        expectSample(stock, at: SIMD3(repeating: 0.75), near: SIMD3(repeating: 0.25400757))
        expectSample(stock, at: SIMD3(0.875, 0.75, 0.625), near: SIMD3(0.34270566, 0.26254348, 0.18238582))
    }

    @Test func rawModeSamplesAuthorDomainWithTrilinearInterpolation() throws {
        // Only the r=1, g=1 edge has red. At the center it contributes 1/4, not 1/2 as in tetrahedral interpolation.
        let text = """
        DOMAIN_MIN -0.5 0 0
        DOMAIN_MAX 0.5 2 1
        LUT_3D_SIZE 2
        0 0 0
        0 0 0
        0 0 0
        1 0 0
        0 0 0
        0 0 0
        0 0 0
        1 0 0
        """
        let stock = try CubeImporter.bake(LUT3D.parseCube(text), id: "user-raw", name: "Raw",
                                          options: .init(inputSpace: .rawPrint), size: 3)
        expectSample(stock, at: SIMD3(0, 1, 0.5), near: SIMD3(0.25, 0, 0))
        expectSample(stock, at: SIMD3(1, 1, 0.5), near: SIMD3(0.5, 0, 0))
    }

    @Test func finishProfilesAndBoxSpeedSurviveStockSerialization() throws {
        let color = Stock.CanisterColor(red: 0.2, green: 0.5, blue: 0.7)
        let halation = Stock.Halation(strength: 0.037, greenShare: 0.42, radiusMicrometres: 180)
        let stock = try CubeImporter.bake(identity, id: "user-finish", name: "Finish",
                                          options: .init(inputSpace: .rawPrint, grain: .highSpeed, halation: .custom(halation),
                                                         boxSpeed: 800, canisterColor: color), size: 2)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try stock.write(to: folder)
        let loaded = try Stock.load(from: folder, origin: .userImported)
        let grain = try #require(loaded.grain)
        #expect(grain.sigma(layer: 0, amount: 0.25) > grain.sigma(layer: 0, amount: 0.75))
        #expect(loaded.grain == stock.grain)
        #expect(loaded.halation == halation)
        #expect(loaded.boxSpeed == 800)
        #expect(loaded.canisterColor == color)

        var strengths: [Float] = []
        for profile in [CubeImporter.Grain.fine, .medium, .coarse, .highSpeed] {
            let finish = try CubeImporter.bake(identity, id: "user-finish", name: "Finish",
                                               options: .init(grain: profile, halation: .subtle), size: 2)
            strengths.append(try #require(finish.grain).sigma(layer: 0, amount: 0.5))
            #expect(finish.halation?.strength == 0.015)
        }
        #expect(zip(strengths, strengths.dropFirst()).allSatisfy { $0.0 < $0.1 })
        let strong = try CubeImporter.bake(identity, id: "user-finish", name: "Finish",
                                           options: .init(halation: .strong), size: 2)
        #expect(strong.halation?.strength == 0.05)
        #expect(throws: StockError.self) {
            try CubeImporter.bake(identity, id: "user-finish", name: "Finish",
                                  options: .init(halation: .custom(.init(strength: .nan, greenShare: 0, radiusMicrometres: 180))),
                                  size: 2)
        }
    }

    private func expectSample(_ stock: Stock, at input: SIMD3<Float>, near expected: SIMD3<Float>) {
        let sample = stock.print.sample(encoded: input)
        for channel in 0..<3 {
            #expect(abs(sample[channel] - expected[channel]) < 0.00002)
        }
    }
}
