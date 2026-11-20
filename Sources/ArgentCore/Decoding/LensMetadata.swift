import Foundation

public struct LensMetadata: Sendable, Equatable {
    public enum Focus: Sendable, Equatable {
        case unknown
        case metres(Double)
        case infinity
    }

    public enum Crop: String, Sendable {
        case fullFrame
        case apsC
    }

    public var lensModel: String?
    public var lensSpecification: [Double]?
    public var lensID: UInt16?
    public var focalLength: Double?
    public var fNumber: Double?
    public var focus: Focus = .unknown
    public var focusPositionRaw: UInt8?
    public var crop: Crop = .fullFrame

    public init() {}

    public var summary: String? {
        func number(_ value: Double) -> String {
            String(format: value.rounded() == value ? "%.0f" : "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        let parts = [lensModel, focalLength.map { number($0) + " mm" }, fNumber.map { "f/" + number($0) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    public static func read(from url: URL) throws -> LensMetadata {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let reader = try TIFFReader(handle: handle)
        _ = try ARWLayout.parse(reader)
        let ifd = try reader.readIFD(at: reader.firstIFDOffset)
        guard let entry = ifd[0x8769], let offset = try reader.integers(entry).first else { return LensMetadata() }
        let model = try ifd[0x0110].map { try reader.string($0) } ?? ""
        return parse(try reader.readIFD(at: offset), reader: reader, model: model)
    }

    static func parse(_ exif: [UInt16: TIFFReader.Entry], reader: TIFFReader, model: String) -> LensMetadata {
        var lens = LensMetadata()
        if let entry = exif[0xA434], entry.type == 2 {
            lens.lensModel = (try? reader.string(entry)).flatMap { $0.isEmpty ? nil : $0 }
        }
        if let entry = exif[0xA432], entry.type == 5, entry.count == 4 {
            lens.lensSpecification = try? reader.doubles(entry)
        }
        if let entry = exif[0x920A], entry.type == 5, entry.count == 1 {
            lens.focalLength = try? reader.doubles(entry).first
        }
        if let entry = exif[0x829D], entry.type == 5, entry.count == 1 {
            lens.fNumber = try? reader.doubles(entry).first
        }

        guard let entry = exif[0x927C], entry.type == 7, entry.count >= 6,
              let countBytes = try? reader.bytes(at: Int(entry.valueField), count: 2),
              2 + Int(TIFFReader.uint16(countBytes, 0, littleEndian: reader.littleEndian)) * 12 + 4 <= Int(entry.count),
              let maker = try? reader.readIFD(at: Int(entry.valueField)) else { return lens }
        var decipher = Array(UInt8(0)...UInt8(255))
        for n in 0..<249 { decipher[(n * n * n) % 249] = UInt8(n) }
        func block(_ tag: UInt16) -> [UInt8]? {
            guard let entry = maker[tag], entry.type == 7, entry.count > 4, entry.count <= 1 << 16,
                  let bytes = try? reader.bytes(at: Int(entry.valueField), count: Int(entry.count)) else { return nil }
            return bytes.map { decipher[Int($0)] }
        }
        let camera = block(0x9416)
        if let camera, camera.count >= 77 {
            // Sony's enciphered blocks are little-endian even in a big-endian TIFF.
            let id = TIFFReader.uint16(camera, 75, littleEndian: true)
            lens.lensID = id == 0 ? nil : id
        }
        // LensType3 can still name the lens mounted before a contactless one, so it counts only
        // where ExifTool takes it: with a known mount, or below the E-mount range.
        if lens.lensID == nil, let other = block(0x940C), other.count >= 11 {
            let id = TIFFReader.uint16(other, 9, littleEndian: true)
            if id != 0, other[8] != 0 || id < 32784 { lens.lensID = id }
        }
        if let focus = block(0x9402), focus.count > 0x2D { lens.focusPositionRaw = focus[0x2D] }
        if model == "ILCE-7M4", let camera, camera.count > 0x08B7 {
            lens.crop = camera[0x08B7] == 1 ? .apsC : .fullFrame
        }
        return lens
    }
}
