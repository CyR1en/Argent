/// Metal shader source, compiled at runtime.
///
/// Runtime compilation keeps the package buildable with Command Line Tools alone
/// (the offline `metal` compiler ships only with Xcode) and costs about 100 ms once
/// per process. The app target can move this to a precompiled metallib later.
enum ShaderSource {
    /// Any compiler's scene mapping of a frame pixel's own light, as `lut3D` compiles it: one text, so the two-input form Presence's
    /// Dehaze needs (`manualSceneOf`) is made from it and not kept beside it.
    static let manualSceneAt = """
        static inline float3 manual_scene_at(float3 rgb, float2 uv, texture2d<float, access::sample> base,
                                             device const float *tables, constant ManualCurveParameters &p) {
            if (p.sceneTables == 0) { return manual_scene(rgb, p); }
            if (p.sceneActive == 0) { return rgb; }
            float3 exposed = rgb * p.exposureGain;
            if (p.localActive == 0 && p.globalActive == 0) { return exposed; }
            float guide = manual_guide(rgb);
            float local = p.localActive != 0
                ? manual_table(tables + p.tableCount, tone_base_log2(guide, uv, base) + p.baseOffset, p) : 0.0f;
            float global = p.globalActive != 0 ? manual_table(tables, guide + p.guideOffset + local, p) : 0.0f;
            return exposed * exp2(local + global);
        }
        """

    static let lut3D = """
    #include <metal_stdlib>
    using namespace metal;

    struct LUTParams {
        float logMin;
        float logMax;
        float midGray;
        uint  lutSize;
        float exposureStops;
    };

    struct PrintParams {
        float offsetR;
        float offsetG;
        float offsetB;
        uint  lutSize;
        // Grain: the per-pixel scale on the stock's sigma48 (0 for none), the two noise
        // tiles' offsets, and the number of entries in the sigma table.
        float grainScale;
        uint  grainAX;
        uint  grainAY;
        uint  grainBX;
        uint  grainBY;
        uint  sigmaCount;
        // Capture sharpening (apply_print_lut_sharpened only): the sensor mask's share of the
        // detail and its kernel's taps either side, the soft threshold, the luminance weights,
        // then the same two for the mask that takes out the decoder's scaling.
        float sharpenAmount;
        float sharpenThreshold;
        uint  sharpenRadius;
        float lumaR;
        float lumaG;
        float lumaB;
        float scalingAmount;
        uint  scalingRadius;
    };

    // ManualRenderSettings 2026-10-09-1, 2026-10-29-1 and 2026-11-06-1. The block mirrors
    // ManualCurveParameters in Swift; scene and print mappings are fused into existing passes, with a
    // literal identity bypass. Constants belong to the compiler version, not to a preview's
    // resolution. The last eight fields are the gain-table compilers': the tables' geometry, which of
    // them are set, and the offsets from the guide's units to stops from the reference. guideOffset is
    // after Exposure and reads the global table. baseOffset reads the local table: before Exposure on
    // 2026-11-06-1, and on 2026-10-29-1 after it, equal to guideOffset.
    struct ManualCurveParameters {
        float exposureGain;
        float sceneReference;
        float highlights;
        float shadows;
        float contrastSlope;
        float whiteEndpoint;
        float blackEndpoint;
        uint sceneActive;
        uint printActive;
        uint sceneTables;
        uint localActive;
        uint globalActive;
        uint tableCount;
        float tableStart;
        float tableScale;
        float guideOffset;
        float baseOffset;
    };

    struct ToneCurveParameters {
        float4 startSlope;
        float4 endSlope;
        uint activeMask;
        uint tableSize;
        uint finiteOutput;
    };

    static inline float curve_encode(float value) {
        return value <= 0.0031308f ? 12.92f * value : 1.055f * pow(value, 1.0f / 2.4f) - 0.055f;
    }
    static inline float curve_decode(float value) {
        return value <= 0.04045f ? value / 12.92f : pow((value + 0.055f) / 1.055f, 2.4f);
    }
    static inline float curve_sample(float input, uint channel, texture2d<float, access::read> table,
                                     constant ToneCurveParameters &p) {
        if ((p.activeMask & (1u << channel)) == 0) { return input; }
        if (input <= 0.0f) { return table.read(uint2(0, 0))[channel] + input * p.startSlope[channel]; }
        if (input >= 1.0f) {
            return table.read(uint2(p.tableSize - 1, 0))[channel] + (input - 1.0f) * p.endSlope[channel];
        }
        float position = input * float(p.tableSize - 1);
        uint low = uint(position);
        float a = table.read(uint2(low, 0))[channel], b = table.read(uint2(low + 1, 0))[channel];
        return a + (b - a) * (position - float(low));
    }
    static inline float3 tone_curves(float3 rgb, texture2d<float, access::read> table,
                                     constant ToneCurveParameters &p) {
        if (p.activeMask == 0) { return rgb; }
        float3 result = rgb;
        if ((p.activeMask & 1u) != 0) {
            float luminance = dot(rgb, float3(0.2627f, 0.6780f, 0.0593f));
            float mapped = curve_decode(curve_sample(curve_encode(luminance), 0, table, p));
            float t = mapped >= 0.0f ? clamp(luminance / 0.02f, 0.0f, 1.0f) : 0.0f;
            float blend = t * t * (3.0f - 2.0f * t);
            float gain = luminance > 0.0f && mapped >= 0.0f ? mapped / max(luminance, 1e-6f) : 1.0f;
            result = rgb * (1.0f + (gain - 1.0f) * blend) + (mapped - luminance) * (1.0f - blend);
        }
        for (uint i = 0; i < 3; i++) {
            if ((p.activeMask & (1u << (i + 1))) != 0) {
                result[i] = curve_decode(curve_sample(curve_encode(result[i]), i + 1, table, p));
            }
        }
        return result;
    }

    static inline half3 print_storage(float3 rgb, constant ToneCurveParameters &p) {
        // Legal steep Tone and RGB curves can produce finite float values beyond half's
        // range. Preserve their composition, then keep the output texture finite. The
        // version-selected flag leaves recorded version-1 pixels unchanged.
        if (p.finiteOutput != 0) { rgb = clamp(rgb, float3(-65504.0f), float3(65504.0f)); }
        return half3(rgb);
    }

    static inline float manual_luminance(float3 rgb) {
        return dot(rgb, float3(0.2627f, 0.6780f, 0.0593f));
    }

    static inline float manual_logistic(float x) { return 1.0f / (1.0f + exp(-x)); }

    static inline float3 manual_scene(float3 rgb, constant ManualCurveParameters &p) {
        if (p.sceneActive == 0) { return rgb; }
        float3 exposed = rgb * p.exposureGain;
        if (p.highlights == 0.0f && p.shadows == 0.0f) { return exposed; }
        float luminance = manual_luminance(exposed);
        float guarded = sqrt(luminance * luminance + 1e-12f);
        float stops = log2(guarded / p.sceneReference);
        float shift = p.highlights * manual_logistic((stops - 1.0f) * 0.5f)
                    + p.shadows * manual_logistic(-(stops + 1.0f) * 0.5f);
        return exposed * exp2(shift);
    }

    // The gain-table compilers (ManualToneTables). A gain table in stops: linear between samples,
    // constant beyond the ends, the same arithmetic as ManualToneTables.value(_:at:) on the CPU.
    static inline float manual_table(device const float *table, float x, constant ManualCurveParameters &p) {
        float position = clamp((x - p.tableStart) * p.tableScale, 0.0f, float(p.tableCount - 1));
        uint low = min(uint(position), p.tableCount - 2);
        float a = table[low], b = table[low + 1];
        return a + (b - a) * (position - float(low));
    }

    // log2 of the Rec. 2020 luminance before Exposure, guarded neutrally at zero and below: what
    // the local base field filters (tone_base_log2) and what each pixel is measured by.
    static inline float manual_guide(float3 rgb) { return tone_base_field_guide(rgb); }

    // Any compiler's scene mapping for a frame pixel at `uv`. 2026-10-09-1 is manual_scene as it
    // was. The gain-table compilers: Exposure's gain, then one gain for all three channels, the local
    // table at the pixel's base plus the global table at its own light moved by that, from `tables`
    // (global samples, then local). Unset tables are not read, and neither is the base field without
    // the local one. Every render without Presence's scene stages takes this text as it was.
    \(manualSceneAt)

    // The same mapping of `light` with its local base read at the untouched pixel `rgb`: made from the
    // text above by exact edits (PresenceShaders.swift), for Presence's Dehaze (scene_at).
    \(manualSceneOf)

    // Rational contrast about print mid-gray. Both pieces meet with derivative k; the
    // endpoint slopes are 1/k and continue linearly through signed or over-white values.
    static inline float manual_contrast(float luminance, float k) {
        if (k == 1.0f) { return luminance; }
        if (luminance <= 0.0f) { return luminance / k; }
        if (luminance >= 1.0f) { return 1.0f + (luminance - 1.0f) / k; }
        if (luminance <= 0.18f) {
            float t = luminance / 0.18f;
            return 0.18f * t / (k + (1.0f - k) * t);
        }
        float t = (1.0f - luminance) / 0.82f;
        return 1.0f - 0.82f * t / (k + (1.0f - k) * t);
    }

    static inline float3 manual_print(float3 rgb, constant ManualCurveParameters &p) {
        if (p.printActive == 0) { return rgb; }
        float luminance = manual_luminance(rgb);
        float curve = manual_contrast(luminance, p.contrastSlope);
        float span = p.whiteEndpoint - p.blackEndpoint;
        float mapped = p.blackEndpoint + span * curve;
        float contrastGain = p.contrastSlope == 1.0f ? 1.0f : luminance <= 0.0f ? 1.0f / p.contrastSlope
            : luminance <= 0.18f ? 1.0f / (p.contrastSlope + (1.0f - p.contrastSlope) * luminance / 0.18f)
            : curve / luminance;
        // Preserve chromaticity away from black; lift the toe neutrally rather than
        // multiplying chroma noise by an unbounded gain or reversing a signed channel.
        float blend = luminance > 0.0f
            ? smoothstep(0.0f, 0.02f, p.blackEndpoint < 0.0f ? max(mapped, 0.0f) : luminance) : 0.0f;
        float endpointGain = luminance > 0.0f ? p.blackEndpoint * blend / luminance : 0.0f;
        return rgb * (span * contrastGain + endpointGain) + p.blackEndpoint * (1.0f - blend);
    }

    \(presenceParameters)
    \(presenceScene)
    \(presencePrint)
    // What every Negative kernel and the halation source map a pixel's light by: Presence's Dehaze on
    // the light before Exposure, the Light mapping of what it leaves with the untouched base, and
    // Clarity's and Texture's stops added to the Light gains (PresenceScene). With no scene slider set
    // it is manual_scene_at: a branch, so a render without them keeps its bytes.
    static inline float3 scene_at(float3 rgb, float2 uv, texture2d<float, access::sample> base,
                                  device const float *tables, constant ManualCurveParameters &p,
                                  constant PresenceSceneParameters &q, device const float *weights,
                                  texture2d<float, access::sample> clarity, texture2d<float, access::sample> texture,
                                  texture2d<float, access::sample> dehaze) {
        if (q.active == 0u) { return manual_scene_at(rgb, uv, base, tables, p); }
        float guide = manual_guide(rgb);
        return manual_scene_of(presence_dehaze(rgb, guide, uv, q, dehaze), rgb, uv, base, tables, p)
            * exp2(presence_detail_stops(guide, uv, q, weights, clarity, texture));
    }

    static inline float3 compress_scene_gamut(float3 rgb) {
        float ach = max(rgb.r, max(rgb.g, rgb.b));
        if (ach <= 0.0f) { return rgb; }
        const float threshold = \(GamutCompression.threshold)f;
        const float power = \(GamutCompression.power)f;
        const float3 limits = float3(\(GamutCompression.limits.x)f, \(GamutCompression.limits.y)f, \(GamutCompression.limits.z)f);
        float3 distance = (ach - rgb) / abs(ach);
        float3 width = limits - threshold;
        float3 scale = width / pow(pow((1.0f - threshold) / width, float3(-power)) - 1.0f, float3(1.0f / power));
        float3 nd = max(distance - threshold, float3(0.0f)) / scale;
        float3 cd = threshold + scale * nd / pow(1.0f + pow(nd, float3(power)), float3(1.0f / power));
        return select(rgb, ach - cd * abs(ach), distance > threshold);
    }

    // Scene-linear to the LUT's log input domain: 0 = logMin stops below mid-gray,
    // 1 = logMax stops above. Matches LogEncoding in LUT3D.swift. exposureStops
    // shifts the negative's exposure before encoding, which is how Rated at arrives.
    static inline float3 encode_log(float3 linear, constant LUTParams &p) {
        float3 v = max(compress_scene_gamut(linear), float3(1e-6f));
        float3 stops = log2(v / p.midGray) + p.exposureStops;
        return saturate((stops - p.logMin) / (p.logMax - p.logMin));
    }

    static inline float3 fetch(texture3d<half, access::read> lut, uint x, uint y, uint z) {
        return float3(lut.read(uint3(x, y, z)).rgb);
    }

    // Tetrahedral interpolation: four fetches per pixel and no hue skew on the
    // gray axis, which trilinear sampling would introduce.
    static inline float3 sample_tetrahedral(texture3d<half, access::read> lut, float3 uvw, uint n) {
        float3 p = uvw * float(n - 1);
        uint3 i0 = min(uint3(floor(p)), uint3(n - 2));
        uint3 i1 = i0 + 1;
        float3 f = p - float3(i0);
        float3 c000 = fetch(lut, i0.x, i0.y, i0.z);
        float3 c111 = fetch(lut, i1.x, i1.y, i1.z);
        float3 result;
        if (f.r > f.g) {
            if (f.g > f.b) {
                float3 c100 = fetch(lut, i1.x, i0.y, i0.z);
                float3 c110 = fetch(lut, i1.x, i1.y, i0.z);
                result = (1.0f - f.r) * c000 + (f.r - f.g) * c100 + (f.g - f.b) * c110 + f.b * c111;
            } else if (f.r > f.b) {
                float3 c100 = fetch(lut, i1.x, i0.y, i0.z);
                float3 c101 = fetch(lut, i1.x, i0.y, i1.z);
                result = (1.0f - f.r) * c000 + (f.r - f.b) * c100 + (f.b - f.g) * c101 + f.g * c111;
            } else {
                float3 c001 = fetch(lut, i0.x, i0.y, i1.z);
                float3 c101 = fetch(lut, i1.x, i0.y, i1.z);
                result = (1.0f - f.b) * c000 + (f.b - f.r) * c001 + (f.r - f.g) * c101 + f.g * c111;
            }
        } else {
            if (f.b > f.g) {
                float3 c001 = fetch(lut, i0.x, i0.y, i1.z);
                float3 c011 = fetch(lut, i0.x, i1.y, i1.z);
                result = (1.0f - f.b) * c000 + (f.b - f.g) * c001 + (f.g - f.r) * c011 + f.r * c111;
            } else if (f.b > f.r) {
                float3 c010 = fetch(lut, i0.x, i1.y, i0.z);
                float3 c011 = fetch(lut, i0.x, i1.y, i1.z);
                result = (1.0f - f.g) * c000 + (f.g - f.b) * c010 + (f.b - f.r) * c011 + f.r * c111;
            } else {
                float3 c010 = fetch(lut, i0.x, i1.y, i0.z);
                float3 c110 = fetch(lut, i1.x, i1.y, i0.z);
                result = (1.0f - f.g) * c000 + (f.g - f.r) * c010 + (f.r - f.b) * c110 + f.b * c111;
            }
        }
        return result;
    }

    kernel void apply_lut3d(texture2d<half, access::read> inTexture [[texture(0)]],
                            texture2d<half, access::write> outTexture [[texture(1)]],
                            texture3d<half, access::read> lut [[texture(2)]],
                            texture2d<float, access::sample> toneBase [[texture(3)]],
                            constant LUTParams &params [[buffer(0)]],
                            constant ManualCurveParameters &manual [[buffer(1)]],
                            device const float *toneTables [[buffer(2)]],
                            \(presenceSceneSignature)
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) { return; }
        float2 uv = (float2(gid) + 0.5f) / float2(outTexture.get_width(), outTexture.get_height());
        half4 pixel = inTexture.read(gid);
        float3 encoded = encode_log(scene_at(float3(pixel.rgb), \(sceneArguments)), params);
        float3 rgb = sample_tetrahedral(lut, encoded, params.lutSize);
        outTexture.write(half4(half3(rgb), pixel.a), gid);
    }

    // The Print LUT pass. The input holds the negative's layer densities, already in the
    // LUT's 0...1 domain, so there is no log encoding here. The offset is lab balance and
    // print exposure: enlarger filtration, applied as a shift in density.
    //
    // Grain goes into the dye amounts here, before the Print LUT, so the paper's curve gives it
    // its gain and channel correlation and clipped whites carry none. Each layer's noise is the
    // sum of two unit-variance tiles over the square root of two, times that layer's sigma at
    // the pixel's own dye amount, times the output pitch's ratio and the grain amount.
    // `film` is the negative's own dye amounts, which set the grain's local strength; `amounts`
    // may carry capture sharpening's detail on top, and the grain is added to them. Sharpening
    // is the scan's crispness, not the film's density, so it moves neither the grain pattern nor
    // its strength (found in review: looked up from the sharpened amounts, the grain grew along
    // edges by up to 0.013 in dye units through Portra 400's table).
    static inline float3 print_amounts(float3 amounts, float3 film, uint2 gid,
                                       texture3d<half, access::read> lut,
                                       texture2d<half, access::read> grainA,
                                       texture2d<half, access::read> grainB,
                                       texture2d<half, access::read> sigmas,
                                       constant PrintParams &params) {
        if (params.grainScale > 0.0f) {
            uint wa = grainA.get_width(), wb = grainB.get_width();
            float3 a = float3(grainA.read(uint2((gid.x + params.grainAX) % wa, (gid.y + params.grainAY) % wa)).rgb);
            float3 b = float3(grainB.read(uint2((gid.x + params.grainBX) % wb, (gid.y + params.grainBY) % wb)).rgb);
            float last = float(params.sigmaCount - 1);
            uint3 index = uint3(clamp(film, 0.0f, 1.0f) * last + 0.5f);
            float3 sigma = float3(float(sigmas.read(uint2(index.r, 0)).r), float(sigmas.read(uint2(index.g, 0)).g),
                                  float(sigmas.read(uint2(index.b, 0)).b));
            amounts += (a + b) * 0.70710678f * sigma * params.grainScale;
        }
        float3 offset = float3(params.offsetR, params.offsetG, params.offsetB);
        float3 density = saturate(amounts + offset);
        return sample_tetrahedral(lut, density, params.lutSize);
    }

    kernel void apply_print_lut(texture2d<half, access::read> inTexture [[texture(0)]],
                                texture2d<half, access::write> outTexture [[texture(1)]],
                                texture3d<half, access::read> lut [[texture(2)]],
                                texture2d<half, access::read> grainA [[texture(3)]],
                                texture2d<half, access::read> grainB [[texture(4)]],
                                texture2d<half, access::read> sigmas [[texture(5)]],
                                constant PrintParams &params [[buffer(0)]],
                                constant ManualCurveParameters &manual [[buffer(2)]],
                                constant PresencePrintParameters &presencePrint [[buffer(6)]],
                                texture2d<float, access::read> curves [[texture(6)]],
                                constant ToneCurveParameters &curveParams [[buffer(3)]],
                                uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) { return; }
        half4 pixel = inTexture.read(gid);
        float3 rgb = print_amounts(float3(pixel.rgb), float3(pixel.rgb), gid, lut, grainA, grainB, sigmas, params);
        outTexture.write(half4(print_storage(tone_curves(manual_print(presence_print(rgb, presencePrint), manual), curves, curveParams), curveParams), pixel.a), gid);
    }

    // The same with capture sharpening first (CaptureSharpening): two unsharp masks on a
    // luminance of the dye amounts, the sensor's and the decoder scaling's, their detail summed,
    // softly thresholded and added to all three layers, before grain. `weights` holds the first
    // kernel's taps, then the second's. Each 16 by 16 threadgroup loads its tile's luminance
    // with a margin into threadgroup memory and blurs it across and then down, so the pass
    // needs no frame-sized texture of its own. Beyond the frame the edge pixels repeat.
    #define SHARPEN_TILE 16
    #define SHARPEN_MAX_RADIUS 6
    #define SHARPEN_SPAN (SHARPEN_TILE + 2 * SHARPEN_MAX_RADIUS)

    kernel void apply_print_lut_sharpened(texture2d<half, access::read> inTexture [[texture(0)]],
                                          texture2d<half, access::write> outTexture [[texture(1)]],
                                          texture3d<half, access::read> lut [[texture(2)]],
                                          texture2d<half, access::read> grainA [[texture(3)]],
                                          texture2d<half, access::read> grainB [[texture(4)]],
                                          texture2d<half, access::read> sigmas [[texture(5)]],
                                          constant PrintParams &params [[buffer(0)]],
                                          constant float *weights [[buffer(1)]],
                                          constant ManualCurveParameters &manual [[buffer(2)]],
                                          constant PresencePrintParameters &presencePrint [[buffer(6)]],
                                          texture2d<float, access::read> curves [[texture(6)]],
                                          constant ToneCurveParameters &curveParams [[buffer(3)]],
                                          uint2 gid [[thread_position_in_grid]],
                                          uint2 lid [[thread_position_in_threadgroup]],
                                          uint2 group [[threadgroup_position_in_grid]]) {
        threadgroup float luma[SHARPEN_SPAN * SHARPEN_SPAN];
        threadgroup float across1[SHARPEN_SPAN * SHARPEN_TILE];
        threadgroup float across2[SHARPEN_SPAN * SHARPEN_TILE];
        int w = int(inTexture.get_width()), h = int(inTexture.get_height());
        int r1 = int(params.sharpenRadius), r2 = int(params.scalingRadius);
        constant float *weights2 = weights + 2 * r1 + 1;
        float3 lw = float3(params.lumaR, params.lumaG, params.lumaB);
        int2 origin = int2(group) * SHARPEN_TILE - SHARPEN_MAX_RADIUS;
        uint first = lid.y * SHARPEN_TILE + lid.x;
        for (uint i = first; i < SHARPEN_SPAN * SHARPEN_SPAN; i += SHARPEN_TILE * SHARPEN_TILE) {
            int2 p = clamp(origin + int2(i % SHARPEN_SPAN, i / SHARPEN_SPAN), int2(0), int2(w - 1, h - 1));
            luma[i] = dot(float3(inTexture.read(uint2(p)).rgb), lw);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint i = first; i < SHARPEN_SPAN * SHARPEN_TILE; i += SHARPEN_TILE * SHARPEN_TILE) {
            int row = int(i / SHARPEN_TILE) * SHARPEN_SPAN + int(i % SHARPEN_TILE) + SHARPEN_MAX_RADIUS;
            float sum1 = 0.0f, sum2 = 0.0f;
            for (int k = -r1; k <= r1; k++) { sum1 += weights[k + r1] * luma[row + k]; }
            for (int k = -r2; k <= r2; k++) { sum2 += weights2[k + r2] * luma[row + k]; }
            across1[i] = sum1;
            across2[i] = sum2;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (int(gid.x) >= w || int(gid.y) >= h) { return; }
        int column = (int(lid.y) + SHARPEN_MAX_RADIUS) * SHARPEN_TILE + int(lid.x);
        float blurred1 = 0.0f, blurred2 = 0.0f;
        for (int k = -r1; k <= r1; k++) { blurred1 += weights[k + r1] * across1[column + k * SHARPEN_TILE]; }
        for (int k = -r2; k <= r2; k++) { blurred2 += weights2[k + r2] * across2[column + k * SHARPEN_TILE]; }
        float centre = luma[(lid.y + SHARPEN_MAX_RADIUS) * SHARPEN_SPAN + lid.x + SHARPEN_MAX_RADIUS];
        float detail = params.sharpenAmount * (centre - blurred1) + params.scalingAmount * (centre - blurred2);
        float squared = detail * detail;
        float threshold = params.sharpenThreshold;
        detail *= squared / max(squared + threshold * threshold, 1e-20f);
        half4 pixel = inTexture.read(gid);
        float3 rgb = print_amounts(float3(pixel.rgb) + detail, float3(pixel.rgb), gid, lut, grainA, grainB, sigmas, params);
        outTexture.write(half4(print_storage(tone_curves(manual_print(presence_print(rgb, presencePrint), manual), curves, curveParams), curveParams), pixel.a), gid);
    }

    // Grain noise tiles (GrainField). A counter hash gives each pixel and layer its own
    // Gaussian value by Box-Muller; a separable blur by the dye clouds' kernel wraps at the
    // tile's edge so the tile repeats without a seam; the two cloud fields are summed and
    // scaled to unit variance.
    static inline uint grain_hash(uint x) {
        x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
        return x;
    }

    static inline float grain_uniform(uint h) { return (float(h >> 8) + 0.5f) / 16777216.0f; }

    kernel void grain_noise(texture2d<float, access::write> out [[texture(0)]],
                            constant uint &seed [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) { return; }
        uint base = grain_hash(seed ^ grain_hash(gid.x ^ grain_hash(gid.y + 0x632be59bu)));
        float3 value;
        for (uint k = 0; k < 3; k++) {
            float u1 = grain_uniform(grain_hash(base + 2u * k + 1u));
            float u2 = grain_uniform(grain_hash(base + 2u * k + 2u + 0x9e3779b9u));
            value[k] = sqrt(-2.0f * log(u1)) * cos(6.28318531f * u2);
        }
        out.write(float4(value, 1.0f), gid);
    }

    struct GrainBlurParams {
        uint radius;
        uint horizontal;
    };

    kernel void grain_blur(texture2d<float, access::read> source [[texture(0)]],
                           texture2d<float, access::write> out [[texture(1)]],
                           constant float *weights [[buffer(0)]],
                           constant GrainBlurParams &params [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
        int w = int(source.get_width()), h = int(source.get_height());
        if (int(gid.x) >= w || int(gid.y) >= h) { return; }
        int r = int(params.radius);
        float3 sum = float3(0.0f);
        for (int k = -r; k <= r; k++) {
            uint2 p = params.horizontal != 0 ? uint2((int(gid.x) + k + w) % w, gid.y)
                                             : uint2(gid.x, (int(gid.y) + k + h) % h);
            sum += weights[k + r] * source.read(p).rgb;
        }
        out.write(float4(sum, 1.0f), gid);
    }

    kernel void grain_combine(texture2d<float, access::read> a [[texture(0)]],
                              texture2d<float, access::read> b [[texture(1)]],
                              texture2d<half, access::write> out [[texture(2)]],
                              constant float &scale [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) { return; }
        out.write(half4(half3((a.read(gid).rgb + b.read(gid).rgb) * scale), 1.0h), gid);
    }

    // Halation (HalationField). The source: each pixel's light, times the Rated at gain, past
    // a soft knee at threshold, averaged over the block of frame pixels that make one field
    // pixel, so a small specular highlight keeps its energy.
    struct HalationSourceParams {
        float threshold;
        float knee;
        float gain;
        float storageScale;
    };

    kernel void halation_source(texture2d<half, access::read> frame [[texture(0)]],
                                texture2d<half, access::write> out [[texture(1)]],
                                texture2d<float, access::sample> toneBase [[texture(2)]],
                                constant HalationSourceParams &p [[buffer(0)]],
                                constant ManualCurveParameters &manual [[buffer(1)]],
                                device const float *toneTables [[buffer(2)]],
                                \(presenceSceneSignature)
                                uint2 gid [[thread_position_in_grid]]) {
        uint ow = out.get_width(), oh = out.get_height();
        if (gid.x >= ow || gid.y >= oh) { return; }
        uint fw = frame.get_width(), fh = frame.get_height();
        uint x0 = gid.x * fw / ow, x1 = max(x0 + 1, (gid.x + 1) * fw / ow);
        uint y0 = gid.y * fh / oh, y1 = max(y0 + 1, (gid.y + 1) * fh / oh);
        float3 sum = float3(0.0f);
        for (uint y = y0; y < y1; y++) {
            for (uint x = x0; x < x1; x++) {
                float2 uv = (float2(x, y) + 0.5f) / float2(fw, fh);
                float3 adjusted = scene_at(float3(frame.read(uint2(x, y)).rgb), \(sceneArguments));
                float3 v = max(adjusted, float3(0.0f)) * p.gain;
                float3 d = v - p.threshold;
                float3 soft = (d + p.knee) * (d + p.knee) / (4.0f * p.knee);
                sum += select(select(soft, d, d > p.knee), float3(0.0f), d < -p.knee);
            }
        }
        float3 averaged = sum / float((x1 - x0) * (y1 - y0));
        if (p.storageScale != 1.0f) { averaged *= p.storageScale; }
        out.write(half4(float4(averaged, 1.0f)), gid);
    }

    // The Negative LUT pass with the frame's halation added back in linear light first, read
    // from the low-resolution field with bilinear filtering.
    kernel void apply_lut3d_halation(texture2d<half, access::read> inTexture [[texture(0)]],
                                     texture2d<half, access::write> outTexture [[texture(1)]],
                                     texture3d<half, access::read> lut [[texture(2)]],
                                     texture2d<float, access::sample> halation [[texture(3)]],
                                     texture2d<float, access::sample> toneBase [[texture(4)]],
                                     constant LUTParams &params [[buffer(0)]],
                                     constant ManualCurveParameters &manual [[buffer(1)]],
                                     device const float *toneTables [[buffer(2)]],
                                     \(presenceSceneSignature)
                                     uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) { return; }
        constexpr sampler field(filter::linear, address::clamp_to_edge, coord::normalized);
        float2 uv = (float2(gid) + 0.5f) / float2(outTexture.get_width(), outTexture.get_height());
        half4 pixel = inTexture.read(gid);
        float3 linear = scene_at(float3(pixel.rgb), \(sceneArguments)) + halation.sample(field, uv).rgb;
        float3 encoded = encode_log(linear, params);
        float3 rgb = sample_tetrahedral(lut, encoded, params.lutSize);
        outTexture.write(half4(half3(rgb), pixel.a), gid);
    }

    // The halo: the blurred sources summed with their weights, which already carry the
    // strength, the channel shares and the inverse of the Rated at gain.
    struct HalationMixParams {
        float w0; float w1; float w2; float w3; float w4; float w5;
        float red; float green;
    };

    kernel void halation_mix(texture2d<float, access::read> b0 [[texture(0)]],
                             texture2d<float, access::read> b1 [[texture(1)]],
                             texture2d<float, access::read> b2 [[texture(2)]],
                             texture2d<float, access::read> b3 [[texture(3)]],
                             texture2d<float, access::read> b4 [[texture(4)]],
                             texture2d<float, access::read> b5 [[texture(5)]],
                             texture2d<half, access::write> out [[texture(6)]],
                             constant HalationMixParams &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) { return; }
        float3 sum = p.w0 * b0.read(gid).rgb + p.w1 * b1.read(gid).rgb + p.w2 * b2.read(gid).rgb
                   + p.w3 * b3.read(gid).rgb + p.w4 * b4.read(gid).rgb + p.w5 * b5.read(gid).rgb;
        out.write(half4(float4(sum.r * p.red, sum.g * p.green, 0.0f, 1.0f)), gid);
    }

    // Area resize (AreaResize): the source mapped exactly onto the output, each output pixel
    // the mean of the source area it covers, the pixels its edges cut through weighted by the
    // share of them inside. Never rings, and keeps a flat field and the image's mean.
    // Positions are whole numbers in units of 1 / (source side * output side): a source pixel is
    // `ow` units across and an output pixel `sw`, so every weight is exact and an output
    // pixel's weights add up to exactly sw by sh.
    kernel void area_resize(texture2d<float, access::read> source [[texture(0)]],
                            texture2d<half, access::write> out [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        uint ow = out.get_width(), oh = out.get_height();
        if (gid.x >= ow || gid.y >= oh) { return; }
        uint sw = source.get_width(), sh = source.get_height();
        uint x0 = gid.x * sw, x1 = x0 + sw, y0 = gid.y * sh, y1 = y0 + sh;
        uint ix1 = min((x1 + ow - 1) / ow, sw), iy1 = min((y1 + oh - 1) / oh, sh);
        float4 sum = float4(0.0f);
        for (uint y = y0 / oh; y < iy1; y++) {
            float wy = float(min((y + 1) * oh, y1) - max(y * oh, y0));
            float4 row = float4(0.0f);
            for (uint x = x0 / ow; x < ix1; x++) {
                row += float(min((x + 1) * ow, x1) - max(x * ow, x0)) * source.read(uint2(x, y));
            }
            sum += wy * row;
        }
        // Converted here, to the nearest half: the texture's own conversion rounds toward zero,
        // which moved a flat field down a step.
        out.write(half4(sum / (float(sw) * float(sh))), gid);
    }

    // Area resize a piece at a time (AreaResize.Pieces), for a source never held whole:
    // `area_resize` over the source pixels of one piece, which sits at `origin` in a source
    // `source` pixels across, its sums added to those the pieces before it left, a float4 an
    // output pixel in rows of `output.x`. Dispatched over the output pixels the piece reaches,
    // from `first`. A pixel inside one piece is summed as `area_resize` sums it; a pixel pieces
    // share is summed in parts.
    struct AreaResizePiece {
        uint2 origin;
        uint2 source;
        uint2 output;
        uint2 first;
    };

    kernel void area_resize_add(texture2d<float, access::read> piece [[texture(0)]],
                                device float4 *sums [[buffer(0)]],
                                constant AreaResizePiece &p [[buffer(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
        uint2 o = p.first + gid;
        uint ow = p.output.x, oh = p.output.y;
        if (o.x >= ow || o.y >= oh) { return; }
        uint sw = p.source.x, sh = p.source.y;
        uint x0 = o.x * sw, x1 = x0 + sw, y0 = o.y * sh, y1 = y0 + sh;
        uint ix0 = max(x0 / ow, p.origin.x), ix1 = min(min((x1 + ow - 1) / ow, sw), p.origin.x + piece.get_width());
        uint iy0 = max(y0 / oh, p.origin.y), iy1 = min(min((y1 + oh - 1) / oh, sh), p.origin.y + piece.get_height());
        if (ix0 >= ix1 || iy0 >= iy1) { return; }
        float4 sum = float4(0.0f);
        for (uint y = iy0; y < iy1; y++) {
            float wy = float(min((y + 1) * oh, y1) - max(y * oh, y0));
            float4 row = float4(0.0f);
            for (uint x = ix0; x < ix1; x++) {
                row += float(min((x + 1) * ow, x1) - max(x * ow, x0)) * piece.read(uint2(x - p.origin.x, y - p.origin.y));
            }
            sum += wy * row;
        }
        sums[o.y * ow + o.x] += sum;
    }

    // The pieces' sums as `area_resize` finishes its own.
    kernel void area_resize_finish(device const float4 *sums [[buffer(0)]],
                                   constant uint2 &source [[buffer(1)]],
                                   texture2d<half, access::write> out [[texture(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
        uint ow = out.get_width(), oh = out.get_height();
        if (gid.x >= ow || gid.y >= oh) { return; }
        out.write(half4(sums[gid.y * ow + gid.x] / (float(source.x) * float(source.y))), gid);
    }
    """
}
