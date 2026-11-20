import ArgentCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ArgentRoll

/// Writes a minimal ARW-shaped file: IFD0 with an embedded JPEG, an orientation and an Exif
/// IFD holding the capture time.
private func writeARW(to url: URL, captured: String, subseconds: String, orientation: UInt16 = 1,
                      width: Int = 48, height: Int = 32) throws {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(red: 0.6, green: 0.4, blue: 0.2, alpha: 1)
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
    // Layout: header 8 | IFD0 (4 entries) at 8 | Exif IFD (2 entries) | strings | JPEG.
    let ifd0 = 8, ifd0Size = 2 + 4 * 12 + 4
    let exif = ifd0 + ifd0Size, exifSize = 2 + 2 * 12 + 4
    let dateText = Array(captured.utf8) + [0]
    let dateOffset = exif + exifSize
    let jpegOffset = dateOffset + dateText.count + dateText.count % 2
    var out: [UInt8] = [0x49, 0x49] + u16(42) + u32(ifd0)
    out += u16(4) + entry(0x0112, 3, 1, u16(Int(orientation))) + entry(0x0201, 4, 1, u32(jpegOffset))
        + entry(0x0202, 4, 1, u32(jpeg.count)) + entry(0x8769, 4, 1, u32(exif)) + u32(0)
    let sub = Array(subseconds.utf8) + [0]
    out += u16(2) + entry(0x9003, 2, dateText.count, u32(dateOffset)) + entry(0x9291, 2, sub.count, sub) + u32(0)
    out += dateText + (dateText.count % 2 == 1 ? [0] : [])
    out += jpeg
    try Data(out).write(to: url)
}

@Suite struct RollTests {
    @Test func scansACardInCaptureOrder() async throws {
        let card = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: card) }
        let dcim = card.appendingPathComponent("DCIM/100MSDCF")
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        // File names out of capture order, two frames in the same second told apart by
        // sub-seconds, a lower-case extension, and things that are not frames.
        try writeARW(to: dcim.appendingPathComponent("DSC00003.ARW"), captured: "2026:10:06 10:00:01", subseconds: "500")
        try writeARW(to: dcim.appendingPathComponent("DSC00001.ARW"), captured: "2026:10:06 10:00:01", subseconds: "900")
        try writeARW(to: dcim.appendingPathComponent("DSC00002.arw"), captured: "2026:10:06 09:59:59", subseconds: "0",
                     orientation: 8)
        try Data("not a raw".utf8).write(to: dcim.appendingPathComponent("DSC00004.ARW"))
        try Data("appledouble".utf8).write(to: dcim.appendingPathComponent("._DSC00001.ARW"))
        try Data("jpeg".utf8).write(to: dcim.appendingPathComponent("DSC00001.JPG"))

        let roll = await RollScanner.scan(card)
        #expect(roll.frames.map(\.name) == ["DSC00002", "DSC00003", "DSC00001"])
        #expect(roll.frames.map(\.id) == [0, 1, 2])
        #expect(roll.unreadable.map(\.lastPathComponent) == ["DSC00004.ARW"])
        #expect(roll.frames[0].info.isPortrait)
        #expect(roll.name == card.lastPathComponent)
    }

    /// A 10 fps burst as the a7 IV and its generation write it (docs/research/camera.md, section 3):
    /// SubSecTimeOriginal in three digits, leading zeros kept, across a second and across the
    /// card's folder change when numbering passes DSC09999. Sorted by name it would start at
    /// DSC00001.
    @Test func aBurstKeepsCaptureOrderAcrossASecondAndAFolder() async throws {
        let card = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: card) }
        let first = card.appendingPathComponent("DCIM/100MSDCF"), second = card.appendingPathComponent("DCIM/101MSDCF")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        var expected: [String] = []
        for shot in 0..<12 {
            let milliseconds = 850 + 100 * shot
            let name = shot < 5 ? String(format: "DSC%05d", 9995 + shot) : String(format: "DSC%05d", shot - 4)
            try writeARW(to: (shot < 5 ? first : second).appendingPathComponent(name + ".ARW"),
                         captured: String(format: "2026:10:07 10:00:%02d", milliseconds / 1000),
                         subseconds: String(format: "%03d", milliseconds % 1000))
            expected.append(name)
        }
        let roll = await RollScanner.scan(card)
        #expect(roll.frames.map(\.name) == expected)
        let times = roll.frames.compactMap(\.info.captureDate)
        #expect(times.count == 12)
        for (a, b) in zip(times, times.dropFirst()) { #expect(abs(b.timeIntervalSince(a) - 0.1) < 1e-3) }
        // One cluster for roll smoothing.
        #expect(RollSmoothing.clusters(roll.frames, analyses: [:]).map(\.count) == [12])
    }

    /// A body that writes no sub-seconds, as Sony's older ones do (reported for the a9), stamps a
    /// burst's frames with the same second; they keep the card's order, folder before name.
    @Test func framesOfOneSecondWithoutSubsecondsKeepTheCardsOrder() async throws {
        let card = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: card) }
        let first = card.appendingPathComponent("DCIM/100MSDCF"), second = card.appendingPathComponent("DCIM/101MSDCF")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        for (folder, name) in [(second, "DSC00002"), (first, "DSC09999"), (second, "DSC00001"), (first, "DSC09998")] {
            try writeARW(to: folder.appendingPathComponent(name + ".ARW"), captured: "2026:10:07 10:00:01", subseconds: "")
        }
        let roll = await RollScanner.scan(card)
        #expect(roll.frames.map(\.name) == ["DSC09998", "DSC09999", "DSC00001", "DSC00002"])
    }

    @Test func framesWithoutATimeSortByNameAfterTimedOnes() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeARW(to: folder.appendingPathComponent("B.ARW"), captured: "garbage", subseconds: "")
        try writeARW(to: folder.appendingPathComponent("A.ARW"), captured: "garbage", subseconds: "")
        try writeARW(to: folder.appendingPathComponent("Z.ARW"), captured: "2026:01:01 00:00:00", subseconds: "")
        let roll = await RollScanner.scan(folder)
        #expect(roll.frames.map(\.name) == ["Z", "A", "B"])
    }

    /// The order `scan` gives a roll's frames and `RollCoverStore.read` its covers, case by case.
    @Test(arguments: [
        ("DSC00009.ARW", 0.0, "DSC00001.ARW", 1.0, true),      // the earlier capture first, whatever the name
        ("DSC00001.ARW", 1.0, "DSC00009.ARW", 0.0, false),
        ("DSC10.ARW", 0.0, "DSC2.ARW", nil, true),             // a time before none
        ("DSC2.ARW", nil, "DSC10.ARW", 0.0, false),
        ("DSC2.ARW", 0.0, "DSC10.ARW", 0.0, true),             // one instant: the numbers in the names as numbers
        ("DSC10.ARW", 0.0, "DSC2.ARW", 0.0, false),
        ("DSC2.ARW", nil, "DSC10.ARW", nil, true),             // no times: as one instant
        ("DSC10.ARW", nil, "DSC2.ARW", nil, false),
        ("100MSDCF/DSC09999.ARW", 0.0, "101MSDCF/DSC00001.ARW", 0.0, true), // the folder before the name
        ("DSC2.ARW", 0.0, "DSC2.ARW", 0.0, false),
    ] as [(String, Double?, String, Double?, Bool)])
    func captureOrder(_ a: String, _ aTime: Double?, _ b: String, _ bTime: Double?, _ before: Bool) {
        let card = URL(fileURLWithPath: "/Volumes/Card/DCIM", isDirectory: true)
        let date = { (time: Double?) in time.map { Date(timeIntervalSinceReferenceDate: 815_000_000 + $0) } }
        #expect(RollScanner.capturedBefore(card.appendingPathComponent(a), at: date(aTime),
                                           card.appendingPathComponent(b), at: date(bTime)) == before)
    }

    /// A roll folder that is itself a symbolic link scans as its target does; a link to a raw
    /// inside the roll is still skipped.
    @Test func followsASymlinkedRollFolderButNotLinksInside() async throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real"), link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try writeARW(to: real.appendingPathComponent("A.ARW"), captured: "2026:01:01 00:00:00", subseconds: "")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try FileManager.default.createSymbolicLink(at: real.appendingPathComponent("B.ARW"),
                                                   withDestinationURL: real.appendingPathComponent("A.ARW"))
        let roll = await RollScanner.scan(link)
        #expect(roll.frames.map(\.name) == ["A"])
    }

    @Test func stopsAtTheMaximumDepth() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var deep = folder
        for level in 0...RollScanner.maximumDepth { deep = deep.appendingPathComponent("level\(level)") }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try writeARW(to: deep.appendingPathComponent("DEEP.ARW"), captured: "2026:01:01 00:00:00", subseconds: "")
        #expect(RollScanner.rawFiles(in: folder).isEmpty)
    }

    @Test func thumbnailsArriveUprightAndAreCached() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeARW(to: folder.appendingPathComponent("P.ARW"), captured: "2026:01:01 00:00:00", subseconds: "",
                     orientation: 6, width: 48, height: 32)
        let roll = await RollScanner.scan(folder)
        let frame = try #require(roll.frames.first)
        let loader = ThumbnailLoader()
        #expect(loader.cached(frame, maxPixelSize: 64) == nil)
        let image = try #require(await loader.thumbnail(for: frame, maxPixelSize: 64))
        #expect(image.width == 32 && image.height == 48)
        #expect(loader.cached(frame, maxPixelSize: 64) != nil)
        loader.removeAll()
        #expect(loader.cached(frame, maxPixelSize: 64) == nil)
    }

    private static let corpus: [URL] = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return ["samples", "references/corpus/photographyblog-a7iv", "references/corpus/imaging-resource-a7iv-wayback"]
            .map { root.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }()

    /// The spec wants a 500-frame sheet's first paint under a second; this measures the header
    /// scan and a full set of thumbnails on whatever a7 IV files are present.
    @Test(.enabled(if: !RollTests.corpus.isEmpty))
    func measuresTheSheetOnRealFiles() async throws {
        let clock = ContinuousClock()
        var frames: [Frame] = []
        var scanTime = Duration.zero
        for folder in Self.corpus {
            let start = clock.now
            let roll = await RollScanner.scan(folder)
            scanTime += clock.now - start
            frames += roll.frames
            #expect(roll.unreadable.isEmpty, "\(folder.lastPathComponent)")
        }
        try #require(!frames.isEmpty, "the corpus folders scanned to no frames")
        let loader = ThumbnailLoader()
        let start = clock.now
        let images = await withTaskGroup(of: CGImage?.self) { group in
            for frame in frames { group.addTask { await loader.thumbnail(for: frame, maxPixelSize: 336) } }
            var all: [CGImage?] = []
            for await image in group { all.append(image) }
            return all
        }
        let thumbTime = clock.now - start
        #expect(images.allSatisfy { $0 != nil })
        let perFrameScan = scanTime / frames.count, perFrameThumb = thumbTime / frames.count
        print("MEASURE \(frames.count) frames: header scan \(scanTime.formatted(.units(allowed: [.milliseconds]))) "
              + "(\(perFrameScan.formatted(.units(allowed: [.microseconds]))) each), thumbnails at 336 px "
              + "\(thumbTime.formatted(.units(allowed: [.milliseconds]))) (\(perFrameThumb.formatted(.units(allowed: [.microseconds]))) each)")
        let portrait = frames.filter { $0.info.isPortrait }
        for frame in portrait {
            let image = try #require(await loader.thumbnail(for: frame, maxPixelSize: 336))
            #expect(image.height > image.width, "\(frame.name)")
        }
    }
}
