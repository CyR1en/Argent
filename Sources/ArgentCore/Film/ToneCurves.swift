import Foundation

public enum ToneCurveError: Error, Sendable, LocalizedError {
    case invalidPoints, invalidRegion, unsupportedVersion(String)
    public var errorDescription: String? {
        switch self {
        case .invalidPoints: "A curve needs 2–32 ordered points, anchored at inputs 0 and 255, with values from 0 to 255."
        case .invalidRegion: "Curve region values must be finite and between −100 and +100."
        case .unsupportedVersion(let version): "Curve version \(version) is unavailable. Update Automatic Baseline to continue."
        }
    }
}

/// Integer display-tone coordinates make keyboard entry, saved intent and graph handles agree.
public struct CurvePoint: Sendable, Equatable, Hashable, Codable {
    public let input: Int
    public let output: Int
    public init(input: Int, output: Int) throws {
        guard (0...255).contains(input), (0...255).contains(output) else { throw ToneCurveError.invalidPoints }
        self.input = input; self.output = output
    }
    private enum CodingKeys: CodingKey { case input, output }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(input: c.decode(Int.self, forKey: .input), output: c.decode(Int.self, forKey: .output))
    }
}

public enum CurveRegion: String, Sendable, CaseIterable, Codable {
    case shadows, darks, lights, highlights
    public var title: String { rawValue.capitalized }
    public var center: Float {
        switch self { case .shadows: 0.125; case .darks: 0.375; case .lights: 0.625; case .highlights: 0.875 }
    }
}

public struct CurveRegions: Sendable, Equatable, Hashable, Codable {
    public private(set) var shadows: Float
    public private(set) var darks: Float
    public private(set) var lights: Float
    public private(set) var highlights: Float
    public static let identity = try! Self()
    public var isIdentity: Bool { self == Self.identity }
    public init(shadows: Float = 0, darks: Float = 0, lights: Float = 0, highlights: Float = 0) throws {
        guard [shadows, darks, lights, highlights].allSatisfy({ $0.isFinite && (-100...100).contains($0) }) else {
            throw ToneCurveError.invalidRegion
        }
        self.shadows = shadows == 0 ? 0 : shadows; self.darks = darks == 0 ? 0 : darks
        self.lights = lights == 0 ? 0 : lights; self.highlights = highlights == 0 ? 0 : highlights
    }
    public func value(for region: CurveRegion) -> Float {
        switch region { case .shadows: shadows; case .darks: darks; case .lights: lights; case .highlights: highlights }
    }
    public func setting(_ region: CurveRegion, to value: Float) throws -> Self {
        var values = self
        switch region { case .shadows: values.shadows = value; case .darks: values.darks = value
        case .lights: values.lights = value; case .highlights: values.highlights = value }
        return try Self(shadows: values.shadows, darks: values.darks, lights: values.lights, highlights: values.highlights)
    }
    private enum CodingKeys: CodingKey { case shadows, darks, lights, highlights }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(shadows: c.decode(Float.self, forKey: .shadows), darks: c.decode(Float.self, forKey: .darks),
                      lights: c.decode(Float.self, forKey: .lights), highlights: c.decode(Float.self, forKey: .highlights))
    }
}

public struct ChannelCurve: Sendable, Equatable, Hashable, Codable {
    public static let maximumPoints = 32
    public static let identity = try! Self(points: [CurvePoint(input: 0, output: 0), CurvePoint(input: 255, output: 255)])
    public let points: [CurvePoint]
    public let regions: CurveRegions
    public var isIdentity: Bool { self == Self.identity }
    /// Collinear added handles remain editable intent, but their renderer bypass is exact.
    public var hasEffect: Bool { points.contains { $0.input != $0.output } || !regions.isIdentity }
    public init(points: [CurvePoint], regions: CurveRegions = .identity) throws {
        guard (2...Self.maximumPoints).contains(points.count), points.first?.input == 0, points.last?.input == 255,
              zip(points, points.dropFirst()).allSatisfy({ $0.input < $1.input }) else { throw ToneCurveError.invalidPoints }
        self.points = points; self.regions = regions
    }
    public func setting(points: [CurvePoint]) throws -> Self { try Self(points: points, regions: regions) }
    public func setting(_ region: CurveRegion, to value: Float) throws -> Self {
        try Self(points: points, regions: regions.setting(region, to: value))
    }
    private enum CodingKeys: CodingKey { case points, regions }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(points: c.decode([CurvePoint].self, forKey: .points), regions: c.decode(CurveRegions.self, forKey: .regions))
    }

    /// Shape-preserving cubic Hermite interpolation. Neighboring opposing slopes get a
    /// zero tangent; each interval stays inside its endpoint range, including inverted curves.
    public func compiled() -> CompiledChannelCurve {
        compiled(sampleCount: CompiledChannelCurve.sampleCount)
    }

    /// Graphs and renders share the recorded compiler, including its sampling grid.
    public func compiled(version: String) throws -> CompiledChannelCurve {
        guard ToneCurves.supports(version: version) else { throw ToneCurveError.unsupportedVersion(version) }
        return compiled(sampleCount: version == ToneCurves.currentVersion ? CompiledChannelCurve.sampleCount : 1025)
    }

    private func compiled(sampleCount: Int) -> CompiledChannelCurve {
        let x = points.map { Float($0.input) / 255 }, y = points.map { Float($0.output) / 255 }
        let slopes = zip(0..<(points.count - 1), 1..<points.count).map { (y[$1] - y[$0]) / (x[$1] - x[$0]) }
        var tangents = Array(repeating: Float(0), count: points.count)
        tangents[0] = slopes[0]; tangents[points.count - 1] = slopes.last!
        if points.count > 2 {
            for i in 1..<(points.count - 1) where slopes[i - 1] * slopes[i] > 0 {
                let h0 = x[i] - x[i - 1], h1 = x[i + 1] - x[i]
                let w0 = 2 * h1 + h0, w1 = h1 + 2 * h0
                tangents[i] = (w0 + w1) / (w0 / slopes[i - 1] + w1 / slopes[i])
            }
        }
        for i in slopes.indices {
            if slopes[i] == 0 { tangents[i] = 0; tangents[i + 1] = 0; continue }
            let a = tangents[i] / slopes[i], b = tangents[i + 1] / slopes[i], length = a * a + b * b
            if length > 9 {
                let scale = 3 / sqrt(length)
                tangents[i] = scale * a * slopes[i]; tangents[i + 1] = scale * b * slopes[i]
            }
        }
        var samples = [Float](); samples.reserveCapacity(sampleCount)
        var interval = 0
        for i in 0..<sampleCount {
            let t = Float(i) / Float(sampleCount - 1)
            while interval < points.count - 2 && t > x[interval + 1] { interval += 1 }
            let h = x[interval + 1] - x[interval], u = (t - x[interval]) / h
            let u2 = u * u, u3 = u2 * u
            let base = (2 * u3 - 3 * u2 + 1) * y[interval] + (u3 - 2 * u2 + u) * h * tangents[interval]
                + (-2 * u3 + 3 * u2) * y[interval + 1] + (u3 - u2) * h * tangents[interval + 1]
            // Smooth regional shifts act in perceptual tone, taper to zero at black and white,
            // and compose after the point curve. They don't alter the saved point handles.
            var shift: Float = 0
            for region in CurveRegion.allCases {
                let distance = (t - region.center) / 0.16
                shift += regions.value(for: region) * 0.00075 * exp(-distance * distance)
            }
            let weight = 4 * t * (1 - t)
            samples.append(min(1, max(0, base + shift * weight)))
        }
        return CompiledChannelCurve(samples: samples, active: hasEffect)
    }
}

public struct CompiledChannelCurve: Sendable {
    /// Four intervals per integer input keep every saved point on a table sample.
    public static let sampleCount = 255 * 4 + 1
    public let samples: [Float]
    public let active: Bool
    public var startSlope: Float { (samples[1] - samples[0]) * Float(samples.count - 1) }
    public var endSlope: Float { (samples[samples.count - 1] - samples[samples.count - 2]) * Float(samples.count - 1) }
    public func value(at input: Float) -> Float {
        guard active else { return input }
        if input <= 0 { return samples[0] + input * startSlope }
        if input >= 1 { return samples.last! + (input - 1) * endSlope }
        let index = input * Float(samples.count - 1), low = Int(index), fraction = index - Float(low)
        return samples[low] + (samples[low + 1] - samples[low]) * fraction
    }
}

/// Saved separately from the six sliders. Curve versioning never reinterprets older slider mappings.
public struct ToneCurves: Sendable, Equatable, Hashable, Codable {
    public enum Channel: String, Sendable, CaseIterable, Codable {
        case tone, red, green, blue
        public var title: String { rawValue.capitalized }
    }
    public enum Preset: String, Sendable, CaseIterable {
        case linear, softContrast, liftedBlacks, strongContrast
        public var title: String {
            switch self { case .linear: "Linear"; case .softContrast: "Soft contrast"
            case .liftedBlacks: "Lifted blacks"; case .strongContrast: "Strong contrast" }
        }
        public var curve: ChannelCurve {
            let pairs: [(Int, Int)]
            switch self {
            case .linear: return .identity
            case .softContrast: pairs = [(0,0), (64,53), (128,137), (192,205), (255,255)]
            case .liftedBlacks: pairs = [(0,19), (64,69), (128,139), (192,205), (255,248)]
            case .strongContrast: pairs = [(0,0), (64,39), (128,137), (192,220), (255,255)]
            }
            return try! ChannelCurve(points: pairs.map { try CurvePoint(input: $0.0, output: $0.1) })
        }
    }
    public static let currentVersion = "2026-10-09-curves-2"
    public static let identity = try! Self()
    public let tone: ChannelCurve
    public let red: ChannelCurve
    public let green: ChannelCurve
    public let blue: ChannelCurve
    public let version: String
    public var isIdentity: Bool { self == Self.identity }
    public var hasEffect: Bool { Channel.allCases.contains { curve(for: $0).hasEffect } }
    public init(tone: ChannelCurve = .identity, red: ChannelCurve = .identity, green: ChannelCurve = .identity,
                blue: ChannelCurve = .identity, version: String = Self.currentVersion) throws {
        guard Self.supports(version: version) else { throw ToneCurveError.unsupportedVersion(version) }
        self.tone = tone; self.red = red; self.green = green; self.blue = blue
        self.version = [tone, red, green, blue].allSatisfy(\.isIdentity) ? Self.currentVersion : version
    }
    public func curve(for channel: Channel) -> ChannelCurve {
        switch channel { case .tone: tone; case .red: red; case .green: green; case .blue: blue }
    }
    public func setting(_ channel: Channel, to curve: ChannelCurve) throws -> Self {
        try validateSupportedVersion()
        return try Self(tone: channel == .tone ? curve : tone, red: channel == .red ? curve : red,
                        green: channel == .green ? curve : green, blue: channel == .blue ? curve : blue,
                        version: version)
    }
    public func updatingVersion() throws -> Self { try Self(tone: tone, red: red, green: green, blue: blue) }
    public static func supports(version: String) -> Bool {
        version == currentVersion || version == "2026-10-09-curves-1"
    }
    public func validateSupportedVersion() throws {
        guard Self.supports(version: version) else { throw ToneCurveError.unsupportedVersion(version) }
    }
    private enum CodingKeys: CodingKey { case tone, red, green, blue, version }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tone = try c.decode(ChannelCurve.self, forKey: .tone); red = try c.decode(ChannelCurve.self, forKey: .red)
        green = try c.decode(ChannelCurve.self, forKey: .green); blue = try c.decode(ChannelCurve.self, forKey: .blue)
        let recordedVersion = try c.decode(String.self, forKey: .version)
        // A known compiler's canonical identity has no pixels to preserve. Neutral extra
        // handles and unavailable versions still retain their recorded edit intent.
        version = Self.supports(version: recordedVersion) && [tone, red, green, blue].allSatisfy(\.isIdentity)
            ? Self.currentVersion : recordedVersion
    }
    public func compiled() throws -> CompiledToneCurves {
        try validateSupportedVersion()
        return CompiledToneCurves(channels: try Channel.allCases.map { try curve(for: $0).compiled(version: version) })
    }
}

public struct CompiledToneCurves: Sendable {
    public let channels: [CompiledChannelCurve]
    public var isActive: Bool { channels.contains(where: \.active) }
    /// sRGB's perceptual transfer applied in working Rec.2020 primaries, with signed toe
    /// and over-white continuation. This is a tuning domain, not an output-space conversion.
    public static func encode(_ linear: Float) -> Float {
        linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }
    public static func decode(_ perceptual: Float) -> Float {
        perceptual <= 0.04045 ? perceptual / 12.92 : pow((perceptual + 0.055) / 1.055, 2.4)
    }
    public func applying(to rgb: SIMD3<Float>) -> SIMD3<Float> {
        guard isActive else { return rgb }
        var result = rgb
        if channels[0].active {
            let luminance = ManualRenderSettings.luminance(rgb)
            let mapped = Self.decode(channels[0].value(at: Self.encode(luminance)))
            // A finite, positive gain preserves chroma away from black; endpoint shifts are
            // neutral through the toe, rather than amplifying chroma noise at zero.
            let t = mapped >= 0 ? min(1, max(0, luminance / 0.02)) : 0
            let blend = t * t * (3 - 2 * t)
            let gain = luminance > 0 && mapped >= 0 ? mapped / max(luminance, 1e-6) : 1
            result = rgb * (1 + (gain - 1) * blend) + SIMD3(repeating: (mapped - luminance) * (1 - blend))
        }
        for i in 0..<3 where channels[i + 1].active {
            result[i] = Self.decode(channels[i + 1].value(at: Self.encode(result[i])))
        }
        return result
    }
}
