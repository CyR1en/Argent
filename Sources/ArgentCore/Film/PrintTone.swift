import Foundation
import simd

/// Auto's tone step: a local burn and dodge in print exposure, the darkroom's own way of holding a
/// bright sky and lifting a dim foreground on one sheet of paper (docs/research/auto/balance-research.md,
/// section 7b).
///
/// It acts on the print, so grain, halation and the film's toe stay what the negative recorded, and only
/// a burn also reaches the negative, for colour (below). Each pixel's offset comes from its local tone base
/// (`ToneBaseField`), so a region moves as one and keeps its texture. `burn` darkens light above the print's mid-gray and
/// `dodge` lightens light below it, both in paper stops at their strongest, like the print exposure
/// and lab balance they add to. A dodge fades out where the negative holds too little to show, since
/// lifting there only prints a flat gray: `local-tone`'s measurements through the baked stocks keep a
/// half of a scene gain's texture 3.7 stops under the metered gray and 0.15 at 4.5 under.
///
/// A burn squeezes a sky's range of light by about half, but the film's contrast still applies to the sky's colour, so
/// a pale sky brought down off the paper's shoulder turned a deep blue that the scene never had. So a burn takes a share
/// of pale light's colour away before the negative, keeping its luminance. Saturated light keeps its own: a flower, or a
/// lamp's patch of orange on a night street, is not a sky.
public struct PrintTone: Sendable, Equatable, Hashable {
    /// The curve a recipe's values were made for. A new curve is a new version, and a recipe keeps
    /// the one it recorded.
    /// 2026-11-05-2: the first.
    public static let currentVersion = "2026-11-05-2"

    public static let identity = PrintTone()

    /// How far a pixel's weights reach, in stops. `u` is the base against the print's mid-gray, the
    /// aim; `negative` is the base against a metered gray as the negative received it.
    public struct Shape: Sendable, Equatable, Hashable {
        /// A burn rises over `burnRise` in `u`, long and gently, since a steep rise flattens the tones it crosses and past
        /// the negative's own contrast reverses them into halos. Above `burnFall` it falls to `burnKeep` of itself, so the
        /// paper's white stays white.
        public var burnRise: ClosedRange<Float>
        public var burnFall: ClosedRange<Float>
        public var burnKeep: Float
        /// A dodge rises over `dodgeRise` in `u` and falls away over `dodgeFall` toward mid-gray.
        public var dodgeRise: ClosedRange<Float>
        public var dodgeFall: ClosedRange<Float>
        /// The dodge's share follows the negative's signal, from none to all over this range.
        public var support: ClosedRange<Float>
        /// The share of the scene's colour a burn takes away, for each paper stop it burns.
        public var burnColour: Float

        public init(burnRise: ClosedRange<Float>, burnFall: ClosedRange<Float>, burnKeep: Float, burnColour: Float,
                    dodgeRise: ClosedRange<Float>, dodgeFall: ClosedRange<Float>, support: ClosedRange<Float>) {
            precondition(burnRise.upperBound > burnRise.lowerBound && burnFall.upperBound > burnFall.lowerBound
                         && dodgeRise.upperBound > dodgeRise.lowerBound && dodgeFall.upperBound > dodgeFall.lowerBound
                         && support.upperBound > support.lowerBound && (0...1).contains(burnKeep) && burnColour >= 0, "invalid tone shape")
            self.burnRise = burnRise
            self.burnFall = burnFall
            self.burnKeep = burnKeep
            self.burnColour = burnColour
            self.dodgeRise = dodgeRise
            self.dodgeFall = dodgeFall
            self.support = support
        }

        /// The shape of 2026-11-05-2 (docs/research/auto/balance-research.md, section 7d).
        public static let v2026_11_05_2 = Shape(burnRise: -0.25...4.5, burnFall: 4.5...5.5, burnKeep: 0.4, burnColour: 0.7,
                                                dodgeRise: -4.0 ... -2.0, dodgeFall: -0.75...0.5, support: -4.6 ... -2.9)
    }

    /// Paper stops of darkening at the burn's strongest, zero or more.
    public var burn: Float
    /// Paper stops of lightening at the dodge's strongest, zero or more.
    public var dodge: Float
    /// The print's mid-gray in scene stops against 0.18: the aim the print brings to density.
    public var referenceStops: Float
    public var version: String
    /// The curve when a measurement tries another, else the version's.
    var shapeOverride: Shape?
    /// Whether the offset keeps a gray's colour; a measurement turns it off to show what it costs.
    var holdsColour = true

    public init(burn: Float = 0, dodge: Float = 0, referenceStops: Float = 0, version: String = PrintTone.currentVersion) {
        self.burn = burn
        self.dodge = dodge
        self.referenceStops = referenceStops
        self.version = version
    }

    /// Whether the render reads the tone base and offsets the print. Identity takes the original render
    /// path, bit for bit.
    public var isActive: Bool { burn != 0 || dodge != 0 }

    public static func supports(version: String) -> Bool { version == currentVersion }

    /// The curve of `version`, or the measurement's.
    public func shape() throws -> Shape {
        if let shapeOverride { return shapeOverride }
        switch version {
        case "2026-11-05-2": return .v2026_11_05_2
        default: throw PrintToneError.unsupportedVersion(version)
        }
    }

    /// The offset in paper stops for a pixel whose base is `baseLog2`, log2 of its local luminance:
    /// what `table` holds for the GPU. `ratedStops` is what the rating adds to the negative.
    public func stops(baseLog2: Float, ratedStops: Float) throws -> Float {
        let shape = try shape()
        func smooth(_ range: ClosedRange<Float>, _ x: Float) -> Float {
            let t = min(max((x - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
            return t * t * (3 - 2 * t)
        }
        let scene = baseLog2 - log2(Float(0.18))
        let u = scene - referenceStops
        let burning = smooth(shape.burnRise, u) * (1 - (1 - shape.burnKeep) * smooth(shape.burnFall, u))
        let dodging = smooth(shape.dodgeRise, u) * (1 - smooth(shape.dodgeFall, u)) * smooth(shape.support, scene + ratedStops)
        return dodge * dodging - burn * burning
    }

    /// The render's table for this tone through `stock` with `settings`' rating and print offset: for each scene level,
    /// the offset in dye amounts per channel that moves a gray there by `stops` of print exposure in lightness and keeps the
    /// colour it prints without the tone step, and in `w` the share of the scene's colour its burn takes away.
    ///
    /// The same stops on all three channels would not: at print exposure a highlight sits on the paper's shoulder, which
    /// takes the negative's three layers to one white, and a burn brings it down off the shoulder to where they differ, so
    /// a white sky printed lavender on Portra 400 (found by eye, docs/research/auto/balance-research.md, section 7c).
    /// So each entry solves the three channels through the stock's own LUTs for the lightness the plain offset gives, with
    /// the unmoved print's chromaticity. What a burn does to coloured light stays the print exposure it is.
    func table(stock: Stock, settings: DevelopSettings) throws -> [SIMD4<Float>] {
        guard burn.isFinite, dodge.isFinite, referenceStops.isFinite, burn >= 0, dodge >= 0 else { throw PrintToneError.invalidValues }
        let rated = settings.exposureStops(boxSpeed: stock.boxSpeed)
        let offset = settings.printOffset(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
        let units = DevelopSettings.printUnits(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
        let encoding = stock.negative.encoding
        let luma = SIMD3<Float>(0.2627, 0.6780, 0.0593)
        let burnColour = try shape().burnColour
        func printed(_ amounts: SIMD3<Float>) -> SIMD3<Float> {
            stock.print.sample(encoded: amounts.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1)))
        }
        var values: [SIMD4<Float>] = []
        values.reserveCapacity(PrintToneTableInfo.entries)
        for index in 0..<PrintToneTableInfo.entries {
            let scene = PrintToneTableInfo.firstStops + Float(index) * PrintToneTableInfo.stepStops
            let stopsHere = try stops(baseLog2: log2(Float(0.18)) + scene, ratedStops: rated)
            guard stopsHere != 0 else { values.append(.zero); continue }
            let colourShare = min(max(-stopsHere, 0) * burnColour, 1)
            let film = stock.negative.sample(encoded: SIMD3(repeating: encoding.encode(encoding.midGray * exp2(scene + rated)))) + offset
            let plain = stopsHere * units
            guard holdsColour else { values.append(SIMD4(plain, colourShare)); continue }
            let unmoved = printed(film)
            let wanted = dot(printed(film + plain), luma)
            let base = dot(unmoved, luma)
            guard base > 1e-5, wanted > 1e-6 else { values.append(SIMD4(plain, colourShare)); continue }
            let target = unmoved * (wanted / base)
            // Newton on the three channels from the plain offset, each kept within its own size of it.
            var delta = plain
            let limit = abs(plain) + SIMD3(repeating: 0.002)
            func error(_ d: SIMD3<Float>) -> SIMD3<Float> { printed(film + d) - target }
            var best = delta, bestError = simd_length(error(delta))
            for _ in 0..<8 {
                let e = error(delta)
                let h: Float = 0.004
                func column(_ c: Int) -> SIMD3<Float> {
                    var up = delta, down = delta
                    up[c] += h; down[c] -= h
                    return (error(up) - error(down)) / (2 * h)
                }
                let jacobian = simd_float3x3(column(0), column(1), column(2))
                guard abs(jacobian.determinant) > 1e-9 else { break }
                let step = jacobian.inverse * e
                guard step.x.isFinite, step.y.isFinite, step.z.isFinite else { break }
                delta = (delta - step).clamped(lowerBound: plain - limit, upperBound: plain + limit)
                let size = simd_length(error(delta))
                if size < bestError { best = delta; bestError = size }
            }
            values.append(SIMD4(best, colourShare))
        }
        return values
    }
}

public enum PrintToneError: Error, LocalizedError, Equatable {
    case unsupportedVersion(String)
    case invalidValues

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "This recipe's tone step needs version \(version), which this build does not have."
        case .invalidValues: return "This recipe's tone step has invalid values."
        }
    }
}

extension PrintTone: Codable {
    private enum CodingKeys: String, CodingKey { case burn, dodge, referenceStops, version }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        burn = try values.decode(Float.self, forKey: .burn)
        dodge = try values.decode(Float.self, forKey: .dodge)
        referenceStops = try values.decode(Float.self, forKey: .referenceStops)
        version = try values.decode(String.self, forKey: .version)
        guard burn.isFinite, dodge.isFinite, referenceStops.isFinite, burn >= 0, dodge >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .burn, in: values, debugDescription: "A tone step must have finite values, zero or more.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(burn, forKey: .burn)
        try values.encode(dodge, forKey: .dodge)
        try values.encode(referenceStops, forKey: .referenceStops)
        try values.encode(version, forKey: .version)
    }
}

/// Mirrors `struct PrintToneTableInfo` in the Metal source: the table's scene levels, in stops against 0.18, past the
/// range of every stock's Negative LUT and every aim's reach.
struct PrintToneTableInfo {
    static let firstStops: Float = -10
    static let stepStops: Float = 0.25
    static let entries = 73

    var start: Float = PrintToneTableInfo.firstStops
    var step: Float = PrintToneTableInfo.stepStops
    var count: UInt32 = UInt32(PrintToneTableInfo.entries)
    var unused: UInt32 = 0
}
