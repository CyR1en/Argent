import Foundation

/// Lossless JPEG, the process of ITU-T T.81 Annex H: SOF3, Huffman-coded differences against
/// one of seven predictors, an optional point transform and restart intervals.
///
/// Written from the recommendation for the a7 IV's lossless-compressed L files, which store the
/// Bayer mosaic as tiles of one such stream each (docs/decoder.md). The decoder writes straight
/// into the caller's sample buffer: `Layout` says where each component of each MCU lands, and the
/// predictors read their neighbours back from there, so a tile needs no buffer of its own. It
/// checks everything it reads and never writes outside the area `Layout` gives it.
public enum LosslessJPEG {
    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case notJPEG
        case truncated
        case unsupported(String)
        case malformed(String)

        public var description: String {
            switch self {
            case .notJPEG: return "not a JPEG stream"
            case .truncated: return "the stream ends before its last sample"
            case .unsupported(let what): return "unsupported lossless JPEG: \(what)"
            case .malformed(let what): return "malformed lossless JPEG: \(what)"
            }
        }
    }

    /// One frame component from SOF3, with the Huffman table the scan gives it.
    public struct Component: Sendable, Equatable {
        public var id: UInt8
        public var horizontalSampling: Int
        public var verticalSampling: Int
        public var table: Int
    }

    /// What a stream says about itself, read up to its scan's first entropy-coded byte.
    public struct Header: Sendable {
        /// Bits per sample, 2 to 16.
        public var precision: Int
        public var lines: Int
        /// Samples per line, which is MCUs per line when every component is sampled 1 by 1.
        public var samplesPerLine: Int
        public var components: [Component]
        /// The predictor, 1 to 7 (Table H.1).
        public var predictor: Int
        public var pointTransform: Int
        /// MCUs per restart interval, 0 for none.
        public var restartInterval: Int
        /// Where the scan's entropy-coded data starts.
        public var scanOffset: Int
        var tables: [HuffmanTable?]
    }

    /// Where the samples go: component `c` of the MCU at (`x`, `y`) is written at
    /// `(y * rowStep + rowOffsets[c]) * pitch + x * columnStep + columnOffsets[c]` from the
    /// destination's origin. A Sony lossless L tile interleaves four components that are the
    /// four corners of a Bayer quad: steps of 2 and offsets (0, 1, 0, 1) and (0, 0, 1, 1).
    public struct Layout: Sendable, Equatable {
        public var columnStep: Int
        public var rowStep: Int
        public var columnOffsets: [Int]
        public var rowOffsets: [Int]

        public init(columnStep: Int, rowStep: Int, columnOffsets: [Int], rowOffsets: [Int]) {
            self.columnStep = columnStep
            self.rowStep = rowStep
            self.columnOffsets = columnOffsets
            self.rowOffsets = rowOffsets
        }

        /// One component, one sample per pixel.
        public static let single = Layout(columnStep: 1, rowStep: 1, columnOffsets: [0], rowOffsets: [0])
        /// Four components, each the corner of a 2 by 2 quad: top-left, top-right, bottom-left,
        /// bottom-right.
        public static let bayerQuad = Layout(columnStep: 2, rowStep: 2, columnOffsets: [0, 1, 0, 1], rowOffsets: [0, 0, 1, 1])

        /// The pixels a stream of `lines` by `samplesPerLine` MCUs covers.
        public func extent(lines: Int, samplesPerLine: Int) -> (width: Int, height: Int) {
            ((samplesPerLine - 1) * columnStep + (columnOffsets.max() ?? 0) + 1,
             (lines - 1) * rowStep + (rowOffsets.max() ?? 0) + 1)
        }
    }

    /// A Huffman table as a 16-bit lookahead: entry `code` holds the length of the code that
    /// starts those 16 bits in its high byte and its symbol in the low byte; 0 is no code.
    final class HuffmanTable: @unchecked Sendable {
        /// 65536 entries, written once in `init`.
        let lookup: UnsafeMutablePointer<UInt16>

        /// From DHT's 16 code counts and its symbols, the canonical codes of T.81 Annex C.
        init(counts: [Int], symbols: [UInt8]) throws {
            lookup = .allocate(capacity: 1 << 16)
            lookup.initialize(repeating: 0, count: 1 << 16)
            var code = 0
            var k = 0
            for length in 1...16 {
                for _ in 0..<counts[length - 1] {
                    // A code that does not fit in `length` bits means the counts are not a prefix code.
                    guard code < 1 << length else { throw DecodeError.malformed("Huffman counts overflow") }
                    let first = code << (16 - length), count = 1 << (16 - length)
                    (lookup + first).update(repeating: UInt16(length << 8) | UInt16(symbols[k]), count: count)
                    code += 1
                    k += 1
                }
                code <<= 1
            }
        }

        deinit { lookup.deallocate() }
    }

    /// Reads the markers up to the scan: SOI, DHT, SOF3, DRI and SOS, skipping APPn and COM.
    public static func header(_ bytes: UnsafeRawBufferPointer) throws -> Header {
        let n = bytes.count
        guard n >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw DecodeError.notJPEG }
        var tables = [HuffmanTable?](repeating: nil, count: 4)
        var frame: (precision: Int, lines: Int, samples: Int, components: [Component])?
        var restartInterval = 0
        var i = 2
        while true {
            // Markers may be preceded by any number of 0xFF fill bytes (B.1.1.2).
            guard i + 1 < n else { throw DecodeError.truncated }
            guard bytes[i] == 0xFF else { throw DecodeError.malformed("expected a marker at byte \(i)") }
            let marker = bytes[i + 1]
            if marker == 0xFF { i += 1; continue }
            guard i + 3 < n else { throw DecodeError.truncated }
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            guard length >= 2, i + 2 + length <= n else { throw DecodeError.truncated }
            let segment = i + 4
            let segmentEnd = i + 2 + length
            switch marker {
            case 0xC4:  // DHT
                var k = segment
                while k < segmentEnd {
                    guard k + 17 <= segmentEnd else { throw DecodeError.malformed("short DHT") }
                    let tableClass = Int(bytes[k] >> 4), destination = Int(bytes[k] & 15)
                    guard tableClass == 0, destination < 4 else { throw DecodeError.malformed("DHT class \(tableClass) destination \(destination)") }
                    let counts = (0..<16).map { Int(bytes[k + 1 + $0]) }
                    let total = counts.reduce(0, +)
                    guard total <= 256, k + 17 + total <= segmentEnd else { throw DecodeError.malformed("DHT symbols overrun") }
                    let symbols = (0..<total).map { bytes[k + 17 + $0] }
                    // A lossless difference category is 0 to 16 (Table H.2).
                    guard symbols.allSatisfy({ $0 <= 16 }) else { throw DecodeError.malformed("difference category above 16") }
                    tables[destination] = try HuffmanTable(counts: counts, symbols: symbols)
                    k += 17 + total
                }
            case 0xC3:  // SOF3, lossless, Huffman
                guard length >= 8 else { throw DecodeError.malformed("short SOF3") }
                let precision = Int(bytes[segment])
                let lines = Int(bytes[segment + 1]) << 8 | Int(bytes[segment + 2])
                let samples = Int(bytes[segment + 3]) << 8 | Int(bytes[segment + 4])
                let count = Int(bytes[segment + 5])
                guard (2...16).contains(precision) else { throw DecodeError.unsupported("precision \(precision)") }
                guard lines > 0, samples > 0 else { throw DecodeError.unsupported("a frame of \(samples) by \(lines)") }
                guard (1...4).contains(count), length == 8 + 3 * count else { throw DecodeError.malformed("SOF3 with \(count) components") }
                var components: [Component] = []
                for c in 0..<count {
                    let base = segment + 6 + 3 * c
                    let sampling = bytes[base + 1]
                    let h = Int(sampling >> 4), v = Int(sampling & 15)
                    guard h == 1, v == 1 else { throw DecodeError.unsupported("component sampling \(h) by \(v)") }
                    components.append(Component(id: bytes[base], horizontalSampling: h, verticalSampling: v, table: -1))
                }
                frame = (precision, lines, samples, components)
            case 0xDD:  // DRI
                guard length == 4 else { throw DecodeError.malformed("DRI length \(length)") }
                restartInterval = Int(bytes[segment]) << 8 | Int(bytes[segment + 1])
            case 0xDA:  // SOS
                guard var frame else { throw DecodeError.malformed("SOS before SOF3") }
                // One component at least: the count, its selector and table, and three bytes.
                guard length >= 8 else { throw DecodeError.malformed("SOS length \(length)") }
                let count = Int(bytes[segment])
                guard count == frame.components.count, length == 6 + 2 * count else {
                    throw DecodeError.unsupported("a scan of \(count) of \(frame.components.count) components")
                }
                for c in 0..<count {
                    let id = bytes[segment + 1 + 2 * c]
                    let table = Int(bytes[segment + 2 + 2 * c] >> 4)
                    guard let index = frame.components.firstIndex(where: { $0.id == id }), index == c else {
                        throw DecodeError.unsupported("scan components out of frame order")
                    }
                    guard table < 4, tables[table] != nil else { throw DecodeError.malformed("component \(c) has no Huffman table") }
                    frame.components[c].table = table
                }
                let predictor = Int(bytes[segment + 1 + 2 * count])
                let pointTransform = Int(bytes[segment + 3 + 2 * count] & 15)
                guard (1...7).contains(predictor) else { throw DecodeError.unsupported("predictor \(predictor)") }
                guard pointTransform < frame.precision else { throw DecodeError.malformed("point transform \(pointTransform)") }
                if restartInterval > 0, restartInterval % frame.samples != 0 {
                    throw DecodeError.unsupported("a restart interval of \(restartInterval) MCUs in lines of \(frame.samples)")
                }
                return Header(precision: frame.precision, lines: frame.lines, samplesPerLine: frame.samples,
                              components: frame.components, predictor: predictor, pointTransform: pointTransform,
                              restartInterval: restartInterval, scanOffset: segmentEnd, tables: tables)
            case 0xC0...0xCF where marker != 0xC8 && marker != 0xCC:
                throw DecodeError.unsupported(String(format: "SOF%d", Int(marker) - 0xC0))
            case 0xD9:
                throw DecodeError.malformed("EOI before the scan")
            default:
                break  // APPn, COM, DQT and the like carry nothing a lossless scan needs
            }
            i = segmentEnd
        }
    }

    /// Decodes the scan into `destination`, which must hold
    /// `layout.extent(lines:samplesPerLine:)` pixels at `pitch` samples a row from its origin.
    public static func decode(_ bytes: UnsafeRawBufferPointer, header: Header,
                              into destination: UnsafeMutablePointer<UInt16>, pitch: Int, layout: Layout) throws {
        let count = header.components.count
        guard layout.columnOffsets.count >= count, layout.rowOffsets.count >= count else {
            throw DecodeError.unsupported("a layout for \(layout.columnOffsets.count) of \(count) components")
        }
        let extent = layout.extent(lines: header.lines, samplesPerLine: header.samplesPerLine)
        guard extent.width <= pitch else { throw DecodeError.unsupported("a frame wider than its destination") }
        guard let base = bytes.baseAddress, header.scanOffset <= bytes.count else { throw DecodeError.truncated }

        // The tables stay alive in `header` for the whole decode; the loop takes raw pointers.
        let tables = header.components.map { header.tables[$0.table]! }
        let offsets = (0..<count).map { layout.rowOffsets[$0] * pitch + layout.columnOffsets[$0] }
        let reader = BitReader(base: base.assumingMemoryBound(to: UInt8.self), position: header.scanOffset, end: bytes.count)
        let overran = try withExtendedLifetime(tables) {
            try tables.map { UnsafePointer($0.lookup) }.withUnsafeBufferPointer { lookups in
                try offsets.withUnsafeBufferPointer { offsets in
                    try scan(header, reader, lookups: lookups, offsets: offsets, into: destination, pitch: pitch, layout: layout)
                }
            }
        }
        guard !overran else { throw DecodeError.truncated }

        // The predictors work on the transformed samples; the output is shifted back up.
        if header.pointTransform > 0 {
            let shift = UInt16(header.pointTransform)
            for y in 0..<header.lines {
                for x in 0..<header.samplesPerLine {
                    let mcu = destination + y * layout.rowStep * pitch + x * layout.columnStep
                    for c in 0..<count { mcu[offsets[c]] <<= shift }
                }
            }
        }
    }

    /// The scan's samples, line by line: each difference added to its prediction (H.1.2.1).
    /// Returns whether the stream ran out before the last sample.
    private static func scan(_ header: Header, _ start: BitReader, lookups: UnsafeBufferPointer<UnsafePointer<UInt16>>,
                             offsets: UnsafeBufferPointer<Int>, into destination: UnsafeMutablePointer<UInt16>,
                             pitch: Int, layout: Layout) throws -> Bool {
        var reader = start
        let count = offsets.count
        let left = layout.columnStep
        let up = layout.rowStep &* pitch
        let initial = 1 << (header.precision - header.pointTransform - 1)
        let predictor = header.predictor
        let linesPerInterval = header.restartInterval > 0 ? header.restartInterval / header.samplesPerLine : Int.max
        var restarts = 0
        for y in 0..<header.lines {
            if reader.invalid { throw DecodeError.malformed("invalid Huffman code") }
            var firstLine = y == 0
            if y > 0, y % linesPerInterval == 0 {
                try reader.restart(expecting: restarts)
                restarts += 1
                firstLine = true
            }
            let row = destination + y &* up
            // The first sample of a line predicts from the line above, or from nothing on the
            // first line of the scan or of a restart interval.
            for c in 0..<count {
                let sample = row + offsets[c]
                let prediction = firstLine ? initial : Int(sample[-up])
                sample.pointee = UInt16(truncatingIfNeeded: prediction &+ reader.difference(lookups[c]))
            }
            if (firstLine || predictor == 1) && count == 4 {
                // One-dimensional over the four interleaved components of a Bayer quad, unrolled.
                let (l0, l1, l2, l3) = (lookups[0], lookups[1], lookups[2], lookups[3])
                let (o0, o1, o2, o3) = (offsets[0], offsets[1], offsets[2], offsets[3])
                var mcu = row + left
                for _ in 1..<max(1, header.samplesPerLine) {
                    mcu[o0] = UInt16(truncatingIfNeeded: Int(mcu[o0 &- left]) &+ reader.difference(l0))
                    mcu[o1] = UInt16(truncatingIfNeeded: Int(mcu[o1 &- left]) &+ reader.difference(l1))
                    mcu[o2] = UInt16(truncatingIfNeeded: Int(mcu[o2 &- left]) &+ reader.difference(l2))
                    mcu[o3] = UInt16(truncatingIfNeeded: Int(mcu[o3 &- left]) &+ reader.difference(l3))
                    mcu += left
                }
                continue
            }
            if firstLine || predictor == 1 {
                // One-dimensional: the sample to the left.
                for x in 1..<max(1, header.samplesPerLine) {
                    let mcu = row + x &* left
                    for c in 0..<count {
                        let sample = mcu + offsets[c]
                        sample.pointee = UInt16(truncatingIfNeeded: Int(sample[-left]) &+ reader.difference(lookups[c]))
                    }
                }
                continue
            }
            for x in 1..<max(1, header.samplesPerLine) {
                let mcu = row + x &* left
                for c in 0..<count {
                    let sample = mcu + offsets[c]
                    let a = Int(sample[-left]), b = Int(sample[-up]), d = Int(sample[-up - left])
                    let prediction: Int
                    switch predictor {
                    case 2: prediction = b
                    case 3: prediction = d
                    case 4: prediction = a &+ b &- d
                    case 5: prediction = a &+ ((b &- d) >> 1)
                    case 6: prediction = b &+ ((a &- d) >> 1)
                    default: prediction = (a &+ b) >> 1
                    }
                    // Modulo 2^16 (H.2.1).
                    sample.pointee = UInt16(truncatingIfNeeded: prediction &+ reader.difference(lookups[c]))
                }
            }
        }
        if reader.invalid { throw DecodeError.malformed("invalid Huffman code") }
        return reader.overran
    }
}

/// Entropy-coded bits, most significant first, with the 0xFF 0x00 stuffing taken out.
///
/// At a marker, or at the end of the bytes, it feeds zeros and remembers whether any of them
/// were used, which is a truncated stream.
struct BitReader {
    private let base: UnsafePointer<UInt8>
    private(set) var position: Int
    private let end: Int
    /// Unread bits, left-aligned.
    private var buffer: UInt64 = 0
    private var available = 0
    private var atMarker = false
    private var zeroBytes = 0
    /// Set when the bits matched no code of the table.
    private(set) var invalid = false

    init(base: UnsafePointer<UInt8>, position: Int, end: Int) {
        self.base = base
        self.position = position
        self.end = end
    }

    /// True when a decode used bits that were not in the stream.
    var overran: Bool { zeroBytes * 8 > available }

    /// Tops the buffer up past 56 bits. Called when fewer than 32 remain, the most one
    /// difference can use (a 16-bit code and 16 extra bits), so it runs every few samples.
    @inline(__always)
    private mutating func refill() {
        // Eight bytes at a time when none of them is 0xFF, which is most of the time.
        if !atMarker && position &+ 8 <= end {
            let word = UInt64(bigEndian: UnsafeRawPointer(base + position).loadUnaligned(as: UInt64.self))
            let inverted = ~word
            if (inverted &- 0x0101_0101_0101_0101) & ~inverted & 0x8080_8080_8080_8080 == 0 {
                let bytes = (64 &- available) >> 3
                let bits = bytes << 3
                // Masking shifts throughout: every amount here is within 0...63.
                buffer |= (word &>> UInt64(64 &- bits)) &<< UInt64(64 &- available &- bits)
                available &+= bits
                position &+= bytes
                return
            }
        }
        while available <= 56 {
            var byte: UInt64 = 0
            if !atMarker && position < end {
                let b = base[position]
                if b != 0xFF {
                    byte = UInt64(b)
                    position &+= 1
                } else if position + 1 < end && base[position + 1] == 0 {
                    byte = 0xFF
                    position &+= 2
                } else {
                    atMarker = true
                    zeroBytes &+= 1
                }
            } else {
                zeroBytes &+= 1
            }
            buffer |= byte &<< UInt64(56 &- available)
            available &+= 8
        }
    }

    /// One Huffman-coded difference category and its extra bits, as the signed difference (H.1.2.2).
    /// A bit pattern that is no code sets `invalid` and reads as 0; the caller checks once a line.
    @inline(__always)
    mutating func difference(_ lookup: UnsafePointer<UInt16>) -> Int {
        if available < 32 { refill() }
        let entry = lookup[Int(truncatingIfNeeded: buffer >> 48)]
        let length = Int(entry >> 8)
        if length == 0 {
            invalid = true
            return 0
        }
        buffer &<<= UInt64(length)
        available &-= length
        let category = Int(entry & 0xFF)
        if category == 0 { return 0 }
        if category == 16 { return 32768 }
        let bits = Int(truncatingIfNeeded: buffer &>> UInt64(64 &- category))
        buffer &<<= UInt64(category)
        available &-= category
        return bits < 1 &<< (category &- 1) ? bits &- (1 &<< category) &+ 1 : bits
    }

    /// The end of a restart interval: drop the padding bits and step over RSTn, where n counts
    /// the restarts so far modulo 8 (F.1.2.3, H.1.1).
    mutating func restart(expecting count: Int) throws {
        guard !overran else { throw LosslessJPEG.DecodeError.truncated }
        // Bits pulled into the buffer past the interval's end are padding; anything the buffer
        // had not reached yet would be data the interval did not use.
        buffer = 0
        available = 0
        atMarker = false
        zeroBytes = 0
        while position < end, base[position] == 0xFF, position + 1 < end, base[position + 1] == 0xFF { position += 1 }
        guard position + 1 < end, base[position] == 0xFF else { throw LosslessJPEG.DecodeError.malformed("no RST marker where a restart interval ends") }
        let marker = Int(base[position + 1])
        guard marker == 0xD0 + count % 8 else {
            throw LosslessJPEG.DecodeError.malformed(String(format: "RST%d where RST%d was due", marker - 0xD0, count % 8))
        }
        position += 2
    }
}
