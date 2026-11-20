import Darwin
import Foundation

/// The full-resolution raw IFD of a Sony uncompressed raw, in the detail the in-house decoder needs:
/// where the samples lie, the CFA, the black and white levels, the crop and the valid area.
///
/// The a7 IV writes one strip of 14-bit samples in 16-bit little-endian words, 7040 by 4688 in full
/// frame and 4736 by 3132 in APS-C, with the CFA, levels, crop and lens tags lossless L carries
/// (docs/decoder.md, section 17). It writes no valid area (Sony's 0x7038): past the crop and a margin
/// as wide as the crop's origin, the stored columns carry on the last two as a smooth ramp, no image
/// (within 4 DN of the column two to the left in 73 to 100 percent of rows on the 16 real frames here,
/// against 3 to 66 percent inside, measured), so the valid area is the crop with its origin's margin
/// on every side, which is the 0x7038 lossless L writes on the same sensor (7032 by 4688; 4696 by
/// 3132 in APS-C, verified). Everything the decode relies on is checked here, so a
/// file this accepts can be read without further guards, and one it refuses goes to Apple's decoder.
public struct SonyUncompressedRaw: Sendable, Equatable {
    /// Stored size, in samples.
    public var width: Int
    public var height: Int
    /// The strips, in file offsets and byte counts, in order: together `width * height` samples.
    public var stripOffsets: [Int]
    public var stripByteCounts: [Int]
    /// The colour of each position of the 2 by 2 CFA repeat, as `SonyLosslessRaw.cfa`.
    public var cfa: [Int]
    public var blackLevels: [Int]
    public var whiteLevel: Int
    public var cropOrigin: ARWLayout.Point
    public var cropSize: ARWLayout.Size
    public var validSize: ARWLayout.Size
    public var lens: SonyLensCorrection? = nil

    /// The mosaic the strip reads to, as the demosaic reads it.
    public var mosaicLayout: BayerMosaicLayout {
        BayerMosaicLayout(pitch: width, cropOrigin: cropOrigin, cropSize: cropSize, validSize: validSize,
                          cfa: cfa, blackLevels: blackLevels, whiteLevel: whiteLevel)
    }

    public enum ReadError: Error, CustomStringConvertible, Equatable {
        case notUncompressed
        case unsupported(String)

        public var description: String {
            switch self {
            case .notUncompressed: return "not an uncompressed Bayer raw"
            case .unsupported(let what): return "unsupported uncompressed layout: \(what)"
            }
        }
    }

    public static func read(from url: URL) throws -> SonyUncompressedRaw {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try parse(TIFFReader(handle: handle))
    }

    static func parse(_ reader: TIFFReader) throws -> SonyUncompressedRaw {
        let ifd0 = try reader.readIFD(at: reader.firstIFDOffset)
        let subIFDs = try ifd0[0x014A].map { try reader.integers($0) } ?? []
        for offset in subIFDs {
            let ifd = try reader.readIFD(at: offset)
            let subfileType = try ifd[0x00FE].map { try reader.integers($0).first ?? 0 } ?? 0
            guard subfileType == 0, let compressionEntry = ifd[0x0103] else { continue }
            func values(_ tag: UInt16) throws -> [Int] { try ifd[tag].map { try reader.integers($0) } ?? [] }
            func value(_ tag: UInt16) throws -> Int? { try values(tag).first }

            let compression = try reader.integers(compressionEntry).first ?? 0
            let photometric = try value(0x0106) ?? 0
            guard compression == 1, photometric == 32803 else { throw ReadError.notUncompressed }
            // The samples are read as the Mac holds them.
            guard reader.littleEndian else { throw ReadError.unsupported("big-endian samples") }

            let width = try value(0x0100) ?? 0, height = try value(0x0101) ?? 0
            let samples = try value(0x0115) ?? 1
            let bits = try value(0x0102) ?? 0
            guard samples == 1 else { throw ReadError.unsupported("\(samples) samples a pixel") }
            // 14-bit samples in 16-bit words, as the a7 IV writes them; Sony's packed 12-bit raws are other bodies'.
            guard bits == 14 else { throw ReadError.unsupported("\(bits) bits a sample") }
            guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
                throw ReadError.unsupported("a \(width) by \(height) frame")
            }
            guard width <= SonyLosslessRaw.largestSide, height <= SonyLosslessRaw.largestSide else {
                throw ReadError.unsupported("a stored frame of \(width) by \(height)")
            }
            let offsets = try values(0x0111), counts = try values(0x0117)
            guard !offsets.isEmpty, offsets.count == counts.count,
                  offsets.allSatisfy({ $0 > 0 }), counts.allSatisfy({ $0 > 0 && $0 % 2 == 0 })
            else { throw ReadError.unsupported("\(offsets.count) strip offsets and \(counts.count) byte counts") }
            guard counts.reduce(0, +) == width * height * 2 else {
                throw ReadError.unsupported("strips of \(counts.reduce(0, +)) bytes for \(width) by \(height) samples")
            }
            guard zip(offsets, counts).allSatisfy({ UInt64($0) + UInt64($1) <= reader.fileSize }) else {
                throw ARWLayout.ReadError.truncated
            }

            let repeatDim = try values(0x828D)
            let pattern = try values(0x828E)
            guard repeatDim == [2, 2], pattern.count == 4, Set(pattern) == [0, 1, 2],
                  pattern.filter({ $0 == 1 }).count == 2, pattern[0] != 1 ? pattern[3] != 1 : pattern[3] == 1
            else { throw ReadError.unsupported("CFA \(repeatDim) \(pattern)") }

            let black = try values(0x7310)
            guard black.count == 4 else { throw ReadError.unsupported("\(black.count) black levels") }
            guard let white = try value(0xC61D), black.allSatisfy({ $0 >= 0 && $0 < white }), white < 1 << bits else {
                throw ReadError.unsupported("black \(black) and white \(try value(0xC61D) ?? -1)")
            }

            let origin = try values(0xC61F), size = try values(0xC620)
            guard origin.count == 2, size.count == 2 else { throw ReadError.unsupported("no crop") }
            let crop = (origin: ARWLayout.Point(x: origin[0], y: origin[1]), size: ARWLayout.Size(width: size[0], height: size[1]))
            let valid = try values(0x7038)
            let validSize = valid.count == 2 ? ARWLayout.Size(width: valid[0], height: valid[1])
                : Self.validSize(cropOrigin: crop.origin, cropSize: crop.size, width: width, height: height)
            let raw = SonyUncompressedRaw(
                width: width, height: height, stripOffsets: offsets, stripByteCounts: counts, cfa: pattern,
                blackLevels: black, whiteLevel: white, cropOrigin: crop.origin, cropSize: crop.size, validSize: validSize,
                lens: SonyLensCorrection.parse(ifd, reader: reader))
            guard raw.validSize.width <= width, raw.validSize.height <= height, raw.cropSize.width > 0, raw.cropSize.height > 0,
                  raw.cropOrigin.x >= 0, raw.cropOrigin.y >= 0,
                  raw.cropOrigin.x + raw.cropSize.width <= raw.validSize.width,
                  raw.cropOrigin.y + raw.cropSize.height <= raw.validSize.height
            else { throw ReadError.unsupported("crop \(origin) \(size) outside the valid \(raw.validSize.width) by \(raw.validSize.height)") }
            return raw
        }
        throw ARWLayout.ReadError.noRawIFD
    }

    /// The valid area of a file that writes none: the crop and, on each side, a margin as wide as the
    /// crop's origin, within the stored frame.
    static func validSize(cropOrigin: ARWLayout.Point, cropSize: ARWLayout.Size, width: Int, height: Int) -> ARWLayout.Size {
        ARWLayout.Size(width: min(width, cropSize.width + 2 * cropOrigin.x), height: min(height, cropSize.height + 2 * cropOrigin.y))
    }

    /// The bytes the samples take, `width * height * 2`.
    public var byteCount: Int { stripByteCounts.reduce(0, +) }

    /// Reads the samples of the file open as `descriptor` into `destination`, a buffer of `width` by
    /// `height` samples: each strip read straight into place, never mapped, so a file whose volume
    /// goes away mid-read is a read error and not a crash. Throws `ReadFailure.system` when the read
    /// fails and `ReadFailure.short` when the file ends early.
    public func readSamples(from descriptor: Int32, into destination: UnsafeMutableRawPointer) throws {
        var at = 0
        for (offset, count) in zip(stripOffsets, stripByteCounts) {
            var done = 0
            while done < count {
                let n = pread(descriptor, destination + at + done, count - done, off_t(offset + done))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ReadFailure.system(errno)
                }
                if n == 0 { throw ReadFailure.short }
                done += n
            }
            at += count
        }
    }

    /// The samples from `file`, the whole ARW in memory, into `destination`.
    public func unpack(_ file: UnsafeRawBufferPointer, into destination: UnsafeMutableRawPointer) throws {
        var at = 0
        for (offset, count) in zip(stripOffsets, stripByteCounts) {
            guard offset <= file.count - count else { throw ReadFailure.short }
            memcpy(destination + at, file.baseAddress! + offset, count)
            at += count
        }
    }

    public enum ReadFailure: Error, CustomStringConvertible, Equatable {
        case system(Int32)
        case short

        public var description: String {
            switch self {
            case .system(let code): return "read failed: \(String(cString: strerror(code)))"
            case .short: return "the file ends inside its samples"
            }
        }
    }
}
