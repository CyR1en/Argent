import ArgentCore
import Foundation
import Testing
@testable import ArgentRoll

/// The smart masks' input picture as the frame view hands it over (`FilmPreviews.maskInputPicture`): from the frame view's own
/// decode when that is at least 2560 pixels long, from a decode of its own otherwise, which leaves the frame view's decode as it
/// was; kept for the next mask, counted by the develop's gate and let go by its trim. Runs where the CC0 samples are.
@Suite(.rawDecodes, .serialized) struct MaskInputPreviewTests {
    private static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples")
    private static var hasSamples: Bool {
        FileManager.default.fileExists(atPath: samples.appendingPathComponent("ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW").path)
    }

    @Test(.enabled(if: MaskInputPreviewTests.hasSamples))
    func thePictureComesFromTheFrameViewsDecodeOrADecodeOfItsOwn() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeToyStock(id: "kodak-portra-400", in: directory)
        let stocks = StockLibrary.load(from: directory).stocks
        let frame = try #require(await RollScanner.scan(Self.samples).frames.first { $0.name.contains("DSC06673") })
        let clock = ContinuousClock()

        // A frame view 1504 pixels long, as a small window on the 14-inch display shows it: too small, so a decode of its own.
        let films = try FilmPreviews(stocks: stocks, decoderChoices: DecoderChoices(route: .raw9))
        _ = try #require(await films.frameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: 1504))
        let held = try #require(films.frameDecode(of: frame, lens: .default, pixels: 1504))
        let heldBefore = films.heldBytes
        var start = clock.now
        let own = try #require(await films.maskInputPicture(frame, lens: .default))
        let ownTime = clock.now - start
        #expect((own.width, own.height) == (2560, 1707))
        #expect(max(own.source.decodeWidth, own.source.decodeHeight) >= 2560 && own.source.decoderVersion == "9")
        // The frame view's decode is the one it had.
        #expect(films.frameDecode(of: frame, lens: .default, pixels: 1504)?.texture === held.texture)
        #expect(films.heldBytes == heldBefore + own.byteCount)
        start = clock.now
        let kept = try #require(await films.maskInputPicture(frame, lens: .default))
        let keptTime = clock.now - start
        #expect(kept.digest == own.digest)
        films.trimForDevelop()
        #expect(films.heldBytes == 0)

        // A frame view 4912 pixels long: its own decode.
        let large = try FilmPreviews(stocks: stocks, decoderChoices: DecoderChoices(route: .raw9))
        _ = try #require(await large.frameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: 4912))
        start = clock.now
        let fromView = try #require(await large.maskInputPicture(frame, lens: .default))
        let viewTime = clock.now - start
        #expect((fromView.width, fromView.height) == (2560, 1707))
        #expect((fromView.source.decodeWidth, fromView.source.decodeHeight) == (4912, 3275))
        #expect(fromView.modelContents[756]?.count == 756 * 504 * 3 && fromView.modelContents[768]?.count == 768 * 512 * 3)
        // The two decodes differ, and so do their pictures, by little.
        let differences = own.withPixels { a, _ in fromView.withPixels { b, _ in zip(a, b).map { abs(Int($0) - Int($1)) } } }
        let mean = Double(differences.reduce(0, +)) / Double(differences.count)
        print(String(format: "MEASURE mask input picture: own decode (%d × %d) %.0f ms, kept %.2f ms; from the frame view's 4912 decode %.0f ms; "
                     + "the two pictures differ by %.2f codes on average",
                     own.source.decodeWidth, own.source.decodeHeight, ownTime.seconds * 1000, keptTime.seconds * 1000,
                     viewTime.seconds * 1000, mean))
        #expect(mean < 3)
        large.removeAll()
        #expect(large.heldBytes == 0)
    }
}
