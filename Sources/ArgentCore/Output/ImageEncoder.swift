import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

public enum OutputFormat: Sendable, Equatable {
    case jpeg(quality: Double)
    case heic(quality: Double)
    /// 16 bits a channel, uncompressed: LZW saved 13 percent of a 262 MB frame for ten times
    /// the time, Deflate 37 percent for fifty times (measured, docs/M2-shell.md).
    case tiff16

    var type: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .tiff16: return .tiff
        }
    }

    var quality: Double? {
        switch self {
        case .jpeg(let q), .heic(let q): return q
        case .tiff16: return nil
        }
    }

    var bitsPerChannel: Int {
        switch self {
        case .jpeg, .heic: return 8
        case .tiff16: return 16
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .tiff16: return "tif"
        }
    }
}

/// The colour space a developed file is encoded in, with its ICC profile embedded.
public enum OutputSpace: String, Sendable, Codable, CaseIterable {
    case sRGB
    case displayP3
    case adobeRGB

    public var title: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        case .adobeRGB: return "Adobe RGB"
        }
    }

    public var colorSpace: CGColorSpace {
        switch self {
        case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)!
        case .adobeRGB: return CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        }
    }
}

public enum EncodeError: LocalizedError, CustomStringConvertible {
    case imageCreation
    case destination(URL)
    case finalize(URL)

    public var description: String {
        switch self {
        case .imageCreation: return "Could not create a CGImage from the rendered texture."
        case .destination(let url): return "Could not create an image destination at \(url.path)."
        case .finalize(let url): return "Could not write \(url.path)."
        }
    }

    public var errorDescription: String? { description }
}

/// Writes a display-referred texture to disk through ImageIO, carrying the raw's EXIF, GPS
/// and XMP (without the vendor MakerNote), restoring the EXIF UTC offsets and `aux:Lens` name
/// that Apple's ARW reader drops or rewrites, and resetting orientation, since the decoder
/// already rotated.
public final class ImageEncoder {
    private let gpu: GPU
    private let resize: AreaResize

    public init(gpu: GPU) throws {
        self.gpu = gpu
        resize = try AreaResize(gpu: gpu)
    }

    /// The texture as a finished picture in `space`, its longer side at most `longEdge`
    /// pixels, rendered now so the texture can go back to its pool before the encode.
    /// `colorSpace` says what the texture's values mean: a stock ends in display-linear light
    /// in the working primaries, an M0 LUT in sRGB-encoded values. A smaller size is
    /// area-resized in linear light (`AreaResize`), `round(width * scale)` by `round(height *
    /// scale)` with the longer side exactly `longEdge`.
    public func picture(_ texture: MTLTexture, colorSpace: CGColorSpace, format: OutputFormat,
                        space: OutputSpace = .sRGB, longEdge: Int? = nil) throws -> CGImage {
        var source = texture, sourceSpace = colorSpace
        var resized: PooledTexture?
        if let longEdge {
            let scale = Double(longEdge) / Double(max(texture.width, texture.height))
            if scale < 1, colorSpace.name == gpu.workingColorSpace.name {
                resized = try resize.resized(texture, scale: scale)
            } else if scale < 1 {
                let linear = try self.linear(texture, colorSpace: colorSpace)
                resized = try withExtendedLifetime(linear) { try resize.resized(linear.texture, scale: scale) }
                sourceSpace = gpu.workingColorSpace
            }
            if let resized { source = resized.texture }
        }
        guard let image = CIImage(mtlTexture: source, options: [.colorSpace: sourceSpace]) else {
            throw EncodeError.imageCreation
        }
        return try withExtendedLifetime(resized) {
            format.bitsPerChannel == 8 ? try surfacePicture(image, space: space) : try memoryPicture(image, format: format, space: space)
        }
    }

    /// A 16-bit TIFF's picture, rendered now into plain memory. Through an IOSurface it encodes
    /// slower (docs/M3-auto.md section 15).
    func memoryPicture(_ image: CIImage, format: OutputFormat, space: OutputSpace) throws -> CGImage {
        let pixelFormat: CIFormat = format.bitsPerChannel == 16 ? .RGBA16 : .RGBA8
        guard let cgImage = gpu.ciContext.createCGImage(image, from: image.extent, format: pixelFormat,
                                                        colorSpace: space.colorSpace, deferred: false)
        else { throw EncodeError.imageCreation }
        return cgImage
    }

    /// A JPEG's or HEIC's picture: rendered now into an IOSurface, then handed to ImageIO through
    /// Core Image. ImageIO encodes a full-size JPEG from it in about 50 ms, where one from a picture
    /// in plain memory took about 145, to a file of the same quality (measured, docs/M3-auto.md
    /// section 15). A HEIC encodes as fast either way and a develop to HEIC peaks 0.16 to 0.43 GB lower
    /// this way (measured, docs/M2-shell.md section 10).
    func surfacePicture(_ image: CIImage, space: OutputSpace) throws -> CGImage {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(nil, Int(image.extent.width), Int(image.extent.height), kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer
        else { throw EncodeError.imageCreation }
        // Finished before returning, so the texture can go back to its pool.
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = space.colorSpace
        _ = try gpu.ciContext.startTask(toRender: image, to: destination).waitUntilCompleted()
        let surface = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: space.colorSpace])
        guard let picture = gpu.ciContext.createCGImage(surface, from: surface.extent, format: .RGBA8,
                                                        colorSpace: space.colorSpace, deferred: true)
        else { throw EncodeError.imageCreation }
        return picture
    }

    /// `texture`, whose values mean `colorSpace`, in linear light in the working space, so a
    /// resize averages light and not encoded values.
    private func linear(_ texture: MTLTexture, colorSpace: CGColorSpace) throws -> PooledTexture {
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace]) else {
            throw EncodeError.imageCreation
        }
        let output = try gpu.texturePool.acquire(width: texture.width, height: texture.height)
        guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        gpu.ciContext.render(image, to: output.texture, commandBuffer: commandBuffer, bounds: image.extent,
                             colorSpace: gpu.workingColorSpace)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
        return output
    }

    /// EXIF fields read straight from a TIFF-structured raw's Exif IFD: the three UTC offsets
    /// Apple's ARW reader omits from its metadata tree, and `LensModel` (0xA434), which Apple's
    /// reader replaces with a lens-ID lookup in `aux:Lens`.
    struct RawExif: Sendable, Equatable {
        var offsetTime: String?
        var offsetTimeOriginal: String?
        var offsetTimeDigitized: String?
        var lensModel: String?
    }

    /// Encodes `image` to `url`. Copies the source's EXIF, GPS and XMP metadata through ImageIO
    /// (the vendor MakerNote is not carried), restores any well-formed `OffsetTime*` tags and sets
    /// `aux:Lens` to the raw's EXIF `LensModel` straight from the TIFF Exif IFD, resets orientation
    /// to 1, sets pixel dimensions to the picture's, and records `software` as TIFF Software and
    /// `xmp:CreatorTool`. Leaves out embedded thumbnails: at 7008 by 4672 on the IOSurface path,
    /// `kCGImageDestinationEmbedThumbnail` adds about 23 ms on HEIC, silently drops JPEG's IFD1
    /// after ~6.5 ms when a 512 by 340 thumbnail exceeds APP1's 64 KB limit, and does nothing on
    /// TIFF.
    public func write(_ image: CGImage, to url: URL, format: OutputFormat, metadataFrom source: URL?,
                      software: String? = nil) throws {
        try write(image, to: url, format: format, metadataFrom: source, software: software,
                  rawExif: source.map(Self.readRawExif(from:)) ?? RawExif())
    }

    func write(_ image: CGImage, to url: URL, format: OutputFormat, metadataFrom source: URL?,
               software: String? = nil, rawExif: RawExif) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw EncodeError.destination(url)
        }
        var options: [CFString: Any] = [:]
        if let quality = format.quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        if format == .tiff16 {
            options[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 1]
        }
        let metadata = Self.metadata(from: source, width: image.width, height: image.height, software: software, rawExif: rawExif)
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, options as CFDictionary)
        // A HEIC's finalize grows the file in memory to 32 MB and frees it; malloc's large cache kept
        // those blocks, 1.1 to 1.3 GB over a roll, so the app is launched with that cache off
        // (MallocLargeCache in App/Info.plist; docs/M2-shell.md section 10).
        guard CGImageDestinationFinalize(destination) else { throw EncodeError.finalize(url) }
    }

    /// Renders and writes in one step, for the spike: the picture in sRGB, at full size or its
    /// longer side `longEdge`.
    public func write(_ texture: MTLTexture, to url: URL, format: OutputFormat, metadataFrom source: URL?,
                      colorSpace: CGColorSpace? = nil, longEdge: Int? = nil) throws {
        let image = try picture(texture, colorSpace: colorSpace ?? gpu.outputColorSpace, format: format,
                                longEdge: longEdge)
        try write(image, to: url, format: format, metadataFrom: source)
    }

    /// The source's metadata as a mutable tree, adjusted for the developed picture.
    static func metadata(from source: URL?, width: Int, height: Int, software: String?) -> CGImageMetadata {
        metadata(from: source, width: width, height: height, software: software,
                 rawExif: source.map(readRawExif(from:)) ?? RawExif())
    }

    static func metadata(from source: URL?, width: Int, height: Int, software: String?,
                         rawExif: RawExif) -> CGImageMetadata {
        let metadata: CGMutableImageMetadata
        if let source, let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
           let found = CGImageSourceCopyMetadataAtIndex(imageSource, 0, nil),
           let copy = CGImageMetadataCreateMutableCopy(found) {
            metadata = copy
        } else {
            metadata = CGImageMetadataCreateMutable()
        }
        let set = { (dictionary: CFString, key: CFString, value: Any) in
            _ = CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key, value as CFTypeRef)
        }
        // The decoder has already turned the frame upright.
        set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1)
        set(kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelXDimension, width)
        set(kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelYDimension, height)
        if let software {
            set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFSoftware, software)
            _ = CGImageMetadataSetValueWithPath(metadata, nil, "xmp:CreatorTool" as CFString, software as CFString)
        }
        apply(rawExif, to: metadata)
        return metadata
    }

    /// Patches the copied metadata tree with the UTC offsets and camera lens name read straight
    /// from the raw's Exif IFD. Malformed offsets and empty lens strings are ignored.
    static func apply(_ rawExif: RawExif, to metadata: CGMutableImageMetadata) {
        let offsets: [(CFString, String?)] = [
            (kCGImagePropertyExifOffsetTime, rawExif.offsetTime),
            (kCGImagePropertyExifOffsetTimeOriginal, rawExif.offsetTimeOriginal),
            (kCGImagePropertyExifOffsetTimeDigitized, rawExif.offsetTimeDigitized),
        ]
        for (key, value) in offsets {
            if let valid = value.flatMap(validOffset) {
                _ = CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary, key, valid as CFString)
            }
        }
        if let lens = rawExif.lensModel?.trimmingCharacters(in: .whitespaces), !lens.isEmpty {
            _ = CGImageMetadataSetValueWithPath(metadata, nil, "aux:Lens" as CFString, lens as CFString)
        }
    }

    /// Reads the EXIF UTC offsets and `LensModel` from a TIFF-structured file's Exif IFD in a few
    /// small reads, without touching image data or the MakerNote. Returns empty fields for any
    /// non-TIFF, unreadable, or tag-less source.
    static func readRawExif(from url: URL) -> RawExif {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return RawExif() }
        defer { try? handle.close() }
        guard let reader = try? TIFFReader(handle: handle),
              let ifd0 = try? reader.readIFD(at: reader.firstIFDOffset),
              let exifPointer = ifd0[0x8769],
              let exifOffset = (try? reader.integers(exifPointer))?.first,
              let exif = try? reader.readIFD(at: exifOffset) else {
            return RawExif()
        }
        return parseRawExif(exif, reader: reader)
    }

    static func parseRawExif(_ exif: [UInt16: TIFFReader.Entry], reader: TIFFReader) -> RawExif {
        func ascii(_ tag: UInt16, maxBytes: UInt32) -> String? {
            guard let entry = exif[tag], entry.type == 2, entry.count > 0, entry.count <= maxBytes,
                  let text = try? reader.string(entry), !text.isEmpty else { return nil }
            return text
        }
        return RawExif(
            offsetTime: ascii(0x9010, maxBytes: 32).flatMap(validOffset),
            offsetTimeOriginal: ascii(0x9011, maxBytes: 32).flatMap(validOffset),
            offsetTimeDigitized: ascii(0x9012, maxBytes: 32).flatMap(validOffset),
            lensModel: ascii(0xA434, maxBytes: 1024)
        )
    }

    /// Accepts an EXIF UTC offset shaped `+HH:MM` or `-HH:MM` (00 to 23 hours, 00 to 59 minutes).
    static func validOffset(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        guard bytes.count == 6,
              bytes[0] == UInt8(ascii: "+") || bytes[0] == UInt8(ascii: "-"),
              bytes[3] == UInt8(ascii: ":") else { return nil }
        func twoDigits(_ high: UInt8, _ low: UInt8) -> Int? {
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(high),
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(low) else { return nil }
            return Int(high - UInt8(ascii: "0")) * 10 + Int(low - UInt8(ascii: "0"))
        }
        guard let hours = twoDigits(bytes[1], bytes[2]), hours <= 23,
              let minutes = twoDigits(bytes[4], bytes[5]), minutes <= 59 else { return nil }
        return text
    }
}
