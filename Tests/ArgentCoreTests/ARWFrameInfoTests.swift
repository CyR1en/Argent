import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import ArgentCore

@Suite struct ARWFrameInfoTests {
    /// An a7 IV-shaped file: IFD0 with the preview JPEG, the model, orientation and Exif; IFD1
    /// with a thumbnail; IFD2 with a larger JPEG; and the Exif IFD outside the chain.
    private func syntheticARW(orientation: UInt16 = 8) -> Data {
        var builder = TIFFBuilder()
        builder.blobs = [TIFFBuilder.jpeg(width: 96, height: 64), TIFFBuilder.jpeg(width: 24, height: 16),
                         TIFFBuilder.jpeg(width: 192, height: 128)]
        builder.ifds = [
            [(0x00FE, .long([1])), (0x0110, .ascii("ILCE-7M4")), (0x0112, .short([orientation])),
             (0x0201, .blobOffset(0)), (0x0202, .blobLength(0)), (0x8769, .ifdOffset(3))],
            [(0x00FE, .long([1])), (0x0201, .blobOffset(1)), (0x0202, .blobLength(1))],
            [(0x00FE, .long([1])), (0x0201, .blobOffset(2)), (0x0202, .blobLength(2))],
            [(0x829A, .rational([(1, 50)])), (0x829D, .rational([(56, 10)])), (0x8827, .short([250])),
             (0x9003, .ascii("2023:10:19 16:13:48")), (0x9291, .ascii("776")), (0x9011, .ascii("+02:00"))],
        ]
        builder.chain = [0, 1, 2]
        return builder.build()
    }

    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("argent-frame-\(UUID().uuidString).arw")
        try data.write(to: url)
        return url
    }

    @Test func readsThePreviewsOrientationAndExif() throws {
        let url = try write(syntheticARW())
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try ARWFrameInfo.read(from: url)
        #expect(info.model == "ILCE-7M4")
        #expect(info.orientation == .left && info.isPortrait)
        #expect(info.exposureTime == 0.02 && info.fNumber == 5.6 && info.iso == 250)
        #expect(info.captureOffset == "+02:00")
        let expected = ARWFrameInfo.captureDate("2023:10:19 16:13:48", subseconds: "776")
        #expect(info.captureDate == expected)
        let preview = try #require(info.preview)
        let full = try #require(info.fullSizePreview)
        #expect(full.length > preview.length)

        // The preview decodes upright: 96 by 64 stored, orientation 8, so 64 wide by 96 tall.
        let image = try EmbeddedJPEG.image(at: preview, in: url, maxPixelSize: 512, orientation: info.orientation)
        #expect(image.width == 64 && image.height == 96)
        let large = try EmbeddedJPEG.image(at: full, in: url, maxPixelSize: 96, orientation: .up)
        #expect(large.width == 96 && large.height == 64)
    }

    @Test func parsesCaptureTimesWithSubseconds() throws {
        let base = try #require(ARWFrameInfo.captureDate("2023:10:19 16:13:48", subseconds: nil))
        let later = try #require(ARWFrameInfo.captureDate("2023:10:19 16:13:48", subseconds: "776"))
        #expect(abs(later.timeIntervalSince(base) - 0.776) < 1e-6)
        #expect(abs(ARWFrameInfo.captureDate("2023:10:19 16:13:48", subseconds: "05")!.timeIntervalSince(base) - 0.05) < 1e-6)
        #expect(ARWFrameInfo.captureDate("not a date", subseconds: nil) == nil)
        #expect(ARWFrameInfo.captureDate("    :  :     :  :  ", subseconds: nil) == nil)
    }

    @Test func refusesAFileThatIsNotTIFF() throws {
        let url = try write(Data("nope".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try ARWFrameInfo.read(from: url) }
    }

    /// RGBA bytes of an image drawn into a plain 8-bit context.
    private func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    @Test func orientsEveryExifCaseAsCoreImageDoes() throws {
        // A 3 by 2 image with six distinct colours, so every flip and turn is visible.
        var source = [UInt8](repeating: 255, count: 3 * 2 * 4)
        let colours: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), (0, 255, 255), (255, 0, 255)]
        for (i, c) in colours.enumerated() { (source[i * 4], source[i * 4 + 1], source[i * 4 + 2]) = c }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let image = CGContext(data: &source, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        for raw in UInt32(1)...8 {
            let orientation = try #require(CGImagePropertyOrientation(rawValue: raw))
            let ours = EmbeddedJPEG.oriented(image, orientation)
            let reference = CIImage(cgImage: image).oriented(orientation)
            let expected = try #require(context.createCGImage(reference, from: reference.extent))
            #expect(ours.width == expected.width && ours.height == expected.height, "orientation \(raw)")
            #expect(pixels(ours) == pixels(expected), "orientation \(raw)")
        }
    }

    private static let samples = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("samples")
    private static var hasSamples: Bool {
        FileManager.default.fileExists(atPath: samples.appendingPathComponent("ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW").path)
    }

    @Test(.enabled(if: ARWFrameInfoTests.hasSamples))
    func readsTheSamples() throws {
        let url = Self.samples.appendingPathComponent("ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")
        let info = try ARWFrameInfo.read(from: url)
        #expect(info.model == "ILCE-7M4" && info.orientation == .up)
        #expect(info.iso == 250 && info.exposureTime == 0.02 && info.fNumber == 5.6)
        #expect(info.captureDate == ARWFrameInfo.captureDate("2023:10:19 16:13:48", subseconds: "776"))
        let preview = try EmbeddedJPEG.image(at: try #require(info.preview), in: url, maxPixelSize: 4096, orientation: info.orientation)
        #expect(preview.width == 1616 && preview.height == 1080)
        let full = try #require(info.fullSizePreview)
        #expect(full.length > 5_000_000)
    }
}
