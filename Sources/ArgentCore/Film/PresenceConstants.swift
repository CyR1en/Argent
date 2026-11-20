import Foundation

/// Every number Presence's stages and analysis read that measurement chose, for one version. A version is data:
/// `scripts/presence/emit_constants.py` writes `PresenceConstants+<version>.swift` from the inputs in `scripts/presence/<version>/`
/// (the fits' `constants.json` files, copied unchanged, and `method.json`), and a test runs it again and compares the bytes. No kernel
/// holds one of these: the scene stages take theirs through `PresenceSceneParameters` and the analysis, the print stages through
/// `PresencePrintParameters`, each filled from here per render.
///
/// A frame records the version it was made with (`Presence.version`), as the Light compilers' versions are recorded, so measuring
/// again means a new version beside the old once a frame may have saved one. Until Presence first lands, the validators' refreshes
/// rewrite this version's inputs in place: no recipe holds it yet.
public struct PresenceConstants: Sendable, Equatable {
    public let version: String
    /// The inputs it was written from, for `docs/provenance.md`.
    public let source: String
    public let texture: Texture
    public let clarity: Clarity
    public let dehaze: Dehaze
    public let saturation: Saturation
    public let vibrance: Vibrance
    /// The most Clarity's and Texture's summed stops may move a pixel, either way. It also bounds what the detail adds to the
    /// halation source's storage scale.
    public let detailLimitStops: Float

    /// Every version this build renders, oldest first. `Presence.supports(version:)` reads it.
    public static let all: [PresenceConstants] = [.v2026_11_11_1]

    public static func named(_ version: String) -> PresenceConstants? { all.first { $0.version == version } }

    /// `version`'s constants, or the error a render of a frame recorded under constants this build does not have stops with.
    static func required(_ version: String) throws -> PresenceConstants {
        guard let constants = named(version) else { throw ManualDevelopmentError.unsupportedVersion(version) }
        return constants
    }

    /// A strength against the slider's magnitude: linear between knots, constant past the last, as the fit scripts' `np.interp` on
    /// `|v|`. A law fitted as a smooth curve is written as dense knots, so a refresh never changes this type.
    public struct Law: Sendable, Equatable {
        /// Slider magnitudes, rising from 0 to 100.
        public let magnitudes: [Float]
        public let values: [Float]

        public func at(_ value: Float) -> Float {
            let x = abs(value)
            if x <= magnitudes[0] { return values[0] }
            for i in 1..<magnitudes.count where x < magnitudes[i] {
                let slope = (values[i] - values[i - 1]) / (magnitudes[i] - magnitudes[i - 1])
                return values[i - 1] + slope * (x - magnitudes[i - 1])
            }
            return values[values.count - 1]
        }
    }

    /// m over the print's CIE L* of a pixel's base level, at L* 0, 10, ..., 100: linear between, constant past the ends, as
    /// `fit_texture_clarity.py`'s `weight_at`.
    public struct ToneWeight: Sendable, Equatable {
        public static let lightness: [Float] = (0...10).map { Float($0 * 10) }
        public let values: [Float]

        public func at(lightness l: Float) -> Float {
            let knots = Self.lightness
            if l <= knots[0] { return values[0] }
            for i in 1..<knots.count where l < knots[i] {
                let slope = (values[i] - values[i - 1]) / (knots[i] - knots[i - 1])
                return values[i - 1] + slope * (l - knots[i - 1])
            }
            return values[values.count - 1]
        }
    }

    /// One side of Clarity or Texture: `delta = k(v) m(L*) D` stops, `k` signed (negative on the negative side).
    public struct DetailSide: Sendable, Equatable {
        public let strength: Law
        public let weight: ToneWeight
    }

    /// Clarity (fits F1 and F1b, `clarity-guided`): a self-guided filter of log2 luminance per side, `ToneBaseField`'s math with these
    /// constants, on 1024-pixel fields made together from one guide pass.
    public struct Clarity: Sendable, Equatable {
        public let positiveField: ToneBaseParameters
        public let negativeField: ToneBaseParameters
        public let positive: DetailSide
        public let negative: DetailSide

        public func side(for value: Float) -> DetailSide { value > 0 ? positive : negative }
    }

    /// Texture (fit F1, `texture-guided-band`): one band for both sides, `D = g - (a g + b)` from a guided filter whose coefficients
    /// sit on a field `fieldShare` of the full-size picture's long side, its radius in full-size pixels, so both follow the decode.
    public struct Texture: Sendable, Equatable {
        public let radiusFramePixels: Float
        public let epsilon: Float
        public let coefficientRadiusShare: Float
        public let fieldShare: Float
        public let minimumFieldLongSide: Int
        public let positive: DetailSide
        public let negative: DetailSide

        public func side(for value: Float) -> DetailSide { value > 0 ? positive : negative }

        /// The band's field for a decode `decodeLongSide` pixels long of a picture `fullLongSide` long: the fit's `texture_band`,
        /// `min(decode, max(16, round(full * fieldShare)))` long (Python's `round`, to even), radius `radiusFramePixels` full-size
        /// pixels. 3504 long, radius 10, at 7008; the decode's own size, radius 6, at 2190.
        public func field(decodeLongSide: Int, fullLongSide: Int) -> ToneBaseParameters {
            let share = Int((Float(fullLongSide) * fieldShare).rounded(.toNearestOrEven))
            return ToneBaseParameters(radiusFraction: radiusFramePixels / Float(fullLongSide), epsilon: epsilon,
                                      fieldLongSide: min(decodeLongSide, max(minimumFieldLongSide, share)),
                                      coefficientRadiusShare: coefficientRadiusShare)
        }
    }

    /// Dehaze (fit F2, `dark-channel`): `O = A + (I - A) G(t)` on light before Exposure, `t = clamp(a g + b, minimumTransmission, 1)`,
    /// `(a, b)` from a field made from the untouched decode at `fieldLongSide`, `g` the pixel's own log2 luminance.
    public struct Dehaze: Sendable, Equatable {
        public let fieldLongSide: Int
        /// `t_raw = 1 - omega d`.
        public let omega: Float
        /// The airlight: the median colour of the top `1 - airlightQuantile` of the minimum channel eroded over `airlightRadius` of the
        /// field's long side, keeping only the brightest `1 - airlightBrightShare` of those when it is above 0.
        public let airlightRadius: Float
        public let airlightQuantile: Float
        public let airlightBrightShare: Float
        /// The normalised dark channel's erosion radius, a share of the field's long side; no dilation.
        public let darkRadius: Float
        /// The guided filter of `t_raw` under log2 luminance: its radius, epsilon in stops squared, and the coefficients' boxes.
        public let guide: ToneBaseParameters
        public let minimumTransmission: Float
        /// Positive values only: the gain fades to 1 between these multiples of the airlight's luminance. `nil` for no fade.
        public let fade: Fade?
        /// Positive values: `G = t^(-kappa(v))`.
        public let kappa: Law
        /// Negative values: `G = 1 - share(v) (1 - t^power(v))`.
        public let hazeShare: Law
        public let hazePower: Law

        public struct Fade: Sendable, Equatable {
            public let startRatio: Float
            public let endRatio: Float
        }
    }

    /// Saturation (fit F3, S-A): `c' = max(0, Y + (1 + s)(c - Y))`, `Y = luma · c` in linear Rec. 2020, `s = v / 100`. Nothing fitted.
    public struct Saturation: Sendable, Equatable {
        public let luma: SIMD3<Float>
    }

    /// Vibrance (fit F3, V-A), after Saturation: in linear ProPhoto, HSV saturation `S` times a gain, rolled off toward 1 above
    /// `saturationKnee`, and HSV value times `2^value`, each channel kept at its share between the smallest and the largest. The gain
    /// reads `S`, the Oklab hue and `l = log2(Y / lightnessReference)`.
    public struct Vibrance: Sendable, Equatable {
        /// Linear Rec. 2020 to linear ProPhoto and back, and ProPhoto to Oklab's LMS (adapted to D65, rows summing to 1).
        public let toProPhoto: Matrix3
        public let fromProPhoto: Matrix3
        public let proPhotoToLMS: Matrix3
        /// Oklab's a and b rows of M2, applied to the cube roots of LMS: the hue is `atan2(b, a)`.
        public let oklabA: SIMD3<Float>
        public let oklabB: SIMD3<Float>
        /// ProPhoto's luminance row, for `l`.
        public let proPhotoLuma: SIMD3<Float>
        public let lightnessReference: Float
        public let saturationKnee: Float
        public let positive: Positive
        public let negative: Negative
        /// The strength per stock id and sign; a stock not listed takes `defaultStrength`.
        public let strengths: [String: Strength]
        public let defaultStrength: Strength

        public func strength(for stockID: String) -> Strength { strengths[stockID] ?? defaultStrength }

        /// `1 + (a1 s + a2 s² + a3 s³) exp(-S / max(x0 + x0v (1 - s), minimumFallOff)) (1 - d B(h; hueCentre, hueWidth))
        /// exp(-((l - l0) / sigma)² / 2)`, B a raised cosine in degrees. The strength multiplies a1, a2 and a3.
        public struct Positive: Sendable, Equatable {
            public let a1: Float, a2: Float, a3: Float
            public let x0: Float, x0v: Float, minimumFallOff: Float
            public let d: Float, hueCentre: Float, hueWidth: Float
            public let l0: Float, sigma: Float
            public let value: ValueTerm
        }

        /// `1 - t (1 + kappa (1 - t)) (1 - c S^q)`, `t = -s`. The strength divides c.
        public struct Negative: Sendable, Equatable {
            public let c: Float, q: Float, kappa: Float
            public let value: ValueTerm
        }

        /// HSV value's scale in stops: `sign(s) (b1 |s| + b2 s²) S^alpha (1 - S)^beta exp(-((l - lv) / sv)² / 2)`.
        public struct ValueTerm: Sendable, Equatable {
            public let b1: Float, b2: Float, alpha: Float, beta: Float, lv: Float, sv: Float
        }

        public struct Strength: Sendable, Equatable {
            public let positive: Float
            public let negative: Float
        }
    }

    /// A 3 by 3 matrix by rows, applied to a column.
    public struct Matrix3: Sendable, Equatable {
        public let r0: SIMD3<Float>, r1: SIMD3<Float>, r2: SIMD3<Float>

        public func applied(to v: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3((r0 * v).sum(), (r1 * v).sum(), (r2 * v).sum())
        }
    }
}
