import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

@MainActor @Suite(.serialized) struct FrameZoomLifecycleTests {
    @Test(arguments: [false, true])
    func openingARollFitsItsFirstFrameAndDropsThePreviousZoomRoom(reopenSameRoll: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-zoom-lifecycle-\(UUID().uuidString)")
        let first = folder.appendingPathComponent("First"), second = folder.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func u16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255)] }
        func u32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(n >> (8 * $0) & 255) } }
        var bytes: [UInt8] = [0x49, 0x49] + u16(42) + u32(8)
        bytes += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(26) + u32(0)
        bytes += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(100) + u16(0) + u32(0)
        try (Data(bytes) + Data(UUID().uuidString.utf8)).write(to: first.appendingPathComponent("A.ARW"))
        try (Data(bytes) + Data(UUID().uuidString.utf8)).write(to: second.appendingPathComponent("B.ARW"))
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        await model.open(first)
        if let restoration = model.manualRestoreTask { await restoration.value }
        defer { model.clearManualSession() }
        model.openFrame()
        #expect(model.isFrameOpen)
        #expect(model.selectedFrame?.id == 0)
        let room = FrameZoom.Room(area: CGSize(width: 1464, height: 880), fitted: CGSize(width: 1320, height: 880),
                                  fitPixels: 2640, fullPixels: 7008, displayScale: 2)
        model.frameZoomRoom = room
        model.zoomFrame(.actualSize)
        model.panFrame(by: CGSize(width: 80, height: -60), ended: true)
        #expect(model.frameZoom.isZoomed)
        #expect(model.frameZoom.offset != .zero)
        #expect(model.frameZoomRoom == room)

        let target = reopenSameRoll ? first : second
        await model.open(target)
        if let restoration = model.manualRestoreTask { await restoration.value }
        #expect(model.roll?.folder == target)
        #expect(model.selectedFrame?.url.lastPathComponent == (reopenSameRoll ? "A.ARW" : "B.ARW"))
        // Both rolls select frame zero: selection's observer cannot detect this transition.
        #expect(model.selectedFrame?.id == 0)
        #expect(!model.isFrameOpen)
        #expect(model.frameZoom == FrameZoom())
        #expect(model.frameZoomRoom == nil)
        model.openFrame()
        #expect(model.isFrameOpen)
        #expect(model.frameZoom == FrameZoom())
        #expect(model.frameZoomRoom == nil)
    }
}
