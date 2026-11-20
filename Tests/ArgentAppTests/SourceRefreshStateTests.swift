import ArgentCore
import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

private func writeRefreshHeader(_ url: URL, iso: UInt16, orientation: UInt16, date: String) throws {
    func u16(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8(value >> 8 & 255)] }
    func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 255) } }
    func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: [UInt8]) -> [UInt8] {
        u16(tag) + u16(type) + u32(count) + value + [UInt8](repeating: 0, count: 4 - value.count)
    }
    let exif = 8 + 2 + 2 * 12 + 4, text = exif + 2 + 2 * 12 + 4
    let captured = Array((date + "\0").utf8)
    var bytes = [UInt8]([0x49, 0x49]) + u16(42) + u32(8)
    bytes += u16(2) + entry(0x0112, 3, 1, u16(Int(orientation)))
    bytes += entry(0x8769, 4, 1, u32(exif)) + u32(0)
    bytes += u16(2) + entry(0x8827, 3, 1, u16(Int(iso)))
    bytes += entry(0x9003, 2, captured.count, u32(text)) + u32(0) + captured
    try Data(bytes).write(to: url, options: .atomic)
}

@MainActor @Suite(.serialized) struct SourceRefreshStateTests {
    @Test func refreshingAReplacementUpdatesHeadersTaskIdentityAndGrainWithoutMovingSelection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-source-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("A.ARW"), second = folder.appendingPathComponent("B.ARW")
        try writeRefreshHeader(first, iso: 100, orientation: 1, date: "2026:10:09 10:00:00")
        try writeRefreshHeader(second, iso: 200, orientation: 1, date: "2026:10:09 11:00:00")
        let bookmarks = BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false)
        let model = RollModel(bookmarks: bookmarks, stocksDirectory: folder, decisions: AutoDecisionStore(library: folder),
                              flagStore: FlagStore(library: folder), recipeLibrary: folder,
                              previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        await model.open(folder)
        model.selection = 1
        model.openFrame()
        let before = try #require(model.selectedFrame)
        let oldSource = try #require(model.sourceStamp(for: before))
        let oldGrain = before.grainSeed
        let oldRequest = FrameSourceRequest(frame: before.url, source: oldSource)
        try writeRefreshHeader(second, iso: 6400, orientation: 6, date: "2026:10:08 09:00:00")

        #expect(model.forgetChangedSources())
        let after = try #require(model.selectedFrame)
        #expect(after.id == before.id && after.url == before.url && model.isFrameOpen)
        #expect(after.info.iso == 6400 && after.info.isPortrait && after.info.captureDate != before.info.captureDate)
        #expect(after.grainSeed != oldGrain)
        #expect(model.sourceStamp(for: after) == SourceStamp.of(second))
        #expect(FrameSourceRequest(frame: after.url, source: model.sourceStamp(for: after)) != oldRequest)
        #expect(!model.forgetChangedSources())
    }

    @Test func anUnreadableReplacementHasNoHeaderStampAndCannotAcceptAnOldMeasurement() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-source-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("A.ARW")
        try writeRefreshHeader(raw, iso: 100, orientation: 1, date: "2026:10:09 10:00:00")
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        await model.open(folder)
        let frame = try #require(model.selectedFrame)
        let oldSource = try #require(model.sourceStamp(for: frame))
        try Data("broken replacement".utf8).write(to: raw, options: .atomic)
        #expect(model.forgetChangedSources())
        #expect(model.sourceStamp(for: frame) == nil)
        model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 1, validWeight: 1), source: oldSource), for: frame)
        #expect(model.analysis(for: frame) == nil)
        #expect(!model.forgetChangedSources())
    }
}
