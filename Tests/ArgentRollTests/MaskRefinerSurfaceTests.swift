import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import ArgentCore
@testable import ArgentRoll

/// Smart masks on real frames and real seeds through the film (plan section 4's tolerance table and section 8's gate; the task's proof).
/// The frames and seeds are private: they are read where they lie and nothing of them enters Git. It runs only when asked:
///
///     ARGENT_MEASURE=1 ARGENT_REFINER_FRAMES=<manifest.json> ARGENT_REFINER_OUT=<folder> \
///       swift test -c release -Xswiftc -enable-testing --filter MaskRefinerSurfaceTests
///
/// The manifest lists frames: `{"stem", "raw", "kind": "sky" | "person" | "subject", "seed", "format": "f32" | "png" | "labels",
/// "seedWidth", "seedHeight", "surfaces": true, "proof": true}`. A `f32` seed is S1b's shipping seed (float32, top row first), quantized
/// to the 8 bits the store keeps; `png` is Vision's matte as R2 saved it, `labels` its foreground labels (any id above 0 is the subject).
///
/// Surfaces (S3's method, grain off): the develop is the full-size decode rendered with tier 2 and area-resized to each preview's size.
/// The frame view after it refines is the develop's decode area-resized to the frame view's size; before, Apple's scaled decode as
/// `FilmPreviews.frameDecodeOptions` asks for it; the sheet is the 960 px decode. Each preview refines on its own decode. The band is the
/// develop's coverage between 0.02 and 0.98, dilated 6 px at the preview's size; a mask's excess is band p99 |ΔL*| against the develop,
/// less the same with no mask on either side. The step when the frame view refines is band p99 |ΔL*| between its two decodes' renders,
/// beside the same with no mask (the settle the app already has).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] != nil
                             && ProcessInfo.processInfo.environment["ARGENT_REFINER_FRAMES"] != nil))
struct MaskRefinerSurfaceTests {
    struct Entry: Codable {
        var stem: String
        var raw: String
        var kind: String
        var seed: String
        var format: String
        var seedWidth: Int?
        var seedHeight: Int?
        var surfaces: Bool?
        var proof: Bool?
    }

    struct Row: Codable {
        var stem: String
        var kind: String
        var adjustment: String
        var surface: String
        var size: Int
        var filmP99: Float
        var maskP99: Float
        var excess: Float
        var coverageP99: Float
        var bandPixels: Int
        var limitExcess: Float
        var limitCoverage: Float
        var passes: Bool
    }

    struct Step: Codable {
        var stem: String
        var kind: String
        var adjustment: String
        var size: Int
        var step: Float
        var settle: Float
        var ratio: Float
    }

    static let environment = ProcessInfo.processInfo.environment
    static var out: URL { URL(fileURLWithPath: environment["ARGENT_REFINER_OUT"] ?? NSTemporaryDirectory() + "argent-refiner") }

    /// The plan's table: excess L* and coverage, band p99, by surface and kind.
    static func limits(surface: String, kind: String) -> (excess: Float, coverage: Float) {
        switch (surface, kind) {
        case ("refined", "person"): return (1, 0.04)
        case ("refined", "subject"): return (2, 0.04)
        case ("refined", _): return (6, 0.10)
        case ("scaled", "person"): return (1.5, 0.08)
        case ("scaled", "subject"): return (2, 0.09)
        case ("scaled", _): return (6, 0.30)
        case (_, "sky"): return (7, 0.35)
        default: return (4, 0.12)
        }
    }

    // MARK: inputs

    final class Seeds: MaskSeedProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var rasters: [RasterID: MaskRaster] = [:]
        func add(_ raster: MaskRaster) { lock.withLock { rasters[raster.identity] = raster } }
        func seed(for ref: RasterRef) throws -> MaskRaster {
            guard let raster = lock.withLock({ rasters[ref.id] }) else { throw CocoaError(.fileNoSuchFile) }
            return raster
        }
    }

    static func seed(_ entry: Entry, frameWidth: Int, frameHeight: Int) throws -> MaskRaster {
        let url = URL(fileURLWithPath: entry.seed)
        switch entry.format {
        case "f32":
            // S1b's seeds are 756 on the long side, the frame's way up.
            let long = max(entry.seedWidth ?? 756, entry.seedHeight ?? 504), short = min(entry.seedWidth ?? 756, entry.seedHeight ?? 504)
            let (w, h) = frameWidth >= frameHeight ? (long, short) : (short, long)
            let data = try Data(contentsOf: url)
            let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            #expect(floats.count == w * h, "\(entry.stem) seed size")
            return try MaskRaster(width: w, height: h, plane: floats.map { UInt8((min(max($0, 0), 1) * 255).rounded()) })
        default:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw CocoaError(.fileReadCorruptFile) }
            let w = image.width, h = image.height
            var plane = [UInt8](repeating: 0, count: w * h)
            let context = CGContext(data: &plane, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            if entry.format == "labels" { plane = plane.map { $0 > 0 ? 255 : 0 } }
            return try MaskRaster(width: w, height: h, plane: plane)
        }
    }

    // MARK: pictures and numbers

    /// A texture's pixels as floats, row 0 the texture's.
    static func pixels(_ texture: MTLTexture) -> [SIMD3<Float>] {
        var halves = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        halves.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return (0..<(texture.width * texture.height)).map { SIMD3(Float(halves[$0 * 4]), Float(halves[$0 * 4 + 1]), Float(halves[$0 * 4 + 2])) }
    }

    /// CIE L* of display-linear Rec. 2020 light, white 1.
    static func lightness(_ pixels: [SIMD3<Float>]) -> [Float] {
        pixels.map { rgb in
            let y = max((rgb * Rec2020.luma).sum(), 0)
            return y > 0.008856 ? 116 * pow(y, 1 / 3) - 16 : 903.3 * y
        }
    }

    /// `values` (`width` by `height`) area-averaged to `toWidth` by `toHeight`, fractional footprints, as `AreaResize` does.
    static func resized(_ values: [Float], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [Float] {
        func weights(_ n: Int, _ m: Int) -> [[(Int, Float)]] {
            (0..<m).map { o in
                let a = Double(o) * Double(n) / Double(m), b = Double(o + 1) * Double(n) / Double(m)
                return (Int(a.rounded(.down))..<min(Int(b.rounded(.up)), n)).map { i in
                    (i, Float((min(Double(i + 1), b) - max(Double(i), a)) / (b - a)))
                }
            }
        }
        let wx = weights(width, toWidth), wy = weights(height, toHeight)
        var rows = [Float](repeating: 0, count: toWidth * height)
        for y in 0..<height {
            for (x, taps) in wx.enumerated() {
                var s: Float = 0
                for (i, w) in taps { s += w * values[y * width + i] }
                rows[y * toWidth + x] = s
            }
        }
        var out = [Float](repeating: 0, count: toWidth * toHeight)
        for (y, taps) in wy.enumerated() {
            for x in 0..<toWidth {
                var s: Float = 0
                for (i, w) in taps { s += w * rows[i * toWidth + x] }
                out[y * toWidth + x] = s
            }
        }
        return out
    }

    /// Where the develop's coverage is between 0.02 and 0.98, dilated `reach` px.
    static func band(_ coverage: [Float], width: Int, height: Int, reach: Int = 6) -> [Bool] {
        let seed = coverage.map { $0 > 0.02 && $0 < 0.98 }
        var across = [Bool](repeating: false, count: seed.count)
        for y in 0..<height {
            var last = -1_000_000
            for x in 0..<width { if seed[y * width + x] { last = x }; if x - last <= reach { across[y * width + x] = true } }
            last = 1_000_000
            for x in stride(from: width - 1, through: 0, by: -1) { if seed[y * width + x] { last = x }; if last - x <= reach { across[y * width + x] = true } }
        }
        var out = across
        for x in 0..<width {
            var last = -1_000_000
            for y in 0..<height { if across[y * width + x] { last = y }; if y - last <= reach { out[y * width + x] = true } }
            last = 1_000_000
            for y in stride(from: height - 1, through: 0, by: -1) { if across[y * width + x] { last = y }; if last - y <= reach { out[y * width + x] = true } }
        }
        return out
    }

    static func p99(_ a: [Float], _ b: [Float], in band: [Bool]) -> Float {
        var d: [Float] = []
        d.reserveCapacity(band.count / 4)
        for i in band.indices where band[i] { d.append(abs(a[i] - b[i])) }
        guard !d.isEmpty else { return 0 }
        d.sort()
        return d[min(d.count - 1, Int(Float(d.count) * 0.99))]
    }

    // MARK: rendering

    /// The frame through the film, and each pixel's coverage of slot 0 as the kernels read it (tier 2 where the rule says).
    /// The render's texture is a loan from the pool: hold `image` while reading `texture`.
    static func render(_ gpu: GPU, _ renderer: FilmRenderer, _ frame: LinearFrame, _ settings: DevelopSettings,
                       coverage: Bool) throws -> (image: PooledTexture, coverage: [Float]?) {
        let rendered = try renderer.render(frame, settings: settings)
        guard coverage else { return (rendered.image, nil) }
        let stock = renderer.stock
        let rated = settings.exposureStops(boxSpeed: stock.boxSpeed)
        let offset = settings.printOffset(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
        let scene = try renderer.sceneInputs(frame, settings: settings, exposureStops: rated, printOffset: offset).scene
        let masks = try #require(scene.masks)
        let count = frame.width * frame.height
        let buffer = try #require(gpu.device.makeBuffer(length: count * 4, options: .storageModeShared))
        let commandBuffer = try #require(gpu.queue.makeCommandBuffer()), encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(masks.pipelines.coverageProbe)
        masks.bind(to: encoder)
        encoder.setTexture(frame.texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        var slot: UInt32 = 0
        encoder.setBytes(&slot, length: 4, index: 1)
        encoder.dispatchPixels(masks.pipelines.coverageProbe, width: frame.width, height: frame.height)
        encoder.endEncoding()
        commandBuffer.commit()
        withExtendedLifetime((frame, scene)) { commandBuffer.waitUntilCompleted() }
        let values = Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: Float.self, capacity: count), count: count))
        return (rendered.image, values)
    }

    static func resizedTexture(_ gpu: GPU, _ resize: AreaResize, _ texture: MTLTexture, width: Int, height: Int) throws -> MTLTexture {
        let output = try gpu.makeTexture(width: width, height: height)
        let commandBuffer = try #require(gpu.queue.makeCommandBuffer())
        try resize.encode(texture, to: output, into: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return output
    }

    /// A window of a rendered texture (display-linear Rec. 2020) as an sRGB PNG; `y` from the picture's top.
    static func crop(_ gpu: GPU, _ texture: MTLTexture, x: Int, y: Int, width: Int, height: Int, scale: Int = 1, to url: URL) throws {
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: gpu.workingColorSpace]) else { return }
        // A texture's row 0 is the picture's bottom, which is CIImage's origin too.
        var window = image.cropped(to: CGRect(x: x, y: texture.height - y - height, width: width, height: height))
        if scale > 1 { window = window.samplingNearest().transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))) }
        let context = CIContext(mtlDevice: gpu.device)
        try context.writePNGRepresentation(of: window, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// A coverage map's window as a gray PNG, top row first.
    static func crop(coverage: [Float], width: Int, height: Int, x: Int, y: Int, w: Int, h: Int, to url: URL) throws {
        var plane = [UInt8](repeating: 0, count: w * h)
        for row in 0..<h {
            let source = (height - 1 - (y + row)) * width
            for column in 0..<w { plane[row * w + column] = UInt8((min(max(coverage[source + x + column], 0), 1) * 255).rounded()) }
        }
        let context = CGContext(data: &plane, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
    }

    /// The windows (`size`, from the picture's top) holding the most of the mask's edge, at most `count`, not overlapping.
    static func windows(_ coverage: [Float], width: Int, height: Int, size: (Int, Int) = (640, 480), count: Int = 3) -> [(Int, Int)] {
        let step = 80
        var scored: [(Int, Int, Int)] = []
        for y in stride(from: 0, through: height - size.1, by: step) {
            for x in stride(from: 0, through: width - size.0, by: step) {
                var n = 0
                for yy in stride(from: y, to: y + size.1, by: 4) {
                    let row = (height - 1 - yy) * width
                    for xx in stride(from: x, to: x + size.0, by: 4) where coverage[row + xx] > 0.05 && coverage[row + xx] < 0.95 { n += 1 }
                }
                scored.append((n, x, y))
            }
        }
        var chosen: [(Int, Int)] = []
        for (_, x, y) in scored.sorted(by: { $0.0 > $1.0 }) where chosen.count < count {
            if chosen.allSatisfy({ abs($0.0 - x) >= size.0 || abs($0.1 - y) >= size.1 }) { chosen.append((x, y)) }
        }
        return chosen
    }

    /// The window at the top of the mask, where a person's or a subject's hair or fur meets what is behind it (S3's "top extreme").
    static func top(_ coverage: [Float], width: Int, height: Int, size: (Int, Int) = (640, 480)) -> (Int, Int)? {
        for yTop in stride(from: 0, to: height, by: 4) {
            let row = (height - 1 - yTop) * width
            let columns = stride(from: 0, to: width, by: 4).filter { coverage[row + $0] > 0.5 }
            guard columns.count > 4 else { continue }
            let x = columns[columns.count / 2]
            return (min(max(x - size.0 / 2, 0), width - size.0), min(max(yTop - size.1 / 4, 0), height - size.1))
        }
        return nil
    }

    // MARK: the run

    struct Context {
        let gpu: GPU
        let decoder: ChosenDecoder
        let resize: AreaResize
        let renderer: FilmRenderer
        let seeds: Seeds
    }

    /// A seed that selects nothing: what `masked(tierOne:)` adds to force tier 1.
    static let emptySeed = try! MaskRaster(width: 64, height: 48, plane: [UInt8](repeating: 0, count: 64 * 48))

    static func context() throws -> Context {
        let gpu = try GPU()
        let seeds = Seeds()
        seeds.add(emptySeed)
        gpu.maskRefiner.seeds = seeds
        let stocks = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/stocks/kodak-portra-400")
        let stock = try Stock.load(from: stocks)
        return Context(gpu: gpu, decoder: ChosenDecoder(gpu: gpu, choices: DecoderChoices(route: .raw9)), resize: try AreaResize(gpu: gpu),
                       renderer: try FilmRenderer(gpu: gpu, stock: stock), seeds: seeds)
    }

    /// Auto's settings for the frame, as the spike's `--auto` and the app make them: the sheet decode's measurement, the aim, the roll's
    /// controls at box speed with lab balance Auto; halation and sharpening on.
    static func settings(_ c: Context, _ url: URL, grain: Bool) throws -> DevelopSettings {
        var sheet = DecodeOptions()
        sheet.maxLongSide = FilmPreviews.previewLongSide
        let analysis = ExposureAnalyzer.measure(try c.decoder.decode(url, options: sheet), workingSpace: c.gpu.workingColorSpace,
                                                info: try? ARWFrameInfo.read(from: url)).analysis
        let aim = AutoPrint.aim(analysis)
        var settings = RollControls().settings(for: c.renderer.stock, aim: aim)
        settings.halation = true
        settings.sharpen = true
        if grain {
            settings.grain = 1
            settings.grainSeed = GrainModel.seed(name: url.lastPathComponent, captureDate: nil)
        }
        settings.manual = try ManualRenderSettings(adjustments: .identity, referenceStops: aim.level)
        return settings
    }

    static func masked(_ settings: DevelopSettings, _ component: MaskComponent, exposure: Float, tierOne: Bool = false) throws -> DevelopSettings {
        var s = settings
        // A second selection whose seed is 0 everywhere refines to exactly 0, so added after the selection it leaves the coverage as
        // it was; with two selections the mask is not affine in either, and takes tier 1: the same field, read from the slice.
        let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let nothing = MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: Self.emptySeed.ref, frame: frame)))
        let mask = Mask(components: tierOne ? [component, nothing] : [component], adjustments: try ManualAdjustments(exposureEV: exposure))
        s.manual = try ManualRenderSettings(adjustments: ManualAdjustments.identity.settingMasks(try MaskSet(masks: [mask])),
                                            referenceStops: settings.manual.referenceStops)
        return s
    }

    /// The selection; with `background`, Subject's seed as Background, and any other's inverted.
    static func component(_ kind: String, _ raster: MaskRaster, background: Bool, width: Int, height: Int) throws -> MaskComponent {
        let smart: SmartKind = kind == "sky" ? .sky : kind == "person" ? .person : .subject
        let frame = try MaskFrame(orientation: 1, width: width, height: height, decoder: .raw9, lensCorrection: true)
        let shown: SmartKind = background && smart == .subject ? .background : smart
        return MaskComponent(shape: .smart(SmartSelection(kind: shown, raster: raster.ref, frame: frame)), invert: background && smart != .subject)
    }

    static func entries() throws -> [Entry] {
        let url = URL(fileURLWithPath: try #require(environment["ARGENT_REFINER_FRAMES"]))
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
    }

    /// The task's proof: each frame at Exposure −1.5 EV through the whole film with grain, unmasked, tier 1 and tier 2, at the windows
    /// that hold most of the edge, 100 % and a 3 × zoom; the coverage map beside them; and one window with grain off.
    @Test func theProof() throws {
        let c = try Self.context()
        let folder = Self.out.appendingPathComponent("proof")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var log = ""
        for entry in try Self.entries() where entry.proof ?? false {
            let url = URL(fileURLWithPath: entry.raw)
            var options = DecodeOptions()
            options.tileSize = RollDeveloper.decodeTile
            options.learnedTileSize = RollDeveloper.learnedDecodeTile
            let frame = try c.decoder.decode(url, options: options)
            let raster = try Self.seed(entry, frameWidth: frame.width, frameHeight: frame.height)
            c.seeds.add(raster)
            let base = try Self.settings(c, url, grain: true)
            let selection = try Self.component(entry.kind, raster, background: false, width: frame.width, height: frame.height)
            var noGrain = base
            noGrain.grain = 0
            // Tier 2 first, for its coverage and the windows; then each other render, cropped as it is made.
            let two = try Self.render(c.gpu, c.renderer, frame, try Self.masked(base, selection, exposure: -1.5), coverage: true)
            let coverage = try #require(two.coverage)
            var chosen = Self.windows(coverage, width: frame.width, height: frame.height)
            if entry.kind != "sky", let head = Self.top(coverage, width: frame.width, height: frame.height) { chosen.insert(head, at: 0) }
            log += "\(entry.stem) \(entry.kind) \(frame.width)x\(frame.height) decoder \(frame.decoderVersion) seed \(raster.width)x\(raster.height) "
                + "windows \(chosen) refiner \(String(describing: c.gpu.maskRefiner.statistics.lastBuild))\n"
            func names(_ index: Int) -> String { "\(entry.stem)_\(entry.kind)_w\(index)" }
            func save(_ image: PooledTexture, _ suffix: String, zoom: Bool = false, first: Bool = false) throws {
                for (index, (x, y)) in chosen.enumerated() where !first || index == 0 {
                    if zoom {
                        try Self.crop(c.gpu, image.texture, x: x + 220, y: y + 160, width: 200, height: 160, scale: 3,
                                 to: folder.appendingPathComponent(names(index) + suffix))
                    } else {
                        try Self.crop(c.gpu, image.texture, x: x, y: y, width: 640, height: 480, to: folder.appendingPathComponent(names(index) + suffix))
                    }
                }
            }
            try save(two.image, "_2tier2.png")
            try save(two.image, "_4tier2_zoom3.png", zoom: true, first: true)
            for (index, (x, y)) in chosen.enumerated() {
                try Self.crop(coverage: coverage, width: frame.width, height: frame.height, x: x, y: y, w: 640, h: 480,
                         to: folder.appendingPathComponent(names(index) + "_3coverage.png"))
            }
            try save(try Self.render(c.gpu, c.renderer, frame, base, coverage: false).image, "_0plain.png")
            let one = try Self.render(c.gpu, c.renderer, frame, try Self.masked(base, selection, exposure: -1.5, tierOne: true), coverage: false).image
            try save(one, "_1tier1.png")
            try save(one, "_5tier1_zoom3.png", zoom: true, first: true)
            try save(try Self.render(c.gpu, c.renderer, frame, try Self.masked(noGrain, selection, exposure: -1.5), coverage: false).image,
                     "_6tier2_nograin.png", first: true)
            c.gpu.maskRefiner.removeAll()
            c.gpu.maskFields.removeAll()
        }
        try log.write(to: folder.appendingPathComponent("proof.txt"), atomically: true, encoding: .utf8)
    }

    /// The plan's main repair, Sky with a Subtract brush, through the film at −1.5 EV on R9's DSC04108 (the first sky frame of the manifest
    /// marked for the proof): a soft stroke across the crown's densest window takes the darkening off there. Tier 2 composed per pixel
    /// (`MaskSlots.composed`), beside Sky alone, the unmasked render, the tier-2 and tier-1 coverage, a 3 × zoom at the stroke's edge and
    /// grain off.
    @Test func theComposedProof() throws {
        let c = try Self.context()
        let folder = Self.out.appendingPathComponent("composed")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let entry = try Self.entries().first(where: { $0.kind == "sky" && ($0.proof ?? false) }) else { return }
        let url = URL(fileURLWithPath: entry.raw)
        var options = DecodeOptions()
        options.tileSize = RollDeveloper.decodeTile
        options.learnedTileSize = RollDeveloper.learnedDecodeTile
        let frame = try c.decoder.decode(url, options: options)
        let raster = try Self.seed(entry, frameWidth: frame.width, frameHeight: frame.height)
        c.seeds.add(raster)
        let base = try Self.settings(c, url, grain: true)
        let sky = try Self.component("sky", raster, background: false, width: frame.width, height: frame.height)
        let long = Float(max(frame.width, frame.height))
        // The stroke runs through the window of the crown with the most edge, as the proof chose it.
        let alone = try Self.render(c.gpu, c.renderer, frame, try Self.masked(base, sky, exposure: -1.5), coverage: true)
        let aloneCoverage = try #require(alone.coverage)
        let (x, y) = try #require(Self.windows(aloneCoverage, width: frame.width, height: frame.height).first)
        let points = [MaskPoint(x: (Float(x) + 80) / long, y: (Float(y) + 380) / long), MaskPoint(x: (Float(x) + 320) / long, y: (Float(y) + 240) / long),
                      MaskPoint(x: (Float(x) + 560) / long, y: (Float(y) + 100) / long)]
        let stroke = BrushStroke(radius: 70 / long, feather: 0.6, flow: 1, points: try PackedPoints.pack(points))
        let paintFrame = try MaskFrame(orientation: 1, width: frame.width, height: frame.height, decoder: .raw9, lensCorrection: true)
        let brush = MaskComponent(operation: .subtract, shape: .brush(BrushPaint(frame: paintFrame, strokes: [stroke])))
        var settings = base
        let mask = Mask(components: [sky, brush], adjustments: try ManualAdjustments(exposureEV: -1.5))
        settings.manual = try ManualRenderSettings(adjustments: ManualAdjustments.identity.settingMasks(try MaskSet(masks: [mask])),
                                                   referenceStops: base.manual.referenceStops)
        let composed = try Self.render(c.gpu, c.renderer, frame, settings, coverage: true)
        // Tier 1 of the same mask: the slice, read by the probe with tier 2 turned off.
        let stock = c.renderer.stock
        var scene = try c.renderer.sceneInputs(frame, settings: settings, exposureStops: settings.exposureStops(boxSpeed: stock.boxSpeed),
                                               printOffset: settings.printOffset(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)).scene
        #expect(scene.masks?.refinement.composed == 1)
        scene.masks?.refinement = LocalMaskRefinement()
        let masks = try #require(scene.masks)
        let count = frame.width * frame.height
        let buffer = try #require(c.gpu.device.makeBuffer(length: count * 4, options: .storageModeShared))
        let commandBuffer = try #require(c.gpu.queue.makeCommandBuffer()), encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(masks.pipelines.coverageProbe)
        masks.bind(to: encoder)
        encoder.setTexture(frame.texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        var slot: UInt32 = 0
        encoder.setBytes(&slot, length: 4, index: 1)
        encoder.dispatchPixels(masks.pipelines.coverageProbe, width: frame.width, height: frame.height)
        encoder.endEncoding()
        commandBuffer.commit()
        withExtendedLifetime((frame, scene)) { commandBuffer.waitUntilCompleted() }
        let tierOne = Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: Float.self, capacity: count), count: count))
        let name = "\(entry.stem)_sky_less_brush"
        try Self.crop(c.gpu, try Self.render(c.gpu, c.renderer, frame, base, coverage: false).image.texture, x: x, y: y, width: 640, height: 480,
                      to: folder.appendingPathComponent(name + "_0plain.png"))
        try Self.crop(c.gpu, alone.image.texture, x: x, y: y, width: 640, height: 480, to: folder.appendingPathComponent(name + "_1sky_alone.png"))
        try Self.crop(c.gpu, composed.image.texture, x: x, y: y, width: 640, height: 480, to: folder.appendingPathComponent(name + "_2composed_tier2.png"))
        try Self.crop(coverage: try #require(composed.coverage), width: frame.width, height: frame.height, x: x, y: y, w: 640, h: 480,
                      to: folder.appendingPathComponent(name + "_3coverage_tier2.png"))
        try Self.crop(coverage: tierOne, width: frame.width, height: frame.height, x: x, y: y, w: 640, h: 480,
                      to: folder.appendingPathComponent(name + "_4coverage_tier1.png"))
        try Self.crop(c.gpu, composed.image.texture, x: x + 220, y: y + 160, width: 200, height: 160, scale: 3,
                      to: folder.appendingPathComponent(name + "_5composed_tier2_zoom3.png"))
        var noGrain = settings
        noGrain.grain = 0
        try Self.crop(c.gpu, try Self.render(c.gpu, c.renderer, frame, noGrain, coverage: false).image.texture, x: x, y: y, width: 640, height: 480,
                      to: folder.appendingPathComponent(name + "_6composed_tier2_nograin.png"))
        // Inside the stroke's core the sky keeps its light; outside its reach the composite is Sky alone, pixel for pixel.
        let coverage = try #require(composed.coverage), skyAlone = try #require(alone.coverage)
        var inside: [Float] = [], outside: Float = 0
        for yy in y..<(y + 480) {
            let row = (frame.height - 1 - yy) * frame.width
            for xx in x..<(x + 640) {
                let q = SIMD2((Float(xx) + 0.5) / long, (Float(yy) + 0.5) / long)
                let near = zip(points, points.dropFirst()).map { a, b -> Float in
                    let p = SIMD2(a.x, a.y), d = SIMD2(b.x, b.y) - p, t = min(max(((q - p) * d).sum() / (d * d).sum(), 0), 1)
                    return ((q - p - t * d) * (q - p - t * d)).sum().squareRoot()
                }.min()!
                if near < 0.2 * stroke.radius { inside.append(coverage[row + xx]) }
                if near > 1.5 * stroke.radius { outside = max(outside, abs(coverage[row + xx] - skyAlone[row + xx])) }
            }
        }
        let line = "\(entry.stem) window (\(x), \(y)): inside the stroke's core coverage max \(inside.max() ?? -1) over \(inside.count) px; "
            + "outside its reach, against Sky alone, max \(outside)"
        print("[refiner] " + line)
        try line.write(to: folder.appendingPathComponent("composed.txt"), atomically: true, encoding: .utf8)
        #expect((inside.max() ?? 1) < 0.01)
        #expect(outside < 0.002)
    }

    /// Whether a seed's low edge columns survive refinement, and whose they are: the portrait padded square's (task A) or the refiner's.
    /// The seed the app stored (`ARGENT_REFINER_EDGE_SEED`, a PNG) and the same seed with its outer four columns on each side set to
    /// the fifth's, each refined on the frame's full-size decode (`ARGENT_REFINER_EDGE_RAW`); tier 2's coverage, by column, over the
    /// rows where the repaired seed's coverage is sky a few hundred pixels in.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ARGENT_REFINER_EDGE_SEED"] != nil))
    func theSeedsEdgeColumns() throws {
        let c = try Self.context()
        let url = URL(fileURLWithPath: try #require(Self.environment["ARGENT_REFINER_EDGE_RAW"]))
        let entry = Entry(stem: url.deletingPathExtension().lastPathComponent, raw: url.path, kind: "sky",
                          seed: try #require(Self.environment["ARGENT_REFINER_EDGE_SEED"]), format: "png")
        var options = DecodeOptions()
        options.tileSize = RollDeveloper.decodeTile
        options.learnedTileSize = RollDeveloper.learnedDecodeTile
        let frame = try c.decoder.decode(url, options: options)
        let stored = try Self.seed(entry, frameWidth: frame.width, frameHeight: frame.height)
        var plane = stored.plane
        for row in 0..<stored.height {
            let base = row * stored.width
            for column in 0..<4 { plane[base + column] = plane[base + 4] }
            for column in (stored.width - 4)..<stored.width { plane[base + column] = plane[base + stored.width - 5] }
        }
        let repaired = try MaskRaster(width: stored.width, height: stored.height, plane: plane)
        c.seeds.add(stored); c.seeds.add(repaired)
        let base = try Self.settings(c, url, grain: false)
        func coverage(_ raster: MaskRaster) throws -> [Float] {
            let component = try Self.component("sky", raster, background: false, width: frame.width, height: frame.height)
            return try #require(try Self.render(c.gpu, c.renderer, frame, try Self.masked(base, component, exposure: -1.5), coverage: true).coverage)
        }
        let original = try coverage(stored), fixed = try coverage(repaired)
        let (w, h) = (frame.width, frame.height)
        var lines: [String] = []
        for (side, columns) in [("left", Array(0..<200)), ("right", Array((w - 200)..<w).reversed())] {
            let inner = side == "left" ? 400 : w - 401
            let rows = (0..<h).filter { fixed[(h - 1 - $0) * w + inner] > 0.98 && fixed[(h - 1 - $0) * w + columns[0]] > 0.98 }
            func mean(_ values: [Float], _ x: Int) -> Float { rows.reduce(0) { $0 + values[(h - 1 - $1) * w + x] } / Float(max(rows.count, 1)) }
            let profile = stride(from: 0, to: 200, by: 20).map { (columns[$0], mean(original, columns[$0]), mean(fixed, columns[$0])) }
            let line = "\(entry.stem) \(side) edge, \(rows.count) sky rows: (px from the edge, coverage stored seed, repaired seed) "
                + profile.enumerated().map { String(format: "%d %.3f %.3f", $0.offset * 20, $0.element.1, $0.element.2) }.joined(separator: " | ")
            print("[refiner] " + line)
            lines.append(line)
        }
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: Self.out.appendingPathComponent("edge-\(entry.stem).txt"), atomically: true, encoding: .utf8)
    }

    /// What a smart mask costs on each surface: the film passes' GPU time unmasked, with the mask in tier 1 and in tier 2 (minimum of
    /// five, after a warm-up), and the refinement's build on that decode (guide frame and coefficients, minimum of five). Taken on a
    /// shared Mac, so read the minimums only as an order of size.
    @Test func theCostPerSurface() throws {
        let c = try Self.context()
        var lines: [String] = []
        for entry in try Self.entries() where entry.proof ?? false {
            let url = URL(fileURLWithPath: entry.raw)
            var options = DecodeOptions()
            options.tileSize = RollDeveloper.decodeTile
            options.learnedTileSize = RollDeveloper.learnedDecodeTile
            let develop = try c.decoder.decode(url, options: options)
            let raster = try Self.seed(entry, frameWidth: develop.width, frameHeight: develop.height)
            c.seeds.add(raster)
            let base = try Self.settings(c, url, grain: false)
            let selection = try Self.component(entry.kind, raster, background: false, width: develop.width, height: develop.height)
            var frames: [(String, LinearFrame)] = [("develop", develop)]
            for size in [4912, 2190, 960] where size < max(develop.width, develop.height) {
                let texture = try Self.resizedTexture(c.gpu, c.resize, develop.texture, width: size * develop.width / max(develop.width, develop.height),
                                                      height: size * develop.height / max(develop.width, develop.height))
                frames.append(("\(size)", LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: develop.decoderVersion, scale: 1, picture: develop.picture)))
            }
            for (name, frame) in frames {
                func gpu(_ settings: DevelopSettings) throws -> Double {
                    _ = try c.renderer.render(frame, settings: settings)
                    return try (0..<5).map { _ in try c.renderer.render(frame, settings: settings).gpuSeconds }.min()! * 1000
                }
                let plain = try gpu(base)
                let two = try gpu(try Self.masked(base, selection, exposure: -1.5))
                let one = try gpu(try Self.masked(base, selection, exposure: -1.5, tierOne: true))
                var builds: [Double] = [], guides: [Double] = []
                for _ in 0..<5 {
                    let session = c.gpu.maskRefiner.session(for: frame, picture: try frame.maskPicture)
                    let started = ContinuousClock.now
                    _ = try session.guideFrame()
                    let guided = ContinuousClock.now
                    let seed = try c.gpu.maskRefiner.upload(raster)
                    let built = try c.gpu.maskRefiner.build(seed: seed, guideFrame: try session.guideFrame(),
                                                            parameters: MaskRefineParameters.of(entry.kind == "sky" ? .sky : entry.kind == "person" ? .person : .subject))
                    guides.append(Double((guided - started).components.attoseconds) / 1e15 + Double((guided - started).components.seconds) * 1000)
                    builds.append(built.build.gpuSeconds * 1000)
                }
                let line = String(format: "%@ %@ %@ %dx%d: film %.2f ms, tier 1 +%.2f, tier 2 +%.2f; guide frame %.1f ms wall, coefficients %.2f ms GPU",
                                  entry.stem, entry.kind, name, frame.width, frame.height, plain, one - plain, two - plain,
                                  guides.min()!, builds.min()!)
                print("[refiner] " + line)
                lines.append(line)
            }
            c.gpu.maskRefiner.removeAll()
            c.gpu.maskFields.removeAll()
        }
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: Self.out.appendingPathComponent("cost.txt"), atomically: true, encoding: .utf8)
    }

    /// The plan's per-surface tolerance table (section 4), and the step when the frame view refines (deliverable 4).
    @Test func theSurfacesHoldThePlansTable() throws {
        let c = try Self.context()
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var rows: [Row] = [], steps: [Step] = []
        for entry in try Self.entries() where entry.surfaces ?? false {
            let url = URL(fileURLWithPath: entry.raw)
            var options = DecodeOptions()
            options.tileSize = RollDeveloper.decodeTile
            options.learnedTileSize = RollDeveloper.learnedDecodeTile
            let develop = try c.decoder.decode(url, options: options)
            let raster = try Self.seed(entry, frameWidth: develop.width, frameHeight: develop.height)
            c.seeds.add(raster)
            let base = try Self.settings(c, url, grain: false)
            var adjustments: [(String, MaskComponent, Float)] = [
                ("e-1.5", try Self.component(entry.kind, raster, background: false, width: develop.width, height: develop.height), -1.5),
                ("e+1.5", try Self.component(entry.kind, raster, background: false, width: develop.width, height: develop.height), 1.5),
            ]
            if entry.kind != "sky" {
                adjustments.append(("bg-1.5", try Self.component(entry.kind, raster, background: true, width: develop.width, height: develop.height), -1.5))
            }
            let long = max(develop.width, develop.height)
            // The previews' decodes: the frame view's at 4912 and 2190 where the frame is larger, scaled and refined, and the sheet's.
            struct Preview { let surface: String; let size: Int; let frame: LinearFrame }
            var previews: [Preview] = []
            var sheetOptions = DecodeOptions()
            sheetOptions.maxLongSide = FilmPreviews.previewLongSide
            previews.append(Preview(surface: "sheet", size: 960, frame: try c.decoder.decode(url, options: sheetOptions)))
            for size in [2190, 4912] where size < long {
                let scaled = try c.decoder.decode(url, options: FilmPreviews.frameDecodeOptions(longSide: size))
                previews.append(Preview(surface: "scaled", size: size, frame: scaled))
                let texture = try Self.resizedTexture(c.gpu, c.resize, develop.texture, width: scaled.width, height: scaled.height)
                let refined = LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: develop.decoderVersion,
                                          scale: Float(scaled.width) / Float(develop.width), picture: develop.picture)
                previews.append(Preview(surface: "refined", size: size, frame: refined))
            }
            var plainAt: [String: [Float]] = [:]   // the develop with no mask, resized to each preview's size
            do {
                let developPlain = try Self.render(c.gpu, c.renderer, develop, base, coverage: false).image
                for preview in previews where plainAt["\(preview.frame.width)x\(preview.frame.height)"] == nil {
                    plainAt["\(preview.frame.width)x\(preview.frame.height)"] = Self.lightness(Self.pixels(try Self.resizedTexture(c.gpu, c.resize, developPlain.texture,
                        width: preview.frame.width, height: preview.frame.height)))
                }
            }
            let previewPlain = try previews.map { Self.lightness(Self.pixels(try Self.render(c.gpu, c.renderer, $0.frame, base, coverage: false).image.texture)) }
            for (name, component, exposure) in adjustments {
                let settings = try Self.masked(base, component, exposure: exposure)
                let developed = try Self.render(c.gpu, c.renderer, develop, settings, coverage: true)
                let developCoverage = try #require(developed.coverage)
                var maskedPreviews: [String: [Float]] = [:]
                for (index, preview) in previews.enumerated() {
                    let (w, h) = (preview.frame.width, preview.frame.height)
                    let key = "\(w)x\(h)"
                    let developL = Self.lightness(Self.pixels(try Self.resizedTexture(c.gpu, c.resize, developed.image.texture, width: w, height: h)))
                    let developC = Self.resized(developCoverage, width: develop.width, height: develop.height, toWidth: w, toHeight: h)
                    let edge = Self.band(developC, width: w, height: h)
                    let shown = try Self.render(c.gpu, c.renderer, preview.frame, settings, coverage: true)
                    let previewL = Self.lightness(Self.pixels(shown.image.texture))
                    maskedPreviews["\(preview.surface)\(preview.size)"] = previewL
                    let film = Self.p99(previewPlain[index], try #require(plainAt[key]), in: edge)
                    let mask = Self.p99(previewL, developL, in: edge)
                    let coverage = Self.p99(try #require(shown.coverage), developC, in: edge)
                    let limit = Self.limits(surface: preview.surface, kind: entry.kind)
                    let row = Row(stem: entry.stem, kind: entry.kind, adjustment: name, surface: preview.surface, size: preview.size,
                                  filmP99: film, maskP99: mask, excess: mask - film, coverageP99: coverage,
                                  bandPixels: edge.reduce(0) { $0 + ($1 ? 1 : 0) }, limitExcess: limit.excess, limitCoverage: limit.coverage,
                                  passes: mask - film <= limit.excess && coverage <= limit.coverage)
                    rows.append(row)
                    print("[refiner] \(row)")
                }
                // The step when the frame view refines, and the settle the app already has without a mask.
                for size in [2190, 4912] {
                    guard let scaledIndex = previews.firstIndex(where: { $0.surface == "scaled" && $0.size == size }),
                          let refinedIndex = previews.firstIndex(where: { $0.surface == "refined" && $0.size == size }),
                          let scaledL = maskedPreviews["scaled\(size)"], let refinedL = maskedPreviews["refined\(size)"] else { continue }
                    let preview = previews[refinedIndex].frame
                    let developC = Self.resized(developCoverage, width: develop.width, height: develop.height, toWidth: preview.width, toHeight: preview.height)
                    let edge = Self.band(developC, width: preview.width, height: preview.height)
                    let step = Self.p99(scaledL, refinedL, in: edge), settle = Self.p99(previewPlain[scaledIndex], previewPlain[refinedIndex], in: edge)
                    let made = Step(stem: entry.stem, kind: entry.kind, adjustment: name, size: size, step: step, settle: settle, ratio: step / max(settle, 1e-6))
                    steps.append(made)
                    print("[refiner] \(made)")
                }
            }
            c.gpu.maskRefiner.removeAll()
            c.gpu.maskFields.removeAll()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: Self.out.appendingPathComponent("surfaces.json"))
        try encoder.encode(steps).write(to: Self.out.appendingPathComponent("steps.json"))
        for row in rows {
            #expect(row.passes, "\(row.stem) \(row.adjustment) \(row.surface) \(row.size): excess \(row.excess) (\(row.limitExcess)), coverage \(row.coverageP99) (\(row.limitCoverage))")
        }
        // The step at 4912 px as S3 measured it, the mean step over the mean settle, by kind and adjustment (plan section 4): at most the
        // settle for darkening and background moves, Subject's 1.1 apart; 1.1 to 1.3 for brightening, where S3's Sky was 1.34.
        let grouped = Dictionary(grouping: steps.filter { $0.size == 4912 }) { "\($0.kind) \($0.adjustment)" }
        for (key, group) in grouped {
            let ratio = group.reduce(0) { $0 + $1.step } / max(group.reduce(0) { $0 + $1.settle }, 1e-6)
            let limit: Float = key.hasSuffix("e+1.5") ? 1.35 : key.hasPrefix("subject") ? 1.1 : 1
            print("[refiner] step at 4912, \(key): \(ratio) of the settle over \(group.count) frames (limit \(limit))")
            #expect(ratio <= limit, "\(key): the step is \(ratio) of the settle")
        }
    }
}
