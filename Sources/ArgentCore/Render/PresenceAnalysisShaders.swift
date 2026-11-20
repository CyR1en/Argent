extension ShaderSource {
    /// Presence's analysis kernels (`PresenceAnalysisBuilder`), compiled after `toneBase` in a library of their own, since they call its
    /// helpers and share its structs.
    static let presenceAnalysis = """
    #include <metal_stdlib>
    using namespace metal;

    // Where a band of a field sits: a texture holding field rows from `inOrigin`, another from `outOrigin`, and the rows a pass writes,
    // from `first`, a segment's start, up to `stop`.
    struct PresenceBand {
        uint fieldWidth;
        uint fieldHeight;
        uint inOrigin;
        uint outOrigin;
        uint first;
        uint stop;
    };

    // tone_base_guide for a band of the field's rows, field row `outOrigin + gid.y` into the band's row gid.y. The same sums in the
    // same order, so a band's guide is the whole field's to the bit.
    kernel void presence_band_guide(texture2d<half, access::read> frame [[texture(0)]],
                                    texture2d<float, access::write> out [[texture(1)]],
                                    constant PresenceBand &band [[buffer(0)]],
                                    uint2 gid [[thread_position_in_grid]]) {
        uint ow = band.fieldWidth, oh = band.fieldHeight, fieldRow = band.outOrigin + gid.y;
        if (gid.x >= ow || gid.y >= out.get_height() || fieldRow >= oh) { return; }
        uint sw = frame.get_width(), sh = frame.get_height();
        uint x0 = gid.x * sw, x1 = x0 + sw, y0 = fieldRow * sh, y1 = y0 + sh;
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

    static inline float2 presence_band_read(texture2d<float, access::read> in, int column, int fieldRow, int fieldHeight, uint origin) {
        return in.read(uint2(column, uint(clamp(fieldRow, 0, fieldHeight - 1)) - origin)).rg;
    }

    static inline float3 presence_band_window(texture2d<float, access::read> in, int column, int i, int r, int fieldHeight, uint origin,
                                              float2 c, uint stage) {
        float3 sum = float3(0.0f);
        for (int j = i - r; j <= i + r; j++) { sum += tone_base_terms(presence_band_read(in, column, j, fieldHeight, origin), c, stage); }
        return sum;
    }

    // tone_base_box's pass down the columns for the field rows `first` to `stop`, read from a band and written to another. Each thread
    // slides from a segment's start in field rows, as the whole field's pass does, and its windows clamp at the field's edges, so every
    // row it writes is that pass's to the bit. `in` must hold every row a window reads: `radius` rows past each end, or to the field's edge.
    kernel void presence_band_columns(texture2d<float, access::read> in [[texture(0)]],
                                      texture2d<float, access::write> out [[texture(1)]],
                                      constant ToneBaseParams &p [[buffer(0)]],
                                      constant ToneBasePass &pass [[buffer(1)]],
                                      constant PresenceBand &band [[buffer(2)]],
                                      uint2 gid [[thread_position_in_grid]]) {
        int length = int(band.fieldHeight);
        int line = int(gid.x), start = int(band.first + gid.y * p.segment);
        int r = int(pass.stage == 0 ? p.radius : p.coefficientRadius);
        if (line >= int(band.fieldWidth) || start >= int(band.stop)) { return; }
        int end = min(start + int(p.segment), int(band.stop));
        float scale = 1.0f / float(2 * r + 1);
        float2 c = presence_band_read(in, line, start, length, band.inOrigin);
        float3 sum = presence_band_window(in, line, start, r, length, band.inOrigin, c, pass.stage);
        for (int i = start; i < end; i++) {
            if (i > start) {
                sum += tone_base_terms(presence_band_read(in, line, i + r, length, band.inOrigin), c, pass.stage)
                     - tone_base_terms(presence_band_read(in, line, i - r - 1, length, band.inOrigin), c, pass.stage);
            }
            float3 m = sum * scale;
            float2 moved = pass.stage == 0 ? float2(m.x, 0.0f) : m.xy;
            if (any(abs(moved) > 4.0f)) {
                c += moved;
                sum = presence_band_window(in, line, i, r, length, band.inOrigin, c, pass.stage);
                m = sum * scale;
            }
            float2 value;
            if (pass.stage != 0) {
                value = c + m.xy;
            } else {
                float mean = c.x + m.x;
                float variance = max(m.y - m.x * m.x + m.z, 0.0f);
                float a = variance / (variance + p.epsilon);
                value = float2(a, mean - a * mean);
            }
            out.write(float4(value, 0.0f, 0.0f), uint2(line, uint(i) - band.outOrigin));
        }
    }

    // Dehaze's field (fit_dehaze.py's Field), on buffers the CPU reads for the airlight with no copy.
    struct PresenceHaze {
        float4 airlight;
        float4 luma;
        uint width;
        uint height;
        int radius;
        float omega;
        float guideFloor;
    };

    // The frame's light area-averaged into the field, as tone_base_guide averages luminance. Held to a half float's range, which keeps
    // a non-finite pixel from reaching the airlight's median (IEEE minimum and maximum take the number over a NaN).
    kernel void presence_haze_area(texture2d<half, access::read> frame [[texture(0)]],
                                   device float4 *field [[buffer(0)]],
                                   constant PresenceHaze &p [[buffer(1)]],
                                   uint2 gid [[thread_position_in_grid]]) {
        uint ow = p.width, oh = p.height;
        if (gid.x >= ow || gid.y >= oh) { return; }
        uint sw = frame.get_width(), sh = frame.get_height();
        uint x0 = gid.x * sw, x1 = x0 + sw, y0 = gid.y * sh, y1 = y0 + sh;
        uint ix1 = min((x1 + ow - 1) / ow, sw), iy1 = min((y1 + oh - 1) / oh, sh);
        float3 sum = float3(0.0f);
        for (uint y = y0 / oh; y < iy1; y++) {
            float wy = float(min((y + 1) * oh, y1) - max(y * oh, y0));
            float3 row = float3(0.0f);
            for (uint x = x0 / ow; x < ix1; x++) {
                float wx = float(min((x + 1) * ow, x1) - max(x * ow, x0));
                row += wx * float3(frame.read(uint2(x, y)).rgb);
            }
            sum += wy * row;
        }
        field[gid.y * ow + gid.x] = float4(clamp(sum / (float(sw) * float(sh)), -65504.0f, 65504.0f), 0.0f);
    }

    // The erosions repeat the field's edge pixels past it, as fit_dehaze.py's erode.
    kernel void presence_haze_dark_rows(device const float4 *field [[buffer(0)]],
                                        device float *out [[buffer(1)]],
                                        constant PresenceHaze &p [[buffer(2)]],
                                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) { return; }
        int last = int(p.width) - 1;
        float least = FLT_MAX;
        for (int dx = -p.radius; dx <= p.radius; dx++) {
            float3 c = field[gid.y * p.width + uint(clamp(int(gid.x) + dx, 0, last))].rgb / p.airlight.rgb;
            least = min(least, min(c.r, min(c.g, c.b)));
        }
        out[gid.y * p.width + gid.x] = least;
    }

    kernel void presence_haze_erode_columns(device const float *in [[buffer(0)]],
                                            device float *out [[buffer(1)]],
                                            constant PresenceHaze &p [[buffer(2)]],
                                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) { return; }
        int last = int(p.height) - 1;
        float least = in[gid.y * p.width + gid.x];
        for (int dy = -p.radius; dy <= p.radius; dy++) {
            least = min(least, in[uint(clamp(int(gid.y) + dy, 0, last)) * p.width + gid.x]);
        }
        out[gid.y * p.width + gid.x] = least;
    }

    kernel void presence_haze_terms(device const float4 *field [[buffer(0)]],
                                    device const float *dark [[buffer(1)]],
                                    texture2d<float, access::write> out [[texture(0)]],
                                    constant PresenceHaze &p [[buffer(2)]],
                                    uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) { return; }
        uint i = gid.y * p.width + gid.x;
        float g = log2(max(dot(field[i].rgb, p.luma.rgb), p.guideFloor));
        out.write(float4(g, 1.0f - p.omega * dark[i], 0.0f, 0.0f), gid);
    }

    struct PresenceHazeBox {
        int radius;
        float epsilon;
        uint columns;
    };

    // The guided filter of t under g, its boxes summed whole about each pixel, of offsets from the pixel's own values so the sums stay
    // small. Along the rows from (g, t): the window's means, the variance of g and the covariance of g and t. Down the columns from
    // those: the variance of the square window is the mean of the rows' variances plus the variance of their means, and the
    // covariance likewise; then a = cov / (var + epsilon) and b = mean t - a mean g.
    kernel void presence_haze_box(texture2d<float, access::read> in [[texture(0)]],
                                  texture2d<float, access::write> out [[texture(1)]],
                                  constant PresenceHazeBox &p [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        int w = int(in.get_width()), h = int(in.get_height());
        if (int(gid.x) >= w || int(gid.y) >= h) { return; }
        bool columns = p.columns != 0;
        float2 c = in.read(gid).xy;
        float4 moments = float4(0.0f);
        float2 within = float2(0.0f);
        for (int j = -p.radius; j <= p.radius; j++) {
            uint2 at = columns ? uint2(gid.x, uint(clamp(int(gid.y) + j, 0, h - 1))) : uint2(uint(clamp(int(gid.x) + j, 0, w - 1)), gid.y);
            float4 v = in.read(at);
            float d = v.x - c.x, e = v.y - c.y;
            moments += float4(d, e, d * d, d * e);
            if (columns) { within += v.zw; }
        }
        float n = float(2 * p.radius + 1);
        moments /= n;
        within /= n;
        float meanG = c.x + moments.x, meanT = c.y + moments.y;
        float variance = moments.z - moments.x * moments.x + within.x;
        float covariance = moments.w - moments.x * moments.y + within.y;
        if (!columns) {
            out.write(float4(meanG, meanT, variance, covariance), gid);
            return;
        }
        float a = covariance / (max(variance, 0.0f) + p.epsilon);
        out.write(float4(a, meanT - a * meanG, 0.0f, 0.0f), gid);
    }

    """
}
