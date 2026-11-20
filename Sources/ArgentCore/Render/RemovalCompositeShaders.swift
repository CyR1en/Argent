extension ShaderSource {
    static let removalComposite = """
    #include <metal_stdlib>
    using namespace metal;

    struct RemovalCompositeParams {
        float limit;
        uint originX, originY, columns, firstRow, level, channel;
    };

    // Where one column or one row of the decode reads the patch: the level's texel before it and how far past that texel it lies.
    struct RemovalTap {
        int base;
        float t;
    };

    // Catmull-Rom, as the lens stage's warp weighs its taps (lw_weights).
    static inline float4 rc_weights(float t) {
        float t2 = t * t, t3 = t2 * t;
        return float4(-0.5f * t3 + t2 - 0.5f * t, 1.5f * t3 - 2.5f * t2 + 1.0f,
                      -1.5f * t3 + 2.0f * t2 + 0.5f * t, 0.5f * t3 - 0.5f * t2);
    }

    // One patch mixed into the decode over a block of the texels whose centres lie in its box, the block's first at
    // (originX, originY) of `frame`, which is the decode or a cut of it. `patch` and `alphas` hold the patch with its bottom row in
    // row 0, as the decode holds the picture's. `taps` says where each of the block's columns, then each of its rows, reads the
    // patch. They are worked out in whole numbers for the decode's own texels: a float's 24 bits would place a texel 4000 rows
    // into a box a ten-thousandth of a patch texel off, and a cut of the decode holds the bits the whole decode would.
    kernel void removal_composite(texture2d<half, access::read_write> frame [[texture(0)]],
                                  texture2d<half, access::read> patch [[texture(1)]],
                                  texture2d<float, access::read> alphas [[texture(2)]],
                                  constant RemovalCompositeParams& P [[buffer(0)]],
                                  constant RemovalTap* taps [[buffer(1)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        const uint2 g(gid.x, gid.y + P.firstRow);
        const RemovalTap tx = taps[g.x], ty = taps[P.columns + g.y];
        const int2 base(tx.base, ty.base);
        const float4 wx = rc_weights(tx.t), wy = rc_weights(ty.t);
        const int2 last(int(patch.get_width(P.level)) - 1, int(patch.get_height(P.level)) - 1);
        float4 sum = float4(0.0f), lo16 = float4(INFINITY), hi16 = float4(-INFINITY), lo4 = float4(INFINITY), hi4 = float4(-INFINITY);
        for (int j = 0; j < 4; j++) {
            float4 row = float4(0.0f);
            for (int i = 0; i < 4; i++) {
                const uint2 at = uint2(clamp(base - 1 + int2(i, j), int2(0), last));
                const float4 s = float4(float3(patch.read(at, P.level).rgb), alphas.read(at, P.level)[P.channel]);
                row += wx[i] * s;
                lo16 = min(lo16, s); hi16 = max(hi16, s);
                if (i >= 1 && i <= 2 && j >= 1 && j <= 2) { lo4 = min(lo4, s); hi4 = max(hi4, s); }
            }
            sum += wy[j] * row;
        }
        // The warp's limiter, so a patch's edge rings no more under its enlargement than the decode's does under the warp.
        sum = select(sum, clamp(sum, lo4, hi4), hi16 - lo16 > P.limit * (abs(hi16) + abs(lo16)));
        // Coverage stays within the taps it was read from: where they are all 1 the patch alone is written, and where they are all
        // 0 the decode's own bits, whatever the weights' sum rounds to.
        const float a = clamp(sum.a, lo16.a, hi16.a);
        const uint2 q = g + uint2(P.originX, P.originY);
        const half4 under = frame.read(q);
        frame.write(half4(half3(float3(under.rgb) * (1.0f - a) + sum.rgb * a), under.a), q);
    }
    """
}
