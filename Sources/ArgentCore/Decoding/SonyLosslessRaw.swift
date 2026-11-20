import Foundation

/// The full-resolution raw IFD of a Sony lossless-compressed L file, in the detail the in-house
/// decoder needs: the tile grid, the CFA, the black and white levels, the crop and the valid area.
///
/// Read with the same TIFF walk as `ARWLayout`. Everything the decode relies on is checked here,
/// so a file this accepts can be decoded without further guards, and a file it refuses goes to
/// Apple's decoder.
public struct SonyLosslessRaw: Sendable, Equatable {
    /// The longest stored side accepted: a Metal texture's longest side on Apple GPUs. The a7 IV
    /// stores about 7,000 by 4,700.
    public static let largestSide = 16384

    /// Stored size: whole tiles, padded beyond the valid area.
    public var width: Int
    public var height: Int
    public var tileWidth: Int
    public var tileHeight: Int
    public var tileOffsets: [Int]
    public var tileByteCounts: [Int]
    /// The colour of each position of the 2 by 2 CFA repeat, `(y & 1) * 2 + (x & 1)` in stored
    /// coordinates: 0 red, 1 green, 2 blue (TIFF/EP CFAPattern).
    public var cfa: [Int]
    /// Sony tag 0x7310, one level per CFA position in the same order.
    public var blackLevels: [Int]
    /// DNG WhiteLevel, 0xC61D, which Sony writes into the raw IFD: the value a saturated sample
    /// holds (16383 on the a7 IV, measured: the sample's clipped highlights read exactly that).
    public var whiteLevel: Int
    public var cropOrigin: ARWLayout.Point
    public var cropSize: ARWLayout.Size
    /// Sony tag 0x7038: how much of the stored area is image.
    public var validSize: ARWLayout.Size
    /// The lens corrections the camera wrote, tags 0x7031 to 0x7037; `nil` without them.
    public var lens: SonyLensCorrection? = nil

    /// The mosaic the tiles decode to, as the demosaic reads it.
    public var mosaicLayout: BayerMosaicLayout {
        BayerMosaicLayout(pitch: width, cropOrigin: cropOrigin, cropSize: cropSize, validSize: validSize,
                          cfa: cfa, blackLevels: blackLevels, whiteLevel: whiteLevel)
    }

    public var tilesAcross: Int { (width + tileWidth - 1) / tileWidth }

    public enum ReadError: Error, CustomStringConvertible, Equatable {
        case notLosslessBayer
        case unsupported(String)

        public var description: String {
            switch self {
            case .notLosslessBayer: return "not a lossless-compressed Bayer (L) raw"
            case .unsupported(let what): return "unsupported lossless L layout: \(what)"
            }
        }
    }

    public static func read(from url: URL) throws -> SonyLosslessRaw {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try parse(TIFFReader(handle: handle))
    }

    static func parse(_ reader: TIFFReader) throws -> SonyLosslessRaw {
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
            guard compression == 7, photometric == 32803 else { throw ReadError.notLosslessBayer }

            let width = try value(0x0100) ?? 0, height = try value(0x0101) ?? 0
            let tileWidth = try value(0x0142) ?? 0, tileHeight = try value(0x0143) ?? 0
            let offsets = try values(0x0144), counts = try values(0x0145)
            let samples = try value(0x0115) ?? 1
            let bits = try value(0x0102) ?? 0
            guard samples == 1 else { throw ReadError.unsupported("\(samples) samples a pixel") }
            guard (8...16).contains(bits) else { throw ReadError.unsupported("\(bits) bits a sample") }
            guard width > 0, height > 0, tileWidth > 0, tileHeight > 0,
                  tileWidth % 2 == 0, tileHeight % 2 == 0, width % tileWidth == 0, height % tileHeight == 0
            else { throw ReadError.unsupported("a \(width) by \(height) frame in \(tileWidth) by \(tileHeight) tiles") }
            // No larger than a Metal texture's side, which the frame is demosaicked into; the
            // mosaic's length is then far from overflowing.
            guard width <= Self.largestSide, height <= Self.largestSide else {
                throw ReadError.unsupported("a stored frame of \(width) by \(height)")
            }
            let tiles = (width / tileWidth) * (height / tileHeight)
            guard offsets.count == tiles, counts.count == tiles else {
                throw ReadError.unsupported("\(offsets.count) tile offsets for \(tiles) tiles")
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

            let origin = try values(0xC61F), size = try values(0xC620), valid = try values(0x7038)
            guard origin.count == 2, size.count == 2, valid.count == 2 else { throw ReadError.unsupported("no crop or valid area") }
            let raw = SonyLosslessRaw(
                width: width, height: height, tileWidth: tileWidth, tileHeight: tileHeight,
                tileOffsets: offsets, tileByteCounts: counts, cfa: pattern, blackLevels: black, whiteLevel: white,
                cropOrigin: ARWLayout.Point(x: origin[0], y: origin[1]),
                cropSize: ARWLayout.Size(width: size[0], height: size[1]),
                validSize: ARWLayout.Size(width: valid[0], height: valid[1]),
                lens: SonyLensCorrection.parse(ifd, reader: reader))
            // The demosaic reads three samples beyond the crop on every side.
            guard raw.validSize.width <= width, raw.validSize.height <= height, raw.cropSize.width > 0, raw.cropSize.height > 0,
                  raw.cropOrigin.x >= 0, raw.cropOrigin.y >= 0,
                  raw.cropOrigin.x + raw.cropSize.width <= raw.validSize.width,
                  raw.cropOrigin.y + raw.cropSize.height <= raw.validSize.height
            else { throw ReadError.unsupported("crop \(origin) \(size) outside the valid \(valid)") }
            return raw
        }
        throw ARWLayout.ReadError.noRawIFD
    }

    /// Decodes every tile of `file`, the whole ARW in memory, into `destination`, a buffer of
    /// `width` by `height` samples, the tiles in parallel. Each tile is an independent lossless
    /// JPEG whose four components are the corners of the Bayer quads it covers.
    public func decodeTiles(_ file: UnsafeRawBufferPointer, into destination: UnsafeMutablePointer<UInt16>) throws {
        let failure = TileFailure()
        let target = TileTarget(file: file, destination: destination)
        DispatchQueue.concurrentPerform(iterations: tileOffsets.count) { index in
            do {
                try decodeTile(index, target.file, into: target.destination)
            } catch {
                failure.record(index, error)
            }
        }
        if let (index, error) = failure.first { throw TileError(tile: index, underlying: error) }
    }

    /// A failure in one tile.
    public struct TileError: Error, CustomStringConvertible {
        public var tile: Int
        public var underlying: Error
        public var description: String { "tile \(tile): \(underlying)" }
    }

    func decodeTile(_ index: Int, _ file: UnsafeRawBufferPointer, into destination: UnsafeMutablePointer<UInt16>) throws {
        let offset = tileOffsets[index], count = tileByteCounts[index]
        guard offset >= 0, count > 0, offset <= file.count - count else { throw LosslessJPEG.DecodeError.truncated }
        let bytes = UnsafeRawBufferPointer(rebasing: file[offset..<(offset + count)])
        let header = try LosslessJPEG.header(bytes)
        let extent = LosslessJPEG.Layout.bayerQuad.extent(lines: header.lines, samplesPerLine: header.samplesPerLine)
        guard header.components.count == 4, extent.width == tileWidth, extent.height == tileHeight else {
            throw LosslessJPEG.DecodeError.unsupported(
                "a tile of \(header.components.count) components, \(header.samplesPerLine) by \(header.lines), in \(tileWidth) by \(tileHeight)")
        }
        let x = (index % tilesAcross) * tileWidth, y = (index / tilesAcross) * tileHeight
        try LosslessJPEG.decode(bytes, header: header, into: destination + y * width + x, pitch: width, layout: .bayerQuad)
    }
}

/// The file and the mosaic, for the tile workers: the file is only read, and each worker writes
/// only its own tile's samples.
private struct TileTarget: @unchecked Sendable {
    let file: UnsafeRawBufferPointer
    let destination: UnsafeMutablePointer<UInt16>
}

/// The first tile to fail, from whichever thread found it.
private final class TileFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: (Int, Error)?

    func record(_ index: Int, _ error: Error) {
        lock.withLock {
            if failure == nil || index < failure!.0 { failure = (index, error) }
        }
    }

    var first: (Int, Error)? { lock.withLock { failure } }
}

/// A Bayer mosaic of 16-bit samples in memory, as the demosaic reads it.
public struct BayerMosaicLayout: Sendable, Equatable {
    /// Samples a row.
    public var pitch: Int
    public var cropOrigin: ARWLayout.Point
    public var cropSize: ARWLayout.Size
    /// The area of real samples from the origin; the demosaic reflects reads beyond it.
    public var validSize: ARWLayout.Size
    /// Colour by CFA position `(y & 1) * 2 + (x & 1)`: 0 red, 1 green, 2 blue.
    public var cfa: [Int]
    /// Per CFA position.
    public var blackLevels: [Int]
    public var whiteLevel: Int

    public init(pitch: Int, cropOrigin: ARWLayout.Point, cropSize: ARWLayout.Size, validSize: ARWLayout.Size,
                cfa: [Int], blackLevels: [Int], whiteLevel: Int) {
        self.pitch = pitch
        self.cropOrigin = cropOrigin
        self.cropSize = cropSize
        self.validSize = validSize
        self.cfa = cfa
        self.blackLevels = blackLevels
        self.whiteLevel = whiteLevel
    }
}
