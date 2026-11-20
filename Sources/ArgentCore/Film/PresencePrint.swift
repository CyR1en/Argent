import Foundation

/// Saturation then Vibrance on the print, inside the Print LUT pass: after the Print LUT, so after Auto's balance and the print
/// exposure, and before the old compiler's print mapping and the tone curves (`manual_print(presence_print(rgb, …))` in both print
/// kernels and, through their generator, the toned ones). Pointwise, so it needs no field, and the preview and the develop differ
/// only by their decodes.
///
///     Saturation  c' = max(0, Y + (1 + s)(c - Y)),  Y = luma · c,  s = v / 100            (F3's S-A, linear Rec. 2020)
///     Vibrance    HSV S and V in linear ProPhoto moved by F3's V-A at s, the stock's strength per sign
///
/// With both at 0 `presence_print` returns its input: a branch on `active`, and one on each control. The block's layout is fixed
/// (`PresencePrintParameters`); this file writes what fills it and what reads it.
enum PresencePrint {
    /// The block for `presence` printed on the stock `stockID`, `.bypass` when neither control is set: Saturation's gain and luma,
    /// Vibrance's side, the matrices, and every slider-dependent term resolved at the value with the stock's strength.
    static func parameters(_ presence: Presence, constants: PresenceConstants, stockID: String) throws -> PresencePrintParameters {
        guard presence.acts(in: .print) else { return .bypass }
        var q = PresencePrintParameters()
        q.active = 1
        let saturation = presence.value(for: .saturation) / 100
        if saturation != 0 {
            q.saturation = 1
            q.saturationGain = 1 + saturation
            (q.lumaR, q.lumaG, q.lumaB) = PresencePrintParameters.three(constants.saturation.luma)
        }
        let s = presence.value(for: .vibrance) / 100
        if s != 0 {
            let v = constants.vibrance, strength = v.strength(for: stockID), t = abs(s)
            q.vibranceAmount = s
            q.toProPhoto = PresencePrintParameters.nine(v.toProPhoto)
            q.fromProPhoto = PresencePrintParameters.nine(v.fromProPhoto)
            q.proPhotoToLMS = PresencePrintParameters.nine(v.proPhotoToLMS)
            q.oklabA = PresencePrintParameters.three(v.oklabA)
            q.oklabB = PresencePrintParameters.three(v.oklabB)
            q.proPhotoLuma = PresencePrintParameters.three(v.proPhotoLuma)
            q.lightnessReference = v.lightnessReference
            q.saturationKnee = v.saturationKnee
            let value: PresenceConstants.Vibrance.ValueTerm
            if s > 0 {
                let p = v.positive
                q.vibrance = 1
                q.gainAmplitude = strength.positive * (p.a1 * s + p.a2 * s * s + p.a3 * s * s * s)
                q.fallOff = max(p.x0 + p.x0v * (1 - s), p.minimumFallOff)
                q.skinDepth = p.d
                q.skinCentre = p.hueCentre
                q.skinWidth = p.hueWidth
                q.lightnessCentre = p.l0
                q.lightnessWidth = p.sigma
                value = p.value
            } else {
                let n = v.negative
                q.vibrance = 2
                q.negativeAmount = t * (1 + n.kappa * (1 - t))
                q.keep = n.c / strength.negative
                q.keepPower = n.q
                value = n.value
            }
            q.valueAmount = (s > 0 ? 1 : -1) * (value.b1 * t + value.b2 * t * t)
            q.valueAlpha = value.alpha
            q.valueBeta = value.beta
            q.valueCentre = value.lv
            q.valueWidth = value.sv
        }
        return q
    }

    /// The CPU reference of `presence_print` for one print pixel, display-linear Rec. 2020, in the kernel's order of operations.
    static func applying(to rgb: SIMD3<Float>, parameters q: PresencePrintParameters) -> SIMD3<Float> {
        guard q.active != 0 else { return rgb }
        var c = rgb
        if q.saturation != 0 {
            let y = (SIMD3(q.lumaR, q.lumaG, q.lumaB) * c).sum()
            c = pointwiseMax(y + q.saturationGain * (c - y), .zero)
        }
        if q.vibrance != 0 { c = vibrance(c, q) }
        return c
    }

    private static func vibrance(_ c: SIMD3<Float>, _ q: PresencePrintParameters) -> SIMD3<Float> {
        let p = matrix(q.toProPhoto, c), clipped = pointwiseMax(p, .zero)
        let high = clipped.max(), low = clipped.min()
        guard high > 0 else { return c }
        let s = (high - low) / high
        let share = high > low ? (clipped - low) / (high - low) : .zero
        let lms = matrix(q.proPhotoToLMS, p)
        let cube = SIMD3(cbrt(lms.x), cbrt(lms.y), cbrt(lms.z))
        let hue = atan2((vector(q.oklabB) * cube).sum(), (vector(q.oklabA) * cube).sum()) * (180 / .pi)
        let lightness = log2(max((vector(q.proPhotoLuma) * p).sum(), 1e-9) / q.lightnessReference)
        let gain: Float
        if q.vibrance == 1 {
            var d = abs(hue - q.skinCentre).truncatingRemainder(dividingBy: 360)
            d = min(d, 360 - d)
            let skin: Float = d < q.skinWidth ? 0.5 * (1 + cos(.pi * d / q.skinWidth)) : 0
            gain = 1 + q.gainAmplitude * exp(-s / q.fallOff) * (1 - q.skinDepth * skin) * bell(lightness, q.lightnessCentre, q.lightnessWidth)
        } else {
            gain = 1 - q.negativeAmount * (1 - q.keep * pow(s, q.keepPower))
        }
        let value = high * exp2(q.valueAmount * pow(s, q.valueAlpha) * pow(1 - s, q.valueBeta) * bell(lightness, q.valueCentre, q.valueWidth))
        let saturated = min(max(knee(s, gain, q.saturationKnee), 0), 1)
        let bottom = value * (1 - saturated)
        return matrix(q.fromProPhoto, bottom + (value - bottom) * share)
    }

    private static func knee(_ x: Float, _ k: Float, _ t: Float) -> Float {
        if k <= 1 || x <= t / k { return k * x }
        let x0 = t / k
        let u = max((x - x0) / (1 - x0), 0)
        let a = k * (1 - x0) / (1 - t)
        return min(t + (1 - t) * a * u / (1 + (a - 1) * u), 1)
    }

    private static func bell(_ x: Float, _ centre: Float, _ width: Float) -> Float {
        let z = (x - centre) / width
        return exp(-0.5 * z * z)
    }

    private static func vector(_ v: PresencePrintParameters.Three) -> SIMD3<Float> { SIMD3(v.0, v.1, v.2) }

    private static func matrix(_ m: PresencePrintParameters.Nine, _ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3((SIMD3(m.0, m.1, m.2) * v).sum(), (SIMD3(m.3, m.4, m.5) * v).sum(), (SIMD3(m.6, m.7, m.8) * v).sum())
    }
}

extension ShaderSource {
    /// Saturation then Vibrance on the print (`PresencePrint`), compiled into `lut3D` after the blocks and before the print kernels.
    static let presencePrint = """

    static inline float3 presence_print_matrix(constant float *m, float3 v) {
        return float3(dot(float3(m[0], m[1], m[2]), v), dot(float3(m[3], m[4], m[5]), v), dot(float3(m[6], m[7], m[8]), v));
    }

    static inline float presence_print_knee(float x, float k, float t) {
        if (k <= 1.0f || x <= t / k) { return k * x; }
        float x0 = t / k;
        float u = max((x - x0) / (1.0f - x0), 0.0f);
        float a = k * (1.0f - x0) / (1.0f - t);
        return min(t + (1.0f - t) * a * u / (1.0f + (a - 1.0f) * u), 1.0f);
    }

    static inline float presence_print_bell(float x, float centre, float width) {
        float z = (x - centre) / width;
        return exp(-0.5f * z * z);
    }

    static inline float3 presence_print_vibrance(float3 c, constant PresencePrintParameters &q) {
        float3 p = presence_print_matrix(q.toProPhoto, c);
        float3 clipped = max(p, 0.0f);
        float high = max3(clipped.r, clipped.g, clipped.b), low = min3(clipped.r, clipped.g, clipped.b);
        if (high <= 0.0f) { return c; }
        float s = (high - low) / high;
        float3 share = high > low ? (clipped - low) / (high - low) : float3(0.0f);
        float3 lms = presence_print_matrix(q.proPhotoToLMS, p);
        // Metal has no cbrt, and powr below zero is undefined; deep blues and light outside the cube take L or S below zero.
        float3 cube = copysign(powr(abs(lms), 1.0f / 3.0f), lms);
        float hue = atan2(dot(float3(q.oklabB[0], q.oklabB[1], q.oklabB[2]), cube),
                          dot(float3(q.oklabA[0], q.oklabA[1], q.oklabA[2]), cube)) * (180.0f / M_PI_F);
        float lightness = log2(max(dot(float3(q.proPhotoLuma[0], q.proPhotoLuma[1], q.proPhotoLuma[2]), p), 1e-9f) / q.lightnessReference);
        float gain;
        if (q.vibrance == 1u) {
            float d = fmod(abs(hue - q.skinCentre), 360.0f);
            d = min(d, 360.0f - d);
            float skin = d < q.skinWidth ? 0.5f * (1.0f + cos(M_PI_F * d / q.skinWidth)) : 0.0f;
            gain = 1.0f + q.gainAmplitude * exp(-s / q.fallOff) * (1.0f - q.skinDepth * skin)
                 * presence_print_bell(lightness, q.lightnessCentre, q.lightnessWidth);
        } else {
            gain = 1.0f - q.negativeAmount * (1.0f - q.keep * powr(s, q.keepPower));
        }
        float value = high * exp2(q.valueAmount * powr(s, q.valueAlpha) * powr(1.0f - s, q.valueBeta)
                                  * presence_print_bell(lightness, q.valueCentre, q.valueWidth));
        float saturated = clamp(presence_print_knee(s, gain, q.saturationKnee), 0.0f, 1.0f);
        float bottom = value * (1.0f - saturated);
        return presence_print_matrix(q.fromProPhoto, bottom + (value - bottom) * share);
    }

    // Saturation, then Vibrance on its result, on the print's display-linear Rec. 2020 light after the Print LUT. The identity while
    // q.active is 0, and with both controls off.
    static inline float3 presence_print(float3 rgb, constant PresencePrintParameters &q) {
        if (q.active == 0u) { return rgb; }
        float3 c = rgb;
        if (q.saturation != 0u) {
            float y = dot(float3(q.lumaR, q.lumaG, q.lumaB), c);
            c = max(y + q.saturationGain * (c - y), 0.0f);
        }
        if (q.vibrance != 0u) { c = presence_print_vibrance(c, q); }
        return c;
    }

    """
}
