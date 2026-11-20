import Foundation

/// A stock's grain as the bake writes it: per layer, along a neutral sweep, the Negative LUT's
/// normalized dye amount and the per-layer dye amount sigma there at a 48 micrometre aperture,
/// also normalized. Grain goes into the dye amounts before the Print LUT, so the paper's curve
/// gives it its gain and clipped whites carry none (docs/M3-research.md, section 3).
public struct GrainTable: Sendable, Equatable {
    public let amounts: [[Float]]
    public let sigma48: [[Float]]

    public init(amounts: [[Float]], sigma48: [[Float]]) {
        self.amounts = amounts
        self.sigma48 = sigma48
    }

    /// The layer's sigma at a normalized dye amount, interpolated along its own column and held
    /// flat past either end. A pixel's grain follows its own density: coarser in the toe.
    public func sigma(layer: Int, amount: Float) -> Float {
        guard let first = amounts.first, let last = amounts.last else { return 0 }
        if amount <= first[layer] { return sigma48[0][layer] }
        if amount >= last[layer] { return sigma48[sigma48.count - 1][layer] }
        var upper = 1
        while upper < amounts.count - 1, amounts[upper][layer] < amount { upper += 1 }
        let a0 = amounts[upper - 1][layer], a1 = amounts[upper][layer]
        let t = a1 > a0 ? (amount - a0) / (a1 - a0) : 0
        return sigma48[upper - 1][layer] + t * (sigma48[upper][layer] - sigma48[upper - 1][layer])
    }

    /// `count` samples of each layer's sigma over normalized amounts 0 to 1, for the shader.
    public func sampled(count: Int = 256) -> [SIMD3<Float>] {
        (0..<count).map { index in
            let amount = Float(index) / Float(count - 1)
            return SIMD3(sigma(layer: 0, amount: amount), sigma(layer: 1, amount: amount), sigma(layer: 2, amount: amount))
        }
    }
}

/// How grain scales with the output, and the one calibration constant.
public enum GrainModel {
    /// A frame is a 36 mm by 24 mm frame of film, whatever the sensor's crop: grain is set by
    /// how large the image is, as on a contact print.
    public static let filmLongEdgeMicrometres: Float = 36_000

    /// Per-pixel sigma over sigma48 by pixel pitch in micrometres: the research's F4, for the
    /// 6.5 and 15 micrometre dye-cloud mixture (docs/M3-research.md section 3; the bake's
    /// `PIXEL_RATIO`). Interpolated and extrapolated in log-log.
    public static let pitchRatios: [(pitch: Float, ratio: Float)] = [
        (5.137, 4.02), (10.27, 2.95), (17.58, 2.07), (20.55, 1.84), (41.1, 1.02),
    ]

    /// The dye clouds' noise power spectrum as two Gaussians: exp(-4.082 d^2 f^2) is the power
    /// of a Gaussian blur with sigma = d * sqrt(4.082) / (2 pi), 0.3216 d, so 2.09 and 4.82
    /// micrometres for the research's 6.5 and 15 micrometre clouds, each with half the power.
    public static let cloudSigmasMicrometres: [Float] = [6.5 * 0.3216, 15 * 0.3216]

    /// The global grain amount: 1, the stocks' own granularity printed through the same paper
    /// curve as the picture. From M3 until 2026-10-07 it was 0.6, set because the print showed
    /// about 1.6 times the 6.5 percent DxO measured on scanned Portra 160NC; but DxO's figure is
    /// referred to scene exposure, where a scanner's or a paper's tone curve cancels, and in
    /// those terms the anchor matches it; freely licensed scans of Portra 400, Gold 200 and
    /// Ektar 100 show 1.0 to 1.2 times this model's grain at amount 1 where their light matches
    /// (docs/research/film.md section 4.3). A scan's gentler tone, if it ever has data, belongs
    /// in the Print LUT, which the grain goes through.
    public static let amount: Float = 1.0

    /// The pitch of an output whose long side is `longSide` pixels.
    public static func pitchMicrometres(longSide: Int) -> Float { filmLongEdgeMicrometres / Float(max(longSide, 1)) }

    /// r(p) for an output whose long side is `longSide` pixels.
    public static func pixelRatio(longSide: Int) -> Float {
        let pitch = log(pitchMicrometres(longSide: longSide))
        let points = pitchRatios.map { (log($0.pitch), log($0.ratio)) }
        var lower = 0
        while lower < points.count - 2, pitch > points[lower + 1].0 { lower += 1 }
        let (x0, y0) = points[lower], (x1, y1) = points[lower + 1]
        return exp(y0 + (pitch - x0) * (y1 - y0) / (x1 - x0))
    }

    /// The long side of the develop that a render `longSide` pixels long stands for: its long side over its
    /// frame's scale (the decode's pixels per full-size pixel), rounded. A frame at full size or larger
    /// stands for itself.
    public static func developLongSide(longSide: Int, scale: Float) -> Int {
        guard scale > 0, scale < 1 else { return longSide }
        return max(longSide, Int((Float(longSide) / scale).rounded()))
    }

    /// A develop's grain area-resized from `from` pixels to `to`, as a smaller picture draws it. For each of
    /// the develop tile's cloud kernels, the kernel whose white noise has the resized field's
    /// autocorrelation; and the resized grain's RMS over the develop tile's.
    ///
    /// The develop's field is white noise blurred across and down by each kernel, so it has the kernel's
    /// autocorrelation each way. The resize makes each output pixel a weighted mean of the develop pixels
    /// its footprint covers (`AreaResize`), and neighbouring outputs correlate where their footprints share
    /// pixels or the kernel reaches between them. Averaged over where the outputs fall on the develop's
    /// grid, that is a stationary field's autocorrelation, and its zero-phase square root is the kernel that
    /// makes such a field from white noise. Drawn at its own pitch instead, a smaller picture would have the
    /// model's sigma there, which a develop resized to it falls short of: its tile, a cloud integrated over
    /// one pixel, holds less power at low frequencies than the model's field, and the resize averages over
    /// all of each pixel its footprint cuts (docs/manual-development-validation.md, "Grain tolerance,
    /// 2026-10-16").
    public static func resized(kernels: [[Float]], from: Int, to: Int) -> (kernels: [[Float]], sigma: Float) {
        let autocorrelations = kernels.map { resizedAutocorrelation($0, from: from, to: to) }
        let tile = kernels.reduce(0.0) { total, kernel in
            let squares = kernel.reduce(0.0) { $0 + Double($1) * Double($1) }
            return total + squares * squares
        }
        let resized = autocorrelations.reduce(0.0) { $0 + $1[0] * $1[0] }
        return (autocorrelations.map { spectralRoot($0, radius: $0.count) }, Float((resized / tile).squareRoot()))
    }

    /// The autocorrelation across, at lags 0 and up, of white noise blurred by `kernel` and area-resized from
    /// `from` pixels to `to`, averaged over the output pixels of one period of the resize's pattern.
    static func resizedAutocorrelation(_ kernel: [Float], from: Int, to: Int) -> [Double] {
        let radius = kernel.count / 2
        let own = (0...(2 * radius)).map { lag in
            (0..<(kernel.count - lag)).reduce(0.0) { $0 + Double(kernel[$1]) * Double(kernel[$1 + lag]) }
        }
        // The resize's pattern repeats every `outputs` pixels, `sources` develop pixels on.
        var (a, b) = (from, to)
        while b != 0 { (a, b) = (b, a % b) }
        let sources = from / a, outputs = to / a
        // Output j covers develop pixels j * sources / outputs to (j + 1) * sources / outputs, each weighted by
        // its share inside, as `area_resize` weights them.
        let weights: [[(pixel: Int, weight: Double)]] = (0..<outputs).map { j in
            let x0 = j * sources, x1 = x0 + sources
            return (x0 / outputs..<min((x1 + outputs - 1) / outputs, sources)).map { x in
                (x, Double(min((x + 1) * outputs, x1) - max(x * outputs, x0)) / Double(sources))
            }
        }
        func footprint(_ j: Int) -> [(pixel: Int, weight: Double)] {
            let (period, place) = j.quotientAndRemainder(dividingBy: outputs)
            return weights[place].map { ($0.pixel + period * sources, $0.weight) }
        }
        // Footprints further apart than the kernel reaches do not correlate.
        let lags = Int((Double(2 * radius + 2) * Double(to) / Double(from)).rounded(.up)) + 1
        return (0...lags).map { lag in
            var total = 0.0
            for j in 0..<outputs {
                for (x, wx) in footprint(j) {
                    for (y, wy) in footprint(j + lag) where abs(x - y) <= 2 * radius { total += wx * wy * own[abs(x - y)] }
                }
            }
            return total / Double(outputs)
        }
    }

    /// The symmetric kernel h, `radius` taps either side, whose autocorrelation is `autocorrelation` (lags 0
    /// and up): the inverse transform of the square root of its power spectrum.
    static func spectralRoot(_ autocorrelation: [Double], radius: Int) -> [Float] {
        let count = 1024
        let frequencies = (0..<count).map { (Double($0) + 0.5) / Double(2 * count) }
        let amplitudes = frequencies.map { nu -> Double in
            var power = autocorrelation[0]
            for lag in 1..<autocorrelation.count { power += 2 * autocorrelation[lag] * cos(2 * .pi * nu * Double(lag)) }
            return max(power, 0).squareRoot()
        }
        let half = (0...radius).map { tap in
            zip(frequencies, amplitudes).reduce(0.0) { $0 + $1.1 * cos(2 * .pi * $1.0 * Double(tap)) } / Double(count)
        }
        return (half.reversed() + half.dropFirst()).map { Float($0) }
    }

    /// A frame's grain seed, so each frame has its own grain and the same frame always the same.
    public static func seed(name: String, captureDate: Date?) -> UInt32 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let key = name + "|" + (captureDate.map { String(Int(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "")
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return UInt32(truncatingIfNeeded: hash ^ (hash >> 32))
    }
}
