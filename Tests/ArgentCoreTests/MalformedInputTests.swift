import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ArgentCore

/// Regression tests for the malformed-input traps from the 2026-10-09 bug hunt.
/// Before the fixes these were runtime traps inside `do`/`catch`, which no caller —
/// RollScanner importing an arbitrary .ARW, or `argent-spike --lut` reading a .cube —
/// could survive: a negative signed TIFF Orientation trapped in `UInt32(raw)`, and an
/// oversized LUT_3D_SIZE header trapped in `n*n*n*3` before the initializer's bounds
/// check could run. A signed negative embedded-preview offset also trapped in `UInt64`.
/// The original failures were documented with a subprocess harness; these
/// tests lock the fixed behavior into the shared suite.
@Suite struct MalformedInputTests {
    // MARK: ARW Orientation, tag 0x0112

    /// The review report's minimal 26-byte TIFF: little-endian header plus a
    /// single-entry IFD0 holding one tag of one value.
    private func minimalTIFF(tag: UInt16 = 0x0112, type: UInt16, value: UInt32) -> Data {
        func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        var out = Data([0x49, 0x49] + u16(42) + u32(8))       // header, first IFD at 8
        out.append(contentsOf: u16(1))                          // one entry
        out.append(contentsOf: u16(tag) + u16(type) + u32(1))   // the tag, count 1
        out.append(contentsOf: u32(value))
        out.append(contentsOf: u32(0))                          // end of the IFD chain
        return out
    }

    private func readOrientation(_ data: Data) throws -> CGImagePropertyOrientation {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("argent-malformed-\(UUID().uuidString).arw")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try ARWFrameInfo.read(from: url).orientation
    }

    @Test func negativeSignedOrientationFallsBackToUp() throws {
        // TIFFReader passes signed types through as negative Ints; type 8 (SSHORT) with
        // value -1 is the report's reproduced trap, type 9 (SLONG) its four-byte twin.
        #expect(try readOrientation(minimalTIFF(type: 8, value: 0x0000_FFFF)) == .up)
        #expect(try readOrientation(minimalTIFF(type: 9, value: 0xFFFF_FFFF)) == .up)
    }

    @Test func unknownAndOversizedOrientationsFallBackToUp() throws {
        #expect(try readOrientation(minimalTIFF(type: 4, value: 0xFFFF_FFFF)) == .up)  // LONG, out of range
        #expect(try readOrientation(minimalTIFF(type: 3, value: 9)) == .up)            // SHORT 9 is no orientation
        #expect(try readOrientation(minimalTIFF(type: 0, value: 3)) == .up)            // unknown type: no values
    }

    @Test func validAndAbsentOrientationsStillParse() throws {
        #expect(try readOrientation(minimalTIFF(type: 3, value: 6)) == .right)
        #expect(try readOrientation(minimalTIFF(type: 8, value: 8)) == .left)
        #expect(try readOrientation(minimalTIFF(tag: 0x0113, type: 3, value: 6)) == .up) // tag absent
    }

    /// The same damage through an a7 IV-shaped file with real JPEG blobs, the structure
    /// roll import actually walks.
    @Test func syntheticARWWithNegativeOrientationSurvives() throws {
        var builder = TIFFBuilder()
        builder.blobs = [TIFFBuilder.jpeg(width: 96, height: 64)]
        builder.ifds = [[(0x0110, .ascii("ILCE-7M4")), (0x0112, .signedShort([-1])),
                         (0x0201, .blobOffset(0)), (0x0202, .blobLength(0))]]
        builder.chain = [0]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("argent-malformed-arw-\(UUID().uuidString).arw")
        try builder.build().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try ARWFrameInfo.read(from: url)
        #expect(info.orientation == .up)
        #expect(info.model == "ILCE-7M4")
        #expect(info.preview != nil)
    }

    // MARK: Embedded-preview byte ranges

    @Test func signedNegativePreviewOffsetThrowsInsteadOfTrapping() throws {
        var builder = TIFFBuilder()
        builder.blobs = [TIFFBuilder.jpeg(width: 96, height: 64)]
        builder.ifds = [[(0x0110, .ascii("ILCE-7M4")), (0x0201, .signedShort([-1])),
                         (0x0202, .blobLength(0))]]
        builder.chain = [0]
        let url = try temporaryRaw(builder.build())
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try ARWFrameInfo.read(from: url)
        let range = try #require(info.preview)
        #expect(range.offset == -1)
        #expect(throws: EmbeddedJPEG.DecodeError.self) {
            try EmbeddedJPEG.image(at: range, in: url, maxPixelSize: 96, orientation: info.orientation)
        }
    }

    @Test func invalidPreviewRangesAreRejectedBeforeReading() throws {
        let url = try temporaryRaw(Data("not a JPEG".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let ranges: [ARWFrameInfo.ByteRange] = [
            .init(offset: -1, length: 4), .init(offset: 0, length: -1), .init(offset: 0, length: 0),
            .init(offset: 20, length: 4), .init(offset: 4, length: 7),
            .init(offset: 0, length: Int.max), .init(offset: Int.max, length: Int.max),
        ]
        for range in ranges {
            #expect(throws: EmbeddedJPEG.DecodeError.self) {
                try EmbeddedJPEG.image(at: range, in: url, maxPixelSize: 96, orientation: .up)
            }
        }
    }

    // MARK: .cube LUT_3D_SIZE

    private func expectBadSize(_ sizeText: String) throws {
        let text = "TITLE \"t\"\nLUT_3D_SIZE \(sizeText)\n"
        do {
            _ = try LUT3D.parseCube(text)
            Issue.record("LUT_3D_SIZE \(sizeText) should have been rejected")
        } catch LUTError.badSize(let n) {
            #expect(n == Int(sizeText))
        }
    }

    @Test func rejectsCubeSizesThatWouldOverflowBeforeAnyArithmetic() throws {
        try expectBadSize("-5")          // negative
        try expectBadSize("0")           // zero
        try expectBadSize("1")           // too small
        try expectBadSize("129")         // one over the top
        try expectBadSize("2147483647")  // the report's reproduced SIGTRAP
        try expectBadSize(String(Int.max))
    }

    @Test func cubeWithoutASizeHeaderIsStillRejected() throws {
        do {
            _ = try LUT3D.parseCube("# no header\n0.1 0.1 0.1\n")
            Issue.record("a .cube without LUT_3D_SIZE should be rejected")
        } catch LUTError.badSize(let n) {
            #expect(n == 0)
        }
    }

    @Test func validCubeStillParses() throws {
        var text = "TITLE \"t\"\nLUT_3D_SIZE 2\n"
        for b in 0...1 { for g in 0...1 { for r in 0...1 { text += "\(r) \(g) \(b)\n" } } }
        let lut = try LUT3D.parseCube(text)
        #expect(lut.size == 2 && lut.values.count == 24)
        #expect(lut.values.first == 0 && lut.values.last == 1)
        #expect(lut.sample(encoded: SIMD3<Float>(0.5, 0.25, 1)) == SIMD3<Float>(0.5, 0.25, 1))
    }
}
