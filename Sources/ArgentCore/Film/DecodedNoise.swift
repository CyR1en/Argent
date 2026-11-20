import Foundation

/// How Apple's decoder turns sensor noise into light in a frame's dark parts, and how auto
/// development's measurement takes it out again.
///
/// On the CC0 scene darkened 3.5 stops in the raw and given the a7 IV's noise (docs/M3-auto.md,
/// section 16), the decode's mean light rises half a stop from ISO 250 to 102400 while the raw's
/// stays put: red and blue come out about doubled, green 10 percent up. The decoder keeps the raw's
/// samples under black (clipping them at black first makes the decode brighter still), so the clip
/// is later in its pipeline. Each channel reads as light `t` with zero-mean noise clipped at zero,
/// `E[max(t + n, 0)]`, where the noise's variance in decoded units is `read + shot * t`: a share
/// of one photosite's (`clipVarianceShare`, a half for red and blue and a quarter for green) times
/// the sensor's noise in digital numbers (`BodyNoise`) carried into the decode by its units per
/// digital number. That model predicts the measured lift of 4 by 4 cell means, ISO 6400 to 102400,
/// light from six to one stop under mid-gray, scenes darkened one to five stops, within 0.033,
/// 0.054 and 0.033 stops (RMS, red, green and blue) where the lift reaches two to three stops
/// (measured, `DarkLevelMeasureTests`). The half for red and blue matches a bilinear demosaic's 9/16
/// to within 6 percent (first principles); the quarter for green is measured.
public struct DecodedNoise: Sendable, Equatable {
    /// Variance at no light, in decoded units squared, red, green and blue.
    public var read: SIMD3<Float>
    /// Variance per decoded unit of light.
    public var shot: SIMD3<Float>

    public init(read: SIMD3<Float>, shot: SIMD3<Float>) {
        self.read = read
        self.shot = shot
    }

    /// The share of one photosite's variance left at the decoder's clip, red, green, blue: round
    /// values within the fit's noise (docs/M3-auto.md, section 16).
    public static let clipVarianceShare = SIMD3<Float>(0.5, 0.25, 0.5)

    /// The noise of a frame Apple's decoder made under `AppleRawDecoder`'s pins from a raw of
    /// `model` at `iso`, or `nil` when the body has no noise profile, the decode is not RAW 8, or the
    /// raw mode is not one the model was measured on: uncompressed, and lossless L, which stores the
    /// same samples. Lossless M and S are YCbCr, and the lossy compressed mode requantizes its samples,
    /// so neither is the modelled noise (review 5). RAW 9 denoises before any clip, and its lift is not
    /// this model's: on the CC0 scene darkened 2, 3.5 and 5 stops it reads within 0.035 stops of its
    /// ISO 250 level up to ISO 12800 and within 0.15 to 102400, and the lift does not grow with the
    /// darkening (+0.144 stops two stops under at 102400, -0.006 five under), so nothing is taken out
    /// of its decodes (measured 2026-10-19, docs/decoder.md section 18).
    public static func appleDecode(model: String, iso: Int?, pins: DecodePins?) -> DecodedNoise? {
        guard let iso, iso > 0, let pins, pins.decoderVersion == AppleRawDecoder.pinnedDecoderVersion,
              let body = BodyProfile.named(model), let noise = body.noise,
              let modeName = pins.rawMode, let mode = body.modes.first(where: { $0.name == modeName }),
              [.uncompressed, .losslessBayer].contains(mode.encoding) else { return nil }
        let sensor = noise.sensorNoise(iso: Double(iso))
        // The decode's gain against the one the units were measured at: below ISO 100 the anchor
        // gives less, and a mode adds its own.
        let gain = exp2(pins.exposureGainStops + pins.modeExposureStops - ExposureAnchor.gainStops())
        let units = noise.decodedUnitsPerDN * gain
        let share = clipVarianceShare
        return DecodedNoise(read: share * units * units * Float(sensor.read), shot: share * units * Float(sensor.shot))
    }

    static let halfSqrt2: Float = 0.70710678
    /// The standard normal density at zero, 1 / sqrt(2 pi).
    static let normalPeak: Float = 0.39894228

    /// The noise's standard deviation in channel `c` under light `t`.
    public func sigma(_ t: Float, channel c: Int) -> Float { (read[c] + shot[c] * max(t, 0)).squareRoot() }

    /// What light `t` decodes to on average in channel `c`: `E[max(t + n, 0)]`.
    public func lifted(_ t: Float, channel c: Int) -> Float {
        let s = sigma(t, channel: c)
        guard s > 0 else { return max(t, 0) }
        let z = t / s
        return t * 0.5 * (1 + erf(z * Self.halfSqrt2)) + s * exp(-z * z / 2) * Self.normalPeak
    }

    /// The light whose average decode is `v`, channel by channel: zero where `v` is no more than
    /// what no light decodes to, `v` itself where the lift is negligible (over five deviations).
    public func unlifted(_ v: SIMD3<Float>) -> SIMD3<Float> {
        var t = v
        for c in 0..<3 {
            let value = v[c]
            guard value > 0, value < 5 * sigma(value, channel: c) else { continue }
            guard value > lifted(0, channel: c) else { t[c] = 0; continue }
            // The lift grows the value and is convex in the light, so Newton's method from the
            // value itself walks down to the root without overshooting.
            var x = value
            for _ in 0..<12 {
                let s = sigma(x, channel: c), z = x / s
                let cdf = 0.5 * (1 + erf(z * Self.halfSqrt2)), pdf = exp(-z * z / 2) * Self.normalPeak
                let f = x * cdf + s * pdf - value
                let slope = cdf + pdf * shot[c] / (2 * s)
                let next = max(0, x - f / max(slope, 1e-6))
                if abs(next - x) <= 1e-5 * max(value, 1e-6) { x = next; break }
                x = next
            }
            t[c] = x
        }
        return t
    }
}
