import ArgentCore
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import Testing
@testable import ArgentRoll

/// The fine-detail gap against Lightroom's Raw Details (docs/fine-detail-plan.md, section 4): the
/// arms at full size with lens correction off, and the blind test's crops through the film.
/// `scripts/measure/fine-detail/run.zsh` drives both around `metrics.py`. Runs only with
/// ARGENT_MEASURE=1, one test at a time:
///
///     FINE_DETAIL_RAWS=<dir of raws> FINE_DETAIL_OUT=<dir> ARGENT_MEASURE=1 swift test -c release \
///         -Xswiftc -enable-testing --skip-build --filter FineDetailMeasureTests/<test>
///
/// FINE_DETAIL_FILES limits a run to the raws whose names it lists, comma separated.
@Suite(.serialized) struct FineDetailMeasureTests {
    static var enabled: Bool { FrameViewMeasureTests.enabled }
    static let environment = ProcessInfo.processInfo.environment

    /// The raws in FINE_DETAIL_RAWS, by name, limited to FINE_DETAIL_FILES when it is set.
    static func raws() throws -> [URL] {
        let folder = URL(fileURLWithPath: try #require(environment["FINE_DETAIL_RAWS"], "FINE_DETAIL_RAWS"))
        let only = environment["FINE_DETAIL_FILES"].map { Set($0.split(separator: ",").map(String.init)) }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "arw" }
            .filter { only == nil || only!.contains($0.lastPathComponent) || only!.contains($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static var output: URL { URL(fileURLWithPath: environment["FINE_DETAIL_OUT"] ?? NSTemporaryDirectory() + "fine-detail") }

    /// Lightroom's Enhanced DNG beside `raw`, `<name>-Enhanced-RD.dng` in any case.
    static func enhanced(beside raw: URL) -> URL? {
        let stem = raw.deletingPathExtension().lastPathComponent.lowercased() + "-enhanced-rd.dng"
        let folder = raw.deletingLastPathComponent()
        return (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.lowercased() == stem }
    }

    static func write(_ texture: MTLTexture, to url: URL) throws {
        try ExposureAnalyzer.pixels(of: texture).withUnsafeBytes { try Data($0).write(to: url) }
    }

    /// Lightroom's linear DNG through Core Image with every control off, so only Adobe's demosaic
    /// acts: no noise or moire reduction, sharpening, boost or lens correction; D55 as Argent pins it.
    /// Levels and colour are left to `metrics.py`, which fits the result to R9.
    static func decodeEnhanced(_ url: URL, gpu: GPU) throws -> (texture: PooledTexture, notes: [String: String]) {
        try autoreleasepool {
            guard let filter = CIRAWFilter(imageURL: url) else { throw DecodeError.unsupportedFile(url) }
            // The classic DNG path, first, as `configure` sets the version first: Core Image also offers
            // RAW 9's network on DNGs ("9.dng"), which would denoise Adobe's pixels.
            let versions = filter.supportedDecoderVersions
            if let classic = ["8.dng", "8"].map(CIRAWDecoderVersion.init(rawValue:)).first(where: versions.contains) {
                filter.decoderVersion = classic
            }
            let orientation = filter.orientation
            filter.orientation = .up
            filter.boostAmount = 0
            filter.boostShadowAmount = 0
            filter.isGamutMappingEnabled = false
            filter.baselineExposure = 0
            filter.shadowBias = 0
            filter.exposure = 0
            filter.isHighlightRecoveryEnabled = true
            filter.extendedDynamicRangeAmount = 1
            filter.neutralChromaticity = CGPoint(x: AppleRawDecoder.daylightNeutral.x, y: AppleRawDecoder.daylightNeutral.y)
            filter.isLensCorrectionEnabled = false
            filter.isDraftModeEnabled = false
            filter.scaleFactor = 1
            if filter.isSharpnessSupported { filter.sharpnessAmount = 0 }
            if filter.isContrastSupported { filter.contrastAmount = 0 }
            if filter.isDetailSupported { filter.detailAmount = 0 }
            if filter.isMoireReductionSupported { filter.moireReductionAmount = 0 }
            if filter.isLuminanceNoiseReductionSupported { filter.luminanceNoiseReductionAmount = 0 }
            if filter.isColorNoiseReductionSupported { filter.colorNoiseReductionAmount = 0 }
            let notes = ["decoderVersion": filter.decoderVersion.rawValue,
                         "supportedVersions": filter.supportedDecoderVersions.map(\.rawValue).joined(separator: " "),
                         "nativeSize": "\(Int(filter.nativeSize.width))x\(Int(filter.nativeSize.height))",
                         "orientation": "\(orientation.rawValue)"]
            guard let image = filter.outputImage?.oriented(orientation) else { throw DecodeError.noOutput(url) }
            let extent = image.extent.integral
            let texture = try gpu.texturePool.acquire(width: Int(extent.width), height: Int(extent.height))
            guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
            gpu.makeContext().render(image, to: texture.texture, commandBuffer: commandBuffer, bounds: extent,
                                     colorSpace: gpu.workingColorSpace)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error { throw error }
            return (texture, notes)
        }
    }

    /// Each raw's arms as RGBA half floats in linear Rec. 2020, rows as the frame texture holds them:
    /// R9 and R8 as a develop decodes them (RAW 9 in 1024-pixel tiles, RAW 8 in 768) with lens
    /// correction off, and Lightroom's Enhanced DNG beside the raw when there is one. A raw RAW 9 does
    /// not take (lossless M and S) gets R8 alone. Writes `<out>/<name>/` with `meta.json`.
    @Test(.enabled(if: Self.enabled))
    func arms() throws {
        let gpu = try GPU(maxIdlePoolBytes: 1 << 30)
        let decoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        for raw in try Self.raws() {
            try autoreleasepool {
                let folder = Self.output.appendingPathComponent(raw.deletingPathExtension().lastPathComponent)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var arms: [String: [String: Any]] = [:]
                var line = raw.lastPathComponent
                var iso: Float?
                for (name, version, tile) in [("r9", AppleDecoderVersion.learned, RollDeveloper.learnedDecodeTile),
                                              ("r8", AppleDecoderVersion.classic, RollDeveloper.decodeTile)] {
                    var options = DecodeOptions()
                    options.appleDecoder = version
                    options.lensCorrection = false
                    options.tileSize = RollDeveloper.decodeTile
                    options.learnedTileSize = tile
                    let frame: LinearFrame
                    do {
                        frame = try decoder.decode(raw, options: options)
                    } catch DecodeError.versionUnsupported {
                        line += ", \(name) not offered"
                        continue
                    }
                    try Self.write(frame.texture, to: folder.appendingPathComponent("\(name).f16"))
                    arms[name] = ["width": frame.width, "height": frame.height, "decoderVersion": frame.decoderVersion,
                                  "tile": frame.pins?.tileSize ?? 0,
                                  "luminanceNoiseReduction": frame.pins?.luminanceNoiseReduction ?? -1]
                    line += ", \(name) \(frame.width)x\(frame.height)"
                }
                if let filter = CIRAWFilter(imageURL: raw) { iso = AppleRawDecoder.isoSpeed(of: filter) }
                var lrdFile: String?
                if let dng = Self.enhanced(beside: raw) {
                    let (texture, notes) = try Self.decodeEnhanced(dng, gpu: gpu)
                    try Self.write(texture.texture, to: folder.appendingPathComponent("lrd.f16"))
                    var entry: [String: Any] = ["width": texture.width, "height": texture.height]
                    for (k, v) in notes { entry[k] = v }
                    arms["lrd"] = entry
                    lrdFile = dng.path
                    line += ", lrd \(texture.width)x\(texture.height) (\(notes["decoderVersion"] ?? "?"))"
                }
                let meta: [String: Any] = ["raw": raw.path, "iso": iso.map { Double($0) } ?? NSNull(),
                                           "lrdFile": lrdFile ?? NSNull(), "arms": arms]
                try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
                    .write(to: folder.appendingPathComponent("meta.json"))
                print(line)
            }
        }
    }

    /// The blind test's crops: every arm `metrics.py` left in a frame's folder, put through the film
    /// as the app develops it, and cut at the blocks `blocks.json` names. The film is
    /// FINE_DETAIL_STOCK (default Portra 400, the app's first). Auto's placement and lab balance come
    /// from R9's 960-pixel decode, as the app measures, for a frame alone. Every arm gets the frame's
    /// own grain seed at natural grain, the stock's halation and capture sharpening. The print goes
    /// through the develop's encoder into sRGB and is written as PNGs, `crops/<arm>-<block>.png`.
    @Test(.enabled(if: Self.enabled))
    func crops() throws {
        let gpu = try GPU(maxIdlePoolBytes: 1 << 30)
        let decoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let stockName = Self.environment["FINE_DETAIL_STOCK"] ?? "kodak-portra-400"
        let stock = try Stock.load(from: FrameViewMeasureTests.root.appendingPathComponent("build/stocks/\(stockName)"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let encoder = try ImageEncoder(gpu: gpu)
        for raw in try Self.raws() {
            try autoreleasepool {
                let folder = Self.output.appendingPathComponent(raw.deletingPathExtension().lastPathComponent)
                let blocksURL = folder.appendingPathComponent("blocks.json")
                guard FileManager.default.fileExists(atPath: blocksURL.path) else { return }
                let blocks = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: blocksURL)) as? [[String: Any]])
                let meta = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("meta.json"))) as? [String: Any])
                let arms = try #require(meta["arms"] as? [String: [String: Any]])

                var options = DecodeOptions()
                options.appleDecoder = .learned
                options.maxLongSide = 960
                let sheet: LinearFrame
                do {
                    sheet = try decoder.decode(raw, options: options)
                } catch DecodeError.versionUnsupported {
                    // Lossless M and S: the app measures them from RAW 8.
                    options.appleDecoder = .classic
                    sheet = try decoder.decode(raw, options: options)
                }
                let info = try ARWFrameInfo.read(from: raw)
                let analysis = ExposureAnalyzer.analyze(sheet, workingSpace: gpu.workingColorSpace, info: info)
                var settings = RollControls().settings(for: stock, analysis: analysis)
                settings.grain = OutputSettings.Grain.natural.amount
                settings.grainSeed = GrainModel.seed(name: raw.lastPathComponent, captureDate: info.captureDate)
                settings.halation = stock.halation != nil
                settings.sharpen = true

                let cropFolder = folder.appendingPathComponent("crops")
                try FileManager.default.createDirectory(at: cropFolder, withIntermediateDirectories: true)
                var written: [String] = []
                for arm in ["r9", "r8", "r9r8c", "lrdfit"] {
                    try autoreleasepool {
                        let file = folder.appendingPathComponent("\(arm).f16")
                        guard let size = arms[arm], FileManager.default.fileExists(atPath: file.path),
                              let width = size["width"] as? Int, let height = size["height"] as? Int else { return }
                        let data = try Data(contentsOf: file)
                        try #require(data.count == width * height * 8, "\(arm): \(data.count) bytes for \(width)x\(height)")
                        let texture = try gpu.texturePool.acquire(width: width, height: height)
                        data.withUnsafeBytes {
                            texture.texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                                    withBytes: $0.baseAddress!, bytesPerRow: width * 8)
                        }
                        let frame = LinearFrame(image: texture, decoderVersion: AppleRawDecoder.learnedDecoderVersion, scale: 1)
                        let print = try renderer.render(frame, settings: settings, inPlace: true).image
                        let picture = try encoder.picture(print.texture, colorSpace: gpu.workingColorSpace, format: .jpeg(quality: 0.92), space: .sRGB)
                        for (k, block) in blocks.enumerated() {
                            let x = try #require(block["x"] as? Int), y = try #require(block["y"] as? Int)
                            let side = try #require(block["size"] as? Int)
                            // Block rows are the texture's, bottom up; the picture's run top down.
                            let rect = CGRect(x: x, y: picture.height - y - side, width: side, height: side)
                            let cg = try #require(picture.cropping(to: rect))
                            let url = cropFolder.appendingPathComponent("\(arm)-\(k).png")
                            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                            CGImageDestinationAddImage(destination, cg, nil)
                            #expect(CGImageDestinationFinalize(destination))
                        }
                        written.append(arm)
                    }
                }
                print(raw.lastPathComponent, "crops of", written.joined(separator: " "), String(format: "level %+.2f", AutoPrint.levelStops(analysis)))
            }
        }
    }
}
