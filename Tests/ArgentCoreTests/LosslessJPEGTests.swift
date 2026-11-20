import CoreImage
import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Random numbers that repeat from run to run.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Decodes `stream` with `layout` into a buffer of exactly the frame's extent.
private func decode(_ stream: [UInt8], layout: LosslessJPEG.Layout = .single) throws -> (samples: [UInt16], width: Int, height: Int) {
    try stream.withUnsafeBytes { bytes in
        let header = try LosslessJPEG.header(bytes)
        let extent = layout.extent(lines: header.lines, samplesPerLine: header.samplesPerLine)
        var out = [UInt16](repeating: 0, count: extent.width * extent.height)
        try out.withUnsafeMutableBufferPointer {
            try LosslessJPEG.decode(bytes, header: header, into: $0.baseAddress!, pitch: extent.width, layout: layout)
        }
        return (out, extent.width, extent.height)
    }
}

@Suite struct LosslessJPEGTests {
    /// Smooth gradients with noise, like a raw tile, and pure noise, which reaches every category.
    private func planes(count: Int, lines: Int, samples: Int, precision: Int, seed: UInt64, noise: Bool = false,
                        pointTransform: Int = 0) -> [[Int]] {
        var rng = SplitMix(state: seed)
        let top = 1 << precision
        return (0..<count).map { c in
            (0..<(lines * samples)).map { i in
                let x = i % samples, y = i / samples
                let value: Int
                if noise {
                    value = Int(rng.next() % UInt64(top))
                } else {
                    let base = (x * 37 + y * 53 + c * 1000) % (top / 2)
                    value = min(top - 1, max(0, base + Int(rng.next() % 64) - 32))
                }
                return (value >> pointTransform) << pointTransform
            }
        }
    }

    @Test(arguments: 1...7)
    func everyPredictorRoundTrips(predictor: Int) throws {
        for noise in [false, true] {
            let input = planes(count: 1, lines: 13, samples: 17, precision: 14, seed: UInt64(predictor), noise: noise)
            let stream = LosslessJPEGEncoder(precision: 14, predictor: predictor).encode(input, lines: 13, samplesPerLine: 17)
            let out = try decode(stream)
            #expect(out.width == 17 && out.height == 13)
            #expect(out.samples.map(Int.init) == input[0], "predictor \(predictor), noise \(noise)")
        }
    }

    /// Four interleaved components land at the corners of 2 by 2 quads, as in a Sony L tile.
    @Test func fourComponentsFillBayerQuads() throws {
        let lines = 6, samples = 9
        let input = planes(count: 4, lines: lines, samples: samples, precision: 14, seed: 7)
        let stream = LosslessJPEGEncoder(precision: 14, predictor: 1).encode(input, lines: lines, samplesPerLine: samples)
        let out = try decode(stream, layout: .bayerQuad)
        #expect(out.width == 2 * samples && out.height == 2 * lines)
        for y in 0..<out.height {
            for x in 0..<out.width {
                let component = (y & 1) * 2 + (x & 1)
                #expect(Int(out.samples[y * out.width + x]) == input[component][(y / 2) * samples + x / 2])
            }
        }
    }

    /// Two components side by side, the other interleaving a raw stream can use, through a
    /// two-dimensional predictor, which reads each component's own neighbours two samples away.
    @Test func twoComponentsSideBySide() throws {
        let layout = LosslessJPEG.Layout(columnStep: 2, rowStep: 1, columnOffsets: [0, 1], rowOffsets: [0, 0])
        let input = planes(count: 2, lines: 5, samples: 8, precision: 12, seed: 3)
        let stream = LosslessJPEGEncoder(precision: 12, predictor: 4).encode(input, lines: 5, samplesPerLine: 8)
        let out = try decode(stream, layout: layout)
        for y in 0..<5 { for x in 0..<16 { #expect(Int(out.samples[y * 16 + x]) == input[x & 1][y * 8 + x / 2]) } }
    }

    @Test(arguments: [1, 2, 3])
    func restartIntervalsResetThePrediction(lines interval: Int) throws {
        let samples = 11, lines = 9
        for predictor in [1, 6] {
            let input = planes(count: 4, lines: lines, samples: samples, precision: 14, seed: 11)
            var encoder = LosslessJPEGEncoder(precision: 14, predictor: predictor)
            encoder.restartInterval = interval * samples
            let stream = encoder.encode(input, lines: lines, samplesPerLine: samples)
            // The stream really carries RST markers, cycling through RST0 to RST7.
            let markers = zip(stream, stream.dropFirst()).filter { $0.0 == 0xFF && (0xD0...0xD7).contains($0.1) }.count
            #expect(markers == (lines - 1) / interval)
            let out = try decode(stream, layout: .bayerQuad)
            for y in 0..<(2 * lines) {
                for x in 0..<(2 * samples) {
                    #expect(Int(out.samples[y * 2 * samples + x]) == input[(y & 1) * 2 + (x & 1)][(y / 2) * samples + x / 2])
                }
            }
        }
    }

    /// A point transform codes the samples shifted down; the decoder shifts them back.
    @Test func pointTransformShiftsBack() throws {
        let input = planes(count: 1, lines: 8, samples: 8, precision: 14, seed: 5, pointTransform: 2)
        var encoder = LosslessJPEGEncoder(precision: 14, predictor: 7)
        encoder.pointTransform = 2
        let out = try decode(encoder.encode(input, lines: 8, samplesPerLine: 8))
        #expect(out.samples.map(Int.init) == input[0])
    }

    /// 16-bit samples need the 16th category, a difference of exactly 32768 with no extra bits,
    /// and differences that wrap modulo 2^16. Long codes with 15 extra bits need 31 bits at once.
    @Test func sixteenBitSamplesAndLongCodes() throws {
        let row = [0, 32768, 0, 32768, 65535, 0, 1, 65535, 40000, 7]
        let input = [Array((0..<4).map { _ in row }.joined())]
        var encoder = LosslessJPEGEncoder(precision: 16, predictor: 1)
        encoder.lengths = [1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 16, 16]
        let stream = encoder.encode(input, lines: 4, samplesPerLine: row.count)
        let out = try decode(stream)
        #expect(out.samples.map(Int.init) == input[0])
        let noise = planes(count: 1, lines: 16, samples: 16, precision: 16, seed: 9, noise: true)
        #expect(try decode(encoder.encode(noise, lines: 16, samplesPerLine: 16)).samples.map(Int.init) == noise[0])
    }

    @Test func readsTheHeader() throws {
        var encoder = LosslessJPEGEncoder(precision: 14, predictor: 6)
        encoder.restartInterval = 20
        let stream = encoder.encode(planes(count: 4, lines: 5, samples: 10, precision: 14, seed: 1), lines: 5, samplesPerLine: 10)
        let header = try stream.withUnsafeBytes { try LosslessJPEG.header($0) }
        #expect(header.precision == 14 && header.lines == 5 && header.samplesPerLine == 10)
        #expect(header.components.count == 4 && header.components.allSatisfy { $0.horizontalSampling == 1 && $0.table == 0 })
        #expect(header.predictor == 6 && header.pointTransform == 0 && header.restartInterval == 20)
    }

    // MARK: Damaged and unsupported streams

    private func stream() -> [UInt8] {
        LosslessJPEGEncoder(precision: 14, predictor: 1).encode(planes(count: 1, lines: 16, samples: 16, precision: 14, seed: 2),
                                                                lines: 16, samplesPerLine: 16)
    }

    private func error(_ bytes: [UInt8], layout: LosslessJPEG.Layout = .single) -> LosslessJPEG.DecodeError? {
        do {
            _ = try decode(bytes, layout: layout)
            return nil
        } catch let error as LosslessJPEG.DecodeError {
            return error
        } catch {
            return nil
        }
    }

    @Test func refusesWhatIsNotLosslessJPEG() {
        #expect(error([0x12, 0x34, 0x56, 0x78]) == .notJPEG)
        var baseline = stream()
        let sof = baseline.indices.first { baseline[$0] == 0xFF && baseline[$0 + 1] == 0xC3 }!
        baseline[sof + 1] = 0xC0
        #expect(error(baseline) == .unsupported("SOF0"))
    }

    /// A scan header with no body at the very end of the stream (review 4): refused, where it
    /// read a byte past the buffer.
    @Test func refusesAnEmptyScanHeaderAtTheEnd() {
        let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xC3, 0x00, 0x0B, 0x0E, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00,
                              0xFF, 0xDA, 0x00, 0x02]
        #expect(error(bytes) == .malformed("SOS length 2"))
    }

    @Test func refusesSubsamplingAndOddRestarts() {
        var subsampled = stream()
        let sof = subsampled.indices.first { subsampled[$0] == 0xFF && subsampled[$0 + 1] == 0xC3 }!
        subsampled[sof + 11] = 0x21
        #expect(error(subsampled) == .unsupported("component sampling 2 by 1"))

        var encoder = LosslessJPEGEncoder(precision: 14, predictor: 1)
        encoder.restartInterval = 16
        var odd = encoder.encode(planes(count: 1, lines: 4, samples: 16, precision: 14, seed: 4), lines: 4, samplesPerLine: 16)
        let dri = odd.indices.first { odd[$0] == 0xFF && odd[$0 + 1] == 0xDD }!
        odd[dri + 5] = 5
        #expect(error(odd) == .unsupported("a restart interval of 5 MCUs in lines of 16"))
    }

    @Test func refusesATruncatedStream() {
        let whole = stream()
        let scan = whole.indices.first { whole[$0] == 0xFF && whole[$0 + 1] == 0xDA }!
        let cut = Array(whole[..<(scan + 14 + (whole.count - scan) / 2)])
        #expect(error(cut) == .truncated)
        #expect(error(Array(whole[..<(scan + 3)])) == .truncated)
    }

    @Test func refusesBitsThatAreNoCode() {
        var bytes = stream()
        let scan = bytes.indices.first { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xDA }! + 10
        // A run of 1 bits: the encoder's lengths leave that code space unused.
        for i in (scan + 4)..<min(scan + 40, bytes.count - 2) where (i - scan) % 2 == 0 {
            bytes[i] = 0xFF
            bytes[i + 1] = 0x00
        }
        #expect(error(bytes) == .malformed("invalid Huffman code"))
    }

    @Test func refusesRestartMarkersOutOfOrder() {
        var encoder = LosslessJPEGEncoder(precision: 14, predictor: 1)
        encoder.restartInterval = 8
        var bytes = encoder.encode(planes(count: 1, lines: 6, samples: 8, precision: 14, seed: 6), lines: 6, samplesPerLine: 8)
        let second = bytes.indices.filter { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xD1 }.first!
        bytes[second + 1] = 0xD3
        #expect(error(bytes) == .malformed("RST3 where RST1 was due"))
    }

    @Test func refusesAMissingTableAndADestinationTooNarrow() throws {
        var bytes = stream()
        let dht = bytes.indices.first { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xC4 }!
        bytes[dht + 1] = 0xFE  // the DHT becomes an APP14 segment
        #expect(error(bytes) == .malformed("component 0 has no Huffman table"))

        let whole = stream()
        #expect(throws: LosslessJPEG.DecodeError.self) {
            try whole.withUnsafeBytes { raw in
                let header = try LosslessJPEG.header(raw)
                var out = [UInt16](repeating: 0, count: 16 * 16)
                try out.withUnsafeMutableBufferPointer { try LosslessJPEG.decode(raw, header: header, into: $0.baseAddress!, pitch: 8, layout: .single) }
            }
        }
    }
}

// MARK: The raw IFD and the tiles

/// The raw IFD of a small synthetic lossless L file: `across` by `down` tiles of 8 by 4, each
/// tile's stream a blob.
func syntheticLosslessFile(across: Int, down: Int, tiles: [[UInt8]], overrides: [(UInt16, TIFFBuilder.Value)] = [],
                          model: String = "ILCE-7M4") -> Data {
    var raw: [(UInt16, TIFFBuilder.Value)] = [
        (0x00FE, .long([0])), (0x0100, .long([UInt32(8 * across)])), (0x0101, .long([UInt32(4 * down)])),
        (0x0102, .short([14])), (0x0103, .short([7])), (0x0106, .short([32803])), (0x0115, .short([1])),
        (0x0142, .short([8])), (0x0143, .short([4])),
        (0x828D, .short([2, 2])), (0x828E, .short([0, 1, 1, 2])),
        (0x7310, .short([512, 510, 514, 508])), (0xC61D, .short([16383])),
        (0xC61F, .short([2, 2])), (0xC620, .short([UInt16(8 * across - 4), UInt16(4 * down - 4)])),
        (0x7038, .short([UInt16(8 * across - 1), UInt16(4 * down)])),
    ]
    for (tag, value) in overrides {
        raw.removeAll { $0.0 == tag }
        raw.append((tag, value))
    }
    // Tile offsets and counts point at the blobs; TIFFBuilder writes one blob offset a tag, so
    // the tables are laid out with placeholders of the same size, then written as plain longs.
    var builder = TIFFBuilder()
    builder.blobs = tiles.map { Data($0) }
    let placeholder = [UInt32](repeating: 0, count: tiles.count)
    builder.ifds = [[(0x0110, .ascii(model)), (0x014A, .ifdOffset(1))], raw + [(0x0144, .long(placeholder)), (0x0145, .long(placeholder))]]
    builder.chain = [0]
    let first = builder.build()
    // Blobs sit after the IFDs, so they start where the blobs' padded sizes say.
    var offsets: [UInt32] = []
    var cursor = first.count - tiles.reduce(0) { $0 + $1.count + $1.count % 2 }
    for tile in tiles {
        offsets.append(UInt32(cursor))
        cursor += tile.count + tile.count % 2
    }
    builder.ifds[1] = raw + [(0x0144, .long(offsets)), (0x0145, .long(tiles.map { UInt32($0.count) }))]
    let data = builder.build()
    return data
}

func temporaryRaw(_ data: Data, _ name: String = "argent-inhouse") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).arw")
    try data.write(to: url)
    return url
}

/// The sample value at stored position (x, y) in the synthetic files.
func syntheticSample(_ x: Int, _ y: Int) -> Int { 600 + x * 17 + y * 101 + (x ^ y) % 7 }

/// One 8 by 4 tile at tile position (tx, ty) as a lossless JPEG of four interleaved quad corners.
func syntheticTile(_ tx: Int, _ ty: Int) -> [UInt8] {
    let planes = (0..<4).map { c in
        (0..<(2 * 4)).map { i in syntheticSample(tx * 8 + (i % 4) * 2 + (c & 1), ty * 4 + (i / 4) * 2 + (c >> 1)) }
    }
    return LosslessJPEGEncoder(precision: 14, predictor: 1).encode(planes, lines: 2, samplesPerLine: 4)
}

@Suite struct SonyLosslessRawTests {
    static let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")
    /// The CC0 sample from `scripts/fetch-samples.sh`, required by `scripts/regression.sh`.
    static var hasSample: Bool { FileManager.default.fileExists(atPath: sample.path) }

    @Test func readsTheRawIFD() throws {
        let tiles = (0..<6).map { syntheticTile($0 % 3, $0 / 3) }
        let url = try temporaryRaw(syntheticLosslessFile(across: 3, down: 2, tiles: tiles))
        defer { try? FileManager.default.removeItem(at: url) }
        let raw = try SonyLosslessRaw.read(from: url)
        #expect(raw.width == 24 && raw.height == 8 && raw.tileWidth == 8 && raw.tileHeight == 4)
        #expect(raw.tilesAcross == 3 && raw.height / raw.tileHeight == 2 && raw.tileOffsets.count == 6)
        #expect(raw.cfa == [0, 1, 1, 2])
        #expect(raw.blackLevels == [512, 510, 514, 508] && raw.whiteLevel == 16383)
        #expect(raw.cropOrigin == .init(x: 2, y: 2) && raw.cropSize == .init(width: 20, height: 4))
        #expect(raw.validSize == .init(width: 23, height: 8))
    }

    /// Every tile lands at its own place in the mosaic, left to right and top to bottom.
    @Test func assemblesTheTiles() throws {
        let tiles = (0..<6).map { syntheticTile($0 % 3, $0 / 3) }
        let data = syntheticLosslessFile(across: 3, down: 2, tiles: tiles)
        let url = try temporaryRaw(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let raw = try SonyLosslessRaw.read(from: url)
        var mosaic = [UInt16](repeating: 0, count: raw.width * raw.height)
        try data.withUnsafeBytes { bytes in
            try mosaic.withUnsafeMutableBufferPointer { try raw.decodeTiles(bytes, into: $0.baseAddress!) }
        }
        for y in 0..<raw.height { for x in 0..<raw.width { #expect(Int(mosaic[y * raw.width + x]) == syntheticSample(x, y), "at \(x), \(y)") } }
    }

    @Test func namesTheTileThatFails() throws {
        var tiles = (0..<6).map { syntheticTile($0 % 3, $0 / 3) }
        tiles[4] = Array(tiles[4].prefix(tiles[4].count / 2))
        let data = syntheticLosslessFile(across: 3, down: 2, tiles: tiles)
        let url = try temporaryRaw(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let raw = try SonyLosslessRaw.read(from: url)
        var mosaic = [UInt16](repeating: 0, count: raw.width * raw.height)
        do {
            try data.withUnsafeBytes { bytes in
                try mosaic.withUnsafeMutableBufferPointer { try raw.decodeTiles(bytes, into: $0.baseAddress!) }
            }
            Issue.record("a truncated tile decoded")
        } catch let error as SonyLosslessRaw.TileError {
            #expect(error.tile == 4)
        }
    }

    /// A tile whose stream covers a different area than the IFD's tile size could write outside
    /// its place, so it is refused.
    @Test func refusesATileOfTheWrongSize() throws {
        let wrong = LosslessJPEGEncoder(precision: 14, predictor: 1).encode([[Int]](repeating: [Int](repeating: 600, count: 6), count: 4),
                                                                             lines: 2, samplesPerLine: 3)
        let tiles = [wrong] + (1..<6).map { syntheticTile($0 % 3, $0 / 3) }
        let data = syntheticLosslessFile(across: 3, down: 2, tiles: tiles)
        let url = try temporaryRaw(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let raw = try SonyLosslessRaw.read(from: url)
        var mosaic = [UInt16](repeating: 0, count: raw.width * raw.height)
        #expect(throws: SonyLosslessRaw.TileError.self) {
            try data.withUnsafeBytes { bytes in
                try mosaic.withUnsafeMutableBufferPointer { try raw.decodeTiles(bytes, into: $0.baseAddress!) }
            }
        }
    }

    /// A stored frame larger than a texture, in one tile (review 4): refused, where the decoder's
    /// mosaic length overflowed for a side of 2^31.
    @Test func refusesAStoredFrameLargerThanATexture() throws {
        let side = UInt32(SonyLosslessRaw.largestSide * 2)
        let overrides: [(UInt16, TIFFBuilder.Value)] = [
            (0x0100, .long([side])), (0x0101, .long([side])), (0x0142, .long([side])), (0x0143, .long([side])),
            (0xC620, .short([64, 64])), (0x7038, .long([side, side])),
        ]
        let url = try temporaryRaw(syntheticLosslessFile(across: 1, down: 1, tiles: [syntheticTile(0, 0)], overrides: overrides))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: SonyLosslessRaw.ReadError.unsupported("a stored frame of \(side) by \(side)")) {
            _ = try SonyLosslessRaw.read(from: url)
        }
    }

    @Test func refusesLayoutsItCannotDecode() throws {
        let tiles = (0..<6).map { syntheticTile($0 % 3, $0 / 3) }
        let cases: [(String, [(UInt16, TIFFBuilder.Value)])] = [
            ("uncompressed", [(0x0103, .short([1]))]),
            ("YCbCr", [(0x0106, .short([6]))]),
            ("not Bayer", [(0x828E, .short([0, 1, 2, 1]))]),
            ("no black", [(0x7310, .short([512]))]),
            ("black above white", [(0x7310, .short([512, 512, 17000, 512]))]),
            ("crop past the valid area", [(0xC620, .short([30, 4]))]),
            ("tiles short", [(0x0100, .long([32]))]),
        ]
        for (name, overrides) in cases {
            let url = try temporaryRaw(syntheticLosslessFile(across: 3, down: 2, tiles: tiles, overrides: overrides))
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(throws: (any Error).self, "\(name)") { _ = try SonyLosslessRaw.read(from: url) }
        }
    }

    /// The sample's raw IFD and its tiles: 140 tiles of 512, the mosaic within black and white,
    /// and the same samples the spike's decoder produced (its FNV-1a hash over the stored area;
    /// the spike was bit-exact with LibRaw, and `InHouseDecoderMeasureTests/tilesMatchTheSpike`
    /// compares sample by sample).
    @Test(.enabled(if: SonyLosslessRawTests.hasSample))
    func decodesTheSampleTiles() throws {
        let raw = try SonyLosslessRaw.read(from: Self.sample)
        #expect(raw.width == 7168 && raw.height == 5120 && raw.tileWidth == 512 && raw.tileHeight == 512)
        #expect(raw.tileOffsets.count == 140 && raw.cfa == [0, 1, 1, 2])
        #expect(raw.blackLevels == [512, 512, 512, 512] && raw.whiteLevel == 16383)
        #expect(raw.cropOrigin == .init(x: 12, y: 8) && raw.cropSize == .init(width: 7008, height: 4672))
        #expect(raw.validSize == .init(width: 7032, height: 4688))
        let file = try Data(contentsOf: Self.sample, options: .alwaysMapped)
        var mosaic = [UInt16](repeating: 0, count: raw.width * raw.height)
        try file.withUnsafeBytes { bytes in try mosaic.withUnsafeMutableBufferPointer { try raw.decodeTiles(bytes, into: $0.baseAddress!) } }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        var lowest = Int.max, highest = 0, clipped = 0
        for y in 0..<raw.height {
            for x in 0..<raw.width {
                let v = mosaic[y * raw.width + x]
                hash = (hash ^ UInt64(v)) &* 0x0000_0100_0000_01B3
                if x < raw.validSize.width, y < raw.validSize.height {
                    lowest = min(lowest, Int(v))
                    highest = max(highest, Int(v))
                    if Int(v) == raw.whiteLevel { clipped += 1 }
                }
            }
        }
        print(String(format: "MEASURE sample mosaic: FNV-1a %016llx, valid samples %d to %d, %d at white", hash, lowest, highest, clipped))
        #expect(hash == 0x164D_B99F_4E29_6244)
        #expect(lowest >= 480 && highest == raw.whiteLevel)
    }
}
