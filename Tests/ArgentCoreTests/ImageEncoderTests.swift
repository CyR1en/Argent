import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
@testable import ArgentCore

/// Runs only where the CC0 sample raws are present.
@Suite struct ImageEncoderSampleTests {
    private static let sample = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")
    private static var hasSample: Bool { FileManager.default.fileExists(atPath: sample.path) }

    private static func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    @Test(.enabled(if: ImageEncoderSampleTests.hasSample),
          arguments: [(OutputFormat.jpeg(quality: 0.92), OutputSpace.sRGB),
                      (OutputFormat.heic(quality: 0.9), OutputSpace.displayP3),
                      (OutputFormat.tiff16, OutputSpace.adobeRGB)])
    func writesEachFormatWithTheRawsMetadata(format: OutputFormat, space: OutputSpace) throws {
        let gpu = try GPU()
        var options = DecodeOptions()
        options.maxLongSide = 900
        let frame = try AppleRawDecoder(gpu: gpu).decode(Self.sample, options: options)
        let encoder = try ImageEncoder(gpu: gpu)
        let picture = try encoder.picture(frame.texture, colorSpace: gpu.workingColorSpace, format: format,
                                          space: space, longEdge: 600)
        #expect(max(picture.width, picture.height) == 600)
        #expect(picture.bitsPerComponent == (format == .tiff16 ? 16 : 8))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("argent-encode-\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try encoder.write(picture, to: url, format: format, metadataFrom: Self.sample, software: "Argent test")

        let written = try Self.properties(url)
        let raw = try Self.properties(Self.sample)
        #expect(written[kCGImagePropertyPixelWidth] as? Int == picture.width)
        #expect(written[kCGImagePropertyOrientation] as? Int ?? 1 == 1)
        #expect(written[kCGImagePropertyDepth] as? Int == (format == .tiff16 ? 16 : 8))
        let profile = written[kCGImagePropertyProfileName] as? String ?? ""
        #expect(profile.contains(space == .sRGB ? "sRGB" : space == .displayP3 ? "P3" : "Adobe RGB"), "\(profile)")

        let exif = try #require(written[kCGImagePropertyExifDictionary] as? [CFString: Any])
        let rawExif = try #require(raw[kCGImagePropertyExifDictionary] as? [CFString: Any])
        for key in [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifLensModel] {
            #expect(exif[key] as? String == rawExif[key] as? String, "\(key)")
            #expect(exif[key] != nil, "\(key)")
        }
        for key in [kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber] {
            let value = try #require(rawExif[key] as? Double, "\(key)")
            #expect(exif[key] as? Double == value, "\(key)")
        }
        let iso = try #require(rawExif[kCGImagePropertyExifISOSpeedRatings] as? [Int])
        #expect(exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] == iso)
        #expect(exif[kCGImagePropertyExifPixelXDimension] as? Int == picture.width)
        let tiff = try #require(written[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        #expect(tiff[kCGImagePropertyTIFFSoftware] as? String == "Argent test")
        #expect(tiff[kCGImagePropertyTIFFModel] as? String == "ILCE-7M4")

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let metadata = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        let creator = CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:CreatorTool" as CFString) as String?
        #expect(creator == "Argent test")
    }

    /// The Develop sheet's quality, 0 to 100, reaches ImageIO as 0 to 1: each step up gives a larger
    /// file that reads back, for HEIC at 1 too, which ImageIO may take as lossless.
    @Test(.enabled(if: ImageEncoderSampleTests.hasSample),
          arguments: [OutputFormat.jpeg(quality: 0), .heic(quality: 0)])
    func higherQualityWritesALargerFileThatReadsBack(format: OutputFormat) throws {
        let gpu = try GPU()
        var options = DecodeOptions()
        options.maxLongSide = 900
        let frame = try AppleRawDecoder(gpu: gpu).decode(Self.sample, options: options)
        let encoder = try ImageEncoder(gpu: gpu)
        var isHEIC = false
        if case .heic = format { isHEIC = true }
        var sizes: [Int] = []
        for quality in [0.0, 0.5, 0.92, 1.0] {
            let at: OutputFormat = isHEIC ? .heic(quality: quality) : .jpeg(quality: quality)
            let picture = try encoder.picture(frame.texture, colorSpace: gpu.workingColorSpace, format: at,
                                              space: .sRGB, longEdge: 600)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("argent-quality-\(UUID().uuidString).\(at.fileExtension)")
            defer { try? FileManager.default.removeItem(at: url) }
            try encoder.write(picture, to: url, format: at, metadataFrom: Self.sample, software: "Argent test")
            let read = try #require(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            #expect(max(read.width, read.height) == 600, "\(quality)")
            sizes.append(try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        }
        #expect(zip(sizes, sizes.dropFirst()).allSatisfy { $0 < $1 }, "\(sizes)")
    }
}

@Suite struct ImageEncoderEdgeTests {
    /// A flat mid-gray texture, so every pixel of a resize should come out the same.
    private func gray(_ gpu: GPU, width: Int, height: Int) throws -> MTLTexture {
        let texture = try gpu.makeTexture(width: width, height: height)
        let pixels = [Float16](repeating: 0.18, count: width * height * 4).enumerated().map { $0.offset % 4 == 3 ? 1 : $0.element }
        pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                                 withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        return texture
    }

    private func rows(_ image: CGImage) throws -> (first: UInt8, middle: UInt8, last: UInt8, lastColumn: UInt8) {
        let data = try #require(image.dataProvider?.data) as Data
        let row = image.bytesPerRow, x = image.width / 2, y = image.height / 2
        return (data[x * 4], data[y * row + x * 4], data[(image.height - 1) * row + x * 4], data[y * row + (image.width - 1) * 4])
    }

    /// A long-edge resize rarely lands on whole pixels; the edge rows must not come out dark.
    @Test func aResizeKeepsItsEdgeRowsAndColumns() throws {
        let gpu = try GPU()
        let encoder = try ImageEncoder(gpu: gpu)
        let picture = try encoder.picture(try gray(gpu, width: 701, height: 467), colorSpace: gpu.workingColorSpace,
                                          format: .jpeg(quality: 0.9), longEdge: 409)
        let values = try rows(picture)
        print("MEASURE resize to \(picture.width)x\(picture.height): first row \(values.first), middle \(values.middle), last row \(values.last), last column \(values.lastColumn)")
        #expect(picture.width == 409)
        #expect(abs(Int(values.last) - Int(values.middle)) <= 1)
        #expect(abs(Int(values.lastColumn) - Int(values.middle)) <= 1)
        #expect(abs(Int(values.first) - Int(values.middle)) <= 1)
    }

    /// A JPEG's and a HEIC's picture go through an IOSurface (docs/M3-auto.md section 15,
    /// docs/M2-shell.md section 10): the same pixels, the same way up, as the 16-bit picture made
    /// in memory for TIFF, in every output space.
    @Test(arguments: OutputSpace.allCases)
    func theJPEGPictureIsThePicture(space: OutputSpace) throws {
        let gpu = try GPU()
        let encoder = try ImageEncoder(gpu: gpu)
        let width = 96, height = 64
        let texture = try gpu.makeTexture(width: width, height: height)
        var pixels = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            pixels[i] = Float16(Float(x) / Float(width)); pixels[i + 1] = Float16(Float(y) / Float(height)); pixels[i + 2] = 0.05
        } }
        pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                                 withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        func drawn(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: space.colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return data
        }
        let jpeg = try encoder.picture(texture, colorSpace: gpu.workingColorSpace, format: .jpeg(quality: 0.92), space: space)
        let heic = try encoder.picture(texture, colorSpace: gpu.workingColorSpace, format: .heic(quality: 0.9), space: space)
        let tiff = try encoder.picture(texture, colorSpace: gpu.workingColorSpace, format: .tiff16, space: space)
        #expect(jpeg.width == width && jpeg.height == height && jpeg.colorSpace?.name == space.colorSpace.name)
        #expect(heic.width == width && heic.height == height && heic.colorSpace?.name == space.colorSpace.name)
        let a = drawn(jpeg), b = drawn(tiff)
        let worst = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 1, "largest difference \(worst)")
        #expect(drawn(heic) == a)
        // The red ramp runs left to right and the green one down the texture's rows.
        #expect(a[(width - 1) * 4] > a[0] + 100)
    }

    /// 16-bit TIFF is written uncompressed (docs/M2-shell.md section 5).
    @Test func sixteenBitTIFFIsUncompressed() throws {
        let gpu = try GPU()
        let encoder = try ImageEncoder(gpu: gpu)
        let picture = try encoder.picture(try gray(gpu, width: 64, height: 48), colorSpace: gpu.workingColorSpace, format: .tiff16)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("argent-tiff-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: url) }
        try encoder.write(picture, to: url, format: .tiff16, metadataFrom: nil)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let tiff = try #require(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        print("MEASURE 64x48 16-bit TIFF: compression \(tiff[kCGImagePropertyTIFFCompression] ?? "none"), \(size) bytes")
        #expect(tiff[kCGImagePropertyTIFFCompression] as? Int == 1)
    }
}
