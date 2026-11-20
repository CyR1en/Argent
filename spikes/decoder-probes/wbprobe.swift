// Argent spike, decoder-probes. Measurement probe, not shipped code.
//
// wbprobe measures what changing the neutral does inside Apple's RAW decoder. It
// decodes each file at Argent's pinned CIRAWFilter settings, scale 0.25, into linear
// Rec. 2020 float32 under eight neutral variants (as-shot; 5500 K with tint 0 and with
// tint 9.9; CIE D50, D55 and D65 by chromaticity; the set order swapped; highlight
// recovery off) and reports per variant the channel means, the geometric-mean
// luminance, R/G and B/G, the per-channel maxima and the filter's read-back of
// neutralChromaticity, neutralTemperature and neutralTint. It also writes a stride-3
// pixel subsample per variant to OUTDIR/dump/ for the least-squares fits that showed
// the change is a per-channel gain in camera space followed by a fixed matrix.
//
// Build: swiftc -O -framework CoreImage -framework CoreGraphics -framework Metal -framework ImageIO wbprobe.swift -o wbprobe
// Run:   mkdir -p OUTDIR/dump && ./wbprobe OUTDIR FILE...
// The report is written to OUTDIR/wbprobe2.json; the name is kept from the spike.

// wbprobe: decode Sony ARW files with Argent's pinned CIRAWFilter settings at scale 0.25 into a
// linear Rec. 2020 float32 buffer and report per white-balance variant: channel means, geometric-mean
// luminance, R/G and B/G of the frame mean, max per channel, and the filter's read-back of
// neutralChromaticity / neutralTemperature / neutralTint. Also writes a stride-3 pixel subsample
// per variant for later least-squares analysis in Python.
// Build: swiftc -O -framework CoreImage -framework CoreGraphics -framework Metal -framework ImageIO wbprobe.swift -o wbprobe
// Run:   ./wbprobe OUTDIR FILE...
import Foundation
import CoreImage
import CoreGraphics
import Metal
import ImageIO

let decodedMidTone: Float = 0.080
let filmMidGray: Float = 0.18

func gainStops(iso: Float?) -> Float {
    var lowISO: Float = 0
    if let iso, iso > 0 { lowISO = max(0, log2(100 / iso)) }
    return log2(filmMidGray / decodedMidTone) - 0 - lowISO
}

func isoSpeed(of filter: CIRAWFilter) -> Float? {
    guard let exif = filter.properties[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return nil }
    if let ratings = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber], let first = ratings.first {
        return first.floatValue
    }
    return (exif[kCGImagePropertyExifRecommendedExposureIndex as String] as? NSNumber)?.floatValue
}

func makeFilter(_ url: URL) -> CIRAWFilter? {
    guard let f = CIRAWFilter(imageURL: url) else { return nil }
    if f.supportedDecoderVersions.contains(.version8) { f.decoderVersion = .version8 }
    f.boostAmount = 0
    f.boostShadowAmount = 0
    f.isGamutMappingEnabled = false
    f.baselineExposure = 0
    f.shadowBias = 0
    f.sharpnessAmount = 0
    f.isHighlightRecoveryEnabled = true
    f.extendedDynamicRangeAmount = 1
    f.exposure = gainStops(iso: isoSpeed(of: f))
    f.scaleFactor = 0.25
    f.isDraftModeEnabled = true            // Argent: scale <= 0.5
    f.isLensCorrectionEnabled = true
    f.luminanceNoiseReductionAmount = 0.0  // Argent DecodeOptions default
    f.colorNoiseReductionAmount = 0.5
    return f
}

struct Readback {
    var chromaX: Double, chromaY: Double, temperature: Double, tint: Double
    init(_ f: CIRAWFilter) {
        chromaX = Double(f.neutralChromaticity.x); chromaY = Double(f.neutralChromaticity.y)
        temperature = Double(f.neutralTemperature); tint = Double(f.neutralTint)
    }
    var dict: [String: Double] { ["chromaX": chromaX, "chromaY": chromaY, "temperature": temperature, "tint": tint] }
}

guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write("usage: wbprobe OUTDIR FILE...\n".data(using: .utf8)!); exit(2)
}
let outDir = CommandLine.arguments[1]
let files = Array(CommandLine.arguments.dropFirst(2))

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
guard let cs = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) else { fatalError("no colour space") }
let ctx = CIContext(mtlDevice: device, options: [
    .workingColorSpace: cs,
    .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
    .cacheIntermediates: false,
    .name: "wbprobe",
])

// Variant: name, description, setup closure (receives the as-shot readback of this file).
typealias Setup = (CIRAWFilter, Readback) -> Void
let variants: [(String, String, Setup)] = [
    ("a", "as-shot, nothing touched", { _, _ in }),
    ("b", "neutralTemperature 5500, neutralTint 0", { f, _ in f.neutralTemperature = 5500; f.neutralTint = 0 }),
    ("k", "neutralChromaticity = CIE D55 (0.33243, 0.34744)", { f, _ in f.neutralChromaticity = CGPoint(x: 0.33243, y: 0.34744) }),
    ("l", "neutralChromaticity = CIE D65 (0.31272, 0.32903)", { f, _ in f.neutralChromaticity = CGPoint(x: 0.31272, y: 0.32903) }),
    ("m", "neutralTemperature 5500, neutralTint 9.9", { f, _ in f.neutralTemperature = 5500; f.neutralTint = 9.9 }),
    ("n", "neutralChromaticity = CIE D50 (0.34567, 0.35850)", { f, _ in f.neutralChromaticity = CGPoint(x: 0.34567, y: 0.35850) }),
    ("o", "tint 0 then temperature 5500 (order swapped)", { f, _ in f.neutralTint = 0; f.neutralTemperature = 5500 }),
    ("p", "neutralTemperature 5500, neutralTint 0, highlight recovery off", { f, _ in f.neutralTemperature = 5500; f.neutralTint = 0; f.isHighlightRecoveryEnabled = false }),
]

var report: [String: Any] = [:]
var fileReports: [[String: Any]] = []

for path in files {
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    print("=== \(name)")
    guard let probe = makeFilter(url) else { print("  cannot open"); continue }
    let asShot = Readback(probe)
    let iso = isoSpeed(of: probe)
    print(String(format: "  ISO %@  exposure gain %.4f stops  as-shot readback: chroma (%.6f, %.6f) temp %.2f K tint %.3f",
                 iso.map { String(Int($0)) } ?? "?", probe.exposure, asShot.chromaX, asShot.chromaY, asShot.temperature, asShot.tint))
    var fileRep: [String: Any] = ["file": name, "iso": iso ?? -1, "exposureGain": probe.exposure, "asShot": asShot.dict]
    var varReps: [[String: Any]] = []

    for (key, desc, setup) in variants {
        guard let f = makeFilter(url) else { continue }
        setup(f, asShot)
        let afterSet = Readback(f)
        guard let image = f.outputImage else { print("  \(key): no output"); continue }
        let afterOutput = Readback(f)
        let extent = image.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        var buf = [Float](repeating: 0, count: w * h * 4)
        let t0 = Date()
        buf.withUnsafeMutableBytes { p in
            ctx.render(image, toBitmap: p.baseAddress!, rowBytes: w * 16, bounds: extent, format: .RGBAf, colorSpace: cs)
        }
        let dt = Date().timeIntervalSince(t0)
        // stats
        var sR = 0.0, sG = 0.0, sB = 0.0, sLogY = 0.0
        var mR = -Double.infinity, mG = -Double.infinity, mB = -Double.infinity
        var nClip = 0, nNeg = 0
        let n = w * h
        for i in 0..<n {
            let r = Double(buf[i*4]), g = Double(buf[i*4+1]), b = Double(buf[i*4+2])
            sR += r; sG += g; sB += b
            let y = 0.2627 * r + 0.6780 * g + 0.0593 * b
            sLogY += log2(max(y, 1e-6))
            if r > mR { mR = r }; if g > mG { mG = g }; if b > mB { mB = b }
            if r >= 1 || g >= 1 || b >= 1 { nClip += 1 }
            if r < 0 || g < 0 || b < 0 { nNeg += 1 }
        }
        let dn = Double(n)
        let meanR = sR/dn, meanG = sG/dn, meanB = sB/dn
        let geoY = pow(2.0, sLogY/dn)
        print(String(format: "  %@ %-52@ w %d h %d  mean R %.5f G %.5f B %.5f  geoY %.5f  R/G %.4f B/G %.4f  max %.3f %.3f %.3f  clip %.5f  neg %.5f  [%.2fs]",
                     key, desc, w, h, meanR, meanG, meanB, geoY, meanR/meanG, meanB/meanG, mR, mG, mB, Double(nClip)/dn, Double(nNeg)/dn, dt))
        print(String(format: "     readback after set: chroma (%.6f, %.6f) temp %.2f tint %.3f | after outputImage: chroma (%.6f, %.6f) temp %.2f tint %.3f",
                     afterSet.chromaX, afterSet.chromaY, afterSet.temperature, afterSet.tint,
                     afterOutput.chromaX, afterOutput.chromaY, afterOutput.temperature, afterOutput.tint))
        // stride-3 subsample dump (RGB float32, row-major over the subsampled grid)
        var sub = [Float](); sub.reserveCapacity((w/3+1)*(h/3+1)*3)
        var y = 0
        while y < h { var x = 0; while x < w { let i = (y*w + x)*4; sub.append(buf[i]); sub.append(buf[i+1]); sub.append(buf[i+2]); x += 3 }; y += 3 }
        let dumpName = "\(name)_2\(key).f32"
        let dumpURL = URL(fileURLWithPath: outDir).appendingPathComponent("dump").appendingPathComponent(dumpName)
        sub.withUnsafeBufferPointer { p in try? Data(buffer: p).write(to: dumpURL) }
        varReps.append([
            "variant": key, "description": desc, "width": w, "height": h,
            "meanR": meanR, "meanG": meanG, "meanB": meanB, "geoY": geoY,
            "RoverG": meanR/meanG, "BoverG": meanB/meanG,
            "maxR": mR, "maxG": mG, "maxB": mB, "clipFraction": Double(nClip)/dn, "negFraction": Double(nNeg)/dn,
            "readbackAfterSet": afterSet.dict, "readbackAfterOutput": afterOutput.dict,
            "dump": dumpName, "dumpCount": sub.count/3, "subW": (w + 2)/3, "subH": (h + 2)/3,
        ])
    }
    fileRep["variants"] = varReps
    fileReports.append(fileRep)
}
report["files"] = fileReports
report["settings"] = ["decoderVersion": 8, "boostAmount": 0, "boostShadowAmount": 0, "isGamutMappingEnabled": false,
                      "baselineExposure": 0, "shadowBias": 0, "sharpnessAmount": 0, "isHighlightRecoveryEnabled": true,
                      "extendedDynamicRangeAmount": 1, "exposure": "log2(0.18/0.080) - max(0, log2(100/ISO))",
                      "scaleFactor": 0.25, "isDraftModeEnabled": true, "isLensCorrectionEnabled": true,
                      "luminanceNoiseReductionAmount": 0.0, "colorNoiseReductionAmount": 0.5,
                      "workingColorSpace": "extendedLinearITUR_2020", "workingFormat": "RGBAh", "renderFormat": "RGBAf",
                      "lumaCoefficients": "BT.2020 0.2627/0.6780/0.0593"]
let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("wbprobe2.json"))
print("wrote \(outDir)/wbprobe.json")
