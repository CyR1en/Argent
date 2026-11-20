extension ShaderSource {
    static let lensStage = """
    #include <metal_stdlib>
    using namespace metal;

    struct LensStageParams {
        float centreX, centreY, inverseRMax, inverseScale, limit;
        uint maps, firstRow;
    };

    static inline float ls_lookup(constant float* tables, uint row, float t) {
        const float x = min(t, 1.0f) * 960.0f;
        const uint i = min(uint(x), 959u);
        return mix(tables[row * 961 + i], tables[row * 961 + i + 1], x - float(i));
    }

    static inline float4 lw_weights(float t) {
        float t2 = t * t, t3 = t2 * t;
        return float4(-0.5f * t3 + t2 - 0.5f * t, 1.5f * t3 - 2.5f * t2 + 1.0f,
                      -1.5f * t3 + 2.0f * t2 + 0.5f * t, 0.5f * t3 - 0.5f * t2);
    }

    template <typename T>
    static inline T ls_sample(texture2d<half, access::read> frame, constant LensStageParams& P,
                              constant float* tables, float2 v, float t, uint ch) {
        const float2 c(P.centreX, P.centreY);
        const float2 p = c + v * (ls_lookup(tables, ch, t) * P.inverseScale);
        const float2 base = floor(p);
        const float4 wx = lw_weights(p.x - base.x), wy = lw_weights(p.y - base.y);
        const int2 last(int(frame.get_width()) - 1, int(frame.get_height()) - 1);
        T sum = T(0.0f), lo16 = T(INFINITY), hi16 = T(-INFINITY), lo4 = T(INFINITY), hi4 = T(-INFINITY);
        for (int j = 0; j < 4; j++) {
            T row = T(0.0f);
            for (int i = 0; i < 4; i++) {
                const float3 rgb = float3(frame.read(uint2(clamp(int2(base) - 1 + int2(i, j), int2(0), last))).rgb);
                T s;
                if constexpr (is_same_v<T, float3>) { s = rgb; }
                else { s = rgb[ch]; }
                row += wx[i] * s;
                lo16 = min(lo16, s); hi16 = max(hi16, s);
                if (i >= 1 && i <= 2 && j >= 1 && j <= 2) { lo4 = min(lo4, s); hi4 = max(hi4, s); }
            }
            sum += wy[j] * row;
        }
        sum = select(sum, clamp(sum, lo4, hi4), hi16 - lo16 > P.limit * (abs(hi16) + abs(lo16)));
        return sum * ls_lookup(tables, 3, length(p - c) * P.inverseRMax);
    }

    kernel void lens_stage(texture2d<half, access::read> frame [[texture(0)]],
                           texture2d<half, access::write> out [[texture(1)]],
                           constant LensStageParams& P [[buffer(0)]],
                           constant float* tables [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        const uint2 q(gid.x, gid.y + P.firstRow);
        const float2 v = float2(q) - float2(P.centreX, P.centreY);
        const float t = length(v) * P.inverseRMax;
        float3 value;
        if (P.maps == 1) { value = ls_sample<float3>(frame, P, tables, v, t, 1); }
        else {
            value = float3(ls_sample<float>(frame, P, tables, v, t, 0),
                           ls_sample<float>(frame, P, tables, v, t, 1),
                           ls_sample<float>(frame, P, tables, v, t, 2));
        }
        out.write(half4(half3(value), 1.0h), q);
    }
    """
}
