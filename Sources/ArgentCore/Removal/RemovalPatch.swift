import Compression
import CryptoKit
import Foundation

/// The pixels of one removal and what is known of how they were made (docs/remove-plan.md, section 4.2). The lens stage stretches
/// the raster over `box` in the decode, before its warp, and mixes it in by one of the two alphas (`Removal.includesEffects`).
///
/// The raster is at the model's working size, not the frame's, so a patch is a few megabytes and a preview samples it as it is. A
/// later full-size fill stores a larger raster over the same box; the format does not change.
///
/// Its identity is the hash of the box, the sizes and the planes, never of the file or of the notes, so a patch is kept once
/// however it was encoded, and a note can be read without changing what a record names.
public struct RemovalPatch: Sendable, Equatable {
    /// Where the patch lies: a box in the full-size decode's pixels, before the lens warp, its origin the picture's top left.
    public struct Box: Sendable, Equatable, Hashable, Codable {
        /// Past any frame's side, so a damaged box is refused.
        public static let limit = 1 << 16
        public let x: Int, y: Int, width: Int, height: Int
        public init(x: Int, y: Int, width: Int, height: Int) throws {
            // By subtraction, so a box that names an `x` near `Int.max` is refused rather than trapping on `x + width`.
            guard x >= 0, y >= 0, width > 0, height > 0, width <= Self.limit, height <= Self.limit,
                  x <= Self.limit - width, y <= Self.limit - height else {
                throw RemovalError.invalid("a patch's box lies inside the frame")
            }
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        private enum CodingKeys: String, CodingKey { case x, y, width, height }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(x: c.decode(Int.self, forKey: .x), y: c.decode(Int.self, forKey: .y),
                          width: c.decode(Int.self, forKey: .width), height: c.decode(Int.self, forKey: .height))
        }
    }

    /// What the patch says of itself, outside its identity: none of it changes a render.
    public struct Notes: Sendable, Equatable, Codable {
        /// The engine that drew it (`RemovalOutput.engine`) and its weights' SHA-256.
        public var engine: String?
        public var weights: String?
        public var steps: Int?
        public var guidance: Float?
        public var seed: UInt64?
        /// The decoder that made the pixels the crop was cut from, and that decode's full size. A patch on another decode is still
        /// used; the row says so (section 4.7).
        public var decoder: String?
        public var frameWidth: Int?
        public var frameHeight: Int?
        /// The box of a face the removal drew new pixels in, though the face was not what was removed: x, y, width and height as
        /// fractions of the upright frame, as `FaceMeasure.box` (section 4.8).
        public var face: [Float]?
        public var made: Date?
        /// The pixels of the raster the object's mask was grown by before the model got it. Making the removal again shrinks
        /// the mask it reads back by this (`RemovalPipeline.plan(retrying:)`); a patch made before this was noted was grown 2.
        public var growth: Int?

        public static let none = Notes()
        public init(engine: String? = nil, weights: String? = nil, steps: Int? = nil, guidance: Float? = nil, seed: UInt64? = nil,
                    decoder: String? = nil, frameWidth: Int? = nil, frameHeight: Int? = nil, face: [Float]? = nil, made: Date? = nil,
                    growth: Int? = nil) {
            self.engine = engine; self.weights = weights; self.steps = steps; self.guidance = guidance; self.seed = seed
            self.decoder = decoder; self.frameWidth = frameWidth; self.frameHeight = frameHeight; self.face = face; self.made = made
            self.growth = growth
        }
    }

    /// The model's working sizes: each side a multiple of `sideMultiple`, from `leastWorkingSide` to `longSideLimit`, which is
    /// what the converted graphs take (the helper's `ObjectClear.sides`), and `shortSide`, the model's training size, at least
    /// where the frame allows it. The helper holds 7 GB at 1344 by 1344 (`RemovalPipeline.workingSize`, `cropBox`).
    public static let shortSide = 512
    public static let longSideLimit = 1344
    public static let sideMultiple = 16
    public static let leastWorkingSide = 64

    public let box: Box
    public let width: Int
    public let height: Int
    /// Scene-linear red, green and blue in the decode's working space, row 0 the picture's top: `width * height * 3` values.
    public let rgb: [Float16]
    /// The object alone, 0 outside and 255 inside: `width * height` values.
    public let objectAlpha: [UInt8]
    /// The object with what the model took as its effects, a shadow or a reflection.
    public let effectsAlpha: [UInt8]
    public var notes: Notes
    public let identity: PatchID

    public var ref: PatchRef { try! PatchRef(id: identity, width: width, height: height) }

    /// Whether the model's pixels are enlarged more than twice over the box: "Soft at full size" on the row.
    public var isSoftAtFullSize: Bool { min(box.width, box.height) > 2 * min(width, height) }

    public init(box: Box, width: Int, height: Int, rgb: [Float16], objectAlpha: [UInt8], effectsAlpha: [UInt8],
                notes: Notes = .none) throws {
        guard PatchRef.sideRange.contains(width), PatchRef.sideRange.contains(height) else {
            throw RemovalError.invalid("a patch's sides are \(PatchRef.sideRange.lowerBound) to \(PatchRef.sideRange.upperBound) pixels")
        }
        guard rgb.count == width * height * 3, objectAlpha.count == width * height, effectsAlpha.count == width * height else {
            throw RemovalError.invalid("a patch's planes are its width by its height")
        }
        guard rgb.allSatisfy(\.isFinite) else { throw RemovalError.invalid("a patch's pixels are finite") }
        self.box = box; self.width = width; self.height = height
        self.rgb = rgb; self.objectAlpha = objectAlpha; self.effectsAlpha = effectsAlpha; self.notes = notes
        identity = Self.identity(box: box, width: width, height: height, rgb: rgb, objectAlpha: objectAlpha, effectsAlpha: effectsAlpha)
    }

    private static func identity(box: Box, width: Int, height: Int, rgb: [Float16], objectAlpha: [UInt8], effectsAlpha: [UInt8]) -> PatchID {
        var hash = SHA256()
        for value in [box.x, box.y, box.width, box.height, width, height] {
            withUnsafeBytes(of: UInt32(value).littleEndian) { hash.update(bufferPointer: $0) }
        }
        rgb.withUnsafeBytes { hash.update(bufferPointer: $0) }
        objectAlpha.withUnsafeBytes { hash.update(bufferPointer: $0) }
        effectsAlpha.withUnsafeBytes { hash.update(bufferPointer: $0) }
        return PatchID(hex: hash.finalize().map { String(format: "%02x", $0) }.joined())!
    }

    // MARK: the file

    /// A patch file's first line. A new layout is a new line, never a change to this one.
    public static let magic = Data("ARGENT-PATCH-1\n".utf8)
    /// A header is a few hundred bytes; more is not one.
    static let headerLimit = 1 << 16

    private struct Header: Codable {
        var box: Box
        var width: Int
        var height: Int
        var notes: Notes
        /// The stored length of each plane, in the order they follow the header.
        var rgb: Int
        var object: Int
        var effects: Int
    }

    /// The patch as its file: the magic line, the header's length in four little-endian bytes, the header in JSON, then the three
    /// planes, each under LZFSE.
    public func encoded() throws -> Data {
        let planes = [rgb.withUnsafeBytes { Data($0) }, Data(objectAlpha), Data(effectsAlpha)].map(Self.compressed)
        guard let red = planes[0], let object = planes[1], let effects = planes[2] else {
            throw RemovalError.invalid("a patch's planes could not be compressed")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let header = try encoder.encode(Header(box: box, width: width, height: height, notes: notes,
                                               rgb: red.count, object: object.count, effects: effects.count))
        var out = Self.magic
        withUnsafeBytes(of: UInt32(header.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(header)
        out.append(red); out.append(object); out.append(effects)
        return out
    }

    /// The patch a file holds, its sides read before any plane is unpacked, so a damaged file cannot ask for a huge picture. Its
    /// identity is recomputed from its planes: the caller compares it with the name it was asked for.
    public init(decoding data: Data) throws {
        let data = Data(data)   // its own indices, from zero
        let start = Self.magic.count + 4
        guard data.count >= start, data.prefix(Self.magic.count) == Self.magic else { throw RemovalError.invalid("not a patch file") }
        let length = Int(data[Self.magic.count..<start].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) })
        guard length <= Self.headerLimit, data.count >= start + length else { throw RemovalError.invalid("a patch file's header is cut short") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(Header.self, from: data[start..<start + length]) else {
            throw RemovalError.invalid("a patch file's header cannot be read")
        }
        guard PatchRef.sideRange.contains(header.width), PatchRef.sideRange.contains(header.height),
              header.rgb >= 0, header.object >= 0, header.effects >= 0,
              // By subtraction, so lengths near `Int.max` are refused rather than trapping on their sum.
              header.rgb <= data.count - (start + length),
              header.object <= data.count - (start + length) - header.rgb,
              header.effects == data.count - (start + length) - header.rgb - header.object else {
            throw RemovalError.invalid("a patch file's planes are not the length its header says")
        }
        let count = header.width * header.height
        var offset = start + length
        func plane(_ stored: Int, bytes: Int) throws -> Data {
            defer { offset += stored }
            guard let plane = Self.expanded(data[offset..<offset + stored], to: bytes) else {
                throw RemovalError.invalid("a patch file's plane does not unpack to its size")
            }
            return plane
        }
        let red = try plane(header.rgb, bytes: count * 3 * MemoryLayout<Float16>.size)
        let object = try plane(header.object, bytes: count), effects = try plane(header.effects, bytes: count)
        let rgb = red.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        try self.init(box: header.box, width: header.width, height: header.height, rgb: rgb,
                      objectAlpha: [UInt8](object), effectsAlpha: [UInt8](effects), notes: header.notes)
    }

    private static func compressed(_ plane: Data) -> Data? {
        // LZFSE stores what it cannot shrink with a small overhead; this is room for it.
        let capacity = plane.count + plane.count / 16 + 4096
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { target in
            plane.withUnsafeBytes { source in
                compression_encode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          source.bindMemory(to: UInt8.self).baseAddress!, plane.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written > 0 else { return nil }
        out.removeSubrange(written...)
        return out
    }

    /// `stored` unpacked into exactly `bytes`, or `nil`: one byte more is asked for, so a plane that unpacks to more is refused
    /// rather than cut.
    private static func expanded(_ stored: Data, to bytes: Int) -> Data? {
        guard !stored.isEmpty else { return nil }
        var out = Data(count: bytes + 1)
        let written = out.withUnsafeMutableBytes { target in
            stored.withUnsafeBytes { source in
                compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, bytes + 1,
                                          source.bindMemory(to: UInt8.self).baseAddress!, stored.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written == bytes else { return nil }
        out.removeSubrange(bytes...)
        return out
    }
}

/// Where the lens stage gets a removal's pixels: the patch store, behind a cache of the patches a roll's frames name
/// (`PatchStore.source`). Safe to call from any thread.
public protocol RemovalPatchSource: Sendable {
    /// The patch `ref` names, checked against that name, or `nil` when there is none that hashes to it. A preview then skips the
    /// removal and its row says the patch is missing; a develop has refused the frame before its decode (section 4.3).
    func patch(_ ref: PatchRef) -> RemovalPatch?
}

/// Patches held in memory: a suite's source.
public struct FixedPatchSource: RemovalPatchSource {
    private let patches: [PatchID: RemovalPatch]
    public init(_ patches: [RemovalPatch]) {
        self.patches = Dictionary(patches.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
    }
    public func patch(_ ref: PatchRef) -> RemovalPatch? {
        patches[ref.id].flatMap { $0.width == ref.width && $0.height == ref.height ? $0 : nil }
    }
}
