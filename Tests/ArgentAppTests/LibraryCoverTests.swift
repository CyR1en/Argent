import ArgentCore
import ArgentRoll
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ArgentApp

@MainActor @Suite(.serialized) struct LibraryCoverTests {
    private final class ScanActivity: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var maximum = 0
        private var folders: [URL] = []

        func begin(_ folder: URL) {
            lock.withLock {
                active += 1
                maximum = max(maximum, active)
                folders.append(folder)
            }
        }

        func end() { lock.withLock { active -= 1 } }
        var peak: Int { lock.withLock { maximum } }
        var scanned: [URL] { lock.withLock { folders } }
    }

    private func model(in folder: URL) -> RollModel {
        RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                  stocksDirectory: folder, decisions: AutoDecisionStore(library: folder),
                  flagStore: FlagStore(library: folder), recipeLibrary: folder,
                  previewCache: folder.appendingPathComponent("Previews"), digestsFile: nil)
    }

    private nonisolated static func image(width: Int = 8) -> CGImage {
        CGContext(data: nil, width: width, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
    }

    private nonisolated static func previewARW(frame: Int) -> Data {
        let jpeg = NSMutableData()
        let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image(width: 8 + frame), nil)
        CGImageDestinationFinalize(destination)
        func u16(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8((value >> 8) & 255)] }
        func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 255) } }
        func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: Int) -> [UInt8] {
            u16(tag) + u16(type) + u32(count) + u32(value)
        }
        let exif = 50, dateOffset = 68
        let date = Array(String(format: "2026:11:11 10:00:%02d", frame).utf8) + [0]
        let jpegOffset = dateOffset + date.count
        let header = [0x49, 0x49] + u16(42) + u32(8)
            + u16(3) + entry(0x0201, 4, 1, jpegOffset) + entry(0x0202, 4, 1, jpeg.length)
            + entry(0x8769, 4, 1, exif) + u32(0)
            + u16(1) + entry(0x9003, 2, date.count, dateOffset) + u32(0) + date
        return Data(header) + (jpeg as Data)
    }

    @Test(arguments: [false, true])
    func removedRollDoesNotRegainCovers(readd: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-covers-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = model(in: folder)
        let bookmarks = model.bookmarks
        let id = try #require(bookmarks.addRoll(folder, origin: .inPlace)?.id)
        let release = DispatchSemaphore(value: 0)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let work = try #require(model.readCovers(for: id) {
            signal.yield(())
            release.wait()
            return [Self.image()]
        })
        for await _ in started { break }
        model.removeLibraryRoll(id: id)
        if readd {
            let replacement = try #require(bookmarks.addRoll(folder, origin: .inPlace)?.id)
            #expect(replacement != id)
            await model.readCovers(for: replacement) { [Self.image(width: 16)] }?.value
            #expect(model.rollCovers[replacement]?.first?.width == 16)
            #expect(model.coverStore.covers(for: replacement).first?.width == 16)
        }
        release.signal()
        await work.value
        #expect(model.rollCovers[id] == nil)
        #expect(model.coverStore.covers(for: id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: model.coverStore.folder.appendingPathComponent(id.uuidString).path))
    }

    @Test(arguments: [false, true])
    func refreshedCoversWinOverStaleProduction(staleFinishesFirst: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-covers-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = model(in: folder)
        let id = try #require(model.bookmarks.addRoll(folder, origin: .inPlace)?.id)
        let oldRelease = DispatchSemaphore(value: 0), newRelease = DispatchSemaphore(value: 0)
        let (oldStarted, oldSignal) = AsyncStream<Void>.makeStream()
        let old = try #require(model.readCovers(for: id) {
            oldSignal.yield(())
            oldRelease.wait()
            return [Self.image()]
        })
        for await _ in oldStarted { break }
        model.invalidateLibraryCovers(id)
        let (newStarted, newSignal) = AsyncStream<Void>.makeStream()
        let new = try #require(model.readCovers(for: id) {
            newSignal.yield(())
            newRelease.wait()
            return [Self.image(width: 16)]
        })
        for await _ in newStarted { break }
        if staleFinishesFirst {
            oldRelease.signal()
            await old.value
            #expect(model.coverReads.contains(id))
            #expect(model.rollCovers[id] == nil)
            #expect(model.coverStore.covers(for: id).isEmpty)
            newRelease.signal()
            await new.value
        } else {
            newRelease.signal()
            await new.value
            oldRelease.signal()
            await old.value
        }
        #expect(model.rollCovers[id]?.first?.width == 16)
        #expect(model.coverStore.covers(for: id).first?.width == 16)
        #expect(!model.coverReads.contains(id))
    }

    @Test func emptyProductionFinishesWithoutPersisting() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-covers-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = model(in: folder)
        let id = try #require(model.bookmarks.addRoll(folder, origin: .inPlace)?.id)
        await model.readCovers(for: id) { [] }?.value
        #expect(model.rollCovers[id]?.isEmpty == true)
        #expect(!model.coverReads.contains(id))
        #expect(!FileManager.default.fileExists(atPath: model.coverStore.folder.appendingPathComponent(id.uuidString).path))
    }

    @Test func openRollCoversPublishWhileColdScanSlotsAreFull() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-cover-bound-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = model(in: folder)
        let release = DispatchSemaphore(value: 0)
        let limit = RollModel.coverScanLimit
        defer { for _ in 0..<limit { release.signal() } }
        for index in 0..<limit {
            let directory = folder.appendingPathComponent("Roll-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.previewARW(frame: 0).write(to: directory.appendingPathComponent("frame.ARW"))
            _ = try #require(model.bookmarks.addRoll(directory, origin: .inPlace))
        }
        model.library = model.bookmarks.rolls
        let (started, signal) = AsyncStream<Void>.makeStream()
        model.libraryCoverReader = { directory in
            signal.yield(())
            release.wait()
            return RollCoverStore.read(directory)
        }
        let scans = model.loadLibraryCovers()
        var starts = started.makeAsyncIterator()
        for _ in 0..<limit { _ = await starts.next() }
        _ = await model.libraryCoverPreparation?.value
        #expect(model.activeCoverScans == limit)
        #expect(model.pendingCoverScans.isEmpty)

        let id = UUID()
        let work = try #require(model.readCovers(for: id) { [Self.image(width: 16)] })
        await work.value
        #expect(model.rollCovers[id]?.map(\.width) == [16])
        #expect(model.coverStore.covers(for: id).map(\.width) == [16])
        #expect(!model.coverReads.contains(id))
        #expect(model.activeCoverScans == limit)
        #expect(model.pendingCoverScans.isEmpty)

        for _ in 0..<limit { release.signal() }
        await scans.value
        #expect(model.activeCoverScans == 0)
        #expect(model.coverReads.isEmpty)
    }

    @Test(arguments: [false, true])
    func coldScansAreBoundedAndCompleteInPageOrder(oldestFirst: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-library-queue-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = model(in: folder)
        var ids: [UUID] = []
        for index in 0..<12 {
            let directory = folder.appendingPathComponent("Roll-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for frame in 0..<14 {
                try Self.previewARW(frame: frame).write(to: directory.appendingPathComponent("frame-\(14 - frame).ARW"))
            }
            try Data("unreadable raw".utf8).write(to: directory.appendingPathComponent("broken.ARW"))
            ids.append(try #require(model.bookmarks.addRoll(directory, origin: .inPlace, at: Date(timeIntervalSince1970: Double(index)))?.id))
        }
        var bypass: [UUID] = []
        for (index, name) in ["Empty", "Offline", "Warm"].enumerated() {
            let directory = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if name == "Offline" { try Self.previewARW(frame: 0).write(to: directory.appendingPathComponent("frame.ARW")) }
            let date = oldestFirst ? 100 + index : -100 - index
            bypass.append(try #require(model.bookmarks.addRoll(directory, origin: .inPlace, at: Date(timeIntervalSince1970: Double(date)))?.id))
        }
        let warm = bypass[2]
        model.coverStore.keep([Self.image(width: 32)], for: warm)
        model.unavailableRolls.insert(bypass[1])
        model.library = model.bookmarks.rolls
        let expected = model.libraryRolls(oldestFirst: oldestFirst).filter { ids.contains($0.id) }
        let release = DispatchSemaphore(value: 0)
        let (started, signal) = AsyncStream<String>.makeStream()
        let activity = ScanActivity()
        let limit = RollModel.coverScanLimit
        model.libraryCoverReader = { directory in
            if directory.lastPathComponent == "Empty" { return RollCoverStore.read(directory) }
            activity.begin(directory)
            defer { activity.end() }
            signal.yield(directory.lastPathComponent)
            if activity.peak > limit { release.signal() }
            release.wait()
            return RollCoverStore.read(directory)
        }
        let work = model.loadLibraryCovers(oldestFirst: oldestFirst)
        _ = await model.libraryCoverPreparation?.value
        #expect(model.activeCoverScans == limit)
        #expect(model.pendingCoverScans.count == ids.count + 1 - limit)
        #expect(model.rollCovers[warm]?.first?.width == 32)
        #expect(model.rollCovers[bypass[0]]?.isEmpty == true)
        #expect(model.rollCovers[bypass[1]]?.isEmpty == true)
        var starts = started.makeAsyncIterator()
        var first: [String] = []
        for _ in 0..<limit { if let name = await starts.next() { first.append(name) } }
        #expect(Set(first) == Set(expected.prefix(limit).map(\.name)))
        let removed = try #require(expected.last?.id)
        model.removeLibraryRoll(id: removed)
        for _ in 0..<(ids.count + bypass.count) { release.signal() }
        await work.value
        #expect(model.coverReads.isEmpty)
        #expect(model.activeCoverScans == 0)
        #expect(model.rollCovers[removed] == nil)
        #expect(model.coverStore.covers(for: removed).isEmpty)
        #expect(activity.peak == limit)
        #expect(activity.scanned.count == ids.count - 1)
        #expect(!activity.scanned.contains { $0.path == expected.last?.path })
        for entry in expected where entry.id != removed {
            let unbounded = try #require(RollCoverStore.read(URL(fileURLWithPath: entry.path)))
            #expect(unbounded.covers.map(\.width) == RollCoverStore.spread(15, RollCoverStore.count).filter { $0 < 14 }.map { 8 + $0 })
            #expect(model.rollCovers[entry.id]?.map(\.width) == unbounded.covers.map(\.width))
            #expect(model.bookmarks.roll(id: entry.id)?.frameCount == unbounded.frameCount)
            #expect(model.bookmarks.roll(id: entry.id)?.firstCapture == unbounded.firstCapture)
        }
    }
}
