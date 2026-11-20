import ArgentCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ArgentRoll

/// Each raw mode's brightness read against the frame's own camera JPEG (docs/research/camera.md,
/// section 2). The camera renders its JPEG from the sensor whatever the raw mode, at the same
/// shutter, aperture and ISO, so a decode set against its own JPEG is free of the light changing
/// between handheld frames; set against the uncompressed frame's raw-to-JPEG relation, what is
/// left is the mode's own offset in the file or the decoder. Runs only with ARGENT_MEASURE=1 and
/// the CC0 samples:
///
///     ARGENT_MEASURE=1 swift test --filter RawModeMeasureTests
@Suite(.serialized, .rawDecodes) struct RawModeMeasureTests {
    static let samples = FrameViewMeasureTests.root.appendingPathComponent("samples")
    static func sample(_ name: String) -> URL { samples.appendingPathComponent("ILCE-7M4_\(name).ARW") }
    static let names = ["DSC06673_FullFrame-Raw-Uncompressed", "DSC06674_FullFrame-LossLess-Compressed-Large",
                        "DSC06675_FullFrame-LossLess-Compressed-Medium", "DSC06676_FullFrame-LossLess-Compressed-Small",
                        "DSC06677_FullFrame-Raw-Compressed"]
    static var hasSamples: Bool { names.allSatisfy { FileManager.default.fileExists(atPath: sample($0).path) } }

    /// Flat blocks of a frame: the decode's and the JPEG's mean luminance, both linear.
    struct Blocks {
        var decoded: [Double] = []
        var jpeg: [Double] = []
    }

    static func srgbToLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// The decode at a quarter of full size with the gain taken back out, so it reads in units of
    /// a decode at baseline 0, mode correction kept or not, against the embedded full-size JPEG
    /// averaged in linear light to the decode's grid, in 8 by 8 blocks flat in both.
    static func blocks(_ url: URL, decoder: AppleRawDecoder, keepModeCorrection: Bool) throws -> (Blocks, String) {
        var options = DecodeOptions()
        options.scale = 0.25
        let frame = try decoder.decode(url, options: options)
        let pins = try #require(frame.pins)
        let gain = exp2(Double(pins.exposureGainStops + (keepModeCorrection ? 0 : pins.modeExposureStops)))
        let pixels = ExposureAnalyzer.pixels(of: frame.texture)
        let w = frame.width, h = frame.height
        // The texture runs from the picture's bottom; the JPEG from its top.
        var yd = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = ((h - 1 - y) * w + x) * 4
                yd[y * w + x] = (0.2627 * Double(pixels[i]) + 0.6780 * Double(pixels[i + 1]) + 0.0593 * Double(pixels[i + 2])) / gain
            }
        }

        let info = try ARWFrameInfo.read(from: url)
        let range = try #require(info.fullSizePreview)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.offset))
        let data = try #require(try handle.read(upToCount: range.length))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let jw = image.width, jh = image.height
        var rgba = [UInt8](repeating: 0, count: jw * jh * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: jw, height: jh, bitsPerComponent: 8, bytesPerRow: jw * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: jw, height: jh))
            return true
        }
        #expect(drawn)
        let table = (0..<256).map { srgbToLinear(Double($0) / 255) }
        // The JPEG is the camera crop; the decode may be trimmed at the right and bottom.
        let f = jw / (w + pins.trimColumns)
        var yj = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0.0
                for yy in (y * f)..<((y + 1) * f) {
                    for xx in (x * f)..<((x + 1) * f) {
                        let i = (yy * jw + xx) * 4
                        sum += 0.2126 * table[Int(rgba[i])] + 0.7152 * table[Int(rgba[i + 1])] + 0.0722 * table[Int(rgba[i + 2])]
                    }
                }
                yj[y * w + x] = sum / Double(f * f)
            }
        }

        var out = Blocks()
        let b = 8
        for by in 0..<(h / b) {
            for bx in 0..<(w / b) {
                var ld: [Double] = [], lj: [Double] = [], sd = 0.0, sj = 0.0
                for y in (by * b)..<((by + 1) * b) {
                    for x in (bx * b)..<((bx + 1) * b) {
                        ld.append(log2(max(yd[y * w + x], 1e-6))); lj.append(log2(max(yj[y * w + x], 1e-6)))
                        sd += yd[y * w + x]; sj += yj[y * w + x]
                    }
                }
                sd /= Double(b * b); sj /= Double(b * b)
                guard spread(ld) < 0.15, spread(lj) < 0.15, sd > 2e-4, sd < 0.45, sj > 1e-3, sj < 0.85 else { continue }
                out.decoded.append(sd); out.jpeg.append(sj)
            }
        }
        return (out, pins.rawMode ?? "unknown")
    }

    static func spread(_ v: [Double]) -> Double {
        let mean = v.reduce(0, +) / Double(v.count)
        return (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count)).squareRoot()
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// The reference's decode as a function of its JPEG: medians in quarter-stop bins of the JPEG.
    static func curve(_ reference: Blocks) -> [(jpeg: Double, decoded: Double)] {
        var points: [(Double, Double)] = []
        for k in 0..<36 {
            let lo = -9 + 0.25 * Double(k), hi = lo + 0.25
            let inBin = reference.jpeg.indices.filter { log2(reference.jpeg[$0]) >= lo && log2(reference.jpeg[$0]) < hi }
            guard inBin.count >= 10 else { continue }
            points.append((median(inBin.map { log2(reference.jpeg[$0]) }), median(inBin.map { log2(reference.decoded[$0]) })))
        }
        return points
    }

    static func interpolate(_ curve: [(jpeg: Double, decoded: Double)], _ x: Double) -> Double? {
        guard let first = curve.first, let last = curve.last, x >= first.jpeg, x <= last.jpeg else { return nil }
        for (a, b) in zip(curve, curve.dropFirst()) where x <= b.jpeg {
            return a.decoded + (b.decoded - a.decoded) * (x - a.jpeg) / max(b.jpeg - a.jpeg, 1e-9)
        }
        return last.decoded
    }

    /// Measured 2026-10-07 on macOS 27.0, before the table's correction and against the
    /// uncompressed frame's curve, on which that frame itself reads -0.004: lossless L -0.001,
    /// compressed -0.000, M +0.258, S +0.267 stops, so M +0.262 and S +0.271 against uncompressed;
    /// after it, M -0.002 and S -0.003 on the curve (docs/research/camera.md).
    @Test(.enabled(if: FrameViewMeasureTests.enabled && RawModeMeasureTests.hasSamples))
    func modesAgainstTheirOwnJPEG() throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        for keep in [false, true] {
            var reference: [(jpeg: Double, decoded: Double)] = []
            for name in Self.names {
                let (blocks, mode) = try Self.blocks(Self.sample(name), decoder: decoder, keepModeCorrection: keep)
                if reference.isEmpty { reference = Self.curve(blocks) }
                let offsets = blocks.jpeg.indices.compactMap { i in
                    Self.interpolate(reference, log2(blocks.jpeg[i])).map { log2(blocks.decoded[i]) - $0 }
                }
                let offset = Self.median(offsets)
                print(String(format: "MEASURE raw mode %@ %@ against its own JPEG: %+.3f stops (%d blocks)",
                             mode, keep ? "with its correction" : "before correction", offset, offsets.count))
                if keep { #expect(abs(offset) < 0.05, "\(mode) still \(offset) stops off after its correction") }
            }
        }
    }
}
