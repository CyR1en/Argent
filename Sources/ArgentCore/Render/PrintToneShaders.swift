extension ShaderSource {
    /// The tone step's kernels (`PrintTone`), compiled after `lut3D`. Each is made from an untoned kernel's own text, so
    /// a change to one reaches the other, and the untoned kernels stay as they are: a print without a tone step
    /// keeps its bytes (`LightCompilerBaselineTests`).
    ///
    /// The Negative LUT pass has the frame's light, so it writes each pixel's local base, in stops against 0.18, to the
    /// density's alpha, and takes from the light going in the share of colour the table's `w` gives for that base. Under Dehaze
    /// that base is the untouched one taken through Dehaze's map (`presence_dehazed_base`), so the step reads the level of the light
    /// it acts on. The print pass looks up the offset for that base in the render's table (`PrintToneTable`), per
    /// channel, and adds it to the dye amounts, so it moves the print's exposure as print exposure does, and grain, keyed to
    /// the film's own amounts, is not moved.
    static let printTone: String = """

    // Where the table's first entry and its spacing sit, in stops against 0.18. It mirrors PrintToneTableInfo in Swift.
    struct PrintToneTableInfo {
        float start;
        float step;
        uint count;
        uint unused;
    };

    // A pixel's local base, from the same field and the same guide before Exposure as the manual tone controls read. Under Dehaze the
    // toned kernels then take it through Dehaze's map, and the manual tone controls keep it.
    static inline half print_tone_base(half4 pixel, float2 uv, texture2d<float, access::sample> base) {
        return half(tone_base_log2(manual_guide(float3(pixel.rgb)), uv, base) - log2(0.18f));
    }

    // The offset in dye amounts for the base the Negative LUT pass left in the alpha, between the table's entries.
    static inline float3 print_tone_amounts(half4 pixel, constant float4 *table, constant PrintToneTableInfo &info) {
        float position = clamp((float(pixel.a) - info.start) / info.step, 0.0f, float(info.count - 1));
        uint low = min(uint(position), info.count - 2);
        return mix(table[low].rgb, table[low + 1].rgb, position - float(low));
    }

    // A burn's share of the scene's colour taken away, keeping luminance, for the base the pixel has, between the table's
    // entries. It is for pale light: skies measure 0.17 to 0.34 of their luminance from brightest channel to darkest, and
    // flowers and coloured lights 1.3 to 2.3, so it is all gone by 1 and a burned flower or lamp keeps its colour.
    static inline float3 print_tone_colour(float3 scene, float baseStops, constant float4 *table, constant PrintToneTableInfo &info) {
        float position = clamp((baseStops - info.start) / info.step, 0.0f, float(info.count - 1));
        uint low = min(uint(position), info.count - 2);
        float share = mix(table[low].a, table[low + 1].a, position - float(low));
        float luminance = dot(scene, float3(0.2627f, 0.6780f, 0.0593f));
        float spread = max(max(scene.r, scene.g), scene.b) - min(min(scene.r, scene.g), scene.b);
        share *= 1.0f - smoothstep(0.5f, 1.0f, spread / max(luminance, 1e-4f));
        return mix(scene, float3(luminance), share);
    }

    """ + toned("apply_lut3d", edits: plainNegativeEdits)
        + toned("apply_lut3d_halation", edits: halationNegativeEdits)
        + toned("apply_print_lut", edits: printEdits + [("print_amounts(float3(pixel.rgb), float3(pixel.rgb),",
                                                        "print_amounts(float3(pixel.rgb) + print_tone_amounts(pixel, toneTable, toneInfo), float3(pixel.rgb),")])
        + toned("apply_print_lut_sharpened", edits: printEdits + [("print_amounts(float3(pixel.rgb) + detail, float3(pixel.rgb),",
                                                                  "print_amounts(float3(pixel.rgb) + detail + print_tone_amounts(pixel, toneTable, toneInfo), float3(pixel.rgb),")])

    private static let negativeEdits = [
        ("device const float *toneTables [[buffer(2)]],",
         "device const float *toneTables [[buffer(2)]], constant float4 *toneTable [[buffer(3)]], constant PrintToneTableInfo &toneInfo [[buffer(4)]],"),
        ("outTexture.write(half4(half3(rgb), pixel.a), gid);", "outTexture.write(half4(half3(rgb), localBase), gid);"),
    ]

    // Today's line stays as it is and the dehazed base is made from what it leaves. Folded into one expression, or chosen by a
    // ternary, the compiler's rounding moved 6,954 of 98 million print values at Dehaze 0 (research R5).
    private static let localBaseLines = "half localBase = print_tone_base(pixel, uv, toneBase);\n        "
        + "if (presence.dehaze != 0u) { localBase = half(presence_dehazed_base(float(localBase) + log2(0.18f), uv, presence, dehazeField) - log2(0.18f)); }"

    private static let plainNegativeEdits = negativeEdits + [
        ("float3 encoded = encode_log(scene_at(float3(pixel.rgb), \(sceneArguments)), params);",
         localBaseLines + "\n        float3 encoded = encode_log(print_tone_colour(scene_at(float3(pixel.rgb), \(sceneArguments)), float(localBase), toneTable, toneInfo), params);"),
    ]

    // Halation is the film's own glow, so it joins after the burn has taken its colour.
    private static let halationNegativeEdits = negativeEdits + [
        ("float3 linear = scene_at(float3(pixel.rgb), \(sceneArguments)) + halation.sample(field, uv).rgb;",
         localBaseLines + "\n        float3 linear = print_tone_colour(scene_at(float3(pixel.rgb), \(sceneArguments)), float(localBase), toneTable, toneInfo) + halation.sample(field, uv).rgb;"),
    ]

    private static let printEdits = [
        ("constant ToneCurveParameters &curveParams [[buffer(3)]],",
         "constant ToneCurveParameters &curveParams [[buffer(3)]], constant float4 *toneTable [[buffer(4)]], constant PrintToneTableInfo &toneInfo [[buffer(5)]],"),
        ("silver_storage(stored, params), pixel.a), gid);", "silver_storage(stored, params), half(1.0f)), gid);"),
    ]

    /// `name`'s kernel from `lut3D`, called `name_toned`, with `edits` made. Each edit must apply: a kernel that no longer
    /// reads as expected fails when the library is built, in every test that renders.
    private static func toned(_ name: String, edits: [(String, String)]) -> String {
        let opening = "kernel void \(name)("
        guard let start = lut3D.range(of: opening), let end = lut3D.range(of: "\n}\n", range: start.upperBound..<lut3D.endIndex) else {
            preconditionFailure("the kernel \(name) is not in the shader source")
        }
        var kernel = String(lut3D[start.lowerBound..<end.upperBound]).replacingOccurrences(of: opening, with: "kernel void \(name)_toned(")
        for (old, new) in edits {
            precondition(kernel.contains(old), "the kernel \(name) no longer has: \(old)")
            kernel = kernel.replacingOccurrences(of: old, with: new)
        }
        return kernel + "\n"
    }
}
