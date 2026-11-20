import Foundation

/// A lossless JPEG encoder (ITU-T T.81 Annex H) for the decoder's tests: any predictor, point
/// transform and restart interval, one or more components sampled 1 by 1 and interleaved, one
/// Huffman table for every component.
struct LosslessJPEGEncoder {
    var precision = 14
    var predictor = 1
    var pointTransform = 0
    /// MCUs per restart interval, 0 for none; whole lines in a lossless scan.
    var restartInterval = 0
    /// Code lengths by the frequency rank of the 17 difference categories, most frequent first.
    /// The default leaves code space unused, so a run of 1 bits is no code.
    var lengths = [2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10]

    /// Encodes `planes`, one per component, each `lines` by `samplesPerLine` samples, row by row.
    /// Samples should be multiples of 2^pointTransform for an exact round trip.
    func encode(_ planes: [[Int]], lines: Int, samplesPerLine: Int) -> [UInt8] {
        let count = planes.count
        // Differences, in scan order, with the same prediction rules as the decoder (H.1.2.1).
        var differences: [Int] = []
        differences.reserveCapacity(count * lines * samplesPerLine)
        let initial = 1 << (precision - pointTransform - 1)
        let linesPerInterval = restartInterval > 0 ? restartInterval / samplesPerLine : Int.max
        for y in 0..<lines {
            let firstLine = y % linesPerInterval == 0
            for x in 0..<samplesPerLine {
                for c in 0..<count {
                    func at(_ xx: Int, _ yy: Int) -> Int { planes[c][yy * samplesPerLine + xx] >> pointTransform }
                    let prediction: Int
                    if firstLine {
                        prediction = x == 0 ? initial : at(x - 1, y)
                    } else if x == 0 {
                        prediction = at(x, y - 1)
                    } else {
                        let a = at(x - 1, y), b = at(x, y - 1), d = at(x - 1, y - 1)
                        switch predictor {
                        case 1: prediction = a
                        case 2: prediction = b
                        case 3: prediction = d
                        case 4: prediction = a + b - d
                        case 5: prediction = a + ((b - d) >> 1)
                        case 6: prediction = b + ((a - d) >> 1)
                        default: prediction = (a + b) >> 1
                        }
                    }
                    var d = (at(x, y) - prediction) & 0xFFFF
                    if d > 32768 { d -= 65536 }
                    differences.append(d)
                }
            }
        }

        // Categories ranked by frequency get the lengths in order; codes are canonical (C.2).
        func category(_ d: Int) -> Int {
            if d == 0 { return 0 }
            if d == 32768 { return 16 }
            var magnitude = abs(d), bits = 0
            while magnitude > 0 { bits += 1; magnitude >>= 1 }
            return bits
        }
        var frequency = [Int](repeating: 0, count: 17)
        for d in differences { frequency[category(d)] += 1 }
        let ranked = (0...16).sorted { frequency[$0] != frequency[$1] ? frequency[$0] > frequency[$1] : $0 < $1 }
        let order = ranked.enumerated().sorted { lengths[$0.offset] != lengths[$1.offset] ? lengths[$0.offset] < lengths[$1.offset] : $0.offset < $1.offset }
        var counts = [UInt8](repeating: 0, count: 16)
        var symbols: [UInt8] = []
        var codes = [(code: Int, length: Int)](repeating: (0, 0), count: 17)
        var code = 0, length = 1
        for (rank, symbol) in order {
            let l = lengths[rank]
            while length < l { code <<= 1; length += 1 }
            codes[symbol] = (code, l)
            counts[l - 1] += 1
            symbols.append(UInt8(symbol))
            code += 1
        }

        var out: [UInt8] = [0xFF, 0xD8]
        func segment(_ marker: UInt8, _ body: [UInt8]) {
            out += [0xFF, marker, UInt8((body.count + 2) >> 8), UInt8((body.count + 2) & 0xFF)] + body
        }
        segment(0xC4, [0x00] + counts + symbols)
        var frame: [UInt8] = [UInt8(precision), UInt8(lines >> 8), UInt8(lines & 0xFF), UInt8(samplesPerLine >> 8),
                              UInt8(samplesPerLine & 0xFF), UInt8(count)]
        for c in 0..<count { frame += [UInt8(c + 1), 0x11, 0] }
        segment(0xC3, frame)
        if restartInterval > 0 { segment(0xDD, [UInt8(restartInterval >> 8), UInt8(restartInterval & 0xFF)]) }
        var scan: [UInt8] = [UInt8(count)]
        for c in 0..<count { scan += [UInt8(c + 1), 0x00] }
        scan += [UInt8(predictor), 0, UInt8(pointTransform)]
        segment(0xDA, scan)

        var writer = BitWriter()
        var mcus = 0, restarts = 0
        for (i, d) in differences.enumerated() {
            if restartInterval > 0, i % count == 0, mcus > 0, mcus % restartInterval == 0 {
                writer.flush()
                out += writer.bytes
                writer = BitWriter()
                out += [0xFF, UInt8(0xD0 + restarts % 8)]
                restarts += 1
            }
            if i % count == count - 1 { mcus += 1 }
            let s = category(d)
            writer.write(codes[s].code, codes[s].length)
            if s > 0 && s < 16 { writer.write(d >= 0 ? d : d + (1 << s) - 1, s) }
        }
        writer.flush()
        out += writer.bytes
        out += [0xFF, 0xD9]
        return out
    }
}

/// Bits most significant first, with a 0 stuffed after every 0xFF and 1 bits to fill the last byte.
struct BitWriter {
    var bytes: [UInt8] = []
    private var accumulator = 0
    private var count = 0

    mutating func write(_ value: Int, _ length: Int) {
        for i in stride(from: length - 1, through: 0, by: -1) {
            accumulator = accumulator << 1 | (value >> i) & 1
            count += 1
            if count == 8 { emit() }
        }
    }

    mutating func flush() {
        while count != 0 {
            accumulator = accumulator << 1 | 1
            count += 1
            if count == 8 { emit() }
        }
    }

    private mutating func emit() {
        bytes.append(UInt8(accumulator))
        if accumulator == 0xFF { bytes.append(0) }
        accumulator = 0
        count = 0
    }
}
