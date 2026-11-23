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
        for key in [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifSubsecTimeOriginal, kCGImagePropertyExifLensModel] {
            #expect(exif[key] as? String == rawExif[key] as? String, "\(key)")
            #expect(exif[key] != nil, "\(key)")
        }
        for key in [kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber] {
            let value = try #require(rawExif[key] as? Double, "\(key)")
            #expect(exif[key] as? Double == value, "\(key)")
        }
        let iso = try #require(rawExif[kCGImagePropertyExifISOSpeedRatings] as? [Int])
        #expect(exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] == iso)
        let lensSpec = try #require(rawExif[kCGImagePropertyExifLensSpecification] as? [Double])
        #expect(exif[kCGImagePropertyExifLensSpecification] as? [Double] == lensSpec)
        #expect(exif[kCGImagePropertyExifPixelXDimension] as? Int == picture.width)
        #expect(exif[kCGImagePropertyExifPixelYDimension] as? Int == picture.height)
        let tiff = try #require(written[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        let rawTIFF = try #require(raw[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        #expect(tiff[kCGImagePropertyTIFFSoftware] as? String == "Argent test")
        #expect(tiff[kCGImagePropertyTIFFMake] as? String == rawTIFF[kCGImagePropertyTIFFMake] as? String)
        #expect(tiff[kCGImagePropertyTIFFModel] as? String == "ILCE-7M4")

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        let metadata = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        let creator = CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:CreatorTool" as CFString) as String?
        #expect(creator == "Argent test")
        let rating = CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:Rating" as CFString) as String?
        #expect(rating == "0")
    }

    /// Checks the bytes written to disk against the raw's own TIFF Exif IFD: Apple's ARW reader
    /// drops `OffsetTime*` and rewrites `aux:Lens`, so JPEG's APP1 Exif block and TIFF's IFDs are
    /// parsed directly with `TIFFReader` rather than trusting ImageIO's reading of the raw.
    @Test(.enabled(if: ImageEncoderSampleTests.hasSample),
          arguments: [OutputFormat.jpeg(quality: 0.92), .heic(quality: 0.9), .tiff16])
    func writesTheRawsExifOffsetsAndLensNameOnDisk(format: OutputFormat) throws {
        let tags: [UInt16] = [0x9010, 0x9011, 0x9012, 0xA434]
        let rawOnDisk = try ExifBytes.readTIFF(Self.sample, tags: tags).tags
        let offsetTime = try #require(rawOnDisk[0x9010])
        let offsetOriginal = try #require(rawOnDisk[0x9011])
        let offsetDigitized = try #require(rawOnDisk[0x9012])
        let rawLens = try #require(rawOnDisk[0xA434])
        #expect(!rawLens.isEmpty)

        // Confirm ImageIO's own reading of the raw drops the offsets and rewrites `aux:Lens`.
        let rawImageSource = try #require(CGImageSourceCreateWithURL(Self.sample as CFURL, nil))
        let rawProps = try #require(CGImageSourceCopyPropertiesAtIndex(rawImageSource, 0, nil) as? [CFString: Any])
        let rawExifProps = try #require(rawProps[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(rawExifProps[kCGImagePropertyExifOffsetTimeOriginal] == nil)
        let rawMeta = try #require(CGImageSourceCopyMetadataAtIndex(rawImageSource, 0, nil))
        let rawAuxLens = CGImageMetadataCopyStringValueWithPath(rawMeta, nil, "aux:Lens" as CFString) as String?
        #expect(rawAuxLens != rawLens)

        let gpu = try GPU()
        var options = DecodeOptions()
        options.maxLongSide = 900
        let frame = try AppleRawDecoder(gpu: gpu).decode(Self.sample, options: options)
        let encoder = try ImageEncoder(gpu: gpu)
        let picture = try encoder.picture(frame.texture, colorSpace: gpu.workingColorSpace, format: format,
                                          space: .sRGB, longEdge: 600)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("argent-exif-disk-\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try encoder.write(picture, to: url, format: format, metadataFrom: Self.sample, software: "Argent test")

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 1)

        switch format {
        case .jpeg:
            let onDisk = try ExifBytes.readJPEG(url, tags: tags)
            #expect(onDisk.tags[0x9010] == offsetTime)
            #expect(onDisk.tags[0x9011] == offsetOriginal)
            #expect(onDisk.tags[0x9012] == offsetDigitized)
            #expect(onDisk.tags[0xA434] == rawLens)
        case .tiff16:
            let onDisk = try ExifBytes.readTIFF(url, tags: tags)
            #expect(onDisk.nextIFDOffset == 0)
            #expect(onDisk.tags[0x9010] == offsetTime)
            #expect(onDisk.tags[0x9011] == offsetOriginal)
            #expect(onDisk.tags[0x9012] == offsetDigitized)
            #expect(onDisk.tags[0xA434] == rawLens)
        case .heic:
            break
        }

        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let exif = try #require(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifOffsetTime] as? String == offsetTime)
        #expect(exif[kCGImagePropertyExifOffsetTimeOriginal] as? String == offsetOriginal)
        #expect(exif[kCGImagePropertyExifOffsetTimeDigitized] as? String == offsetDigitized)
        #expect(exif[kCGImagePropertyExifLensModel] as? String == rawLens)

        let aux = try #require(props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any])
        #expect(aux[kCGImagePropertyExifAuxLensModel] as? String == rawLens)

        let metadata = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        #expect(CGImageMetadataCopyStringValueWithPath(metadata, nil, "aux:Lens" as CFString) as String? == rawLens)
        #expect(CGImageMetadataCopyStringValueWithPath(metadata, nil, "exifEX:LensModel" as CFString) as String? == rawLens)
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

@Suite struct ImageEncoderMetadataTests {
    private static let allFormats: [OutputFormat] = [
        .jpeg(quality: 0.92),
        .heic(quality: 0.9),
        .tiff16,
    ]

    private func solidPicture(_ gpu: GPU, encoder: ImageEncoder, format: OutputFormat,
                              width: Int = 64, height: Int = 48) throws -> CGImage {
        let texture = try gpu.makeTexture(width: width, height: height)
        let pixels = [Float16](repeating: 0.18, count: width * height * 4)
            .enumerated().map { $0.offset % 4 == 3 ? 1 : $0.element }
        pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        return try encoder.picture(texture, colorSpace: gpu.workingColorSpace, format: format)
    }

    private func smallImage(width: Int = 32, height: Int = 24) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func temporaryURL(prefix: String, ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString).\(ext)")
    }

    /// A differing EXIF `LensModel` (for instance a third-party lens whose Sony lens ID maps to a
    /// Sony lens in ImageIO's `aux:Lens` lookup) replaces `aux:Lens` in every output format.
    @Test(arguments: ImageEncoderMetadataTests.allFormats)
    func differingExifLensModelReplacesAuxLensInEachFormat(format: OutputFormat) throws {
        let sourceURL = temporaryURL(prefix: "argent-lens-src", ext: "jpg")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let sourceMeta = CGImageMetadataCreateMutable()
        _ = CGImageMetadataSetValueWithPath(sourceMeta, nil, "aux:Lens" as CFString, "Sony FE 50mm F1.4" as CFString)
        _ = CGImageMetadataSetValueMatchingImageProperty(sourceMeta, kCGImagePropertyExifDictionary,
                                                         kCGImagePropertyExifLensModel, "Viltrox 50mm F1.4 FE" as CFString)
        let sourceDest = try #require(CGImageDestinationCreateWithURL(sourceURL as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(sourceDest, try smallImage(), sourceMeta, nil)
        #expect(CGImageDestinationFinalize(sourceDest))
        let srcMeta = try #require(CGImageSourceCreateWithURL(sourceURL as CFURL, nil)
            .flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) })
        #expect(CGImageMetadataCopyStringValueWithPath(srcMeta, nil, "aux:Lens" as CFString) as String? == "Sony FE 50mm F1.4")

        let gpu = try GPU(), encoder = try ImageEncoder(gpu: gpu)
        let picture = try solidPicture(gpu, encoder: encoder, format: format)
        let outURL = temporaryURL(prefix: "argent-lens-out", ext: format.fileExtension)
        defer { try? FileManager.default.removeItem(at: outURL) }
        try encoder.write(picture, to: outURL, format: format, metadataFrom: sourceURL,
                          software: "Argent test", rawExif: .init(lensModel: "Viltrox 50mm F1.4 FE"))

        let readSource = try #require(CGImageSourceCreateWithURL(outURL as CFURL, nil))
        #expect(CGImageSourceGetCount(readSource) == 1)
        let readMeta = try #require(CGImageSourceCopyMetadataAtIndex(readSource, 0, nil))
        let auxLens = CGImageMetadataCopyStringValueWithPath(readMeta, nil, "aux:Lens" as CFString) as String?
        #expect(auxLens == "Viltrox 50mm F1.4 FE")
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(readSource, 0, nil) as? [CFString: Any])
        let aux = try #require(props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any])
        #expect(aux[kCGImagePropertyExifAuxLensModel] as? String == "Viltrox 50mm F1.4 FE")
        let exif = try #require(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifLensModel] as? String == "Viltrox 50mm F1.4 FE")
    }

    @Test func applyReplacesAuxLensOnlyWhenLensModelIsNonEmpty() {
        for empty in [nil, "", "   "] {
            let meta = CGImageMetadataCreateMutable()
            _ = CGImageMetadataSetValueWithPath(meta, nil, "aux:Lens" as CFString, "Sony FE 50mm F1.4" as CFString)
            ImageEncoder.apply(.init(lensModel: empty), to: meta)
            let lens = CGImageMetadataCopyStringValueWithPath(meta, nil, "aux:Lens" as CFString) as String?
            #expect(lens == "Sony FE 50mm F1.4")
        }
        let meta = CGImageMetadataCreateMutable()
        _ = CGImageMetadataSetValueWithPath(meta, nil, "aux:Lens" as CFString, "Sony FE 50mm F1.4" as CFString)
        ImageEncoder.apply(.init(lensModel: "Viltrox 50mm F1.4 FE"), to: meta)
        let lens = CGImageMetadataCopyStringValueWithPath(meta, nil, "aux:Lens" as CFString) as String?
        #expect(lens == "Viltrox 50mm F1.4 FE")
    }

    @Test func validOffsetAcceptsWellFormedAndRejectsMalformed() {
        for good in ["+00:00", "-00:00", "+02:00", "-07:00", "+05:30", "+05:45", "-12:00", "+14:00", "+23:59", "-23:59"] {
            #expect(ImageEncoder.validOffset(good) == good, "\(good)")
        }
        for bad in ["", "   :  ", "+  :  ", "-  :  ", "Z", "+0200", "+2:00", "+02:0", "+02:00:00",
                    "02:00", "+24:00", "-24:00", "+02:60", "+99:99", "UTC+2", "+02:00 ", "+٠٢:٠٠"] {
            #expect(ImageEncoder.validOffset(bad) == nil, "\(bad)")
        }
    }

    /// Only offsets present and well formed in the raw's Exif IFD are written; absent or malformed
    /// offsets are never invented.
    @Test(arguments: ImageEncoderMetadataTests.allFormats)
    func onlyPresentWellFormedOffsetsAreCarried(format: OutputFormat) throws {
        var builder = TIFFBuilder()
        builder.chain = [0]
        builder.ifds = [
            [(0x0110, .ascii("ILCE-7M4")), (0x8769, .ifdOffset(1))],
            [(0x9010, .ascii("   :  ")), (0x9011, .ascii("-07:00")), (0xA434, .ascii("Viltrox 50mm F1.4 FE"))],
        ]
        let tiffURL = temporaryURL(prefix: "argent-partial-offset", ext: "arw")
        try builder.build().write(to: tiffURL)
        defer { try? FileManager.default.removeItem(at: tiffURL) }

        let parsed = ImageEncoder.readRawExif(from: tiffURL)
        #expect(parsed == ImageEncoder.RawExif(offsetTime: nil, offsetTimeOriginal: "-07:00",
                                               offsetTimeDigitized: nil, lensModel: "Viltrox 50mm F1.4 FE"))

        let gpu = try GPU(), encoder = try ImageEncoder(gpu: gpu)
        let picture = try solidPicture(gpu, encoder: encoder, format: format)
        let outURL = temporaryURL(prefix: "argent-partial-out", ext: format.fileExtension)
        defer { try? FileManager.default.removeItem(at: outURL) }
        try encoder.write(picture, to: outURL, format: format, metadataFrom: tiffURL, software: "Argent test")

        let readSource = try #require(CGImageSourceCreateWithURL(outURL as CFURL, nil))
        #expect(CGImageSourceGetCount(readSource) == 1)
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(readSource, 0, nil) as? [CFString: Any])
        let exif = try #require(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifOffsetTime] == nil)
        #expect(exif[kCGImagePropertyExifOffsetTimeOriginal] as? String == "-07:00")
        #expect(exif[kCGImagePropertyExifOffsetTimeDigitized] == nil)

        let readMeta = try #require(CGImageSourceCopyMetadataAtIndex(readSource, 0, nil))
        #expect(CGImageMetadataCopyStringValueWithPath(readMeta, nil, "aux:Lens" as CFString) as String? == "Viltrox 50mm F1.4 FE")

        switch format {
        case .jpeg:
            let onDisk = try ExifBytes.readJPEG(outURL, tags: [0x9010, 0x9011, 0x9012])
            #expect(onDisk.tags[0x9010] == nil)
            #expect(onDisk.tags[0x9011] == "-07:00")
            #expect(onDisk.tags[0x9012] == nil)
        case .tiff16:
            let onDisk = try ExifBytes.readTIFF(outURL, tags: [0x9010, 0x9011, 0x9012])
            #expect(onDisk.nextIFDOffset == 0)
            #expect(onDisk.tags[0x9010] == nil)
            #expect(onDisk.tags[0x9011] == "-07:00")
            #expect(onDisk.tags[0x9012] == nil)
        case .heic:
            break
        }
    }

    /// An offset the raw padded with spaces is the offset it says: read without the padding, as every TIFF string is, and
    /// carried so. `validOffset` itself takes only the six characters, so nothing padded is ever written.
    @Test func aPaddedOffsetIsCarriedWithoutItsPadding() throws {
        var builder = TIFFBuilder()
        builder.chain = [0]
        builder.ifds = [
            [(0x0110, .ascii("ILCE-7M4")), (0x8769, .ifdOffset(1))],
            [(0x9010, .ascii("+02:00 ")), (0x9011, .ascii(" -07:00")), (0x9012, .ascii("+02:00 x"))],
        ]
        let tiffURL = temporaryURL(prefix: "argent-padded-offset", ext: "arw")
        try builder.build().write(to: tiffURL)
        defer { try? FileManager.default.removeItem(at: tiffURL) }

        #expect(ImageEncoder.readRawExif(from: tiffURL) == ImageEncoder.RawExif(
            offsetTime: "+02:00", offsetTimeOriginal: "-07:00", offsetTimeDigitized: nil, lensModel: nil))
    }

    /// Each of the three offset tags maps to its own EXIF tag without crossing wires.
    @Test(arguments: ImageEncoderMetadataTests.allFormats)
    func threeDistinctOffsetsMapToTheirOwnExifTags(format: OutputFormat) throws {
        var builder = TIFFBuilder()
        builder.chain = [0]
        builder.ifds = [
            [(0x0110, .ascii("ILCE-7M4")), (0x8769, .ifdOffset(1))],
            [(0x9010, .ascii("+01:00")), (0x9011, .ascii("-05:00")), (0x9012, .ascii("+09:30"))],
        ]
        let tiffURL = temporaryURL(prefix: "argent-distinct-offsets", ext: "arw")
        try builder.build().write(to: tiffURL)
        defer { try? FileManager.default.removeItem(at: tiffURL) }

        let gpu = try GPU(), encoder = try ImageEncoder(gpu: gpu)
        let picture = try solidPicture(gpu, encoder: encoder, format: format)
        let outURL = temporaryURL(prefix: "argent-distinct-out", ext: format.fileExtension)
        defer { try? FileManager.default.removeItem(at: outURL) }
        try encoder.write(picture, to: outURL, format: format, metadataFrom: tiffURL)

        let readSource = try #require(CGImageSourceCreateWithURL(outURL as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(readSource, 0, nil) as? [CFString: Any])
        let exif = try #require(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifOffsetTime] as? String == "+01:00")
        #expect(exif[kCGImagePropertyExifOffsetTimeOriginal] as? String == "-05:00")
        #expect(exif[kCGImagePropertyExifOffsetTimeDigitized] as? String == "+09:30")

        switch format {
        case .jpeg:
            let onDisk = try ExifBytes.readJPEG(outURL, tags: [0x9010, 0x9011, 0x9012])
            #expect(onDisk.tags == [0x9010: "+01:00", 0x9011: "-05:00", 0x9012: "+09:30"])
        case .tiff16:
            let onDisk = try ExifBytes.readTIFF(outURL, tags: [0x9010, 0x9011, 0x9012])
            #expect(onDisk.tags == [0x9010: "+01:00", 0x9011: "-05:00", 0x9012: "+09:30"])
        case .heic:
            break
        }
    }

    /// None of the sample raws carry GPS, so verify latitude and longitude survive through a
    /// synthetic GPS-tagged source in all three output formats.
    @Test(arguments: ImageEncoderMetadataTests.allFormats)
    func gpsSurvivesInEachFormat(format: OutputFormat) throws {
        let sourceURL = temporaryURL(prefix: "argent-gps-src", ext: "jpg")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let sourceDest = try #require(CGImageDestinationCreateWithURL(sourceURL as CFURL, "public.jpeg" as CFString, 1, nil))
        let gpsProperties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.7749,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.4194,
                kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSAltitude: 16.5,
                kCGImagePropertyGPSAltitudeRef: 0,
            ] as [CFString: Any],
        ]
        CGImageDestinationAddImage(sourceDest, try smallImage(), gpsProperties as CFDictionary)
        #expect(CGImageDestinationFinalize(sourceDest))

        let gpu = try GPU(), encoder = try ImageEncoder(gpu: gpu)
        let picture = try solidPicture(gpu, encoder: encoder, format: format)
        let outURL = temporaryURL(prefix: "argent-gps-out", ext: format.fileExtension)
        defer { try? FileManager.default.removeItem(at: outURL) }
        try encoder.write(picture, to: outURL, format: format, metadataFrom: sourceURL, software: "Argent test")

        let readSource = try #require(CGImageSourceCreateWithURL(outURL as CFURL, nil))
        #expect(CGImageSourceGetCount(readSource) == 1)
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(readSource, 0, nil) as? [CFString: Any])
        let gps = try #require(props[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        let latitude = try #require(gps[kCGImagePropertyGPSLatitude] as? Double)
        let longitude = try #require(gps[kCGImagePropertyGPSLongitude] as? Double)
        let altitude = try #require(gps[kCGImagePropertyGPSAltitude] as? Double)
        #expect(abs(latitude - 37.7749) < 1e-6)
        #expect(gps[kCGImagePropertyGPSLatitudeRef] as? String == "N")
        #expect(abs(longitude - 122.4194) < 1e-6)
        #expect(gps[kCGImagePropertyGPSLongitudeRef] as? String == "W")
        #expect(abs(altitude - 16.5) < 1e-3)
        #expect(gps[kCGImagePropertyGPSAltitudeRef] as? Int == 0)
    }

    /// A nil, missing, unreadable, non-ARW, tag-less or malformed source never fails an encode and
    /// produces the baseline metadata without inventing offsets or a lens name.
    @Test(arguments: ImageEncoderMetadataTests.allFormats)
    func fallbacksSucceedWithoutInventingOffsetsOrLens(format: OutputFormat) throws {
        let missingURL = temporaryURL(prefix: "argent-missing", ext: "arw")
        let directoryURL = temporaryURL(prefix: "argent-dir", ext: "d")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let textURL = temporaryURL(prefix: "argent-text", ext: "txt")
        try Data("not an image".utf8).write(to: textURL)
        defer { try? FileManager.default.removeItem(at: textURL) }

        let plainJPEGURL = temporaryURL(prefix: "argent-plain", ext: "jpg")
        defer { try? FileManager.default.removeItem(at: plainJPEGURL) }
        let jpegDest = try #require(CGImageDestinationCreateWithURL(plainJPEGURL as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(jpegDest, try smallImage(), [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:06:15 10:20:30"]
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(jpegDest))

        var noExifBuilder = TIFFBuilder()
        noExifBuilder.chain = [0]
        noExifBuilder.ifds = [[(0x0110, .ascii("ILCE-7M4"))]]
        let noExifURL = temporaryURL(prefix: "argent-no-exif", ext: "arw")
        try noExifBuilder.build().write(to: noExifURL)
        defer { try? FileManager.default.removeItem(at: noExifURL) }

        var emptyExifBuilder = TIFFBuilder()
        emptyExifBuilder.chain = [0]
        emptyExifBuilder.ifds = [[(0x8769, .ifdOffset(1))], [(0x8827, .short([100]))]]
        let emptyExifURL = temporaryURL(prefix: "argent-empty-exif", ext: "arw")
        try emptyExifBuilder.build().write(to: emptyExifURL)
        defer { try? FileManager.default.removeItem(at: emptyExifURL) }

        var negativeExifBuilder = TIFFBuilder()
        negativeExifBuilder.chain = [0]
        negativeExifBuilder.ifds = [[(0x8769, .signedShort([-1]))]]
        let negativeExifURL = temporaryURL(prefix: "argent-neg-exif", ext: "arw")
        try negativeExifBuilder.build().write(to: negativeExifURL)
        defer { try? FileManager.default.removeItem(at: negativeExifURL) }

        let truncatedURL = temporaryURL(prefix: "argent-trunc", ext: "arw")
        try Data([0x49, 0x49, 0x2A, 0x00, 0xFF, 0x00, 0x00, 0x00]).write(to: truncatedURL)
        defer { try? FileManager.default.removeItem(at: truncatedURL) }

        let gpu = try GPU(), encoder = try ImageEncoder(gpu: gpu)
        let picture = try solidPicture(gpu, encoder: encoder, format: format)

        let cases: [(label: String, url: URL?, expectsDate: String?)] = [
            ("nil", nil, nil),
            ("missing", missingURL, nil),
            ("directory", directoryURL, nil),
            ("plain text", textURL, nil),
            ("plain JPEG", plainJPEGURL, "2024:06:15 10:20:30"),
            ("TIFF without Exif IFD", noExifURL, nil),
            ("TIFF without offset or lens tags", emptyExifURL, nil),
            ("TIFF with negative Exif offset", negativeExifURL, nil),
            ("truncated TIFF", truncatedURL, nil),
        ]

        for entry in cases {
            if let url = entry.url {
                #expect(ImageEncoder.readRawExif(from: url) == ImageEncoder.RawExif(), "\(entry.label)")
            }
            let outURL = temporaryURL(prefix: "argent-fallback-out", ext: format.fileExtension)
            defer { try? FileManager.default.removeItem(at: outURL) }
            try encoder.write(picture, to: outURL, format: format, metadataFrom: entry.url, software: "Argent test")

            let readSource = try #require(CGImageSourceCreateWithURL(outURL as CFURL, nil), "\(entry.label)")
            #expect(CGImageSourceGetCount(readSource) == 1, "\(entry.label)")
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(readSource, 0, nil) as? [CFString: Any], "\(entry.label)")
            #expect(props[kCGImagePropertyOrientation] as? Int ?? 1 == 1, "\(entry.label)")
            let tiff = try #require(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any], "\(entry.label)")
            #expect(tiff[kCGImagePropertyTIFFSoftware] as? String == "Argent test", "\(entry.label)")
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            #expect(exif?[kCGImagePropertyExifPixelXDimension] as? Int == picture.width, "\(entry.label)")
            #expect(exif?[kCGImagePropertyExifPixelYDimension] as? Int == picture.height, "\(entry.label)")
            #expect(exif?[kCGImagePropertyExifOffsetTime] == nil, "\(entry.label)")
            #expect(exif?[kCGImagePropertyExifOffsetTimeOriginal] == nil, "\(entry.label)")
            #expect(exif?[kCGImagePropertyExifOffsetTimeDigitized] == nil, "\(entry.label)")
            if let expectedDate = entry.expectsDate {
                #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == expectedDate, "\(entry.label)")
            }
            let meta = try #require(CGImageSourceCopyMetadataAtIndex(readSource, 0, nil), "\(entry.label)")
            #expect(CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:CreatorTool" as CFString) as String? == "Argent test", "\(entry.label)")
            #expect(CGImageMetadataCopyStringValueWithPath(meta, nil, "aux:Lens" as CFString) == nil, "\(entry.label)")
        }
    }

    /// A malformed tag (wrong type, oversized count or out-of-bounds offset) is skipped without
    /// hiding valid sibling tags in the same Exif IFD.
    @Test func malformedTagsInExifIFDDoNotHideValidSiblings() throws {
        var builder = TIFFBuilder()
        builder.chain = [0]
        builder.ifds = [
            [(0x8769, .ifdOffset(1))],
            [(0x9010, .short([42])), (0x9011, .ascii("+05:30")), (0x9012, .ascii("+05:30")), (0xA434, .ascii("Sigma 35mm F1.4"))],
        ]
        var data = builder.build()
        // Corrupt tag 0x9012's ASCII count to an absurd value past EOF.
        let ifd0Offset = 8
        let exifOffset = (0..<4).reduce(0) { $0 | Int(data[ifd0Offset + 2 + 8 + $1]) << (8 * $1) }
        let exifCount = Int(data[exifOffset]) | Int(data[exifOffset + 1]) << 8
        for i in 0..<exifCount {
            let at = exifOffset + 2 + i * 12
            let tag = UInt16(data[at]) | UInt16(data[at + 1]) << 8
            if tag == 0x9012 {
                data[at + 4] = 0xFF; data[at + 5] = 0xFF; data[at + 6] = 0xFF; data[at + 7] = 0x7F
            }
        }
        let url = temporaryURL(prefix: "argent-mixed-exif", ext: "arw")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let parsed = ImageEncoder.readRawExif(from: url)
        #expect(parsed == ImageEncoder.RawExif(offsetTime: nil, offsetTimeOriginal: "+05:30",
                                               offsetTimeDigitized: nil, lensModel: "Sigma 35mm F1.4"))
    }
}

private enum ExifBytes {
    /// Extracts the standalone TIFF byte stream inside a JPEG's APP1 `Exif\0\0` segment.
    static func jpegExifTIFF(_ url: URL) throws -> Data? {
        let data = try Data(contentsOf: url)
        guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else { return nil }
        var index = 2
        while index + 1 < data.count {
            guard data[index] == 0xFF else { break }
            while index < data.count && data[index] == 0xFF { index += 1 }
            guard index < data.count else { break }
            let marker = data[index]
            index += 1
            if marker == 0xDA || marker == 0xD9 { break }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }
            guard index + 1 < data.count else { break }
            let length = Int(data[index]) << 8 | Int(data[index + 1])
            guard length >= 2, index + length <= data.count else { break }
            let payload = data[(index + 2)..<(index + length)]
            if marker == 0xE1, payload.count > 6, payload.prefix(6) == Data("Exif\0\0".utf8) {
                return Data(payload.dropFirst(6))
            }
            index += length
        }
        return nil
    }

    /// Reads ASCII tags from a TIFF file's Exif IFD (0x8769) using `TIFFReader`, together with
    /// IFD0's next-IFD pointer (0 when there is only one top-level image).
    static func readTIFF(_ url: URL, tags: [UInt16]) throws -> (tags: [UInt16: String], nextIFDOffset: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let reader = try TIFFReader(handle: handle)
        let ifd0 = try reader.readIFD(at: reader.firstIFDOffset)
        let nextIFD = try reader.nextIFDOffset(after: reader.firstIFDOffset)
        let exifPointer = try #require(ifd0[0x8769], "missing Exif IFD pointer (0x8769)")
        let exifOffset = try #require(try reader.integers(exifPointer).first)
        let exif = try reader.readIFD(at: exifOffset)
        var values: [UInt16: String] = [:]
        for tag in tags {
            if let entry = exif[tag] {
                #expect(entry.type == 2, "tag 0x\(String(tag, radix: 16)) is not ASCII (type \(entry.type))")
                values[tag] = try reader.string(entry)
            }
        }
        return (values, nextIFD)
    }

    /// Reads ASCII tags from a JPEG's APP1 Exif IFD using `TIFFReader`.
    static func readJPEG(_ url: URL, tags: [UInt16]) throws -> (tags: [UInt16: String], nextIFDOffset: Int) {
        let tiffBytes = try #require(try jpegExifTIFF(url), "JPEG has no APP1 Exif segment")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("argent-exif-\(UUID().uuidString).tif")
        try tiffBytes.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        return try readTIFF(temp, tags: tags)
    }
}
