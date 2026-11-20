import Foundation
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// A selection's edge at the library: what a develop weighs, what a pack carries, and what the overlay keeps apart.
@Suite struct SmartEdgeRollTests {
    private static let frame = try! MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)

    private func masks(_ edge: SmartEdge, _ raster: MaskRaster, kind: SmartKind = .subject) throws -> MaskSet {
        try MaskSet(masks: [Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: kind, raster: raster.ref, frame: Self.frame, edge: edge)))],
                                 adjustments: try ManualAdjustments(exposureEV: -1))])
    }

    /// What a matte costs a develop: the alpha held for the render, its `r8Unorm` texture and field, and the slices, with no guide frame or working set.
    @Test func aMatteWeighsItsAlphaAndItsFieldAndNoFilter() throws {
        let alpha = try MaskRaster(width: 2560, height: 1707, plane: [UInt8](repeating: 180, count: 2560 * 1707))
        let settings = try MaskFixtures.settings(try masks(.matte, alpha))
        let field = MaskFieldSize(picture: try MaskSpace(width: 7008, height: 4672))
        let cost = DevelopBudget.maskCost(settings: settings, width: 7008, height: 4672)
        let seeds = 2560 * 1707, slice = 2048 * 1365 * 8, tables = 181_936, texture = 2560 * 1707 + field.width * field.height * 2
        #expect(cost == seeds + slice + tables + texture, "\(cost)")
        // A crisp seed costs what today's Subject at its size does.
        let seed = try MaskRaster(width: 1024, height: 683, plane: [UInt8](repeating: 180, count: 1024 * 683))
        let crisp = DevelopBudget.maskCost(settings: try MaskFixtures.settings(try masks(.crisp, seed)), width: 7008, height: 4672)
        let guided = DevelopBudget.maskCost(settings: try MaskFixtures.settings(try masks(.guided, seed)), width: 7008, height: 4672)
        #expect(crisp == guided)
    }

    /// A pack carries a matte's print-size alpha as it carries any seed, with no limit a print's size reaches, and a record asks for it by name.
    @Test func aPackCarriesAPrintSizedAlpha() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MaskRasterStore(library: root.appendingPathComponent("library"))
        let plane = (0..<(2560 * 1707)).map { UInt8($0 % 256) }
        let alpha = try MaskRaster(width: 2560, height: 1707, plane: plane)
        let ref = try store.store(alpha)
        let pack = root.appendingPathComponent("frame").appendingPathExtension(MaskRasterStore.packExtension)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("library"), withIntermediateDirectories: true)
        try store.writePack([ref], to: pack)
        let other = MaskRasterStore(library: root.appendingPathComponent("elsewhere"))
        #expect(try other.importPack(from: pack).added == [ref.id])
        #expect(try other.load(ref) == alpha)
        #expect(MaskSeeds.needs(try ManualRenderSettings(adjustments: ManualAdjustments.identity.settingMasks(try masks(.matte, alpha)), referenceStops: 0)).rasters == [ref])
    }

    /// The overlay's kept rasters are keyed by edge, so a raster refined as `crisp` is never shown for the same pixels as `guided`.
    @Test func theOverlayKeepsEdgesApart() throws {
        let raster = try MaskRaster(width: 64, height: 48, plane: [UInt8](repeating: 9, count: 3072))
        func key(_ edge: SmartEdge) -> RefinedOverlayKey {
            RefinedOverlayKey(guide: MaskGuideID(serial: 1, width: 2, height: 3), raster: raster.identity, kind: .subject, feather: 0, edge: edge, width: 8, height: 6)
        }
        #expect(key(.crisp) != key(.guided) && key(.matte) != key(.crisp))
    }
}
