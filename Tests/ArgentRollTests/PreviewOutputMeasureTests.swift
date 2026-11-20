import ArgentCore
import CoreImage
import Foundation
import ImageIO
import Metal
import Testing
@testable import ArgentRoll

/// M3's preview/output checks (docs/manual-development-validation.md, "Preview, output and develop
/// budget, 2026-10-15"): pictures the running app wrote through its debug hook, compared under the
/// tolerances declared there before they were made. Runs only with ARGENT_MEASURE=1 and
/// PREVIEW_OUTPUT naming the folder of pictures:
///
///     ARGENT_MEASURE=1 PREVIEW_OUTPUT=/path swift test -c release -Xswiftc -enable-testing --filter PreviewOutputMeasureTests
///
/// For each frame NAME the folder holds NAME-on.tif and NAME-off.tif, full-size 16-bit Display P3
/// develops with grain Natural and Off; NAME-full.png, the frame view's path asked for the develop's
/// long side with grain Natural; and NAME-on.png and NAME-off.png, the frame view's picture at the
/// window's pixels. Side-by-side crops for looking at go to NAME-crop-N.png in the same folder. The hook
/// writes previews in the output colour space, so send it `space displayP3` before writing these.
///
/// `matchingSize` and `normalSize` hold the declared rules, and on the 2026-10-16 pictures they fail:
/// the matching-size rule sat below 8-bit rounding, and Apple-decoded frames exceed the normal-size
/// ones. The diagnostics after them (`quantization`, `registration`, `registrationExhaustive`,
/// `differenceMap`) were added to explain those results; the validation doc records both.
///
/// "Apple-decoded previews, 2026-10-16" uses two folders of the same develops: one with the frame
/// view's refined pictures, held to `normalSize`, and one with its scaled decode's pictures, taken
/// with refinement off, held to `textureAware` (route (a)), declared there before measuring.
@Suite(.serialized) struct PreviewOutputMeasureTests {
    typealias A = AutoMeasureTests

    static let folder = ProcessInfo.processInfo.environment["PREVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
    static var enabled: Bool { FrameViewMeasureTests.enabled && folder != nil }

    static var names: [String] {
        guard let folder else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { $0.hasSuffix("-on.tif") }.map { String($0.dropLast("-on.tif".count)) }.sorted()
    }

    /// A picture file read through its profile into linear Rec. 2020, the app's working space.
    static func linear(_ url: URL, gpu: GPU) throws -> PooledTexture {
        guard let image = CIImage(contentsOf: url) else { throw CocoaError(.fileReadCorruptFile) }
        let texture = try gpu.texturePool.acquire(width: Int(image.extent.width), height: Int(image.extent.height),
                                                  usage: [.shaderRead, .shaderWrite, .renderTarget])
        guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw CocoaError(.featureUnsupported) }
        gpu.ciContext.render(image, to: texture.texture, commandBuffer: commandBuffer, bounds: image.extent,
                             colorSpace: gpu.workingColorSpace)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }

    /// A picture as RGB rows, `width` by `height`, cropped from the texture's first rows and columns.
    struct Picture {
        var rgb: [SIMD3<Float>]
        let width: Int, height: Int

        init(_ texture: MTLTexture, width: Int, height: Int) {
            let pixels = ExposureAnalyzer.pixels(of: texture)
            self.width = width
            self.height = height
            rgb = [SIMD3<Float>](repeating: .zero, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    let i = 4 * (y * texture.width + x)
                    rgb[y * width + x] = SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
                }
            }
        }

        /// Each channel blurred by a sampled Gaussian of `sigma` pixels, edges repeated.
        func blurred(sigma: Float) -> Picture {
            let radius = Int((3 * sigma).rounded(.up))
            let raw = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
            let total = raw.reduce(0, +)
            let weights = raw.map { $0 / total }
            let (w, h, source) = (width, height, rgb)
            let across = Self.rows(h, width: w) { y, x in
                var sum = SIMD3<Float>.zero
                for k in -radius...radius { sum += weights[k + radius] * source[y * w + min(max(x + k, 0), w - 1)] }
                return sum
            }
            var picture = self
            picture.rgb = Self.rows(h, width: w) { y, x in
                var sum = SIMD3<Float>.zero
                for k in -radius...radius { sum += weights[k + radius] * across[min(max(y + k, 0), h - 1) * w + x] }
                return sum
            }
            return picture
        }

        /// `height` rows of `width` pixels from `pixel(y, x)`, the rows in parallel.
        static func rows(_ height: Int, width: Int, _ pixel: @Sendable (Int, Int) -> SIMD3<Float>) -> [SIMD3<Float>] {
            var out = [SIMD3<Float>](repeating: .zero, count: width * height)
            out.withUnsafeMutableBufferPointer { buffer in
                let target = UncheckedBox(buffer.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for x in 0..<width { target.value[y * width + x] = pixel(y, x) }
                }
            }
            return out
        }

        /// L* of each pixel, from Rec. 2020 luminance with white at 1.
        var lightness: [Float] {
            rgb.map { p in
                let y = 0.2627 * p.x + 0.6780 * p.y + 0.0593 * p.z
                return y > 0.008856 ? 116 * cbrt(y) - 16 : 903.3 * y
            }
        }
    }

    struct Differences {
        var mean = 0.0, p95 = 0.0, max = 0.0, l = 0.0, a = 0.0, b = 0.0
        var text: String {
            String(format: "dE00 mean %.3f p95 %.3f max %.3f; mean dL* %+.3f da* %+.3f db* %+.3f", mean, p95, max, l, a, b)
        }
    }

    /// CIEDE2000 pixel by pixel, `border` pixels in from each edge, with the mean signed
    /// L*, a* and b* differences of `p` from `q`.
    static func differences(_ p: Picture, _ q: Picture, border: Int) -> Differences {
        let w = p.width, rows = Array(border..<(p.height - border))
        var parts = [(values: [Float], sums: SIMD3<Double>)](repeating: ([], .zero), count: rows.count)
        parts.withUnsafeMutableBufferPointer { buffer in
            let target = UncheckedBox(buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: rows.count) { index in
                let y = rows[index]
                var values: [Float] = [], sums = SIMD3<Double>.zero
                values.reserveCapacity(w - 2 * border)
                for x in border..<(w - border) {
                    let i = y * w + x
                    let lp = Colour.lab(SIMD3<Double>(p.rgb[i])), lq = Colour.lab(SIMD3<Double>(q.rgb[i]))
                    values.append(Float(Colour.deltaE2000(lp, lq)))
                    sums += lp - lq
                }
                target.value[index] = (values, sums)
            }
        }
        var all = parts.flatMap(\.values)
        let n = Double(all.count)
        let sums = parts.reduce(SIMD3<Double>.zero) { $0 + $1.sums }
        all.sort()
        return Differences(mean: all.reduce(0) { $0 + Double($1) } / n, p95: Double(all[Int(0.95 * Double(all.count - 1))]),
                           max: Double(all.last ?? 0), l: sums.x / n, a: sums.y / n, b: sums.z / n)
    }

    /// The RMS of `p` minus `q` over the pixels `border` in from each edge.
    static func rms(_ p: [Float], _ q: [Float], width: Int, height: Int, border: Int) -> Double {
        var squares = 0.0, n = 0
        for y in border..<(height - border) {
            for x in border..<(width - border) {
                let d = Double(p[y * width + x] - q[y * width + x])
                squares += d * d
                n += 1
            }
        }
        return (squares / Double(n)).squareRoot()
    }

    /// One just-noticeable difference in graininess as an RMS ratio: four Print Grain Index units at
    /// 10^(ΔPGI/100.8) ("Grain tolerance, 2026-10-16").
    static let grainJND = pow(10, 4.0 / 100.8)

    /// "Grain tolerance, 2026-10-16", as amended before V1 and V2: the standard deviation of `on` minus `off`
    /// about its mean at each lightness of `off`, in bins of 1 L* holding at least 100 pixels, over the
    /// pixels `border` in from each edge; and the mean of `on` minus `off` over them all.
    static func grainSpread(_ on: [Float], _ off: [Float], width: Int, height: Int, border: Int) -> (sd: Double, mean: Double) {
        var bins = [(n: Int, sum: Double, squares: Double)](repeating: (0, 0, 0), count: 101)
        var total = 0.0, count = 0
        for y in border..<(height - border) {
            for x in border..<(width - border) {
                let i = y * width + x, d = Double(on[i] - off[i])
                let bin = min(100, max(0, Int(off[i].rounded(.down))))
                bins[bin].n += 1
                bins[bin].sum += d
                bins[bin].squares += d * d
                total += d
                count += 1
            }
        }
        var squares = 0.0, n = 0
        for bin in bins where bin.n >= 100 {
            squares += bin.squares - bin.sum * bin.sum / Double(bin.n)
            n += bin.n
        }
        return ((squares / Double(n)).squareRoot(), total / Double(count))
    }

    /// A picture in linear light rounded to 8-bit Display P3 as the frame view rounds its own
    /// (`FilmPreviews.displayImage`), read back through its profile into linear Rec. 2020, as a picture
    /// file is read.
    static func roundedAsFrameView(_ texture: MTLTexture, gpu: GPU) throws -> PooledTexture {
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: gpu.workingColorSpace]),
              let space = CGColorSpace(name: CGColorSpace.displayP3),
              let picture = gpu.ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space, deferred: false)
        else { throw CocoaError(.featureUnsupported) }
        let rounded = CIImage(cgImage: picture)
        let out = try gpu.texturePool.acquire(width: texture.width, height: texture.height, usage: [.shaderRead, .shaderWrite, .renderTarget])
        guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw CocoaError(.featureUnsupported) }
        gpu.ciContext.render(rounded, to: out.texture, commandBuffer: commandBuffer, bounds: rounded.extent, colorSpace: gpu.workingColorSpace)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return out
    }

    /// The preview and the develop side by side at the preview's pixels, 8-bit Display P3.
    static func writeCrops(_ preview: MTLTexture, _ develop: MTLTexture, gpu: GPU, name: String, in folder: URL) {
        let options: [CIImageOption: Any] = [.colorSpace: gpu.workingColorSpace]
        guard let p = CIImage(mtlTexture: preview, options: options), let d = CIImage(mtlTexture: develop, options: options),
              let space = CGColorSpace(name: CGColorSpace.displayP3) else { return }
        let w = CGFloat(min(preview.width, develop.width)), h = CGFloat(min(preview.height, develop.height))
        let size = CGSize(width: min(480, w / 3), height: min(320, h / 3))
        for (index, centre) in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.25, y: 0.7), CGPoint(x: 0.72, y: 0.3)].enumerated() {
            let rect = CGRect(x: (centre.x * w - size.width / 2).rounded(), y: (centre.y * h - size.height / 2).rounded(),
                              width: size.width, height: size.height)
            let left = p.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            let right = d.cropped(to: rect).transformed(by: CGAffineTransform(translationX: size.width + 8 - rect.minX, y: -rect.minY))
            let canvas = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
                .cropped(to: CGRect(x: 0, y: 0, width: 2 * size.width + 8, height: size.height))
            let image = right.composited(over: left.composited(over: canvas))
            let url = folder.appendingPathComponent("\(name)-crop-\(index).png")
            guard let cg = gpu.ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, cg, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    /// The frame view's own path at the develop's size against the develop: the same decode size,
    /// grain pitch and seed, so only the picture's 8 bits and Apple's tiled decode may differ.
    /// Declared pass: CIEDE2000 mean at most 0.10 and maximum at most 1.0.
    @Test(.enabled(if: enabled))
    func matchingSize() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let folder = try #require(Self.folder)
        #expect(!Self.names.isEmpty)
        for name in Self.names {
            let develop = try Self.linear(folder.appendingPathComponent("\(name)-on.tif"), gpu: gpu)
            let preview = try Self.linear(folder.appendingPathComponent("\(name)-full.png"), gpu: gpu)
            try #require(preview.width == develop.width && preview.height == develop.height,
                         "\(name): preview \(preview.width)x\(preview.height), develop \(develop.width)x\(develop.height)")
            let d = Self.differences(Picture(preview.texture, width: preview.width, height: preview.height),
                                     Picture(develop.texture, width: develop.width, height: develop.height), border: 0)
            print("MEASURE matching size \(name) \(develop.width)x\(develop.height): \(d.text)")
            #expect(d.mean <= 0.10 && d.max <= 1.0, "\(name)")
        }
    }

    /// The frame view's picture at the window's pixels against the full-size develop area-resized
    /// to them in linear light, with grain Off and Natural. Declared pass: after a σ = 2 px blur,
    /// CIEDE2000 mean at most 1.0 and 95th percentile at most 2.0; grain Off, finest band 0.85 to
    /// 1.10 and the others 0.95 to 1.05. The grain rule is "Grain tolerance, 2026-10-16"'s, as amended
    /// before it was measured: the grain's standard deviation about its mean at each lightness, preview
    /// over the develop rounded to the preview's 8 bits, within one JND (0.913 to 1.096). It replaced
    /// the RMS, preview over the unrounded develop, within 0.80 to 1.25, which is still printed.
    @Test(.enabled(if: enabled))
    func normalSize() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let resize = try AreaResize(gpu: gpu)
        let folder = try #require(Self.folder)
        #expect(!Self.names.isEmpty)
        for name in Self.names {
            var lightness: [String: (preview: [Float], develop: [Float], rounded: [Float])] = [:]
            var size = (width: 0, height: 0)
            for grain in ["off", "on"] {
                let preview = try Self.linear(folder.appendingPathComponent("\(name)-\(grain).png"), gpu: gpu)
                let full = try Self.linear(folder.appendingPathComponent("\(name)-\(grain).tif"), gpu: gpu)
                let scale = Double(max(preview.width, preview.height)) / Double(max(full.width, full.height))
                let develop = try resize.resized(full.texture, scale: scale)
                size = (min(preview.width, develop.width), min(preview.height, develop.height))
                let p = Picture(preview.texture, width: size.width, height: size.height)
                let d = Picture(develop.texture, width: size.width, height: size.height)
                let blurred = Self.differences(p.blurred(sigma: 2), d.blurred(sigma: 2), border: 8)
                let sharp = Self.differences(p, d, border: 8)
                let lp = p.lightness, ld = d.lightness
                let bands = zip(A.bands(lp, width: size.width), A.bands(ld, width: size.width)).map { $0 / $1 }
                print("MEASURE normal size \(name) grain \(grain), preview \(preview.width)x\(preview.height), develop \(full.width)x\(full.height) resized to \(develop.width)x\(develop.height)")
                print("MEASURE   blurred σ 2 px: \(blurred.text)")
                print("MEASURE   unblurred: \(sharp.text)")
                print("MEASURE   bands preview/develop " + bands.map { String(format: "%.3f", $0) }.joined(separator: ", "))
                #expect(blurred.mean <= 1.0 && blurred.p95 <= 2.0, "\(name) grain \(grain)")
                if grain == "off" {
                    #expect(bands[0] >= 0.85 && bands[0] <= 1.10, "\(name) finest band")
                    #expect(bands[1...].allSatisfy { $0 >= 0.95 && $0 <= 1.05 }, "\(name) middle and coarse bands")
                } else {
                    Self.writeCrops(preview.texture, develop.texture, gpu: gpu, name: name, in: folder)
                }
                let rounded = try Self.roundedAsFrameView(develop.texture, gpu: gpu)
                lightness[grain] = (lp, ld, Picture(rounded.texture, width: size.width, height: size.height).lightness)
            }
            guard let on = lightness["on"], let off = lightness["off"] else { continue }
            let grainPreview = Self.rms(on.preview, off.preview, width: size.width, height: size.height, border: 8)
            let grainDevelop = Self.rms(on.develop, off.develop, width: size.width, height: size.height, border: 8)
            let grainBands = zip(A.bands(zip(on.preview, off.preview).map(-), width: size.width),
                                 A.bands(zip(on.develop, off.develop).map(-), width: size.width)).map { $0 / $1 }
            print(String(format: "MEASURE   grain RMS L* preview %.3f develop %.3f ratio %.3f; grain bands preview/develop %@", grainPreview,
                         grainDevelop, grainPreview / grainDevelop, grainBands.map { String(format: "%.3f", $0) }.joined(separator: ", ")))
            let (w, h) = (size.width, size.height)
            let spread = Self.grainSpread(on.preview, off.preview, width: w, height: h, border: 8)
            let spreadDevelop = Self.grainSpread(on.develop, off.develop, width: w, height: h, border: 8)
            let spreadRounded = Self.grainSpread(on.rounded, off.rounded, width: w, height: h, border: 8)
            let judged = spread.sd / spreadRounded.sd, jnd = Self.grainJND, half = pow(10, 2.0 / 100.8)
            print(String(format: "MEASURE   grain SD about the mean by lightness: preview %.3f, develop rounded to 8 bits %.3f, unrounded %.3f; "
                         + "ratio %.3f (one JND %@, two units %@), against the unrounded develop %.3f",
                         spread.sd, spreadRounded.sd, spreadDevelop.sd, judged, judged >= 1 / jnd && judged <= jnd ? "within" : "outside",
                         judged >= 1 / half && judged <= half ? "within" : "outside", spread.sd / spreadDevelop.sd))
            let ratio = grainPreview / grainDevelop
            print(String(format: "MEASURE   grain means L* preview %+.3f develop %+.3f; RMS ratio %.3f: 0.80 to 1.25 %@, one JND %@", spread.mean,
                         spreadDevelop.mean, ratio, ratio >= 0.80 && ratio <= 1.25 ? "within" : "outside",
                         ratio >= 1 / jnd && ratio <= jnd ? "within" : "outside"))
            #expect(judged >= 1 / jnd && judged <= jnd, "\(name) grain")
        }
    }

    /// "Apple-decoded previews, 2026-10-16", route (a), declared before measuring: the picture against
    /// the resized develop, grain Off, on 32 by 32-pixel block means in linear light, whole blocks
    /// inside the 8-pixel border, so the decoders' pixel texture averages out. Pass: CIEDE2000 between
    /// the block means, mean at most 1.0 and p95 at most 2.0; and in every tenth of L* (the develop's
    /// block's) holding at least 1 percent of the blocks, the mean signed ΔL*, Δa* and Δb* within
    /// ±1.0. The tone curve is read on the blocks too, so a pixel's own texture cannot choose its tenth.
    @Test(.enabled(if: enabled))
    func textureAware() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let resize = try AreaResize(gpu: gpu)
        let folder = try #require(Self.folder)
        let side = 32, border = 8
        for name in Self.names {
            let preview = try Self.linear(folder.appendingPathComponent("\(name)-off.png"), gpu: gpu)
            let full = try Self.linear(folder.appendingPathComponent("\(name)-off.tif"), gpu: gpu)
            let develop = try resize.resized(full.texture, scale: Double(max(preview.width, preview.height)) / Double(max(full.width, full.height)))
            let w = min(preview.width, develop.width), h = min(preview.height, develop.height)
            let p = Picture(preview.texture, width: w, height: h), d = Picture(develop.texture, width: w, height: h)
            var blocks: [Double] = []
            var tenths = [(count: Int, sum: SIMD3<Double>)](repeating: (0, .zero), count: 10)
            for y0 in stride(from: border, through: h - border - side, by: side) {
                for x0 in stride(from: border, through: w - border - side, by: side) {
                    var sp = SIMD3<Double>.zero, sd = SIMD3<Double>.zero
                    for y in y0..<(y0 + side) {
                        for x in x0..<(x0 + side) {
                            sp += SIMD3<Double>(p.rgb[y * w + x])
                            sd += SIMD3<Double>(d.rgb[y * w + x])
                        }
                    }
                    let n = Double(side * side)
                    let lp = Colour.lab(sp / n), ld = Colour.lab(sd / n)
                    blocks.append(Colour.deltaE2000(lp, ld))
                    let tenth = min(9, max(0, Int(ld.x / 10)))
                    tenths[tenth].count += 1
                    tenths[tenth].sum += lp - ld
                }
            }
            blocks.sort()
            let mean = blocks.reduce(0, +) / Double(blocks.count), p95 = blocks[Int(0.95 * Double(blocks.count - 1))]
            let counted = tenths.enumerated().filter { 100 * $0.element.count >= blocks.count }
            let shifts = counted.map { (tenth: $0.offset, shift: $0.element.sum / Double($0.element.count)) }
            let worst = shifts.map { max(abs($0.shift.x), abs($0.shift.y), abs($0.shift.z)) }.max() ?? 0
            print(String(format: "MEASURE texture-aware %@, %d blocks of %d px: dE00 of block means mean %.3f p95 %.3f max %.3f; worst tenth shift %.3f",
                         name, blocks.count, side, mean, p95, blocks.last ?? 0, worst))
            print("MEASURE   by the develop's L*: " + shifts.map {
                String(format: "%d-%d: dL* %+.2f da* %+.2f db* %+.2f", 10 * $0.tenth, 10 * $0.tenth + 10, $0.shift.x, $0.shift.y, $0.shift.z)
            }.joined(separator: "; "))
            #expect(mean <= 1.0 && p95 <= 2.0, "\(name) block means")
            #expect(worst <= 1.0, "\(name) tone curve")
        }
    }

    // Diagnostics added after the declared checks failed (docs/manual-development-validation.md):
    // they explain those results and are not part of the declared protocol.

    /// A picture file's own channel values, drawn into a bitmap of its own colour space and depth,
    /// so nothing is converted: 8 or 16 bits per channel, RGBA.
    static func codes(_ url: URL) throws -> (values: [UInt16], width: Int, height: Int, bits: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let space = image.colorSpace
        else { throw CocoaError(.fileReadCorruptFile) }
        let bits = image.bitsPerComponent == 16 ? 16 : 8
        let (w, h) = (image.width, image.height)
        var values = [UInt16](repeating: 0, count: 4 * w * h)
        if bits == 16 {
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            values.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: 8 * w,
                                        space: space, bitmapInfo: info)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        } else {
            var bytes8 = [UInt8](repeating: 0, count: 4 * w * h)
            bytes8.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 4 * w,
                                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            values = bytes8.map(UInt16.init)
        }
        return (values, w, h, bits)
    }

    /// The full-size preview's 8-bit codes against the develop's 16-bit codes rounded to 8 bits,
    /// channel by channel, both in Display P3 as written.
    @Test(.enabled(if: enabled))
    func quantization() throws {
        let folder = try #require(Self.folder)
        for name in Self.names {
            let preview = try Self.codes(folder.appendingPathComponent("\(name)-full.png"))
            let develop = try Self.codes(folder.appendingPathComponent("\(name)-on.tif"))
            try #require(preview.bits == 8 && develop.bits == 16 && preview.width == develop.width && preview.height == develop.height)
            var counts = [Int: Int]()
            for i in preview.values.indices where i % 4 != 3 {
                let rounded = (Int(develop.values[i]) * 255 + 32767) / 65535
                counts[Int(preview.values[i]) - rounded, default: 0] += 1
            }
            let total = counts.values.reduce(0, +)
            let shares = counts.keys.sorted().map { String(format: "%+d: %.5f%%", $0, 100 * Double(counts[$0]!) / Double(total)) }
            print("MEASURE quantization \(name): preview code minus develop rounded to 8 bits, of \(total) channel values: "
                  + shares.joined(separator: ", "))
        }
    }

    /// Where 96-pixel patches of the normal-size preview sit in the resized develop, grain Off, on
    /// a 3 by 3 grid, and the shift and scale that fit them; green channel, high-passed.
    @Test(.enabled(if: enabled))
    func registration() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let resize = try AreaResize(gpu: gpu)
        let folder = try #require(Self.folder)
        for name in Self.names {
            let preview = try Self.linear(folder.appendingPathComponent("\(name)-off.png"), gpu: gpu)
            let full = try Self.linear(folder.appendingPathComponent("\(name)-off.tif"), gpu: gpu)
            let develop = try resize.resized(full.texture, scale: Double(max(preview.width, preview.height)) / Double(max(full.width, full.height)))
            let p = Pixels(preview.texture), d = Pixels(develop.texture)
            var points: [(x: Double, y: Double, dx: Double, dy: Double)] = []
            var lines: [String] = []
            for fy in [0.2, 0.5, 0.8] {
                for fx in [0.2, 0.5, 0.8] {
                    let cx = Int(fx * Double(p.width)), cy = Int(fy * Double(p.height))
                    let shift = Registration.shift(p, d, centreX: cx, centreY: cy, side: 96, channel: 1, reach: 40)
                    lines.append(String(format: "(%d,%d) %+.2f,%+.2f r%.2f", cx, cy, shift.x, shift.y, shift.correlation))
                    if shift.correlation > 0.5 { points.append((Double(cx), Double(cy), shift.x, shift.y)) }
                }
            }
            // dx = tx + sx (x - centre), dy = ty + sy (y - centre), by least squares.
            func fit(_ u: [Double], _ v: [Double]) -> (offset: Double, slope: Double) {
                let mu = u.reduce(0, +) / Double(u.count), mv = v.reduce(0, +) / Double(v.count)
                let suu = zip(u, u).map { ($0 - mu) * ($1 - mu) }.reduce(0, +)
                let suv = zip(u, v).map { ($0 - mu) * ($1 - mv) }.reduce(0, +)
                let slope = suu > 0 ? suv / suu : 0
                return (mv - slope * mu, slope)
            }
            let x = fit(points.map { $0.x - Double(p.width) / 2 }, points.map(\.dx))
            let y = fit(points.map { $0.y - Double(p.height) / 2 }, points.map(\.dy))
            print("MEASURE registration \(name), preview \(p.width)x\(p.height) in develop \(full.width)x\(full.height) resized \(d.width)x\(d.height): "
                  + lines.joined(separator: "; "))
            print(String(format: "MEASURE   fit: shift at centre %+.2f, %+.2f px; scale error %+.2f, %+.2f px per 1000 px (%d patches)",
                         x.offset, y.offset, 1000 * x.slope, 1000 * y.slope, points.count))
        }
    }

    /// Where the blurred preview and develop differ, grain Off: CIEDE2000 after the σ = 2 px blur
    /// as a gray PNG, black 0 to white 10 or more, NAME-difference.png, rows as the texture holds
    /// them; and the mean over each tenth of the frame's luminance range of the develop.
    @Test(.enabled(if: enabled))
    func differenceMap() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let resize = try AreaResize(gpu: gpu)
        let folder = try #require(Self.folder)
        for name in Self.names {
            let preview = try Self.linear(folder.appendingPathComponent("\(name)-off.png"), gpu: gpu)
            let full = try Self.linear(folder.appendingPathComponent("\(name)-off.tif"), gpu: gpu)
            let develop = try resize.resized(full.texture, scale: Double(max(preview.width, preview.height)) / Double(max(full.width, full.height)))
            let w = min(preview.width, develop.width), h = min(preview.height, develop.height)
            let p = Picture(preview.texture, width: w, height: h).blurred(sigma: 2)
            let d = Picture(develop.texture, width: w, height: h).blurred(sigma: 2)
            var gray = [UInt8](repeating: 0, count: w * h)
            var byLightness = [(sum: Double, count: Int)](repeating: (0, 0), count: 10)
            for i in 0..<(w * h) {
                let lp = Colour.lab(SIMD3<Double>(p.rgb[i])), ld = Colour.lab(SIMD3<Double>(d.rgb[i]))
                let e = Colour.deltaE2000(lp, ld)
                gray[i] = UInt8(min(255, e * 25.5))
                let band = min(9, max(0, Int(ld.x / 10)))
                byLightness[band].sum += e
                byLightness[band].count += 1
            }
            let url = folder.appendingPathComponent("\(name)-difference.png")
            if let provider = CGDataProvider(data: Data(gray) as CFData),
               let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
               let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
            let bands = byLightness.enumerated().map { String(format: "L* %d-%d: %.2f (%.1f%%)", 10 * $0.offset, 10 * $0.offset + 10,
                $0.element.count > 0 ? $0.element.sum / Double($0.element.count) : 0, 100 * Double($0.element.count) / Double(w * h)) }
            print("MEASURE difference \(name): blurred dE00 mean by the develop's L*: " + bands.joined(separator: "; "))
        }
    }

    /// `registration` again with an exhaustive search: L* blurred by σ = 1 px, 128-pixel patches on
    /// a 4 by 3 grid, every integer shift within 16 px, then a parabola through the best's
    /// neighbours (`PatchRegistration`). Sparse sharp edges, the S frame's wall and gate, can fall
    /// between a coarse search's steps.
    @Test(.enabled(if: enabled))
    func registrationExhaustive() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let resize = try AreaResize(gpu: gpu)
        let folder = try #require(Self.folder)
        for name in Self.names {
            let preview = try Self.linear(folder.appendingPathComponent("\(name)-off.png"), gpu: gpu)
            let full = try Self.linear(folder.appendingPathComponent("\(name)-off.tif"), gpu: gpu)
            let develop = try resize.resized(full.texture, scale: Double(max(preview.width, preview.height)) / Double(max(full.width, full.height)))
            let w = min(preview.width, develop.width), h = min(preview.height, develop.height)
            let result = PatchRegistration.register(Pixels(preview.texture), against: Pixels(develop.texture))
            let lines = result.patches.map { String(format: "(%d,%d) %+.2f,%+.2f r%.2f", $0.x, $0.y, $0.dx, $0.dy, $0.r) }
            let x = (offset: result.shift.x, slope: result.scale.x), y = (offset: result.shift.y, slope: result.scale.y)
            print("MEASURE exhaustive registration \(name) (develop patch found at preview + shift; texture rows bottom up): " + lines.joined(separator: "; "))
            print(String(format: "MEASURE   fit over %d patches with r > 0.8: shift at centre %+.2f, %+.2f px; scale %+.2f, %+.2f px per 1000 px",
                         result.matched.count, x.offset, y.offset, 1000 * x.slope, 1000 * y.slope))
            // The develop moved onto the preview by the fit, bilinear, then the declared blurred comparison.
            let pp = Picture(preview.texture, width: w, height: h)
            var moved = Picture(develop.texture, width: w, height: h)
            let source = moved.rgb
            for yy in 0..<h {
                for xx in 0..<w {
                    let sx = Double(xx) - (x.offset + x.slope * (Double(xx) - Double(w) / 2))
                    let sy = Double(yy) - (y.offset + y.slope * (Double(yy) - Double(h) / 2))
                    let x0 = min(max(Int(sx.rounded(.down)), 0), w - 2), y0 = min(max(Int(sy.rounded(.down)), 0), h - 2)
                    let fx = Float(min(max(sx - Double(x0), 0), 1)), fy = Float(min(max(sy - Double(y0), 0), 1))
                    let top = source[y0 * w + x0] * (1 - fx) + source[y0 * w + x0 + 1] * fx
                    let bottom = source[(y0 + 1) * w + x0] * (1 - fx) + source[(y0 + 1) * w + x0 + 1] * fx
                    moved.rgb[yy * w + xx] = top * (1 - fy) + bottom * fy
                }
            }
            let aligned = Self.differences(pp.blurred(sigma: 2), moved.blurred(sigma: 2), border: 8)
            print("MEASURE   after moving the develop by the fit, grain Off, blurred σ 2 px: \(aligned.text)")
        }
    }
}
