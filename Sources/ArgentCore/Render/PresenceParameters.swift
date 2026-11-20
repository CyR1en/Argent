import Metal

// The two blocks Presence's stages read on the GPU, in Swift and in Metal (`ShaderSource.presenceParameters`), complete: a stage
// package fills them per render and writes the functions that read them, and changes no layout. Every field is a 4-byte scalar or an
// array of them, so the two mirrors lay out alike; `PresenceParametersTests` holds them to it, name by name and offset by offset.
// Every value a slider moves is resolved on the CPU into these fields, once a render, so a kernel's per-pixel work reads only what
// its pixel brings.

/// Dehaze, Clarity and Texture, at buffer 8 of every Negative kernel and the halation source (`PresenceSceneInputs.bind`). For a
/// pixel with untouched light `I`, its luminance `Y` and guide `g` (`manual_guide`, log2 luminance before Exposure) at `uv`:
///
///     t       = clamp(a_d log2(max(Y, hazeGuideFloor)) + b_d, minimumTransmission, 1)   (a_d, b_d) from the Dehaze field at uv,
///                                                                     at the guide the field was made under
///     G       = t^(-kappa)                    dehaze 1, faded to 1 from fadeStart to fadeEnd times airlightLuminance when fade is 1
///             = 1 - hazeShare (1 - t^hazePower)   dehaze 2
///     dehazed = A + (I - A) G                                             A = airlight
///     base    = a g + b                                                   (a, b) from the Clarity or Texture field at uv
///     stops   = clamp(Σ k m(base + weightOffset) (g - base), -detailLimit, detailLimit)   k: clarityStrength, textureStrength
///     m(x)    = weights[w + clamp((x - weightStart) weightScale, 0, weightCount - 1)], linear between samples; w: the side's offset
///
/// The Light mapping then maps `dehazed` with its local base read at the untouched `g`, and its gain is multiplied by `2^stops`.
/// Auto's tone step takes that untouched base through the same `t`, `G` and `A`, as a grey at its level, and holds the luminance it
/// leaves to `hazeGuideFloor` (`presence_dehazed_base`).
struct PresenceSceneParameters: Sendable {
    static let bufferIndex = 8
    static let weightsIndex = 9
    /// Clarity's field (the side its value is on), Texture's band and Dehaze's transmission, at textures 10, 11 and 12.
    static let firstTextureIndex = 10

    /// 0: `scene_at` is `manual_scene_at`, today's text, and nothing below is read.
    var active: UInt32 = 0
    /// 0 off, 1 the positive side's law, 2 the negative side's.
    var dehaze: UInt32 = 0
    /// The frame's airlight in its light before Exposure, and its Rec. 2020 luminance.
    var airlightR: Float = 0
    var airlightG: Float = 0
    var airlightB: Float = 0
    var airlightLuminance: Float = 1
    var minimumTransmission: Float = 1
    /// `PresenceAnalysisBuilder.hazeGuideFloor`: the least luminance under the log of the guide the transmission's field was made under.
    var hazeGuideFloor: Float = 0
    /// The positive side at the slider's value.
    var kappa: Float = 0
    /// The negative side at the slider's value.
    var hazeShare: Float = 0
    var hazePower: Float = 1
    /// 1: the positive gain fades to 1 as the pixel's luminance goes from `fadeStart` to `fadeEnd` times the airlight's.
    var fade: UInt32 = 0
    var fadeStart: Float = 1
    var fadeEnd: Float = 2
    /// k at the slider's value, signed; 0 leaves the detail signal out. The weights' offset of its side's table, in samples.
    var clarityStrength: Float = 0
    var clarityWeights: UInt32 = 0
    var textureStrength: Float = 0
    var textureWeights: UInt32 = 0
    /// The tone weights' geometry: samples a table, stops from the manual reference at the first, samples a stop, and what takes a
    /// base in the guide's units to those stops (the reference and Exposure, as `ManualCurveParameters.guideOffset`).
    var weightCount: UInt32 = 0
    var weightStart: Float = 0
    var weightScale: Float = 0
    var weightOffset: Float = 0
    /// The constants' `detailLimitStops`.
    var detailLimit: Float = 0
}

/// Saturation then Vibrance on the print's display-linear Rec. 2020 light, at buffer 6 of both print kernels and their toned copies
/// (`manual_print(presence_print(rgb, …))`), after the Print LUT and before the old compiler's print mapping and the tone curves.
///
///     Saturation  c = max(0, Y + saturationGain (c - Y)),  Y = (lumaR, lumaG, lumaB) · c          saturation 1
///     Vibrance    p = toProPhoto c; V = max(p), S = (V - min(p)) / V, the hue h = atan2(oklabB · ∛(LMS p), oklabA · ∛(LMS p))
///                 in degrees, l = log2(max(proPhotoLuma · p, 1e-9) / lightnessReference)
///                 vibrance 1: gain = 1 + gainAmplitude exp(-S / fallOff) (1 - skinDepth B(h; skinCentre, skinWidth))
///                                    exp(-((l - lightnessCentre) / lightnessWidth)² / 2),  B a raised cosine
///                 vibrance 2: gain = 1 - negativeAmount (1 - keep S^keepPower)
///                 S' = clamp(knee(S, gain, saturationKnee), 0, 1), V' = V 2^(valueAmount S^valueAlpha (1 - S)^valueBeta
///                      exp(-((l - valueCentre) / valueWidth)² / 2)), each channel at its share from min to max; then fromProPhoto
///
/// `fit_colour.py`'s `sat_lightroom`, `vib_gain`, `vib_value`, `knee` and `vib_hsv` are the reference. Matrices are row-major.
struct PresencePrintParameters: Sendable {
    typealias Three = (Float, Float, Float)
    typealias Nine = (Float, Float, Float, Float, Float, Float, Float, Float, Float)
    static let bufferIndex = 6

    /// 0: `presence_print` returns its input, and nothing below is read.
    var active: UInt32 = 0
    var saturation: UInt32 = 0
    /// `1 + s`, s = v / 100.
    var saturationGain: Float = 1
    var lumaR: Float = 0
    var lumaG: Float = 0
    var lumaB: Float = 0
    /// 0 off, 1 the positive side, 2 the negative side.
    var vibrance: UInt32 = 0
    /// s = v / 100, signed.
    var vibranceAmount: Float = 0
    var toProPhoto: Nine = (0, 0, 0, 0, 0, 0, 0, 0, 0)
    var fromProPhoto: Nine = (0, 0, 0, 0, 0, 0, 0, 0, 0)
    var proPhotoToLMS: Nine = (0, 0, 0, 0, 0, 0, 0, 0, 0)
    var oklabA: Three = (0, 0, 0)
    var oklabB: Three = (0, 0, 0)
    var proPhotoLuma: Three = (0, 0, 0)
    var lightnessReference: Float = 0.18
    var saturationKnee: Float = 1
    /// The positive side, at the value: the stock's strength times `a1 s + a2 s² + a3 s³`, and `max(x0 + x0v (1 - s), minimumFallOff)`.
    var gainAmplitude: Float = 0
    var fallOff: Float = 1
    var skinDepth: Float = 0
    var skinCentre: Float = 0
    var skinWidth: Float = 1
    var lightnessCentre: Float = 0
    var lightnessWidth: Float = 1
    /// The negative side, at the value: `t (1 + kappa (1 - t))` with t = -s, and `c` over the stock's strength, and `q`.
    var negativeAmount: Float = 0
    var keep: Float = 0
    var keepPower: Float = 1
    /// HSV value's scale, at the value on its side: `sign(s) (b1 |s| + b2 s²)`, then alpha, beta, lv and sv.
    var valueAmount: Float = 0
    var valueAlpha: Float = 1
    var valueBeta: Float = 1
    var valueCentre: Float = 0
    var valueWidth: Float = 1

    static let bypass = PresencePrintParameters()

    static func nine(_ m: PresenceConstants.Matrix3) -> Nine {
        (m.r0.x, m.r0.y, m.r0.z, m.r1.x, m.r1.y, m.r1.z, m.r2.x, m.r2.y, m.r2.z)
    }

    static func three(_ v: SIMD3<Float>) -> Three { (v.x, v.y, v.z) }
}

extension ShaderSource {
    /// The two blocks in Metal, compiled into `lut3D` before the stages that read them. Their Swift mirrors are above.
    static let presenceParameters = """

    struct PresenceSceneParameters {
        uint active;
        uint dehaze;
        float airlightR;
        float airlightG;
        float airlightB;
        float airlightLuminance;
        float minimumTransmission;
        float hazeGuideFloor;
        float kappa;
        float hazeShare;
        float hazePower;
        uint fade;
        float fadeStart;
        float fadeEnd;
        float clarityStrength;
        uint clarityWeights;
        float textureStrength;
        uint textureWeights;
        uint weightCount;
        float weightStart;
        float weightScale;
        float weightOffset;
        float detailLimit;
    };

    struct PresencePrintParameters {
        uint active;
        uint saturation;
        float saturationGain;
        float lumaR;
        float lumaG;
        float lumaB;
        uint vibrance;
        float vibranceAmount;
        float toProPhoto[9];
        float fromProPhoto[9];
        float proPhotoToLMS[9];
        float oklabA[3];
        float oklabB[3];
        float proPhotoLuma[3];
        float lightnessReference;
        float saturationKnee;
        float gainAmplitude;
        float fallOff;
        float skinDepth;
        float skinCentre;
        float skinWidth;
        float lightnessCentre;
        float lightnessWidth;
        float negativeAmount;
        float keep;
        float keepPower;
        float valueAmount;
        float valueAlpha;
        float valueBeta;
        float valueCentre;
        float valueWidth;
    };

    """
}

/// What the Negative kernels and the halation source bind for Presence's scene stages, and what a render holds for them.
struct PresenceSceneInputs {
    var parameters = PresenceSceneParameters()
    /// The tone weights (`PresenceToneWeights.samples`) on the GPU; `nil` while neither Clarity nor Texture is set.
    var weights: MTLBuffer?
    /// The field each stage reads: Clarity's for the side its value is on, Texture's band, Dehaze's transmission.
    var clarity: MTLTexture?
    var texture: MTLTexture?
    var dehaze: MTLTexture?
    /// The analysis the fields came from. Holding it holds them while the command buffer runs, whatever the cache lets go meanwhile.
    var analysis: PresenceAnalysis?
    /// The most the stages can raise light, in stops: Dehaze's largest gain and the detail's limit. The halation source's storage scale
    /// adds it (`HalationField.storageStops`), so the glow the film gets stays finite in half floats.
    var maximumGainStops: Float = 0

    static var bypass: PresenceSceneInputs { PresenceSceneInputs() }

    /// The block at buffer 8, the weights at 9 and the fields at textures 10 to 12 (`ShaderSource.presenceSceneSignature`),
    /// placeholders for what is not read. Every Negative kernel and the halation source take the same indices.
    func bind(to encoder: MTLComputeCommandEncoder, placeholders: ManualSceneInputs.Placeholders) {
        var block = parameters
        encoder.setBytes(&block, length: MemoryLayout<PresenceSceneParameters>.stride, index: PresenceSceneParameters.bufferIndex)
        encoder.setBuffer(weights ?? placeholders.tables, offset: 0, index: PresenceSceneParameters.weightsIndex)
        encoder.setTexture(clarity ?? placeholders.base, index: PresenceSceneParameters.firstTextureIndex)
        encoder.setTexture(texture ?? placeholders.base, index: PresenceSceneParameters.firstTextureIndex + 1)
        encoder.setTexture(dehaze ?? placeholders.base, index: PresenceSceneParameters.firstTextureIndex + 2)
    }
}

/// One render's Presence: what the scene passes bind, and the print block. `FilmRenderer.presenceInputs` makes it, or a test gives it.
struct PresenceRenderInputs {
    var scene = PresenceSceneInputs.bypass
    var print = PresencePrintParameters.bypass

    static var bypass: PresenceRenderInputs { PresenceRenderInputs() }
}
