// Argent spike, decoder-probes. Measurement probe, not shipped code.
//
// moire_probe measures what CIRAWFilter's moireReductionAmount changes. It decodes
// one raw at several amounts with the pinned settings and reports, per amount, the
// 3 by 3 Laplacian high-pass energy of Y, R-G and B-G, and per pair of amounts the
// RMS of the difference in Y and chroma and of the 8 by 8 and 64 by 64 block means,
// which says how much of the change is low-frequency. With --time N it also times N
// decodes at amount 0 and 1, alternating, rendered to a Metal texture, and prints
// medians.
//
// Build: swiftc -O -framework CoreImage -framework CoreGraphics -framework Metal -framework ImageIO moire_probe.swift -o moire_probe
// Run:   ./moire_probe [--scale 1.0] [--no-lens] [--levels 0,0.05,0.5,1] [--time N] FILE

// moire_probe: characterise what moireReductionAmount changes.
//
// Decodes one raw at several moireReductionAmount levels with the project's pinned
// settings and reports, per level: high-pass (3x3 Laplacian) energy of Y, R-G, B-G;
// and, per pair of levels: RMS of the difference in Y and chroma, and the RMS of the
// block-mean difference at 8x8 and 64x64 (low-frequency content of the change).
// With --time N it also times N decodes at moire 0 and 1, alternating, and prints medians.
//
// Usage: moire_probe [--scale 1.0] [--no-lens] [--levels 0,0.05,0.5,1] [--time N] file.ARW

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal

var scale: Float = 1.0
var lens = true
var levels: [Float] = [0, 0.05, 0.5, 1]
var timeN = 0
var files: [String] = []
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--scale": scale = Float(it.next()!)!
    case "--no-lens": lens = false
    case "--levels": levels = it.next()!.split(separator: ",").map { Float($0)! }
    case "--time": timeN = Int(it.next()!)!
    default: files.append(a)
    }
}

let device = MTLCreateSystemDefaultDevice()!
let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
let ctx = CIContext(mtlDevice: device, options: [
    .workingColorSpace: linear,
    .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
    .cacheIntermediates: false,
])

func pinned(_ url: URL, moire: Float) -> CIRAWFilter {
    let f = CIRAWFilter(imageURL: url)!
    if f.supportedDecoderVersions.contains(.version8) { f.decoderVersion = .version8 }
    f.boostAmount = 0
    f.boostShadowAmount = 0
    f.isGamutMappingEnabled = false
    f.baselineExposure = 0
    f.shadowBias = 0
    f.sharpnessAmount = 0
    f.isHighlightRecoveryEnabled = true
    f.extendedDynamicRangeAmount = 1
    f.exposure = 0
    f.scaleFactor = scale
    f.isDraftModeEnabled = scale <= 0.5
    f.isLensCorrectionEnabled = lens
    f.luminanceNoiseReductionAmount = 0
    f.colorNoiseReductionAmount = 0.5
    f.moireReductionAmount = moire
    return f
}

// Y, C1 = R-G, C2 = B-G planes.
struct Planes {
    var w: Int, h: Int
    var y: [Float], c1: [Float], c2: [Float]
}

func render(_ f: CIRAWFilter) -> (Planes, Double) {
    let t0 = Date()
    let img = f.outputImage!
    let ext = img.extent.integral
    let w = Int(ext.width), h = Int(ext.height)
    var buf = [Float](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { p in
        ctx.render(img, toBitmap: p.baseAddress!, rowBytes: w * 16, bounds: ext,
                   format: .RGBAf, colorSpace: linear)
    }
    let t = Date().timeIntervalSince(t0)
    var y = [Float](repeating: 0, count: w * h)
    var c1 = y, c2 = y
    for i in 0..<(w * h) {
        let r = buf[i * 4], g = buf[i * 4 + 1], b = buf[i * 4 + 2]
        y[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        c1[i] = r - g
        c2[i] = b - g
    }
    return (Planes(w: w, h: h, y: y, c1: c1, c2: c2), t)
}

func rms(_ a: [Float]) -> Double {
    var s = 0.0
    for v in a { s += Double(v) * Double(v) }
    return (s / Double(a.count)).squareRoot()
}

func rmsDiff(_ a: [Float], _ b: [Float]) -> Double {
    var s = 0.0
    for i in 0..<a.count { let d = Double(b[i] - a[i]); s += d * d }
    return (s / Double(a.count)).squareRoot()
}

// RMS of a 3x3 Laplacian (4-neighbour) of the plane: high-pass energy.
func hpRMS(_ p: [Float], _ w: Int, _ h: Int) -> Double {
    var s = 0.0
    var n = 0
    for yy in 1..<(h - 1) {
        for xx in 1..<(w - 1) {
            let i = yy * w + xx
            let l = 4 * p[i] - p[i - 1] - p[i + 1] - p[i - w] - p[i + w]
            s += Double(l) * Double(l)
            n += 1
        }
    }
    return (s / Double(n)).squareRoot()
}

// RMS of the block-mean of (b - a) over k x k blocks.
func blockRMS(_ a: [Float], _ b: [Float], _ w: Int, _ h: Int, _ k: Int) -> Double {
    let bw = w / k, bh = h / k
    var s = 0.0
    for by in 0..<bh {
        for bx in 0..<bw {
            var acc = 0.0
            for yy in 0..<k {
                let row = (by * k + yy) * w + bx * k
                for xx in 0..<k { acc += Double(b[row + xx] - a[row + xx]) }
            }
            let m = acc / Double(k * k)
            s += m * m
        }
    }
    return (s / Double(bw * bh)).squareRoot()
}

func f(_ v: Double) -> String { String(format: "%.4e", v) }

for path in files {
    let url = URL(fileURLWithPath: path)
    print("== \(url.lastPathComponent)  scale=\(scale) lens=\(lens) levels=\(levels)")
    var frames: [Planes] = []
    for m in levels {
        let (p, t) = render(pinned(url, moire: m))
        print(String(format: "   moire=%.2f  %dx%d  decode %.3f s  rmsY=%@  hpRMS(Y)=%@  hpRMS(R-G)=%@  hpRMS(B-G)=%@",
                     m, p.w, p.h, t, f(rms(p.y)), f(hpRMS(p.y, p.w, p.h)), f(hpRMS(p.c1, p.w, p.h)), f(hpRMS(p.c2, p.w, p.h))))
        frames.append(p)
    }
    for i in 0..<levels.count {
        for j in (i + 1)..<levels.count {
            let a = frames[i], b = frames[j]
            let dy = rmsDiff(a.y, b.y)
            let dc = ((pow(rmsDiff(a.c1, b.c1), 2) + pow(rmsDiff(a.c2, b.c2), 2)) / 2).squareRoot()
            let b8 = blockRMS(a.y, b.y, a.w, a.h, 8)
            let b64 = blockRMS(a.y, b.y, a.w, a.h, 64)
            let c8 = blockRMS(a.c1, b.c1, a.w, a.h, 8)
            let c64 = blockRMS(a.c1, b.c1, a.w, a.h, 64)
            print(String(format: "   pair %.2f vs %.2f: rmsDiffY=%@  rmsDiffChroma=%@  blockMeanDiffY 8px=%@ 64px=%@  blockMeanDiff(R-G) 8px=%@ 64px=%@",
                         levels[i], levels[j], f(dy), f(dc), f(b8), f(b64), f(c8), f(c64)))
        }
    }
    frames.removeAll()
    if timeN > 0 {
        var t0s: [Double] = [], t1s: [Double] = []
        for _ in 0..<timeN {
            for m: Float in [0, 1] {
                let fl = pinned(url, moire: m)
                let t0 = Date()
                let img = fl.outputImage!
                let ext = img.extent.integral
                let w = Int(ext.width), h = Int(ext.height)
                let tex = device.makeTexture(descriptor: {
                    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
                    d.usage = [.shaderWrite, .shaderRead]
                    d.storageMode = .private
                    return d
                }())!
                let cb = ctx.render(img, to: tex, commandBuffer: nil, bounds: ext, colorSpace: linear)
                _ = cb
                // ctx.render with nil command buffer is synchronous.
                let t = Date().timeIntervalSince(t0)
                if m == 0 { t0s.append(t) } else { t1s.append(t) }
            }
        }
        t0s.sort(); t1s.sort()
        print(String(format: "   timing (GPU texture render, %d each, alternating): moire=0 median %.3f s [%.3f..%.3f]  moire=1 median %.3f s [%.3f..%.3f]",
                     timeN, t0s[timeN / 2], t0s.first!, t0s.last!, t1s[timeN / 2], t1s.first!, t1s.last!))
    }
}
