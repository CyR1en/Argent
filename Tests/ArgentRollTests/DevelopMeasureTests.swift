import ArgentCore
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import ArgentRoll

/// Full-size develop costs on this machine, behind docs/M2-shell.md section 5. Like
/// `FrameViewMeasureTests` they need the corpus and build/stocks and run only with
/// ARGENT_MEASURE=1, one test at a time.
@Suite(.serialized) struct DevelopMeasureTests {
    static var enabled: Bool { FrameViewMeasureTests.enabled }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("argent-develop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test(.enabled(if: DevelopMeasureTests.enabled))
    func stagesAtFullSize() throws {
        let clock = ContinuousClock()
        let gpu = try GPU()
        let decoder = AppleRawDecoder(gpu: gpu)
        let stock = try Stock.load(from: FrameViewMeasureTests.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let files = Array(FrameViewMeasureTests.files().prefix(8))
        let out = try scratch()
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try decoder.decode(files[0], options: DecodeOptions())
        var decode: [Double] = [], film: [Double] = [], resize2048: [Double] = []
        var image8: [String: [Double]] = [:], image16: [Double] = []
        var encode: [String: [Double]] = [:], bytes: [String: [Double]] = [:]
        let spaces: [(String, CFString)] = [("sRGB", CGColorSpace.sRGB), ("P3", CGColorSpace.displayP3),
                                            ("AdobeRGB", CGColorSpace.adobeRGB1998)]
        for (n, url) in files.enumerated() {
            var start = clock.now
            let linear = try decoder.decode(url, options: DecodeOptions())
            decode.append(FrameViewMeasureTests.ms(clock.now - start))
            start = clock.now
            let rendered = try renderer.render(linear, settings: DevelopSettings())
            film.append(FrameViewMeasureTests.ms(clock.now - start))
            let ci = CIImage(mtlTexture: rendered.image.texture, options: [.colorSpace: gpu.workingColorSpace])!
            start = clock.now
            let scaled = ci.applyingFilter("CILanczosScaleTransform",
                                           parameters: [kCIInputScaleKey: 2048 / max(ci.extent.width, ci.extent.height),
                                                        kCIInputAspectRatioKey: 1])
            _ = gpu.ciContext.createCGImage(scaled, from: scaled.extent.integral, format: .RGBA8,
                                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            resize2048.append(FrameViewMeasureTests.ms(clock.now - start))
            var srgb: CGImage?
            for (name, space) in spaces {
                start = clock.now
                let image = gpu.ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: space)!)
                image8[name, default: []].append(FrameViewMeasureTests.ms(clock.now - start))
                if name == "sRGB" { srgb = image }
            }
            start = clock.now
            let deep = gpu.ciContext.createCGImage(ci, from: ci.extent, format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
            image16.append(FrameViewMeasureTests.ms(clock.now - start))
            let jobs: [(String, CGImage, UTType, [CFString: Any])] = [
                ("JPEG 0.92", srgb!, .jpeg, [kCGImageDestinationLossyCompressionQuality: 0.92]),
                ("HEIC 0.9", srgb!, .heic, [kCGImageDestinationLossyCompressionQuality: 0.9]),
                ("TIFF 16 none", deep, .tiff, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]]),
                ("TIFF 16 LZW", deep, .tiff, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]]),
                ("TIFF 16 deflate", deep, .tiff, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 8]]),
            ]
            for (name, image, type, properties) in jobs {
                let file = out.appendingPathComponent("\(n)-\(name).\(type.preferredFilenameExtension ?? "x")")
                start = clock.now
                let destination = CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, image, properties as CFDictionary)
                #expect(CGImageDestinationFinalize(destination))
                encode[name, default: []].append(FrameViewMeasureTests.ms(clock.now - start))
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                bytes[name, default: []].append(Double(size) / 1e6)
            }
        }
        print("MEASURE full-size decode: \(FrameViewMeasureTests.summary(decode))")
        print("MEASURE film passes: \(FrameViewMeasureTests.summary(film))")
        print("MEASURE resize to 2048 and 8-bit picture: \(FrameViewMeasureTests.summary(resize2048))")
        for (name, _) in spaces { print("MEASURE 8-bit picture in \(name): \(FrameViewMeasureTests.summary(image8[name]!))") }
        print("MEASURE 16-bit picture in sRGB: \(FrameViewMeasureTests.summary(image16))")
        for name in ["JPEG 0.92", "HEIC 0.9", "TIFF 16 none", "TIFF 16 LZW", "TIFF 16 deflate"] {
            let sizes = bytes[name]!.sorted()
            print("MEASURE encode \(name): \(FrameViewMeasureTests.summary(encode[name]!)), median \(String(format: "%.1f", sizes[sizes.count / 2])) MB")
        }
    }

    /// Frames a second when `lanes` frames decode and render at once and the encodes overlap.
    @Test(.enabled(if: DevelopMeasureTests.enabled), arguments: [1, 2])
    func throughput(lanes: Int) throws {
        let gpu = try GPU()
        let decoder = AppleRawDecoder(gpu: gpu)
        let stock = try Stock.load(from: FrameViewMeasureTests.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let files = FrameViewMeasureTests.files()
        let out = try scratch()
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try decoder.decode(files[0], options: DecodeOptions())
        let decodeQueue = OperationQueue()
        decodeQueue.maxConcurrentOperationCount = lanes
        let encodeQueue = OperationQueue()
        encodeQueue.maxConcurrentOperationCount = 4
        let lock = NSLock()
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let clock = ContinuousClock()
        let start = clock.now
        // Apple's decoder is safe to share across threads, as `ChosenDecoder` shares it; the
        // renderer and the GPU are used only under `lock`.
        let shared = UncheckedBox((decoder: decoder, renderer: renderer, gpu: gpu))
        for (n, url) in files.enumerated() {
            decodeQueue.addOperation {
                let (decoder, renderer, gpu) = shared.value
                guard let linear = try? decoder.decode(url, options: DecodeOptions()) else { return }
                let image: CGImage? = lock.withLock {
                    // The GPU context is not thread-safe outside the pool.
                    guard let rendered = try? renderer.render(linear, settings: DevelopSettings()) else { return nil }
                    let ci = CIImage(mtlTexture: rendered.image.texture, options: [.colorSpace: gpu.workingColorSpace])!
                    return gpu.ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: sRGB)
                }
                guard let image else { return }
                encodeQueue.addOperation {
                    let file = out.appendingPathComponent("\(n).jpg")
                    let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
                    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
                    _ = CGImageDestinationFinalize(destination)
                }
            }
        }
        decodeQueue.waitUntilAllOperationsAreFinished()
        encodeQueue.waitUntilAllOperationsAreFinished()
        let seconds = FrameViewMeasureTests.ms(clock.now - start) / 1000
        print(String(format: "MEASURE %d lane(s): %d frames to full-size JPEG in %.1f s, %.2f frames a second",
                     lanes, files.count, seconds, Double(files.count) / seconds))
    }
}

/// The process's VM accounting, with the kernel's footprint by kind.
func vmInfo() -> task_vm_info_data_t {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return info
}

/// The process's physical footprint, as Activity Monitor and `footprint` report it.
func physicalFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

/// The kernel's peak footprint since the last `resetFootprintPeak()`, which catches what a
/// sampler misses: a 20 ms sampler of the app's develop read 2.30 GB where this read 2.40 to
/// 2.43 GB (measured, docs/M2-shell.md section 10). 0 where the kernel does not report it.
func footprintPeakSinceReset() -> Int {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return result == 0 ? Int(info.ri_interval_max_phys_footprint) : 0
}

/// Starts the kernel's peak footprint over from the footprint now.
func resetFootprintPeak() {
    // libSystem exports it; Swift's Darwin module does not import the declaration.
    typealias Control = @convention(c) (pid_t, Int32, UnsafeMutableRawPointer?) -> Int32
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_rlimit_control") else { return }
    _ = unsafeBitCast(symbol, to: Control.self)(getpid(), RLIMIT_FOOTPRINT_INTERVAL,
                                                UnsafeMutableRawPointer(bitPattern: UInt(FOOTPRINT_INTERVAL_RESET)))
}

/// The footprint's peak while `work` runs: the kernel's, and a 50 ms sampler's where that is
/// higher (it never is where the kernel reports one).
func peakFootprint(during work: () async -> Void) async -> (start: Int, peak: Int) {
    let start = physicalFootprint()
    let peak = PeakBox()
    resetFootprintPeak()
    let sampler = Task.detached {
        while !Task.isCancelled {
            peak.note(physicalFootprint())
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    await work()
    sampler.cancel()
    peak.note(physicalFootprint())
    peak.note(footprintPeakSinceReset())
    return (start, peak.value)
}

final class PeakBox: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0
    func note(_ value: Int) { lock.withLock { peak = max(peak, value) } }
    var value: Int { lock.withLock { peak } }
}

@Suite(.serialized) struct DevelopMemoryTests {
    struct Setup: Sendable, CustomStringConvertible {
        var lanes: Int
        var pictures: Int
        var pool: Int
        var description: String { "\(lanes) lane(s), \(pictures) picture(s), pool \(pool >> 20) MB" }
    }

    /// One setup a process: the developer's own, or ARGENT_DEVELOP="lanes,pictures,tile[,pool MB[,format]]"
    /// (tile 0 decodes whole); the format, 0 JPEG, 1 HEIC, 2 TIFF, from ARGENT_FORMAT or the fifth
    /// number. The develop's memory target is the app's, or ARGENT_DEVELOP_MEMORY_MB.
    @Test(.enabled(if: DevelopMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_ROLL"] != nil))
    func peakDuringADevelop() async throws {
        let given = ProcessInfo.processInfo.environment["ARGENT_DEVELOP"]?.split(separator: ",").map { Int($0)! }
        let parts = given ?? [RollDeveloper.lanes, 2, RollDeveloper.decodeTile ?? 0, 0,
                              ProcessInfo.processInfo.environment["ARGENT_FORMAT"].flatMap(Int.init) ?? 0]
        let setup = Setup(lanes: parts[0], pictures: parts[1], pool: parts.count > 3 ? parts[3] << 20 : 0)
        let tile = parts[2] == 0 ? nil : parts[2]
        let stock = try Stock.load(from: FrameViewMeasureTests.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in FrameViewMeasureTests.files() { try FileManager.default.linkItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent)) }
        let roll = await RollScanner.scan(folder)
        // ARGENT_INHOUSE_AT_ONCE bounds the in-house decodes among the lanes, 0 for none.
        let atOnce = ProcessInfo.processInfo.environment["ARGENT_INHOUSE_AT_ONCE"].flatMap(Int.init).map { $0 > 0 ? $0 : nil }
            ?? RollDeveloper.inHouseDecodesAtOnce
        let developer = try RollDeveloper(stocks: [stock], software: "Argent measure", library: root.appendingPathComponent("library"),
                                          lanes: setup.lanes, picturesInFlight: (setup.pictures, min(setup.pictures, 1)), maxIdlePoolBytes: setup.pool,
                                          decodeTile: tile, inHouseDecodesAtOnce: atOnce)
        let jobs = roll.frames.map { frame in
            RollDeveloper.Job(frame: frame, recipe: Recipe(frame: frame, byteCount: RecipeStore.byteCount(of: frame.url), stock: stock,
                                                           stockDigest: stock.digest, roll: RollControls(), own: FrameControls()))
        }
        // ARGENT_TIMELINE: the stages in flight when a 5 ms sampler saw its highest footprint.
        let timeline = ProcessInfo.processInfo.environment["ARGENT_TIMELINE"] != nil ? StageTimeline(jobs.map { DecoderChoice.of($0.frame.url) }) : nil
        if let timeline { developer.observeStage = { timeline.note($0, $1, $2) } }
        let clock = ContinuousClock()
        let start = clock.now
        timeline?.start()
        let (base, peak) = await peakFootprint {
            let format: OutputSettings.Format = parts.count > 4 ? [.jpeg, .heic, .tiff16][parts[4]] : .jpeg
            _ = await developer.develop(jobs, to: root.appendingPathComponent("out"), output: OutputSettings(format: format))
        }
        let seconds = FrameViewMeasureTests.ms(clock.now - start) / 1000
        if ProcessInfo.processInfo.environment["ARGENT_CATEGORIES"] != nil {
            print("MEASURE categories as the develop ends: \(footprintCategories())")
        }
        if let timeline { print("MEASURE timeline: \(timeline.stop())") }
        if let (admitted, waited, _) = developer.lastAdmissions {
            print("MEASURE budget: target \(developer.memoryTarget >> 20) MB, \(admitted) frames let in, \(waited) after waiting")
        }
        developer.trim()
        if ProcessInfo.processInfo.environment["ARGENT_DECAY"] != nil {
            var decay: [Int] = []
            for _ in 0..<15 {
                decay.append(physicalFootprint() >> 20)
                try await Task.sleep(for: .milliseconds(200))
            }
            print("MEASURE after the develop, every 0.2 s: \(decay) MB")
        }
        print(String(format: "MEASURE develop %@, decode tile %d, format %d, in-house decodes at once %@, %@: %d frames in %.1f s (%.2f a second), footprint %d MB at start, peak %d MB, %d MB after trim",
                     setup.description, tile ?? 0, parts.count > 4 ? parts[4] : 0, atOnce.map(String.init) ?? "unbounded",
                     DecoderSwitchMeasureTests.decoderName,
                     jobs.count, seconds, Double(jobs.count) / seconds, base >> 20, peak >> 20, physicalFootprint() >> 20))
    }

    /// One full-size decode on its own: what Apple's decoder holds while it works.
    @Test(.enabled(if: DevelopMeasureTests.enabled))
    func peakDuringOneDecode() async throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let decoder = AppleRawDecoder(gpu: gpu)
        let file = FrameViewMeasureTests.files().first { $0.lastPathComponent.contains("Large") }!
        _ = try decoder.decode(file, options: { var o = DecodeOptions(); o.maxLongSide = 512; return o }())
        let (base, peak) = await peakFootprint {
            _ = try? decoder.decode(file, options: DecodeOptions())
        }
        print("MEASURE one full-size decode: footprint \(base >> 20) MB at start, peak \(peak >> 20) MB, \(physicalFootprint() >> 20) MB after")
    }
}

@Suite(.serialized) struct DecodeMemoryTests {
    static let file = FrameViewMeasureTests.files().first { $0.lastPathComponent.contains("Large") }!

    /// What Core Image keeps after a full-size decode, and what clearing its caches gives back.
    @Test(.enabled(if: DevelopMeasureTests.enabled))
    func cachesAfterAFullSizeDecode() async throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let decoder = AppleRawDecoder(gpu: gpu)
        var frame: LinearFrame? = try decoder.decode(Self.file, options: { var o = DecodeOptions(); o.maxLongSide = 512; return o }())
        let base = physicalFootprint()
        let clock = ContinuousClock()
        let start = clock.now
        let (_, peak) = await peakFootprint { frame = try? decoder.decode(Self.file, options: DecodeOptions()) }
        let time = FrameViewMeasureTests.ms(clock.now - start)
        let held = withExtendedLifetime(frame) { physicalFootprint() }
        frame = nil
        let released = physicalFootprint()
        gpu.ciContext.clearCaches()
        let cleared = physicalFootprint()
        gpu.ciContext.reclaimResources()
        try await Task.sleep(for: .milliseconds(200))
        let reclaimed = physicalFootprint()
        print(String(format: "MEASURE whole decode %.0f ms: base %d MB, peak %d, held %d, texture released %d, clearCaches %d, reclaimResources %d",
                     time, base >> 20, peak >> 20, held >> 20, released >> 20, cleared >> 20, reclaimed >> 20))
    }
}

@Suite(.serialized) struct DecodeMemoryTargetTests {
    /// A whole-frame decode through a context told to stay within `target` MB.
    @Test(.enabled(if: DevelopMeasureTests.enabled), arguments: [0, 1024, 512, 256])
    func memoryTarget(target: Int) async throws {
        if let only = ProcessInfo.processInfo.environment["ARGENT_TARGET"], Int(only) != target { return }
        let device = MTLCreateSystemDefaultDevice()!
        let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        var options: [CIContextOption: Any] = [.workingColorSpace: working, .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
                                               .cacheIntermediates: false]
        if target > 0 { options[.memoryTarget] = NSNumber(value: target) }
        let context = CIContext(mtlDevice: device, options: options)
        let queue = device.makeCommandQueue()!
        let all = ProcessInfo.processInfo.environment["ARGENT_ALL"] != nil
        let files = all ? Array(FrameViewMeasureTests.files()) : Array(FrameViewMeasureTests.files().filter { $0.path.contains("photographyblog") }.prefix(6))
        let fresh = ProcessInfo.processInfo.environment["ARGENT_FRESH"] != nil
        var times: [Double] = []
        let base = physicalFootprint()
        let (_, peak) = await peakFootprint {
            for file in files {
                let start = ContinuousClock.now
                let pooled = ProcessInfo.processInfo.environment["ARGENT_POOL"] != nil
                let used = fresh ? CIContext(mtlDevice: device, options: options) : context
                let texture: MTLTexture? = pooled ? autoreleasepool { Self.decode(file, used, device, queue, working) }
                                                  : Self.decode(file, used, device, queue, working)
                _ = texture
                times.append(FrameViewMeasureTests.ms(ContinuousClock.now - start))
            }
        }
        context.reclaimResources()
        try await Task.sleep(for: .milliseconds(300))
        print(String(format: "MEASURE memoryTarget %d MB%@%@, %d files: %@; base %d MB, peak %d MB, %d MB after reclaim",
                     target, ProcessInfo.processInfo.environment["ARGENT_POOL"] != nil ? " in autorelease pools" : "",
                     fresh ? ", a new context per decode" : "", files.count,
                     FrameViewMeasureTests.summary(times), base >> 20, peak >> 20, physicalFootprint() >> 20))
    }

    static func decode(_ file: URL, _ context: CIContext, _ device: MTLDevice, _ queue: MTLCommandQueue,
                       _ working: CGColorSpace) -> MTLTexture? {
                let filter = CIRAWFilter(imageURL: file)!
                AppleRawDecoder.configure(filter, options: DecodeOptions(), iso: AppleRawDecoder.isoSpeed(of: filter),
                                          layout: try? ARWLayout.read(from: file))
                let image = filter.outputImage!
                let extent = image.extent.integral
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: Int(extent.width),
                                                                          height: Int(extent.height), mipmapped: false)
                descriptor.usage = [.shaderRead, .shaderWrite]
                descriptor.storageMode = .shared
                let texture = device.makeTexture(descriptor: descriptor)!
                let buffer = queue.makeCommandBuffer()!
                context.render(image, to: texture, commandBuffer: buffer, bounds: extent, colorSpace: working)
                buffer.commit()
                buffer.waitUntilCompleted()
                return texture
    }
}

@Suite(.serialized) struct DevelopStageMemoryTests {
    /// Frames through the develop's stages one at a time, stopping after ARGENT_STAGE:
    /// 1 decode, 2 film passes, 3 finished picture, 4 JPEG encode.
    @Test(.enabled(if: DevelopMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_STAGE"] != nil))
    func peakThroughStages() async throws {
        let stage = Int(ProcessInfo.processInfo.environment["ARGENT_STAGE"]!)!
        let gpu = try GPU()
        let decoder = AppleRawDecoder(gpu: gpu)
        let encoder = try ImageEncoder(gpu: gpu)
        let stock = try Stock.load(from: FrameViewMeasureTests.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("argent-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let files = FrameViewMeasureTests.files()
        let (base, peak) = await peakFootprint {
            for (n, file) in files.enumerated() {
                autoreleasepool {
                    guard let linear = try? decoder.decode(file, options: DecodeOptions()), stage >= 2,
                          let rendered = try? renderer.render(linear, settings: DevelopSettings()), stage >= 3,
                          let picture = try? encoder.picture(rendered.image.texture, colorSpace: gpu.workingColorSpace,
                                                             format: .jpeg(quality: 0.92)), stage >= 4
                    else { return }
                    try? encoder.write(picture, to: out.appendingPathComponent("\(n).jpg"), format: .jpeg(quality: 0.92),
                                       metadataFrom: file)
                }
            }
        }
        print("MEASURE stages to \(stage), one frame at a time, \(files.count) frames: base \(base >> 20) MB, peak \(peak >> 20) MB, after \(physicalFootprint() >> 20) MB")
    }
}

@Suite(.serialized) struct TiledDecodeTests {
    static func context(_ device: MTLDevice) -> CIContext {
        CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!,
                                               .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue), .cacheIntermediates: false])
    }

    /// Decodes `file` whole (`tile` 0) or in `tile`-pixel tiles through a context of its own.
    static func decode(_ file: URL, tile: Int, device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture {
        autoreleasepool {
            let context = Self.context(device)
            let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
            let filter = CIRAWFilter(imageURL: file)!
            AppleRawDecoder.configure(filter, options: DecodeOptions(), iso: AppleRawDecoder.isoSpeed(of: filter),
                                      layout: try? ARWLayout.read(from: file))
            let image = filter.outputImage!
            let extent = image.extent.integral
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: Int(extent.width),
                                                                      height: Int(extent.height), mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            let texture = device.makeTexture(descriptor: descriptor)!
            if tile == 0 {
                let buffer = queue.makeCommandBuffer()!
                context.render(image, to: texture, commandBuffer: buffer, bounds: extent, colorSpace: working)
                buffer.commit()
                buffer.waitUntilCompleted()
                return texture
            }
            let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
            destination.colorSpace = working
            var y = extent.minY
            while y < extent.maxY {
                var x = extent.minX
                while x < extent.maxX {
                    let rect = CGRect(x: x, y: y, width: min(CGFloat(tile), extent.maxX - x), height: min(CGFloat(tile), extent.maxY - y))
                    let task = try! context.startTask(toRender: image, from: rect, to: destination,
                                                      at: CGPoint(x: rect.minX - extent.minX, y: rect.minY - extent.minY))
                    _ = try! task.waitUntilCompleted()
                    x += CGFloat(tile)
                }
                y += CGFloat(tile)
            }
            return texture
        }
    }

    @Test(.enabled(if: DevelopMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_TILE"] != nil))
    func peakAndPixels() async throws {
        let tile = Int(ProcessInfo.processInfo.environment["ARGENT_TILE"]!)!
        let device = MTLCreateSystemDefaultDevice()!
        let queue = device.makeCommandQueue()!
        let files = FrameViewMeasureTests.files()
        var times: [Double] = []
        let (base, peak) = await peakFootprint {
            for file in files {
                let start = ContinuousClock.now
                _ = Self.decode(file, tile: tile, device: device, queue: queue)
                times.append(FrameViewMeasureTests.ms(ContinuousClock.now - start))
            }
        }
        var line = String(format: "MEASURE decode in %d px tiles (0 = whole), a context per decode: %@; base %d MB, peak %d MB",
                          tile, FrameViewMeasureTests.summary(times), base >> 20, peak >> 20)
        if tile > 0 {
            // Against the whole decode, on three files: the largest difference relative to the
            // pixel, the mean, and the share of pixels off by more than 1 percent.
            for file in files.prefix(3) {
                let whole = Self.decode(file, tile: 0, device: device, queue: queue)
                // ARGENT_SELF compares two whole decodes, for the decoder's own run-to-run noise.
                let selfCheck = ProcessInfo.processInfo.environment["ARGENT_SELF"] != nil
                let tiled = Self.decode(file, tile: selfCheck ? 0 : tile, device: device, queue: queue)
                var nearSeam = 0, offSeam = 0
                let (a, b) = (Self.pixels(whole), Self.pixels(tiled))
                var maxRelative: Float = 0, sum: Double = 0, over = 0
                for i in stride(from: 0, to: a.count, by: 4) {
                    for c in 0..<3 {
                        let x = Float(a[i + c]), y = Float(b[i + c])
                        let relative = abs(x - y) / max(abs(x), 0.01)
                        maxRelative = max(maxRelative, relative)
                        sum += Double(abs(x - y))
                        if relative > 0.01 {
                            over += 1
                            // Distance from the nearest tile edge, in texture pixels from the top
                            // left; Core Image's tiles start at the bottom left.
                            let px = (i / 4) % whole.width, py = whole.height - 1 - (i / 4) / whole.width
                            let dx = min(px % tile, tile - 1 - px % tile), dy = min(py % tile, tile - 1 - py % tile)
                            if min(dx, dy) < 8 { nearSeam += 1 } else { offSeam += 1 }
                        }
                    }
                }
                line += String(format: "\n  %@%@: largest relative difference %.4f, mean absolute %.6f, %.4f%% of samples off by over 1%% (%d within 8 px of a seam, %d elsewhere)",
                               file.lastPathComponent, selfCheck ? " whole against whole" : "", maxRelative, sum / Double(a.count / 4 * 3),
                               100 * Double(over) / Double(a.count / 4 * 3), nearSeam, offSeam)
            }
        }
        print(line)
    }

    static func pixels(_ texture: MTLTexture) -> [Float16] {
        var out = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&out, bytesPerRow: texture.width * 8, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return out
    }
}

/// What each frame of a develop is doing, sampled with the footprint every 5 ms.
final class StageTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private let decoders: [DecoderChoice]
    private var stages: [Int: RollDeveloper.Stage] = [:]
    private var peak = (bytes: 0, at: 0.0, state: "", kinds: "")
    private var sampler: Task<Void, Never>?
    private let clock = ContinuousClock()
    private var origin = ContinuousClock.now

    init(_ decoders: [DecoderChoice]) { self.decoders = decoders }

    func note(_ index: Int, _ stage: RollDeveloper.Stage, _ begins: Bool) {
        lock.withLock { stages[index] = begins ? stage : nil }
    }

    private func state() -> String {
        stages.sorted { $0.key < $1.key }.map { "\($0.key)\(decoders[$0.key] == .inHouse ? "i" : decoders[$0.key] == .raw9 ? "9" : "a"):\($0.value.rawValue)" }.joined(separator: " ")
    }

    func start() {
        origin = clock.now
        sampler = Task.detached { [self] in
            while !Task.isCancelled {
                let info = vmInfo()
                let bytes = Int(info.phys_footprint)
                lock.withLock {
                    if bytes > peak.bytes {
                        let kinds = "graphics \(info.ledger_tag_graphics_footprint >> 20), media \(info.ledger_tag_media_footprint >> 20), internal \(info.internal >> 20), compressed \(info.compressed >> 20) MB"
                        peak = (bytes, FrameViewMeasureTests.ms(clock.now - origin) / 1000, state(), kinds)
                    }
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    func stop() -> String {
        sampler?.cancel()
        return lock.withLock { String(format: "sampled peak %d MB at %.2f s: %@; %@", peak.bytes >> 20, peak.at, peak.state, peak.kinds) }
    }
}
