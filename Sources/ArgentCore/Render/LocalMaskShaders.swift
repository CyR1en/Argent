/// A kernel text the masked kernels are generated from no longer reads as the generator expects. It fails the first render with
/// masks, in every test that renders one, rather than print a frame through a kernel that lost its masks.
public enum LocalMaskShaderError: Error, Equatable, CustomStringConvertible {
    case kernelMissing(String)
    case editDidNotApply(kernel: String, text: String, count: Int)
    /// An edit left the plain scene mapping in a masked kernel, so that read would have ignored the masks.
    case unmaskedRead(kernel: String)

    public var description: String {
        switch self {
        case .kernelMissing(let name): return "The kernel \(name) is not in the shader source."
        case .editDidNotApply(let kernel, let text, let count):
            return "The kernel \(kernel) should have one \"\(text)\" and has \(count)."
        case .unmaskedRead(let kernel): return "The masked kernel \(kernel) still reads the scene without its masks."
        }
    }
}

extension ShaderSource {
    /// The kernels a frame with masks takes in place of today's: the Negative LUT pass with and without halation and the tone step, the
    /// halation source and the halo's mix. Print-stage kernels have no masked copy: a mask's balance reaches the print through the dye amounts
    /// the Negative LUT pass writes, where its coverage is already the pixel's own.
    static let localMaskKernels = ["apply_lut3d", "apply_lut3d_halation", "apply_lut3d_toned", "apply_lut3d_halation_toned",
                                   "halation_source", "halation_mix"]

    /// `name` with the suffix a masked kernel has.
    static func localMaskName(_ name: String) -> String { name + "_masked" }

    /// The whole second library's source (plan section 4, rule 4): what today's kernels call, then the evaluation, then the masked kernels
    /// made from today's kernels' own text, so a change to one reaches the other and today's keep their text. Each edit must apply once.
    static func localMaskLibrary() throws -> String {
        let shared = try [toneBase, lut3D, printTone].map(strippingKernels)
        var text = shared.joined(separator: "\n") + "\n" + localMaskEvaluation
        for name in localMaskKernels {
            text += try localMaskKernel(name, in: name.contains("toned") ? printTone : lut3D)
        }
        return text + localMaskCore
    }

    /// `source` without its kernels: the structs and functions the masked kernels call. Today's kernels are in the first library, and
    /// compiling them again would add about 90 ms to the first masked frame on a cold compile cache: 0.30 s against 0.39 s (measured).
    static func strippingKernels(_ source: String) throws -> String {
        var text = source + "\n"   // the last kernel of a source has no line after it
        while let start = text.range(of: "kernel void ") {
            guard let end = text.range(of: "\n}\n", range: start.upperBound..<text.endIndex) else {
                throw LocalMaskShaderError.kernelMissing(String(text[start.lowerBound...].prefix(60)))
            }
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return text
    }

    /// `name`'s kernel from `source` with the edits a masked kernel takes.
    static func localMaskKernel(_ name: String, in source: String) throws -> String {
        let opening = "kernel void \(name)("
        guard let start = source.range(of: opening), let end = source.range(of: "\n}\n", range: start.upperBound..<source.endIndex) else {
            throw LocalMaskShaderError.kernelMissing(name)
        }
        var kernel = String(source[start.lowerBound..<end.upperBound])
            .replacingOccurrences(of: opening, with: "kernel void \(localMaskName(name))(")
        for (old, new) in localMaskEdits(name) {
            let count = kernel.components(separatedBy: old).count - 1
            guard count == 1 else { throw LocalMaskShaderError.editDidNotApply(kernel: name, text: old, count: count) }
            kernel = kernel.replacingOccurrences(of: old, with: new)
        }
        // `scene_at(` is in `manual_scene_at(` too, so either plain read left behind fails here.
        guard !kernel.contains("scene_at(") else { throw LocalMaskShaderError.unmaskedRead(kernel: name) }
        return kernel + "\n"
    }

    /// Each kernel's edits. Tier 2 is in the signature and the evaluation from the start (plan section 4, "Edges and the two tiers"), so
    /// Phase 2 binds textures and sets a flag and cuts no kernel.
    private static func localMaskEdits(_ name: String) -> [(String, String)] {
        let signature = ("device const float *toneTables [[buffer(2)]],", """
        device const float *toneTables [[buffer(2)]], texture2d_array<float, access::sample> maskCoverage [[texture(5)]], \
        device const float *maskTables [[buffer(5)]], constant LocalMaskParameters &masks [[buffer(6)]], \
        constant LocalMaskRefinement &maskRefinement [[buffer(7)]], texture2d<float, access::sample> maskRefined0 [[texture(6)]], \
        texture2d<float, access::sample> maskRefined1 [[texture(7)]], texture2d<float, access::sample> maskRefined2 [[texture(8)]], \
        texture2d<float, access::sample> maskRefined3 [[texture(9)]],
        """)
        let refinedArguments = "maskRefinement, maskRefined0, maskRefined1, maskRefined2, maskRefined3)"
        let masked = sceneArguments + ", maskCoverage, maskTables, masks, " + refinedArguments
        switch name {
        case "halation_source":
            // The storage scale has a limit (`LocalMaskInputs.storageStopsLimit`), past which only light far beyond the film can clip.
            return [signature,
                    ("scene_at(float3(frame.read(uint2(x, y)).rgb), \(sceneArguments))",
                     "scene_masked_at(float3(frame.read(uint2(x, y)).rgb), " + masked),
                    ("out.write(half4(float4(averaged, 1.0f)), gid);",
                     "out.write(half4(float4(min(averaged, float3(\(halfLargest))), 1.0f)), gid);")]
        case "halation_mix":
            // Plain `halation_mix` already caps at the largest finite half float, which summed masks need too; keep the line
            // checked so an edit that drops the cap fails here.
            let capped = "out.write(half4(float4(min(sum.r * p.red, \(halfLargest)), min(sum.g * p.green, \(halfLargest)), 0.0f, 1.0f)), gid);"
            return [(capped, capped)]
        default:
            // The balance joins the dye amounts the print pass shifts by Lab balance, so it is the same move, in the same units, per pixel. It
            // is skipped altogether while no mask carries one, so a mask without one keeps its bits.
            return [signature, ("scene_at(float3(pixel.rgb), \(sceneArguments))",
                                "scene_masked_at(float3(pixel.rgb), " + masked),
                    ("float3 rgb = sample_tetrahedral(lut, encoded, params.lutSize);",
                     "float3 rgb = sample_tetrahedral(lut, encoded, params.lutSize);\n        if (masks.balanceAny != 0u && params.silverR == 0.0f) { rgb += local_balance_at(float3(pixel.rgb), uv, maskCoverage, masks, " + refinedArguments + "; }")]
        }
    }

    /// The largest finite half float.
    private static let halfLargest = "65504.0f"

    /// A smart mask's refined coverage, in the one text every library that evaluates it compiles: the masked kernels (tier 2, per
    /// pixel), the coverage bake (tier 1, per slice texel) and the refiner, whose coefficients are made against this guide. The guide is
    /// log luminance and chroma of the untouched decode, each over 8 (R8, R9); `MaskRefiner.guide` is the same in Swift.
    static let maskRefinedFunctions = """
        // The guide tier 2's coefficients are made against: log luminance and chroma of the untouched decode, each over 8 (R8, R9).
        static inline float3 mask_refined_guide(float3 rgb) {
            rgb = max(rgb, float3(0.0f));
            float y = dot(rgb, float3(0.2627f, 0.6780f, 0.0593f));
            float d = 1e-4f;
            return float3(log2(y + d), log2((rgb.b + d) / (y + d)), log2((rgb.r + d) / (y + d))) / 8.0f;
        }

        static inline float mask_refined(float3 guide, float2 uv, texture2d<float, access::sample> coefficients) {
            constexpr sampler cs(filter::linear, address::clamp_to_edge, coord::normalized);
            float4 k = coefficients.sample(cs, uv);
            return clamp(dot(k.xyz, guide) + k.w, 0.0f, 1.0f);
        }
        """

    /// The masked Light mapping of a frame pixel's own light, as the masked library compiles it: one text, so the two-input form
    /// Presence's Dehaze needs (`manualSceneMaskedOf`) is made from it and not kept beside it.
    static let manualSceneMaskedAt = """
        static inline float3 manual_scene_masked_at(float3 rgb, float2 uv, texture2d<float, access::sample> base,
                                                    device const float *tables, constant ManualCurveParameters &p,
                                                    texture2d_array<float, access::sample> coverage, device const float *maskTables,
                                                    constant LocalMaskParameters &m, constant LocalMaskRefinement &r,
                                                    texture2d<float, access::sample> k0, texture2d<float, access::sample> k1,
                                                    texture2d<float, access::sample> k2, texture2d<float, access::sample> k3) {
            float4 c0, c1, c2, c3;
            local_coverage_at(rgb, uv, coverage, m, r, k0, k1, k2, k3, c0, c1, c2, c3);
            LocalSliders s = local_sliders(c0, c1, c2, c3, m);
            float3 exposed = rgb * p.exposureGain;
            if (s.exposure != 0.0f) { exposed *= exp2(s.exposure); }
            if (p.localActive == 0u && p.globalActive == 0u && m.localAny == 0u && m.toneAny == 0u) { return exposed; }
            float x = manual_guide(rgb);
            if (local_tone_is_zero(s)) {
                float local = p.localActive != 0u ? manual_table(tables + p.tableCount, tone_base_log2(x, uv, base) + p.baseOffset, p) : 0.0f;
                return exposed * exp2(local_panel_gain(x, local, s.exposure, tables, p));
            }
            float u = x + p.guideOffset + s.exposure;
            float ub = (p.localActive != 0u || s.highlights != 0.0f || s.shadows != 0.0f)
                ? tone_base_log2(x, uv, base) + m.referenceOffset : 0.0f;
            return exposed * exp2(local_gain(u, ub, s, tables, p, maskTables, m));
        }
        """

    /// One evaluation of summed sliders (plan section 4's E1, T3's section 9), `LocalScene` line for line. Offsets and axes are the tables'
    /// layout, so they are constants here and the parameter block holds only what an edit changes.
    private static let localMaskEvaluation: String = {
        typealias L = LocalScene.Layout
        let levels = L.samples, lastLevel = L.samples - 1, lastKnot = L.knots - 1
        let saturating = LocalScene.saturatingAxis, extending = LocalScene.extendingAxis
        return """

        // Mirrors LocalMaskParameters in Swift: written on every slider or Amount move, 592 bytes. By mask slot k at [k / 4][k % 4],
        // Amount × value, Exposure in stops. A mask that is off is 0 here, so nothing reads what its channel holds.
        struct LocalMaskParameters {
            float4 exposure[4];
            float4 highlights[4];
            float4 shadows[4];
            float4 contrast[4];
            float4 whites[4];
            float4 blacks[4];
            uint maskCount;
            uint sliceCount;
            float referenceOffset;     // LocalScene.referenceOffset, the one read of the base: the masks' and the panel's
            float tableStart;
            float tableScale;
            float panelHighlights;     // H0 and S0, and 1 / k(H0) - 1, 1 / k(S0) - 1
            float panelShadows;
            float highlightsFade;
            float shadowsFade;
            uint localAny;             // some mask carries Highlights or Shadows
            uint toneAny;              // some mask carries Contrast, Whites or Blacks
            uint balanceAny;           // some mask carries a balance
            float4 warmth[4];          // By slot, as the Light controls: Amount × value
            float4 magenta[4];
            float4 warmthAxis;         // One unit of each slider in the Print LUT's dye units, per channel
            float4 magentaAxis;
        };

        // Tier 2. Bit i: coefficient texture i takes the coverage of mask slot slot[i], at the pixel, inverted where invert's bit i is set;
        // or, where composed's bit i is set, c0 + (c1 - c0) v from the composed fields in slots low and low + 1, low in composedSlots'
        // bits 4i to 4i + 3: the mask's own composition with the refined value v, as the bake makes it at a texel.
        struct LocalMaskRefinement {
            uint refined;
            uint invert;
            uint composed;
            uint composedSlots;
            uint4 slot;
        };

        \(maskRefinedFunctions)

        struct LocalSliders {
            float exposure, highlights, shadows, contrast, whites, blacks;
        };

        static inline float local_sum(float4 c0, float4 c1, float4 c2, float4 c3, constant float4 *values) {
            return dot(c0, values[0]) + dot(c1, values[1]) + dot(c2, values[2]) + dot(c3, values[3]);
        }

        // sX = Σ c·A·V, one dot product a slice whatever the number of masks. The two guards are uniforms: an Exposure mask pays for one.
        static inline LocalSliders local_sliders(float4 c0, float4 c1, float4 c2, float4 c3, constant LocalMaskParameters &m) {
            LocalSliders s;
            s.exposure = clamp(local_sum(c0, c1, c2, c3, m.exposure), \(-LocalScene.exposureLimit)f, \(LocalScene.exposureLimit)f);
            s.highlights = m.localAny != 0u ? local_sum(c0, c1, c2, c3, m.highlights) : 0.0f;
            s.shadows = m.localAny != 0u ? local_sum(c0, c1, c2, c3, m.shadows) : 0.0f;
            s.contrast = m.toneAny != 0u ? local_sum(c0, c1, c2, c3, m.contrast) : 0.0f;
            s.whites = m.toneAny != 0u ? local_sum(c0, c1, c2, c3, m.whites) : 0.0f;
            s.blacks = m.toneAny != 0u ? local_sum(c0, c1, c2, c3, m.blacks) : 0.0f;
            return s;
        }

        // A gain table over level and slider: linear in both, constant past both axes' ends. The level's arithmetic is manual_table's.
        static inline float local_table(device const float *table, float start, float spacing, float level, float value,
                                        constant LocalMaskParameters &m) {
            float position = clamp((value - start) / spacing, 0.0f, \(lastKnot).0f);
            uint knot = uint(position);
            uint next = min(knot + 1u, \(lastKnot)u);
            float fraction = position - float(knot);
            float scaled = clamp((level - m.tableStart) * m.tableScale, 0.0f, \(lastLevel).0f);
            uint low = min(uint(scaled), \(lastLevel - 1)u);
            float along = scaled - float(low);
            device const float *r0 = table + knot * \(levels)u + low;
            device const float *r1 = table + next * \(levels)u + low;
            float a = r0[0] + (r0[1] - r0[0]) * along;
            float b = r1[0] + (r1[1] - r1[0]) * along;
            return a + (b - a) * fraction;
        }

        static inline float local_saturating(device const float *table, float level, float value, constant LocalMaskParameters &m) {
            return local_table(table, \(saturating.start)f, \(saturating.spacing)f, level, value, m);
        }

        static inline float local_extending(device const float *table, float level, float value, constant LocalMaskParameters &m) {
            return local_table(table, \(extending.start)f, \(extending.spacing)f, level, value, m);
        }

        // Highlights or Shadows over the panel's: along one row, from the panel's value to the sum, with k's share of the panel's row
        // fading out over the mask's first |P| of slider. With no panel value, the row at the mask's value and no second read.
        static inline float local_move(device const float *table, float level, float value, float panel, float fade,
                                       constant LocalMaskParameters &m) {
            float moved = local_saturating(table, level, panel + value, m);
            if (panel == 0.0f) { return moved; }
            return moved - local_saturating(table, level, panel, m) * (1.0f + min(fabs(value) / fabs(panel), 1.0f) * fade);
        }

        // A row of the stretch: linear in the slider, on the extending axis.
        static inline float local_row(device const float *row, float value) {
            float position = clamp((value - \(extending.start)f) / \(extending.spacing)f, 0.0f, \(lastKnot).0f);
            uint knot = uint(position);
            uint next = min(knot + 1u, \(lastKnot)u);
            return row[knot] + (row[next] - row[knot]) * (position - float(knot));
        }

        // Whites and Blacks below 0 as one levels stretch in lightness, softly limited as the tables' gains are.
        static inline float local_stretch(device const float *tables, float level, float whites, float blacks,
                                          constant LocalMaskParameters &m) {
            float black = local_row(tables + \(L.blackPoint)u, blacks);
            float white = local_row(tables + \(L.whitePoint)u, whites);
            float scaled = clamp((level - m.tableStart) * m.tableScale, 0.0f, \(lastLevel).0f);
            uint low = min(uint(scaled), \(lastLevel - 1)u);
            device const float *r = tables + \(L.regularized)u + low;
            float inside = clamp(level, m.tableStart, m.tableStart + \(lastLevel).0f / m.tableScale);
            float lightness = r[0] + (r[1] - r[0]) * (scaled - float(low)) + (level - inside) * \(ManualToneTables.minimumSlope)f;
            float v = (lightness - black) / (white - black);
            float c = clamp(v, 0.0f, 1.0f);
            float aim = 100.0f * c + \(100 * ManualToneTables.minimumTargetSlope)f * (v - c);
            float q = clamp((aim - \(L.inverseStart)f) * \(L.inverseScale)f, 0.0f, \(L.inverseCount - 1).0f);
            uint q0 = min(uint(q), \(L.inverseCount - 2)u);
            device const float *i = tables + \(L.inverse)u + q0;
            float g = i[0] + (i[1] - i[0]) * (q - float(q0)) - level;
            float a = fabs(g);
            float knee = \(ManualToneTables.gainKnee)f, room = \(ManualToneTables.gainLimit - ManualToneTables.gainKnee)f;
            return a <= knee ? g : copysign(knee + room * tanh((a - knee) / room), g);
        }

        // The evaluation's core: the gain in stops from the pixel's level after all Exposure and its base's level before any.
        static inline float local_gain(float u, float ub, LocalSliders s, device const float *tables, constant ManualCurveParameters &p,
                                       device const float *maskTables, constant LocalMaskParameters &m) {
            float t = p.localActive != 0u ? manual_table(tables + p.tableCount, ub, p) : 0.0f;
            if (s.highlights != 0.0f) {
                t += local_move(maskTables + \(L.highlights)u, ub, s.highlights, m.panelHighlights, m.highlightsFade, m);
            }
            if (s.shadows != 0.0f) {
                t += local_move(maskTables + \(L.shadows)u, ub, s.shadows, m.panelShadows, m.shadowsFade, m);
            }
            if (p.globalActive != 0u) { t += manual_table(tables, u + t, p); }
            if (s.contrast != 0.0f) { t += local_extending(maskTables + \(L.contrast)u, u + t, s.contrast, m); }
            if (s.whites != 0.0f && s.blacks < 0.0f) {
                float level = u + t;
                float stretch = local_stretch(maskTables, level, s.whites, s.blacks, m);
                float size = min(fabs(s.whites), fabs(s.blacks));
                if (size >= \(LocalScene.stretchBlendWidth)f) {
                    t += stretch;
                } else {
                    float first = local_extending(maskTables + \(L.whites)u, level, s.whites, m);
                    float sequence = first + local_extending(maskTables + \(L.blacks)u, level + first, s.blacks, m);
                    float v = size / \(LocalScene.stretchBlendWidth)f;
                    t += sequence + (stretch - sequence) * (v * v * (3.0f - 2.0f * v));
                }
            } else {
                if (s.whites != 0.0f) { t += local_extending(maskTables + \(L.whites)u, u + t, s.whites, m); }
                if (s.blacks != 0.0f) { t += local_extending(maskTables + \(L.blacks)u, u + t, s.blacks, m); }
            }
            return clamp(t, \(-LocalScene.gainLimit)f, \(LocalScene.gainLimit)f);
        }

        static inline bool local_tone_is_zero(LocalSliders s) {
            return s.highlights == 0.0f && s.shadows == 0.0f && s.contrast == 0.0f && s.whites == 0.0f && s.blacks == 0.0f;
        }

        // The same on a pixel no mask's tone reaches, in manual_scene_at's own form: this sum is local_gain's with its branches gone. `local`
        // is the panel's local table, read by the caller in the one expression manual_scene_at has: the compiler rounds that much as it rounds
        // today's, and with the read apart from it three times as many values lie a half-ulp off (measured). It reads with baseOffset, the
        // panel's read, which equals referenceOffset on any compiler that takes a mask.
        static inline float local_panel_gain(float x, float local, float exposure, device const float *tables, constant ManualCurveParameters &p) {
            float global = p.globalActive != 0u ? manual_table(tables, x + p.guideOffset + exposure + local, p) : 0.0f;
            return clamp(local + global, \(-LocalScene.gainLimit)f, \(LocalScene.gainLimit)f);
        }

        // The coverage at the pixel: the slices sampled, then tier 2's refined layers in place of theirs, from the pixel's own light.
        static inline void local_coverage_at(float3 rgb, float2 uv, texture2d_array<float, access::sample> coverage,
                                             constant LocalMaskParameters &m, constant LocalMaskRefinement &r,
                                             texture2d<float, access::sample> k0, texture2d<float, access::sample> k1,
                                             texture2d<float, access::sample> k2, texture2d<float, access::sample> k3,
                                             thread float4 &c0, thread float4 &c1, thread float4 &c2, thread float4 &c3) {
            constexpr sampler cs(filter::linear, address::clamp_to_edge, coord::normalized);
            c0 = coverage.sample(cs, uv, 0);
            c1 = m.sliceCount > 1u ? coverage.sample(cs, uv, 1) : float4(0.0f);
            c2 = m.sliceCount > 2u ? coverage.sample(cs, uv, 2) : float4(0.0f);
            c3 = m.sliceCount > 3u ? coverage.sample(cs, uv, 3) : float4(0.0f);
            if (r.refined != 0u) {
                float3 g = mask_refined_guide(rgb);
                float4 c[4] = { c0, c1, c2, c3 };
                float4 v = float4(0.0f);
                if ((r.refined & 1u) != 0u) { v.x = mask_refined(g, uv, k0); }
                if ((r.refined & 2u) != 0u) { v.y = mask_refined(g, uv, k1); }
                if ((r.refined & 4u) != 0u) { v.z = mask_refined(g, uv, k2); }
                if ((r.refined & 8u) != 0u) { v.w = mask_refined(g, uv, k3); }
                // The composed fields are read before any slot is written: they sit after the masks', never in a refined slot.
                float4 low = float4(0.0f), high = float4(0.0f);
                for (uint i = 0u; i < 4u; i++) {
                    if ((r.composed & (1u << i)) == 0u) { continue; }
                    uint at = (r.composedSlots >> (4u * i)) & 15u;
                    low[i] = c[at / 4u][at % 4u];
                    high[i] = c[(at + 1u) / 4u][(at + 1u) % 4u];
                }
                for (uint i = 0u; i < 4u; i++) {
                    if ((r.refined & (1u << i)) == 0u) { continue; }
                    uint s = r.slot[i];
                    float value = (r.composed & (1u << i)) != 0u ? clamp(low[i] + (high[i] - low[i]) * v[i], 0.0f, 1.0f)
                                : ((r.invert & (1u << i)) != 0u ? 1.0f - v[i] : v[i]);
                    c[s / 4u][s % 4u] = value;
                }
                c0 = c[0]; c1 = c[1]; c2 = c[2]; c3 = c[3];
            }
        }

        // The masks' balance at the pixel in dye amounts, added to what the Negative LUT pass writes: Σ c·A·V along the two axes, the coverage
        // tier 2's where it has one. The sums are held to `MaskBalance.sumLimit`, and the print's own saturate holds the result in the LUT.
        static inline float3 local_balance_at(float3 rgb, float2 uv, texture2d_array<float, access::sample> coverage,
                                              constant LocalMaskParameters &m, constant LocalMaskRefinement &r,
                                              texture2d<float, access::sample> k0, texture2d<float, access::sample> k1,
                                              texture2d<float, access::sample> k2, texture2d<float, access::sample> k3) {
            float4 c0, c1, c2, c3;
            local_coverage_at(rgb, uv, coverage, m, r, k0, k1, k2, k3, c0, c1, c2, c3);
            float limit = \(MaskBalance.sumLimit)f;
            float warmth = clamp(local_sum(c0, c1, c2, c3, m.warmth), -limit, limit);
            float magenta = clamp(local_sum(c0, c1, c2, c3, m.magenta), -limit, limit);
            return warmth * m.warmthAxis.xyz + magenta * m.magentaAxis.xyz;
        }

        // manual_scene_at with masks: the guide before any Exposure, the coverage at the pixel, tier 2's refined layers in place of theirs,
        // the summed sliders, and one evaluation. The base is read only where something on this pixel reads it.
        \(manualSceneMaskedAt)

        // The same mapping of `light` with the coverage and the local base read at the untouched pixel `rgb`: made from the text above by
        // exact edits (PresenceShaders.swift), for Presence's Dehaze (scene_masked_at).
        \(manualSceneMaskedOf)

        // scene_at with masks: Presence's scene stages round the masked Light mapping, as scene_at puts them round the panel's.
        static inline float3 scene_masked_at(float3 rgb, float2 uv, texture2d<float, access::sample> base,
                                             device const float *tables, constant ManualCurveParameters &p,
                                             constant PresenceSceneParameters &q, device const float *weights,
                                             texture2d<float, access::sample> clarity, texture2d<float, access::sample> texture,
                                             texture2d<float, access::sample> dehaze,
                                             texture2d_array<float, access::sample> coverage, device const float *maskTables,
                                             constant LocalMaskParameters &m, constant LocalMaskRefinement &r,
                                             texture2d<float, access::sample> k0, texture2d<float, access::sample> k1,
                                             texture2d<float, access::sample> k2, texture2d<float, access::sample> k3) {
            if (q.active == 0u) { return manual_scene_masked_at(rgb, uv, base, tables, p, coverage, maskTables, m, r, k0, k1, k2, k3); }
            float guide = manual_guide(rgb);
            return manual_scene_masked_of(presence_dehaze(rgb, guide, uv, q, dehaze), rgb, uv, base, tables, p, coverage, maskTables,
                                          m, r, k0, k1, k2, k3)
                * exp2(presence_detail_stops(guide, uv, q, weights, clarity, texture));
        }

        """
    }()

    /// The evaluation on numbers from a buffer, for parity with `LocalScene` without the sampler in the way, as `tone_base_map` is for
    /// the base: per input the guide, the base and sixteen coverages; per output `t` and the summed Exposure.
    private static let localMaskCore = """

    // Each pixel's coverage of one slot as the masked kernels see it, tier 2 included, from the same function: for tests, which hold
    // tier 2 to `MaskRefiner`'s CPU reference and the bake to it. One float a pixel, row 0 the picture's bottom.
    kernel void local_mask_coverage_probe(texture2d<half, access::read> frame [[texture(0)]],
                                          texture2d_array<float, access::sample> maskCoverage [[texture(5)]],
                                          constant LocalMaskParameters &masks [[buffer(6)]],
                                          constant LocalMaskRefinement &maskRefinement [[buffer(7)]],
                                          texture2d<float, access::sample> maskRefined0 [[texture(6)]],
                                          texture2d<float, access::sample> maskRefined1 [[texture(7)]],
                                          texture2d<float, access::sample> maskRefined2 [[texture(8)]],
                                          texture2d<float, access::sample> maskRefined3 [[texture(9)]],
                                          device float *outputs [[buffer(0)]],
                                          constant uint &slot [[buffer(1)]],
                                          uint2 gid [[thread_position_in_grid]]) {
        uint width = frame.get_width(), height = frame.get_height();
        if (gid.x >= width || gid.y >= height) { return; }
        float2 uv = (float2(gid) + 0.5f) / float2(width, height);
        float4 c0, c1, c2, c3;
        local_coverage_at(float3(frame.read(gid).rgb), uv, maskCoverage, masks, maskRefinement, maskRefined0, maskRefined1,
                          maskRefined2, maskRefined3, c0, c1, c2, c3);
        float4 c[4] = { c0, c1, c2, c3 };
        outputs[gid.y * width + gid.x] = c[slot / 4u][slot % 4u];
    }

    // The overlay's sharp raster (`GPU.regionCoverage`): what the probe reads, over one region of the decode, top row first, to 8 bits. A
    // pixel takes the decode texel its centre lies in and that texel's uv, so at `step` 1 it is the print's own pixel.
    struct LocalMaskCoverageRegion {
        uint2 origin;
        float2 step;
    };

    kernel void local_mask_coverage_region(texture2d<half, access::read> frame [[texture(0)]],
                                           texture2d<float, access::write> out [[texture(1)]],
                                           texture2d_array<float, access::sample> maskCoverage [[texture(5)]],
                                           constant LocalMaskParameters &masks [[buffer(6)]],
                                           constant LocalMaskRefinement &maskRefinement [[buffer(7)]],
                                           texture2d<float, access::sample> maskRefined0 [[texture(6)]],
                                           texture2d<float, access::sample> maskRefined1 [[texture(7)]],
                                           texture2d<float, access::sample> maskRefined2 [[texture(8)]],
                                           texture2d<float, access::sample> maskRefined3 [[texture(9)]],
                                           constant LocalMaskCoverageRegion &region [[buffer(0)]],
                                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) { return; }
        uint width = frame.get_width(), height = frame.get_height();
        uint2 top = region.origin + uint2(floor((float2(gid) + 0.5f) * region.step));
        uint2 at = uint2(min(top.x, width - 1u), height - 1u - min(top.y, height - 1u));
        float2 uv = (float2(at) + 0.5f) / float2(width, height);
        float4 c0, c1, c2, c3;
        local_coverage_at(float3(frame.read(at).rgb), uv, maskCoverage, masks, maskRefinement, maskRefined0, maskRefined1,
                          maskRefined2, maskRefined3, c0, c1, c2, c3);
        out.write(float4(c0.x), gid);
    }

    kernel void local_mask_core(device const float *inputs [[buffer(0)]], device float *outputs [[buffer(1)]],
                                device const float *tables [[buffer(2)]], constant ManualCurveParameters &p [[buffer(3)]],
                                device const float *maskTables [[buffer(5)]], constant LocalMaskParameters &m [[buffer(6)]],
                                uint gid [[thread_position_in_grid]]) {
        device const float *in = inputs + gid * 18u;
        LocalSliders s = local_sliders(float4(in[2], in[3], in[4], in[5]), float4(in[6], in[7], in[8], in[9]),
                                       float4(in[10], in[11], in[12], in[13]), float4(in[14], in[15], in[16], in[17]), m);
        float local = p.localActive != 0u ? manual_table(tables + p.tableCount, in[1] + p.baseOffset, p) : 0.0f;
        outputs[gid * 2u] = local_tone_is_zero(s) ? local_panel_gain(in[0], local, s.exposure, tables, p)
            : local_gain(in[0] + p.guideOffset + s.exposure, in[1] + m.referenceOffset, s, tables, p, maskTables, m);
        outputs[gid * 2u + 1u] = s.exposure;
    }

    """
}
