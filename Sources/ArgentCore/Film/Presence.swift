import Foundation

/// Lightroom's Presence group on a frame: Texture, Clarity, Dehaze, Vibrance and Saturation, each -100 to +100, 0 changing
/// nothing. One value beside the curves and the masks in `ManualAdjustments`, with its own version, the constants' version
/// (`PresenceConstants`), so a frame keeps rendering as it did when the constants are measured again. Never on a mask
/// (`MaskSet` refuses it).
///
/// Where each acts is fixed by the render, not chosen here: Dehaze, Clarity and Texture on scene light in the Negative LUT
/// pass and the halation source (`PresenceScene`), Saturation then Vibrance on the print in the Print LUT pass
/// (`PresencePrint`). The scene stages read the decode's analysis, made once a decode (`PresenceAnalyses`).
public struct Presence: Sendable, Equatable, Hashable {
    /// The one list of Presence's controls, in Lightroom's order. The inspector's rows, the spike's flags (`flag`), the
    /// recipe's keys (`rawValue`), the drive hook's names and the tests all come from it.
    public enum Control: String, CaseIterable, Sendable, Codable {
        case texture, clarity, dehaze, vibrance, saturation

        public var title: String {
            switch self {
            case .texture: "Texture"
            case .clarity: "Clarity"
            case .dehaze: "Dehaze"
            case .vibrance: "Vibrance"
            case .saturation: "Saturation"
            }
        }
        public var range: ClosedRange<Float> { -100...100 }
        public var step: Float { 1 }
        /// The spike's flag for it: `--texture`, `--clarity` and so on.
        public var flag: String { "--" + rawValue }

        public init?(flag: String) {
            guard let control = Self.allCases.first(where: { $0.flag == flag }) else { return nil }
            self = control
        }
        /// Which pass acts on it: scene light before the film, or the print after it.
        public var placement: Placement {
            switch self {
            case .texture, .clarity, .dehaze: .scene
            case .vibrance, .saturation: .print
            }
        }
    }

    public enum Placement: Sendable { case scene, print }

    /// The constants' version a frame with Presence records. A version with no `PresenceConstants` cannot render.
    public static let currentVersion = "2026-11-23-1"
    public static let identity = Presence()

    public private(set) var texture: Float = 0
    public private(set) var clarity: Float = 0
    public private(set) var dehaze: Float = 0
    public private(set) var vibrance: Float = 0
    public private(set) var saturation: Float = 0
    /// Always `currentVersion` while every value is 0, so identity is one value whatever version it came from.
    public private(set) var version = Presence.currentVersion

    public var isIdentity: Bool { self == Self.identity }

    private init() {}

    /// Values keyed by control, at `version`; a control left out is 0. Validated here, the boundary: each in its range and
    /// finite, -0 stored as 0, and a non-identity value's version one whose constants this build has.
    public init(_ values: [Control: Float], version: String = Presence.currentVersion) throws {
        try self.init(recorded: values, version: version)
        guard isIdentity || Self.supports(version: version) else { throw ManualDevelopmentError.unsupportedVersion(version) }
    }

    /// The same without the version check, so a recipe made by a build with other constants still opens. The render checks the
    /// version and refuses a frame whose version is not in `PresenceConstants.all`. No adjustment issue is raised, so Update
    /// Automatic Baseline is not offered, because `ManualRenderSettings.init` checks neither this version nor the curves'.
    private init(recorded values: [Control: Float], version: String) throws {
        var result = Presence()
        for (control, value) in values { result.store(try Self.validated(value, for: control), at: control) }
        if !result.isAllZero { result.version = version }
        self = result
    }

    public func value(for control: Control) -> Float {
        switch control {
        case .texture: texture
        case .clarity: clarity
        case .dehaze: dehaze
        case .vibrance: vibrance
        case .saturation: saturation
        }
    }

    /// The same at this value's version: a slider's step never moves the constants a frame renders with.
    public func setting(_ control: Control, to value: Float) throws -> Presence {
        var values = Dictionary(uniqueKeysWithValues: Control.allCases.map { ($0, self.value(for: $0)) })
        values[control] = value
        return try Presence(values, version: version)
    }

    /// The same values at the current constants: a new pin (Update Automatic Baseline, a paste that pins anew).
    public func updatingVersion() throws -> Presence {
        try Presence(Dictionary(uniqueKeysWithValues: Control.allCases.map { ($0, value(for: $0)) }))
    }

    /// Combines this Presence (such as Neutral Auto's polish) with a user's `other` refinements, summing each
    /// control within its valid range. Keeps `other`'s constants version when `other` is active, else `self`'s.
    public func combined(with other: Presence) -> Presence {
        guard !isIdentity else { return other }
        guard !other.isIdentity else { return self }
        var values: [Control: Float] = [:]
        for control in Control.allCases {
            let sum = value(for: control) + other.value(for: control)
            values[control] = min(max(sum, control.range.lowerBound), control.range.upperBound)
        }
        return (try? Presence(recorded: values, version: other.version)) ?? other
    }

    /// Whether any control acting in `placement` is set: the render binds and computes that side's stages only then.
    public func acts(in placement: Placement) -> Bool {
        Control.allCases.contains { $0.placement == placement && value(for: $0) != 0 }
    }

    public static func supports(version: String) -> Bool { PresenceConstants.named(version) != nil }

    public func validateSupportedVersion() throws {
        guard isIdentity || Self.supports(version: version) else { throw ManualDevelopmentError.unsupportedVersion(version) }
    }

    private var isAllZero: Bool { Control.allCases.allSatisfy { value(for: $0) == 0 } }

    private mutating func store(_ value: Float, at control: Control) {
        switch control {
        case .texture: texture = value
        case .clarity: clarity = value
        case .dehaze: dehaze = value
        case .vibrance: vibrance = value
        case .saturation: saturation = value
        }
    }

    private static func validated(_ value: Float, for control: Control) throws -> Float {
        guard value.isFinite, control.range.contains(value) else { throw ManualDevelopmentError.invalidPresence(control, value) }
        return value == 0 ? 0 : value
    }
}

/// The recipe's form: `{"version": …, "texture": …, "clarity": …, "dehaze": …, "vibrance": …, "saturation": …}`, every
/// control by its `rawValue`, so the keys come from the one list. `ManualAdjustments` writes it only when it is not identity,
/// so a frame without Presence keeps its bytes. Reading requires every control: a recipe is version 7 or it has none.
extension Presence: Codable {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        static let version = Key(stringValue: "version")
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let values = try Dictionary(uniqueKeysWithValues: Control.allCases.map {
            ($0, try c.decode(Float.self, forKey: Key(stringValue: $0.rawValue)))
        })
        try self.init(recorded: values, version: c.decode(String.self, forKey: .version))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(version, forKey: .version)
        for control in Control.allCases { try c.encode(value(for: control), forKey: Key(stringValue: control.rawValue)) }
    }
}

/// A Presence stage or build this build does not have yet. A render with that control set stops with it, so the spike and a test say
/// which piece is missing and whose it is, rather than crash in the renderer. Each place that throws it carries a marker naming its
/// package and what goes there (docs/presence-plan.md, section 5).
public enum PresenceError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case notBuilt(String, package: String)

    public var description: String {
        switch self {
        case .notBuilt(let what, let package): return "\(what) is not built yet: package \(package) of docs/presence-plan.md builds it."
        }
    }

    public var errorDescription: String? { description }
}

/// Automatic Presence applied by a stock's Auto finish (such as Neutral's subtle Vibrance and Clarity polish),
/// kept apart from `ManualRenderSettings` so untouched Auto frames remain unedited (`manual.isIdentity`) and
/// user adjustments stack on top of Auto without losing the polish.
public struct AutoPresence: Sendable, Equatable, Hashable, Codable {
    public static let identity = AutoPresence()

    public var presence: Presence
    /// Scene midtone reference in stops against 0.18, used by Clarity and Texture tone weights.
    /// Zero while `presence` is identity so identity is a single canonical value.
    public var referenceStops: Float

    public var isActive: Bool { !presence.isIdentity }

    public init(presence: Presence = .identity, referenceStops: Float = 0) {
        self.presence = presence
        self.referenceStops = presence.isIdentity ? 0 : (referenceStops == 0 ? 0 : referenceStops)
    }

    private enum CodingKeys: String, CodingKey { case presence, referenceStops }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let presence = try values.decode(Presence.self, forKey: .presence)
        let referenceStops = try values.decode(Float.self, forKey: .referenceStops)
        guard referenceStops.isFinite, (-32...32).contains(referenceStops) else {
            throw DecodingError.dataCorruptedError(forKey: .referenceStops, in: values,
                debugDescription: "Automatic Presence tonal reference must be finite and in -32...32.")
        }
        self.init(presence: presence, referenceStops: referenceStops)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(presence, forKey: .presence)
        try values.encode(referenceStops, forKey: .referenceStops)
    }
}
