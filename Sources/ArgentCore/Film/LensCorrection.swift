import CryptoKit
import Foundation

public enum LensCorrectionError: Error, Equatable {
    /// An invalid knot count, a non-finite table value, or a factor sample or framing scale outside 0.5...2.
    case malformedTable
    case readRadiusFalls(at: Double)
    case localScale(Double, at: Double)
    /// A gain sample that is not positive, exceeds 64, or is not 1 at the centre.
    case gain
    case decoderCorrected
}

/// A radial curve from centre to half diagonal, held at its last sample beyond the corner.
public struct RadialTable: Sendable, Hashable {
    // Both 15 and 10 divide this grid, so the file's 16 and 11 knots are copied exactly.
    static let intervals = 960
    let samples: [Float]

    public static var one: RadialTable { try! RadialTable(knots: [1, 1]) }

    public init(knots: [Double]) throws {
        guard knots.count >= 2, Self.intervals % (knots.count - 1) == 0,
              knots.allSatisfy({ $0.isFinite }) else { throw LensCorrectionError.malformedTable }
        let m = Self.intervals / (knots.count - 1)
        samples = (0...Self.intervals).map { i in
            let (j, r) = i.quotientAndRemainder(dividingBy: m)
            return Float(r == 0 ? knots[j] : knots[j] + (knots[j + 1] - knots[j]) * Double(r) / Double(m))
        }
        guard samples.allSatisfy({ $0.isFinite }) else { throw LensCorrectionError.malformedTable }
    }

    func value(at t: Double) -> Double {
        let x = min(max(t, 0), 1) * Double(Self.intervals)
        let i = min(Int(x), Self.intervals - 1)
        return Double(samples[i]) + (Double(samples[i + 1]) - Double(samples[i])) * (x - Double(i))
    }
}

public enum LensSource: Sendable, Hashable {
    case off, none(String), file

    public var description: String {
        switch self {
        case .off: return "off"
        case .none(let reason): return "none, \(reason)"
        case .file: return "file-curve"
        }
    }
}

/// Resolved intent. Inactive bands carry no hue state into render identity.
public struct DefringeParameters: Sendable, Hashable {
    public struct Band: Sendable, Hashable {
        public let amount: Float
        public let hueLow: Float, hueHigh: Float
    }
    public let purple: Band?, green: Band?
    public init?(_ settings: LensSettings.Defringe) {
        guard settings.purpleAmount > 0 || settings.greenAmount > 0 else { return nil }
        purple = settings.purpleAmount > 0 ? Band(amount: settings.purpleAmount, hueLow: settings.purpleHue.lowerBound,
                                                  hueHigh: settings.purpleHue.upperBound) : nil
        green = settings.greenAmount > 0 ? Band(amount: settings.greenAmount, hueLow: settings.greenHue.lowerBound,
                                                hueHigh: settings.greenHue.upperBound) : nil
    }
}

/// One immutable, validated map, resolved at full size and reused at every render size.
public struct ResolvedLensCorrection: Sendable, Equatable {
    public struct Status: Sendable, Hashable {
        public var distortion: LensSource, lateralColour: LensSource, vignetting: LensSource

        public init(distortion: LensSource = .off, lateralColour: LensSource = .off, vignetting: LensSource = .off) {
            self.distortion = distortion
            self.lateralColour = lateralColour
            self.vignetting = vignetting
        }
    }

    static let version = "2026-11-12-2"
    let red: RadialTable, green: RadialTable, blue: RadialTable, gain: RadialTable
    public let scale: Double
    public let status: Status
    public private(set) var digest: String
    private let warpDigest: String
    public private(set) var defringe: DefringeParameters?
    /// The objects taken out of the frame, as the settings this was resolved from hold them (`LensSettings.removals`). The lens stage
    /// composites those that are on into the decode before its warp, so the warp, Defringe and the vignette act on a patch as on the
    /// rest of the decode (docs/remove-plan.md, section 4.3).
    public private(set) var removals: [Removal] = []
    public let geometry: LensGeometry
    public private(set) var legacy: LensGeometry?

    public static var identity: ResolvedLensCorrection {
        try! ResolvedLensCorrection(red: .one, green: .one, blue: .one, gain: .one, status: Status(), scale: 1)
    }

    public static func uncorrected(_ reason: String) -> ResolvedLensCorrection {
        try! ResolvedLensCorrection(red: .one, green: .one, blue: .one, gain: .one,
                                   status: Status(distortion: .none(reason)), scale: 1)
    }

    public var isIdentity: Bool {
        [red, green, blue].allSatisfy { $0.samples.allSatisfy { Double($0) == scale } }
            && gain.samples.allSatisfy { $0 == 1 }
    }

    public init(red: RadialTable, green: RadialTable, blue: RadialTable, gain: RadialTable, status: Status,
                width: Int, height: Int) throws {
        let t0 = Double(min(width, height) - 1) / hypot(Double(width), Double(height))
        let scale = [red, green, blue].map { table in
            max(table.value(at: t0), table.samples.enumerated().filter {
                Double($0.offset) / Double(RadialTable.intervals) > t0
            }.map { Double($0.element) }.max() ?? table.value(at: t0))
        }.max()!
        try self.init(red: red, green: green, blue: blue, gain: gain, status: status, scale: scale)
    }

    public func reframed(scale: Double) throws -> ResolvedLensCorrection {
        let made = try ResolvedLensCorrection(red: red, green: green, blue: blue, gain: gain, status: status, scale: scale)
        let framed = made.defringing(defringe).removing(removals)
        return legacy.map { framed.remembering(legacy: $0) } ?? framed
    }

    public func defringing(_ parameters: DefringeParameters?) -> ResolvedLensCorrection {
        var copy = self
        copy.defringe = parameters
        copy.digest = copy.digested()
        return copy
    }

    /// This correction for a frame with `removals`. Only those that are on reach the digest, so a frame whose removals are all off
    /// has the keys of a frame with none, and turning one off returns to a decode the cache may still hold.
    public func removing(_ removals: [Removal]) -> ResolvedLensCorrection {
        var copy = self
        copy.removals = removals
        copy.digest = copy.digested()
        return copy
    }

    /// The warp's digest, hashed with Defringe's values when a band is on, then named with the removals that are on. With neither
    /// it is the warp's own, as before either existed.
    private func digested() -> String {
        var staged = warpDigest
        if let parameters = defringe {
            var bytes = Data((warpDigest + Defringe.version).utf8)
            for band in [parameters.purple, parameters.green] {
                bytes.append(band == nil ? 0 : 1)
                if let band {
                    for value in [band.amount, band.hueLow, band.hueHigh] {
                        withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
                    }
                }
            }
            staged = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        return removals.renderDigest.map { staged + "+remove-" + $0 } ?? staged
    }

    public func remembering(legacy: LensGeometry) -> ResolvedLensCorrection {
        var copy = self
        copy.legacy = legacy == geometry ? nil : legacy
        return copy
    }

    init(red: RadialTable, green: RadialTable, blue: RadialTable, gain: RadialTable, status: Status,
                 scale: Double) throws {
        guard (0.5...2).contains(scale),
              [red, green, blue].allSatisfy({ $0.samples.allSatisfy { (0.5...2).contains($0) } }) else {
            throw LensCorrectionError.malformedTable
        }
        for table in [red, green, blue] {
            for i in 0..<RadialTable.intervals {
                let slope = (Double(table.samples[i + 1]) - Double(table.samples[i])) * Double(RadialTable.intervals)
                for j in i...(i + 1) {
                    let t = Double(j) / Double(RadialTable.intervals), f = Double(table.samples[j])
                    let along = (f + t * slope) / scale, across = f / scale
                    guard along > 0 else { throw LensCorrectionError.readRadiusFalls(at: t) }
                    guard (0.8...1.25).contains(along) else { throw LensCorrectionError.localScale(along, at: t) }
                    guard (0.8...1.25).contains(across) else { throw LensCorrectionError.localScale(across, at: t) }
                }
            }
        }
        guard gain.samples[0] == 1, gain.samples.allSatisfy({ $0 > 0 && $0 <= 64 }) else { throw LensCorrectionError.gain }
        self.red = red; self.green = green; self.blue = blue; self.gain = gain
        self.scale = scale
        self.geometry = LensGeometry(unchecked: green, scale: scale)
        self.status = status

        var bytes = Data(Self.version.utf8)
        for table in [red, green, blue, gain] {
            for sample in table.samples {
                withUnsafeBytes(of: sample.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
            }
        }
        withUnsafeBytes(of: scale.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        for source in [status.distortion, status.lateralColour, status.vignetting] {
            switch source {
            case .off: bytes.append(0)
            case .file: bytes.append(1)
            case .none(let reason):
                bytes.append(2)
                let text = Data(reason.utf8)
                withUnsafeBytes(of: UInt64(text.count).littleEndian) { bytes.append(contentsOf: $0) }
                bytes.append(text)
            }
        }
        digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        warpDigest = digest
        defringe = nil
    }
}
