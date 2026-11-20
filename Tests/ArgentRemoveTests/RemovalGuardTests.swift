import ArgentCore
import ArgentRoll
import AppKit
import Foundation
import Testing
@testable import ArgentApp

/// The base of docs/remove-plan.md in the app: a copy never takes a removal, a paste and a reset never move or drop one, and the
/// Remove tab is named and not yet shown (section 4.1).
@MainActor @Suite(.serialized) struct RemovalGuardTests {
    private func header(_ url: URL) throws {
        func u16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255)] }
        func u32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(n >> (8 * $0) & 255) } }
        var b: [UInt8] = [0x49, 0x49] + u16(42) + u32(8)
        b += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(26) + u32(0)
        b += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(100) + u16(0) + u32(0)
        try Data(b).write(to: url, options: .atomic)
    }

    private static func removal(_ byte: String = "ab") throws -> Removal {
        Removal(patch: try PatchRef(id: PatchID(hex: String(repeating: byte, count: 32))!, width: 512, height: 1328))
    }

    /// A roll of one frame that is ready to adjust, holding `adjustments`.
    private func fixture(_ adjustments: ManualAdjustments) async throws -> (RollModel, Frame, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-removal-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try header(folder.appendingPathComponent("DSC1.ARW"))
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        await model.open(folder)
        if let restore = model.manualRestoreTask { await restore.value }
        let frame = try #require(model.selectedFrame)
        let verified = try SourceDigests.shared.digest(of: frame.url)
        model.manualReadySources[frame.url] = verified
        model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 0.3, validWeight: 1), source: verified.source), for: frame)
        let pin = AutomaticBaseline(sourceSHA256: verified.sha256, stockID: "test", stockDigest: "digest",
            controls: .init(), aim: PrintAim(level: -0.65, cast: SIMD3(0.2, -0.1, 0.15)), analysisVersion: ExposureAnalysis.currentVersion,
            baseRender: Recipe.Render(settings: DevelopSettings(labBalance: SIMD3(0.1, 0.2, 0.3)), grain: .off))
        model.manualEdits[frame.url] = ManualEdit(adjustments: adjustments, baseline: pin)
        model.manualUndoManager = UndoManager()
        model.manualUndoManager?.groupsByEvent = false
        return (model, frame, folder)
    }

    @Test func aCopyHoldsNoRemovalAndOffersNoLensPartForOne() async throws {
        let removals = [try Self.removal()]
        let (model, frame, folder) = try await fixture(try ManualAdjustments(exposureEV: 0.5).settingRemovals(removals))
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(model.manualAdjustments(for: frame).removals == removals && model.lensSettings(for: frame).removals == removals)
        let copy = model.clipboard(of: frame)
        #expect(copy.adjustments.removals.isEmpty && copy.adjustments.exposureEV == 0.5)
        #expect(copy.parts.contains(.light) && !copy.parts.contains(.lens))
    }

    @Test func resetLensKeepsTheRemovalsAndMovingALensSliderKeepsThem() async throws {
        let removals = [try Self.removal()]
        let lens = try LensSettings.default.setting(.vignette, to: 25)
        let (model, frame, folder) = try await fixture(try ManualAdjustments().settingLens(lens).settingRemovals(removals))
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(InspectorMenus.canReset(.lens, frame, model: model))
        model.manualUndoManager?.beginUndoGrouping()
        model.resetLens(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        let reset = model.manualAdjustments(for: frame)
        #expect(reset.removals == removals && reset.lens.hasDefaultValues)
        #expect(!InspectorMenus.canReset(.lens, frame, model: model), "nothing of the lens is left to reset")

        // What the Lens tab and the drive hook do: new lens values through `settingLens`.
        model.manualUndoManager?.beginUndoGrouping()
        model.setManualAdjustments(reset.settingLens(try LensSettings(arguments: "distortion-amount=60")), for: frame)
        model.manualUndoManager?.endUndoGrouping()
        let moved = model.manualAdjustments(for: frame)
        #expect(moved.removals == removals && moved.lens.distortion.amount == 60)
    }

    @Test func theRemoveTabIsNamedAndShown() {
        let suite = "argent-removal-guard-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AdjustInspectorTab.remove.rawValue, forKey: AdjustInspectorTab.storageKey)
        #expect(AdjustInspectorTab.showsRemove)
        #expect(AdjustInspectorTab.stored(in: defaults) == .remove, "the strip shows it, so it is one to open on")
        defaults.set(AdjustInspectorTab.lens.rawValue, forKey: AdjustInspectorTab.storageKey)
        #expect(AdjustInspectorTab.stored(in: defaults) == .lens)
    }
}
