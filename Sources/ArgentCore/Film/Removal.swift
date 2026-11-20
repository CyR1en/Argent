import CryptoKit
import Foundation

/// A removal patch's identity: the SHA-256 of its box, its sizes and its pixels (`RemovalPatch.identity`), as a seed's `RasterID` is
/// of its pixels, so a patch is kept once however often it is saved, undone or redone. 64 lowercase hex digits.
public struct PatchID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let hex: String
    public init?(hex: String) {
        guard hex.count == 64, hex.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }) else { return nil }
        self.hex = hex
    }
    public var description: String { hex }
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let id = PatchID(hex: text) else { throw RemovalError.invalid("a patch id is 64 lowercase hex digits") }
        self = id
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// The patch a removal names: its identity and its raster's size, which is the model's and not the frame's
/// (docs/remove-plan.md, section 4.2).
public struct PatchRef: Sendable, Equatable, Hashable, Codable {
    /// A patch is at most the size a later full-size fill would store; the model's own is 1344 a side at most.
    public static let sideRange = 16...4096
    public let id: PatchID
    public let width: Int
    public let height: Int
    public init(id: PatchID, width: Int, height: Int) throws {
        guard Self.sideRange.contains(width), Self.sideRange.contains(height) else {
            throw RemovalError.invalid("a patch's sides are \(Self.sideRange.lowerBound) to \(Self.sideRange.upperBound) pixels")
        }
        self.id = id; self.width = width; self.height = height
    }
    private enum CodingKeys: String, CodingKey { case id, width, height }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(PatchID.self, forKey: .id), width: c.decode(Int.self, forKey: .width), height: c.decode(Int.self, forKey: .height))
    }
}

/// One object taken out of a frame: the patch that takes its place, whether it shows, and which of the patch's two alphas the lens
/// stage composites it by, the object with its shadow and reflections or the object alone (docs/remove-plan.md, section 4.1). Its
/// name is its place in the frame's list ("Removal 1"); how its pixels were made is in the patch's own notes.
///
/// It lives in `LensSettings.removals`, since the lens stage composites it before the warp and every preview, key and cache follows
/// the lens settings. A record is written only once its patch is in the store, so no record names nothing.
public struct Removal: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// More than a frame is given, so a damaged list is refused.
    public static let limit = 64

    public let id: UUID
    public let patch: PatchRef
    public private(set) var isOn: Bool
    public private(set) var includesEffects: Bool

    public init(id: UUID = UUID(), patch: PatchRef, isOn: Bool = true, includesEffects: Bool = true) {
        self.id = id; self.patch = patch; self.isOn = isOn; self.includesEffects = includesEffects
    }

    /// The row's eye.
    public func setting(isOn: Bool) -> Removal {
        var result = self
        result.isOn = isOn
        return result
    }

    /// Include Shadow and Reflections: both alphas are in the patch, so this never runs the model.
    public func setting(includesEffects: Bool) -> Removal {
        var result = self
        result.includesEffects = includesEffects
        return result
    }

    /// Try Again and Better: another patch for the same removal, which keeps its place, its eye and its switch.
    public func replacingPatch(_ patch: PatchRef) -> Removal {
        Removal(id: id, patch: patch, isOn: isOn, includesEffects: includesEffects)
    }

    private enum CodingKeys: String, CodingKey { case id, patch, off, objectOnly }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), patch: try c.decode(PatchRef.self, forKey: .patch),
                  isOn: !(try c.decodeIfPresent(Bool.self, forKey: .off) ?? false),
                  includesEffects: !(try c.decodeIfPresent(Bool.self, forKey: .objectOnly) ?? false))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(patch, forKey: .patch)
        if !isOn { try c.encode(true, forKey: .off) }
        if !includesEffects { try c.encode(true, forKey: .objectOnly) }
    }
}

extension Array where Element == Removal {
    /// These as a frame may hold them: no more than `Removal.limit`, each id once.
    public func validated() throws -> [Removal] {
        guard count <= Removal.limit else { throw RemovalError.invalid("a frame holds at most \(Removal.limit) removals") }
        guard Set(map(\.id)).count == count else { throw RemovalError.invalid("two removals share an id") }
        return self
    }

    /// Every patch these name, shown or not, each once and in order: what a record keeps in the store and in its pack.
    public var patches: [PatchRef] {
        var seen = Set<PatchID>()
        return map(\.patch).filter { seen.insert($0.id).inserted }
    }

    /// What the lens stage composites of these, as one digest: the patches that are on, their order and which alpha each takes.
    /// `nil` when none is on, and then a frame's keys are those of a frame with no removal.
    public var renderDigest: String? {
        let shown = filter(\.isOn)
        guard !shown.isEmpty else { return nil }
        let text = shown.map { $0.patch.id.hex + ($0.includesEffects ? "+effects" : "+object") }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// What Remove refuses, and what of it this build does not have yet. Each place that throws `notBuilt` is marked
/// "Unbuilt, package X" with what goes there (docs/remove-plan.md, section 5), so a test says which piece is missing and whose it
/// is.
public enum RemovalError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case invalid(String)
    case notBuilt(String, package: String)

    public var description: String {
        switch self {
        case .invalid(let why): return "Invalid removal: \(why)."
        case .notBuilt(let what, let package): return "\(what) is not built yet: package \(package) of docs/remove-plan.md builds it."
        }
    }

    public var errorDescription: String? { description }
}
