import Foundation
import Metal

private let hostIsLittleEndian = UInt32(1).littleEndian == 1

/// The log encoding that maps scene-linear light onto a LUT's 0...1 input domain.
///
/// Mid-gray (0.18) sits `stopsBelowMidGray / (stopsBelowMidGray + stopsAboveMidGray)`
/// of the way up. The defaults cover eight stops below and five above. The top was four
/// until bake contract 2: Apple's highlight recovery extends clipped neutrals to about
/// +4.95 EV over 0.18 once the exposure anchor is applied, and a +4 top would clamp them.
/// The same defaults live in `bake/argent_bake/encoding.py`; change both together. A stock
/// manifest carries its own numbers, and the loader reads them from there.
public struct LogEncoding: Sendable, Equatable {
    public var stopsBelowMidGray: Float
    public var stopsAboveMidGray: Float
    public var midGray: Float

    public init(stopsBelowMidGray: Float = 8, stopsAboveMidGray: Float = 5, midGray: Float = 0.18) {
        self.stopsBelowMidGray = stopsBelowMidGray
        self.stopsAboveMidGray = stopsAboveMidGray
        self.midGray = midGray
    }

    public var range: Float { stopsBelowMidGray + stopsAboveMidGray }

    public func encode(_ linear: Float) -> Float {
        let stops = log2(max(linear, 1e-6) / midGray)
        return min(max((stops + stopsBelowMidGray) / range, 0), 1)
    }

    public func decode(_ encoded: Float) -> Float {
        midGray * pow(2, encoded * range - stopsBelowMidGray)
    }
}

/// Mirrors `struct LUTParams` in the Metal source.
public struct LUTParams: Sendable {
    public var logMin: Float
    public var logMax: Float
    public var midGray: Float
    public var lutSize: UInt32
    /// Stops added to the scene's exposure before the log encoding. Rated at lands here.
    public var exposureStops: Float = 0
    var silverR: Float = 0
    var silverG: Float = 0
    var silverB: Float = 0
}

public enum LUTError: Error, CustomStringConvertible {
    case badSize(Int)
    case malformedCube(line: Int, text: String)
    case wrongEntryCount(expected: Int, found: Int)
    case badBinaryMagic
    case unsupportedBinaryVersion(UInt32)
    case wrongBinaryLength(expected: Int, found: Int)
    case invalidValue(index: Int, value: Float)

    public var description: String {
        switch self {
        case .badSize(let n): return "LUT size \(n) is not supported; use 2...128."
        case .malformedCube(let line, let text): return "Malformed .cube at line \(line): \(text)"
        case .wrongEntryCount(let e, let f): return ".cube has \(f) entries but LUT_3D_SIZE implies \(e)."
        case .badBinaryMagic: return "Not a .lut3d file: the first eight bytes are not ARGLUT3D."
        case .unsupportedBinaryVersion(let v): return ".lut3d version \(v) is not supported; this build reads version 1."
        case .wrongBinaryLength(let e, let f): return ".lut3d is \(f) bytes but its header implies \(e)."
        case .invalidValue(let index, let value):
            return "LUT value \(index) (\(value)) is not finite in the renderer's half-float storage."
        }
    }
}

/// A 3D lookup table. What its axes mean depends on the stage it serves.
///
/// The Negative LUT, and the M0 spike's single display LUT, take log-encoded
/// scene-linear RGB. The Print LUT takes the amounts of the negative's three dyes,
/// normalized to 0...1 by the stock's density range, and returns display-linear RGB.
///
/// Storage is red-fastest, `index = ((b * size) + g) * size + r`, which is both the
/// `.cube` file order and the Metal 3D texture order (x = R, y = G, z = B).
public struct LUT3D: Sendable {
    public let size: Int
    public let encoding: LogEncoding
    public var values: [Float]

    public init(size: Int, encoding: LogEncoding = LogEncoding(), values: [Float]) throws {
        guard (2...128).contains(size) else { throw LUTError.badSize(size) }
        guard values.count == size * size * size * 3 else {
            throw LUTError.wrongEntryCount(expected: size * size * size, found: values.count / 3)
        }
        try Self.validateValues(values)
        self.size = size
        self.encoding = encoding
        self.values = values
    }

    public var params: LUTParams {
        LUTParams(logMin: -encoding.stopsBelowMidGray, logMax: encoding.stopsAboveMidGray,
                  midGray: encoding.midGray, lutSize: UInt32(size))
    }

    // MARK: Generators

    /// Output equals the log-encoded input. Useful for tests and for inspecting the encoding.
    public static func identity(size: Int = 17, encoding: LogEncoding = LogEncoding()) -> LUT3D {
        var values = [Float](repeating: 0, count: size * size * size * 3)
        let denominator = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let i = (((b * size) + g) * size + r) * 3
                    values[i] = Float(r) / denominator
                    values[i + 1] = Float(g) / denominator
                    values[i + 2] = Float(b) / denominator
                }
            }
        }
        return try! LUT3D(size: size, encoding: encoding, values: values)
    }

    /// A placeholder "print" until the bake tool produces real stock LUTs:
    /// a generic filmic tone curve followed by the sRGB transfer function.
    /// It exists so the M0 spike writes a viewable image, not as a look.
    public static func neutralPrint(size: Int = 33, encoding: LogEncoding = LogEncoding()) -> LUT3D {
        var values = [Float](repeating: 0, count: size * size * size * 3)
        let denominator = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let i = (((b * size) + g) * size + r) * 3
                    let linear = SIMD3<Float>(
                        encoding.decode(Float(r) / denominator),
                        encoding.decode(Float(g) / denominator),
                        encoding.decode(Float(b) / denominator))
                    let toned = filmicPlaceholder(linear)
                    values[i] = srgbEncode(toned.x)
                    values[i + 1] = srgbEncode(toned.y)
                    values[i + 2] = srgbEncode(toned.z)
                }
            }
        }
        return try! LUT3D(size: size, encoding: encoding, values: values)
    }

    /// Narkowicz's ACES fit. A stand-in curve, replaced by the stock model in M1.
    static func filmicPlaceholder(_ x: SIMD3<Float>) -> SIMD3<Float> {
        let a: Float = 2.51, b: Float = 0.03, c: Float = 2.43, d: Float = 0.59, e: Float = 0.14
        let y = (x * (a * x + b)) / (x * (c * x + d) + e)
        return y.clamped(lowerBound: SIMD3<Float>(repeating: 0), upperBound: SIMD3<Float>(repeating: 1))
    }

    static func srgbEncode(_ c: Float) -> Float {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    // MARK: .cube

    public static func parseCube(_ text: String, encoding: LogEncoding = LogEncoding()) throws -> LUT3D {
        var size = 0
        var values: [Float] = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = parts.first else { continue }
            switch first {
            case "TITLE", "DOMAIN_MIN", "DOMAIN_MAX":
                continue
            case "LUT_3D_SIZE":
                guard parts.count == 2, let n = Int(parts[1]) else {
                    throw LUTError.malformedCube(line: index + 1, text: line)
                }
                // Bounds before the arithmetic below: a hostile header such as 2147483647
                // overflows n*n*n*3, an uncatchable trap no caller can survive.
                guard (2...128).contains(n) else { throw LUTError.badSize(n) }
                size = n
                values.reserveCapacity(n * n * n * 3)
            case "LUT_1D_SIZE":
                throw LUTError.malformedCube(line: index + 1, text: "1D LUTs are not supported")
            default:
                guard parts.count == 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else {
                    throw LUTError.malformedCube(line: index + 1, text: line)
                }
                values.append(r); values.append(g); values.append(b)
            }
        }
        return try LUT3D(size: size, encoding: encoding, values: values)
    }

    public func cubeText(title: String) -> String {
        var out = "TITLE \"\(title)\"\nLUT_3D_SIZE \(size)\n"
        out.reserveCapacity(size * size * size * 30)
        for i in stride(from: 0, to: values.count, by: 3) {
            out += String(format: "%.6f %.6f %.6f\n", values[i], values[i + 1], values[i + 2])
        }
        return out
    }

    // MARK: .lut3d

    /// The binary file `argent-bake` writes beside each `.cube`, bake contract 2.
    ///
    /// Little-endian throughout: eight ASCII bytes `ARGLUT3D`, a uint32 version (1), a
    /// uint32 size (2 to 128), then size cubed times three float32 values in `.cube` order,
    /// red fastest, R G B per node. No trailer and no padding, so the length is fixed by the
    /// header. Parsing is a copy, where a 65 cubed `.cube` costs a few hundred milliseconds
    /// of text scanning.
    public static let binaryMagic = Data("ARGLUT3D".utf8)
    public static let binaryVersion: UInt32 = 1
    private static let binaryHeaderLength = 16

    public static func parseBinary(_ data: Data, encoding: LogEncoding = LogEncoding()) throws -> LUT3D {
        guard data.count >= binaryHeaderLength, data.prefix(binaryMagic.count) == binaryMagic else {
            throw LUTError.badBinaryMagic
        }
        let version = readLittleEndianUInt32(data, at: 8)
        guard version == binaryVersion else { throw LUTError.unsupportedBinaryVersion(version) }
        let size = Int(readLittleEndianUInt32(data, at: 12))
        guard (2...128).contains(size) else { throw LUTError.badSize(size) }
        let count = size * size * size * 3
        let expected = binaryHeaderLength + count * MemoryLayout<Float>.size
        guard data.count == expected else { throw LUTError.wrongBinaryLength(expected: expected, found: data.count) }

        let values = [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.withUnsafeBytes { bytes in
                let payload = UnsafeRawBufferPointer(rebasing: bytes[binaryHeaderLength...])
                if hostIsLittleEndian {
                    UnsafeMutableRawBufferPointer(buffer).copyMemory(from: payload)
                } else {
                    for i in 0..<count {
                        let bits = payload.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                        buffer[i] = Float(bitPattern: UInt32(littleEndian: bits))
                    }
                }
            }
            initialized = count
        }
        return try LUT3D(size: size, encoding: encoding, values: values)
    }

    /// The table in the `.lut3d` layout, the same bytes `argent-bake` writes.
    public func binaryData() -> Data {
        var out = Data(capacity: Self.binaryHeaderLength + values.count * MemoryLayout<Float>.size)
        out.append(Self.binaryMagic)
        out.append(littleEndianBytes(Self.binaryVersion))
        out.append(littleEndianBytes(UInt32(size)))
        if hostIsLittleEndian {
            values.withUnsafeBytes { out.append(contentsOf: $0) }
        } else {
            for value in values { out.append(littleEndianBytes(value.bitPattern)) }
        }
        return out
    }

    private static func readLittleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    private func littleEndianBytes(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    // MARK: Metal

    public func makeTexture(device: MTLDevice) throws -> MTLTexture {
        // `values` is mutable for callers building tables, so enforce the storage contract
        // again at the GPU boundary rather than relying only on the initializer.
        guard values.count == size * size * size * 3 else {
            throw LUTError.wrongEntryCount(expected: size * size * size, found: values.count / 3)
        }
        try Self.validateValues(values)
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = size
        descriptor.height = size
        descriptor.depth = size
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw GPUError.textureAllocation }

        let count = size * size * size
        var pixels = [Float16](repeating: 0, count: count * 4)
        for i in 0..<count {
            pixels[i * 4] = Float16(values[i * 3])
            pixels[i * 4 + 1] = Float16(values[i * 3 + 1])
            pixels[i * 4 + 2] = Float16(values[i * 3 + 2])
            pixels[i * 4 + 3] = 1
        }
        pixels.withUnsafeBytes { buffer in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0,
                            withBytes: buffer.baseAddress!, bytesPerRow: size * 8, bytesPerImage: size * size * 8)
        }
        return texture
    }

    private static func validateValues(_ values: [Float]) throws {
        if let index = values.firstIndex(where: { !$0.isFinite || !Float16($0).isFinite }) {
            throw LUTError.invalidValue(index: index, value: values[index])
        }
    }

    // MARK: CPU reference

    /// Tetrahedral sample on the CPU, the reference the GPU tests compare against.
    public func sample(encoded: SIMD3<Float>) -> SIMD3<Float> {
        let n = size
        let p = encoded.clamped(lowerBound: .zero, upperBound: SIMD3<Float>(repeating: 1)) * Float(n - 1)
        var i0 = SIMD3<Int>(Int(p.x), Int(p.y), Int(p.z))
        i0 = i0.clamped(lowerBound: .zero, upperBound: SIMD3<Int>(repeating: n - 2))
        let i1 = i0 &+ 1
        let f = p - SIMD3<Float>(Float(i0.x), Float(i0.y), Float(i0.z))
        func fetch(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Float> {
            let i = (((z * n) + y) * n + x) * 3
            return SIMD3<Float>(values[i], values[i + 1], values[i + 2])
        }
        let c000 = fetch(i0.x, i0.y, i0.z)
        let c111 = fetch(i1.x, i1.y, i1.z)
        if f.x > f.y {
            if f.y > f.z {
                return (1 - f.x) * c000 + (f.x - f.y) * fetch(i1.x, i0.y, i0.z) + (f.y - f.z) * fetch(i1.x, i1.y, i0.z) + f.z * c111
            } else if f.x > f.z {
                return (1 - f.x) * c000 + (f.x - f.z) * fetch(i1.x, i0.y, i0.z) + (f.z - f.y) * fetch(i1.x, i0.y, i1.z) + f.y * c111
            } else {
                return (1 - f.z) * c000 + (f.z - f.x) * fetch(i0.x, i0.y, i1.z) + (f.x - f.y) * fetch(i1.x, i0.y, i1.z) + f.y * c111
            }
        } else {
            if f.z > f.y {
                return (1 - f.z) * c000 + (f.z - f.y) * fetch(i0.x, i0.y, i1.z) + (f.y - f.x) * fetch(i0.x, i1.y, i1.z) + f.x * c111
            } else if f.z > f.x {
                return (1 - f.y) * c000 + (f.y - f.z) * fetch(i0.x, i1.y, i0.z) + (f.z - f.x) * fetch(i0.x, i1.y, i1.z) + f.x * c111
            } else {
                return (1 - f.y) * c000 + (f.y - f.x) * fetch(i0.x, i1.y, i0.z) + (f.x - f.z) * fetch(i1.x, i1.y, i0.z) + f.z * c111
            }
        }
    }
}
