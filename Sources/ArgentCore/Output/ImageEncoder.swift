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
/// and XMP through and resetting orientation, since the decoder already rotated.
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

    /// Encodes `image` to `url`. The raw's metadata comes through whole, EXIF, GPS and XMP,
    /// with the orientation reset, the pixel dimensions set to the picture's, and `software`
    /// recorded as the creator tool.
    public func write(_ image: CGImage, to url: URL, format: OutputFormat, metadataFrom source: URL?,
                      software: String? = nil) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw EncodeError.destination(url)
        }
        var options: [CFString: Any] = [:]
        if let quality = format.quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        if format == .tiff16 {
            options[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 1]
        }
        let metadata = Self.metadata(from: source, width: image.width, height: image.height, software: software)
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
        return metadata
    }
}
