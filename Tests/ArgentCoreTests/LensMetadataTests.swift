import Foundation
import Testing
@testable import ArgentCore

@Suite struct LensMetadataTests {
    private static let shot: [(UInt16, TIFFBuilder.Value)] = [
        (0xA434, .ascii("Test 28-75mm F2.8")), (0xA432, .rational([(28, 1), (75, 1), (28, 10), (28, 10)])),
        (0x920A, .rational([(75, 1)])), (0x829D, .rational([(14, 10)])),
    ]

    private func uint32(_ data: Data, at: Int) -> Int {
        (0..<4).reduce(0) { $0 | Int(data[at + $1]) << (8 * $1) }
    }

    private func put(_ value: Int, at: Int, bytes: Int, in data: inout Data) {
        for i in 0..<bytes { data[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }

    private func entry(_ tag: UInt16, in data: Data, ifd: Int) -> Int {
        let count = Int(data[ifd]) | Int(data[ifd + 1]) << 8
        for i in 0..<count {
            let at = ifd + 2 + 12 * i
            if UInt16(data[at]) | UInt16(data[at + 1]) << 8 == tag { return at }
        }
        preconditionFailure("missing fixture tag \(tag)")
    }

    private func fixture(exif: [(UInt16, TIFFBuilder.Value)] = Self.shot,
                         blocks: [(UInt16, [UInt8])] = [],
                         raw: [(UInt16, TIFFBuilder.Value)] = []) -> Data {
        var builder = TIFFBuilder()
        builder.chain = [0]
        builder.ifds = [
            [(0x0110, .ascii("ILCE-7M4")), (0x8769, .ifdOffset(1)), (0x014A, .ifdOffset(2))],
            exif + (blocks.isEmpty ? [] : [(0x927C, .ifdOffset(3))]),
            [(0x0103, .short([7])), (0x0106, .short([32803])), (0x0100, .long([16])), (0x0101, .long([16]))] + raw,
            blocks.enumerated().map { ($0.element.0, .blobOffset($0.offset)) },
        ]
        builder.blobs = blocks.map { _, bytes in
            Data(bytes.map { $0 < 249 ? UInt8((Int($0) * Int($0) * Int($0)) % 249) : $0 })
        }
        var data = builder.build()
        if !blocks.isEmpty {
            let exifIFD = uint32(data, at: entry(0x8769, in: data, ifd: 8) + 8)
            let makerEntry = entry(0x927C, in: data, ifd: exifIFD)
            let makerIFD = uint32(data, at: makerEntry + 8)
            put(7, at: makerEntry + 2, bytes: 2, in: &data)
            put(2 + blocks.count * 12 + 4, at: makerEntry + 4, bytes: 4, in: &data)
            for (tag, bytes) in blocks {
                let at = entry(tag, in: data, ifd: makerIFD)
                put(7, at: at + 2, bytes: 2, in: &data)
                put(bytes.count, at: at + 4, bytes: 4, in: &data)
            }
        }
        return data
    }

    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("argent-lens-\(UUID().uuidString).arw")
        try data.write(to: url)
        return url
    }

    @Test func readsEXIFWithoutAMakerNote() throws {
        let url = try write(fixture())
        defer { try? FileManager.default.removeItem(at: url) }
        let lens = try LensMetadata.read(from: url)
        #expect(lens.lensModel == "Test 28-75mm F2.8")
        #expect(lens.lensSpecification == [28, 75, 2.8, 2.8])
        #expect(lens.focalLength == 75 && lens.fNumber == 1.4)
        #expect(lens.lensID == nil && lens.focusPositionRaw == nil && lens.focus == .unknown)
        #expect(lens.crop == .fullFrame)
        let frame = try ARWFrameInfo.read(from: url)
        #expect(frame.lensMetadata == lens && frame.fNumber == lens.fNumber)
    }

    @Test(arguments: [UInt16(0xA434), 0xA432, 0x920A, 0x829D])
    func missingEXIFTagStaysAbsent(_ tag: UInt16) throws {
        let url = try write(fixture(exif: Self.shot.filter { $0.0 != tag }))
        defer { try? FileManager.default.removeItem(at: url) }
        let lens = try LensMetadata.read(from: url)
        #expect((lens.lensModel == nil) == (tag == 0xA434))
        #expect((lens.lensSpecification == nil) == (tag == 0xA432))
        #expect((lens.focalLength == nil) == (tag == 0x920A))
        #expect((lens.fNumber == nil) == (tag == 0x829D))
    }

    @Test func readsDecipheredIdentifierFocusAndCrop() throws {
        var camera = [UInt8](repeating: 0, count: 0x08B8)
        camera[75] = 0x3E
        camera[76] = 0xC1
        camera[0x08B7] = 1
        var other = [UInt8](repeating: 0, count: 11)
        other[9] = 0x5E
        other[10] = 0x80
        var focus = [UInt8](repeating: 0, count: 46)
        focus[0x2D] = 255
        let url = try write(fixture(blocks: [(0x9416, camera), (0x940C, other), (0x9402, focus)]))
        defer { try? FileManager.default.removeItem(at: url) }
        let lens = try LensMetadata.read(from: url)
        #expect(lens.lensID == 49470 && lens.focusPositionRaw == 255)
        #expect(lens.focus == .unknown && lens.crop == .apsC)
        #expect(try ARWFrameInfo.read(from: url).lensMetadata == lens)
    }

    @Test func zeroLensType2UsesLensType3() throws {
        let camera = [UInt8](repeating: 0, count: 77)
        var other = [UInt8](repeating: 0, count: 11)
        other[8] = 4
        other[9] = 0x5E
        other[10] = 0x80
        var focus = [UInt8](repeating: 0, count: 46)
        focus[0x2D] = 128
        let url = try write(fixture(blocks: [(0x9416, camera), (0x940C, other), (0x9402, focus)]))
        defer { try? FileManager.default.removeItem(at: url) }
        let lens = try LensMetadata.read(from: url)
        #expect(lens.lensID == 32862 && lens.focusPositionRaw == 128 && lens.focus == .unknown)
    }

    @Test func lensType3NeedsAMountOrAnAMountIdentifier() throws {
        func lensID(mount: UInt8, low: UInt8, high: UInt8, cameraLength: Int = 77) throws -> UInt16? {
            var other = [UInt8](repeating: 0, count: 11)
            other[8] = mount
            other[9] = low
            other[10] = high
            let url = try write(fixture(blocks: [(0x9416, [UInt8](repeating: 0, count: cameraLength)), (0x940C, other)]))
            defer { try? FileManager.default.removeItem(at: url) }
            return try LensMetadata.read(from: url).lensID
        }
        #expect(try lensID(mount: 0, low: 0x5E, high: 0x80) == nil)
        #expect(try lensID(mount: 0, low: 0x2C, high: 0x00) == 44)
        #expect(try lensID(mount: 4, low: 0, high: 0) == nil)
        #expect(try lensID(mount: 4, low: 0x5E, high: 0x80, cameraLength: 76) == 32862)
    }

    @Test func truncatedBlocksLeaveEXIFReadable() throws {
        let data = fixture(blocks: [(0x9416, [UInt8](repeating: 0, count: 76)),
                                    (0x940C, [UInt8](repeating: 0, count: 10)),
                                    (0x9402, [UInt8](repeating: 0, count: 45))])
        for bytes in [data, Data(data.dropLast(3))] {
            let url = try write(bytes)
            defer { try? FileManager.default.removeItem(at: url) }
            let lens = try LensMetadata.read(from: url)
            #expect(lens.lensModel == "Test 28-75mm F2.8" && lens.focalLength == 75 && lens.fNumber == 1.4)
            #expect(lens.lensID == nil && lens.focusPositionRaw == nil && lens.focus == .unknown)
        }
    }

    @Test func malformedLensSpecificationIsAbsent() throws {
        let exif = Self.shot.filter { $0.0 != 0xA432 } + [(0xA432, .rational([(28, 1), (75, 1)]))]
        let url = try write(fixture(exif: exif))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try LensMetadata.read(from: url).lensSpecification == nil)
    }

    @Test func classifiesPresentCurves() throws {
        let settings: [(Int16, Int16, Int16, SonyLensCorrection.State)] = [
            (255, 255, 511, .absent), (0, 0, 256, .offByCamera), (1, 1, 272, .usable), (17, 1, 257, .usable),
        ]
        for (distortion, colour, shading, state) in settings {
            let url = try write(fixture(raw: [
                (0x7036, .signedShort([distortion])), (0x7037, .signedShort([2, 1, 2])),
                (0x7034, .signedShort([colour])), (0x7035, .signedShort([4, 0, 1, 0, 0])),
                (0x7031, .signedShort([shading])), (0x7032, .signedShort([2, 0, 1])),
            ]))
            defer { try? FileManager.default.removeItem(at: url) }
            let curves = try #require(SonyLensCorrection.read(from: url))
            #expect(curves.distortionState == state && curves.lateralColourState == state && curves.shadingState == state)
            #expect(curves.distortion?.knots == [1, 2])
        }
    }

    @Test func identityPrecedesCameraOff() throws {
        let url = try write(fixture(raw: [
            (0x7036, .signedShort([0])), (0x7037, .signedShort([2, 37, 37])),
            (0x7034, .signedShort([0])), (0x7035, .signedShort([4, 0, 0, 0, 0])),
            (0x7031, .signedShort([256])), (0x7032, .signedShort([2, 0, 0])),
        ]))
        defer { try? FileManager.default.removeItem(at: url) }
        let curves = try #require(SonyLensCorrection.read(from: url))
        #expect(curves.distortionState == .identity && curves.lateralColourState == .identity && curves.shadingState == .identity)
    }

    @Test func missingAndMalformedCurvesAreAbsent() throws {
        let url = try write(fixture(raw: [
            (0x7036, .signedShort([17])), (0x7037, .signedShort([3, 1, 2])),
            (0x7034, .signedShort([1])), (0x7035, .signedShort([3, 0, 0])),
            (0x7031, .signedShort([272])),
        ]))
        defer { try? FileManager.default.removeItem(at: url) }
        let curves = try #require(SonyLensCorrection.read(from: url))
        #expect(curves.distortionState == .absent && curves.lateralColourState == .absent && curves.shadingState == .absent)
    }

    @Test func refusesNonRawSources() throws {
        var builder = TIFFBuilder()
        builder.ifds = [[(0x0110, .ascii("ILCE-7M4"))]]
        builder.chain = [0]
        for data in [Data("not a TIFF".utf8), builder.build()] {
            let url = try write(data)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(throws: (any Error).self) { try LensMetadata.read(from: url) }
        }
    }

    private static let samples = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("samples")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: LensMetadataTests.samples.path),
                   "CC0 samples absent; run scripts/fetch-samples.sh to enable this case"))
    func readsFiveCC0Samples() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.samples, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "arw" }
        #expect(files.count == 5)
        for file in files {
            let lens = try LensMetadata.read(from: file)
            #expect(lens.lensModel == "FE 50mm F2.5 G" && lens.focalLength == 50 && lens.fNumber == 5.6)
            #expect(lens.lensSpecification == [50, 50, 2.5, 2.5] && lens.crop == .fullFrame && lens.focus == .unknown)
            #expect(lens.lensID == 32868 && lens.focusPositionRaw != nil)
            let corrections = try #require(SonyLensCorrection.read(from: file))
            #expect(corrections.shadingSetting == 272 && corrections.lateralColourSetting == 1 && corrections.distortionSetting == 17)
        }
    }
}
