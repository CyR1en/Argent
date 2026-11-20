import CoreImage
import Foundation
import Metal
import Testing
@testable import ArgentCore

/// A TIFF value for the builder below.
private enum TIFFValue {
    case short([UInt16])
    case long([UInt32])
    case rational([(UInt32, UInt32)])
    case ascii(String)
}

/// Writes a minimal TIFF: a header, IFD0 with the given entries and a SubIFDs tag, then one
/// IFD per entry of `subs`, each followed by its out-of-line values.
private func makeTIFF(littleEndian: Bool, ifd0: [(UInt16, TIFFValue)], subs: [[(UInt16, TIFFValue)]]) -> Data {
    func u16(_ v: UInt16) -> [UInt8] { littleEndian ? [UInt8(v & 0xFF), UInt8(v >> 8)] : [UInt8(v >> 8), UInt8(v & 0xFF)] }
    func u32(_ v: UInt32) -> [UInt8] {
        let bytes = (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) }
        return littleEndian ? bytes : bytes.reversed()
    }
    func encode(_ value: TIFFValue) -> (type: UInt16, count: UInt32, bytes: [UInt8]) {
        switch value {
        case .short(let v): return (3, UInt32(v.count), v.flatMap(u16))
        case .long(let v): return (4, UInt32(v.count), v.flatMap(u32))
        case .rational(let v): return (5, UInt32(v.count), v.flatMap { u32($0.0) + u32($0.1) })
        case .ascii(let s): let b = Array(s.utf8) + [0]; return (2, UInt32(b.count), b)
        }
    }
    func ifd(_ entries: [(UInt16, TIFFValue)], at offset: Int) -> [UInt8] {
        let sorted = entries.sorted { $0.0 < $1.0 }
        let tableSize = 2 + sorted.count * 12 + 4
        var table = u16(UInt16(sorted.count))
        var data: [UInt8] = []
        for (tag, value) in sorted {
            let encoded = encode(value)
            table += u16(tag) + u16(encoded.type) + u32(encoded.count)
            if encoded.bytes.count <= 4 {
                table += encoded.bytes + [UInt8](repeating: 0, count: 4 - encoded.bytes.count)
            } else {
                table += u32(UInt32(offset + tableSize + data.count))
                data += encoded.bytes
                if data.count % 2 == 1 { data.append(0) }
            }
        }
        return table + u32(0) + data
    }

    let header = (littleEndian ? [0x49, 0x49] : [0x4D, 0x4D]) + u16(42) + u32(8)
    // IFD0's size does not depend on the SubIFD offsets it holds, so lay it out once with
    // placeholders, then again with the real offsets.
    let placeholder = ifd(ifd0 + [(0x014A, .long([UInt32](repeating: 0, count: subs.count)))], at: 8)
    var offsets: [UInt32] = []
    var cursor = 8 + placeholder.count
    var subBytes: [UInt8] = []
    for sub in subs {
        offsets.append(UInt32(cursor))
        let bytes = ifd(sub, at: cursor)
        subBytes += bytes
        cursor += bytes.count
    }
    let first = ifd(ifd0 + [(0x014A, .long(offsets))], at: 8)
    return Data(header + first + subBytes)
}

private func writeTemporary(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("argent-layout-\(UUID().uuidString).arw")
    try data.write(to: url)
    return url
}

/// The full-frame lossless S raw IFD of the a7 IV sample, as the camera writes it.
private let fullFrameSmall: [(UInt16, TIFFValue)] = [
    (0x00FE, .long([0])), (0x0100, .short([3584])), (0x0101, .short([2560])),
    (0x0103, .short([7])), (0x0106, .short([6])),
    (0x7038, .short([3516, 2344])), (0xC61F, .short([6, 4])), (0xC620, .short([3504, 2336])),
]

@Suite struct ARWLayoutTests {
    @Test func readsTheRawIFDOfALosslessSmallFile() throws {
        let url = try writeTemporary(makeTIFF(littleEndian: true, ifd0: [(0x0110, .ascii("ILCE-7M4"))],
                                              subs: [fullFrameSmall]))
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = try ARWLayout.read(from: url)
        #expect(layout == ARWLayout(model: "ILCE-7M4", encoding: .losslessYCbCr, cropOrigin: .init(x: 6, y: 4),
                                    cropSize: .init(width: 3504, height: 2336), validSize: .init(width: 3516, height: 2344)))
    }

    @Test func readsBigEndianRationalsAndSonysOwnCropTags() throws {
        // No DNG crop tags, so the Sony copies are read, here as rationals and longs.
        let sub: [(UInt16, TIFFValue)] = [
            (0x00FE, .long([0])), (0x0100, .long([7040])), (0x0101, .long([4688])),
            (0x0103, .short([7])), (0x0106, .short([32803])),
            (0x74C7, .rational([(24, 2), (8, 1)])), (0x74C8, .long([7008, 4672])),
        ]
        let url = try writeTemporary(makeTIFF(littleEndian: false, ifd0: [(0x0110, .ascii("ILCE-7M4"))], subs: [sub]))
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = try ARWLayout.read(from: url)
        #expect(layout.encoding == .losslessBayer)
        #expect(layout.cropOrigin == .init(x: 12, y: 8))
        #expect(layout.cropSize == .init(width: 7008, height: 4672))
        #expect(layout.validSize == nil)
    }

    @Test func skipsAReducedSubIFDAndReadsEachEncoding() throws {
        let preview: [(UInt16, TIFFValue)] = [(0x00FE, .long([1])), (0x0103, .short([6])), (0x0106, .short([6]))]
        for (compression, photometric, expected) in [(1, 32803, ARWLayout.Encoding.uncompressed),
                                                     (32767, 32803, .compressed), (7, 32803, .losslessBayer),
                                                     (7, 6, .losslessYCbCr)] {
            let raw: [(UInt16, TIFFValue)] = [(0x00FE, .long([0])), (0x0100, .short([7040])), (0x0101, .short([4688])),
                                              (0x0103, .short([UInt16(compression)])), (0x0106, .short([UInt16(photometric)]))]
            let url = try writeTemporary(makeTIFF(littleEndian: true, ifd0: [], subs: [preview, raw]))
            defer { try? FileManager.default.removeItem(at: url) }
            let layout = try ARWLayout.read(from: url)
            #expect(layout.encoding == expected, "Compression \(compression)")
            // Without crop tags the crop is the stored size.
            #expect(layout.cropSize == .init(width: 7040, height: 4688))
            #expect(layout.model == "")
        }
    }

    @Test func refusesWhatIsNotARecognizableRaw() throws {
        let notTIFF = try writeTemporary(Data("not a tiff at all".utf8))
        defer { try? FileManager.default.removeItem(at: notTIFF) }
        #expect(throws: ARWLayout.ReadError.self) { try ARWLayout.read(from: notTIFF) }

        let jpegIFD: [(UInt16, TIFFValue)] = [(0x00FE, .long([0])), (0x0103, .short([6])), (0x0106, .short([6]))]
        let unknown = try writeTemporary(makeTIFF(littleEndian: true, ifd0: [], subs: [jpegIFD]))
        defer { try? FileManager.default.removeItem(at: unknown) }
        #expect(throws: ARWLayout.ReadError.self) { try ARWLayout.read(from: unknown) }

        let noSubIFD = try writeTemporary(makeTIFF(littleEndian: true, ifd0: [(0x0110, .ascii("X"))], subs: []))
        defer { try? FileManager.default.removeItem(at: noSubIFD) }
        #expect(throws: ARWLayout.ReadError.self) { try ARWLayout.read(from: noSubIFD) }

        // An IFD offset past the end of the file.
        var truncated = makeTIFF(littleEndian: true, ifd0: [], subs: [fullFrameSmall])
        truncated[4] = 0xFF
        truncated[5] = 0xFF
        let past = try writeTemporary(truncated)
        defer { try? FileManager.default.removeItem(at: past) }
        #expect(throws: ARWLayout.ReadError.self) { try ARWLayout.read(from: past) }
    }
}

@Suite struct RawModeTests {
    private let fullFrameS = ARWLayout(model: "ILCE-7M4", encoding: .losslessYCbCr, cropOrigin: .init(x: 6, y: 4),
                                       cropSize: .init(width: 3504, height: 2336), validSize: .init(width: 3516, height: 2344))
    private let apscS = ARWLayout(model: "ILCE-7M4", encoding: .losslessYCbCr, cropOrigin: .init(x: 32, y: 22),
                                  cropSize: .init(width: 3504, height: 2336), validSize: .init(width: 3568, height: 2380))
    private let fullFrameM = ARWLayout(model: "ILCE-7M4", encoding: .losslessYCbCr, cropOrigin: .init(x: 8, y: 4),
                                       cropSize: .init(width: 4608, height: 3072), validSize: .init(width: 4624, height: 3080))

    @Test func picksTheModeByEncodingAndCropSize() throws {
        let body = try #require(BodyProfile.named("ILCE-7M4"))
        #expect(body.mode(for: fullFrameS)?.name == "lossless S")
        #expect(body.mode(for: apscS)?.name == "lossless S")
        #expect(body.mode(for: fullFrameM)?.name == "lossless M")
        var large = fullFrameS
        large.encoding = .losslessBayer
        large.cropSize = .init(width: 7008, height: 4672)
        #expect(body.mode(for: large)?.name == "lossless L")
        var odd = fullFrameS
        odd.cropSize = .init(width: 2000, height: 1000)
        #expect(body.mode(for: odd) == nil)
        #expect(BodyProfile.named("ILCE-7M3") == nil)
    }

    /// The full-frame S trim covers the bad band measured at each scale (23 by 16, 13 by 9,
    /// 7 by 5 and 5 by 3) and keeps the frame 3:2.
    @Test func trimsFullFrameSmallPastItsValidData() throws {
        let small = try #require(BodyProfile.a7IV.mode(for: fullFrameS))
        let expected: [(Float, Int, Int)] = [(1, 24, 16), (0.5, 15, 10), (0.25, 9, 6), (0.125, 9, 6)]
        for (scale, columns, rows) in expected {
            let trim = small.trim(for: fullFrameS, scale: scale)
            #expect(trim.columns == columns && trim.rows == rows, "scale \(scale): \(trim)")
        }
        #expect(3504 - 24 == 3480 && 2336 - 16 == 2320 && 3480 * 2 == 2320 * 3)
    }

    /// Filled to the frame view's 1690 pixels, full-frame S is decoded at 1690 / 3480, which puts
    /// the full-size decode's 3480 columns on exactly those pixels. Its 16 trimmed rows end 7.770
    /// rows up; centring its 1126.667 rows scaled on the picture's 1127 moves that a sixth of a
    /// pixel down, so the picture starts at row 8 and samples 0.397 of a pixel below its rows. The
    /// bad data reaches 3 pixels past the overrun's 1691.94 columns and 6.80 rows.
    @Test func fillsFullFrameSmallWithTheFilesOwnArea() throws {
        let small = try #require(BodyProfile.a7IV.mode(for: fullFrameS))
        let picture = try #require(small.filled(for: fullFrameS, longSide: 1690))
        #expect(picture.scale == Float(1690) / Float(3480))
        #expect(picture.width == 1690 && picture.height == 1127 && picture.bottom == 8)
        #expect(abs(picture.rowPhase + 0.3966) < 0.0005, "\(picture.rowPhase)")
        #expect(picture.cleanWidth == 1688 && picture.cleanBottom == 10)

        // At every size up to the whole raw: exactly the asked pixels at 3:2, the rows within half a
        // pixel of the decode's, meeting the file's at the middle and within a sixth of a pixel at
        // the ends, and at most two columns and four rows given over to the bad data from 900 on.
        for longSide in 300..<3480 {
            let p = try #require(small.filled(for: fullFrameS, longSide: longSide))
            let s = Double(p.scale)
            let height = Int((Double(longSide) * 2 / 3).rounded())
            // Where the picture's rows sample the decode at its lower edge, middle and top, and the
            // trimmed picture's edges and middle scaled: 16, 1176 and 2336 rows up the window.
            let start: Double = Double(p.bottom) + p.rowPhase
            let middle: Double = start + Double(p.height) / 2, top: Double = start + Double(p.height)
            let lowerError: Double = abs(start - 16 * s), middleError: Double = abs(middle - 1176 * s)
            let upperError: Double = abs(top - 2336 * s)
            let lastClean: Double = 3484 * s - RawMode.scaledSpillReach, firstClean: Double = 14 * s + RawMode.scaledSpillReach
            #expect(p.width == longSide && p.height == height, "\(longSide)")
            #expect(abs(p.rowPhase) <= 0.5, "\(longSide)")
            #expect(middleError < 1e-9, "\(longSide)")
            #expect(lowerError <= 1.0 / 6 + 0.001 && upperError <= 1.0 / 6 + 0.001, "\(longSide)")
            #expect(Double(p.cleanWidth) <= lastClean && Double(p.cleanBottom) >= firstClean, "\(longSide)")
            if longSide >= 900 {
                let columns = p.width - p.cleanWidth, rows = p.cleanBottom - p.bottom
                #expect(columns <= 2 && rows <= 4, "\(longSide)")
            }
        }

        // As long as the trimmed raw or longer: the whole raw at full size, trimmed as a develop is.
        for longSide in [3480, 3500, 4000] {
            #expect(small.filled(for: fullFrameS, longSide: longSide)
                    == RawMode.FilledPicture(scale: 1, width: 3480, height: 2320, bottom: 16, rowPhase: 0, cleanWidth: 3480, cleanBottom: 16))
        }
        // Modes without a trim decode as they would anyway.
        let apsc = try #require(BodyProfile.a7IV.mode(for: apscS)), medium = try #require(BodyProfile.a7IV.mode(for: fullFrameM))
        #expect(apsc.filled(for: apscS, longSide: 1690) == nil && medium.filled(for: fullFrameM, longSide: 1690) == nil)
        var unknownValid = fullFrameS
        unknownValid.validSize = nil
        #expect(small.filled(for: unknownValid, longSide: 1690) == nil)
    }

    @Test func leavesModesThatStayInsideTheirValidDataAlone() throws {
        let small = try #require(BodyProfile.a7IV.mode(for: apscS))
        #expect(small.trim(for: apscS, scale: 1) == (0, 0))
        let medium = try #require(BodyProfile.a7IV.mode(for: fullFrameM))
        #expect(medium.trim(for: fullFrameM, scale: 1) == (0, 0))
        var unknownValid = fullFrameS
        unknownValid.validSize = nil
        #expect(small.trim(for: unknownValid, scale: 1) == (0, 0))
    }

    @Test func theReducedLosslessModesDecodeDarkerToMeetL() {
        let modes = Dictionary(uniqueKeysWithValues: BodyProfile.a7IV.modes.map { ($0.name, $0.exposureStops) })
        #expect(modes["lossless M"] == -0.26)
        #expect(modes["lossless S"] == -0.27)
        for name in ["uncompressed", "compressed", "lossless L"] { #expect(modes[name] == 0) }
    }
}

/// Runs only where the CC0 sample raws from `scripts/fetch-samples.sh` are present.
@Suite struct RawModeSampleTests {
    private static let samples = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("samples")
    private static func sample(_ name: String) -> URL { samples.appendingPathComponent("ILCE-7M4_\(name).ARW") }
    private static let small = sample("DSC06676_FullFrame-LossLess-Compressed-Small")
    private static let medium = sample("DSC06675_FullFrame-LossLess-Compressed-Medium")
    private static var hasSamples: Bool { FileManager.default.fileExists(atPath: small.path) }

    @Test(.enabled(if: RawModeSampleTests.hasSamples))
    func readsEveryModeOfTheSamples() throws {
        let expected: [(String, String, ARWLayout.Size)] = [
            ("DSC06673_FullFrame-Raw-Uncompressed", "uncompressed", .init(width: 7008, height: 4672)),
            ("DSC06674_FullFrame-LossLess-Compressed-Large", "lossless L", .init(width: 7008, height: 4672)),
            ("DSC06675_FullFrame-LossLess-Compressed-Medium", "lossless M", .init(width: 4608, height: 3072)),
            ("DSC06676_FullFrame-LossLess-Compressed-Small", "lossless S", .init(width: 3504, height: 2336)),
            ("DSC06677_FullFrame-Raw-Compressed", "compressed", .init(width: 7008, height: 4672)),
        ]
        let clock = ContinuousClock()
        for (file, mode, size) in expected {
            let start = clock.now
            let layout = try ARWLayout.read(from: Self.sample(file))
            let elapsed = (clock.now - start).milliseconds
            print(String(format: "MEASURE ARWLayout.read %@: %.3f ms", file, elapsed))
            #expect(elapsed < 5)
            #expect(layout.model == "ILCE-7M4")
            #expect(layout.cropSize == size, "\(file)")
            #expect(BodyProfile.a7IV.mode(for: layout)?.name == mode, "\(file)")
        }
        let small = try ARWLayout.read(from: Self.small)
        #expect(small.cropOrigin == .init(x: 6, y: 4) && small.validSize == .init(width: 3516, height: 2344))
    }

    private func halves(_ texture: MTLTexture) -> [Float16] {
        let width = texture.width, height = texture.height
        var halves = [Float16](repeating: 0, count: width * height * 4)
        halves.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return halves
    }

    /// Counts pixels per edge line that are out of range: a channel above 6, past the
    /// highlight-recovery ceiling after the gain, or below -0.1.
    private func badFraction(_ texture: MTLTexture, column: Int? = nil, row: Int? = nil) -> Double {
        let width = texture.width, height = texture.height
        let halves = halves(texture)
        let points: [(Int, Int)] = column.map { x in (0..<height).map { (x, $0) } } ?? (0..<width).map { ($0, row!) }
        var bad = 0
        for (x, y) in points {
            let i = (y * width + x) * 4
            let rgb = [Float(halves[i]), Float(halves[i + 1]), Float(halves[i + 2])]
            if rgb.contains(where: { !$0.isFinite || $0 > 6 || $0 < -0.1 }) { bad += 1 }
        }
        return Double(bad) / Double(points.count)
    }

    @Test(.enabled(if: RawModeSampleTests.hasSamples))
    func fullFrameSmallDecodesTrimmedWithACleanEdge() throws {
        let gpu = try GPU()
        for scale: Float in [1, 0.25] {
            var options = DecodeOptions()
            options.scale = scale
            let frame = try AppleRawDecoder(gpu: gpu).decode(Self.small, options: options)
            let pins = try #require(frame.pins)
            #expect(pins.rawMode == "lossless S")
            #expect(pins.modeExposureStops == -0.27)
            if scale == 1 {
                #expect(frame.width == 3480 && frame.height == 2320)
                #expect(pins.trimColumns == 24 && pins.trimRows == 16)
            }
            for k in 1...3 {
                #expect(badFraction(frame.texture, column: frame.width - k) < 0.01, "scale \(scale), column -\(k)")
                #expect(badFraction(frame.texture, row: frame.height - k) < 0.01, "scale \(scale), row -\(k)")
            }
        }
    }

    /// Asked to fill its long side, a lossless S decode makes up the trim and is exactly as long
    /// as asked, at the scale that puts the full-size decode's 3480 columns on it, clean past the
    /// bad data and 3:2 to the pixel; otherwise the trim leaves it short. Where it lies against the
    /// file is `FrameViewRegistrationSampleTests`.
    @Test(.enabled(if: RawModeSampleTests.hasSamples))
    func fullFrameSmallFillsTheLongSideItIsAskedFor() throws {
        let gpu = try GPU()
        let decoder = AppleRawDecoder(gpu: gpu)
        for longSide in [900, 2190, 2600, 3000] {
            var options = DecodeOptions()
            options.maxLongSide = longSide
            let short = try decoder.decode(Self.small, options: options)
            #expect(short.width < longSide)
            options.fillsMaxLongSide = true
            let frame = try decoder.decode(Self.small, options: options)
            let pins = try #require(frame.pins)
            let height = Int((Double(longSide) * 2 / 3).rounded())
            #expect(frame.width == longSide && abs(frame.height - height) <= 1, "\(longSide): \(frame.width) by \(frame.height)")
            #expect(pins.trimColumns > 0 && pins.scale > short.scale && pins.scale == Float(longSide) / Float(3480))
            for k in 1...3 {
                #expect(badFraction(frame.texture, column: frame.width - k) < 0.01, "\(longSide), column -\(k)")
                #expect(badFraction(frame.texture, row: frame.height - k) < 0.01, "\(longSide), row -\(k)")
            }
        }
        // Larger than the raw: the whole raw, trimmed, as without the option.
        var options = DecodeOptions()
        options.maxLongSide = 4000
        options.fillsMaxLongSide = true
        let whole = try decoder.decode(Self.small, options: options)
        #expect(whole.scale == 1 && whole.width == 3480)
    }

    /// A copy of `url` in `directory` with every top-level IFD's Orientation set to
    /// `orientation`, as the camera writes a frame shot turned: Core Image follows IFD1's tag
    /// and `ARWFrameInfo` IFD0's (measured), and the a7 IV writes the same value in all three.
    private func turnedCopy(of url: URL, _ orientation: CGImagePropertyOrientation, in directory: URL) throws -> URL {
        var data = try Data(contentsOf: url)
        let littleEndian = data[0] == 0x49
        func integer(_ at: Int, _ size: Int) -> Int {
            (0..<size).reduce(0) { value, i in value | Int(data[at + (littleEndian ? i : size - 1 - i)]) << (8 * i) }
        }
        var offset = integer(4, 4), patched = 0
        while offset != 0 {
            let count = integer(offset, 2)
            for i in 0..<count where integer(offset + 2 + 12 * i, 2) == 0x0112 {
                let at = offset + 2 + 12 * i + 8, value = UInt16(orientation.rawValue)
                data[at] = UInt8(littleEndian ? value & 0xFF : value >> 8)
                data[at + 1] = UInt8(littleEndian ? value >> 8 : value & 0xFF)
                patched += 1
            }
            offset = integer(offset + 2 + 12 * count, 4)
        }
        #expect(patched == 3)
        let copy = directory.appendingPathComponent("turned-\(orientation.rawValue).ARW")
        try data.write(to: copy)
        return copy
    }

    /// A texture's pixels, each its four half floats as one word, bottom row first.
    private func words(_ texture: MTLTexture) -> [UInt64] {
        var words = [UInt64](repeating: 0, count: texture.width * texture.height)
        words.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: texture.width * 8,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return words
    }

    /// `pixels`, `width` by `height` and bottom row first as a texture holds them, turned
    /// upright for `orientation` as Exif defines it, top down.
    private func turned(_ pixels: [UInt64], width: Int, height: Int, _ orientation: CGImagePropertyOrientation) -> [UInt64] {
        let swaps = orientation == .right || orientation == .left
        let outWidth = swaps ? height : width, outHeight = swaps ? width : height
        var out = [UInt64](repeating: 0, count: pixels.count)
        for y in 0..<outHeight {
            for x in 0..<outWidth {
                // In top-down picture coordinates, the stored pixel that shows at (x, y).
                let source: (x: Int, y: Int)
                switch orientation {
                case .down: source = (width - 1 - x, height - 1 - y)
                case .right: source = (y, height - 1 - x)
                case .left: source = (width - 1 - y, x)
                default: source = (x, y)
                }
                out[(outHeight - 1 - y) * outWidth + x] = pixels[(height - 1 - source.y) * width + source.x]
            }
        }
        return out
    }

    /// A lossless S frame shot turned keeps the trim on the sensor's right and bottom, wherever
    /// its orientation puts them: the decode is 2:3 or 3:2 to the pixel, clean on all four
    /// edges, and the upright decode turned, pixel for pixel. The copies differ from the sample
    /// only in their Orientation tags, so the layout, the embedded JPEGs and the raw agree.
    @Test(.enabled(if: RawModeSampleTests.hasSamples))
    func turnedSmallIsTrimmedOnTheSensorsEdges() throws {
        let gpu = try GPU()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("argent-turned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let decoder = AppleRawDecoder(gpu: gpu)
        var quarter = DecodeOptions()
        quarter.scale = 0.25
        var filled = DecodeOptions()
        filled.maxLongSide = 2190
        filled.fillsMaxLongSide = true
        let upright = try [quarter, filled].map { try decoder.decode(Self.small, options: $0) }
        #expect(upright[0].width == 867 && upright[0].height == 578)
        #expect(upright[1].width == 2190 && upright[1].height == 1460)

        for orientation: CGImagePropertyOrientation in [.down, .right, .left] {
            let url = try turnedCopy(of: Self.small, orientation, in: directory)
            let info = try ARWFrameInfo.read(from: url)
            #expect(info.orientation == orientation && info.isPortrait == (orientation != .down))
            #expect(try ARWLayout.read(from: url) == ARWLayout.read(from: Self.small))
            let preview = try EmbeddedJPEG.image(at: try #require(info.preview), in: url, maxPixelSize: 4096,
                                                 orientation: info.orientation)
            for (options, reference) in zip([quarter, filled], upright) {
                let frame = try decoder.decode(url, options: options)
                let pins = try #require(frame.pins)
                #expect(pins.trimColumns == reference.pins?.trimColumns && pins.trimRows == reference.pins?.trimRows)
                let (width, height) = info.isPortrait ? (reference.height, reference.width) : (reference.width, reference.height)
                #expect(frame.width == width && frame.height == height, "\(orientation): \(frame.width) by \(frame.height)")
                #expect((frame.width > frame.height) == (preview.width > preview.height))
                guard frame.width == width, frame.height == height else { continue }
                for k in 0..<3 {
                    for column in [k, frame.width - 1 - k] {
                        #expect(badFraction(frame.texture, column: column) < 0.01, "\(orientation), column \(column)")
                    }
                    for row in [k, frame.height - 1 - k] {
                        #expect(badFraction(frame.texture, row: row) < 0.01, "\(orientation), row \(row)")
                    }
                }
                let expected = turned(words(reference.texture), width: reference.width, height: reference.height, orientation)
                let differing = zip(words(frame.texture), expected).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
                #expect(differing == 0, "\(orientation) at \(frame.width) by \(frame.height): \(differing) pixels differ")
            }
        }
    }

    /// A canary: if a macOS update stops Apple's decoder reading past the valid data, the
    /// untrimmed edge comes out clean and the lossless S row in `BodyProfile.a7IV` should
    /// lose its `decoderCropOrigin`.
    @Test(.enabled(if: RawModeSampleTests.hasSamples))
    func applesDecoderStillReadsPastFullFrameSmall() throws {
        let filter = try #require(CIRAWFilter(imageURL: Self.small))
        var options = DecodeOptions()
        options.scale = 0.25
        AppleRawDecoder.configure(filter, options: options, iso: AppleRawDecoder.isoSpeed(of: filter))
        let image = try #require(filter.outputImage)
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])
        pixels.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16, bounds: extent, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
        }
        // The last column and the last row of the untrimmed decode, out of range as above.
        func bad(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return pixels[i..<(i + 3)].contains { !$0.isFinite || $0 > 6 || $0 < -0.1 }
        }
        let lastColumn = Double((0..<height).filter { bad(width - 1, $0) }.count) / Double(height)
        let lastRow = Double((0..<width).filter { bad($0, height - 1) }.count) / Double(width)
        #expect(lastColumn > 0.9,
                "Apple's decoder no longer reads past full-frame lossless S's valid data; drop the trim for lossless S")
        #expect(lastRow > 0.9)
    }

    @Test(.enabled(if: RawModeSampleTests.hasSamples))
    func losslessMediumCarriesItsOffsetAndNoTrim() throws {
        let gpu = try GPU()
        var options = DecodeOptions()
        options.scale = 0.25
        let frame = try AppleRawDecoder(gpu: gpu).decode(Self.medium, options: options)
        let pins = try #require(frame.pins)
        #expect(pins.rawMode == "lossless M" && pins.modeExposureStops == -0.26)
        #expect(pins.trimColumns == 0 && pins.trimRows == 0)
        #expect(frame.width == 1152 && frame.height == 768)
    }
}
