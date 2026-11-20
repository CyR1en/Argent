extension ShaderSource {
    /// `MaskRefiner`'s library, compiled the first time a frame has a smart mask, apart from `GPU.shaderLibrary()` (plan section 4, rule 4).
    ///
    /// The guided filter (He and Sun) at the seed's own pitch, R8's pipeline as S3 banded it: the guide frame area-averaged over each seed
    /// pixel in linear light and taken to the refined guide, the products, four boxes, the 3 × 3 solve, one box of the result. Every pass
    /// works on one horizontal band of the seed at a time, carried with 2 r rows of context on each side: the pipeline boxes twice, so a
    /// row's result reads rows up to 2 r away, and with that margin a band's arithmetic is the whole seed's, value for value. The vertical
    /// box clamps against the whole seed's height, as the unbanded pass does, and the last pass writes rows of the whole output. The
    /// boxes are plain sums in a fixed order, not running sums, whose order would depend on where a band starts.
    static let maskRefiner = """
    #include <metal_stdlib>
    using namespace metal;

    \(maskRefinedFunctions)

    // Mirrors MaskRefiner.Band in Swift.
    struct MaskRefineBand {
        uint w, h;          // the seed
        float epsilon;      // the window's guide covariance gets epsilon squared on its diagonal
        int r;              // box radius, in seed pixels
        uint s;             // the seed row a band texture's row 0 holds
        uint rows;          // the band textures' rows that carry data
        uint outRow0;       // the first output row the last pass writes
        uint outRows;       // how many
        uint grid;          // seed pixels a coefficient texel averages on each axis: 1 or 2
        uint outWidth;
        uint outHeight;
        uint unused;
    };

    // A selection's refined coverage at each texel of the slice (tier 1): its coefficients at the texel's uv, dotted with the guide of
    // the guide frame's light there. The guide frame is the slice's size, or smaller, the decode itself, read by the sampler.
    kernel void mask_refine_field(texture2d<float, access::sample> guide [[texture(0)]],
                                  texture2d<float, access::sample> coefficients [[texture(1)]],
                                  texture2d<float, access::write> out [[texture(2)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        uint w = out.get_width(), h = out.get_height();
        if (gid.x >= w || gid.y >= h) { return; }
        constexpr sampler cs(filter::linear, address::clamp_to_edge, coord::normalized);
        float2 uv = (float2(gid) + 0.5f) / float2(w, h);
        out.write(float4(mask_refined(mask_refined_guide(guide.sample(cs, uv).rgb), uv, coefficients)), gid);
    }

    // The guide frame: the untouched decode area-averaged in linear light to the field's size (R8's canonical frame).
    kernel void mask_refine_guide_frame(texture2d<half, access::read> source [[texture(0)]],
                                        texture2d<half, access::write> out [[texture(1)]],
                                        uint2 gid [[thread_position_in_grid]]) {
        uint ow = out.get_width(), oh = out.get_height();
        if (gid.x >= ow || gid.y >= oh) { return; }
        uint sw = source.get_width(), sh = source.get_height();
        float fx0 = float(gid.x) * float(sw) / float(ow), fx1 = float(gid.x + 1u) * float(sw) / float(ow);
        float fy0 = float(gid.y) * float(sh) / float(oh), fy1 = float(gid.y + 1u) * float(sh) / float(oh);
        float3 sum = float3(0.0f);
        float weights = 0.0f;
        for (int y = int(floor(fy0)); y < min(int(ceil(fy1)), int(sh)); y++) {
            float wy = min(float(y + 1), fy1) - max(float(y), fy0);
            for (int x = int(floor(fx0)); x < min(int(ceil(fx1)), int(sw)); x++) {
                float wx = min(float(x + 1), fx1) - max(float(x), fx0);
                sum += wx * wy * float3(source.read(uint2(x, y)).rgb);
                weights += wx * wy;
            }
        }
        out.write(half4(half3(sum / max(weights, 1e-6f)), 1.0h), gid);
    }

    // A: the guide of the guide frame's light over each seed pixel, and the seed.
    kernel void mask_refine_down(texture2d<half, access::read> frame [[texture(0)]],
                                 texture2d<float, access::read> seed [[texture(1)]],
                                 texture2d<float, access::write> A [[texture(2)]],
                                 constant MaskRefineBand &p [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.w || gid.y >= p.rows) { return; }
        uint gy = p.s + gid.y;
        uint fw = frame.get_width(), fh = frame.get_height();
        float fx0 = float(gid.x) * float(fw) / float(p.w), fx1 = float(gid.x + 1u) * float(fw) / float(p.w);
        float fy0 = float(gy) * float(fh) / float(p.h), fy1 = float(gy + 1u) * float(fh) / float(p.h);
        float3 sum = float3(0.0f);
        float weights = 0.0f;
        for (int y = int(floor(fy0)); y < min(int(ceil(fy1)), int(fh)); y++) {
            float wy = min(float(y + 1), fy1) - max(float(y), fy0);
            for (int x = int(floor(fx0)); x < min(int(ceil(fx1)), int(fw)); x++) {
                float wx = min(float(x + 1), fx1) - max(float(x), fx0);
                sum += wx * wy * float3(frame.read(uint2(x, y)).rgb);
                weights += wx * wy;
            }
        }
        float3 g = mask_refined_guide(sum / max(weights, 1e-6f));
        A.write(float4(g, seed.read(uint2(gid.x, gy)).r), gid);
    }

    // The products the covariances need: B (gg: 00, 01, 02, 11), C (gg: 12, 22; gp: 0, 1), D (gp: 2).
    kernel void mask_refine_terms(texture2d<float, access::read> A [[texture(0)]],
                                  texture2d<float, access::write> B [[texture(1)]],
                                  texture2d<float, access::write> C [[texture(2)]],
                                  texture2d<float, access::write> D [[texture(3)]],
                                  constant MaskRefineBand &p [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.w || gid.y >= p.rows) { return; }
        float4 a = A.read(gid);
        B.write(float4(a.x * a.x, a.x * a.y, a.x * a.z, a.y * a.y), gid);
        C.write(float4(a.y * a.z, a.z * a.z, a.x * a.w, a.y * a.w), gid);
        D.write(float4(a.z * a.w, 0.0f, 0.0f, 0.0f), gid);
    }

    kernel void mask_refine_box_h(texture2d<float, access::read> in [[texture(0)]],
                                  texture2d<float, access::write> out [[texture(1)]],
                                  constant MaskRefineBand &p [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.w || gid.y >= p.rows) { return; }
        float4 s = float4(0.0f);
        for (int i = -p.r; i <= p.r; i++) { s += in.read(uint2(clamp(int(gid.x) + i, 0, int(p.w) - 1), gid.y)); }
        out.write(s / float(2 * p.r + 1), gid);
    }

    // The vertical box at seed row gy, over the whole seed's rows clamped to it, read from the band.
    static inline float4 mask_refine_vbox(texture2d<float, access::read> in, uint x, uint gy, constant MaskRefineBand &p) {
        float4 s = float4(0.0f);
        for (int i = -p.r; i <= p.r; i++) {
            int row = clamp(int(gy) + i, 0, int(p.h) - 1) - int(p.s);
            s += in.read(uint2(x, uint(clamp(row, 0, int(p.rows) - 1))));
        }
        return s / float(2 * p.r + 1);
    }

    kernel void mask_refine_box_v(texture2d<float, access::read> in [[texture(0)]],
                                  texture2d<float, access::write> out [[texture(1)]],
                                  constant MaskRefineBand &p [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.w || gid.y >= p.rows) { return; }
        out.write(mask_refine_vbox(in, gid.x, p.s + gid.y, p), gid);
    }

    // The symmetric 3 × 3 solve, LDL without pivots: the diagonal carries epsilon squared, so it is positive.
    static inline float3 mask_refine_solve3(float s00, float s01, float s02, float s11, float s12, float s22, float3 b) {
        float d1 = s00;
        float l21 = s01 / d1, l31 = s02 / d1;
        float d2 = s11 - l21 * s01;
        float l32 = (s12 - l31 * s01) / d2;
        float d3 = s22 - l31 * s02 - l32 * l32 * d2;
        float y1 = b.x, y2 = b.y - l21 * y1, y3 = b.z - l31 * y1 - l32 * y2;
        float x3 = y3 / d3;
        float x2 = y2 / d2 - l32 * x3;
        float x1 = y1 / d1 - l21 * x2 - l31 * x3;
        return float3(x1, x2, x3);
    }

    // From the boxed means: a, the three slopes, and b.
    kernel void mask_refine_solve(texture2d<float, access::read> A [[texture(0)]],
                                  texture2d<float, access::read> B [[texture(1)]],
                                  texture2d<float, access::read> C [[texture(2)]],
                                  texture2d<float, access::read> D [[texture(3)]],
                                  texture2d<float, access::write> E [[texture(4)]],
                                  constant MaskRefineBand &p [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.w || gid.y >= p.rows) { return; }
        float4 a = A.read(gid), b = B.read(gid), c = C.read(gid), d = D.read(gid);
        float3 mu = a.xyz;
        float mp = a.w;
        float e2 = p.epsilon * p.epsilon;
        float s00 = b.x - mu.x * mu.x + e2, s01 = b.y - mu.x * mu.y, s02 = b.z - mu.x * mu.z;
        float s11 = b.w - mu.y * mu.y + e2, s12 = c.x - mu.y * mu.z, s22 = c.y - mu.z * mu.z + e2;
        float3 covariance = float3(c.z - mu.x * mp, c.w - mu.y * mp, d.x - mu.z * mp);
        float3 k = mask_refine_solve3(s00, s01, s02, s11, s12, s22, covariance);
        E.write(float4(k, mp - dot(k, mu)), gid);
    }

    // Mirrors MaskRefiner.FeatherPass in Swift.
    struct MaskFeatherPass {
        uint radius;        // weights past the centre
        uint vertical;      // 0 along rows, 1 along columns
    };

    // One pass of a Feather's Gaussian (MaskFeather) over a refined field: weights[0] at the texel, weights[i] at ±i, a texel past the
    // side reading the side's, summed in this order as MaskFeather.blurred sums on the CPU.
    kernel void mask_feather_pass(texture2d<float, access::read> source [[texture(0)]],
                                  texture2d<float, access::write> target [[texture(1)]],
                                  constant MaskFeatherPass &p [[buffer(0)]],
                                  constant float *weights [[buffer(1)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        uint w = target.get_width(), h = target.get_height();
        if (gid.x >= w || gid.y >= h) { return; }
        int2 at = int2(gid), step = p.vertical != 0u ? int2(0, 1) : int2(1, 0), last = int2(int(w) - 1, int(h) - 1);
        float sum = weights[0] * source.read(gid).r;
        for (uint i = 1u; i <= p.radius; i++) {
            int2 d = step * int(i);
            sum += weights[i] * (source.read(uint2(clamp(at - d, int2(0), last))).r + source.read(uint2(clamp(at + d, int2(0), last))).r);
        }
        target.write(float4(sum), gid);
    }

    // A contrast about 0.5 on the finished coefficients, in place, as V5 measured it: (g a, g b + (1 - g) / 2). `crisp`, V7's frozen edge.
    kernel void mask_refine_contrast(texture2d<float, access::read_write> co [[texture(0)]],
                                     constant float &gain [[buffer(0)]],
                                     uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= co.get_width() || gid.y >= co.get_height()) { return; }
        float4 c = co.read(gid);
        float g = gain;
        co.write(float4(c.xyz * g, c.w * g + (1.0f - g) * 0.5f), gid);
    }

    // A `matte`'s stored alpha at each texel of the slice, sampled as tier 2 samples it at a pixel. `alpha` is the view that reads (0, 0, 0, a);
    // no guide, no decode.
    kernel void mask_refine_alpha_field(texture2d<float, access::sample> alpha [[texture(0)]],
                                        texture2d<float, access::write> out [[texture(1)]],
                                        uint2 gid [[thread_position_in_grid]]) {
        uint w = out.get_width(), h = out.get_height();
        if (gid.x >= w || gid.y >= h) { return; }
        constexpr sampler cs(filter::linear, address::clamp_to_edge, coord::normalized);
        float2 uv = (float2(gid) + 0.5f) / float2(w, h);
        out.write(float4(alpha.sample(cs, uv).a), gid);
    }

    // The last vertical box, written into rows of the whole coefficient texture. On a grid of 2 a texel is the mean of its 2 × 2 seed
    // pixels' results, the seed's last row and column repeated where its side is odd; a band then starts on an even row.
    kernel void mask_refine_out(texture2d<float, access::read> in [[texture(0)]],
                                texture2d<float, access::write> out [[texture(1)]],
                                constant MaskRefineBand &p [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.outWidth || gid.y >= p.outRows) { return; }
        uint row = p.outRow0 + gid.y;
        if (p.grid == 1u) {
            out.write(mask_refine_vbox(in, gid.x, row, p), uint2(gid.x, row));
            return;
        }
        uint x0 = 2u * gid.x, x1 = min(x0 + 1u, p.w - 1u);
        uint y0 = 2u * row, y1 = min(y0 + 1u, p.h - 1u);
        float4 sum = mask_refine_vbox(in, x0, y0, p) + mask_refine_vbox(in, x1, y0, p)
                   + mask_refine_vbox(in, x0, y1, p) + mask_refine_vbox(in, x1, y1, p);
        out.write(sum * 0.25f, uint2(gid.x, row));
    }
    """
}
