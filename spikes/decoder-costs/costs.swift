// Argent spike, decoder-costs. Measurement prototype, not shipped code.
//
// costs times, on the GPU, the stages the in-house decoder path still needs after the
// tile decoder has filled a uint16 Bayer mosaic: normalization, demosaic, noise reduction
// and lens correction. Each stage is a representative Metal kernel, not a tuned or final
// one, and its cost is the median GPU time (command buffer gpuStartTime to gpuEndTime)
// of the timed runs after three warm-ups, one stage per command buffer. The full chain is
// also timed in one command buffer.
//
// Build: swiftc -O -framework Metal costs.swift -o costs
// Run:   ./costs out/L [--iters 15] [--dump out/L]
//
// --dump writes the demosaiced frame (HA + colour difference, camera matrix applied) and
// the lens-corrected frame as raw half-float RGBA files beside the prefix, for compare.py.

import Foundation
import Metal

let source = """
#include <metal_stdlib>
using namespace metal;

// p: 0 width, 1 height, 2 1/(white-black), 3 black, 4-6 white balance R G B,
// 7-10 colour at (y&1)*2+(x&1) (0 R, 1 G, 2 B), 11-19 camera to output, row-major,
// 20-22 distortion k1 k2 k3, 23-25 vignetting v1 v2 v3, 26-27 lateral CA scale R and B,
// 28-29 NR sigma luma and chroma.

inline int colorAt(constant float* p, int x, int y) { return int(p[7 + (y & 1) * 2 + (x & 1)]); }
inline float tap(texture2d<float, access::read> t, int x, int y) {
    return t.read(uint2(clamp(x, 0, int(t.get_width()) - 1), clamp(y, 0, int(t.get_height()) - 1))).r;
}
inline float3 toOutput(constant float* p, float3 c) {
    return float3(p[11] * c.x + p[12] * c.y + p[13] * c.z,
                  p[14] * c.x + p[15] * c.y + p[16] * c.z,
                  p[17] * c.x + p[18] * c.y + p[19] * c.z);
}

kernel void prep(device const ushort* raw [[buffer(0)]], constant float* p [[buffer(1)]],
                 texture2d<float, access::write> cfa [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    uint w = uint(p[0]);
    if (gid.x >= w || gid.y >= uint(p[1])) return;
    int c = colorAt(p, gid.x, gid.y);
    cfa.write(float4((float(raw[gid.y * w + gid.x]) - p[3]) * p[2] * p[4 + c]), gid);
}

kernel void bilinear(texture2d<float, access::read> cfa [[texture(0)]], texture2d<half, access::write> out [[texture(1)]],
                     constant float* p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    int x = gid.x, y = gid.y, c = colorAt(p, x, y);
    float v = tap(cfa, x, y);
    float cross = 0.25 * (tap(cfa, x - 1, y) + tap(cfa, x + 1, y) + tap(cfa, x, y - 1) + tap(cfa, x, y + 1));
    float diag = 0.25 * (tap(cfa, x - 1, y - 1) + tap(cfa, x + 1, y - 1) + tap(cfa, x - 1, y + 1) + tap(cfa, x + 1, y + 1));
    float h = 0.5 * (tap(cfa, x - 1, y) + tap(cfa, x + 1, y)), vv = 0.5 * (tap(cfa, x, y - 1) + tap(cfa, x, y + 1));
    float3 rgb;
    if (c == 0) rgb = float3(v, cross, diag);
    else if (c == 2) rgb = float3(diag, cross, v);
    else rgb = colorAt(p, x + 1, y) == 0 ? float3(h, v, vv) : float3(vv, v, h);
    out.write(half4(half3(toOutput(p, rgb)), 1), gid);
}

// Malvar, He and Cutler 2004: gradient-corrected bilinear, one 5x5 pass.
kernel void mhc(texture2d<float, access::read> cfa [[texture(0)]], texture2d<half, access::write> out [[texture(1)]],
                constant float* p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    int x = gid.x, y = gid.y, c = colorAt(p, x, y);
    float n[5][5];
    for (int j = 0; j < 5; j++) for (int i = 0; i < 5; i++) n[j][i] = tap(cfa, x + i - 2, y + j - 2);
    float C = n[2][2];
    float gAtRB = (4 * C + 2 * (n[1][2] + n[3][2] + n[2][1] + n[2][3]) - (n[0][2] + n[4][2] + n[2][0] + n[2][4])) / 8;
    float rowNeighbours = (5 * C + 4 * (n[2][1] + n[2][3]) - (n[1][1] + n[1][3] + n[3][1] + n[3][3]) - (n[2][0] + n[2][4])
                           + 0.5 * (n[0][2] + n[4][2])) / 8;
    float colNeighbours = (5 * C + 4 * (n[1][2] + n[3][2]) - (n[1][1] + n[1][3] + n[3][1] + n[3][3]) - (n[0][2] + n[4][2])
                           + 0.5 * (n[2][0] + n[2][4])) / 8;
    float opposite = (6 * C + 2 * (n[1][1] + n[1][3] + n[3][1] + n[3][3]) - 1.5 * (n[0][2] + n[4][2] + n[2][0] + n[2][4])) / 8;
    float3 rgb;
    if (c == 0) rgb = float3(C, gAtRB, opposite);
    else if (c == 2) rgb = float3(opposite, gAtRB, C);
    else rgb = colorAt(p, x + 1, y) == 0 ? float3(rowNeighbours, C, colNeighbours) : float3(colNeighbours, C, rowNeighbours);
    out.write(half4(half3(toOutput(p, rgb)), 1), gid);
}

// Hamilton-Adams: green at red and blue along the smoother direction.
kernel void greenHA(texture2d<float, access::read> cfa [[texture(0)]], texture2d<float, access::write> green [[texture(1)]],
                    constant float* p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= green.get_width() || gid.y >= green.get_height()) return;
    int x = gid.x, y = gid.y;
    float C = tap(cfa, x, y);
    if (colorAt(p, x, y) == 1) { green.write(float4(C), gid); return; }
    float gl = tap(cfa, x - 1, y), gr = tap(cfa, x + 1, y), gu = tap(cfa, x, y - 1), gd = tap(cfa, x, y + 1);
    float lh = 2 * C - tap(cfa, x - 2, y) - tap(cfa, x + 2, y), lv = 2 * C - tap(cfa, x, y - 2) - tap(cfa, x, y + 2);
    float dh = abs(gl - gr) + abs(lh), dv = abs(gu - gd) + abs(lv);
    float gh = 0.5 * (gl + gr) + 0.25 * lh, gv = 0.5 * (gu + gd) + 0.25 * lv;
    float g = dh < dv ? gh : (dv < dh ? gv : 0.5 * (gh + gv));
    green.write(float4(g), gid);
}

// Red and blue by bilinear interpolation of the colour differences against the full green.
kernel void rbColorDifference(texture2d<float, access::read> cfa [[texture(0)]], texture2d<float, access::read> green [[texture(1)]],
                              texture2d<half, access::write> out [[texture(2)]], constant float* p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    int x = gid.x, y = gid.y, c = colorAt(p, x, y);
    float G = tap(green, x, y);
    #define DIFF(i, j) (tap(cfa, i, j) - tap(green, i, j))
    float3 rgb;
    if (c != 1) {
        float other = G + 0.25 * (DIFF(x - 1, y - 1) + DIFF(x + 1, y - 1) + DIFF(x - 1, y + 1) + DIFF(x + 1, y + 1));
        float own = tap(cfa, x, y);
        rgb = c == 0 ? float3(own, G, other) : float3(other, G, own);
    } else {
        float h = 0.5 * (DIFF(x - 1, y) + DIFF(x + 1, y)), v = 0.5 * (DIFF(x, y - 1) + DIFF(x, y + 1));
        rgb = colorAt(p, x + 1, y) == 0 ? float3(G + h, G, G + v) : float3(G + v, G, G + h);
    }
    out.write(half4(half3(toOutput(p, rgb)), 1), gid);
}

// Noise reduction works on Y = (R + 2G + B) / 4 and the differences R - G, B - G.
kernel void toOpponent(texture2d<half, access::read> rgbIn [[texture(0)]], texture2d<half, access::write> opp [[texture(1)]],
                       texture2d<half, access::write> acc [[texture(2)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= opp.get_width() || gid.y >= opp.get_height()) return;
    float3 c = float3(rgbIn.read(gid).rgb);
    opp.write(half4(0.25 * (c.r + 2 * c.g + c.b), c.r - c.g, c.b - c.g, 1), gid);
    acc.write(half4(0), gid);
}

// One level of the a-trous B3-spline wavelet: smooth at dilation 2^level, soft-threshold the
// detail, and add it to the accumulator.
kernel void atrous(texture2d<half, access::read> src [[texture(0)]], texture2d<half, access::write> dst [[texture(1)]],
                   texture2d<half, access::read_write> acc [[texture(2)]], constant float* p [[buffer(0)]],
                   constant int& level [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
    int w = src.get_width(), h = src.get_height();
    if (int(gid.x) >= w || int(gid.y) >= h) return;
    const float k[5] = {1.0 / 16, 4.0 / 16, 6.0 / 16, 4.0 / 16, 1.0 / 16};
    int step = 1 << level;
    float3 sum = 0;
    for (int j = 0; j < 5; j++) for (int i = 0; i < 5; i++) {
        int2 q = clamp(int2(gid) + int2((i - 2) * step, (j - 2) * step), int2(0), int2(w - 1, h - 1));
        sum += k[i] * k[j] * float3(src.read(uint2(q)).rgb);
    }
    float3 detail = float3(src.read(gid).rgb) - sum;
    float3 t = float3(p[28], p[29], p[29]) / float(1 << level);
    float3 kept = sign(detail) * max(abs(detail) - t, 0.0);
    acc.write(acc.read(gid) + half4(half3(kept), 0), gid);
    dst.write(half4(half3(sum), 1), gid);
}

// The same level as two 5-tap passes: horizontal into tmp, then vertical with the threshold.
kernel void atrousH(texture2d<half, access::read> src [[texture(0)]], texture2d<half, access::write> tmp [[texture(1)]],
                    constant int& level [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
    int w = src.get_width(), h = src.get_height();
    if (int(gid.x) >= w || int(gid.y) >= h) return;
    const float k[5] = {1.0 / 16, 4.0 / 16, 6.0 / 16, 4.0 / 16, 1.0 / 16};
    int step = 1 << level;
    float3 sum = 0;
    for (int i = 0; i < 5; i++) sum += k[i] * float3(src.read(uint2(clamp(int(gid.x) + (i - 2) * step, 0, w - 1), gid.y)).rgb);
    tmp.write(half4(half3(sum), 1), gid);
}

kernel void atrousV(texture2d<half, access::read> src [[texture(0)]], texture2d<half, access::read> tmp [[texture(1)]],
                    texture2d<half, access::write> dst [[texture(2)]], texture2d<half, access::read_write> acc [[texture(3)]],
                    constant float* p [[buffer(0)]], constant int& level [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
    int w = src.get_width(), h = src.get_height();
    if (int(gid.x) >= w || int(gid.y) >= h) return;
    const float k[5] = {1.0 / 16, 4.0 / 16, 6.0 / 16, 4.0 / 16, 1.0 / 16};
    int step = 1 << level;
    float3 sum = 0;
    for (int j = 0; j < 5; j++) sum += k[j] * float3(tmp.read(uint2(gid.x, clamp(int(gid.y) + (j - 2) * step, 0, h - 1))).rgb);
    float3 detail = float3(src.read(gid).rgb) - sum;
    float3 t = float3(p[28], p[29], p[29]) / float(1 << level);
    acc.write(acc.read(gid) + half4(half3(sign(detail) * max(abs(detail) - t, 0.0)), 0), gid);
    dst.write(half4(half3(sum), 1), gid);
}

// Laplacian pyramid: reduce with the B3 kernel at stride 2, then rebuild each level from the
// expanded coarser reconstruction plus its soft-thresholded detail. Expansion is one bilinear
// sample of the coarser level.
kernel void pyrDown(texture2d<half, access::read> src [[texture(0)]], texture2d<half, access::write> dst [[texture(1)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    int w = src.get_width(), h = src.get_height();
    const float k[5] = {1.0 / 16, 4.0 / 16, 6.0 / 16, 4.0 / 16, 1.0 / 16};
    float3 sum = 0;
    for (int j = 0; j < 5; j++) for (int i = 0; i < 5; i++) {
        int2 q = clamp(int2(gid) * 2 + int2(i - 2, j - 2), int2(0), int2(w - 1, h - 1));
        sum += k[i] * k[j] * float3(src.read(uint2(q)).rgb);
    }
    dst.write(half4(half3(sum), 1), gid);
}

kernel void pyrUp(texture2d<half, access::read> fine [[texture(0)]], texture2d<half, access::sample> coarse [[texture(1)]],
                  texture2d<half, access::sample> coarseRebuilt [[texture(2)]], texture2d<half, access::write> out [[texture(3)]],
                  constant float* p [[buffer(0)]], constant int& level [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(out.get_width(), out.get_height());
    float3 detail = float3(fine.read(gid).rgb) - float3(coarse.sample(s, uv).rgb);
    float3 t = float3(p[28], p[29], p[29]) / float(1 << level);
    float3 kept = sign(detail) * max(abs(detail) - t, 0.0);
    out.write(half4(half3(float3(coarseRebuilt.sample(s, uv).rgb) + kept), 1), gid);
}

kernel void toRGB(texture2d<half, access::read> o [[texture(0)]], texture2d<half, access::write> out [[texture(1)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float3 v = float3(o.read(gid).rgb);
    float g = v.x - 0.25 * (v.y + v.z);
    out.write(half4(half(v.y + g), half(g), half(v.z + g), 1), gid);
}

kernel void recombine(texture2d<half, access::read> smooth [[texture(0)]], texture2d<half, access::read> acc [[texture(1)]],
                      texture2d<half, access::write> out [[texture(2)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float3 o = float3(smooth.read(gid).rgb) + float3(acc.read(gid).rgb);
    float g = o.x - 0.25 * (o.y + o.z);
    out.write(half4(half(o.y + g), half(g), half(o.z + g), 1), gid);
}

kernel void bilateralY(texture2d<half, access::read> opp [[texture(0)]], texture2d<half, access::write> out [[texture(1)]],
                       constant float* p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    int w = opp.get_width(), h = opp.get_height();
    if (int(gid.x) >= w || int(gid.y) >= h) return;
    float4 center = float4(opp.read(gid));
    float sum = 0, weight = 0, inv = 1.0 / (2 * p[28] * p[28]);
    for (int j = -2; j <= 2; j++) for (int i = -2; i <= 2; i++) {
        float y = float(opp.read(uint2(clamp(int2(gid) + int2(i, j), int2(0), int2(w - 1, h - 1)))).r);
        float wgt = exp(-float(i * i + j * j) / 4.5 - (y - center.r) * (y - center.r) * inv);
        sum += wgt * y; weight += wgt;
    }
    out.write(half4(half(sum / weight), half(center.g), half(center.b), 1), gid);
}

// Non-local means on Y, 3x3 patches over a 7x7 search window: the expensive end.
kernel void nlmY(texture2d<half, access::read> opp [[texture(0)]], texture2d<half, access::write> out [[texture(1)]],
                 constant float* p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    int w = opp.get_width(), h = opp.get_height();
    if (int(gid.x) >= w || int(gid.y) >= h) return;
    int2 g = int2(gid);
    #define Y(q) float(opp.read(uint2(clamp((q), int2(0), int2(w - 1, h - 1)))).r)
    float sum = 0, weight = 0, inv = 1.0 / (9 * 2 * p[28] * p[28]);
    for (int sj = -3; sj <= 3; sj++) for (int si = -3; si <= 3; si++) {
        float d = 0;
        for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
            float e = Y(g + int2(i, j)) - Y(g + int2(si + i, sj + j));
            d += e * e;
        }
        float wgt = exp(-d * inv);
        sum += wgt * Y(g + int2(si, sj)); weight += wgt;
    }
    #undef Y
    float4 center = float4(opp.read(gid));
    out.write(half4(half(sum / weight), half(center.g), half(center.b), 1), gid);
}

// Lens correction in one resampling pass: radial distortion, lateral chromatic aberration as
// a per-channel radial scale, and vignetting as a radial gain.
inline float2 sourcePosition(constant float* p, float2 centre, float norm, uint2 gid, float scale, thread float& r2) {
    float2 d = (float2(gid) + 0.5 - centre) * norm;
    r2 = dot(d, d);
    float distort = 1 + r2 * (p[20] + r2 * (p[21] + r2 * p[22]));
    return centre + d * distort * scale / norm;
}

kernel void lensBilinear(texture2d<half, access::sample> src [[texture(0)]], texture2d<half, access::write> out [[texture(1)]],
                         constant float* p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    constexpr sampler s(coord::pixel, filter::linear, address::clamp_to_edge);
    float2 centre = float2(out.get_width(), out.get_height()) * 0.5;
    float norm = 1.0 / length(centre), r2;
    float2 pg = sourcePosition(p, centre, norm, gid, 1.0, r2);
    float2 pr = sourcePosition(p, centre, norm, gid, p[26], r2), pb = sourcePosition(p, centre, norm, gid, p[27], r2);
    float vig = 1 + r2 * (p[23] + r2 * (p[24] + r2 * p[25]));
    out.write(half4(half(src.sample(s, pr).r * vig), half(src.sample(s, pg).g * vig), half(src.sample(s, pb).b * vig), 1), gid);
}

inline float4 cubicWeights(float t) {
    float t2 = t * t, t3 = t2 * t;
    return float4(-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1, -1.5 * t3 + 2 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2);
}
inline float catmullRom(texture2d<half, access::read> src, float2 pos, int channel) {
    float2 q = pos - 0.5, f = floor(q), t = q - f;
    float4 wx = cubicWeights(t.x), wy = cubicWeights(t.y);
    int w = src.get_width(), h = src.get_height();
    float sum = 0;
    for (int j = 0; j < 4; j++) for (int i = 0; i < 4; i++) {
        int2 c = clamp(int2(f) + int2(i - 1, j - 1), int2(0), int2(w - 1, h - 1));
        sum += wx[i] * wy[j] * float(src.read(uint2(c))[channel]);
    }
    return sum;
}

kernel void lensBicubic(texture2d<half, access::read> src [[texture(0)]], texture2d<half, access::write> out [[texture(1)]],
                        constant float* p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float2 centre = float2(out.get_width(), out.get_height()) * 0.5;
    float norm = 1.0 / length(centre), r2;
    float2 pg = sourcePosition(p, centre, norm, gid, 1.0, r2);
    float2 pr = sourcePosition(p, centre, norm, gid, p[26], r2), pb = sourcePosition(p, centre, norm, gid, p[27], r2);
    float vig = 1 + r2 * (p[23] + r2 * (p[24] + r2 * p[25]));
    out.write(half4(half(catmullRom(src, pr, 0) * vig), half(catmullRom(src, pg, 1) * vig), half(catmullRom(src, pb, 2) * vig), 1), gid);
}
"""

// MARK: Host

struct Meta: Decodable {
    var width: Int
    var height: Int
    var pattern: [[Int]]
    var black: [Int]
    var white: Int
    var camMul: [Double]
    var xyzToCamera: [[Double]]
}

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }

var arguments = Array(CommandLine.arguments.dropFirst())
guard let prefix = arguments.first else { fail("usage: costs PREFIX [--iters N] [--dump PREFIX]") }
var iterations = 15
var dumpPrefix: String?
var index = 1
while index < arguments.count {
    switch arguments[index] {
    case "--iters": iterations = Int(arguments[index + 1])!; index += 2
    case "--dump": dumpPrefix = arguments[index + 1]; index += 2
    default: fail("unknown argument \(arguments[index])")
    }
}

let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: URL(fileURLWithPath: prefix + ".json")))
let mosaicData = try Data(contentsOf: URL(fileURLWithPath: prefix + ".cfa"))
let width = meta.width, height = meta.height
guard mosaicData.count == width * height * 2 else { fail("mosaic size mismatch") }

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fail("no Metal device") }
let library = try device.makeLibrary(source: source, options: nil)
func pipeline(_ name: String) -> MTLComputePipelineState {
    try! device.makeComputePipelineState(function: library.makeFunction(name: name)!)
}

// Camera to linear Rec. 2020, the dcraw way: rows of camera-from-Rec.2020 normalized to sum 1,
// then inverted, so white-balanced camera white maps to equal RGB.
let xyzFromRec2020: [[Double]] = [[0.636958, 0.144617, 0.168881], [0.262700, 0.677998, 0.059302], [0.0, 0.028073, 1.060985]]
func multiply(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
    (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + a[i][$1] * b[$1][j] } } }
}
func invert(_ m: [[Double]]) -> [[Double]] {
    let a = m[0][0], b = m[0][1], c = m[0][2], d = m[1][0], e = m[1][1], f = m[1][2], g = m[2][0], h = m[2][1], i = m[2][2]
    let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    return [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
            [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
            [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]
}
var cameraFromRec2020 = multiply(meta.xyzToCamera, xyzFromRec2020)
cameraFromRec2020 = cameraFromRec2020.map { row in let s = row.reduce(0, +); return row.map { $0 / s } }
let rec2020FromCamera = invert(cameraFromRec2020)

let green = meta.camMul[1]
var params = [Float](repeating: 0, count: 32)
params[0] = Float(width); params[1] = Float(height)
params[2] = 1 / Float(meta.white - meta.black[0]); params[3] = Float(meta.black[0])
params[4] = Float(meta.camMul[0] / green); params[5] = 1; params[6] = Float(meta.camMul[2] / green)
for (k, c) in [meta.pattern[0][0], meta.pattern[0][1], meta.pattern[1][0], meta.pattern[1][1]].enumerated() { params[7 + k] = Float(c) }
for r in 0..<3 { for c in 0..<3 { params[11 + r * 3 + c] = Float(rec2020FromCamera[r][c]) } }
// A plausible 50 mm prime: mild barrel distortion, lateral CA of a few pixels at the corner,
// two thirds of a stop of vignetting. Only the arithmetic matters for the timing.
params[20] = -0.02; params[21] = 0.004; params[22] = 0
params[23] = 0.35; params[24] = 0.1; params[25] = 0
params[26] = 1.0003; params[27] = 0.9997
params[28] = 0.01; params[29] = 0.02
let paramBuffer = device.makeBuffer(bytes: params, length: params.count * 4, options: .storageModeShared)!

// The tile decoder writes straight into a shared buffer; here the mosaic is copied in, and
// the copy is timed on the CPU only to show what a decoder without that buffer would pay.
let mosaic = device.makeBuffer(length: mosaicData.count, options: .storageModeShared)!
var copyTimes: [Double] = []
for _ in 0..<5 {
    let start = DispatchTime.now().uptimeNanoseconds
    mosaicData.withUnsafeBytes { _ = memcpy(mosaic.contents(), $0.baseAddress!, mosaicData.count) }
    copyTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
}

func texture(_ format: MTLPixelFormat, storage: MTLStorageMode = .private) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]
    d.storageMode = storage
    return device.makeTexture(descriptor: d)!
}
let cfa = texture(.r32Float), greenPlane = texture(.r32Float)
let rgb = texture(.rgba16Float), opp = texture(.rgba16Float), smoothA = texture(.rgba16Float), smoothB = texture(.rgba16Float)
let acc = texture(.rgba16Float), denoised = texture(.rgba16Float), lensOut = texture(.rgba16Float), scratch = texture(.rgba16Float)

let pipes = ["prep", "bilinear", "mhc", "greenHA", "rbColorDifference", "toOpponent", "atrous", "atrousH", "atrousV", "recombine", "pyrDown", "pyrUp", "toRGB",
             "bilateralY", "nlmY", "lensBilinear", "lensBicubic"].reduce(into: [String: MTLComputePipelineState]()) { $0[$1] = pipeline($1) }

func dispatch(_ e: MTLComputeCommandEncoder, _ name: String, textures: [MTLTexture], buffers: [MTLBuffer] = [paramBuffer],
              level: Int32? = nil, grid: MTLTexture? = nil) {
    let p = pipes[name]!
    e.setComputePipelineState(p)
    for (i, t) in textures.enumerated() { e.setTexture(t, index: i) }
    if name == "prep" {
        e.setBuffer(mosaic, offset: 0, index: 0)
        e.setBuffer(paramBuffer, offset: 0, index: 1)
    } else {
        for (i, b) in buffers.enumerated() { e.setBuffer(b, offset: 0, index: i) }
    }
    if var level { e.setBytes(&level, length: 4, index: 1) }
    let w = p.threadExecutionWidth, h = p.maxTotalThreadsPerThreadgroup / w
    let size = grid.map { MTLSize(width: $0.width, height: $0.height, depth: 1) } ?? MTLSize(width: width, height: height, depth: 1)
    e.dispatchThreads(size, threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
}

// The stages, each an encoding closure, so they can be timed alone and chained.
let prepStage: (MTLComputeCommandEncoder) -> Void = { dispatch($0, "prep", textures: [cfa]) }
let haStage: (MTLComputeCommandEncoder) -> Void = {
    dispatch($0, "greenHA", textures: [cfa, greenPlane])
    dispatch($0, "rbColorDifference", textures: [cfa, greenPlane, rgb])
}
let atrousLevels = 5
let atrousStage: (MTLComputeCommandEncoder) -> Void = { e in
    dispatch(e, "toOpponent", textures: [rgb, opp, acc], buffers: [])
    var src = opp, dst = smoothA
    for level in 0..<atrousLevels {
        dispatch(e, "atrous", textures: [src, dst, acc], level: Int32(level))
        src = dst
        dst = (dst === smoothA) ? smoothB : smoothA
    }
    dispatch(e, "recombine", textures: [src, acc, denoised], buffers: [])
}
let separableStage: (MTLComputeCommandEncoder) -> Void = { e in
    dispatch(e, "toOpponent", textures: [rgb, opp, acc], buffers: [])
    var src = opp, dst = smoothA
    for level in 0..<atrousLevels {
        dispatch(e, "atrousH", textures: [src, scratch], buffers: [], level: Int32(level))
        dispatch(e, "atrousV", textures: [src, scratch, dst, acc], level: Int32(level))
        src = dst
        dst = (dst === smoothA) ? smoothB : smoothA
    }
    dispatch(e, "recombine", textures: [src, acc, denoised], buffers: [])
}
// Pyramid levels: originals at full, 1/2, 1/4 ... and their reconstructions.
func levelTexture(_ level: Int) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(1, (width + (1 << level) - 1) >> level),
                                                     height: max(1, (height + (1 << level) - 1) >> level), mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]
    d.storageMode = .private
    return device.makeTexture(descriptor: d)!
}
let pyramidLevels = 5
let originals = [opp] + (1...pyramidLevels).map(levelTexture)
let rebuilt = [smoothA] + (1..<pyramidLevels).map(levelTexture)
let pyramidStage: (MTLComputeCommandEncoder) -> Void = { e in
    dispatch(e, "toOpponent", textures: [rgb, opp, acc], buffers: [])
    for l in 0..<pyramidLevels { dispatch(e, "pyrDown", textures: [originals[l], originals[l + 1]], buffers: [], grid: originals[l + 1]) }
    for l in stride(from: pyramidLevels - 1, through: 0, by: -1) {
        let coarseRebuilt = l == pyramidLevels - 1 ? originals[pyramidLevels] : rebuilt[l + 1]
        dispatch(e, "pyrUp", textures: [originals[l], originals[l + 1], coarseRebuilt, rebuilt[l]], level: Int32(l), grid: rebuilt[l])
    }
    dispatch(e, "toRGB", textures: [rebuilt[0], denoised], buffers: [])
}
let lensStage: (MTLComputeCommandEncoder) -> Void = { dispatch($0, "lensBicubic", textures: [denoised, lensOut]) }

func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2 }

func time(_ encode: (MTLComputeCommandEncoder) -> Void) -> (median: Double, min: Double, max: Double) {
    var samples: [Double] = []
    for run in 0..<(iterations + 3) {
        let cb = queue.makeCommandBuffer()!
        let e = cb.makeComputeCommandEncoder()!
        encode(e)
        e.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { fail("GPU error: \(error)") }
        if run >= 3 { samples.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
    }
    return (median(samples), samples.min()!, samples.max()!)
}

print("frame    \(width)x\(height), \(String(format: "%.1f", Double(width * height) / 1e6)) MP, \(device.name), \(iterations) timed runs per stage")
print(String(format: "copy     mosaic into a shared buffer, CPU: median %.1f ms (a tile decoder writing in place pays none)", median(copyTimes)))
// Run prep and the HA demosaic once so the downstream stages read a real image.
_ = time { prepStage($0); haStage($0) }

let stages: [(String, (MTLComputeCommandEncoder) -> Void)] = [
    ("normalize (black, scale, white balance) into an R32F plane", prepStage),
    ("demosaic: bilinear", { dispatch($0, "bilinear", textures: [cfa, scratch]) }),
    ("demosaic: Malvar-He-Cutler 5x5", { dispatch($0, "mhc", textures: [cfa, scratch]) }),
    ("demosaic: Hamilton-Adams green + colour-difference R/B (2 passes)", haStage),
    ("NR: a-trous wavelet, 5 levels, luma and chroma (7 passes)", atrousStage),
    ("NR: a-trous wavelet, 5 levels, separable (12 passes)", separableStage),
    ("NR: Laplacian pyramid, 5 levels, luma and chroma (12 passes, decimated)", pyramidStage),
    ("NR: bilateral 5x5 on luma", { dispatch($0, "bilateralY", textures: [opp, scratch]) }),
    ("NR: non-local means 3x3 patch, 7x7 search, luma", { dispatch($0, "nlmY", textures: [opp, scratch]) }),
    ("lens: distortion + lateral CA + vignetting, bilinear", { dispatch($0, "lensBilinear", textures: [denoised, scratch]) }),
    ("lens: distortion + lateral CA + vignetting, Catmull-Rom bicubic", lensStage),
]
for (name, stage) in stages {
    let t = time(stage)
    print(String(format: "%7.2f ms  (%.2f to %.2f)  %@", t.median, t.min, t.max, name))
}
let chain = time { prepStage($0); haStage($0); pyramidStage($0); lensStage($0) }
print(String(format: "%7.2f ms  (%.2f to %.2f)  chain: normalize, HA demosaic, pyramid NR, bicubic lens, one command buffer",
             chain.median, chain.min, chain.max))

if let dumpPrefix {
    func dump(_ t: MTLTexture, _ path: String) {
        let bytes = width * height * 8
        let buffer = device.makeBuffer(length: bytes, options: .storageModeShared)!
        let cb = queue.makeCommandBuffer()!
        let blit = cb.makeBlitCommandEncoder()!
        blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: width * 8, destinationBytesPerImage: bytes)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        try! Data(bytesNoCopy: buffer.contents(), count: bytes, deallocator: .none).write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
    _ = time { prepStage($0); haStage($0); pyramidStage($0); lensStage($0) }
    dump(rgb, dumpPrefix + ".demosaic.rgba16f")
    dump(denoised, dumpPrefix + ".denoised.rgba16f")
    dump(lensOut, dumpPrefix + ".lens.rgba16f")
}
