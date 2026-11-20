import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The job folder's pictures: 8-bit PNGs, red, green and blue or gray, read and written as `FolderEngine` writes and reads them,
/// from and to the image's own buffer, so no colour conversion touches a value.
enum Pictures {
    /// An 8-bit PNG of exactly `width` by `height`: gray for one channel, red, green and blue for three. Row 0 is the top.
    static func png(_ bytes: [UInt8], width: Int, height: Int, channels: Int) throws -> Data {
        let space = channels == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let out = NSMutableData()
        guard bytes.count == width * height * channels, let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * channels,
                                  bytesPerRow: width * channels, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw ObjectClearError.failed("a picture could not be made")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ObjectClearError.failed("a picture could not be written") }
        return out as Data
    }

    /// The bytes of an 8-bit PNG of that size and that many channels, as stored; `nil` for anything else.
    static func pixels(of url: URL, width: Int, height: Int, channels: Int) -> [UInt8]? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              image.width == width, image.height == height, image.bitsPerComponent == 8,
              image.colorSpace?.model == (channels == 1 ? .monochrome : .rgb),
              image.byteOrderInfo == .orderDefault || image.byteOrderInfo == .order32Big else { return nil }
        // Where the first colour sits in a pixel: a decoder may pad it to four bytes, before or after.
        let pixel = image.bitsPerPixel / 8, rowBytes = image.bytesPerRow
        let first: Int
        switch image.alphaInfo {
        case .none where pixel == channels: first = 0
        case .noneSkipLast where pixel == channels + 1: first = 0
        case .noneSkipFirst where pixel == channels + 1: first = 1
        default: return nil
        }
        guard rowBytes >= width * pixel, let data = image.dataProvider?.data,
              CFDataGetLength(data) >= rowBytes * (height - 1) + width * pixel, let base = CFDataGetBytePtr(data) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * channels)
        bytes.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                let row = base + y * rowBytes
                if pixel == channels {
                    memcpy(out.baseAddress! + y * width * channels, row, width * channels)
                } else {
                    for x in 0..<width {
                        for channel in 0..<channels { out[(y * width + x) * channels + channel] = row[x * pixel + first + channel] }
                    }
                }
            }
        }
        return bytes
    }

    /// The width and height of a picture file, without decoding it.
    static func size(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}
