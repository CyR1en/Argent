// Argent spike, decoder-probes. Measurement probe, not shipped code.
//
// isoseries measures Apple's RAW decoder along an a7 IV ISO series. The meta mode
// prints per-file EXIF, the decoder's per-file defaults (baselineExposure, both noise
// reduction amounts, shadow bias, neutral) and the mean and geometric-mean linear green
// at the pinned settings, which is how ISO 50 was shown to carry ISO 100's raw gain.
// The nr and nrsweep modes decode at full scale with luminance noise reduction at
// several amounts and report how much of the 3 by 3 and 5 by 5 high-pass luma noise
// each amount removes on flat 64 by 64 blocks. The preview mode writes a small JPEG
// for locating patches by eye.
//
// Build: swiftc -O -framework CoreImage -framework CoreGraphics -framework Metal -framework ImageIO isoseries.swift -o isoseries
// Run:   ./isoseries meta|nr|nrsweep|preview FILE...

// Spike low-iso-nr: measure Apple's CIRAWFilter on a real a7 IV ISO series.
// Usage:
//   isoseries meta FILE...            per-file EXIF, CIRAWFilter defaults, mean/geomean linear G at pinned settings (scale 0.25)
//   isoseries nr FILE...              full-scale decode at lumNR 0 and 1; lowest-variance 64x64 luma block; high-pass std at both
//   isoseries nrsweep FILE            as nr, but lumNR 0, 0.25, 0.5, default, 0.75, 1.0 on the same block
// Pinned settings (Argent, AppleRawDecoder.swift): decoderVersion 8, boost 0, boostShadow 0, gamutMapping off,
// baselineExposure 0, shadowBias 0, sharpness 0, highlight recovery on, EDR 1, exposure 0. Lens correction and
// draft mode are left at Apple's defaults (lens correction on, draft off). colorNoiseReductionAmount 0.5 unless stated.
import Foundation
import CoreImage
import ImageIO

let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let ctx = CIContext(options: [.workingColorSpace: lin, .outputColorSpace: lin, .cacheIntermediates: false])

struct Exif {
    var iso: Double = .nan, exposure: Double = .nan, fnumber: Double = .nan, bias: Double = .nan
    var dto = "", subsec = "", model = "", software = ""
}

func readExif(_ url: URL) -> Exif {
    var e = Exif()
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return e }
    if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
        e.model = tiff[kCGImagePropertyTIFFModel as String] as? String ?? ""
        e.software = tiff[kCGImagePropertyTIFFSoftware as String] as? String ?? ""
    }
    if let ex = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
        if let r = ex[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber], let f = r.first { e.iso = f.doubleValue }
        e.exposure = (ex[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? .nan
        e.fnumber = (ex[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue ?? .nan
        e.bias = (ex[kCGImagePropertyExifExposureBiasValue as String] as? NSNumber)?.doubleValue ?? .nan
        e.dto = ex[kCGImagePropertyExifDateTimeOriginal as String] as? String ?? ""
        e.subsec = ex[kCGImagePropertyExifSubsecTimeOriginal as String] as? String ?? ""
    }
    return e
}

func pinnedFilter(_ url: URL, scale: Float, lum: Float?, col: Float?) -> CIRAWFilter {
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
    if let lum { f.luminanceNoiseReductionAmount = lum }
    if let col { f.colorNoiseReductionAmount = col }
    return f
}

/// Render the whole output image to an RGBA half-float buffer; returns (pixels as Float, width, height).
func render(_ f: CIRAWFilter) -> ([Float], Int, Int) {
    let img = f.outputImage!
    let e = img.extent.integral
    let w = Int(e.width), h = Int(e.height)
    var buf = [Float16](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { p in
        ctx.render(img, toBitmap: p.baseAddress!, rowBytes: w * 8, bounds: e, format: .RGBAh, colorSpace: lin)
    }
    var out = [Float](repeating: 0, count: w * h * 4)
    for i in 0..<(w * h * 4) { out[i] = Float(buf[i]) }
    return (out, w, h)
}

struct GStats { var mean: Double; var geomean: Double; var nonpos: Int; var clipped: Double; var n: Int }

func gStats(_ px: [Float], w: Int, h: Int, rect: (x0: Int, y0: Int, x1: Int, y1: Int)) -> GStats {
    var s = 0.0, sl = 0.0, n = 0, nonpos = 0, clip = 0
    for y in rect.y0..<rect.y1 { for x in rect.x0..<rect.x1 {
        let i = (y * w + x) * 4
        let g = Double(px[i + 1])
        s += g; n += 1
        if g > 0 { sl += log(g) } else { nonpos += 1 }
        if max(px[i], px[i + 1], px[i + 2]) >= 0.999 { clip += 1 }
    } }
    return GStats(mean: s / Double(n), geomean: exp(sl / Double(n - nonpos)), nonpos: nonpos, clipped: Double(clip) / Double(n), n: n)
}

func luma(_ px: [Float], w: Int, h: Int) -> [Float] {
    var y = [Float](repeating: 0, count: w * h)
    for i in 0..<(w * h) { y[i] = 0.2126 * px[i * 4] + 0.7152 * px[i * 4 + 1] + 0.0722 * px[i * 4 + 2] }
    return y
}

/// Std of (pixel - box mean of radius r) over the block [bx, bx+64) x [by, by+64), neighbours taken from the full image.
func hpStd(_ a: [Float], w: Int, h: Int, bx: Int, by: Int, size: Int, r: Int) -> Double {
    var s = 0.0, s2 = 0.0, n = 0
    let k = Float((2 * r + 1) * (2 * r + 1))
    for y in max(r, by)..<min(h - r, by + size) { for x in max(r, bx)..<min(w - r, bx + size) {
        var m: Float = 0
        for dy in -r...r { for dx in -r...r { m += a[(y + dy) * w + (x + dx)] } }
        let d = Double(a[y * w + x] - m / k)
        s += d; s2 += d * d; n += 1
    } }
    let mean = s / Double(n)
    return (s2 / Double(n) - mean * mean).squareRoot()
}

struct Block { var bx: Int; var by: Int; var mean: Double; var variance: Double; var maxv: Float }

/// Non-overlapping 64x64 blocks with their luma mean, variance and max channel.
func blocks(_ y: [Float], px: [Float], w: Int, h: Int, size: Int) -> [Block] {
    var out: [Block] = []
    var by = 0
    while by + size <= h {
        var bx = 0
        while bx + size <= w {
            var s = 0.0, s2 = 0.0; var mx: Float = 0
            for yy in by..<(by + size) { for xx in bx..<(bx + size) {
                let v = Double(y[yy * w + xx]); s += v; s2 += v * v
                let i = (yy * w + xx) * 4
                mx = max(mx, px[i], px[i + 1], px[i + 2])
            } }
            let n = Double(size * size)
            let m = s / n
            out.append(Block(bx: bx, by: by, mean: m, variance: s2 / n - m * m, maxv: mx))
            bx += size
        }
        by += size
    }
    return out
}

func fmt(_ v: Double, _ d: Int = 5) -> String { v.isNaN ? "nan" : String(format: "%.\(d)f", v) }

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: isoseries meta|nr|nrsweep FILE..."); exit(1) }
let mode = args[1]
let files = args[2...].map { URL(fileURLWithPath: $0) }

switch mode {
case "meta":
    print(["file", "model", "software", "iso", "exposure_s", "fnumber", "ev_bias", "dto", "subsec", "iso_t_over_N2",
           "def_decoder", "def_baselineExposure", "def_lumNR", "def_colNR", "def_shadowBias", "def_neutralTemp", "def_neutralTint",
           "size", "meanG_full", "geomeanG_full", "clip_full", "meanG_centre", "geomeanG_centre", "clip_centre", "nonposG_full",
           "meanG_full_defBaseline", "meanG_centre_defBaseline"].joined(separator: "\t"))
    for url in files {
        let e = readExif(url)
        let d = CIRAWFilter(imageURL: url)!
        let defVer = d.decoderVersion.rawValue
        let defBE = d.baselineExposure, defLum = d.luminanceNoiseReductionAmount, defCol = d.colorNoiseReductionAmount
        let defSB = d.shadowBias, defT = d.neutralTemperature, defTint = d.neutralTint
        let f = pinnedFilter(url, scale: 0.25, lum: nil, col: nil)   // NR amounts at Apple's per-file defaults
        let (px, w, h) = render(f)
        let full = gStats(px, w: w, h: h, rect: (0, 0, w, h))
        let cx0 = Int(Double(w) * 0.4), cx1 = Int(Double(w) * 0.6), cy0 = Int(Double(h) * 0.4), cy1 = Int(Double(h) * 0.6)
        let centre = gStats(px, w: w, h: h, rect: (cx0, cy0, cx1, cy1))
        // same decode with Apple's default baselineExposure, to see what the default does per ISO
        let g = pinnedFilter(url, scale: 0.25, lum: nil, col: nil); g.baselineExposure = defBE
        let (px2, _, _) = render(g)
        let full2 = gStats(px2, w: w, h: h, rect: (0, 0, w, h))
        let centre2 = gStats(px2, w: w, h: h, rect: (cx0, cy0, cx1, cy1))
        let exposureIndex = e.iso * e.exposure / (e.fnumber * e.fnumber)
        print([url.lastPathComponent, e.model, e.software, fmt(e.iso, 0), fmt(e.exposure, 6), fmt(e.fnumber, 1), fmt(e.bias, 2), e.dto, e.subsec, fmt(exposureIndex, 6),
               defVer, fmt(Double(defBE), 3), fmt(Double(defLum), 4), fmt(Double(defCol), 3), fmt(Double(defSB), 3), fmt(Double(defT), 0), fmt(Double(defTint), 2),
               "\(w)x\(h)", fmt(full.mean), fmt(full.geomean), fmt(full.clipped), fmt(centre.mean), fmt(centre.geomean), fmt(centre.clipped), "\(full.nonpos)",
               fmt(full2.mean), fmt(centre2.mean)].joined(separator: "\t"))
        fflush(stdout)
    }
case "nr", "nrsweep":
    let size = 64
    print(["file", "iso", "size", "def_lumNR", "colNR", "block", "block_mean", "block_std0", "lumNR", "hp3_std", "hp3_removed_pct", "hp5_std", "hp5_removed_pct", "std_block", "secs"].joined(separator: "\t"))
    for url in files {
        let e = readExif(url)
        let d = CIRAWFilter(imageURL: url)!
        let defLum = d.luminanceNoiseReductionAmount
        let col: Float = 0.5
        let t0 = Date()
        let f0 = pinnedFilter(url, scale: 1.0, lum: 0, col: col)
        let (px0, w, h) = render(f0)
        let y0 = luma(px0, w: w, h: h)
        let secs0 = Date().timeIntervalSince(t0)
        let bl = blocks(y0, px: px0, w: w, h: h, size: size)
        // candidates: not clipped, not black, away from the frame edge (lens-corrected borders)
        let valid = bl.filter { $0.maxv < 0.98 && $0.mean > 0.005 && $0.bx >= size && $0.by >= size && $0.bx + 2 * size <= w && $0.by + 2 * size <= h }
        let lowest = valid.min { $0.variance < $1.variance }!
        var picks: [(String, Block)] = [("lowest", lowest)]
        // 'flat': among mid-tone blocks whose total std is close to their 5x5 high-pass std (no gradient or texture
        // at low frequencies), the one with the lowest high-pass variance. Texture-free patches score here.
        var flatBest: (Block, Double)? = nil
        for b in valid where b.mean >= 0.02 && b.mean < 0.6 {
            let hp = hpStd(y0, w: w, h: h, bx: b.bx, by: b.by, size: size, r: 2)
            if b.variance.squareRoot() < 1.6 * hp {
                if flatBest == nil || hp < flatBest!.1 { flatBest = (b, hp) }
            }
        }
        if let fb = flatBest { picks.append(("flat", fb.0)) }
        if let env = ProcessInfo.processInfo.environment["BLOCKS"] {
            for spec in env.split(separator: ";") {
                let xy = spec.split(separator: ",").compactMap { Int($0) }
                if xy.count == 2, let b = bl.first(where: { $0.bx == xy[0] && $0.by == xy[1] }) { picks.append(("fixed", b)) }
            }
        }
        for (lo, hi) in [(0.005, 0.02), (0.02, 0.06), (0.06, 0.2), (0.2, 0.6)] {
            if let b = valid.filter({ $0.mean >= lo && $0.mean < hi }).min(by: { $0.variance < $1.variance }) {
                picks.append((String(format: "band[%.3f,%.2f)", lo, hi), b))
            }
        }
        let amounts: [Float] = mode == "nr" ? [1.0] : [0.25, 0.5, defLum, 0.75, 1.0]
        var renders: [(Float, [Float], Double)] = []
        for a in amounts {
            let t1 = Date()
            let f1 = pinnedFilter(url, scale: 1.0, lum: a, col: col)
            let (px1, w1, h1) = render(f1)
            precondition(w1 == w && h1 == h)
            renders.append((a, luma(px1, w: w, h: h), Date().timeIntervalSince(t1)))
        }
        for (label, b) in picks {
            let hp3_0 = hpStd(y0, w: w, h: h, bx: b.bx, by: b.by, size: size, r: 1)
            let hp5_0 = hpStd(y0, w: w, h: h, bx: b.bx, by: b.by, size: size, r: 2)
            let std0 = b.variance.squareRoot()
            print([url.lastPathComponent, fmt(e.iso, 0), "\(w)x\(h)", fmt(Double(defLum), 4), fmt(Double(col), 2), "\(label)@(\(b.bx),\(b.by))", fmt(b.mean), fmt(std0),
                   "0", fmt(hp3_0, 6), "0.0", fmt(hp5_0, 6), "0.0", fmt(std0, 6), fmt(secs0, 2)].joined(separator: "\t"))
            for (a, y1, secs) in renders {
                let hp3 = hpStd(y1, w: w, h: h, bx: b.bx, by: b.by, size: size, r: 1)
                let hp5 = hpStd(y1, w: w, h: h, bx: b.bx, by: b.by, size: size, r: 2)
                // whole-block std at this amount
                var s = 0.0, s2 = 0.0
                for yy in b.by..<(b.by + size) { for xx in b.bx..<(b.bx + size) { let v = Double(y1[yy * w + xx]); s += v; s2 += v * v } }
                let n = Double(size * size); let m = s / n
                let std1 = (s2 / n - m * m).squareRoot()
                print([url.lastPathComponent, fmt(e.iso, 0), "\(w)x\(h)", fmt(Double(defLum), 4), fmt(Double(col), 2), "\(label)@(\(b.bx),\(b.by))", fmt(b.mean), fmt(std0),
                       fmt(Double(a), 4), fmt(hp3, 6), fmt(100 * (1 - hp3 / hp3_0), 1), fmt(hp5, 6), fmt(100 * (1 - hp5 / hp5_0), 1), fmt(std1, 6), fmt(secs, 2)].joined(separator: "\t"))
            }
        }
        fflush(stdout)
    }
case "preview":
    // Gamma-encoded JPEG at scale 0.125 (876 px wide for a 7008 px frame), for locating patches by eye.
    for url in files {
        let f = pinnedFilter(url, scale: 0.125, lum: nil, col: nil)
        let img = f.outputImage!
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let gain = (ProcessInfo.processInfo.environment["GAIN"]).flatMap { Double($0) } ?? 2.25
        let bright = img.applyingFilter("CIExposureAdjust", parameters: ["inputEV": log2(gain)])
        let out = URL(fileURLWithPath: "preview_" + url.deletingPathExtension().lastPathComponent + ".jpg")
        try! ctx.writeJPEGRepresentation(of: bright, to: out, colorSpace: srgb, options: [:])
        print("wrote \(out.path) extent \(img.extent.integral)")
    }
default:
    print("unknown mode \(mode)"); exit(1)
}
