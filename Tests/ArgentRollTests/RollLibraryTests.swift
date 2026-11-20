@testable import ArgentCore
@testable import ArgentRoll
import CoreGraphics
import Foundation
import ImageIO
import Testing

/// The Rolls page's library as `BookmarkStore` keeps it, and the covers `RollCoverStore` keeps for it.
@Suite struct RollLibraryTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func store(in folder: URL) -> BookmarkStore {
        BookmarkStore(file: folder.appendingPathComponent("Bookmarks.json"), securityScoped: false)
    }

    @Test func aRollAddedAgainKeepsItsIdAndNameAndBecomesImported() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Titos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let library = store(in: base)
        #expect(library.rolls.isEmpty)
        let added = try #require(library.addRoll(folder, origin: .inPlace, at: Date(timeIntervalSince1970: 10)))
        #expect(added.name == "Titos" && added.origin == .inPlace && added.source == nil && added.volume == nil)
        #expect(added.date == Date(timeIntervalSince1970: 10))
        library.updateRoll(id: added.id) { $0.name = "Saturday" }
        let again = try #require(library.addRoll(folder, origin: .imported, source: "Untitled"))
        #expect(again.id == added.id && again.name == "Saturday" && again.origin == .imported && again.source == "Untitled")
        // An in-place add of an imported roll leaves it imported.
        #expect(library.addRoll(folder, origin: .inPlace)?.origin == .imported)
        #expect(library.rolls.count == 1)
        #expect(library.roll(atPath: folder.path)?.id == added.id)
        #expect(library.resolve(again)?.canonicalPath == folder.canonicalPath)

        // Kept across launches; removing forgets it and leaves the folder.
        let reopened = store(in: base)
        #expect(reopened.rolls.map(\.name) == ["Saturday"])
        #expect(reopened.removeRoll(id: added.id))
        #expect(!reopened.removeRoll(id: added.id))
        #expect(store(in: base).rolls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    /// A store written before the library makes its recents the first rolls, added where they are, oldest first;
    /// a card opened as a roll, a whole volume, is left out.
    @Test func theRecentsOfAStoreWrittenBeforeTheLibraryBecomeItsFirstRolls() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let older = base.appendingPathComponent("Misc"), newer = base.appendingPathComponent("Titos")
        for folder in [older, newer] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let first = store(in: base)
        first.noteOpened(older, at: Date(timeIntervalSince1970: 1))
        first.noteOpened(newer, at: Date(timeIntervalSince1970: 2))
        // As the build before the library wrote it: recents, and no rolls; one recent a card's volume.
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: first.file)) as? [String: Any])
        json["rolls"] = nil
        var recents = try #require(json["recents"] as? [[String: Any]])
        var card = recents[0]
        card["path"] = "/Volumes/Untitled"
        card["name"] = "Untitled"
        recents.insert(card, at: 0)
        json["recents"] = recents
        try JSONSerialization.data(withJSONObject: json).write(to: first.file)

        let migrated = store(in: base)
        #expect(migrated.rolls.map(\.name) == ["Misc", "Titos"])
        #expect(migrated.rolls.allSatisfy { $0.origin == .inPlace && $0.opened != nil })
        #expect(migrated.rolls.map(\.added) == [Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 2)])
        // Written once: the next launch reads the same rolls with the same ids.
        #expect(store(in: base).rolls.map(\.id) == migrated.rolls.map(\.id))
    }

    @Test func aVolumesRootAndNameAreReadFromThePath() {
        #expect(BookmarkStore.isVolumeRoot("/Volumes/Untitled"))
        #expect(!BookmarkStore.isVolumeRoot("/Volumes/T7 Shield/Rolls"))
        #expect(!BookmarkStore.isVolumeRoot("/Users/me/Pictures"))
        #expect(BookmarkStore.volumeName(ofPath: "/Volumes/T7 Shield/Rolls/Titos") == "T7 Shield")
        #expect(BookmarkStore.volumeName(ofPath: "/Users/me/Pictures/Argent/Titos") == nil)
    }

    @Test func coversSpreadFromTheFirstFrameToTheLast() {
        #expect(RollCoverStore.spread(0, 10).isEmpty)
        #expect(RollCoverStore.spread(4, 10) == [0, 1, 2, 3])
        #expect(RollCoverStore.spread(100, 10) == [0, 11, 22, 33, 44, 55, 66, 77, 88, 99])
        #expect(RollCoverStore.spread(11, 10).first == 0 && RollCoverStore.spread(11, 10).last == 10)
        #expect(RollCoverStore.spread(5, 1) == [0])
    }

    @Test func coversAreKeptInOrderReplacedAndRemoved() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RollCoverStore(folder: base.appendingPathComponent("Roll Covers"))
        let id = UUID()
        #expect(store.covers(for: id).isEmpty)
        func image(width: Int) -> CGImage {
            let context = CGContext(data: nil, width: width, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: 20))
            return context.makeImage()!
        }
        store.keep((1...12).map { image(width: 10 + $0) }, for: id)
        #expect(store.covers(for: id).map(\.width) == (1...12).map { 10 + $0 })
        store.keep([image(width: 40)], for: id)
        #expect(store.covers(for: id).map(\.width) == [40])
        store.remove(id)
        #expect(store.covers(for: id).isEmpty)
    }

    @Test func aFolderWithoutRawsHasNoCovers() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(RollCoverStore.read(base) == nil)
    }

    @Test func coversAndTheDateFollowCaptureOrder() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        // Fourteen frames, more than the strip shows, named in the reverse of the order they were taken in:
        // the earliest capture is in the last name, and the shade, and so the red, rises with capture order.
        let total = 14
        for number in 0..<total {
            let captured = String(format: "2026:11:11 10:00:%02d", number)
            let name = String(format: "DSC%05d.ARW", total - number)
            try Data(Self.previewARW(captured: captured, shade: Double(number) / Double(total - 1)))
                .write(to: base.appendingPathComponent(name))
        }
        let read = try #require(RollCoverStore.read(base))
        #expect(read.frameCount == total)
        // The earliest is the last name's, which the spread over name order would not have picked first.
        let earliest = try #require(ARWFrameInfo.read(from: base.appendingPathComponent("DSC00014.ARW")).captureDate)
        #expect(read.firstCapture == earliest)
        #expect(read.covers.count == RollCoverStore.count)
        let reds = try read.covers.map { try Self.red(of: $0) }
        #expect(reds == reds.sorted() && Set(reds).count == reds.count)
        let (lowest, highest) = (try #require(reds.first), try #require(reds.last))
        #expect(lowest < 20 && highest > 235)
    }

    /// The covers and the roll's frames come in one order: capture time, undated frames after dated ones, then the
    /// path with the numbers in it as numbers; an unreadable raw is neither a frame nor a cover.
    @Test func coversFollowTheOrderOfTheRollsFrames() async throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let expected: [(name: String, captured: String)] = [
            ("DSC00010", "2026:11:11 10:00:00"), ("DSC00001", "2026:11:11 10:00:05"),
            ("DSC2", "2026:11:11 10:00:09"), ("DSC10", "2026:11:11 10:00:09"),
            ("DSC3", "undated"), ("DSC20", "undated"),
        ]
        for (index, frame) in expected.enumerated() {
            try Data(Self.previewARW(captured: frame.captured, shade: Double(index) / Double(expected.count - 1)))
                .write(to: base.appendingPathComponent(frame.name + ".ARW"))
        }
        try Data("not a raw".utf8).write(to: base.appendingPathComponent("DSC4.ARW"))

        let roll = await RollScanner.scan(base)
        #expect(roll.frames.map(\.name) == expected.map(\.name))
        #expect(roll.unreadable.map(\.lastPathComponent) == ["DSC4.ARW"])
        let read = try #require(RollCoverStore.read(base))
        #expect(read.frameCount == expected.count + 1)
        let reds = try read.covers.map { try Self.red(of: $0) }
        #expect(reds.count == expected.count)
        #expect(reds == reds.sorted() && Set(reds).count == reds.count)
    }

    /// The red of the middle pixel of `image`, 0 to 255.
    private static func red(of image: CGImage) throws -> Int {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return Int(pixel[0])
    }

    /// A raw with a capture date and an embedded JPEG preview of one shade: a TIFF with the preview's offset and
    /// length in the first image directory and the date in the Exif one.
    private static func previewARW(captured: String, shade: Double) -> [UInt8] {
        let width = 160, height = 120
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: shade, green: 0.5, blue: 1 - shade, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let jpegData = NSMutableData()
        let destination = CGImageDestinationCreateWithData(jpegData, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        let jpeg = [UInt8](jpegData as Data)

        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(v >> (8 * $0) & 0xFF) } }
        func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: [UInt8]) -> [UInt8] {
            u16(tag) + u16(type) + u32(count) + value + [UInt8](repeating: 0, count: 4 - value.count)
        }
        let ifd0 = 8, exif = ifd0 + 2 + 3 * 12 + 4
        let date = Array(captured.utf8) + [0]
        let dateOffset = exif + 2 + 12 + 4
        let jpegOffset = dateOffset + date.count + date.count % 2
        return [0x49, 0x49] + u16(42) + u32(ifd0)
            + u16(3) + entry(0x0201, 4, 1, u32(jpegOffset)) + entry(0x0202, 4, 1, u32(jpeg.count)) + entry(0x8769, 4, 1, u32(exif)) + u32(0)
            + u16(1) + entry(0x9003, 2, date.count, u32(dateOffset)) + u32(0)
            + date + (date.count % 2 == 1 ? [0] : []) + jpeg
    }
}
