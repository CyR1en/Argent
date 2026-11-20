import CoreGraphics
import CoreImage
import ImageIO
import Metal
import Foundation
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// What each stage of a develop holds, measured one frame at a time with the develop's own
/// setup, behind the develop's memory budget (docs/M2-shell.md section 10). Like the other
/// measurements they need the samples and build/stocks and run only with ARGENT_MEASURE=1, in a
/// release build with testing on, one process a test:
///
///     ARGENT_MEASURE=1 swift test -c release -Xswiftc -enable-testing --skip-build --filter DevelopBudgetMeasureTests/stages
@Suite(.serialized) struct DevelopBudgetMeasureTests {
    static var enabled: Bool { FrameViewMeasureTests.enabled }

    /// The CC0 lossless L sample through each decoder, and the CC0 uncompressed sample through
    /// Apple's, each through every format: the kernel's peak footprint during each stage and what
    /// is still held after it, in MB above the footprint with nothing held, and how soon the decode's
    /// rise shows in the footprint, sampled every 2 ms (when it first reaches half and nine tenths of
    /// its highest). ARGENT_DECODE_TILE sets the decode's tile (0 for a decode rendered whole) and
    /// ARGENT_CASES keeps the cases whose names contain one of its comma-separated words.
    @Test(.enabled(if: enabled))
    func stages() async throws {
        let stocks = DecoderSwitchMeasureTests.stocks
        let stock = try Stock.load(from: stocks.appendingPathComponent("kodak-portra-400"))
        let root = FrameViewMeasureTests.root.appendingPathComponent("samples")
        let lossless = root.appendingPathComponent("ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")
        let uncompressed = root.appendingPathComponent("ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW")
        let out = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        let cases: [(String, URL, DecoderRoute)] = [("in-house, lossless L", lossless, .inHouse), ("RAW 9, lossless L", lossless, .raw9),
                                                    ("RAW 9, uncompressed", uncompressed, .raw9), ("Apple, lossless L", lossless, .apple),
                                                    ("Apple, uncompressed", uncompressed, .apple)]
        let environment = ProcessInfo.processInfo.environment
        let kept = environment["ARGENT_CASES"].map { $0.split(separator: ",").map(String.init) }
        let tile = environment["ARGENT_DECODE_TILE"].flatMap(Int.init).map { $0 > 0 ? $0 : nil } ?? RollDeveloper.decodeTile
        for (name, file, route) in cases where kept.map({ $0.contains { name.contains($0) } }) ?? true {
            let gpu = try GPU(maxIdlePoolBytes: 300 << 20)
            let decoder = ChosenDecoder(gpu: gpu, choices: DecoderChoices(route: route), contextPerDecode: true, inHouseAtOnce: 1)
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            let encoder = try ImageEncoder(gpu: gpu)
            var options = DecodeOptions()
            options.tileSize = tile
            let settings = DevelopSettings(grain: 1, grainSeed: 7, halation: true, sharpen: true)
            for format in [OutputFormat.jpeg(quality: 0.92), .heic(quality: 0.9), .tiff16] {
                // Once to compile and warm everything, then measured from a trimmed start.
                for pass in 0..<2 {
                    gpu.texturePool.trim()
                    decoder.trim()
                    try await Task.sleep(for: .milliseconds(300))
                    let base = physicalFootprint()
                    func mb(_ bytes: Int) -> Int { (bytes - base) >> 20 }
                    var line: [String] = []
                    func stage<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
                        resetFootprintPeak()
                        let start = ContinuousClock.now
                        let result = try work()
                        let ms = FrameViewMeasureTests.ms(ContinuousClock.now - start)
                        line.append(String(format: "%@ peak %d held %d (%.0f ms)", label, mb(footprintPeakSinceReset()), mb(physicalFootprint()), ms))
                        return result
                    }
                    try autoreleasepool {
                        let picture: CGImage = try autoreleasepool {
                            let shows = FootprintRamp()
                    shows.start()
                    let decoded = try stage("decode") { try decoder.decode(file, options: options) }
                    line.append(shows.stop())
                            let rendered = try stage("film") { try renderer.render(decoded, settings: settings) }
                            return try stage("picture") {
                                try encoder.picture(rendered.image.texture, colorSpace: gpu.workingColorSpace, format: format, space: .sRGB)
                            }
                        }
                        line.append("after the frame's textures go \(mb(physicalFootprint()))")
                        let url = out.appendingPathComponent("\(pass).\(format.fileExtension)")
                        try stage("encode") { try encoder.write(picture, to: url, format: format, metadataFrom: file, software: "measure") }
                    }
                    line.append("all released \(mb(physicalFootprint()))")
                    if pass == 1, ProcessInfo.processInfo.environment["ARGENT_CATEGORIES"] != nil {
                        print("MEASURE categories after \(name), \(format.fileExtension): \(footprintCategories())")
                    }
                    if pass == 1 {
                        print("MEASURE stages, \(name), \(format.fileExtension), decode tile \(tile.map(String.init) ?? "whole"): base \(base >> 20) MB; " + line.joined(separator: "; "))
                    }
                }
            }
        }
    }
}

/// The process's footprint by category, the largest first, as `footprint` reports it.
func footprintCategories(over minimum: Int = 8) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
    process.arguments = ["-p", "\(getpid())", "-f", "bytes"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        // Dirty, clean, reclaimable, each a number and "B", then the regions and the category.
        guard fields.count >= 8, let dirty = Int(fields[0]), dirty >> 20 >= minimum, fields[7] != "TOTAL" else { return nil }
        return "\(fields[7...].joined(separator: " ")) \(dirty >> 20)"
    }.joined(separator: ", ")
}

extension DevelopBudgetMeasureTests {
    /// Apple's full-size decode of the CC0 lossless L and uncompressed samples at each tile size,
    /// with the frame's texture already in the pool: the time, and the kernel's peak footprint above
    /// the start, which is what the decode needs besides its frame. Five decodes each after one to warm.
    @Test(.enabled(if: enabled))
    func appleDecodeTiles() async throws {
        let root = FrameViewMeasureTests.root.appendingPathComponent("samples")
        let files = ["ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW", "ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW"]
            .map { root.appendingPathComponent($0) }
        let tiles = (ProcessInfo.processInfo.environment["ARGENT_TILES"] ?? "1024,768,512").split(separator: ",").map { Int($0)! }
        for file in files {
            for tile in tiles {
                let gpu = try GPU(maxIdlePoolBytes: 300 << 20)
                let decoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
                var options = DecodeOptions()
                options.tileSize = tile
                _ = try decoder.decode(file, options: options)
                var times: [Double] = [], peaks: [Int] = []
                for _ in 0..<5 {
                    try await Task.sleep(for: .milliseconds(200))
                    let base = physicalFootprint()
                    resetFootprintPeak()
                    let start = ContinuousClock.now
                    _ = try decoder.decode(file, options: options)
                    times.append(FrameViewMeasureTests.ms(ContinuousClock.now - start))
                    peaks.append((footprintPeakSinceReset() - base) >> 20)
                }
                print("MEASURE Apple decode \(file.lastPathComponent.prefix(40)), tile \(tile): \(FrameViewMeasureTests.summary(times)); peak above start \(peaks.sorted()) MB")
            }
        }
    }
}

extension DevelopBudgetMeasureTests {
    /// A full-size HEIC of the CC0 lossless L sample through Portra 400, from a picture in memory
    /// and from one in an IOSurface: the time to make and encode each (median of five), the file's
    /// bytes, and its pixels decoded against the exact 8-bit picture.
    @Test(.enabled(if: enabled))
    func heicPaths() async throws {
        let stock = try Stock.load(from: DecoderSwitchMeasureTests.stocks.appendingPathComponent("kodak-portra-400"))
        let file = FrameViewMeasureTests.root.appendingPathComponent("samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")
        let gpu = try GPU(maxIdlePoolBytes: 600 << 20)
        let decoder = ChosenDecoder(gpu: gpu, choices: DecoderChoices())
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let encoder = try ImageEncoder(gpu: gpu)
        let rendered = try renderer.render(try decoder.decode(file, options: DecodeOptions()),
                                           settings: DevelopSettings(grain: 1, grainSeed: 7, halation: true, sharpen: true))
        let out = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        guard let image = CIImage(mtlTexture: rendered.image.texture, options: [.colorSpace: gpu.workingColorSpace]) else { return }
        let exact = try encoder.memoryPicture(image, format: .heic(quality: 0.9), space: .sRGB)
        func pixels(_ picture: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: picture.width * picture.height * 4)
            let context = CGContext(data: &data, width: picture.width, height: picture.height, bitsPerComponent: 8,
                                    bytesPerRow: picture.width * 4, space: OutputSpace.sRGB.colorSpace,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(picture, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
            return data
        }
        let reference = pixels(exact)
        for (name, make) in [("in memory", { try encoder.memoryPicture(image, format: .heic(quality: 0.9), space: .sRGB) }),
                             ("IOSurface", { try encoder.surfacePicture(image, space: .sRGB) })] as [(String, () throws -> CGImage)] {
            var makeTimes: [Double] = [], encodeTimes: [Double] = []
            let url = out.appendingPathComponent("\(name).heic")
            for _ in 0..<5 {
                try autoreleasepool {
                    let start = ContinuousClock.now
                    let picture = try make()
                    let made = ContinuousClock.now
                    try encoder.write(picture, to: url, format: .heic(quality: 0.9), metadataFrom: file, software: "measure")
                    makeTimes.append(FrameViewMeasureTests.ms(made - start))
                    encodeTimes.append(FrameViewMeasureTests.ms(ContinuousClock.now - made))
                }
            }
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let decoded = pixels(CGImageSourceCreateImageAtIndex(source, 0, nil)!)
            var squared = 0.0, worst = 0
            for i in 0..<decoded.count where i % 4 != 3 {
                let d = Int(decoded[i]) - Int(reference[i])
                squared += Double(d * d)
                worst = max(worst, abs(d))
            }
            let psnr = 10 * log10(255 * 255 / (squared / Double(decoded.count / 4 * 3)))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
            let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print(String(format: "MEASURE HEIC %@: picture %@; encode %@; %d bytes, %@, PSNR %.2f dB against the exact picture, worst %d",
                         name, FrameViewMeasureTests.summary(makeTimes), FrameViewMeasureTests.summary(encodeTimes), bytes,
                         properties[kCGImagePropertyProfileName] as? String ?? "no profile", psnr, worst))
        }
    }
}

extension DevelopBudgetMeasureTests {
    /// How long what a stage lets go stays in the footprint: after a full-size Apple decode, after the
    /// film passes and the JPEG picture with the frame let go, and after the picture is written and
    /// let go, the footprint every 10 ms for 0.6 s. ARGENT_CLEAR clears the shared Core Image
    /// context's caches after each stage.
    @Test(.enabled(if: enabled))
    func releaseLag() async throws {
        let stock = try Stock.load(from: DecoderSwitchMeasureTests.stocks.appendingPathComponent("kodak-portra-400"))
        let file = FrameViewMeasureTests.root.appendingPathComponent("samples/ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW")
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let decoder = ChosenDecoder(gpu: gpu, choices: DecoderChoices(), contextPerDecode: true)
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let encoder = try ImageEncoder(gpu: gpu)
        let clear = ProcessInfo.processInfo.environment["ARGENT_CLEAR"] != nil
        var options = DecodeOptions()
        options.tileSize = 1024
        let out = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        func watch(_ label: String) async {
            if clear { gpu.ciContext.clearCaches() }
            var samples: [Int] = []
            for _ in 0..<60 {
                samples.append(physicalFootprint() >> 20)
                try? await Task.sleep(for: .milliseconds(10))
            }
            print("MEASURE release lag\(clear ? " (caches cleared)" : ""), \(label): \(samples.first!) MB, then \(samples[5]) at 50 ms, \(samples[10]) at 100, \(samples[20]) at 200, \(samples[40]) at 400, \(samples.last!) at 600")
        }
        for pass in 0..<2 {
            var decoded: LinearFrame? = try decoder.decode(file, options: options)
            await watch("pass \(pass), the decode returned, its frame held")
            var picture: CGImage? = try autoreleasepool {
                let rendered = try renderer.render(decoded!, settings: DevelopSettings(grain: 1, grainSeed: 3, halation: true, sharpen: true),
                                                   inPlace: true)
                return try encoder.picture(rendered.image.texture, colorSpace: gpu.workingColorSpace, format: .jpeg(quality: 0.92), space: .sRGB)
            }
            decoded = nil
            await watch("pass \(pass), the picture made and the frame let go")
            try autoreleasepool { try encoder.write(picture!, to: out.appendingPathComponent("\(pass).jpg"), format: .jpeg(quality: 0.92), metadataFrom: file) }
            picture = nil
            await watch("pass \(pass), the picture written and let go")
        }
    }
}

extension DevelopBudgetMeasureTests {
    /// The frame let go after its decode alone, after the film passes, and after the JPEG picture:
    /// the footprint every 10 ms for 0.4 s, to find what keeps a frame after it is let go.
    @Test(.enabled(if: enabled))
    func releaseLagByStage() async throws {
        let stock = try Stock.load(from: DecoderSwitchMeasureTests.stocks.appendingPathComponent("kodak-portra-400"))
        let file = FrameViewMeasureTests.root.appendingPathComponent("samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let decoder = ChosenDecoder(gpu: gpu, choices: DecoderChoices(),
                                    contextPerDecode: true)
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let encoder = try ImageEncoder(gpu: gpu)
        var options = DecodeOptions()
        options.tileSize = 1024
        func watch(_ label: String) async {
            var samples: [Int] = []
            for _ in 0..<40 {
                samples.append(physicalFootprint() >> 20)
                try? await Task.sleep(for: .milliseconds(10))
            }
            let drop = samples.firstIndex { $0 < samples[0] - 150 }.map { "\($0 * 10) ms" } ?? "not within 400 ms"
            print("MEASURE lag, \(label): \(samples[0]) MB, 150 MB lower after \(drop), \(samples.last!) at 400 ms")
        }
        for pass in 0..<3 {
            autoreleasepool { _ = try? decoder.decode(file, options: options) }
            await watch("pass \(pass), decode only")
            autoreleasepool {
                let decoded = try! decoder.decode(file, options: options)
                _ = try! renderer.render(decoded, settings: DevelopSettings(grain: 1, grainSeed: 3, halation: true, sharpen: true), inPlace: true)
            }
            await watch("pass \(pass), decode and film")
            autoreleasepool {
                let decoded = try! decoder.decode(file, options: options)
                let rendered = try! renderer.render(decoded, settings: DevelopSettings(grain: 1, grainSeed: 3, halation: true, sharpen: true), inPlace: true)
                _ = try! encoder.picture(rendered.image.texture, colorSpace: gpu.workingColorSpace, format: .jpeg(quality: 0.92), space: .sRGB)
            }
            await watch("pass \(pass), decode, film and picture, picture let go too")
        }
    }
}

extension DevelopBudgetMeasureTests {
    /// A full-size 16-bit TIFF written from the picture as the encoder makes it, and from the same
    /// pixels in other layouts: the time and what the write adds to the footprint, sampled every 2 ms
    /// by kind, with the file's bytes.
    @Test(.enabled(if: enabled))
    func tiffEncode() async throws {
        let stock = try Stock.load(from: DecoderSwitchMeasureTests.stocks.appendingPathComponent("kodak-portra-400"))
        let file = FrameViewMeasureTests.root.appendingPathComponent("samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let decoder = ChosenDecoder(gpu: gpu, choices: DecoderChoices())
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let encoder = try ImageEncoder(gpu: gpu)
        let out = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        let picture: CGImage = try autoreleasepool {
            let rendered = try renderer.render(try decoder.decode(file, options: DecodeOptions()), settings: DevelopSettings(), inPlace: true)
            return try encoder.picture(rendered.image.texture, colorSpace: gpu.workingColorSpace, format: .tiff16, space: .sRGB)
        }
        print("MEASURE TIFF picture: \(picture.bitsPerPixel) bits a pixel, alpha \(picture.alphaInfo.rawValue), byte order \(picture.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue), \(picture.bytesPerRow) bytes a row")
        func redrawn(_ info: CGBitmapInfo, bitsPerPixel: Int) -> CGImage {
            let context = CGContext(data: nil, width: picture.width, height: picture.height, bitsPerComponent: 16,
                                    bytesPerRow: picture.width * bitsPerPixel / 8, space: picture.colorSpace!, bitmapInfo: info.rawValue)!
            context.draw(picture, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
            return context.makeImage()!
        }
        let variants: [(String, CGImage)] = [
            ("as made", picture),
            ("RGBX, little-endian", redrawn(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue), bitsPerPixel: 64)),
            ("RGBX, big-endian", redrawn(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Big.rawValue), bitsPerPixel: 64)),
            ("RGBA premultiplied, big-endian", redrawn(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Big.rawValue), bitsPerPixel: 64)),
        ]
        for (name, image) in variants {
            for pass in 0..<2 {
                let url = out.appendingPathComponent("\(pass).tif")
                try? FileManager.default.removeItem(at: url)
                try await Task.sleep(for: .milliseconds(300))
                let before = vmInfo()
                resetFootprintPeak()
                let most = PeakBox(), internalMost = PeakBox(), graphicsMost = PeakBox()
                let sampler = Task.detached {
                    while !Task.isCancelled {
                        let info = vmInfo()
                        most.note(Int(info.phys_footprint)); internalMost.note(Int(info.internal)); graphicsMost.note(Int(info.ledger_tag_graphics_footprint))
                        try? await Task.sleep(for: .milliseconds(2))
                    }
                }
                let start = ContinuousClock.now
                try autoreleasepool { try encoder.write(image, to: url, format: .tiff16, metadataFrom: file) }
                let ms = FrameViewMeasureTests.ms(ContinuousClock.now - start)
                sampler.cancel()
                let peak = footprintPeakSinceReset()
                let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                let samples = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as? [CFString: Any]
                if pass == 1 {
                    print(String(format: "MEASURE TIFF %@: %.0f ms, %d bytes, alpha %@; peak +%d MB (malloc +%d, graphics +%d)", name, ms, bytes,
                                 "\(samples?[kCGImagePropertyHasAlpha] ?? "?")", (peak - Int(before.phys_footprint)) >> 20,
                                 (internalMost.value - Int(before.internal)) >> 20, (graphicsMost.value - Int(before.ledger_tag_graphics_footprint)) >> 20))
                }
            }
        }
    }
}

extension DevelopBudgetMeasureTests {
    /// Apple's full-size decode of each CC0 sample in 768-pixel tiles against 1024-pixel tiles and
    /// against the whole frame: the share of samples that differ, the largest difference relative to
    /// the sample, and the mean absolute difference.
    @Test(.enabled(if: enabled))
    func tileDifferences() throws {
        let root = FrameViewMeasureTests.root.appendingPathComponent("samples")
        let names = ["ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW", "ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW",
                     "ILCE-7M4_DSC06677_FullFrame-Raw-Compressed.ARW"]
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let decoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        func samples(_ file: URL, tile: Int?) throws -> [Float16] {
            try autoreleasepool {
                var options = DecodeOptions()
                options.tileSize = tile
                let frame = try decoder.decode(file, options: options)
                var values = [Float16](repeating: 0, count: frame.width * frame.height * 4)
                values.withUnsafeMutableBytes {
                    frame.texture.getBytes($0.baseAddress!, bytesPerRow: frame.width * 8,
                                           from: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0)
                }
                return values
            }
        }
        for name in names {
            let file = root.appendingPathComponent(name)
            let at768 = try samples(file, tile: 768)
            for (label, other) in [("1024", try samples(file, tile: 1024)), ("whole", try samples(file, tile: nil))] {
                var differing = 0, worst: Float = 0, sum: Double = 0, count = 0
                for i in at768.indices where i % 4 != 3 {
                    let a = Float(at768[i]), b = Float(other[i])
                    count += 1
                    if a != b {
                        differing += 1
                        worst = max(worst, abs(a - b) / max(abs(b), 1e-3))
                        sum += Double(abs(a - b))
                    }
                }
                print(String(format: "MEASURE tiles 768 against %@, %@: %.4f percent of samples differ, by up to %.0f percent of the sample, mean %.2e",
                             label, String(name.prefix(40)), Double(differing) / Double(count) * 100, worst * 100, sum / Double(count)))
            }
        }
    }
}

/// The footprint sampled every 2 ms from `start` to `stop`: how long it took to first reach half and nine
/// tenths of its highest rise over the first sample, for how soon a decode's memory shows.
final class FootprintRamp: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(at: Double, bytes: Int)] = []
    private var sampler: Thread?
    private var running = false

    func start() {
        let origin = ProcessInfo.processInfo.systemUptime
        lock.withLock { running = true; samples = [(0, physicalFootprint())] }
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let sample = (ProcessInfo.processInfo.systemUptime - origin, physicalFootprint())
                lock.withLock { samples.append(sample) }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        sampler = thread
        thread.start()
    }

    func stop() -> String {
        let taken = lock.withLock { running = false; return samples }
        guard let first = taken.first, let top = taken.map(\.bytes).max(), top > first.bytes else { return "decode shows nothing" }
        func reached(_ share: Double) -> Double {
            let level = first.bytes + Int(Double(top - first.bytes) * share)
            return taken.first { $0.bytes >= level }?.at ?? .nan
        }
        return String(format: "decode shows half its rise at %.0f ms, nine tenths at %.0f ms, the highest %d MB over its start",
                      reached(0.5) * 1000, reached(0.9) * 1000, (top - first.bytes) >> 20)
    }
}

extension DevelopBudgetMeasureTests {
    /// What a frame's masks add to its film passes as a develop runs them (the develop's GPU, which keeps no coverage between frames):
    /// the CC0 lossless L sample decoded once by RAW 9, then rendered in place with no masks, with 4 and with 16, Exposure on each and
    /// Highlights or Shadows on every other, so the local base field is made too. The kernel's peak footprint during the film passes
    /// above the footprint before them, and what is held after, against `DevelopBudget.maskCost`. The first masked render of the
    /// process also compiles the masks' library, so each count runs twice and the second is the one printed.
    @Test(.enabled(if: enabled))
    func maskedFilmPasses() async throws {
        let stocks = DecoderSwitchMeasureTests.stocks
        let stock = try Stock.load(from: stocks.appendingPathComponent("kodak-portra-400"))
        let file = FrameViewMeasureTests.root.appendingPathComponent("samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")
        let gpu = try GPU(maxIdlePoolBytes: 0)
        gpu.maskFields.maximumBytes = 0
        let decoder = ChosenDecoder(gpu: gpu, choices: DecoderChoices(route: .raw9), contextPerDecode: true, inHouseAtOnce: 1)
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        var options = DecodeOptions()
        options.tileSize = RollDeveloper.decodeTile
        options.learnedTileSize = RollDeveloper.learnedDecodeTile
        func masks(_ count: Int) throws -> MaskSet {
            try MaskSet(masks: (0..<count).map { k in
                let shape: MaskShape = k % 2 == 0
                    ? .linear(.init(full: MaskPoint(x: 0.1 + 0.05 * Float(k), y: 0.02 * Float(k)), zero: MaskPoint(x: 0.15 + 0.05 * Float(k), y: 0.35)))
                    : .radial(.init(center: MaskPoint(x: 0.15 + 0.045 * Float(k), y: 0.3), semiAxisA: 0.22, semiAxisB: 0.13, angle: Float(k) * 0.2))
                return Mask(components: [MaskComponent(shape: shape)],
                            adjustments: k % 2 == 0 ? try ManualAdjustments(exposureEV: -0.3, highlights: -25) : try ManualAdjustments(exposureEV: 0.2, shadows: 20))
            })
        }
        for count in [0, 4, 4, 16, 16] {
            var settings = DevelopSettings(grain: 1, grainSeed: 7, halation: true, sharpen: true)
            settings.manual = try ManualRenderSettings(adjustments: ManualAdjustments.identity.settingMasks(masks(count)), referenceStops: 0.4)
            let decoded = try decoder.decode(file, options: options)
            decoder.trim()
            try await Task.sleep(for: .milliseconds(400))
            let base = physicalFootprint()
            resetFootprintPeak()
            let start = ContinuousClock.now
            let peak: Int = try autoreleasepool {
                let rendered = try renderer.render(decoded, settings: settings, inPlace: true)
                return withExtendedLifetime(rendered) { footprintPeakSinceReset() }
            }
            let ms = FrameViewMeasureTests.ms(ContinuousClock.now - start)
            withExtendedLifetime(decoded) {}
            try await Task.sleep(for: .milliseconds(400))
            let cost = DevelopBudget.maskCost(settings: settings, width: decoded.width, height: decoded.height)
            print(String(format: "MEASURE masked film passes, %d masks: peak %d MB above %d MB, held after %d MB, %.0f ms; maskCost %.1f MB; fields made %d",
                         count, (peak - base) >> 20, base >> 20, (physicalFootprint() - base) >> 20, ms, Double(cost) / 1048576,
                         gpu.maskFields.statistics.allocations))
        }
    }
}
