import Foundation
import Metal
import Testing
@testable import ArgentCore

@Suite struct LogEncodingTests {
    @Test func midGrayLandsAtItsStopFraction() {
        let encoding = LogEncoding()
        #expect(encoding.stopsBelowMidGray == 8 && encoding.stopsAboveMidGray == 5)
        #expect(abs(encoding.encode(0.18) - 8.0 / 13.0) < 1e-5)
    }

    @Test func topOfTheRangeClearsHighlightRecovery() {
        // Apple's highlight recovery reaches about +4.95 EV over 0.18 after the anchor.
        let encoding = LogEncoding()
        #expect(encoding.encode(0.18 * exp2(4.95)) < 1)
        #expect(encoding.encode(0.18 * exp2(5.05)) == 1)
    }

    @Test func roundTripsAcrossTheRange() {
        let encoding = LogEncoding()
        for linear: Float in [0.001, 0.01, 0.05, 0.18, 0.5, 1.0, 2.8] {
            let back = encoding.decode(encoding.encode(linear))
            #expect(abs(back - linear) / linear < 1e-4)
        }
    }

    @Test func clampsOutsideTheRange() {
        let encoding = LogEncoding()
        #expect(encoding.encode(0) == 0)
        #expect(encoding.encode(1000) == 1)
    }
}

@Suite struct LUT3DTests {
    @Test func cubeRoundTrip() throws {
        let lut = LUT3D.identity(size: 5)
        let parsed = try LUT3D.parseCube(lut.cubeText(title: "identity"))
        #expect(parsed.size == 5)
        for (a, b) in zip(parsed.values, lut.values) {
            #expect(abs(a - b) < 1e-5)
        }
    }

    @Test func bundledIdentityCubeParses() throws {
        let url = try #require(Bundle.module.url(forResource: "identity-2", withExtension: "cube", subdirectory: "Resources"))
        let lut = try LUT3D.parseCube(String(contentsOf: url, encoding: .utf8))
        #expect(lut.size == 2)
        #expect(lut.sample(encoded: SIMD3<Float>(0.5, 0.25, 1)) == SIMD3<Float>(0.5, 0.25, 1))
    }

    @Test func crlfCubeMatchesLFCube() throws {
        let text = """
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let lf = try LUT3D.parseCube(text)
        let crlf = try LUT3D.parseCube(text.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(crlf.size == lf.size)
        #expect(crlf.values == lf.values)
    }

    @Test func crlfCubeCountsBlankAndCommentLinesInErrors() throws {
        let text = "LUT_3D_SIZE 2\r\n\r\n# bad row follows\r\n0 0\r\n"
        let error = #expect(throws: LUTError.self) { try LUT3D.parseCube(text) }
        guard case .malformedCube(let line, let row) = error else {
            Issue.record("expected malformedCube, got \(String(describing: error))")
            return
        }
        #expect(line == 4)
        #expect(row == "0 0")
    }

    @Test func cubeCommentCanContainAFormFeed() throws {
        let lut = LUT3D.identity(size: 2)
        let text = "# comment\u{000C}still a comment\n" + lut.cubeText(title: "identity")
        #expect(try LUT3D.parseCube(text).values == lut.values)
    }

    @Test func tabSeparatedCubeMatchesSpaceSeparatedCube() throws {
        let spaced = LUT3D.identity(size: 2).cubeText(title: "identity")
        let expected = try LUT3D.parseCube(spaced).values
        // Tabs alone, and tabs mixed with spaces, separate fields as a single space does.
        for separator in ["\t", " \t ", "\t\t"] {
            let lut = try LUT3D.parseCube(spaced.replacingOccurrences(of: " ", with: separator))
            #expect(lut.size == 2)
            #expect(lut.values == expected)
        }
    }

    @Test func tabSeparatedRowsStillNeedThreeNumbers() throws {
        let text = "LUT_3D_SIZE\t2\n0\t0\n" + String(repeating: "0\t0\t0\n", count: 8)
        let error = #expect(throws: LUTError.self) { try LUT3D.parseCube(text) }
        guard case .malformedCube(let line, _) = error else {
            Issue.record("expected malformedCube, got \(String(describing: error))")
            return
        }
        #expect(line == 2)
    }

    @Test func identityTetrahedralSamplingReturnsItsInput() {
        let lut = LUT3D.identity(size: 17)
        for point in [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1), SIMD3<Float>(0.3, 0.7, 0.1),
                      SIMD3<Float>(0.9, 0.2, 0.5), SIMD3<Float>(0.5, 0.5, 0.5), SIMD3<Float>(0.02, 0.98, 0.51)] {
            let sampled = lut.sample(encoded: point)
            #expect(abs(sampled.x - point.x) < 1e-5)
            #expect(abs(sampled.y - point.y) < 1e-5)
            #expect(abs(sampled.z - point.z) < 1e-5)
        }
    }

    @Test func neutralPrintIsMonotonicOnTheGrayAxis() {
        let lut = LUT3D.neutralPrint(size: 33)
        var previous: Float = -1
        for i in 0..<33 {
            let e = Float(i) / 32
            let v = lut.sample(encoded: SIMD3<Float>(repeating: e)).x
            #expect(v >= previous)
            previous = v
        }
        #expect(previous <= 1)
    }

    @Test func rejectsBadSizes() {
        #expect(throws: LUTError.self) { try LUT3D(size: 1, values: [0, 0, 0]) }
        #expect(throws: LUTError.self) { try LUT3D(size: 2, values: [0, 0, 0]) }
    }

    @Test(arguments: [Float.nan, .infinity, -.infinity, 65536, -65536])
    func rejectsCubeValuesThatCannotBeStoredAsFiniteHalves(value: Float) throws {
        let text = "LUT_3D_SIZE 2\n\(value) 0 0\n" + String(repeating: "0 0 0\n", count: 7)
        let error = #expect(throws: LUTError.self) { try LUT3D.parseCube(text) }
        guard case .invalidValue(let index, _) = error else {
            Issue.record("expected invalidValue, got \(String(describing: error))")
            return
        }
        #expect(index == 0)
    }

    @Test(arguments: [Float.nan, .infinity, -.infinity, 65536, -65536])
    func rejectsBinaryValuesThatCannotBeStoredAsFiniteHalves(value: Float) throws {
        var data = LUT3D.identity(size: 2).binaryData()
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.replaceSubrange(16..<20, with: $0) }
        let error = #expect(throws: LUTError.self) { try LUT3D.parseBinary(data) }
        guard case .invalidValue(let index, _) = error else {
            Issue.record("expected invalidValue, got \(String(describing: error))")
            return
        }
        #expect(index == 0)
    }

    @Test func acceptsFiniteSignedAndOverWhiteValues() throws {
        let values: [Float] = [-65504, -0.25, 0, 1, 1.25, 65504]
        let lut = try LUT3D(size: 2, values: Array(repeating: values, count: 4).flatMap { $0 })
        #expect(try LUT3D.parseBinary(lut.binaryData()).values == lut.values)
        #expect(try LUT3D.parseCube(lut.cubeText(title: "signed")).values == lut.values)
    }

    @Test func rejectsTablesMutatedAfterInitializationBeforeUploading() throws {
        let gpu = try GPU()
        var nonfinite = LUT3D.identity(size: 2)
        nonfinite.values[0] = .nan
        #expect(throws: LUTError.self) { try nonfinite.makeTexture(device: gpu.device) }

        var truncated = LUT3D.identity(size: 2)
        truncated.values.removeLast()
        #expect(throws: LUTError.self) { try truncated.makeTexture(device: gpu.device) }
    }

    @Test func binaryRoundTripIsExact() throws {
        let lut = ToyStock.lut(size: 7, ToyStock.negative)
        let data = lut.binaryData()
        #expect(data.count == 16 + 7 * 7 * 7 * 3 * 4)
        let parsed = try LUT3D.parseBinary(data, encoding: LogEncoding(stopsBelowMidGray: 6, stopsAboveMidGray: 6))
        #expect(parsed.size == 7)
        #expect(parsed.values == lut.values)
        #expect(parsed.encoding.stopsAboveMidGray == 6)
    }

    @Test func binaryLayoutIsTheContract() throws {
        // Eight ASCII bytes, uint32 version 1, uint32 size, then float32 R G B per node with
        // red fastest, all little-endian and nothing after the last float.
        let data = LUT3D.identity(size: 2).binaryData()
        #expect(Array(data.prefix(8)) == Array("ARGLUT3D".utf8))
        #expect(Array(data[8..<16]) == [1, 0, 0, 0, 2, 0, 0, 0])
        let floats = stride(from: 16, to: data.count, by: 4).map { offset -> Float in
            data[offset..<offset + 4].withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        }
        #expect(floats.count == 24)
        #expect(Array(floats[0..<6]) == [0, 0, 0, 1, 0, 0])  // node (0,0,0) then node (1,0,0)
        #expect(Array(floats[6..<9]) == [0, 1, 0])           // node (0,1,0)
        #expect(Array(floats[21..<24]) == [1, 1, 1])
    }

    @Test func rejectsABinaryThatIsNotTheContract() throws {
        let good = LUT3D.identity(size: 3).binaryData()

        var badMagic = good
        badMagic[0] = UInt8(ascii: "X")
        #expect(throws: LUTError.self) { try LUT3D.parseBinary(badMagic) }

        var badVersion = good
        badVersion[8] = 2
        #expect(throws: LUTError.self) { try LUT3D.parseBinary(badVersion) }

        var badSize = good
        badSize[12] = 1
        #expect(throws: LUTError.self) { try LUT3D.parseBinary(badSize) }

        #expect(throws: LUTError.self) { try LUT3D.parseBinary(good.prefix(good.count - 4)) }
        #expect(throws: LUTError.self) { try LUT3D.parseBinary(good + Data([0, 0, 0, 0])) }
        #expect(throws: LUTError.self) { try LUT3D.parseBinary(Data()) }
        #expect(throws: LUTError.self) { try LUT3D.parseBinary(Data("ARGLUT3D".utf8)) }
    }
}

@Suite struct LUTPassGPUTests {
    @Test func identityLUTReturnsLogEncodedInput() throws {
        let gpu = try GPU()
        let pass = try LUTPass(gpu: gpu)
        let lut = LUT3D.identity(size: 17)
        let lutTexture = try lut.makeTexture(device: gpu.device)

        let samples: [Float] = [0.001, 0.01, 0.05, 0.18, 0.5, 1, 2, 4, 8, 0, 0.18, 0.18, 0.3, 0.6, 0.9, 1.2]
        let input = try gpu.makeTexture(width: 4, height: 4)
        var pixels = [Float16](repeating: 0, count: 16 * 4)
        for i in 0..<16 {
            pixels[i * 4] = Float16(samples[i])
            pixels[i * 4 + 1] = Float16(samples[i])
            pixels[i * 4 + 2] = Float16(samples[i])
            pixels[i * 4 + 3] = 1
        }
        pixels.withUnsafeBytes { buffer in
            input.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                          withBytes: buffer.baseAddress!, bytesPerRow: 4 * 8)
        }

        let (output, gpuSeconds) = try pass.run(input: input, lut: lutTexture, params: lut.params)
        #expect(gpuSeconds >= 0)

        var result = [Float16](repeating: 0, count: 16 * 4)
        result.withUnsafeMutableBytes { buffer in
            output.texture.getBytes(buffer.baseAddress!, bytesPerRow: 4 * 8, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
        }
        for i in 0..<16 {
            let expected = lut.encoding.encode(Float(Float16(samples[i])))
            #expect(abs(Float(result[i * 4]) - expected) < 0.01, "sample \(samples[i])")
            #expect(abs(Float(result[i * 4 + 2]) - expected) < 0.01, "sample \(samples[i]) blue")
        }
    }
}
