extension ShaderSource {
    /// The local tone base (`ToneBaseField`): the field's kernels and `tone_base_log2`, which the
    /// kernels after it in the library call. `GPU.shaderLibrary()` compiles it before `lut3D`.
    static let toneBase = """
    #include <metal_stdlib>
    using namespace metal;

    // The local tone base (ToneBaseField): a self-guided fast guided filter of log2 luminance.
    // A pixel's guide is g = log2(sqrt(Y^2 + 1e-12)), Y the Rec. 2020 luminance of its light. The
    // field's guide is the same of Y area-averaged into it; there mu = box(g), sigma^2 = box(g^2)
    // - mu^2, a = sigma^2 / (sigma^2 + epsilon), b = mu - a mu, and the field holds (box(a),
    // box(b)), boxes of the coefficient radius. A pixel's base is box(a) g + box(b), the
    // coefficients interpolated to it.
    // The guide is held to ±40 stops. Real light lies well inside (half floats reach 16 stops,
    // the floor -20), so this changes no finite pixel; it keeps one Inf or NaN in a frame from
    // poisoning the box filters' running sums, which would black out a block of the picture.
    static inline float tone_base_field_guide(float3 rgb) {
        float luminance = dot(rgb, float3(0.2627f, 0.6780f, 0.0593f));
        return clamp(log2(sqrt(luminance * luminance + 1e-12f)), -40.0f, 40.0f);
    }

    // A pixel's base in log2 luminance, from its guide and the field (rg32Float: box(a), box(b))
    // at uv = (pixel + 0.5) / frame size. The coefficients are interpolated bilinearly as the
    // edge-clamped sampler would, with float weights from four reads, so the CPU reference
    // (ToneBaseField.reference) makes the same sums.
    static inline float tone_base_log2(float guideLog2, float2 uv, texture2d<float, access::sample> coefficients) {
        int w = int(coefficients.get_width()), h = int(coefficients.get_height());
        float2 s = uv * float2(w, h) - 0.5f;
        float2 cell = floor(s);
        float2 t = s - cell;
        int x0 = clamp(int(cell.x), 0, w - 1), x1 = clamp(int(cell.x) + 1, 0, w - 1);
        int y0 = clamp(int(cell.y), 0, h - 1), y1 = clamp(int(cell.y) + 1, 0, h - 1);
        float2 top = mix(coefficients.read(uint2(x0, y0)).rg, coefficients.read(uint2(x1, y0)).rg, t.x);
        float2 bottom = mix(coefficients.read(uint2(x0, y1)).rg, coefficients.read(uint2(x1, y1)).rg, t.x);
        float2 ab = mix(top, bottom, t.y);
        return ab.x * guideLog2 + ab.y;
    }

    struct ToneBaseParams {
        float epsilon;
        uint radius;
        uint coefficientRadius;
        uint segment;
    };

    // One box pass: along rows or down columns, and of the guide (stage 0) or of the
    // coefficients (stage 1).
    struct ToneBasePass {
        uint columns;
        uint stage;
    };

    // The field's guide: the frame's luminance area-averaged into it, as `area_resize` averages,
    // each field pixel the mean of the frame area it covers, the pixels its edges cut through
    // weighted by the share inside; then its log. Averaged in linear light, a field is the same
    // from a frame and from any area-resize of it to the field's size or more.
    kernel void tone_base_guide(texture2d<half, access::read> frame [[texture(0)]],
                                texture2d<float, access::write> out [[texture(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
        uint ow = out.get_width(), oh = out.get_height();
        if (gid.x >= ow || gid.y >= oh) { return; }
        uint sw = frame.get_width(), sh = frame.get_height();
        uint x0 = gid.x * sw, x1 = x0 + sw, y0 = gid.y * sh, y1 = y0 + sh;
        uint ix1 = min((x1 + ow - 1) / ow, sw), iy1 = min((y1 + oh - 1) / oh, sh);
        float sum = 0.0f;
        for (uint y = y0 / oh; y < iy1; y++) {
            float wy = float(min((y + 1) * oh, y1) - max(y * oh, y0));
            float row = 0.0f;
            for (uint x = x0 / ow; x < ix1; x++) {
                float wx = float(min((x + 1) * ow, x1) - max(x * ow, x0));
                row += wx * dot(float3(frame.read(uint2(x, y)).rgb), float3(0.2627f, 0.6780f, 0.0593f));
            }
            sum += wy * row;
        }
        float luminance = sum / (float(sw) * float(sh));
        out.write(float4(clamp(log2(sqrt(luminance * luminance + 1e-12f)), -40.0f, 40.0f), 0.0f, 0.0f, 0.0f), gid);
    }

    static inline uint2 tone_base_at(int line, int i, int length, bool columns) {
        uint j = uint(clamp(i, 0, length - 1));
        return columns ? uint2(line, j) : uint2(j, line);
    }

    // What a box pass sums of a texel `v`, less `c`. Stage 0: the guide's offset and its square,
    // and the variance across the rows (zero in the guide itself). Stage 1: both coefficients.
    static inline float3 tone_base_terms(float2 v, float2 c, uint stage) {
        float d = v.x - c.x;
        return stage == 0 ? float3(d, d * d, v.y) : float3(d, v.y - c.y, 0.0f);
    }

    // The sum of `tone_base_terms` over the window of radius r about pixel i of a line.
    static inline float3 tone_base_window(texture2d<float, access::read> in, int line, int i, int r, int length,
                                          bool columns, float2 c, uint stage) {
        float3 sum = float3(0.0f);
        for (int j = i - r; j <= i + r; j++) { sum += tone_base_terms(in.read(tone_base_at(line, j, length, columns)).rg, c, stage); }
        return sum;
    }

    // Box filters with the edges clamped (a window past the field repeats its edge pixel), as
    // running sums: each thread takes `segment` pixels of a line, sums its first window whole and
    // slides it, adding the pixel that enters and taking off the one that leaves. With `segment`
    // at least the window, a pixel costs about three reads whatever the radius. The sums are of
    // offsets from a centre near the window's mean, so they stay small and slide without drifting;
    // when the mean has moved four stops from it, across an edge, the window is summed again about
    // the mean, as often as a line's large shapes ask and no more often for its texture. (At one
    // stop the sample's 960-pixel field took 1.8 ms against 0.3, for no difference that matters:
    // the field matches the CPU's double-precision sums to 1e-4 stops either way.)
    //
    // Stage 0 along the rows writes each window's mean and variance; down the columns the
    // window's variance is then the mean of the rows' variances plus the variance of their
    // means, and the pass writes the filter's a and b. Stage 1 writes the means of a and b over the
    // coefficient radius, smaller than the guide's, so an edge's lean on its other side stays nearer it.
    kernel void tone_base_box(texture2d<float, access::read> in [[texture(0)]],
                              texture2d<float, access::write> out [[texture(1)]],
                              constant ToneBaseParams &p [[buffer(0)]],
                              constant ToneBasePass &pass [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
        bool columns = pass.columns != 0;
        int length = int(columns ? in.get_height() : in.get_width());
        int lines = int(columns ? in.get_width() : in.get_height());
        int line = int(gid.x), start = int(gid.y * p.segment);
        int r = int(pass.stage == 0 ? p.radius : p.coefficientRadius);
        if (line >= lines || start >= length) { return; }
        int end = min(start + int(p.segment), length);
        float scale = 1.0f / float(2 * r + 1);
        float2 c = in.read(tone_base_at(line, start, length, columns)).rg;
        float3 sum = tone_base_window(in, line, start, r, length, columns, c, pass.stage);
        for (int i = start; i < end; i++) {
            if (i > start) {
                sum += tone_base_terms(in.read(tone_base_at(line, i + r, length, columns)).rg, c, pass.stage)
                     - tone_base_terms(in.read(tone_base_at(line, i - r - 1, length, columns)).rg, c, pass.stage);
            }
            float3 m = sum * scale;
            float2 moved = pass.stage == 0 ? float2(m.x, 0.0f) : m.xy;
            if (any(abs(moved) > 4.0f)) {
                c += moved;
                sum = tone_base_window(in, line, i, r, length, columns, c, pass.stage);
                m = sum * scale;
            }
            float2 value;
            if (pass.stage != 0) {
                value = c + m.xy;
            } else {
                float mean = c.x + m.x;
                float variance = max(m.y - m.x * m.x + m.z, 0.0f);
                if (columns) {
                    float a = variance / (variance + p.epsilon);
                    value = float2(a, mean - a * mean);
                } else {
                    value = float2(mean, variance);
                }
            }
            out.write(float4(value, 0.0f, 0.0f), tone_base_at(line, i, length, columns));
        }
    }

    // Each pixel's base, for tests and measurements; the manual mapping reads the base in its own
    // passes.
    kernel void tone_base_map(texture2d<half, access::read> frame [[texture(0)]],
                              texture2d<float, access::sample> coefficients [[texture(1)]],
                              texture2d<float, access::write> out [[texture(2)]],
                              uint2 gid [[thread_position_in_grid]]) {
        uint w = frame.get_width(), h = frame.get_height();
        if (gid.x >= w || gid.y >= h) { return; }
        float2 uv = (float2(gid) + 0.5f) / float2(w, h);
        float g = tone_base_field_guide(float3(frame.read(gid).rgb));
        out.write(float4(tone_base_log2(g, uv, coefficients), 0.0f, 0.0f, 0.0f), gid);
    }

    """
}
