import CoreGraphics
import Foundation
import ImageIO

/// What a contact sheet needs from an ARW without touching the raw data: where its embedded
/// JPEGs are, how the frame is oriented, and when and how it was taken.
///
/// An a7 IV ARW chains three IFDs at the top level: IFD0 holds a 1616 by 1080 preview JPEG and
/// the Exif pointer, IFD1 a 160 by 120 thumbnail, and IFD2 a JPEG at the full crop size, 7008
/// by 4672 on a full-frame file. Every JPEG is stored unrotated; IFD0's Orientation says how to
/// show it. Reading all of this takes a handful of small reads.
public struct ARWFrameInfo: Sendable, Equatable {
    /// A JPEG's bytes inside the file.
    public struct ByteRange: Sendable, Equatable {
        public var offset: Int
        public var length: Int

        public init(offset: Int, length: Int) {
            self.offset = offset
            self.length = length
        }
    }

    public var model: String
    public var orientation: CGImagePropertyOrientation
    /// DateTimeOriginal plus SubSecTimeOriginal, read as UTC because the camera records local
    /// time without a zone unless OffsetTimeOriginal is set. Right for ordering a roll; shift by
    /// `captureOffset` for the true instant.
    public var captureDate: Date?
    /// OffsetTimeOriginal, for example "+02:00", when the camera wrote one.
    public var captureOffset: String?
    public var exposureTime: Double?
    public var fNumber: Double?
    public var lensMetadata: LensMetadata
    public var iso: Int?
    /// Exif Flash's fired bit, when the camera wrote the tag.
    public var flashFired: Bool?
    /// IFD0's preview JPEG, the contact sheet's source.
    public var preview: ByteRange?
    /// The largest JPEG in the file, at the full crop size on the a7 IV.
    public var fullSizePreview: ByteRange?

    public init(model: String = "", orientation: CGImagePropertyOrientation = .up, captureDate: Date? = nil,
                captureOffset: String? = nil, exposureTime: Double? = nil, fNumber: Double? = nil, iso: Int? = nil,
                flashFired: Bool? = nil, preview: ByteRange? = nil, fullSizePreview: ByteRange? = nil,
                lensMetadata: LensMetadata = LensMetadata()) {
        self.flashFired = flashFired
        self.model = model
        self.orientation = orientation
        self.captureDate = captureDate
        self.captureOffset = captureOffset
        self.exposureTime = exposureTime
        self.fNumber = fNumber
        self.lensMetadata = lensMetadata
        self.iso = iso
        self.preview = preview
        self.fullSizePreview = fullSizePreview
    }

    /// True when the frame shows taller than wide.
    public var isPortrait: Bool { [.left, .leftMirrored, .right, .rightMirrored].contains(orientation) }

    public static func read(from url: URL) throws -> ARWFrameInfo {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try parse(TIFFReader(handle: handle))
    }

    static func parse(_ reader: TIFFReader) throws -> ARWFrameInfo {
        var info = ARWFrameInfo()
        var jpegs: [(ifd: Int, range: ByteRange)] = []
        var offset = reader.firstIFDOffset
        var index = 0
        while offset != 0, index < 8 {
            let ifd = try reader.readIFD(at: offset)
            if let start = ifd[0x0201], let length = ifd[0x0202],
               let o = try reader.integers(start).first, let l = try reader.integers(length).first, l > 0 {
                jpegs.append((index, ByteRange(offset: o, length: l)))
            }
            if index == 0 {
                info.model = try ifd[0x0110].map { try reader.string($0) } ?? ""
                let raw = try ifd[0x0112].map { try reader.integers($0).first ?? 1 } ?? 1
                // TIFFReader hands signed types through as negative Ints, and UInt32(raw)
                // traps on them — a trap no caller can catch. Convert losslessly and fall
                // back to .up for anything unrepresentable or not an Exif orientation.
                info.orientation = UInt32(exactly: raw).flatMap { CGImagePropertyOrientation(rawValue: $0) } ?? .up
                if let exifEntry = ifd[0x8769], let exifOffset = try reader.integers(exifEntry).first {
                    try readExif(reader, at: exifOffset, into: &info)
                }
            }
            offset = try reader.nextIFDOffset(after: offset)
            index += 1
        }
        info.preview = jpegs.first { $0.ifd == 0 }?.range
        info.fullSizePreview = jpegs.max { $0.range.length < $1.range.length }?.range
        return info
    }

    private static func readExif(_ reader: TIFFReader, at offset: Int, into info: inout ARWFrameInfo) throws {
        let exif = try reader.readIFD(at: offset)
        info.lensMetadata = LensMetadata.parse(exif, reader: reader, model: info.model)
        if let entry = exif[0x9003] {
            let subseconds = try exif[0x9291].map { try reader.string($0) }
            info.captureDate = captureDate(try reader.string(entry), subseconds: subseconds)
        }
        info.captureOffset = try exif[0x9011].map { try reader.string($0) }.flatMap { $0.isEmpty ? nil : $0 }
        info.exposureTime = try exif[0x829A].flatMap { try reader.doubles($0).first }
        info.fNumber = try exif[0x829D].flatMap { try reader.doubles($0).first }
        // ISOSpeedRatings saturates at 65535; RecommendedExposureIndex holds the real value.
        let ratings = try exif[0x8827].flatMap { try reader.integers($0).first }
        let recommended = try exif[0x8832].flatMap { try reader.integers($0).first }
        info.iso = ratings.flatMap { $0 == 65535 ? nil : $0 } ?? recommended ?? ratings
        info.flashFired = try exif[0x9209].flatMap { try reader.integers($0).first }.map { $0 & 1 == 1 }
    }

    /// The light the exposure was set for, in EV at ISO 100: log2(N^2 / t) - log2(ISO / 100).
    /// `nil` without a shutter, an aperture and an ISO.
    public var sceneEV100: Double? {
        guard let t = exposureTime, t > 0, let n = fNumber, n > 0, let iso, iso > 0 else { return nil }
        return log2(n * n / t) - log2(Double(iso) / 100)
    }

    /// "2023:10:19 16:13:48" and "776" as an instant, read in UTC.
    static func captureDate(_ text: String, subseconds: String?) -> Date? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == " " }).compactMap { Int($0) }
        guard parts.count == 6 else { return nil }
        var components = DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                         hour: parts[3], minute: parts[4], second: parts[5])
        components.timeZone = TimeZone(secondsFromGMT: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: components) else { return nil }
        guard let digits = subseconds?.trimmingCharacters(in: .whitespaces), !digits.isEmpty,
              let fraction = Double("0." + digits) else { return date }
        return date.addingTimeInterval(fraction)
    }
}

/// Decoding an ARW's embedded JPEGs, upright and at the size asked for.
public enum EmbeddedJPEG {
    public enum DecodeError: Error, CustomStringConvertible {
        case unreadable(URL)

        public var description: String {
            switch self {
            case .unreadable(let url): return "Could not read the embedded preview of \(url.lastPathComponent)"
            }
        }
    }

    /// The JPEG at `range` in `url`, decoded so its longer side is at most `maxPixelSize` and
    /// turned upright by `orientation`. JPEG decoding scales by powers of two in the DCT, so a
    /// size at or under half the stored one is cheap.
    public static func image(at range: ARWFrameInfo.ByteRange, in url: URL, maxPixelSize: Int,
                             orientation: CGImagePropertyOrientation) throws -> CGImage {
        guard range.offset >= 0, range.length > 0 else { throw DecodeError.unreadable(url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let offset = UInt64(range.offset), length = UInt64(range.length)
        let fileSize = try handle.seekToEnd()
        guard offset <= fileSize, length <= fileSize - offset else { throw DecodeError.unreadable(url) }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: range.length), data.count == range.length,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { throw DecodeError.unreadable(url) }
        return oriented(image, orientation)
    }

    /// `image` turned upright for an Exif `orientation`, the way Core Image's `oriented(_:)` does.
    public static func oriented(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage {
        guard orientation != .up else { return image }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let swapsAxes = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
        let outWidth = swapsAxes ? height : width, outHeight = swapsAxes ? width : height
        guard let context = CGContext(data: nil, width: Int(outWidth), height: Int(outHeight), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        // Core Graphics puts the origin at the bottom left, so these are the Exif rotations
        // expressed for a y-up canvas.
        var transform = CGAffineTransform.identity
        switch orientation {
        case .down, .downMirrored:
            transform = transform.translatedBy(x: outWidth, y: outHeight).rotated(by: .pi)
        case .left, .leftMirrored:
            transform = transform.translatedBy(x: outWidth, y: 0).rotated(by: .pi / 2)
        case .right, .rightMirrored:
            transform = transform.translatedBy(x: 0, y: outHeight).rotated(by: -.pi / 2)
        default:
            break
        }
        switch orientation {
        case .upMirrored, .downMirrored:
            transform = transform.translatedBy(x: width, y: 0).scaledBy(x: -1, y: 1)
        case .leftMirrored, .rightMirrored:
            transform = transform.translatedBy(x: width, y: 0).scaledBy(x: -1, y: 1)
        default:
            break
        }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
