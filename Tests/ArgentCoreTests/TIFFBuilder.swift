import CoreGraphics
import Foundation
import ImageIO

/// Builds little-endian TIFF files with chained IFDs, sub-IFD pointers and embedded blobs,
/// for tests that need an ARW's structure without a real file.
struct TIFFBuilder {
    enum Value {
        case short([UInt16])
        /// SSHORT, type 8, as Sony writes its lens correction curves.
        case signedShort([Int16])
        case long([UInt32])
        case rational([(UInt32, UInt32)])
        case ascii(String)
        /// A LONG holding the offset of IFD number `ifd` in `ifds` (chained or not).
        case ifdOffset(Int)
        /// A LONG holding the offset, or the length, of blob number `blob`.
        case blobOffset(Int)
        case blobLength(Int)
    }

    /// Every IFD; those listed in `chain` are linked as the top-level chain, in that order.
    var ifds: [[(UInt16, Value)]] = []
    var chain: [Int] = []
    var blobs: [Data] = []

    func build() -> Data {
        func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
        func outOfLine(_ value: Value) -> Int {
            switch value {
            case .short(let v): return v.count * 2 > 4 ? v.count * 2 : 0
            case .signedShort(let v): return v.count * 2 > 4 ? v.count * 2 : 0
            case .long(let v): return v.count * 4 > 4 ? v.count * 4 : 0
            case .rational(let v): return v.count * 8
            case .ascii(let s): return s.utf8.count + 1 > 4 ? s.utf8.count + 1 : 0
            default: return 0
            }
        }
        func padded(_ n: Int) -> Int { n + n % 2 }

        // Lay out: header, each IFD followed by its out-of-line values, then the blobs.
        var ifdOffsets: [Int] = []
        var cursor = 8
        for ifd in ifds {
            ifdOffsets.append(cursor)
            cursor += 2 + ifd.count * 12 + 4 + ifd.reduce(0) { $0 + padded(outOfLine($1.1)) }
        }
        var blobOffsets: [Int] = []
        for blob in blobs {
            blobOffsets.append(cursor)
            cursor += padded(blob.count)
        }

        var out = [UInt8]([0x49, 0x49]) + u16(42) + u32(UInt32(chain.first.map { ifdOffsets[$0] } ?? 0))
        for (index, ifd) in ifds.enumerated() {
            let sorted = ifd.sorted { $0.0 < $1.0 }
            var data: [UInt8] = []
            let dataStart = ifdOffsets[index] + 2 + sorted.count * 12 + 4
            var table = u16(UInt16(sorted.count))
            for (tag, value) in sorted {
                let (type, count, bytes): (UInt16, UInt32, [UInt8])
                switch value {
                case .short(let v): (type, count, bytes) = (3, UInt32(v.count), v.flatMap(u16))
                case .signedShort(let v): (type, count, bytes) = (8, UInt32(v.count), v.map { UInt16(bitPattern: $0) }.flatMap(u16))
                case .long(let v): (type, count, bytes) = (4, UInt32(v.count), v.flatMap(u32))
                case .rational(let v): (type, count, bytes) = (5, UInt32(v.count), v.flatMap { u32($0.0) + u32($0.1) })
                case .ascii(let s): (type, count, bytes) = (2, UInt32(s.utf8.count + 1), Array(s.utf8) + [0])
                case .ifdOffset(let i): (type, count, bytes) = (4, 1, u32(UInt32(ifdOffsets[i])))
                case .blobOffset(let b): (type, count, bytes) = (4, 1, u32(UInt32(blobOffsets[b])))
                case .blobLength(let b): (type, count, bytes) = (4, 1, u32(UInt32(blobs[b].count)))
                }
                table += u16(tag) + u16(type) + u32(count)
                if bytes.count <= 4 {
                    table += bytes + [UInt8](repeating: 0, count: 4 - bytes.count)
                } else {
                    table += u32(UInt32(dataStart + data.count))
                    data += bytes
                    if data.count % 2 == 1 { data.append(0) }
                }
            }
            let position = chain.firstIndex(of: index)
            let next = position.flatMap { $0 + 1 < chain.count ? ifdOffsets[chain[$0 + 1]] : nil } ?? 0
            out += table + u32(UInt32(next)) + data
        }
        for blob in blobs {
            out += [UInt8](blob)
            if blob.count % 2 == 1 { out.append(0) }
        }
        return Data(out)
    }

    /// A small JPEG of a horizontal gradient, `width` by `height`.
    static func jpeg(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for x in 0..<width {
            context.setFillColor(red: CGFloat(x) / CGFloat(width), green: 0.5, blue: 0.2, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
