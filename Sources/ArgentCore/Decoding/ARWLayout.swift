import Foundation

/// What a Sony ARW's raw IFD says about how the frame was recorded.
///
/// Core Image does not expose the raw IFD, so this reads the TIFF structure directly: the
/// header, IFD0 for the model, and the full-resolution SubIFD for its encoding, the
/// camera's crop and, on the lossless modes, the area of valid data. A few small reads,
/// 0.13 to 0.33 ms per file.
public struct ARWLayout: Sendable, Equatable {
    /// How the raw data is stored, from the SubIFD's Compression and PhotometricInterpretation.
    public enum Encoding: String, Sendable, Codable {
        /// Compression 1, CFA.
        case uncompressed
        /// Compression 32767, Sony's lossy ARW 2 format.
        case compressed
        /// Compression 7 with CFA data: lossless L, a true Bayer mosaic.
        case losslessBayer
        /// Compression 7 with YCbCr data: the reduced lossless sizes, M and S on the a7 IV.
        case losslessYCbCr
    }

    public struct Point: Sendable, Equatable {
        public var x: Int
        public var y: Int

        public init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    public struct Size: Sendable, Equatable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public var model: String
    public var encoding: Encoding
    /// The camera's crop of the stored data: DefaultCropOrigin and DefaultCropSize, or Sony's
    /// own copies of them (tags 0x74C7 and 0x74C8) when the DNG tags are absent.
    public var cropOrigin: Point
    public var cropSize: Size
    /// Sony tag 0x7038: how much of the stored data is image, present on the lossless modes.
    /// The stored tiles are padded beyond it.
    public var validSize: Size?

    public init(model: String, encoding: Encoding, cropOrigin: Point, cropSize: Size, validSize: Size?) {
        self.model = model
        self.encoding = encoding
        self.cropOrigin = cropOrigin
        self.cropSize = cropSize
        self.validSize = validSize
    }

    public enum ReadError: Error, CustomStringConvertible {
        case notTIFF
        case truncated
        case noRawIFD
        case unknownEncoding(compression: Int, photometric: Int)

        public var description: String {
            switch self {
            case .notTIFF: return "not a TIFF-structured raw file"
            case .truncated: return "the TIFF structure points past the end of the file"
            case .noRawIFD: return "no full-resolution raw IFD"
            case .unknownEncoding(let c, let p): return "unknown raw encoding: Compression \(c), PhotometricInterpretation \(p)"
            }
        }
    }

    /// Reads the layout of the ARW at `url`. Throws for a file that is not TIFF-structured
    /// or has no recognizable raw IFD.
    public static func read(from url: URL) throws -> ARWLayout {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try parse(TIFFReader(handle: handle))
    }

    static func parse(_ reader: TIFFReader) throws -> ARWLayout {
        let ifd0 = try reader.readIFD(at: reader.firstIFDOffset)
        let model = try ifd0[0x0110].map { try reader.string($0) } ?? ""
        let subIFDs = try ifd0[0x014A].map { try reader.integers($0) } ?? []

        for offset in subIFDs {
            let ifd = try reader.readIFD(at: offset)
            // NewSubfileType 0 is the full-resolution image; a reduced preview is 1.
            let subfileType = try ifd[0x00FE].map { try reader.integers($0).first ?? 0 } ?? 0
            guard subfileType == 0, let compressionEntry = ifd[0x0103] else { continue }
            let compression = try reader.integers(compressionEntry).first ?? 0
            let photometric = try ifd[0x0106].map { try reader.integers($0).first ?? 0 } ?? 0

            let encoding: Encoding
            switch (compression, photometric) {
            case (1, 32803): encoding = .uncompressed
            case (32767, 32803): encoding = .compressed
            case (7, 32803): encoding = .losslessBayer
            case (7, 6): encoding = .losslessYCbCr
            default: throw ReadError.unknownEncoding(compression: compression, photometric: photometric)
            }

            func pair(_ tags: [UInt16]) throws -> (Int, Int)? {
                for tag in tags {
                    if let entry = ifd[tag] {
                        let values = try reader.integers(entry)
                        if values.count >= 2 { return (values[0], values[1]) }
                    }
                }
                return nil
            }
            let width = try ifd[0x0100].map { try reader.integers($0).first ?? 0 } ?? 0
            let height = try ifd[0x0101].map { try reader.integers($0).first ?? 0 } ?? 0
            let origin = try pair([0xC61F, 0x74C7]) ?? (0, 0)
            let size = try pair([0xC620, 0x74C8]) ?? (width, height)
            let valid = try pair([0x7038])
            return ARWLayout(model: model, encoding: encoding,
                             cropOrigin: Point(x: origin.0, y: origin.1),
                             cropSize: Size(width: size.0, height: size.1),
                             validSize: valid.map { Size(width: $0.0, height: $0.1) })
        }
        throw ReadError.noRawIFD
    }
}

/// Just enough TIFF to walk IFDs and read short integer, rational and ASCII values.
struct TIFFReader {
    struct Entry {
        var type: UInt16
        var count: UInt32
        /// The four value bytes as stored: the value itself when it fits, else an offset.
        var valueField: UInt32
        var valueFieldBytes: [UInt8]
    }

    private let handle: FileHandle
    let fileSize: UInt64
    let littleEndian: Bool
    let firstIFDOffset: Int

    init(handle: FileHandle) throws {
        self.handle = handle
        fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: 8), header.count == 8 else { throw ARWLayout.ReadError.notTIFF }
        switch (header[0], header[1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: throw ARWLayout.ReadError.notTIFF
        }
        let bytes = [UInt8](header)
        let magic = littleEndian ? UInt16(bytes[2]) | UInt16(bytes[3]) << 8 : UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        guard magic == 42 else { throw ARWLayout.ReadError.notTIFF }
        firstIFDOffset = Int(Self.uint32(bytes, 4, littleEndian: littleEndian))
    }

    func bytes(at offset: Int, count: Int) throws -> [UInt8] {
        guard offset >= 0, count >= 0, UInt64(offset) + UInt64(count) <= fileSize else { throw ARWLayout.ReadError.truncated }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: count), data.count == count else { throw ARWLayout.ReadError.truncated }
        return [UInt8](data)
    }

    func readIFD(at offset: Int) throws -> [UInt16: Entry] {
        let countBytes = try bytes(at: offset, count: 2)
        let count = Int(Self.uint16(countBytes, 0, littleEndian: littleEndian))
        let raw = try bytes(at: offset + 2, count: count * 12)
        var entries: [UInt16: Entry] = [:]
        for i in 0..<count {
            let base = i * 12
            let tag = Self.uint16(raw, base, littleEndian: littleEndian)
            entries[tag] = Entry(type: Self.uint16(raw, base + 2, littleEndian: littleEndian),
                                 count: Self.uint32(raw, base + 4, littleEndian: littleEndian),
                                 valueField: Self.uint32(raw, base + 8, littleEndian: littleEndian),
                                 valueFieldBytes: Array(raw[(base + 8)..<(base + 12)]))
        }
        return entries
    }

    /// The offset of the IFD after the one at `offset`, or 0 at the end of the chain.
    func nextIFDOffset(after offset: Int) throws -> Int {
        let count = Int(Self.uint16(try bytes(at: offset, count: 2), 0, littleEndian: littleEndian))
        return Int(Self.uint32(try bytes(at: offset + 2 + count * 12, count: 4), 0, littleEndian: littleEndian))
    }

    /// RATIONAL and SRATIONAL values as doubles; integers pass through.
    func doubles(_ entry: Entry) throws -> [Double] {
        guard entry.type == 5 || entry.type == 10 else { return try integers(entry).map(Double.init) }
        let total = 8 * Int(entry.count)
        guard total <= 1 << 16 else { return [] }
        let data = try bytes(at: Int(entry.valueField), count: total)
        return (0..<Int(entry.count)).map { i in
            let raw = (Self.uint32(data, i * 8, littleEndian: littleEndian), Self.uint32(data, i * 8 + 4, littleEndian: littleEndian))
            let numerator = entry.type == 5 ? Double(raw.0) : Double(Int32(bitPattern: raw.0))
            let denominator = entry.type == 5 ? Double(raw.1) : Double(Int32(bitPattern: raw.1))
            return denominator == 0 ? 0 : numerator / denominator
        }
    }

    /// BYTE, SHORT, LONG, IFD and RATIONAL values as integers; a rational is rounded.
    func integers(_ entry: Entry) throws -> [Int] {
        let size: Int
        switch entry.type {
        case 1, 6, 7: size = 1
        case 3, 8: size = 2
        case 4, 9, 13: size = 4
        case 5, 10: size = 8
        default: return []
        }
        let total = size * Int(entry.count)
        guard total <= 1 << 16 else { return [] }  // tile and strip tables, never needed here
        let data = total <= 4 ? Array(entry.valueFieldBytes.prefix(total)) : try bytes(at: Int(entry.valueField), count: total)
        return (0..<Int(entry.count)).map { i in
            let at = i * size
            switch entry.type {
            case 1, 7: return Int(data[at])
            case 6: return Int(Int8(bitPattern: data[at]))
            case 3: return Int(Self.uint16(data, at, littleEndian: littleEndian))
            case 8: return Int(Int16(bitPattern: Self.uint16(data, at, littleEndian: littleEndian)))
            case 4, 13: return Int(Self.uint32(data, at, littleEndian: littleEndian))
            case 9: return Int(Int32(bitPattern: Self.uint32(data, at, littleEndian: littleEndian)))
            default:
                let numerator = Double(Self.uint32(data, at, littleEndian: littleEndian))
                let denominator = Double(Self.uint32(data, at + 4, littleEndian: littleEndian))
                return denominator == 0 ? 0 : Int((numerator / denominator).rounded())
            }
        }
    }

    func string(_ entry: Entry) throws -> String {
        guard entry.type == 2 else { return "" }
        let count = Int(entry.count)
        let data = count <= 4 ? Array(entry.valueFieldBytes.prefix(count)) : try bytes(at: Int(entry.valueField), count: count)
        return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    static func uint16(_ bytes: [UInt8], _ at: Int, littleEndian: Bool) -> UInt16 {
        littleEndian ? UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 : UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }

    static func uint32(_ bytes: [UInt8], _ at: Int, littleEndian: Bool) -> UInt32 {
        let b = (0..<4).map { UInt32(bytes[at + $0]) }
        return littleEndian ? b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24 : b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
    }
}
