import Foundation

public enum MonochromeFilter: String, CaseIterable, Codable, Sendable {
    case none, yellow, orange, red

    fileprivate var transmission: [SIMD3<Float>] {
        switch self {
        case .none: return Array(repeating: SIMD3(repeating: 1), count: 3)
        case .yellow: return [SIMD3(0.898, 0.903, 0.907), SIMD3(0.780, 0.884, 0.895), SIMD3(0, 0.055, 0.410)]
        case .orange: return [SIMD3(0.873, 0.887, 0.895), SIMD3(0, 0.290, 0.854), .zero]
        case .red: return [SIMD3(0.126, 0.750, 0.855), .zero, .zero]
        }
    }
}

public enum PaperGrade: Int, CaseIterable, Codable, Sendable {
    case soft = 0, mediumSoft, normal, mediumHard, hard, extraHard

    var contrast: Float {
        switch self {
        case .soft: return 0.58
        case .mediumSoft: return 0.76
        case .normal: return 1
        case .mediumHard: return 1.25
        case .hard: return 1.55
        case .extraHard: return 1.9
        }
    }
}

/// One silver image, represented as equal channels at the boundary of the shared print graph.
public enum MonochromeFilm: String, Sendable, CaseIterable {
    case triX, hp5

    private var sensitivity: [SIMD3<Float>] {
        switch self {
        case .triX:
            // F-4017 at net density 1.0, in log units relative to the highest sample.
            return [SIMD3(-0.27, -0.29, -0.31), SIMD3(-0.41, -0.26, -0.24), SIMD3(0, -0.15, -0.32)]
                .map { SIMD3(pow(10, $0.x), pow(10, $0.y), pow(10, $0.z)) }
        case .hp5:
            return [SIMD3(0.92, 0.92, 0.87), SIMD3(0.80, 0.93, 0.98), SIMD3(0.83, 0.82, 0.79)]
        }
    }

    public func weights(for filter: MonochromeFilter) -> SIMD3<Float> {
        let bands = zip(sensitivity, filter.transmission).map { ($0 * $1).sum() }
        let weights = SIMD3(bands[0], bands[1], bands[2])
        return weights / weights.sum()
    }

    private var characteristic: (start: Float, mid: Float, samples: [Float]) {
        switch self {
        case .triX: return (-3.5, -1.8, [0.34, 0.44, 0.69, 1.04, 1.41, 1.77, 2.11, 2.43, 2.74])
        case .hp5: return (0, 2.1, [0.18, 0.19, 0.26, 0.46, 0.79, 1.12, 1.44, 1.77, 2.10])
        }
    }

    private func density(logExposure: Float) -> Float {
        let curve = characteristic
        let t = max(0, (logExposure - curve.start) * 2)
        let i = Int(min(t, Float(curve.samples.count - 2)))
        return curve.samples[i] + (t - Float(i)) * (curve.samples[i + 1] - curve.samples[i])
    }

    private static let range: Float = 2.4
    private static let logTwo = Float(log10(2.0))

    private func negativeAmount(stops: Float) -> Float {
        let mid = characteristic.mid
        return min(max(0.5 + (density(logExposure: mid + stops * Self.logTwo) - density(logExposure: mid)) / Self.range, 0), 1)
    }

    private static func paperLight(_ amount: Float) -> Float {
        let t = min(max(amount, 0), 1)
        // Inverse paper exposure through the silver image, with a soft black toe and white shoulder.
        let u = pow(t, 1.89)
        return u * u * (3 - 2 * u)
    }

    private static func scalarTable(encoding: LogEncoding = LogEncoding(), sample: (Float) -> Float) -> LUT3D {
        let size = 33
        let row = (0..<size).flatMap { Array(repeating: sample(Float($0) / Float(size - 1)), count: 3) }
        return try! LUT3D(size: size, encoding: encoding, values: (0..<(size * size)).flatMap { _ in row })
    }

    public static let stocks = allCases.map { film in
        let encoding = LogEncoding(stopsBelowMidGray: 10, stopsAboveMidGray: 8)
        let negative = scalarTable(encoding: encoding) {
            film.negativeAmount(stops: $0 * encoding.range - encoding.stopsBelowMidGray)
        }
        let sigma: Float = (film == .triX ? 0.017 : 0.015) / range
        let curve = film.characteristic
        let netDensityOne = 0.5 + (curve.samples[0] + 1 - film.density(logExposure: curve.mid)) / range
        let density: [Float] = [0, 0.18, netDensityOne, 0.85, 1]
        let grain = GrainTable(amounts: density.map { [$0, $0, $0] },
                               sigma48: [0.15, 0.58, 1, 0.90, 0.60].map { [$0 * sigma, 0, 0] })
        return Stock(id: film == .triX ? "kodak-tri-x-400" : "ilford-hp5-plus",
                     displayName: film == .triX ? "Tri-X 400" : "HP5 Plus",
                     modelledFilm: film == .triX ? "Kodak Tri-X 400" : "Ilford HP5 Plus",
                     status: "datasheet", boxSpeed: 400, densityRange: range, negative: negative,
                     print: scalarTable(sample: paperLight), grain: grain, monochrome: film)
    }
}

extension Stock {
    /// Samples the negative for CPU print predictions, after scene exposure and gamut compression.
    public func negativeAmounts(exposed: SIMD3<Float>, filter: MonochromeFilter) -> SIMD3<Float> {
        let encoding = negative.encoding
        if let monochrome {
            let gray = (exposed * monochrome.weights(for: filter)).sum()
            return negative.sample(encoded: SIMD3(repeating: encoding.encode(gray)))
        }
        return negative.sample(encoded: SIMD3(encoding.encode(exposed.x), encoding.encode(exposed.y), encoding.encode(exposed.z)))
    }

    /// Applies the paper's density-domain contrast around its mid-gray, before paper clipping.
    public func paperAmounts(_ amounts: SIMD3<Float>, grade: PaperGrade) -> SIMD3<Float> {
        guard monochrome != nil else { return amounts }
        return SIMD3(repeating: 0.5 + (amounts.x - 0.5) * grade.contrast)
    }
}
