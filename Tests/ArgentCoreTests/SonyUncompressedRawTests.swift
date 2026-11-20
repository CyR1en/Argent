import Darwin
import Foundation
import Testing
@testable import ArgentCore

// MARK: Synthetic uncompressed files

/// The sample at stored position (x, y) in the synthetic uncompressed files: 14-bit, every value
/// distinct along a row and down a column.
func uncompressedSample(_ x: Int, _ y: Int) -> UInt16 { UInt16(512 + (x * 37 + y * 113 + (x ^ y) % 11) % 15000) }

/// A small synthetic uncompressed ARW: `width` by `height` samples (`uncompressedSample`) in
/// `strips` strips of whole rows, each a blob, after `gap` bytes of other data, with the a7 IV's tags
/// and a crop of everything but a margin of `origin`.
func syntheticUncompressedFile(width: Int = 48, height: Int = 32, strips: Int = 1, origin: (x: Int, y: Int) = (4, 2),
                               crop: (width: Int, height: Int)? = nil, overrides: [(UInt16, TIFFBuilder.Value)] = [],
                               model: String = "ILCE-7M4", fill: UInt16? = nil, samples: ((Int, Int) -> UInt16)? = nil) -> Data {
    let sample = samples ?? uncompressedSample
    let rowsPerStrip = (height + strips - 1) / strips
    var blobs: [Data] = [Data([1, 2, 3, 4, 5, 6])]
    for s in 0..<strips {
        let rows = (s * rowsPerStrip)..<min(height, (s + 1) * rowsPerStrip)
        if let fill {
            // One value everywhere, written at once: a full-size frame in a moment.
            let words = [UInt16](repeating: fill.littleEndian, count: rows.count * width)
            blobs.append(words.withUnsafeBytes { Data($0) })
            continue
        }
        var bytes = Data()
        for y in rows {
            for x in 0..<width { withUnsafeBytes(of: sample(x, y).littleEndian) { bytes.append(contentsOf: $0) } }
        }
        blobs.append(bytes)
    }
    let size = crop ?? (width - 2 * origin.x - 2, height - 2 * origin.y)
    var raw: [(UInt16, TIFFBuilder.Value)] = [
        (0x00FE, .long([0])), (0x0100, .long([UInt32(width)])), (0x0101, .long([UInt32(height)])),
        (0x0102, .short([14])), (0x0103, .short([1])), (0x0106, .short([32803])), (0x0115, .short([1])),
        (0x0116, .long([UInt32(rowsPerStrip)])),
        (0x828D, .short([2, 2])), (0x828E, .short([0, 1, 1, 2])),
        (0x7310, .short([512, 510, 514, 508])), (0xC61D, .short([16383])),
        (0xC61F, .short([UInt16(origin.x), UInt16(origin.y)])),
        (0xC620, .short([UInt16(size.0), UInt16(size.1)])),
    ]
    for (tag, value) in overrides {
        raw.removeAll { $0.0 == tag }
        raw.append((tag, value))
    }
    // The strip tables point at the blobs after the first; laid out with placeholders of the same
    // size first, as `syntheticLosslessFile` does.
    var builder = TIFFBuilder()
    builder.blobs = blobs
    let placeholder = [UInt32](repeating: 0, count: strips)
    let hasOffsets = overrides.contains { $0.0 == 0x0111 }, hasCounts = overrides.contains { $0.0 == 0x0117 }
    func ifd(_ offsets: [UInt32], _ counts: [UInt32]) -> [(UInt16, TIFFBuilder.Value)] {
        raw + (hasOffsets ? [] : [(0x0111, .long(offsets))]) + (hasCounts ? [] : [(0x0117, .long(counts))])
    }
    builder.ifds = [[(0x0110, .ascii(model)), (0x0112, .short([1])), (0x014A, .ifdOffset(1))], ifd(placeholder, placeholder)]
    builder.chain = [0]
    let first = builder.build()
    var cursor = first.count - blobs.reduce(0) { $0 + $1.count + $1.count % 2 }
    var offsets: [UInt32] = []
    for (i, blob) in blobs.enumerated() {
        if i > 0 { offsets.append(UInt32(cursor)) }
        cursor += blob.count + blob.count % 2
    }
    builder.ifds[1] = ifd(offsets, blobs.dropFirst().map { UInt32($0.count) })
    return builder.build()
}

@Suite struct SonyUncompressedRawTests {
    static let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples/ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW")
    /// The CC0 sample from `scripts/fetch-samples.sh`, required by the real-RAW regression suite.
    static var hasSample: Bool { FileManager.default.fileExists(atPath: sample.path) }

    /// The raw IFD: size, strips, CFA, the four black levels in CFA order, white, crop, and the valid
    /// area as the crop with its origin's margin on every side, the file writing none.
    @Test func readsTheRawIFD() throws {
        let url = try temporaryRaw(syntheticUncompressedFile())
        defer { try? FileManager.default.removeItem(at: url) }
        let raw = try SonyUncompressedRaw.read(from: url)
        #expect(raw.width == 48 && raw.height == 32)
        #expect(raw.stripOffsets.count == 1 && raw.stripByteCounts == [48 * 32 * 2] && raw.byteCount == 48 * 32 * 2)
        #expect(raw.cfa == [0, 1, 1, 2] && raw.blackLevels == [512, 510, 514, 508] && raw.whiteLevel == 16383)
        #expect(raw.cropOrigin == .init(x: 4, y: 2) && raw.cropSize == .init(width: 38, height: 28))
        #expect(raw.validSize == .init(width: 46, height: 32))
        #expect(raw.lens == nil)
        let layout = raw.mosaicLayout
        #expect(layout.pitch == 48 && layout.validSize == raw.validSize && layout.cropOrigin == raw.cropOrigin
                && layout.blackLevels == raw.blackLevels && layout.whiteLevel == 16383 && layout.cfa == raw.cfa)
    }

    /// A valid area the file writes is taken as written; the derived one never passes the stored frame.
    @Test func takesAWrittenValidAreaAndKeepsTheDerivedOneInside() throws {
        let written = try temporaryRaw(syntheticUncompressedFile(overrides: [(0x7038, .short([44, 31]))]))
        defer { try? FileManager.default.removeItem(at: written) }
        #expect(try SonyUncompressedRaw.read(from: written).validSize == .init(width: 44, height: 31))
        #expect(SonyUncompressedRaw.validSize(cropOrigin: .init(x: 12, y: 8), cropSize: .init(width: 7008, height: 4672),
                                              width: 7040, height: 4688) == .init(width: 7032, height: 4688))
        #expect(SonyUncompressedRaw.validSize(cropOrigin: .init(x: 44, y: 30), cropSize: .init(width: 4608, height: 3072),
                                              width: 4736, height: 3132) == .init(width: 4696, height: 3132))
        #expect(SonyUncompressedRaw.validSize(cropOrigin: .init(x: 10, y: 10), cropSize: .init(width: 20, height: 20),
                                              width: 32, height: 32) == .init(width: 32, height: 32))
    }

    /// Every sample lands at its stored position, read in place from the file or unpacked from it in
    /// memory, in one strip or in several with other data between.
    @Test(arguments: [1, 3, 32])
    func readsEverySampleInPlace(strips: Int) throws {
        let data = syntheticUncompressedFile(strips: strips)
        let url = try temporaryRaw(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let raw = try SonyUncompressedRaw.read(from: url)
        #expect(raw.stripOffsets.count == strips)
        var read = [UInt16](repeating: 0, count: 48 * 32), unpacked = read
        let descriptor = open(url.path, O_RDONLY)
        defer { close(descriptor) }
        try read.withUnsafeMutableBytes { try raw.readSamples(from: descriptor, into: $0.baseAddress!) }
        try data.withUnsafeBytes { file in try unpacked.withUnsafeMutableBytes { try raw.unpack(file, into: $0.baseAddress!) } }
        for y in 0..<32 {
            for x in 0..<48 { #expect(read[y * 48 + x] == uncompressedSample(x, y), "(\(x), \(y))") }
        }
        #expect(unpacked == read)
    }

    /// A file shortened after its structure was read is a short read, which the decoder reports as
    /// a damaged file, and never a crash.
    @Test func aFileCutShortIsAShortRead() throws {
        let data = syntheticUncompressedFile()
        let url = try temporaryRaw(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let raw = try SonyUncompressedRaw.read(from: url)
        try data.prefix(data.count - 100).write(to: url)
        var out = [UInt16](repeating: 0, count: 48 * 32)
        let descriptor = open(url.path, O_RDONLY)
        defer { close(descriptor) }
        #expect(throws: SonyUncompressedRaw.ReadFailure.short) {
            try out.withUnsafeMutableBytes { try raw.readSamples(from: descriptor, into: $0.baseAddress!) }
        }
        #expect(throws: SonyUncompressedRaw.ReadFailure.short) {
            try data.prefix(data.count - 100).withUnsafeBytes { file in try out.withUnsafeMutableBytes { try raw.unpack(file, into: $0.baseAddress!) } }
        }
        // Read again, the shortened file is refused before any read.
        #expect(throws: (any Error).self) { _ = try SonyUncompressedRaw.read(from: url) }
    }

    @Test func refusesLayoutsItCannotRead() throws {
        let cases: [(String, [(UInt16, TIFFBuilder.Value)])] = [
            ("lossless", [(0x0103, .short([7]))]),
            ("lossy compressed", [(0x0103, .short([32767]))]),
            ("YCbCr", [(0x0106, .short([6]))]),
            ("12 bits", [(0x0102, .short([12]))]),
            ("16 bits", [(0x0102, .short([16]))]),
            ("two samples a pixel", [(0x0115, .short([2]))]),
            ("odd width", [(0x0100, .long([47]))]),
            ("strips short of the frame", [(0x0117, .long([48 * 32 * 2 - 2]))]),
            ("strips past the end of the file", [(0x0111, .long([1 << 30]))]),
            ("no strips", [(0x0111, .long([])), (0x0117, .long([]))]),
            ("not Bayer", [(0x828E, .short([0, 1, 2, 1]))]),
            ("no black", [(0x7310, .short([512]))]),
            ("black above white", [(0x7310, .short([512, 512, 17000, 512]))]),
            ("white past 14 bits", [(0xC61D, .short([20000]))]),
            ("crop past the valid area", [(0xC620, .short([46, 28]))]),
            ("no crop", [(0xC61F, .short([4]))]),
        ]
        for (name, overrides) in cases {
            let url = try temporaryRaw(syntheticUncompressedFile(overrides: overrides))
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(throws: (any Error).self, "\(name)") { _ = try SonyUncompressedRaw.read(from: url) }
        }
        let tiles = (0..<6).map { syntheticTile($0 % 3, $0 / 3) }
        let lossless = try temporaryRaw(syntheticLosslessFile(across: 3, down: 2, tiles: tiles))
        defer { try? FileManager.default.removeItem(at: lossless) }
        #expect(throws: SonyUncompressedRaw.ReadError.notUncompressed) { _ = try SonyUncompressedRaw.read(from: lossless) }
    }

    /// A stored frame larger than a texture is refused before its length is computed.
    @Test func refusesAStoredFrameLargerThanATexture() throws {
        let side = UInt32(SonyLosslessRaw.largestSide * 2)
        let url = try temporaryRaw(syntheticUncompressedFile(overrides: [(0x0100, .long([side])), (0x0101, .long([side]))]))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: SonyUncompressedRaw.ReadError.unsupported("a stored frame of \(side) by \(side)")) {
            _ = try SonyUncompressedRaw.read(from: url)
        }
    }

    /// The CC0 uncompressed sample: 7040 by 4688 in one strip, the crop and levels lossless L has,
    /// a valid area of 7032 by 4688 (lossless L's 0x7038), past which the stored columns carry on the
    /// last two as a ramp, and the lens tags.
    @Test(.enabled(if: SonyUncompressedRawTests.hasSample))
    func readsTheSample() throws {
        let raw = try SonyUncompressedRaw.read(from: Self.sample)
        #expect(raw.width == 7040 && raw.height == 4688 && raw.stripOffsets.count == 1 && raw.byteCount == 7040 * 4688 * 2)
        #expect(raw.cfa == [0, 1, 1, 2] && raw.blackLevels == [512, 512, 512, 512] && raw.whiteLevel == 16383)
        #expect(raw.cropOrigin == .init(x: 12, y: 8) && raw.cropSize == InHouseColor.fullFrameCrop)
        #expect(raw.validSize == .init(width: 7032, height: 4688))
        let lens = try #require(raw.lens)
        #expect(lens.correctsDistortion)
        var mosaic = [UInt16](repeating: 0, count: raw.width * raw.height)
        let descriptor = open(Self.sample.path, O_RDONLY)
        defer { close(descriptor) }
        try mosaic.withUnsafeMutableBytes { try raw.readSamples(from: descriptor, into: $0.baseAddress!) }
        #expect(mosaic.max()! <= 16383 && mosaic.min()! >= 400)
        // The share of rows where a column is within 4 DN of the one two to its left: nearly all past
        // the valid area (0.96 and 0.97 measured), few inside it (0.04 to 0.06).
        func near(_ column: Int) -> Double {
            let rows = stride(from: 0, to: raw.height, by: 7)
            let close = rows.filter { abs(Int(mosaic[$0 * raw.width + column]) - Int(mosaic[$0 * raw.width + column - 2])) <= 4 }.count
            return Double(close) / Double(rows.underestimatedCount)
        }
        for column in [7034, 7036] { #expect(near(column) > 0.85, "column \(column): \(near(column))") }
        for column in 7026..<7032 { #expect(near(column) < 0.25, "column \(column): \(near(column))") }
    }
}
