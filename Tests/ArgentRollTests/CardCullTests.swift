import ArgentCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ArgentRoll

@Suite struct CardCullTests {
    @Test func scoresEveryFrameAndLeavesATruncatedOneUnscored() async throws {
        let card = try Self.card(frames: 4, truncating: 2)
        defer { try? FileManager.default.removeItem(at: card) }
        let reports = Reports()
        let cull = try await CardCull.run(folder: card) { scored, total in reports.add(scored, total) }

        #expect(cull.frames.map(\.path) == (1...4).map { String(format: "DCIM/100MSDCF/DSC%05d.ARW", $0) })
        #expect(cull.verdicts.map(\.path) == cull.frames.map(\.path))
        #expect(cull.frames.map { $0.captureDate != nil } == [true, true, true, true])
        #expect(cull.frames.map { $0.scores?.featurePrint.count } == [768, nil, 768, 768])
        #expect(cull.verdicts[1].keep)
        #expect(reports.all.map(\.scored) == [0, 1, 2, 3, 4] && reports.all.allSatisfy { $0.total == 4 })
    }

    @Test func cancellingStopsBeforeTheLastFrame() async throws {
        let frames = 2 * CardCull.lanes + 2
        let card = try Self.card(frames: frames)
        defer { try? FileManager.default.removeItem(at: card) }
        let reports = Reports(), canceller = Canceller()
        canceller.hold(Task {
            try await CardCull.run(folder: card) { scored, total in
                reports.add(scored, total)
                if scored == 1 { canceller.cancel() }
            }
        })
        await #expect(throws: CancellationError.self) { try await canceller.task?.value }
        #expect(reports.all.map(\.scored) == [0, 1])
    }

    @Test func aRawRemovedAfterItIsScoredEndsTheCullWithAnError() async throws {
        let card = try Self.card(frames: 1)
        defer { try? FileManager.default.removeItem(at: card) }
        let raw = try #require(RollScanner.rawFiles(in: card).first)
        await #expect(throws: CardCull.Failure.rawGone(raw)) {
            try await CardCull.run(folder: card) { scored, _ in
                if scored == 1 { try? FileManager.default.removeItem(at: raw) }
            }
        }
    }

    @Test func aRawRemovedBeforeItIsScoredIsNotCounted() async throws {
        let card = try Self.card(frames: 1)
        defer { try? FileManager.default.removeItem(at: card) }
        let raw = try #require(RollScanner.rawFiles(in: card).first)
        let reports = Reports()
        await #expect(throws: CardCull.Failure.rawGone(raw)) {
            try await CardCull.run(folder: card) { scored, total in
                reports.add(scored, total)
                if scored == 0 { try? FileManager.default.removeItem(at: raw) }
            }
        }
        #expect(reports.all.map(\.scored) == [0])
    }

    @Test func anUnreadableFolderIsAnError() async throws {
        let card = try Self.card(frames: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: card.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: card.path)
            try? FileManager.default.removeItem(at: card)
        }
        await #expect(throws: CardCull.Failure.unreadable(card)) { try await CardCull.run(folder: card) }
    }

    @Test func aCardThatGoesAwayEndsTheCullWithAnError() async throws {
        let card = try Self.card(frames: 2 * CardCull.lanes + 2)
        defer { try? FileManager.default.removeItem(at: card) }
        let error = await #expect(throws: CardCull.Failure.self) {
            try await CardCull.run(folder: card) { scored, _ in
                if scored == 1 { try? FileManager.default.removeItem(at: card) }
            }
        }
        guard case .rawGone(let raw)? = error else { Issue.record("no rawGone: \(String(describing: error))"); return }
        #expect(raw.pathExtension == "ARW")
        await #expect(throws: CardCull.Failure.noFolder(card)) { try await CardCull.run(folder: card) }
    }

    static func card(frames: Int, truncating: Int? = nil) throws -> URL {
        let card = try temporaryFolder()
        let dcim = card.appendingPathComponent("DCIM/100MSDCF")
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        for number in 1...frames {
            let bytes = headerOnlyARW(captured: String(format: "2026:11:11 10:%02d:%02d", number / 60, number % 60),
                                      shade: Double(number) / Double(frames), truncated: number == truncating)
            try Data(bytes).write(to: dcim.appendingPathComponent(String(format: "DSC%05d.ARW", number)))
        }
        return card
    }

    static func headerOnlyARW(captured: String, shade: Double, truncated: Bool) -> [UInt8] {
        let width = 160, height = 120
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: shade, green: 0.5, blue: 1 - shade, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 1, blue: 0.9, alpha: 1)
        context.fillEllipse(in: CGRect(x: 50, y: 30, width: 60, height: 60))
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
            + date + (date.count % 2 == 1 ? [0] : []) + (truncated ? Array(jpeg.prefix(jpeg.count / 2)) : jpeg)
    }
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [(scored: Int, total: Int)] = []
    func add(_ scored: Int, _ total: Int) { lock.withLock { counts.append((scored, total)) } }
    var all: [(scored: Int, total: Int)] { lock.withLock { counts } }
}

private final class Canceller: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Task<CardCull, Error>?
    private var cancelRequested = false
    func hold(_ task: Task<CardCull, Error>) { lock.withLock { held = task; if cancelRequested { task.cancel() } } }
    func cancel() { lock.withLock { cancelRequested = true; held?.cancel() } }
    var task: Task<CardCull, Error>? { lock.withLock { held } }
}
