import Foundation

/// The frame's intent for the lens stage. Defaults keep recipes written before Lens unchanged.
public struct LensSettings: Sendable, Hashable, Codable {
    public struct Distortion: Sendable, Hashable, Codable {
        public private(set) var isOn: Bool
        public private(set) var amount: Float

        public init(isOn: Bool = true, amount: Float = 100) throws {
            guard amount.isFinite, LensSettings.amountRange.contains(amount) else {
                throw ManualDevelopmentError.invalidLens("Distortion amount must be 0 to 200.")
            }
            self.isOn = isOn
            self.amount = amount == 0 ? 0 : amount
        }

        private enum CodingKeys: String, CodingKey { case on, amount }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(isOn: c.decodeIfPresent(Bool.self, forKey: .on) ?? true,
                          amount: c.decodeIfPresent(Float.self, forKey: .amount) ?? 100)
        }
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if !isOn { try c.encode(isOn, forKey: .on) }
            if amount != 100 { try c.encode(amount, forKey: .amount) }
        }
    }

    public struct Defringe: Sendable, Hashable, Codable {
        public static let amountRange: ClosedRange<Float> = 0...20
        public static let hueLowRange: ClosedRange<Float> = 0...90
        public static let hueHighRange: ClosedRange<Float> = 10...100
        public static let minimumHueWidth: Float = 10
        public static let `default` = try! Defringe()
        public private(set) var purpleAmount: Float
        public private(set) var purpleHue: ClosedRange<Float>
        public private(set) var greenAmount: Float
        public private(set) var greenHue: ClosedRange<Float>
        public var isDefault: Bool { self == Self.default }

        public init(purpleAmount: Float = 0, purpleHue: ClosedRange<Float> = 30...70,
                    greenAmount: Float = 0, greenHue: ClosedRange<Float> = 40...60) throws {
            guard [purpleAmount, greenAmount].allSatisfy({ $0.isFinite && Self.amountRange.contains($0) }),
                  [purpleHue, greenHue].allSatisfy({
                      $0.lowerBound.isFinite && $0.upperBound.isFinite
                          && Self.hueLowRange.contains($0.lowerBound) && Self.hueHighRange.contains($0.upperBound)
                          && $0.upperBound - $0.lowerBound >= Self.minimumHueWidth
                  }) else { throw ManualDevelopmentError.invalidLens("Defringe requires amounts 0 to 20 and hue pairs 0 <= low <= high - 10 <= 90.") }
            self.purpleAmount = purpleAmount == 0 ? 0 : purpleAmount
            self.purpleHue = purpleHue
            self.greenAmount = greenAmount == 0 ? 0 : greenAmount
            self.greenHue = greenHue
        }

        private enum CodingKeys: String, CodingKey { case purpleAmount, purpleHue, greenAmount, greenHue }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func hue(_ key: CodingKeys, default value: ClosedRange<Float>) throws -> ClosedRange<Float> {
                guard let pair = try c.decodeIfPresent([Float].self, forKey: key) else { return value }
                guard pair.count == 2, pair.allSatisfy(\.isFinite), pair[0] <= pair[1] else {
                    throw ManualDevelopmentError.invalidLens("Defringe hue requires [low, high].")
                }
                return pair[0]...pair[1]
            }
            try self.init(purpleAmount: c.decodeIfPresent(Float.self, forKey: .purpleAmount) ?? 0,
                          purpleHue: hue(.purpleHue, default: 30...70),
                          greenAmount: c.decodeIfPresent(Float.self, forKey: .greenAmount) ?? 0,
                          greenHue: hue(.greenHue, default: 40...60))
        }
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if purpleAmount != 0 { try c.encode(purpleAmount, forKey: .purpleAmount) }
            if purpleHue != Self.default.purpleHue { try c.encode([purpleHue.lowerBound, purpleHue.upperBound], forKey: .purpleHue) }
            if greenAmount != 0 { try c.encode(greenAmount, forKey: .greenAmount) }
            if greenHue != Self.default.greenHue { try c.encode([greenHue.lowerBound, greenHue.upperBound], forKey: .greenHue) }
        }
    }

    public struct Vignetting: Sendable, Hashable, Codable {
        public static let amountRange: ClosedRange<Float> = -100...100
        public static let midpointRange: ClosedRange<Float> = 0...100
        public static let `default` = try! Vignetting()
        public private(set) var amount: Float
        public private(set) var midpoint: Float

        public init(amount: Float = 0, midpoint: Float = 50) throws {
            guard amount.isFinite, Self.amountRange.contains(amount),
                  midpoint.isFinite, Self.midpointRange.contains(midpoint) else {
                throw ManualDevelopmentError.invalidLens("Vignetting requires amount -100 to 100 and midpoint 0 to 100.")
            }
            self.amount = amount == 0 ? 0 : amount
            self.midpoint = midpoint == 0 ? 0 : midpoint
        }

        private enum CodingKeys: String, CodingKey { case amount, midpoint }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(amount: c.decodeIfPresent(Float.self, forKey: .amount) ?? 0,
                          midpoint: c.decodeIfPresent(Float.self, forKey: .midpoint) ?? 50)
        }
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if amount != 0 { try c.encode(amount, forKey: .amount) }
            if midpoint != 50 { try c.encode(midpoint, forKey: .midpoint) }
        }
    }

    public enum Control: String, CaseIterable, Sendable {
        case distortion
        case purpleAmount = "defringe-purple", purpleHueLow = "defringe-purple-hue-low", purpleHueHigh = "defringe-purple-hue-high"
        case greenAmount = "defringe-green", greenHueLow = "defringe-green-hue-low", greenHueHigh = "defringe-green-hue-high"
        case vignette = "vignette", vignetteMidpoint = "vignette-midpoint"
        public var title: String {
            switch self {
            case .distortion, .vignette: "Amount"
            case .vignetteMidpoint: "Midpoint"
            case .purpleAmount: "Purple Amount"
            case .purpleHueLow: "Purple Hue Low"
            case .purpleHueHigh: "Purple Hue High"
            case .greenAmount: "Green Amount"
            case .greenHueLow: "Green Hue Low"
            case .greenHueHigh: "Green Hue High"
            }
        }
        public var range: ClosedRange<Float> {
            switch self {
            case .distortion: LensSettings.amountRange
            case .vignette: Vignetting.amountRange
            case .vignetteMidpoint: Vignetting.midpointRange
            case .purpleAmount, .greenAmount: Defringe.amountRange
            case .purpleHueLow, .greenHueLow: Defringe.hueLowRange
            case .purpleHueHigh, .greenHueHigh: Defringe.hueHighRange
            }
        }
        public var defaultValue: Float { LensSettings.default.value(for: self) }
    }

    public static let amountRange: ClosedRange<Float> = 0...200
    public static let `default` = LensSettings()
    public private(set) var distortion: Distortion
    public private(set) var defringe: Defringe
    public private(set) var vignetting: Vignetting
    /// The objects taken out of the frame, in the order they were made (`Removal`). They are the lens stage's, composited before
    /// its warp, so they are kept here and reach every preview, key and cache with the lens values (docs/remove-plan.md,
    /// section 4.1). They are not lens values: every setter below keeps them, `ManualAdjustments.settingLens` keeps its own, and
    /// only `settingRemovals` changes them.
    public private(set) var removals: [Removal]
    /// Whether the lens stage has nothing of this frame's to do: no value moved and no removal.
    public var isDefault: Bool { self == Self.default }
    /// Whether the lens values are the defaults, whatever was removed: what the Lens tab's mark, Reset Lens and Copy's Lens part
    /// ask, which are about the values alone.
    public var hasDefaultValues: Bool { carryingRemovals([]) == Self.default }
    /// Inactive hue handles remain saved intent, but cannot distinguish rendered pictures.
    var ignoringInactiveHue: Self {
        guard (defringe.purpleAmount == 0 && defringe.purpleHue != Defringe.default.purpleHue)
            || (defringe.greenAmount == 0 && defringe.greenHue != Defringe.default.greenHue) else { return self }
        return settingDefringe(try! Defringe(
            purpleAmount: defringe.purpleAmount,
            purpleHue: defringe.purpleAmount == 0 ? Defringe.default.purpleHue : defringe.purpleHue,
            greenAmount: defringe.greenAmount,
            greenHue: defringe.greenAmount == 0 ? Defringe.default.greenHue : defringe.greenHue))
    }
    private init() { distortion = try! Distortion(); defringe = .default; vignetting = .default; removals = [] }
    public init(distortion: Distortion, defringe: Defringe = .default, vignetting: Vignetting = .default) {
        self.distortion = distortion; self.defringe = defringe; self.vignetting = vignetting; removals = []
    }
    /// Lens values with removals already checked: a setter's, which keeps its own.
    private init(distortion: Distortion, defringe: Defringe, vignetting: Vignetting, removals: [Removal]) {
        self.distortion = distortion; self.defringe = defringe; self.vignetting = vignetting; self.removals = removals
    }

    /// These lens values with `removals`, checked (`[Removal].validated`).
    public func settingRemovals(_ removals: [Removal]) throws -> LensSettings {
        carryingRemovals(try removals.validated())
    }

    /// These lens values with removals a `LensSettings` already holds, which need no second check.
    func carryingRemovals(_ removals: [Removal]) -> LensSettings {
        LensSettings(distortion: distortion, defringe: defringe, vignetting: vignetting, removals: removals)
    }

    public func value(for control: Control) -> Float {
        switch control {
        case .distortion: distortion.amount
        case .vignette: vignetting.amount
        case .vignetteMidpoint: vignetting.midpoint
        case .purpleAmount: defringe.purpleAmount
        case .purpleHueLow: defringe.purpleHue.lowerBound
        case .purpleHueHigh: defringe.purpleHue.upperBound
        case .greenAmount: defringe.greenAmount
        case .greenHueLow: defringe.greenHue.lowerBound
        case .greenHueHigh: defringe.greenHue.upperBound
        }
    }
    public func setting(_ control: Control, to value: Float) throws -> LensSettings {
        guard value.isFinite else { throw ManualDevelopmentError.invalidLens("Lens values must be finite.") }
        var p = defringe.purpleAmount, g = defringe.greenAmount
        var ph = defringe.purpleHue, gh = defringe.greenHue
        switch control {
        case .distortion:
            return LensSettings(distortion: try Distortion(isOn: distortion.isOn, amount: value), defringe: defringe, vignetting: vignetting,
                                removals: removals)
        case .vignette:
            return LensSettings(distortion: distortion, defringe: defringe,
                                vignetting: try Vignetting(amount: value, midpoint: vignetting.midpoint), removals: removals)
        case .vignetteMidpoint:
            return LensSettings(distortion: distortion, defringe: defringe,
                                vignetting: try Vignetting(amount: vignetting.amount, midpoint: value), removals: removals)
        case .purpleAmount: p = value
        case .greenAmount: g = value
        case .purpleHueLow: ph = min(max(value, 0), ph.upperBound - 10)...ph.upperBound
        case .purpleHueHigh: ph = ph.lowerBound...max(min(value, 100), ph.lowerBound + 10)
        case .greenHueLow: gh = min(max(value, 0), gh.upperBound - 10)...gh.upperBound
        case .greenHueHigh: gh = gh.lowerBound...max(min(value, 100), gh.lowerBound + 10)
        }
        return settingDefringe(try Defringe(purpleAmount: p, purpleHue: ph, greenAmount: g, greenHue: gh))
    }
    public func settingDistortion(isOn: Bool) -> LensSettings {
        LensSettings(distortion: try! Distortion(isOn: isOn, amount: distortion.amount), defringe: defringe, vignetting: vignetting,
                     removals: removals)
    }
    public func settingDefringe(_ defringe: Defringe) -> LensSettings {
        LensSettings(distortion: distortion, defringe: defringe, vignetting: vignetting, removals: removals)
    }

    private enum CodingKeys: String, CodingKey { case distortion, defringe, vignetting, removals }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        distortion = try c.decodeIfPresent(Distortion.self, forKey: .distortion) ?? Self.default.distortion
        defringe = try c.decodeIfPresent(Defringe.self, forKey: .defringe) ?? .default
        vignetting = try c.decodeIfPresent(Vignetting.self, forKey: .vignetting) ?? .default
        removals = try (c.decodeIfPresent([Removal].self, forKey: .removals) ?? []).validated()
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if distortion != Self.default.distortion { try c.encode(distortion, forKey: .distortion) }
        if !defringe.isDefault { try c.encode(defringe, forKey: .defringe) }
        if vignetting != .default { try c.encode(vignetting, forKey: .vignetting) }
        // A frame with nothing removed is written as before Remove existed (recipe version 11 and below).
        if !removals.isEmpty { try c.encode(removals, forKey: .removals) }
    }

    /// Shared by the spike and the drive hook. Omitted keys retain their defaults. The words are the lens values': they name no
    /// removal, and what they make has none.
    public init(arguments: String) throws {
        if arguments == "default" { self = .default; return }
        var isOn = true, amount: Float = 100, purple: Float = 0, green: Float = 0
        var vignette: Float = 0, midpoint: Float = 50
        var purpleHue: ClosedRange<Float> = 30...70, greenHue: ClosedRange<Float> = 40...60
        var seen = Set<String>()
        for argument in arguments.split(separator: ",", omittingEmptySubsequences: false) {
            let pair = argument.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2, seen.insert(String(pair[0])).inserted else {
                throw ManualDevelopmentError.invalidLens("Lens settings require distinct KEY=VALUE pairs.")
            }
            func number() throws -> Float {
                guard let value = Float(pair[1]) else { throw ManualDevelopmentError.invalidLens("Invalid Lens value.") }
                return value
            }
            func hue() throws -> ClosedRange<Float> {
                let ends = pair[1].split(separator: ":", omittingEmptySubsequences: false)
                guard ends.count == 2, let lo = Float(ends[0]), let hi = Float(ends[1]),
                      lo.isFinite, hi.isFinite, lo <= hi else { throw ManualDevelopmentError.invalidLens("Defringe hue requires LOW:HIGH.") }
                return lo...hi
            }
            switch pair[0] {
            case "distortion":
                guard pair[1] == "on" || pair[1] == "off" else { throw ManualDevelopmentError.invalidLens("Distortion must be on or off.") }
                isOn = pair[1] == "on"
            case "distortion-amount": amount = try number()
            case "vignette": vignette = try number()
            case "vignette-midpoint": midpoint = try number()
            case "defringe-purple": purple = try number()
            case "defringe-green": green = try number()
            case "defringe-purple-hue": purpleHue = try hue()
            case "defringe-green-hue": greenHue = try hue()
            default: throw ManualDevelopmentError.invalidLens("Unknown Lens setting: \(pair[0]).")
            }
        }
        distortion = try Distortion(isOn: isOn, amount: amount)
        defringe = try Defringe(purpleAmount: purple, purpleHue: purpleHue, greenAmount: green, greenHue: greenHue)
        vignetting = try Vignetting(amount: vignette, midpoint: midpoint)
        removals = []
    }
    public var arguments: String {
        func number(_ value: Float) -> String { value.rounded() == value ? String(Int(value)) : String(value) }
        var parts: [String] = []
        if !distortion.isOn { parts.append("distortion=off") }
        if distortion.amount != 100 { parts.append("distortion-amount=\(number(distortion.amount))") }
        if vignetting.amount != 0 { parts.append("vignette=\(number(vignetting.amount))") }
        if vignetting.midpoint != 50 { parts.append("vignette-midpoint=\(number(vignetting.midpoint))") }
        if defringe.purpleAmount != 0 { parts.append("defringe-purple=\(number(defringe.purpleAmount))") }
        if defringe.purpleHue != Defringe.default.purpleHue {
            parts.append("defringe-purple-hue=\(number(defringe.purpleHue.lowerBound)):\(number(defringe.purpleHue.upperBound))")
        }
        if defringe.greenAmount != 0 { parts.append("defringe-green=\(number(defringe.greenAmount))") }
        if defringe.greenHue != Defringe.default.greenHue {
            parts.append("defringe-green-hue=\(number(defringe.greenHue.lowerBound)):\(number(defringe.greenHue.upperBound))")
        }
        return parts.isEmpty ? "default" : parts.joined(separator: ",")
    }
}

public enum LensAmount {
    public static func factor(_ factor: Double, amount: Double) -> Double { 1 + (amount / 100) * (factor - 1) }
    /// Scale each point's displacement while keeping the file table's amount-100 framing.
    public static func scaled(_ base: RadialTable, scale: Double, amount: Float,
                              picture: MaskSpace) throws -> (table: RadialTable, scale: Double) {
        let alpha = Double(amount) / 100
        let table = try RadialTable(knots: base.samples.map { alpha * Double($0) + (1 - alpha) * scale })
        let validated = try ResolvedLensCorrection(red: table, green: table, blue: table, gain: .one,
                                                  status: .init(distortion: .file), width: picture.width, height: picture.height)
        return (table, validated.scale)
    }
}
