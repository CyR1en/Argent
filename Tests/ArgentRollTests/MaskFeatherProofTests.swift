import Foundation
import Metal
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// A smart selection's Feather on real frames and real seeds through the film (decision 19; task K's proof). The frames and seeds are
/// private: read where they lie, and nothing of them enters Git. It runs only when asked:
///
///     ARGENT_MEASURE=1 ARGENT_FEATHER_FRAMES=<manifest.json> ARGENT_FEATHER_OUT=<folder> [ARGENT_FEATHER_VALUES=0,25,50,100] \
///       swift test -c release -Xswiftc -enable-testing --filter MaskFeatherProofTests
///
/// The manifest is `MaskRefinerSurfaceTests`'s; the frames marked `proof` are rendered. Sky takes Exposure −1.5 EV, Person and Subject
/// +0.7 EV, through Portra 400 with Auto's settings, halation, sharpening and grain, at each Feather.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] != nil
                             && ProcessInfo.processInfo.environment["ARGENT_FEATHER_FRAMES"] != nil))
struct MaskFeatherProofTests {
    typealias Surface = MaskRefinerSurfaceTests
    static let environment = ProcessInfo.processInfo.environment
    static var out: URL { URL(fileURLWithPath: environment["ARGENT_FEATHER_OUT"] ?? NSTemporaryDirectory() + "argent-feather") }
    static var feathers: [Float] {
        (environment["ARGENT_FEATHER_VALUES"] ?? "0,25,50,100").split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func entries() throws -> [Surface.Entry] {
        let url = URL(fileURLWithPath: try #require(environment["ARGENT_FEATHER_FRAMES"]))
        return try JSONDecoder().decode([Surface.Entry].self, from: Data(contentsOf: url)).filter { $0.proof ?? false }
    }

    static func exposure(_ kind: String) -> Float { kind == "sky" ? -1.5 : 0.7 }

    static func feathered(_ component: MaskComponent, _ feather: Float) -> MaskComponent {
        guard case .smart(var selection) = component.shape else { return component }
        selection.feather = feather
        return MaskComponent(operation: component.operation, shape: .smart(selection), invert: component.invert)
    }

    static func name(_ feather: Float) -> String { String(format: "f%03.0f", feather) }

    static func decodeFull(_ c: Surface.Context, _ url: URL) throws -> LinearFrame {
        var options = DecodeOptions()
        options.tileSize = RollDeveloper.decodeTile
        options.learnedTileSize = RollDeveloper.learnedDecodeTile
        return try c.decoder.decode(url, options: options)
    }

    /// Each frame at each Feather: the whole frame at fit (1800 px on the long side), 640 × 480 windows at 100 % where the edge is
    /// densest (for a person, the top of the head first), the coverage there, and the unmasked frame for reference. Which tier each
    /// render took goes in `look.txt`.
    @Test func theLook() throws {
        let c = try Surface.context()
        let folder = Self.out.appendingPathComponent("look")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var log = ""
        for entry in try Self.entries() {
            let url = URL(fileURLWithPath: entry.raw)
            let frame = try Self.decodeFull(c, url)
            let raster = try Surface.seed(entry, frameWidth: frame.width, frameHeight: frame.height)
            c.seeds.add(raster)
            let base = try Surface.settings(c, url, grain: true)
            let selection = try Surface.component(entry.kind, raster, background: false, width: frame.width, height: frame.height)
            let exposure = Self.exposure(entry.kind)
            let long = max(frame.width, frame.height), fit = 1800
            let (fitWidth, fitHeight) = (frame.width * fit / long, frame.height * fit / long)
            // The windows from Feather 0's coverage, so every Feather is seen at the same places.
            let zero = try Surface.render(c.gpu, c.renderer, frame, try Surface.masked(base, selection, exposure: exposure), coverage: true)
            let coverageZero = try #require(zero.coverage)
            var chosen = Surface.windows(coverageZero, width: frame.width, height: frame.height, count: 2)
            if entry.kind != "sky", let head = Surface.top(coverageZero, width: frame.width, height: frame.height) { chosen.insert(head, at: 0) }
            log += "\(entry.stem) \(entry.kind) \(frame.width)x\(frame.height) \(exposure) EV windows \(chosen)\n"
            func save(_ texture: MTLTexture, _ suffix: String) throws {
                let small = try Surface.resizedTexture(c.gpu, c.resize, texture, width: fitWidth, height: fitHeight)
                try Surface.crop(c.gpu, small, x: 0, y: 0, width: fitWidth, height: fitHeight,
                                 to: folder.appendingPathComponent("\(entry.stem)_fit_\(suffix).png"))
                for (index, (x, y)) in chosen.enumerated() {
                    try Surface.crop(c.gpu, texture, x: x, y: y, width: 640, height: 480,
                                     to: folder.appendingPathComponent("\(entry.stem)_w\(index)_\(suffix).png"))
                }
            }
            try save(try Surface.render(c.gpu, c.renderer, frame, base, coverage: false).image.texture, "plain")
            for feather in Self.feathers {
                let settings = try Surface.masked(base, Self.feathered(selection, feather), exposure: exposure)
                let rendered = try Surface.render(c.gpu, c.renderer, frame, settings, coverage: true)
                try save(rendered.image.texture, Self.name(feather))
                let coverage = try #require(rendered.coverage)
                for (index, (x, y)) in chosen.enumerated() {
                    try Surface.crop(coverage: coverage, width: frame.width, height: frame.height, x: x, y: y, w: 640, h: 480,
                                     to: folder.appendingPathComponent("\(entry.stem)_w\(index)_\(Self.name(feather))_coverage.png"))
                }
                let stock = c.renderer.stock
                let scene = try c.renderer.sceneInputs(frame, settings: settings, exposureStops: settings.exposureStops(boxSpeed: stock.boxSpeed),
                                                       printOffset: settings.printOffset(densityRange: stock.densityRange,
                                                                                         exposurePerUnit: stock.exposurePerUnit)).scene
                let tier = scene.masks?.refinement.refined == 0 ? 1 : 2
                let line = "\(entry.stem) feather \(feather) sigma \(MaskFeather.sigma(feather)) long sides (\(MaskFeather.sigma(feather) * Float(long)) px) tier \(tier)"
                print("[feather] " + line)
                log += line + "\n"
                #expect(tier == (feather > 0 ? 1 : 2), "\(line)")
            }
            c.gpu.maskRefiner.removeAll()
            c.gpu.maskFields.removeAll()
        }
        try log.write(to: folder.appendingPathComponent("look.txt"), atomically: true, encoding: .utf8)
    }

    struct Row: Codable {
        var stem: String
        var kind: String
        /// "feather N", or "gradient": a linear gradient of the same adjustment down the frame, the plan's reference for 0.1 L*.
        var mask: String
        var feather: Float
        var surface: String
        var size: Int
        var tier: Int
        /// Band p99 |ΔL*|, preview against the develop resized, with the mask and without; `excess` the first less the second.
        var maskP99: Float
        var filmP99: Float
        var excess: Float
        /// The same over every pixel.
        var allMaskP99: Float
        var allFilmP99: Float
        var allExcess: Float
        var coverageP99: Float
        var bandPixels: Int
    }

    /// Preview against develop for a feathered selection (deliverable 4), by `MaskRefinerSurfaceTests`' method, grain off: the frame
    /// view's refined and scaled decodes at 4912 and 2190 and the sheet's 960, each refined on its own decode, against the full-size
    /// develop area-resized. The band is the develop's coverage between 0.02 and 0.98, dilated 6 px; the excess is the mask's band
    /// p99 less the film's alone. Written to `preview.json`; nothing is asserted here (the core suite holds the gate on a phantom).
    @Test func thePreviewAgainstTheDevelop() throws {
        let c = try Surface.context()
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var rows: [Row] = []
        func p99All(_ a: [Float], _ b: [Float]) -> Float { Surface.p99(a, b, in: [Bool](repeating: true, count: a.count)) }
        for entry in try Self.entries() {
            let url = URL(fileURLWithPath: entry.raw)
            let develop = try Self.decodeFull(c, url)
            let raster = try Surface.seed(entry, frameWidth: develop.width, frameHeight: develop.height)
            c.seeds.add(raster)
            let base = try Surface.settings(c, url, grain: false)
            let selection = try Surface.component(entry.kind, raster, background: false, width: develop.width, height: develop.height)
            let long = max(develop.width, develop.height)
            struct Preview { let surface: String; let size: Int; let frame: LinearFrame }
            var previews: [Preview] = []
            var sheetOptions = DecodeOptions()
            sheetOptions.maxLongSide = FilmPreviews.previewLongSide
            previews.append(Preview(surface: "sheet", size: 960, frame: try c.decoder.decode(url, options: sheetOptions)))
            for size in [2190, 4912] where size < long {
                let scaled = try c.decoder.decode(url, options: FilmPreviews.frameDecodeOptions(longSide: size))
                previews.append(Preview(surface: "scaled", size: size, frame: scaled))
                let texture = try Surface.resizedTexture(c.gpu, c.resize, develop.texture, width: scaled.width, height: scaled.height)
                previews.append(Preview(surface: "refined", size: size, frame: LinearFrame(image: PooledTexture(unpooled: texture),
                    decoderVersion: develop.decoderVersion, scale: Float(scaled.width) / Float(develop.width), picture: develop.picture)))
            }
            var plainAt: [String: [Float]] = [:]
            do {
                let developPlain = try Surface.render(c.gpu, c.renderer, develop, base, coverage: false).image
                for preview in previews where plainAt["\(preview.frame.width)x\(preview.frame.height)"] == nil {
                    plainAt["\(preview.frame.width)x\(preview.frame.height)"] = Surface.lightness(Surface.pixels(try Surface.resizedTexture(c.gpu, c.resize,
                        developPlain.texture, width: preview.frame.width, height: preview.frame.height)))
                }
            }
            let previewPlain = try previews.map { Surface.lightness(Surface.pixels(try Surface.render(c.gpu, c.renderer, $0.frame, base, coverage: false).image.texture)) }
            let extent = try MaskSpace(width: develop.width, height: develop.height).extent
            let gradient = MaskComponent(shape: .linear(.init(full: MaskPoint(x: extent.x / 2, y: 0.15 * extent.y), zero: MaskPoint(x: extent.x / 2, y: 0.6 * extent.y))))
            let cases: [(String, Float, MaskComponent)] = [("gradient", -1, gradient)]
                + Self.feathers.map { ("feather \(Int($0))", $0, Self.feathered(selection, $0)) }
            for (name, feather, component) in cases {
                let settings = try Surface.masked(base, component, exposure: Self.exposure(entry.kind))
                let developed = try Surface.render(c.gpu, c.renderer, develop, settings, coverage: true)
                let developCoverage = try #require(developed.coverage)
                for (index, preview) in previews.enumerated() {
                    let (w, h) = (preview.frame.width, preview.frame.height)
                    let developL = Surface.lightness(Surface.pixels(try Surface.resizedTexture(c.gpu, c.resize, developed.image.texture, width: w, height: h)))
                    let developC = Surface.resized(developCoverage, width: develop.width, height: develop.height, toWidth: w, toHeight: h)
                    let edge = Surface.band(developC, width: w, height: h)
                    let shown = try Surface.render(c.gpu, c.renderer, preview.frame, settings, coverage: true)
                    let previewL = Surface.lightness(Surface.pixels(shown.image.texture))
                    let plain = try #require(plainAt["\(w)x\(h)"])
                    let stock = c.renderer.stock
                    let scene = try c.renderer.sceneInputs(preview.frame, settings: settings, exposureStops: settings.exposureStops(boxSpeed: stock.boxSpeed),
                                                           printOffset: settings.printOffset(densityRange: stock.densityRange,
                                                                                             exposurePerUnit: stock.exposurePerUnit)).scene
                    let mask = Surface.p99(previewL, developL, in: edge), film = Surface.p99(previewPlain[index], plain, in: edge)
                    let allMask = p99All(previewL, developL), allFilm = p99All(previewPlain[index], plain)
                    let row = Row(stem: entry.stem, kind: entry.kind, mask: name, feather: feather, surface: preview.surface, size: preview.size,
                                  tier: scene.masks?.refinement.refined == 0 ? 1 : 2, maskP99: mask, filmP99: film, excess: mask - film,
                                  allMaskP99: allMask, allFilmP99: allFilm, allExcess: allMask - allFilm,
                                  coverageP99: Surface.p99(try #require(shown.coverage), developC, in: edge),
                                  bandPixels: edge.reduce(0) { $0 + ($1 ? 1 : 0) })
                    rows.append(row)
                    print("[feather] \(row)")
                }
            }
            c.gpu.maskRefiner.removeAll()
            c.gpu.maskFields.removeAll()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: Self.out.appendingPathComponent("preview.json"))
    }
}
