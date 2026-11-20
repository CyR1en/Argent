extension ShaderSource {
    /// Follow edges' kernels (task L): the colour test a stroke in progress paints with, and the replay of strokes that kept a measured
    /// shape. Compiled after `maskCoverage`'s and `brushCanvas`'s text, whose `brush_dab`, `brush_half` and `brush_compose` it shares, in a
    /// library of its own the first time a Follow edges stroke is painted or laid (`MaskFieldCache`), so the brush library a plain stroke
    /// uses keeps its text and its bits.
    ///
    /// The colour test is R8's (section 7.6): a texel's light, as the guide frame holds it (the untouched decode area-averaged to the
    /// slice), taken to Oklab, against the colour of a dab, the mean light of the 7 × 7 slice texels about its centre taken to Oklab; the
    /// dab's value there is multiplied by `1 − smoothstep((Δ − near)/(far − near))`. A stroke's shape is then the largest of its weighted
    /// dabs, as a plain stroke's is of its dabs.
    static let followEdges = """
    struct FollowParams {
        float near;             // the colour test's distances in Oklab: weight 1 below near, 0 beyond far
        float far;
        uint sampleRadius;      // a dab's colour is the mean of (2 r + 1)^2 slice texels
        uint count;             // dabs to colour
        uint width;             // the slice
        uint height;
        uint pad0;
        uint pad1;
    };

    // A measured stroke, as BrushMeasuredGPU in Swift: its raster's first texel in the slice (from the picture's top), its size, where its
    // bytes start, whether the slice is the one it was measured over (then texel for texel), and if not, the texel pitch of that one;
    // then how it is laid, as BrushStrokeGPU.
    struct BrushMeasuredGPU {
        int x;
        int y;
        uint width;
        uint height;
        uint offset;
        uint same;
        float2 recordedTexelToPoint;
        float flow;
        uint erase;
    };

    // Rec. 2020 linear light to Oklab, through linear sRGB (R8's prototype, its matrices).
    static inline float3 follow_oklab(float3 rgb) {
        float3 s = max(float3(1.6605f * rgb.r - 0.5876f * rgb.g - 0.0728f * rgb.b,
                              -0.1246f * rgb.r + 1.1329f * rgb.g - 0.0083f * rgb.b,
                              -0.0182f * rgb.r - 0.1006f * rgb.g + 1.1187f * rgb.b), float3(0.0f));
        float l = powr(max(0.4122214708f * s.r + 0.5363325363f * s.g + 0.0514459929f * s.b, 1e-12f), 1.0f / 3.0f);
        float m = powr(max(0.2119034982f * s.r + 0.6806995451f * s.g + 0.1073969566f * s.b, 1e-12f), 1.0f / 3.0f);
        float q = powr(max(0.0883024619f * s.r + 0.2817188376f * s.g + 0.6299787005f * s.b, 1e-12f), 1.0f / 3.0f);
        return float3(0.2104542553f * l + 0.7936177850f * m - 0.0040720468f * q,
                      1.9779984951f * l - 2.4285922050f * m + 0.4505937099f * q,
                      0.0259040371f * l + 0.7827717662f * m - 0.8086757660f * q);
    }

    static inline float follow_weight(float distance, constant FollowParams &f) {
        float t = clamp((distance - f.near) / (f.far - f.near), 0.0f, 1.0f);
        return 1.0f - t * t * (3.0f - 2.0f * t);
    }

    // The guide frame's light at a slice texel (row 0 the picture's bottom): read where the guide frame is the slice's size, and sampled
    // at the texel's centre where it is a smaller decode itself, as the refinement samples it.
    static inline float3 follow_light(texture2d<float, access::sample> guide, uint2 px, uint width, uint height) {
        if (guide.get_width() == width && guide.get_height() == height) { return guide.read(px).rgb; }
        constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
        return guide.sample(s, (float2(px) + 0.5f) / float2(width, height)).rgb;
    }

    // Each dab's colour: the mean light of the slice texels about the texel its centre lies in (`at`, from the picture's top, worked out
    // on the CPU so it is exact), clamped to the slice, then Oklab.
    kernel void follow_dab_colours(texture2d<float, access::sample> guide [[texture(0)]],
                                   constant FollowParams &f [[buffer(0)]],
                                   device const int2 *at [[buffer(1)]],
                                   device float4 *colours [[buffer(2)]],
                                   uint gid [[thread_position_in_grid]]) {
        if (gid >= f.count) { return; }
        int r = int(f.sampleRadius);
        float3 sum = float3(0.0f);
        for (int dy = -r; dy <= r; dy++) {
            for (int dx = -r; dx <= r; dx++) {
                int x = clamp(at[gid].x + dx, 0, int(f.width) - 1), top = clamp(at[gid].y + dy, 0, int(f.height) - 1);
                sum += follow_light(guide, uint2(uint(x), f.height - 1u - uint(top)), f.width, f.height);
            }
        }
        colours[gid] = float4(follow_oklab(sum / float((2 * r + 1) * (2 * r + 1))), 0.0f);
    }

    // brush_tick with the colour test: each dab's value at a texel weighted by how near the texel's colour is to the dab's.
    kernel void brush_tick_follow(texture2d<float, access::read> base [[texture(0)]],
                                  texture2d<float, access::read_write> stroke [[texture(1)]],
                                  texture2d<float, access::write> live [[texture(2)]],
                                  texture2d<float, access::sample> guide [[texture(3)]],
                                  constant BrushCanvasParams &p [[buffer(0)]],
                                  device const BrushDabGPU *fresh [[buffer(1)]],
                                  device const BrushDabGPU *tail [[buffer(2)]],
                                  device const uint *freshOffsets [[buffer(3)]],
                                  device const uint *freshList [[buffer(4)]],
                                  device const uint *tailOffsets [[buffer(5)]],
                                  device const uint *tailList [[buffer(6)]],
                                  constant FollowParams &f [[buffer(7)]],
                                  device const float4 *freshColours [[buffer(8)]],
                                  device const float4 *tailColours [[buffer(9)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        uint2 px = uint2(p.originX, p.originY) + gid;
        if (px.x >= p.width || px.y >= p.height) return;
        float2 q = brush_point(px, p);
        uint tile = (px.y / p.tile) * p.tilesX + px.x / p.tile;
        float3 here = follow_oklab(follow_light(guide, px, p.width, p.height));
        float held = stroke.read(px).r;
        float made = held;
        for (uint k = freshOffsets[tile]; k < freshOffsets[tile + 1u]; k++) {
            uint i = freshList[k];
            float v = brush_dab(q, fresh[i]);
            if (v > made) made = max(made, v * follow_weight(length(here - freshColours[i].xyz), f));
        }
        made = brush_half(made);
        if (made != held) stroke.write(float4(made, 0.0f, 0.0f, 0.0f), px);
        float shown = made;
        for (uint k = tailOffsets[tile]; k < tailOffsets[tile + 1u]; k++) {
            uint i = tailList[k];
            float v = brush_dab(q, tail[i]);
            if (v > shown) shown = max(shown, v * follow_weight(length(here - tailColours[i].xyz), f));
        }
        live.write(float4(brush_compose(base.read(px).r, brush_half(shown), p.flow, p.erase), 0.0f, 0.0f, 0.0f), px);
    }

    // A measured stroke's value at a slice texel: its raster's texel, texel for texel on the slice it was measured over, else the texel of
    // that slice the point lies in; 0 outside it. k / 255 as a product, as BrushField has it.
    static inline float follow_measured(uint2 px, float2 q, BrushMeasuredGPU m, device const uchar *shapes, constant BrushCanvasParams &p) {
        int2 at;
        if (m.same != 0u) {
            at = int2(int(px.x), int(p.height - 1u - px.y)) - int2(m.x, m.y);
        } else {
            at = int2(floor(q / m.recordedTexelToPoint)) - int2(m.x, m.y);
        }
        if (at.x < 0 || at.y < 0 || at.x >= int(m.width) || at.y >= int(m.height)) return 0.0f;
        return float(shapes[m.offset + uint(at.y) * m.width + uint(at.x)]) * (1.0f / 255.0f);
    }

    // A run of measured strokes laid onto `base` (or onto 0) into `canvas`, in order, over a region from (originX, originY): each stroke's
    // shape is its raster's value, laid as any stroke is (brush_compose). A plain stroke never comes here: its dabs are laid by
    // brush_replay or brush_tick in the brush library, so a plain stroke has one arithmetic whichever brush it is in. Where a raster does
    // not reach, its stroke lays 0, which leaves the canvas as it is, so it is skipped.
    kernel void brush_lay_measured(texture2d<float, access::read> base [[texture(0)]],
                                   texture2d<float, access::write> canvas [[texture(1)]],
                                   constant BrushCanvasParams &p [[buffer(0)]],
                                   device const BrushMeasuredGPU *measured [[buffer(1)]],
                                   device const uchar *shapes [[buffer(2)]],
                                   constant uint &count [[buffer(3)]],
                                   uint2 gid [[thread_position_in_grid]]) {
        uint2 px = uint2(p.originX, p.originY) + gid;
        if (px.x >= p.width || px.y >= p.height) return;
        float2 q = brush_point(px, p);
        float c = p.hasBase != 0u ? base.read(px).r : 0.0f;
        for (uint k = 0u; k < count; k++) {
            float s = follow_measured(px, q, measured[k], shapes, p);
            if (s > 0.0f) c = brush_compose(c, brush_half(s), measured[k].flow, measured[k].erase);
        }
        canvas.write(float4(c, 0.0f, 0.0f, 0.0f), px);
    }
    """
}
