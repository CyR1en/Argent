import Foundation
import Metal

/// Dehaze, Clarity and Texture on scene light, inside the Negative LUT pass and the halation source: every Negative kernel calls
/// `scene_at` where it called `manual_scene_at` (`ShaderSource.sceneArguments`), so the film and its glow see the same light. For a
/// pixel with untouched light `I`, its luminance `Y` and guide `g` before Exposure:
///
///     dehazed = A + (I - A) G(t),  t = clamp(a_d log2(max(Y, floor)) + b_d, tMin, 1)      Dehaze, first, on light before Exposure
///     stops   = Σ k m(L*(base)) (g - base), held to ±detailLimit        Clarity and Texture
///     out     = manual_scene_of(dehazed, I) * 2^stops
///     tone    = log2(max(A_Y + (y - A_Y) G(t), floor)),  y = 2^base, t read at log2(max(y, floor))   Auto's tone step's base under Dehaze
///
/// `manual_scene_of` is any compiler's Light mapping, made from `manual_scene_at`'s own text: its Exposure multiplies the dehazed
/// light, which is Dehaze with `2^E A`, and Contrast, Whites and Blacks read the dehazed light. On the gain-table compilers Highlights
/// and Shadows read their base from the untouched frame. `2026-10-09-1` has no base, so its Highlights and Shadows weigh the dehazed
/// pixel's own level (`PresenceLightMappingTests`). Auto's tone step, in the toned kernels, reads the untouched base taken through
/// Dehaze's map (`presence_dehazed_base`). Clarity's and Texture's stops add to its gains, so their gains multiply. With every scene control at 0,
/// `scene_at` is `manual_scene_at` itself, a branch on `active`. The block's layout is fixed (`PresenceSceneParameters`); this file
/// writes what fills it and what reads it. With `active` 1 and every stage off, `scene_at` must render `manual_scene_at`'s bytes
/// (`PresenceRenderTests`).
enum PresenceScene {
    /// The scene inputs for `manual`'s Presence on this render: the block filled from the laws at each value, the side's tables named
    /// in `weights`, the fields from `analysis` (Clarity's for the side its value is on), and `maximumGainStops`. `.bypass` when no scene
    /// control is set.
    static func inputs(_ manual: ManualRenderSettings, constants: PresenceConstants, analysis: PresenceAnalysis,
                       weights: (tables: PresenceToneWeights, buffer: MTLBuffer)?) throws -> PresenceSceneInputs {
        let presence = manual.adjustments.presence
        guard presence.acts(in: .scene) else { return .bypass }
        var inputs = PresenceSceneInputs(analysis: analysis)
        var q = PresenceSceneParameters()
        q.active = 1
        let dehaze = presence.value(for: .dehaze)
        if dehaze != 0 {
            guard let haze = analysis.haze else { preconditionFailure("the analysis holds the parts Presence reads") }
            let law = constants.dehaze
            (q.airlightR, q.airlightG, q.airlightB) = (haze.airlight.x, haze.airlight.y, haze.airlight.z)
            q.airlightLuminance = ToneBaseField.luminance(haze.airlight)
            q.minimumTransmission = law.minimumTransmission
            q.hazeGuideFloor = PresenceAnalysisBuilder.hazeGuideFloor
            if dehaze > 0 {
                q.dehaze = 1
                q.kappa = law.kappa.at(dehaze)
                if let fade = law.fade { (q.fade, q.fadeStart, q.fadeEnd) = (1, fade.startRatio, fade.endRatio) }
                // t^-kappa at the least transmission; the negative side only pulls light toward the airlight.
                inputs.maximumGainStops += q.kappa * -log2(law.minimumTransmission)
            } else {
                q.dehaze = 2
                q.hazeShare = law.hazeShare.at(dehaze)
                q.hazePower = law.hazePower.at(dehaze)
            }
            inputs.dehaze = haze.transmission
        }
        let clarity = presence.value(for: .clarity), texture = presence.value(for: .texture)
        if clarity != 0 || texture != 0 {
            guard let weights else { preconditionFailure("Clarity and Texture read the tone weights") }
            q.weightCount = UInt32(PresenceToneWeights.samplesPerTable)
            q.weightStart = weights.tables.start
            q.weightScale = 1 / weights.tables.step
            // `ManualCurveParameters.guideOffset`, which the oldest compiler's block leaves out: a base in the guide's units, before
            // Exposure, to stops from the reference after it.
            q.weightOffset = manual.adjustments.exposureEV + manual.referenceStops - log2(Float(0.18))
            q.detailLimit = constants.detailLimitStops
            inputs.weights = weights.buffer
            inputs.maximumGainStops += constants.detailLimitStops
            if clarity != 0 {
                guard let fields = analysis.clarity else { preconditionFailure("the analysis holds the parts Presence reads") }
                q.clarityStrength = constants.clarity.side(for: clarity).strength.at(clarity)
                q.clarityWeights = UInt32(weights.tables.offset(of: clarity > 0 ? .clarityPositive : .clarityNegative))
                inputs.clarity = clarity > 0 ? fields.positive : fields.negative
            }
            if texture != 0 {
                guard let band = analysis.texture else { preconditionFailure("the analysis holds the parts Presence reads") }
                q.textureStrength = constants.texture.side(for: texture).strength.at(texture)
                q.textureWeights = UInt32(weights.tables.offset(of: texture > 0 ? .texturePositive : .textureNegative))
                inputs.texture = band.coefficients
            }
        }
        inputs.parameters = q
        return inputs
    }

    /// The CPU reference of `scene_at` for one pixel, given what the GPU reads at it: its untouched light, the fields' coefficients at
    /// its uv (`FieldSample`), the weights, and the Light mapping's two-input form (`ManualRenderSettings.applyingScene`'s arithmetic
    /// with the local base read at the untouched pixel). The kernels are held to it, and it to the fits' prototypes.
    static func applying(to rgb: SIMD3<Float>, inputs: PresenceSceneInputs, at sample: FieldSample, weights: PresenceToneWeights?,
                         light: (_ light: SIMD3<Float>, _ untouched: SIMD3<Float>) throws -> SIMD3<Float>) throws -> SIMD3<Float> {
        let q = inputs.parameters
        guard q.active != 0 else { return try light(rgb, rgb) }
        return try light(dehazed(rgb, q, at: sample.dehaze), rgb) * exp2(detailStops(guide: ToneBaseField.guide(rgb), q, at: sample, weights: weights))
    }

    /// The fields' coefficients at one pixel, interpolated as `tone_base_log2` does (`ToneBaseField.interpolated`).
    struct FieldSample {
        var clarity: SIMD2<Float>?
        var texture: SIMD2<Float>?
        var dehaze: SIMD2<Float>?
    }

    /// `presence_dehaze`.
    static func dehazed(_ rgb: SIMD3<Float>, _ q: PresenceSceneParameters, at coefficients: SIMD2<Float>?) -> SIMD3<Float> {
        guard q.dehaze != 0 else { return rgb }
        guard let ab = coefficients else { preconditionFailure("Dehaze reads its transmission at the pixel") }
        let guide = log2(Float.maximum(ToneBaseField.luminance(rgb), q.hazeGuideFloor))
        let t = min(max(ab.x * guide + ab.y, q.minimumTransmission), 1)
        var gain: Float
        if q.dehaze == 1 {
            gain = exp2(-q.kappa * log2(t))
            if q.fade != 0 {
                let ratio = ToneBaseField.luminance(rgb) / q.airlightLuminance
                gain = 1 + (gain - 1) * min(max((q.fadeEnd - ratio) / (q.fadeEnd - q.fadeStart), 0), 1)
            }
        } else {
            gain = 1 - q.hazeShare * (1 - exp2(q.hazePower * log2(t)))
        }
        let airlight = SIMD3(q.airlightR, q.airlightG, q.airlightB)
        return airlight + (rgb - airlight) * gain
    }

    /// `presence_dehazed_base`: the base, in log2 luminance before Exposure, of a grey at that level once Dehaze has taken it as it
    /// takes any light, its transmission read at its own level. Light Dehaze takes below black is held at the floor of Dehaze's own
    /// guide, the darkest base, so a region further below black never reads brighter.
    static func dehazedBase(_ base: Float, _ q: PresenceSceneParameters, at coefficients: SIMD2<Float>?) -> Float {
        guard q.dehaze != 0 else { return base }
        let light = ToneBaseField.luminance(dehazed(SIMD3(repeating: exp2(base)), q, at: coefficients))
        return ToneBaseField.limited(log2(.maximum(light, q.hazeGuideFloor)))
    }

    /// `presence_detail_stops`.
    static func detailStops(guide: Float, _ q: PresenceSceneParameters, at sample: FieldSample, weights: PresenceToneWeights?) -> Float {
        func side(_ strength: Float, _ offset: UInt32, _ coefficients: SIMD2<Float>?) -> Float {
            guard strength != 0 else { return 0 }
            guard let ab = coefficients, let weights else { preconditionFailure("a detail side reads its field and the weights at the pixel") }
            let base = ab.x * guide + ab.y
            return strength * weight(weights.samples, offset: offset, at: base + q.weightOffset, q) * (guide - base)
        }
        let stops = side(q.clarityStrength, q.clarityWeights, sample.clarity) + side(q.textureStrength, q.textureWeights, sample.texture)
        return min(max(stops, -q.detailLimit), q.detailLimit)
    }

    /// `presence_tone_weight`: the table from `offset` at `x` stops, by the block's geometry, as `PresenceToneWeights.value` reads it.
    static func weight(_ samples: [Float], offset: UInt32, at x: Float, _ q: PresenceSceneParameters) -> Float {
        let scaled = (x - q.weightStart) * q.weightScale
        let position = scaled.isNaN ? 0 : min(max(scaled, 0), Float(q.weightCount - 1))
        let low = min(Int(position), Int(q.weightCount) - 2)
        let a = samples[Int(offset) + low], b = samples[Int(offset) + low + 1]
        return a + (b - a) * (position - Float(low))
    }
}

extension ShaderSource {
    /// Dehaze, Clarity and Texture's per-pixel functions, compiled into `lut3D` after the blocks and before `scene_at`; `PresenceScene`'s
    /// `dehazed`, `dehazedBase`, `detailStops` and `weight` are their CPU reference.
    static let presenceScene = """

    // Dehaze: the pixel's light before Exposure toward or away from the frame's airlight, O = A + (I - A) G(t), t read from the field
    // at the guide it was made under, log2 of the pixel's luminance before Exposure held to the floor. The second argument is Light's
    // guide, which reads another level below 0 and near the floor, so it is not read. The identity while q.dehaze is 0.
    static inline float3 presence_dehaze(float3 rgb, float, float2 uv, constant PresenceSceneParameters &q,
                                         texture2d<float, access::sample> dehaze) {
        if (q.dehaze == 0u) { return rgb; }
        float guide = log2(max(manual_luminance(rgb), q.hazeGuideFloor));
        float t = clamp(tone_base_log2(guide, uv, dehaze), q.minimumTransmission, 1.0f);
        float gain;
        if (q.dehaze == 1u) {
            gain = exp2(-q.kappa * log2(t));
            // Light brighter than the airlight (a lamp, a specular, the airlight's own patch) is not haze.
            if (q.fade != 0u) {
                float ratio = manual_luminance(rgb) / q.airlightLuminance;
                gain = 1.0f + (gain - 1.0f) * clamp((q.fadeEnd - ratio) / (q.fadeEnd - q.fadeStart), 0.0f, 1.0f);
            }
        } else {
            gain = 1.0f - q.hazeShare * (1.0f - exp2(q.hazePower * log2(t)));
        }
        float3 airlight = float3(q.airlightR, q.airlightG, q.airlightB);
        return airlight + (rgb - airlight) * gain;
    }

    // Auto's tone step's base under Dehaze: the untouched base, log2 luminance before Exposure, as a grey at that level through Dehaze's
    // own map, the transmission read at that level, so the step burns and dodges by the level of the light Dehaze leaves. It returns
    // log2 of that light's luminance held to the floor of Dehaze's own guide: light pushed below black is the darkest base, and a
    // guide of its magnitude would read it brighter the further below black it falls. Highlights and Shadows keep the untouched base,
    // since Lightroom's own compose with Dehaze from it (research R5). The identity while q.dehaze is 0.
    static inline float presence_dehazed_base(float base, float2 uv, constant PresenceSceneParameters &q,
                                              texture2d<float, access::sample> dehaze) {
        if (q.dehaze == 0u) { return base; }
        float y = exp2(base);
        float t = clamp(tone_base_log2(log2(max(y, q.hazeGuideFloor)), uv, dehaze), q.minimumTransmission, 1.0f);
        float gain;
        if (q.dehaze == 1u) {
            gain = exp2(-q.kappa * log2(t));
            if (q.fade != 0u) {
                float ratio = y / q.airlightLuminance;
                gain = 1.0f + (gain - 1.0f) * clamp((q.fadeEnd - ratio) / (q.fadeEnd - q.fadeStart), 0.0f, 1.0f);
            }
        } else {
            gain = 1.0f - q.hazeShare * (1.0f - exp2(q.hazePower * log2(t)));
        }
        float dehazed = q.airlightLuminance + (y - q.airlightLuminance) * gain;
        return clamp(log2(max(dehazed, q.hazeGuideFloor)), -40.0f, 40.0f);
    }

    // A side's tone weight: its table from `offset` in `weights` at `x` stops, linear between samples and constant past the ends, as
    // PresenceToneWeights.value reads it.
    static inline float presence_tone_weight(device const float *weights, uint offset, float x, constant PresenceSceneParameters &q) {
        float position = clamp((x - q.weightStart) * q.weightScale, 0.0f, float(q.weightCount - 1));
        uint low = min(uint(position), q.weightCount - 2);
        float a = weights[offset + low], b = weights[offset + low + 1];
        return a + (b - a) * (position - float(low));
    }

    // Clarity's and Texture's gain in stops: k m(L*(base)) (guide - base) for each, the base from its field at the pixel's guide, m from
    // its side's table in `weights`, the sum held to the limit. 0 while both strengths are 0.
    static inline float presence_detail_stops(float guide, float2 uv, constant PresenceSceneParameters &q,
                                              device const float *weights, texture2d<float, access::sample> clarity,
                                              texture2d<float, access::sample> texture) {
        float stops = 0.0f;
        if (q.clarityStrength != 0.0f) {
            float base = tone_base_log2(guide, uv, clarity);
            stops += q.clarityStrength * presence_tone_weight(weights, q.clarityWeights, base + q.weightOffset, q) * (guide - base);
        }
        if (q.textureStrength != 0.0f) {
            float base = tone_base_log2(guide, uv, texture);
            stops += q.textureStrength * presence_tone_weight(weights, q.textureWeights, base + q.weightOffset, q) * (guide - base);
        }
        return clamp(stops, -q.detailLimit, q.detailLimit);
    }

    """
}
