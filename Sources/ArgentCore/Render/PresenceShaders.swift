/// A function text Presence's two-input Light mapping is made from no longer reads as the derivation expects. It fails the first
/// render, in every test that renders, rather than map a dehazed pixel through a Light mapping that drifted from today's.
public enum PresenceShaderError: Error, Equatable, CustomStringConvertible {
    case editDidNotApply(function: String, text: String, count: Int)
    /// The derived function reads the untouched light in more or fewer places than the coverage and the local base.
    case untouchedReads(function: String, count: Int, expected: Int)

    public var description: String {
        switch self {
        case .editDidNotApply(let function, let text, let count):
            return "The function \(function) should have one \"\(text)\" and has \(count)."
        case .untouchedReads(let function, let count, let expected):
            return "The two-input form of \(function) reads the untouched pixel \(count) times, where \(expected) are expected."
        }
    }
}

extension ShaderSource {
    /// What every scene-mapping call passes after the pixel's light, in every Negative kernel and the halation source, and what the
    /// toned and masked generators look for: one text, so a kernel and its generators cannot disagree about it.
    static let sceneArguments = "uv, toneBase, toneTables, manual, presence, presenceWeights, clarityField, textureField, dehazeField"

    /// The Presence bindings of every Negative kernel and the halation source, after `toneTables` on a line of their own, so the
    /// generators' signature edit (`device const float *toneTables [[buffer(2)]],`) still applies once.
    static let presenceSceneSignature = """
    constant PresenceSceneParameters &presence [[buffer(8)]], device const float *presenceWeights [[buffer(9)]],
                                texture2d<float, access::sample> clarityField [[texture(10)]],
                                texture2d<float, access::sample> textureField [[texture(11)]],
                                texture2d<float, access::sample> dehazeField [[texture(12)]],
    """

    /// `manual_scene_of(light, rgb, …)`: any compiler's scene mapping of `light`, with its local base read at the untouched pixel
    /// `rgb`. On the gain-table compilers that base is a field made from the untouched frame, so Highlights and Shadows keep it after
    /// Dehaze while Exposure, Contrast, Whites and Blacks act on the dehazed light. `2026-10-09-1` has no local base: its Highlights and
    /// Shadows weigh the pixel's own level, so they weigh the dehazed light, which is how acting after Dehaze reads for a pointwise
    /// weight (`manual_scene(light, p)`). Made from `manual_scene_at`'s own text by exact edits, so the two cannot drift apart: with
    /// `light` equal to `rgb` it is the same arithmetic. `manual_scene_at` stays as it is, and a render without Presence reaches only it
    /// (`scene_at`).
    static let manualSceneOf: String = {
        do { return try twoInputs(manualSceneAt, function: "manual_scene_at", edits: manualSceneOfEdits, untouchedReads: 2) } catch {
            preconditionFailure("\(error)")
        }
    }()

    static let manualSceneOfEdits = [
        ("static inline float3 manual_scene_at(float3 rgb, ", "static inline float3 manual_scene_of(float3 light, float3 rgb, "),
        ("return manual_scene(rgb, p);", "return manual_scene(light, p);"),
        ("if (p.sceneActive == 0) { return rgb; }", "if (p.sceneActive == 0) { return light; }"),
        ("float3 exposed = rgb * p.exposureGain;", "float3 exposed = light * p.exposureGain;"),
        ("float guide = manual_guide(rgb);", "float guide = manual_guide(light), untouched = manual_guide(rgb);"),
        ("tone_base_log2(guide, uv, base)", "tone_base_log2(untouched, uv, base)"),
    ]

    /// The same for the masked Light mapping: the coverage and the local base read the untouched pixel, the rest the light.
    static let manualSceneMaskedOf: String = {
        do {
            return try twoInputs(manualSceneMaskedAt, function: "manual_scene_masked_at", edits: manualSceneMaskedOfEdits, untouchedReads: 3)
        } catch {
            preconditionFailure("\(error)")
        }
    }()

    static let manualSceneMaskedOfEdits = [
        ("static inline float3 manual_scene_masked_at(float3 rgb, ", "static inline float3 manual_scene_masked_of(float3 light, float3 rgb, "),
        ("float3 exposed = rgb * p.exposureGain;", "float3 exposed = light * p.exposureGain;"),
        ("float x = manual_guide(rgb);", "float x = manual_guide(light), untouched = manual_guide(rgb);"),
        ("tone_base_log2(x, uv, base) + p.baseOffset", "tone_base_log2(untouched, uv, base) + p.baseOffset"),
        ("tone_base_log2(x, uv, base) + m.referenceOffset", "tone_base_log2(untouched, uv, base) + m.referenceOffset"),
    ]

    /// `text` with `edits`, each of which must apply exactly once, and then reading the untouched pixel `rgb` in exactly
    /// `untouchedReads` places, its parameter included: a new read of `rgb` in the one-input text is a question for whoever adds it,
    /// whether the dehazed light or the untouched pixel is meant, and fails here until the edits answer it.
    static func twoInputs(_ text: String, function: String, edits: [(String, String)], untouchedReads: Int) throws -> String {
        var derived = text
        for (old, new) in edits {
            let count = derived.components(separatedBy: old).count - 1
            guard count == 1 else { throw PresenceShaderError.editDidNotApply(function: function, text: old, count: count) }
            derived = derived.replacingOccurrences(of: old, with: new)
        }
        let reads = derived.components(separatedBy: "rgb").count - 1
        guard reads == untouchedReads else {
            throw PresenceShaderError.untouchedReads(function: function, count: reads, expected: untouchedReads)
        }
        return derived
    }
}
