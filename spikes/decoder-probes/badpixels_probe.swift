// Argent spike, decoder-probes. Measurement probe, not shipped code.
//
// badpixels_probe finds where a decode goes out of range. For each file, at scale 1.0
// and at moireReductionAmount 0 and 1, it counts pixels with any channel above 4.0 or
// below -0.5, reports their bounding box, how many lie in the outer 32 px border, the
// counts per 8-column band over the last 64 columns and per 8-row band over the first
// 64 rows, and the interior and border minimum and maximum. It found the garbage
// columns at the right edge of the full-frame Lossless S sample and the negative
// demosaic overshoots that moire reduction removes.
//
// Build: swiftc -O -framework CoreImage -framework CoreGraphics -framework Metal -framework ImageIO badpixels_probe.swift -o badpixels_probe
// Run:   ./badpixels_probe [--levels 0,1] [--scale 1.0] FILE...

// badpixels_probe: where are the bad pixels? For each file, scale 1.0, moire 0 and 1:
// count pixels with any channel > 4.0 or < -0.5, their bounding box, how many lie in the
// outer 32 px border, per-column-band counts for the last 64 columns, and interior min/max.
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal

var files: [String] = []
var levels: [Float] = [0, 1]
var scale: Float = 1.0
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--levels": levels = it.next()!.split(separator: ",").map { Float($0)! }
    case "--scale": scale = Float(it.next()!)!
    default: files.append(a)
    }
}
let device = MTLCreateSystemDefaultDevice()!
let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
let ctx = CIContext(mtlDevice: device, options: [.workingColorSpace: linear, .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue), .cacheIntermediates: false])
func pinned(_ url: URL, moire: Float) -> CIRAWFilter {
    let f = CIRAWFilter(imageURL: url)!
    if f.supportedDecoderVersions.contains(.version8) { f.decoderVersion = .version8 }
    f.boostAmount = 0; f.boostShadowAmount = 0; f.isGamutMappingEnabled = false
    f.baselineExposure = 0; f.shadowBias = 0; f.sharpnessAmount = 0
    f.isHighlightRecoveryEnabled = true; f.extendedDynamicRangeAmount = 1; f.exposure = 0
    f.scaleFactor = scale; f.isDraftModeEnabled = scale <= 0.5
    f.isLensCorrectionEnabled = true; f.luminanceNoiseReductionAmount = 0; f.colorNoiseReductionAmount = 0.5
    f.moireReductionAmount = moire
    return f
}
for path in files {
    let url = URL(fileURLWithPath: path)
    print("== \(url.lastPathComponent)")
    for m in levels {
        let f = pinned(url, moire: m)
        let img = f.outputImage!
        let ext = img.extent.integral
        let w = Int(ext.width), h = Int(ext.height)
        var buf = [Float](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { p in ctx.render(img, toBitmap: p.baseAddress!, rowBytes: w * 16, bounds: ext, format: .RGBAf, colorSpace: linear) }
        var bad = 0, badBorder = 0
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        var colBand = [Int](repeating: 0, count: 8) // last 64 columns in bands of 8
        var rowBand = [Int](repeating: 0, count: 8) // first 64 rows in bands of 8
        var imin = Float.infinity, imax = -Float.infinity
        var bmin = Float.infinity, bmax = -Float.infinity
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let r = buf[i], g = buf[i+1], b = buf[i+2]
            let mx = max(r, g, b), mn = min(r, g, b)
            let border = x < 32 || y < 32 || x >= w - 32 || y >= h - 32
            if border { bmin = min(bmin, mn); bmax = max(bmax, mx) } else { imin = min(imin, mn); imax = max(imax, mx) }
            if mx > 4 || mn < -0.5 {
                bad += 1; if border { badBorder += 1 }
                x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
                if x >= w - 64 { colBand[(x - (w - 64)) / 8] += 1 }
                if y < 64 { rowBand[y / 8] += 1 }
            }
        } }
        print(String(format: "   moire=%.1f %dx%d  bad(>4 or <-0.5)=%d  inBorder32=%d  bbox=[x %d..%d, y %d..%d]  interior min/max=%.3g/%.3g  border min/max=%.3g/%.3g",
                     m, w, h, bad, badBorder, x0, x1, y0, y1, imin, imax, bmin, bmax))
        print("      bad per 8-col band over last 64 cols (left->right): \(colBand)   bad per 8-row band over first 64 rows (top->down): \(rowBand)")
    }
}
