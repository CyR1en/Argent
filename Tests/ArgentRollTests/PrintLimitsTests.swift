import ArgentCore
import Foundation
import Testing
@testable import ArgentRoll

/// The print's own white and black, which the app's clipping views compare a film's codes to.
@Suite struct PrintLimitsTests {
    @Test func comeFromTheStocksOwnRenderAndFollowThePrintSideSettings() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeToyStock(id: "toy", in: directory)
        let films = try FilmPreviews(stocks: StockLibrary.load(from: directory).stocks)
        let plain = try #require(await films.printLimits(stock: 0, settings: DevelopSettings()))
        #expect((0..<3).allSatisfy { plain.white[$0] > plain.black[$0] }, "\(plain)")
        // A uniform frame's ends do not depend on grain, halation or sharpening, so those share one probe.
        var grainy = DevelopSettings(grain: 1, halation: true, sharpen: true)
        grainy.grainSeed = 7
        #expect(await films.printLimits(stock: 0, settings: grainy) == plain)
        // Blacks under compiler 2026-10-09-1 lifts the print's lower end; scene Exposure moves neither end.
        let lifted = try #require(await films.printLimits(stock: 0, settings: DevelopSettings(manual: ManualRenderSettings(
            adjustments: ManualAdjustments(blacks: 100), referenceStops: 0, version: "2026-10-09-1"))))
        #expect((0..<3).allSatisfy { lifted.black[$0] > plain.black[$0] }, "\(lifted)")
        let exposed = try #require(await films.printLimits(stock: 0, settings: DevelopSettings(manual: ManualRenderSettings(
            adjustments: ManualAdjustments(exposureEV: -5), referenceStops: 0, version: "2026-10-09-1"))))
        #expect(exposed == plain)
        #expect(await films.printLimits(stock: 1, settings: DevelopSettings()) == nil)
    }
}
