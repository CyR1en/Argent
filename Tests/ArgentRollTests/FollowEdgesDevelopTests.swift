import Foundation
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// A Follow edges stroke's measured shape is a seed to the develop: loaded and checked before the frame's decode, counted by the memory
/// gate, kept by the store's sweep and written into packs, and a lost one fails the frame rather than print the brush without it.
@Suite struct FollowEdgesDevelopTests {
    static func manual(_ raster: MaskRaster) throws -> ManualRenderSettings {
        let measured = try MeasuredStroke(raster: raster.ref, x: 400, y: 300, pictureWidth: 7008, pictureHeight: 4672)
        let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let stroke = BrushStroke(followEdges: true, radius: 0.02, points: try PackedPoints.pack([MaskPoint(x: 0.25, y: 0.2)]), measured: measured)
        let mask = Mask(components: [MaskComponent(shape: .brush(BrushPaint(frame: frame, strokes: [stroke])))],
                        adjustments: try ManualAdjustments(exposureEV: 0.8))
        return try ManualRenderSettings(adjustments: ManualAdjustments.identity.settingMasks(try MaskSet(masks: [mask])), referenceStops: 0)
    }

    @Test func aLostShapeFailsTheFrameBeforeItsDecode() throws {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("argent-follow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: library) }
        let raster = try MaskRaster(width: 120, height: 40, plane: (0..<4800).map { UInt8($0 % 200) })
        let manual = try Self.manual(raster)
        let needs = MaskSeeds.needs(manual)
        #expect(needs.rasters == [raster.ref] && needs.pending.isEmpty)
        let store = MaskRasterStore(library: library)
        let failure = try #require(RollDeveloper.seedFailure(needs, store: store))
        #expect(failure.contains("missing"))
        try store.store(raster)
        #expect(RollDeveloper.seedFailure(needs, store: store) == nil)
        #expect(try store.seeds(needs.rasters)[raster.ref] == raster)
    }

    @Test func theGateCountsTheShapeAndASecondCanvas() throws {
        let raster = try MaskRaster(width: 120, height: 40, plane: [UInt8](repeating: 9, count: 4800))
        let manual = try Self.manual(raster)
        var plain = manual
        // The same brush with its stroke plain: no shape, no second canvas.
        var mask = manual.adjustments.masks.masks[0]
        guard case .brush(var paint) = mask.components[0].shape else { Issue.record("not a brush"); return }
        paint.strokes[0].followEdges = false
        paint.strokes[0].measured = nil
        mask.components[0].shape = .brush(paint)
        plain = try ManualRenderSettings(adjustments: ManualAdjustments.identity.settingMasks(try MaskSet(masks: [mask])), referenceStops: 0)
        let followed = DevelopBudget.maskCost(settings: DevelopSettings(manual: manual), width: 7008, height: 4672)
        let painted = DevelopBudget.maskCost(settings: DevelopSettings(manual: plain), width: 7008, height: 4672)
        let field = MaskFieldSize(picture: try MaskSpace(width: 7008, height: 4672))
        // The seed as the lane holds it, the same bytes in the laying's buffer, and the second canvas the laying writes.
        #expect(followed - painted == 2 * 4800 + BrushCanvas.byteCount(field), "\(followed - painted)")
    }
}
