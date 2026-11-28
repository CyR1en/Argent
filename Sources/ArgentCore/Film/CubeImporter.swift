import Foundation

public enum CubeImporter {
    public enum InputSpace: String, CaseIterable, Sendable {
        case displaySRGB, sonySLog3, rawPrint
    }

    public enum Grain: String, CaseIterable, Sendable {
        case none, fine, medium, coarse, highSpeed

        var table: GrainTable? {
            let sigma: Float
            switch self {
            case .none: return nil
            case .fine: sigma = 0.0015
            case .medium: sigma = 0.0025
            case .coarse: sigma = 0.004
            case .highSpeed: sigma = 0.006
            }
            return GrainTable(
                amounts: [0, 0.25, 0.5, 0.75, 1].map { [Float](repeating: $0, count: 3) },
                sigma48: [1.4, 1.25, 1, 0.75, 0.45].map { [sigma * $0, sigma * $0 * 1.05, sigma * $0 * 1.15] }
            )
        }
    }

    public enum Halation: Sendable, Equatable {
        case none, subtle, strong
        case custom(Stock.Halation)

        func profile() throws -> Stock.Halation? {
            switch self {
            case .none: return nil
            case .subtle: return .init(strength: 0.015, greenShare: 0.2, radiusMicrometres: 110)
            case .strong: return .init(strength: 0.05, greenShare: 0.3, radiusMicrometres: 220)
            case .custom(let profile):
                guard (0...0.08).contains(profile.strength), (0...1).contains(profile.greenShare),
                      (60...350).contains(profile.radiusMicrometres) else {
                    throw StockError.badValue("Custom halation needs strength 0–0.08, green share 0–1, and radius 60–350 µm")
                }
                return profile.strength > 0 ? profile : nil
            }
        }
    }

    public struct Options: Sendable, Equatable {
        public var inputSpace: InputSpace
        public var grain: Grain
        public var halation: Halation
        public var boxSpeed: Float
        public var canisterColor: Stock.CanisterColor?

        public init(inputSpace: InputSpace = .displaySRGB, grain: Grain = .none, halation: Halation = .none,
                    boxSpeed: Float = 400, canisterColor: Stock.CanisterColor? = nil) {
            self.inputSpace = inputSpace
            self.grain = grain
            self.halation = halation
            self.boxSpeed = boxSpeed
            self.canisterColor = canisterColor
        }
    }

    public static func bake(_ cube: LUT3D, id: String, name: String, options: Options = .init(),
                            size: Int = 65) throws -> Stock {
        guard (2...128).contains(size) else { throw LUTError.badSize(size) }
        guard options.boxSpeed.isFinite, options.boxSpeed > 0 else { throw StockError.badValue("Box speed must be positive") }
        let halation = try options.halation.profile()
        let encoding = LogEncoding()
        let values = LUT3D.gridValues(size: size) { input in
            switch options.inputSpace {
            case .rawPrint:
                return cube.sampleTrilinear(encoded: input)
            case .displaySRGB, .sonySLog3:
                let scene = SIMD3(encoding.decode(input.x), encoding.decode(input.y), encoding.decode(input.z))
                let encoded: SIMD3<Float>
                switch options.inputSpace {
                case .displaySRGB:
                    let rgb = rec2020ToSRGB(neutralDisplay(scene))
                    encoded = SIMD3(LUT3D.srgbEncode(rgb.x), LUT3D.srgbEncode(rgb.y), LUT3D.srgbEncode(rgb.z))
                case .sonySLog3:
                    let rgb = rec2020ToSGamut3Cine(scene)
                    encoded = SIMD3(sLog3(rgb.x), sLog3(rgb.y), sLog3(rgb.z))
                case .rawPrint: return input
                }
                let rgb = cube.sampleTrilinear(encoded: encoded)
                return sRGBToRec2020(SIMD3(sRGBDecode(rgb.x), sRGBDecode(rgb.y), sRGBDecode(rgb.z)))
            }
        }
        return Stock(id: id, displayName: name, status: "custom", boxSpeed: options.boxSpeed,
                     densityRange: encoding.range * log10(Float(2)), negative: .identity(size: 2, encoding: encoding),
                     print: try LUT3D(size: size, encoding: encoding, values: values), grain: options.grain.table,
                     halation: halation, origin: .userImported, canisterColor: options.canisterColor)
    }

    private static func sLog3(_ linear: Float) -> Float {
        if linear >= 0.01125 {
            return (420 + log10((linear + 0.01) / 0.19) * 261.5) / 1023
        }
        return (95 + linear * ((171.2102946929 - 95) / 0.01125)) / 1023
    }

    private static func sRGBDecode(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func rec2020ToSRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(1.660491 * c.x - 0.5876411 * c.y - 0.0728499 * c.z,
              -0.1245505 * c.x + 1.1328999 * c.y - 0.0083494 * c.z,
              -0.0181508 * c.x - 0.1005789 * c.y + 1.1187297 * c.z)
    }

    private static func sRGBToRec2020(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(0.6274039 * c.x + 0.3292830 * c.y + 0.0433131 * c.z,
              0.0690973 * c.x + 0.9195404 * c.y + 0.0113623 * c.z,
              0.0163914 * c.x + 0.0880133 * c.y + 0.8955953 * c.z)
    }

    private static func rec2020ToSGamut3Cine(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(1.0381441 * c.x - 0.0954527 * c.y + 0.0573086 * c.z,
              0.0479489 * c.x + 0.7938619 * c.y + 0.1581892 * c.z,
              0.0301321 * c.x + 0.0408858 * c.y + 0.9289822 * c.z)
    }

    // The native Neutral curve from bake/argent_bake/neutral.py, including its highlight gamut roll-off.
    private static func rawNeutralTone(_ y: Float) -> Float {
        let midtone = y * pow((y + 0.035) / 0.215, 0.35)
        return midtone / pow(1 + pow(midtone, 1.6), 1 / 1.6)
    }

    private static let neutralMidGrayGain: Float = {
        var low: Float = 0.5, high: Float = 2
        for _ in 0..<24 {
            let mid = (low + high) * 0.5
            if rawNeutralTone(mid * 0.18) < 0.18 { low = mid }
            else { high = mid }
        }
        return (low + high) * 0.5
    }()

    private static func neutralDisplay(_ scene: SIMD3<Float>) -> SIMD3<Float> {
        let y = 0.2627 * scene.x + 0.6780 * scene.y + 0.0593 * scene.z
        let out = rawNeutralTone(neutralMidGrayGain * y)
        let scaled = scene * (out / y)
        let peak = max(scaled.x, scaled.y, scaled.z)
        let ratio = max(peak - out, 0) / max(1 - out, 1e-12)
        let neutral = SIMD3<Float>(repeating: out)
        let excess = max(ratio - 0.85, 0)
        let rolled = 0.85 + 0.15 * (excess / (excess + 0.15))
        let rgb = ratio > 0.85 ? neutral + (rolled / ratio) * (scaled - neutral) : scaled
        return rgb.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
    }
}
