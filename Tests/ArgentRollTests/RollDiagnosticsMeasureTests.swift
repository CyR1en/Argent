import ArgentCore
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ArgentRoll

/// Stage 1 of docs/auto-exposure-consistency-plan.md, reproduce and classify: what makes neighbouring
/// frames print at visibly different brightness today, before anything changes. Each frame is measured
/// the two ways the app can measure it, from the sheet's own 960-pixel decode (`FilmPreviews`' direct
/// decode) and from the frame view's decode area-resized to 960; its aim is taken apart into the fitted
/// placement's terms, smoothed with the whole roll measured and with the frames arriving in seeded
/// random orders, as `RollModel.analyses` smooths them; and it is rendered through the production
/// renderer. Each neighbouring and skip-one pair is then lined up by `DiagnosticMatcher`, and a pair it
/// calls the same subject in the same light has its matched region's rendered difference taken apart
/// into the camera's exposure change the print did not undo, placement responding to framing and to
/// faces, smoothing, and what the stock's curve adds. Runs only with ARGENT_MEASURE=1:
///
///     ARGENT_MEASURE=1 ARGENT_DIAGNOSE_ROLL=<folder of raws> ARGENT_DIAGNOSE_OUT=<folder> \
///       swift test -c release -Xswiftc -enable-testing --skip-build --filter RollDiagnosticsMeasureTests
///     ARGENT_MEASURE=1 ARGENT_DIAGNOSE_OUT=<folder> ARGENT_CUBEPP_COHORT=docs/research/auto/gate-protocol/cubepp-cohort-2234.txt \
///       swift test -c release -Xswiftc -enable-testing --skip-build --filter RollDiagnosticsMeasureTests
///
/// `rollDiagnostics` runs with ARGENT_DIAGNOSE_ROLL, and `cubeppDiagnostics` with ARGENT_CUBEPP_COHORT
/// and without it, so the two never write into one folder. Each writes report.json, pairs.csv and
/// summary.md; the roll also its contact sheets and a tile a frame under frames/.
///
/// The roll is read and never written: its stock and controls come from its newest recipe when it has
/// sidecars, read beside the raws (`RestoredRoll`), and Portra 400 on Auto at box speed otherwise.
/// ARGENT_DIAGNOSE_ORDERS sets the arrival orders (20), ARGENT_DIAGNOSE_FRAME_SIDE the frame view's
/// decode (2560 pixels, a typical window) and ARGENT_DIAGNOSE_CHECK how many frames are measured again
/// through `FilmPreviews` itself to show the replica is the app's measurement (2). Everything written
/// is derived from the photographs: the output folder must lie outside the repository and the roll.
@Suite(.serialized) struct RollDiagnosticsMeasureTests {
    typealias G = GateMeasureTests
    typealias L = LabBalanceMeasureTests
    typealias M = FrameViewMeasureTests
    typealias S = SeriesMeasureTests

    /// The matcher's same-subject, same-light test: correlation, overlap, and light changed by at most
    /// this many stops once the camera's exposure change is taken out (the probe's thresholds).
    static let linkCorrelation = 0.8
    static let linkOverlap = 0.3
    static let linkLight = 0.5
    /// On Cube++ the best alignment of two different scenes sits near the smallest overlap allowed, and
    /// half the frame or more separates same light from changed light far better (`cubeppDiagnostics`):
    /// reported beside the link as its strict form.
    static let strictOverlap = 0.5
    /// A visible jump: a linked pair's matched region printed more than this many L* apart, about
    /// 0.15 scene stop at mid-gray on the Portras (docs/research/film-sim/print.md, section 4).
    static let jumpLightness = 3.0
    /// A frame whose shown aim moved more than this from its final one while the roll was measured.
    static let loadingRisk: Float = 0.1
    /// A frame whose two decode routes give aims further apart than this.
    static let routeRisk: Float = 0.05
    /// Half the step, in scene stops, over which a region's print slope is taken.
    static let slopeStep: Float = 0.125

    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// The frame view's decode for a typical window: `FilmPreviews.frameDecodeSide` of a picture 2560
    /// pixels long.
    static var frameViewSide: Int {
        FilmPreviews.frameDecodeSide(forPixels: Int(environment["ARGENT_DIAGNOSE_FRAME_SIDE"] ?? "") ?? 2560)
    }

    /// ARGENT_DIAGNOSE_OUT, made if need be; refused inside the repository or any of `refusing`.
    static func outputFolder(refusing folders: [URL]) throws -> URL {
        let out = URL(fileURLWithPath: try #require(environment["ARGENT_DIAGNOSE_OUT"], "ARGENT_DIAGNOSE_OUT names the output folder"))
        let path = out.canonicalPath + "/"
        for folder in [M.root] + folders {
            try #require(!path.hasPrefix(folder.canonicalPath + "/"), "write diagnostics outside \(folder.path)")
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    // MARK: Records

    struct Header: Codable {
        var file: String
        var model: String
        var captureDate: String?
        var secondsSincePrevious: Double?
        var sceneEV100: Double?
        var exposureTime: Double?
        var fNumber: Double?
        var iso: Int?
        var flash: Bool?
    }

    /// A measurement and the aim `FittedPlacement` makes of it.
    struct AnalysisRecord: Codable {
        var width: Int
        var height: Int
        var meanStops: Double
        var validWeight: Double
        var faces: Int
        var faceArea: Double
        var asShotTemperature: Double?
        var aim: Double
        var histogram: [Double]
    }

    /// The frame view's measurement against the sheet's.
    struct Route: Codable {
        var measurement: AnalysisRecord
        var deltaMeanStops: Double
        var histogramDistance: Double?
        var deltaAim: Double
    }

    /// `FittedPlacement`'s features and each coefficient's term, and the terms summed: the whole
    /// frame's (intercept to dark), the faces' (`faceWeight`, `faceOffset`, `faceFrameLevel`), the raw
    /// aim and the bounded one.
    struct Placement: Codable {
        var features: [String: Double]
        var terms: [String: Double]
        var wholeFrame: Double
        var faces: Double
        var raw: Double
        var aim: Double
    }

    struct Face: Codable {
        var box: [Double]
        var area: Double
        var levelStops: Double
        /// `skinArea / area`; `nil` with the fallback.
        var skinShare: Double?
        /// Too little skin: the level is the whole inset's.
        var fallback: Bool
    }

    struct Rule: Codable {
        var value: Double?
        var fired: Bool
    }

    /// Each of `RollSmoothing.splits`' rules against the previous frame, on its own.
    struct Split: Codable {
        var time: Rule
        var ev: Rule
        var flash: Rule
        var whiteBalance: Rule
        var histogram: Rule
        var splits: Bool

        var fired: [String] {
            [("time", time), ("EV", ev), ("flash", flash), ("WB", whiteBalance), ("hist", histogram)].filter(\.1.fired).map(\.0)
        }
    }

    /// The aim shown while the roll was being measured, over the arrival orders.
    struct Loading: Codable {
        var orders: Int
        /// The aim first shown, in each order.
        var firstShown: [Double]
        var changesMean: Double
        var changesMax: Int
        /// The largest |shown − final| over every order.
        var maxDeviation: Double
        /// The same in capture order, as the low-priority sweep queues the roll.
        var captureOrderChanges: Int
        var captureOrderMaxDeviation: Double
    }

    struct Lightness: Codable {
        var whole: Double
        var face: Double?
    }

    /// Mean L* of the 960 decode rendered at the final aim and at the frame's own: with halation and
    /// sharpening off, and as `DevelopmentResolver.resolve` sets them; grain off in both.
    struct Rendered: Codable {
        var final: Lightness
        var independent: Lightness
        var productionFinal: Lightness
        var productionIndependent: Lightness
    }

    /// What the frame's sidecar says, read and not written.
    struct RecipeNote: Codable {
        var stock: String
        var controls: String
        var currentAnalysis: Bool
        var analysisAim: Double?
        var printLevel: Double?
        var manual: Bool
    }

    /// The replica against `FilmPreviews.measurement` itself.
    struct Check: Codable {
        var sheetIdentical: Bool
        var sheetDeltaAim: Double?
        var frameViewIdentical: Bool
        var frameViewDeltaAim: Double?
    }

    struct FrameRecord: Codable {
        var index: Int
        var name: String
        var header: Header
        var controls: String
        var decoder: String
        var sheet: AnalysisRecord
        var frameView: Route
        var placement: Placement
        var faces: [Face]
        var independentAim: Double
        var finalAim: Double
        var cast: [Double]
        var smoothing: Double
        var cluster: Int
        var clusterSize: Int
        var split: Split?
        var loading: Loading
        var rendered: Rendered
        var recipe: RecipeNote?
        var check: Check?
    }

    struct MatchRecord: Codable {
        var correlation: Double
        var overlap: Double
        var scale: Double
        var translation: [Double]
        var cells: Int
        var inliers: Int
        /// Median log2 luminance of frame j less frame i over aligned cells, and its MAD.
        var shift: Double
        var mad: Double
        /// `shift` less the camera's exposure change; positive when the scene got brighter.
        var light: Double?
        /// The matched cells' mean L* in each frame at its final aim, and the difference.
        var regionLightness: [Double]
        var deltaRegionLightness: Double
        var deltaRegionLightnessIndependent: Double
        /// The region's L* per stop of print aim, negative: a higher aim prints darker.
        var slope: Double
    }

    /// m = (a_j − a_i) − d taken apart. `terms` as the aims are built: the whole frame's and the
    /// faces' terms of the independent aim, its bound, smoothing, the camera's exposure change and the
    /// light's (each as it enters m). `counterfactual` against frame i re-exposed by d: what the aim
    /// does when only the exposure changes (`exposureNotFollowed`, zero for a placement that undid it),
    /// what it does for the rest of the difference, frame then faces, and smoothing. `contributions`
    /// are those in L* (slope × term) with what rendering adds beyond the slope.
    struct Attribution: Codable {
        var mismatch: Double
        var terms: [String: Double]
        var counterfactual: [String: Double]
        var contributions: [String: Double]
        var remainder: Double
        var cause: String
    }

    struct PairRecord: Codable {
        var kind: String
        var i: Int
        var j: Int
        var from: String
        var to: String
        var seconds: Double?
        var deltaEV: Double?
        var deltaAim: Double
        var deltaAimIndependent: Double
        var deltaWholeLightness: Double
        var deltaWholeLightnessIndependent: Double
        var sameCluster: Bool
        var split: Split?
        var match: MatchRecord?
        var linked: Bool
        var jump: Bool
        var attribution: Attribution?
        var loadingRisk: Bool
        var routeRisk: Bool
    }

    struct Report: Codable {
        var roll: String
        var stock: String
        var controls: String
        var controlsFrom: String
        var overrides: Int
        var decoderRoute: String
        var frameViewSide: Int
        var orders: Int
        var thresholds: [String: Double]
        var frames: [FrameRecord]
        var pairs: [PairRecord]
    }

    // MARK: The roll

    /// What one frame's measurement keeps for the rest of the run.
    struct Measured {
        var frame: Frame
        var sheet: LinearFrame
        var analysis: ExposureAnalysis
        var frameView: ExposureAnalysis
        var frameViewSize: (Int, Int)
        var grid: ExposureAnalyzer.Grid
        var map: DiagnosticMatcher.Map
    }

    @Test(.enabled(if: FrameViewMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_DIAGNOSE_ROLL"] != nil))
    func rollDiagnostics() async throws {
        let folder = URL(fileURLWithPath: try #require(Self.environment["ARGENT_DIAGNOSE_ROLL"]))
        let out = try Self.outputFolder(refusing: [folder])
        let orders = Int(Self.environment["ARGENT_DIAGNOSE_ORDERS"] ?? "") ?? 20
        let side = Self.frameViewSide
        let roll = await RollScanner.scan(folder)
        try #require(!roll.frames.isEmpty, "no readable raws in \(folder.path)")

        // The stock and controls the roll was left with, from its sidecars; nothing is written.
        let recipes = roll.frames.map { frame -> Recipe? in
            guard let data = try? Data(contentsOf: RecipeStore.besideRaw(frame.url)), let recipe = Recipe.decoded(data),
                  recipe.raw.fileName == frame.url.lastPathComponent else { return nil }
            return recipe
        }
        let restored = RestoredRoll(frames: roll.frames, recipes: recipes)
        let stocks = StockLibrary.load(from: M.root.appendingPathComponent("build/stocks")).stocks
        let stock = try #require(stocks.first { $0.id == restored.stockID ?? "kodak-portra-400" }, "the roll's stock is baked")
        let rollControls = restored.controls ?? RollControls()
        func controls(_ frame: Frame) -> RollControls { restored.overrides[frame.url]?.applied(to: rollControls) ?? rollControls }
        func describe(_ c: RollControls) -> String { "\(c.ratedAt.title), \(c.labBalance.title)" }
        print("DIAGNOSE \(roll.name): \(roll.frames.count) frames, \(stock.displayName) (\(stock.id)), \(describe(rollControls)), "
              + "\(restored.overrides.count) frames with their own controls, from \(recipes.compactMap { $0 }.count) recipes")

        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let choices = DecoderChoices()
        let decoder = ChosenDecoder(gpu: gpu, choices: choices, contextPerDecode: true, inHouseAtOnce: FilmPreviews.inHouseDecodesAtOnce)
        let resize = try AreaResize(gpu: gpu)
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let digest = stock.digest

        // 1. Each frame measured from the sheet's decode and from the frame view's.
        var measured: [Measured] = []
        for frame in roll.frames {
            let one = try autoreleasepool { try Self.measure(frame, side: side, decoder: decoder, resize: resize, gpu: gpu) }
            measured.append(one)
        }
        let frames = roll.frames
        let analyses = Dictionary(uniqueKeysWithValues: measured.map { ($0.frame.url, $0.analysis) })
        let aims = RollSmoothing.aims(frames, analyses: analyses)
        var clusterOf: [URL: (Int, Int)] = [:]
        for (index, cluster) in RollSmoothing.clusters(frames, analyses: analyses).enumerated() {
            for frame in cluster { clusterOf[frame.url] = (index, cluster.count) }
        }
        let loading = Self.loading(frames, analyses: analyses, final: aims, orders: orders)

        // 2. Each frame rendered at its final aim and at its own.
        var records: [FrameRecord] = []
        var tiles: [CGImage?] = []
        let tileFolder = out.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: tileFolder, withIntermediateDirectories: true)
        for (index, m) in measured.enumerated() {
            let frame = m.frame, own = controls(frame)
            let final = try #require(aims[frame.url])
            let independent = PrintAim(level: AutoPrint.levelStops(m.analysis), cast: AutoBalance.cast(m.analysis))
            let record: FrameRecord = try autoreleasepool {
                func lightness(_ settings: DevelopSettings, tile: Bool = false) throws -> Lightness {
                    let pixels = ExposureAnalyzer.pixels(of: try renderer.render(m.sheet, settings: settings).image.texture)
                    let face = m.analysis.faces.max { $0.area < $1.area }
                    if tile {
                        let image = Self.tile(pixels, width: m.sheet.width, height: m.sheet.height, gpu: gpu, longSide: 320)
                        tiles.append(image)
                        if let image { try Self.writePNG(image, to: tileFolder.appendingPathComponent("\(frame.name).png")) }
                    }
                    return Lightness(whole: G.measure(pixels, width: m.sheet.width, height: m.sheet.height).lightness,
                                     face: face.map { G.measure(pixels, width: m.sheet.width, height: m.sheet.height, box: $0.box).lightness })
                }
                func production(_ aim: PrintAim) throws -> DevelopSettings {
                    try DevelopmentResolver.resolve(stock: stock, stockDigest: digest, controls: own, aim: aim, manual: nil,
                                                    grain: 0, grainSeed: frame.grainSeed, sharpen: true)
                }
                let rendered = Rendered(final: try lightness(own.settings(for: stock, aim: final)),
                                        independent: try lightness(own.settings(for: stock, aim: independent)),
                                        productionFinal: try lightness(try production(final), tile: true),
                                        productionIndependent: try lightness(try production(independent)))
                let previous = index > 0 ? frames[index - 1] : nil
                let cluster = clusterOf[frame.url] ?? (-1, 0)
                return FrameRecord(
                    index: index, name: frame.name, header: Self.header(frame, previous: previous), controls: describe(own),
                    decoder: "\(DecoderChoice.of(m.sheet).rawValue) \(m.sheet.decoderVersion)",
                    sheet: Self.analysisRecord(m.analysis, width: m.sheet.width, height: m.sheet.height),
                    frameView: Self.route(m.frameView, size: m.frameViewSize, against: m.analysis),
                    placement: Self.placement(m.analysis), faces: m.analysis.faces.map(Self.face),
                    independentAim: Double(independent.level), finalAim: Double(final.level), cast: [Double(final.cast.x), Double(final.cast.y), Double(final.cast.z)],
                    smoothing: Double(final.level - independent.level), cluster: cluster.0, clusterSize: cluster.1,
                    split: previous.map { Self.split($0, frame, analyses: analyses) }, loading: loading[index], rendered: rendered,
                    recipe: recipes[index].map(Self.note), check: nil)
            }
            records.append(record)
        }
        for record in records.dropFirst() {
            if let split = record.split { #expect(split.splits == !split.fired.isEmpty, "each rule alone agrees with RollSmoothing.splits") }
        }

        // 3. The replica against the app's own measurement, a few frames, both routes.
        let checked = min(frames.count, Int(Self.environment["ARGENT_DIAGNOSE_CHECK"] ?? "") ?? 2)
        if checked > 0 {
            let sheetFilms = try FilmPreviews(stocks: []), frameFilms = try FilmPreviews(stocks: [])
            for index in 0..<checked {
                let viaSheet = await sheetFilms.measurement(frames[index])?.analysis
                // Since stage 4 the app measures from the sheet's decode alone: with the frame view's
                // decode held first, it still gives the sheet's measurement, not the replica's path (c).
                _ = await frameFilms.frameNeutral(frames[index], lens: .default, pixels: side)
                let viaFrame = await frameFilms.measurement(frames[index])?.analysis
                let m = measured[index]
                records[index].check = Check(
                    sheetIdentical: viaSheet == m.analysis,
                    sheetDeltaAim: viaSheet.map { Double(AutoPrint.levelStops($0) - AutoPrint.levelStops(m.analysis)) },
                    frameViewIdentical: viaFrame == m.analysis,
                    frameViewDeltaAim: viaFrame.map { Double(AutoPrint.levelStops($0) - AutoPrint.levelStops(m.analysis)) })
            }
        }

        // 4. Neighbouring and skip-one pairs.
        var pairs: [PairRecord] = []
        for (kind, gap) in [("neighbour", 1), ("skip", 2)] where frames.count > gap {
            for j in gap..<frames.count {
                pairs.append(Self.pair(kind, measured[j - gap], measured[j], records[j - gap], records[j], stock: stock,
                                       controls: (controls(frames[j - gap]), controls(frames[j])),
                                       aims: (aims[frames[j - gap].url]!, aims[frames[j].url]!)))
            }
        }

        // 5. What was found, written outside the repository.
        let report = Report(roll: folder.path, stock: "\(stock.displayName) (\(stock.id))", controls: describe(rollControls),
                            controlsFrom: restored.controls == nil ? "default (no recipe)" : "newest of \(recipes.compactMap { $0 }.count) recipes",
                            overrides: restored.overrides.count, decoderRoute: "\(choices.route)", frameViewSide: side, orders: orders,
                            thresholds: ["linkCorrelation": Self.linkCorrelation, "linkOverlap": Self.linkOverlap, "linkLight": Self.linkLight,
                                         "jumpLightness": Self.jumpLightness, "loadingRisk": Double(Self.loadingRisk),
                                         "routeRisk": Double(Self.routeRisk)],
                            frames: records, pairs: pairs)
        try Self.encoder.encode(report).write(to: out.appendingPathComponent("report.json"))
        try Self.csv(pairs).write(to: out.appendingPathComponent("pairs.csv"), atomically: true, encoding: .utf8)
        try Self.contactSheets(records, pairs: pairs, tiles: tiles, title: roll.name, to: out)
        let summary = Self.summary(report)
        try summary.write(to: out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        print(summary)
    }

    /// `frame` decoded and measured as the sheet measures it (`FilmPreviews`' direct decode, path (a)),
    /// and as the frame view's decode of `side` pixels area-resized to the sheet's size measures it
    /// (path (c)), with the sheet's analysis grid rebuilt for the matcher.
    static func measure(_ frame: Frame, side: Int, decoder: ChosenDecoder, resize: AreaResize, gpu: GPU) throws -> Measured {
        var options = DecodeOptions()
        options.maxLongSide = FilmPreviews.previewLongSide
        let sheet = try decoder.decode(frame.url, options: options)
        let analysis = ExposureAnalyzer.analyze(sheet, workingSpace: gpu.workingColorSpace, info: frame.info)
        let noise = DecodedNoise.appleDecode(model: frame.info.model, iso: frame.info.iso, pins: sheet.pins)
        let grid = ExposureAnalyzer.grid(pixels: ExposureAnalyzer.pixels(of: sheet.texture), width: sheet.width,
                                         height: sheet.height, noise: noise)
        let large = try decoder.decode(frame.url, options: FilmPreviews.frameDecodeOptions(longSide: side))
        let size = (large.width, large.height)
        let scaled = try downscaled(large, longSide: FilmPreviews.previewLongSide, resize: resize)
        let frameView = ExposureAnalyzer.analyze(scaled, workingSpace: gpu.workingColorSpace, info: frame.info)
        return Measured(frame: frame, sheet: sheet, analysis: analysis, frameView: frameView, frameViewSize: size,
                        grid: grid, map: DiagnosticMatcher.map(grid))
    }

    /// `FilmPreviews.downscaled`: area-resized so its longer side is `longSide`, still scene-linear.
    static func downscaled(_ frame: LinearFrame, longSide: Int, resize: AreaResize) throws -> LinearFrame {
        let scale = Double(longSide) / Double(max(frame.width, frame.height))
        guard scale < 1 else { return frame }
        let texture = try withExtendedLifetime(frame) { try resize.resized(frame.texture, scale: scale) }
        return LinearFrame(image: texture, decoderVersion: frame.decoderVersion, scale: frame.scale * Float(scale),
                           pins: frame.pins, readback: frame.readback)
    }

    static func header(_ frame: Frame, previous: Frame?) -> Header {
        let info = frame.info
        var since: Double?
        if let a = previous?.info.captureDate, let b = info.captureDate { since = b.timeIntervalSince(a) }
        return Header(file: frame.url.lastPathComponent, model: info.model,
                      captureDate: info.captureDate.map { ISO8601DateFormatter.string(from: $0, timeZone: .gmt, formatOptions: [.withInternetDateTime, .withFractionalSeconds]) },
                      secondsSincePrevious: since, sceneEV100: info.sceneEV100, exposureTime: info.exposureTime,
                      fNumber: info.fNumber, iso: info.iso, flash: info.flashFired)
    }

    static func analysisRecord(_ a: ExposureAnalysis, width: Int, height: Int) -> AnalysisRecord {
        AnalysisRecord(width: width, height: height, meanStops: Double(a.meanStops), validWeight: Double(a.validWeight),
                    faces: a.faces.count, faceArea: Double(a.faceArea), asShotTemperature: a.asShotTemperature.map(Double.init),
                    aim: Double(AutoPrint.levelStops(a)), histogram: a.histogram.map(Double.init))
    }

    static func route(_ a: ExposureAnalysis, size: (Int, Int), against sheet: ExposureAnalysis) -> Route {
        Route(measurement: analysisRecord(a, width: size.0, height: size.1), deltaMeanStops: Double(a.meanStops - sheet.meanStops),
              histogramDistance: sheet.histogramDistance(to: a).map(Double.init),
              deltaAim: Double(AutoPrint.levelStops(a) - AutoPrint.levelStops(sheet)))
    }

    static let featureNames = ["intercept", "level", "reach", "faceWeight", "faceOffset", "faceFrameLevel"]

    /// `FittedPlacement`'s terms of `a`: each coefficient times its feature.
    static func terms(_ a: ExposureAnalysis) -> [Float] {
        zip(FittedPlacement.coefficients, FittedPlacement.Features(a).vector).map { $0 * $1 }
    }

    static func placement(_ a: ExposureAnalysis) -> Placement {
        let vector = FittedPlacement.Features(a).vector, t = terms(a)
        return Placement(features: Dictionary(uniqueKeysWithValues: zip(featureNames, vector.map(Double.init))),
                         terms: Dictionary(uniqueKeysWithValues: zip(featureNames, t.map(Double.init))),
                         wholeFrame: Double(t[..<7].reduce(0, +)), faces: Double(t[7...].reduce(0, +)),
                         raw: Double(t.reduce(0, +)), aim: Double(FittedPlacement.aim(a)))
    }

    static func face(_ f: FaceMeasure) -> Face {
        Face(box: f.box.map(Double.init), area: Double(f.area), levelStops: Double(f.levelStops),
             skinShare: f.skinArea.map { f.area > 0 ? Double($0 / f.area) : 0 }, fallback: f.skin == nil)
    }

    static func note(_ recipe: Recipe) -> RecipeNote {
        RecipeNote(stock: recipe.stock.id, controls: "\(recipe.roll.ratedAt.title), \(recipe.roll.labBalance.title)",
                   currentAnalysis: recipe.analysis?.isCurrent ?? false,
                   analysisAim: recipe.analysis.map { Double(AutoPrint.levelStops($0)) },
                   printLevel: recipe.printLevel.map(Double.init), manual: recipe.manual != nil)
    }

    /// `RollSmoothing.splits`' rules between `last` and `next`, each on its own.
    static func split(_ last: Frame, _ next: Frame, analyses: [URL: ExposureAnalysis]) -> Split {
        var seconds: Double?
        if let a = last.info.captureDate, let b = next.info.captureDate { seconds = abs(b.timeIntervalSince(a)) }
        var ev: Double?
        if let x = last.info.sceneEV100, let y = next.info.sceneEV100 { ev = abs(x - y) }
        var flash: Double?
        if let x = last.info.flashFired, let y = next.info.flashFired { flash = x == y ? 0 : 1 }
        let p = analyses[last.url], q = analyses[next.url]
        var mired: Double?
        if let x = p?.asShotTemperature, let y = q?.asShotTemperature, x > 0, y > 0 { mired = Double(abs(1e6 / x - 1e6 / y)) }
        let histogram = p.flatMap { a in q.flatMap { a.histogramDistance(to: $0) } }.map(Double.init)
        return Split(time: Rule(value: seconds, fired: seconds.map { $0 > RollSmoothing.timeGap } ?? true),
                     ev: Rule(value: ev, fired: (ev ?? 0) > RollSmoothing.evJump),
                     flash: Rule(value: flash, fired: flash == 1),
                     whiteBalance: Rule(value: mired, fired: (mired ?? 0) > Double(RollSmoothing.whiteBalanceMired)),
                     histogram: Rule(value: histogram, fired: (histogram ?? 0) > Double(RollSmoothing.histogramDistance)),
                     splits: RollSmoothing.splits(last, next, analyses: analyses))
    }

    /// SplitMix64, so the arrival orders are the same on every run.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// The fixed seeds of the arrival orders.
    static func seeds(_ count: Int) -> [UInt64] { (0..<count).map { 0x5EED_0000 &+ UInt64($0) &* 7919 } }

    /// `frames`' indices in an order drawn from `seed` (Fisher-Yates).
    static func order(_ count: Int, seed: UInt64) -> [Int] {
        var generator = SeededGenerator(state: seed), order = Array(0..<count)
        for i in stride(from: count - 1, to: 0, by: -1) {
            order.swapAt(i, Int(generator.next() % UInt64(i + 1)))
        }
        return order
    }

    /// Each frame's shown aim while `analyses` arrive in `order`, the roll smoothed after each arrival
    /// as `RollModel.analyses.didSet` smooths it: how often it moved after it was first shown, the
    /// most it lay from `final`, and what was first shown.
    static func arrivals(_ frames: [Frame], analyses: [URL: ExposureAnalysis], final: [URL: PrintAim],
                         order: [Int]) -> (changes: [Int], deviation: [Float], first: [Float]) {
        var arrived: [URL: ExposureAnalysis] = [:]
        var shown = [Float?](repeating: nil, count: frames.count)
        var changes = [Int](repeating: 0, count: frames.count), deviation = [Float](repeating: 0, count: frames.count)
        var first = [Float](repeating: .nan, count: frames.count)
        for index in order {
            arrived[frames[index].url] = analyses[frames[index].url]
            let aims = RollSmoothing.aims(frames, analyses: arrived)
            for (k, frame) in frames.enumerated() {
                guard let level = aims[frame.url]?.level, let settled = final[frame.url]?.level else { continue }
                if let last = shown[k] {
                    if abs(level - last) > 1e-5 { changes[k] += 1 }
                } else {
                    first[k] = level
                }
                shown[k] = level
                deviation[k] = max(deviation[k], abs(level - settled))
            }
        }
        return (changes, deviation, first)
    }

    static func loading(_ frames: [Frame], analyses: [URL: ExposureAnalysis], final: [URL: PrintAim], orders: Int) -> [Loading] {
        let runs = seeds(orders).map { arrivals(frames, analyses: analyses, final: final, order: order(frames.count, seed: $0)) }
        let sweep = arrivals(frames, analyses: analyses, final: final, order: Array(frames.indices))
        return frames.indices.map { k in
            let changes = runs.map { $0.changes[k] }
            return Loading(orders: orders, firstShown: runs.map { Double($0.first[k]) },
                           changesMean: Double(changes.reduce(0, +)) / Double(max(orders, 1)), changesMax: changes.max() ?? 0,
                           maxDeviation: Double(runs.map { $0.deviation[k] }.max() ?? 0),
                           captureOrderChanges: sweep.changes[k], captureOrderMaxDeviation: Double(sweep.deviation[k]))
        }
    }

    // MARK: Pairs

    /// `rgb`, scene-linear, printed through `stock` with `settings` on the CPU as the render graph's
    /// LUT passes print it without halation, sharpening or grain: the rating's exposure, the Negative
    /// LUT, the print offset, the Print LUT; its L* (`GateMeasureTests.lightness`).
    static func printedLightness(_ rgb: SIMD3<Float>, _ settings: DevelopSettings, stock: Stock) -> Double {
        let encoding = stock.negative.encoding
        let exposed = GamutCompression.compress(rgb * exp2(settings.exposureStops(boxSpeed: stock.boxSpeed)))
        let dyes = stock.negative.sample(encoded: SIMD3(encoding.encode(exposed.x), encoding.encode(exposed.y), encoding.encode(exposed.z)))
        let offset = settings.printOffset(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
        let printed = stock.print.sample(encoded: (dyes + offset).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1)))
        return G.lightness(Double((printed * Rec2020.luma).sum()))
    }

    /// The mean printed L* of `cells` with `settings`.
    static func regionLightness(_ cells: [SIMD3<Float>], _ settings: DevelopSettings, stock: Stock) -> Double {
        G.mean(cells.map { printedLightness($0, settings, stock: stock) })
    }

    /// `analysis`' grid as if the camera had given it `stops` more exposure, measured again with its
    /// faces metered over the same boxes: the frame's own content at the other frame's exposure.
    static func reexposed(_ grid: ExposureAnalyzer.Grid, faces: [FaceMeasure], by stops: Float) -> ExposureAnalysis {
        var g = grid
        let scale = exp2(stops)
        for k in g.light.indices {
            g.light[k] *= scale
            g.all[k] *= scale
        }
        var analysis = ExposureAnalyzer.analyze(grid: g)
        let boxes = faces.map { CGRect(x: CGFloat($0.box[0]), y: CGFloat($0.box[1]), width: CGFloat($0.box[2]), height: CGFloat($0.box[3])) }
        analysis.faces = FaceMeter.meter(boxes, grid: g)
        return analysis
    }

    static func pair(_ kind: String, _ a: Measured, _ b: Measured, _ ra: FrameRecord, _ rb: FrameRecord, stock: Stock,
                     controls: (RollControls, RollControls), aims: (PrintAim, PrintAim)) -> PairRecord {
        let ia = PrintAim(level: AutoPrint.levelStops(a.analysis), cast: AutoBalance.cast(a.analysis))
        let ib = PrintAim(level: AutoPrint.levelStops(b.analysis), cast: AutoBalance.cast(b.analysis))
        var seconds: Double?
        if let x = a.frame.info.captureDate, let y = b.frame.info.captureDate { seconds = y.timeIntervalSince(x) }
        var deltaEV: Double?
        if let x = a.frame.info.sceneEV100, let y = b.frame.info.sceneEV100 { deltaEV = y - x }
        var record = PairRecord(
            kind: kind, i: ra.index, j: rb.index, from: ra.name, to: rb.name, seconds: seconds, deltaEV: deltaEV,
            deltaAim: Double(aims.1.level - aims.0.level), deltaAimIndependent: Double(ib.level - ia.level),
            deltaWholeLightness: rb.rendered.productionFinal.whole - ra.rendered.productionFinal.whole,
            deltaWholeLightnessIndependent: rb.rendered.productionIndependent.whole - ra.rendered.productionIndependent.whole,
            sameCluster: ra.cluster == rb.cluster, split: kind == "neighbour" ? rb.split : nil, match: nil, linked: false,
            jump: false, attribution: nil,
            loadingRisk: max(ra.loading.maxDeviation, rb.loading.maxDeviation) > Double(loadingRisk),
            routeRisk: max(abs(ra.frameView.deltaAim), abs(rb.frameView.deltaAim)) > Double(routeRisk))
        guard let match = DiagnosticMatcher.match(a.map, b.map) else { return record }
        let cellsA = match.inliers.map(\.0), cellsB = match.inliers.map(\.1)
        func settings(_ c: RollControls, _ aim: PrintAim, _ by: Float = 0) -> DevelopSettings {
            c.settings(for: stock, aim: PrintAim(level: aim.level + by, cast: aim.cast))
        }
        let la = regionLightness(cellsA, settings(controls.0, aims.0), stock: stock)
        let lb = regionLightness(cellsB, settings(controls.1, aims.1), stock: stock)
        let independent = regionLightness(cellsB, settings(controls.1, ib), stock: stock)
            - regionLightness(cellsA, settings(controls.0, ia), stock: stock)
        let h = slopeStep
        let slopeA = (regionLightness(cellsA, settings(controls.0, aims.0, h), stock: stock)
            - regionLightness(cellsA, settings(controls.0, aims.0, -h), stock: stock)) / Double(2 * h)
        let slopeB = (regionLightness(cellsB, settings(controls.1, aims.1, h), stock: stock)
            - regionLightness(cellsB, settings(controls.1, aims.1, -h), stock: stock)) / Double(2 * h)
        let slope = (slopeA + slopeB) / 2
        let camera = deltaEV.map { -$0 }
        let light = camera.map { Double(match.shift) - $0 }
        record.match = MatchRecord(correlation: match.alignment.correlation, overlap: match.alignment.overlap,
                                   scale: Double(match.alignment.scale),
                                   translation: [Double(match.alignment.tx), Double(match.alignment.ty)],
                                   cells: match.cells, inliers: match.inliers.count, shift: Double(match.shift),
                                   mad: Double(match.mad), light: light, regionLightness: [la, lb], deltaRegionLightness: lb - la,
                                   deltaRegionLightnessIndependent: independent, slope: slope)
        record.linked = match.alignment.correlation >= linkCorrelation && match.alignment.overlap >= linkOverlap
            && light.map { abs($0) <= linkLight } ?? false
        record.jump = record.linked && abs(lb - la) > jumpLightness
        guard record.linked, let camera, let light else { return record }

        // m = (a_j − a_i) − d, as the aims are built.
        let d = match.shift
        let mismatch = Double(aims.1.level - aims.0.level - d)
        let ta = terms(a.analysis), tb = terms(b.analysis)
        let whole = Double(tb[..<7].reduce(0, +) - ta[..<7].reduce(0, +))
        let faces = Double(tb[7...].reduce(0, +) - ta[7...].reduce(0, +))
        let clamp = Double((ib.level - tb.reduce(0, +)) - (ia.level - ta.reduce(0, +)))
        let smoothing = Double((aims.1.level - ib.level) - (aims.0.level - ia.level))
        // Against frame i re-exposed by d: what the aim did for the exposure alone, and for the rest.
        let shifted = reexposed(a.grid, faces: a.analysis.faces, by: d)
        let ts = terms(shifted), shiftedAim = AutoPrint.levelStops(shifted)
        let notFollowed = Double(shiftedAim - ia.level - d)
        let framingFaces = Double(tb[7...].reduce(0, +) - ts[7...].reduce(0, +))
        let framingWhole = Double(ib.level - shiftedAim) - framingFaces
        let counterfactual = ["exposureNotFollowed": notFollowed, "framingWhole": framingWhole, "framingFaces": framingFaces,
                              "smoothing": smoothing]
        let remainder = (lb - la) - slope * mismatch
        var contributions = counterfactual.mapValues { slope * $0 }
        contributions["rendering"] = remainder
        record.attribution = Attribution(
            mismatch: mismatch,
            terms: ["wholeFrame": whole, "faces": faces, "clamp": clamp, "smoothing": smoothing, "camera": -camera, "light": -light],
            counterfactual: counterfactual, contributions: contributions, remainder: remainder,
            cause: cause(contributions, delta: lb - la))
        return record
    }

    static let causeNames = ["exposureNotFollowed": "exposure not followed", "framingWhole": "framing (whole frame)",
                             "framingFaces": "faces", "smoothing": "smoothing", "rendering": "rendering"]

    /// The largest contribution with the difference's sign, or the largest of all when none has it.
    static func cause(_ contributions: [String: Double], delta: Double) -> String {
        let sorted = contributions.sorted { abs($0.value) > abs($1.value) || (abs($0.value) == abs($1.value) && $0.key < $1.key) }
        let key = sorted.first { $0.value * delta > 0 }?.key ?? sorted.first?.key ?? "rendering"
        return causeNames[key] ?? key
    }

    // MARK: Output

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    static func f(_ x: Double?, _ digits: Int = 2) -> String {
        guard let x, x.isFinite else { return "" }
        return String(format: "%+.\(digits)f", x)
    }

    static func csv(_ pairs: [PairRecord]) -> String {
        var lines = ["kind,from,to,seconds,dEV,dAim,dAimIndependent,dWholeL,ncc,overlap,shift,mad,light,dRegionL,dRegionLIndependent,"
                     + "slope,linked,jump,mismatch,exposureNotFollowed,framingWhole,framingFaces,smoothing,remainderL,cause,loadingRisk,routeRisk,splitRules"]
        for p in pairs {
            let m = p.match, a = p.attribution
            let fields: [String] = [
                p.kind, p.from, p.to, f(p.seconds, 1), f(p.deltaEV), f(p.deltaAim, 3), f(p.deltaAimIndependent, 3), f(p.deltaWholeLightness),
                f(m?.correlation, 3), f(m?.overlap, 3), f(m?.shift, 3), f(m?.mad, 3), f(m?.light, 3), f(m?.deltaRegionLightness),
                f(m?.deltaRegionLightnessIndependent), f(m?.slope), "\(p.linked)", "\(p.jump)", f(a?.mismatch, 3),
                f(a?.counterfactual["exposureNotFollowed"], 3), f(a?.counterfactual["framingWhole"], 3),
                f(a?.counterfactual["framingFaces"], 3), f(a?.counterfactual["smoothing"], 3), f(a?.remainder), a?.cause ?? "",
                "\(p.loadingRisk)", "\(p.routeRisk)", p.split?.fired.joined(separator: "+") ?? "",
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The tile of display-linear working-space `pixels` (rows from the bottom), its longer side
    /// `longSide`, in sRGB.
    static func tile(_ pixels: [Float16], width: Int, height: Int, gpu: GPU, longSide: Int) -> CGImage? {
        let data = pixels.withUnsafeBytes { Data($0) }
        let scale = Double(longSide) / Double(max(width, height))
        let image = CIImage(bitmapData: data, bytesPerRow: width * 8, size: CGSize(width: width, height: height),
                            format: .RGBAh, colorSpace: gpu.workingColorSpace)
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(height)))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
        let extent = CGRect(x: 0, y: 0, width: (Double(width) * scale).rounded(), height: (Double(height) * scale).rounded())
        return gpu.ciContext.createCGImage(image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination), "wrote \(url.lastPathComponent)")
    }

    static func draw(_ text: String, at point: CGPoint, in context: CGContext, color: CGColor) {
        let font = CTFontCreateWithName("Menlo" as CFString, 11, nil)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                         NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
    }

    /// Contact sheets of the frames in capture order, 48 to a sheet, each tile labelled with its name,
    /// cluster, aims, the split that fired from the previous frame, its whole-frame L*, and the matched
    /// region's L* against the previous frame with the attributed cause when that is a jump.
    static func contactSheets(_ records: [FrameRecord], pairs: [PairRecord], tiles: [CGImage?], title: String, to out: URL) throws {
        let columns = 6, rows = 8, cellWidth = 336, imageHeight = 224, labelHeight = 66, margin = 16, heading = 28
        let neighbours = Dictionary(pairs.filter { $0.kind == "neighbour" }.map { ($0.j, $0) }, uniquingKeysWith: { a, _ in a })
        let perSheet = columns * rows
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let text = CGColor(gray: 0.9, alpha: 1), alert = CGColor(srgbRed: 1, green: 0.45, blue: 0.3, alpha: 1)
        for sheet in 0..<((records.count + perSheet - 1) / perSheet) {
            let range = (sheet * perSheet)..<min(records.count, (sheet + 1) * perSheet)
            let used = (range.count + columns - 1) / columns
            let width = margin * 2 + columns * cellWidth, height = heading + margin * 2 + used * (imageHeight + labelHeight)
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 0.16, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            draw("\(title)  frames \(range.lowerBound + 1)-\(range.upperBound) of \(records.count)", at: CGPoint(x: margin, y: height - margin - 12),
                 in: context, color: text)
            for (slot, index) in range.enumerated() {
                let record = records[index]
                let x = margin + slot % columns * cellWidth
                let top = heading + margin + slot / columns * (imageHeight + labelHeight)
                if let image = tiles[index] {
                    let scale = min(Double(cellWidth - 12) / Double(image.width), Double(imageHeight - 8) / Double(image.height))
                    let w = Double(image.width) * scale, h = Double(image.height) * scale
                    context.interpolationQuality = .high
                    context.draw(image, in: CGRect(x: Double(x) + (Double(cellWidth - 12) - w) / 2, y: Double(height - top - imageHeight + 4),
                                                   width: w, height: h))
                }
                let split = record.split.map { $0.fired.isEmpty ? "joined" : "split " + $0.fired.joined(separator: "+") } ?? "start"
                // A long name keeps its frame number: "ILCE-7M4_DSC06673_FullFrame-…" from the camera's own part.
                var name = record.name
                if name.count > 24, let underscore = name.firstIndex(of: "_") { name = String(name[name.index(after: underscore)...]) }
                if name.count > 24 { name = name.prefix(23) + "…" }
                var lines: [(String, CGColor)] = [
                    ("\(name)  c\(record.cluster)  \(split)", text),
                    ("a0 \(f(record.independentAim))  a \(f(record.finalAim))  L* \(String(format: "%.1f", record.rendered.productionFinal.whole))", text),
                ]
                if let p = neighbours[index], let m = p.match {
                    let line = "dL*rgn \(f(m.deltaRegionLightness, 1)) ncc \(String(format: "%.2f", m.correlation)) l \(f(m.light, 2))"
                    lines.append((line, p.jump ? alert : text))
                    if let a = p.attribution, p.jump { lines.append(("jump: \(a.cause)", alert)) }
                }
                for (k, line) in lines.enumerated() {
                    draw(line.0, at: CGPoint(x: x, y: height - top - imageHeight - 14 - k * 14), in: context, color: line.1)
                }
            }
            let image = try #require(context.makeImage())
            try writePNG(image, to: out.appendingPathComponent(String(format: "contact-%02d.png", sheet + 1)))
        }
    }

    /// Median, 90th percentile and largest of `values`' magnitudes, or of `values` with `signed`.
    static func spread(_ values: [Double], signed: Bool = false) -> String {
        let s = (signed ? values : values.map(abs)).filter(\.isFinite).sorted()
        guard let last = s.last else { return "–" }
        return String(format: "%.2f / %.2f / %.2f", G.median(s), s[min(s.count - 1, Int(0.9 * Double(s.count)))], last)
    }

    static func sd(_ values: [Double]) -> Double {
        let mean = G.mean(values)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(values.count - 1, 1))).squareRoot()
    }

    static func summary(_ report: Report) -> String {
        let frames = report.frames, pairs = report.pairs
        var md = "# Exposure jumps: \(URL(fileURLWithPath: report.roll).lastPathComponent)\n\n"
        md += "\(frames.count) frames from `\(report.roll)`, \(report.stock), \(report.controls) (\(report.controlsFrom); "
        md += "\(report.overrides) frames with their own controls). Decoder route \(report.decoderRoute); frame view decode "
        md += "\(report.frameViewSide) px; \(report.orders) seeded arrival orders. Linked: diagnostic matcher NCC ≥ \(linkCorrelation), "
        md += "overlap ≥ \(linkOverlap), |l| ≤ \(linkLight); jump: linked and matched-region |ΔL*| > \(jumpLightness).\n\n"

        md += "## Pairs\n\n| | neighbours | skip-one |\n|---|---|---|\n"
        let kinds = ["neighbour", "skip"]
        func row(_ name: String, _ value: (String) -> String) { md += "| \(name) | \(value(kinds[0])) | \(value(kinds[1])) |\n" }
        func of(_ kind: String) -> [PairRecord] { pairs.filter { $0.kind == kind } }
        row("pairs") { "\(of($0).count)" }
        row("aligned at all") { "\(of($0).filter { $0.match != nil }.count)" }
        row("linked (same subject, same light)") { "\(of($0).filter(\.linked).count)" }
        row("jumps") { "\(of($0).filter(\.jump).count)" }
        row("linked with overlap ≥ \(strictOverlap)") { "\(of($0).filter { $0.linked && ($0.match?.overlap ?? 0) >= strictOverlap }.count)" }
        row("jumps with overlap ≥ \(strictOverlap)") { "\(of($0).filter { $0.jump && ($0.match?.overlap ?? 0) >= strictOverlap }.count)" }
        row("linked: matched-region \\|ΔL*\\| median / p90 / max") { spread(of($0).filter(\.linked).compactMap { $0.match?.deltaRegionLightness }) }
        row("linked: same at independent aims") { spread(of($0).filter(\.linked).compactMap { $0.match?.deltaRegionLightnessIndependent }) }
        row("linked: \\|Δ final aim\\|") { spread(of($0).filter(\.linked).map(\.deltaAim)) }
        row("all: whole-frame \\|ΔL*\\|") { spread(of($0).map(\.deltaWholeLightness)) }
        row("unlinked with whole-frame \\|ΔL*\\| > 3") { "\(of($0).filter { !$0.linked && abs($0.deltaWholeLightness) > jumpLightness }.count)" }
        row("linked but split by RollSmoothing") { "\(of($0).filter { $0.linked && !$0.sameCluster }.count)" }

        md += "\n## Jumps by attributed cause\n\nThe cause is the largest contribution in L* with the jump's sign "
        md += "(counterfactual against frame i re-exposed by the matched shift d).\n\n| cause | neighbours | skip-one |\n|---|---|---|\n"
        for cause in ["exposure not followed", "framing (whole frame)", "faces", "smoothing", "rendering"] {
            row(cause) { kind in "\(of(kind).filter { $0.jump && $0.attribution?.cause == cause }.count)" }
        }
        row("jumps with loading-state risk") { "\(of($0).filter { $0.jump && $0.loadingRisk }.count)" }
        row("jumps with decode-route risk") { "\(of($0).filter { $0.jump && $0.routeRisk }.count)" }
        let linked = pairs.filter { $0.linked && $0.attribution != nil }
        let total = linked.map { pow($0.match!.deltaRegionLightness, 2) }.reduce(0, +)
        if total > 0 {
            md += "\nShare of linked pairs' ΔL*² by cause (projection, both kinds, n = \(linked.count)): "
            md += ["exposureNotFollowed", "framingWhole", "framingFaces", "smoothing", "rendering"].map { key in
                let share = linked.map { ($0.attribution!.contributions[key] ?? 0) * $0.match!.deltaRegionLightness }.reduce(0, +) / total
                return "\(causeNames[key]!) \(String(format: "%.0f%%", share * 100))"
            }.joined(separator: ", ") + ".\n"
        }

        md += "\n## Worst ten linked pairs\n\n| pair | Δt s | ΔEV | Δa | Δa0 | d | l | region ΔL* | whole ΔL* | m | exposure | framing | faces | smoothing | rendering | cause | risk |\n"
        md += "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for p in linked.sorted(by: { abs($0.match!.deltaRegionLightness) > abs($1.match!.deltaRegionLightness) }).prefix(10) {
            let m = p.match!, a = p.attribution!, c = a.contributions
            let risk = [p.loadingRisk ? "loading" : nil, p.routeRisk ? "route" : nil].compactMap { $0 }.joined(separator: "+")
            md += "| \(p.from)→\(p.to) | \(f(p.seconds, 1)) | \(f(p.deltaEV)) | \(f(p.deltaAim)) | \(f(p.deltaAimIndependent)) | \(f(m.shift)) | "
            md += "\(f(m.light)) | \(f(m.deltaRegionLightness, 1)) | \(f(p.deltaWholeLightness, 1)) | \(f(a.mismatch)) | "
            md += "\(f(c["exposureNotFollowed"], 1)) | \(f(c["framingWhole"], 1)) | \(f(c["framingFaces"], 1)) | \(f(c["smoothing"], 1)) | "
            md += "\(f(c["rendering"], 1)) | \(a.cause) | \(risk) |\n"
        }

        let splits = frames.compactMap(\.split)
        md += "\n## Clusters and splits\n\n"
        let sizes = Dictionary(grouping: frames, by: \.cluster).values.map(\.count).sorted(by: >)
        md += "\(sizes.count) clusters; sizes \(sizes.prefix(20).map { "\($0)" }.joined(separator: ", "))\(sizes.count > 20 ? ", …" : ""). "
        md += "Neighbour splits by rule (a split can fire several): " + ["time", "EV", "flash", "WB", "hist"].map { rule in
            "\(rule) \(splits.filter { $0.fired.contains(rule) }.count)"
        }.joined(separator: ", ") + " of \(splits.count).\n"
        let linkedNeighbours = of("neighbour").filter(\.linked)
        md += "Linked neighbours split: \(linkedNeighbours.filter { $0.split?.splits == true }.count) of \(linkedNeighbours.count) ("
        md += ["time", "EV", "flash", "WB", "hist"].map { rule in
            "\(rule) \(linkedNeighbours.filter { $0.split?.fired.contains(rule) == true }.count)"
        }.joined(separator: ", ") + ").\n"

        md += "\n## Decode route: sheet decode against the frame view's \(report.frameViewSide)-pixel decode area-resized\n\n"
        let route = frames.map { abs($0.frameView.deltaAim) }
        md += "|Δ aim| median / p90 / max \(spread(route)); frames over \(routeRisk): \(route.filter { $0 > Double(routeRisk) }.count) of \(frames.count). "
        md += "|Δ meanStops| \(spread(frames.map(\.frameView.deltaMeanStops))); histogram distance \(spread(frames.compactMap(\.frameView.histogramDistance))); "
        md += "face count differs on \(frames.filter { $0.frameView.measurement.faces != $0.sheet.faces }.count) frames.\n\n"
        for r in frames.sorted(by: { abs($0.frameView.deltaAim) > abs($1.frameView.deltaAim) }).prefix(5) {
            md += "- \(r.name): Δaim \(f(r.frameView.deltaAim, 3)), ΔmeanStops \(f(r.frameView.deltaMeanStops, 3)), faces \(r.sheet.faces) → "
            md += "\(r.frameView.measurement.faces), face area \(String(format: "%.4f", r.sheet.faceArea)) → \(String(format: "%.4f", r.frameView.measurement.faceArea))\n"
        }

        md += "\n## Loading state: \(report.orders) seeded arrival orders, and capture order\n\n"
        let deviations = frames.map(\.loading.maxDeviation)
        md += "Max |shown − final| per frame: median / p90 / max \(spread(deviations)); frames over \(loadingRisk): "
        md += "\(deviations.filter { $0 > Double(loadingRisk) }.count) of \(frames.count). Shown aim changed after first shown: "
        md += "mean \(String(format: "%.2f", G.mean(frames.map(\.loading.changesMean)))) times a frame, at most \(frames.map(\.loading.changesMax).max() ?? 0). "
        md += "Capture order: max |shown − final| \(spread(frames.map(\.loading.captureOrderMaxDeviation))), frames over \(loadingRisk): "
        md += "\(frames.filter { $0.loading.captureOrderMaxDeviation > Double(loadingRisk) }.count).\n\n"
        for r in frames.sorted(by: { $0.loading.maxDeviation > $1.loading.maxDeviation }).prefix(5) {
            let first = r.loading.firstShown.filter(\.isFinite)
            md += "- \(r.name): final \(f(r.finalAim)), first shown \(f(first.min())) to \(f(first.max())), max deviation "
            md += "\(String(format: "%.3f", r.loading.maxDeviation)), changes up to \(r.loading.changesMax)\n"
        }

        md += "\n## Spread across the roll (the repeatability floor on a one-scene roll)\n\n"
        let a0 = frames.map(\.independentAim), a = frames.map(\.finalAim), whole = frames.map(\.rendered.productionFinal.whole)
        let wholeIndependent = frames.map(\.rendered.productionIndependent.whole)
        func range(_ v: [Double]) -> Double { (v.max() ?? 0) - (v.min() ?? 0) }
        md += "| | SD | range |\n|---|---|---|\n"
        for (name, values) in [("independent aim a0", a0), ("final aim a", a), ("whole-frame L* at a", whole), ("whole-frame L* at a0", wholeIndependent),
                               ("meanStops", frames.map(\.sheet.meanStops))] {
            md += "| \(name) | \(String(format: "%.3f", sd(values))) | \(String(format: "%.3f", range(values))) |\n"
        }
        md += "\nMatched-region |ΔL*| over every aligned pair at final aims: \(spread(pairs.compactMap { $0.match?.deltaRegionLightness })); "
        md += "at independent aims: \(spread(pairs.compactMap { $0.match?.deltaRegionLightnessIndependent })).\n"

        let checks = frames.compactMap { r in r.check.map { (r.name, $0) } }
        if !checks.isEmpty {
            md += "\n## Replica against FilmPreviews.measurement\n\n"
            for (name, c) in checks {
                md += "- \(name): sheet \(c.sheetIdentical ? "identical" : "Δaim \(f(c.sheetDeltaAim, 4))"), with the frame view's decode held "
                md += "\(c.frameViewIdentical ? "identical" : "Δaim \(f(c.frameViewDeltaAim, 4))")\n"
            }
        }
        return md
    }

    // MARK: Cube++

    struct CubePair: Codable {
        var camera: String
        var from: String
        var to: String
        var seconds: Double
        var deltaEV: Double
        /// SeriesMeasureTests' label from the cube: same, changed or between.
        var light: String
        var deltaAbsoluteGray: Double
        var deltaGray: Double
        var independentAims: [Double]
        var finalAims: [Double]
        var split: Split
        var grayLightness: [Double]
        var deltaGrayLightness: Double
        var match: MatchRecord?
        /// m = Δa − Δg taken apart: the exposure the print did not undo, placement responding to
        /// framing, smoothing; in stops and in L* (slope × term), with what rendering adds.
        var mismatch: Double
        var terms: [String: Double]
        var contributions: [String: Double]
        var slope: Double
    }

    @Test(.enabled(if: FrameViewMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_CUBEPP_COHORT"] != nil
                   && ProcessInfo.processInfo.environment["ARGENT_DIAGNOSE_ROLL"] == nil))
    func cubeppDiagnostics() throws {
        let out = try Self.outputFolder(refusing: [L.corpus.resolvingSymlinksInPath()])
        let cameras = try S.loadShots()
        try #require(cameras.reduce(0, { $0 + $1.count }) == L.expectedFrameCount, "Cube++ sequence cohort is incomplete")
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let neutral = RollControls(labBalance: .neutral)
        func lightness(_ gray: Double, level: Float) -> Double {
            G.lightness(Double((S.printedGray(gray, neutral.settings(for: stock, level: level), stock: stock) * Rec2020.luma).sum()))
        }
        var pairs: [CubePair] = []
        for shots in cameras {
            let analyses = shots.map { S.analysis($0) }
            let frames = S.roll(shots)
            let byURL = Dictionary(uniqueKeysWithValues: zip(frames.map(\.url), analyses))
            let aims = RollSmoothing.aims(frames, analyses: byURL)
            let maps = shots.map { DiagnosticMatcher.map($0.frame.analysisGrid) }
            for j in shots.indices.dropFirst() where shots[j].date.timeIntervalSince(shots[j - 1].date) <= 600 {
                let i = j - 1, a = shots[i], b = shots[j]
                // SeriesMeasureTests' label, from the cube's light.
                let light = abs(a.absoluteGray - b.absoluteGray)
                let (rbA, gA) = AutoBalance.axes(a.light), (rbB, gB) = AutoBalance.axes(b.light)
                let redBlue = Double(abs(rbA - rbB) / AutoBalance.stopsPerMired), green = Double(abs(gA - gB))
                let same: Bool? = light <= 1.0 / 3 && redBlue <= 10 && green <= 0.1 ? true
                    : light > 2.0 / 3 || redBlue > 20 || green > 0.2 ? false : nil
                let a0 = (AutoPrint.levelStops(analyses[i]), AutoPrint.levelStops(analyses[j]))
                let final = (aims[frames[i].url]!.level, aims[frames[j].url]!.level)
                let grays = (lightness(a.gray, level: final.0), lightness(b.gray, level: final.1))
                // m = Δa − Δg against frame i re-exposed by the cube's Δg.
                let dg = b.gray - a.gray
                let shiftedAim = AutoPrint.levelStops(S.analysis(a, shift: dg))
                let notFollowed = Double(shiftedAim - a0.0) - dg
                let framing = Double(a0.1 - shiftedAim)
                let smoothing = Double((final.1 - a0.1) - (final.0 - a0.0))
                let mismatch = Double(final.1 - final.0) - dg
                let h = Self.slopeStep
                let slope = ((lightness(a.gray, level: final.0 + h) - lightness(a.gray, level: final.0 - h))
                             + (lightness(b.gray, level: final.1 + h) - lightness(b.gray, level: final.1 - h))) / Double(4 * h)
                let delta = grays.1 - grays.0
                var record = CubePair(
                    camera: a.camera, from: a.id, to: b.id, seconds: b.date.timeIntervalSince(a.date), deltaEV: b.ev - a.ev,
                    light: same.map { $0 ? "same" : "changed" } ?? "between", deltaAbsoluteGray: b.absoluteGray - a.absoluteGray,
                    deltaGray: dg, independentAims: [Double(a0.0), Double(a0.1)], finalAims: [Double(final.0), Double(final.1)],
                    split: Self.split(frames[i], frames[j], analyses: byURL), grayLightness: [grays.0, grays.1], deltaGrayLightness: delta,
                    match: nil, mismatch: mismatch,
                    terms: ["exposureNotFollowed": notFollowed, "framing": framing, "smoothing": smoothing, "camera": a.ev - b.ev,
                            "light": b.absoluteGray - a.absoluteGray],
                    contributions: ["exposureNotFollowed": slope * notFollowed, "framing": slope * framing, "smoothing": slope * smoothing,
                                    "rendering": delta - slope * mismatch],
                    slope: slope)
                if let match = DiagnosticMatcher.match(maps[i], maps[j]) {
                    let cellsA = match.inliers.map(\.0), cellsB = match.inliers.map(\.1)
                    let la = Self.regionLightness(cellsA, neutral.settings(for: stock, level: final.0), stock: stock)
                    let lb = Self.regionLightness(cellsB, neutral.settings(for: stock, level: final.1), stock: stock)
                    let independent = Self.regionLightness(cellsB, neutral.settings(for: stock, level: a0.1), stock: stock)
                        - Self.regionLightness(cellsA, neutral.settings(for: stock, level: a0.0), stock: stock)
                    record.match = MatchRecord(correlation: match.alignment.correlation, overlap: match.alignment.overlap,
                                               scale: Double(match.alignment.scale),
                                               translation: [Double(match.alignment.tx), Double(match.alignment.ty)],
                                               cells: match.cells, inliers: match.inliers.count, shift: Double(match.shift),
                                               mad: Double(match.mad), light: Double(match.shift) - (a.ev - b.ev),
                                               regionLightness: [la, lb], deltaRegionLightness: lb - la,
                                               deltaRegionLightnessIndependent: independent, slope: .nan)
                }
                pairs.append(record)
            }
        }
        try Self.encoder.encode(pairs).write(to: out.appendingPathComponent("report.json"))
        var lines = ["camera,from,to,seconds,dEV,light,dAbsoluteGray,dGray,a0i,a0j,ai,aj,splitRules,grayLi,grayLj,dGrayL,ncc,overlap,shift,"
                     + "matcherLight,dRegionL,mismatch,exposureNotFollowed,framing,smoothing,renderingL,slope"]
        for p in pairs {
            let m = p.match
            lines.append([p.camera, p.from, p.to, Self.f(p.seconds, 1), Self.f(p.deltaEV), p.light, Self.f(p.deltaAbsoluteGray, 3),
                          Self.f(p.deltaGray, 3), Self.f(p.independentAims[0], 3), Self.f(p.independentAims[1], 3), Self.f(p.finalAims[0], 3),
                          Self.f(p.finalAims[1], 3), p.split.fired.joined(separator: "+"), Self.f(p.grayLightness[0]), Self.f(p.grayLightness[1]),
                          Self.f(p.deltaGrayLightness), Self.f(m?.correlation, 3), Self.f(m?.overlap, 3), Self.f(m?.shift, 3), Self.f(m?.light, 3),
                          Self.f(m?.deltaRegionLightness), Self.f(p.mismatch, 3), Self.f(p.terms["exposureNotFollowed"], 3),
                          Self.f(p.terms["framing"], 3), Self.f(p.terms["smoothing"], 3), Self.f(p.contributions["rendering"]),
                          Self.f(p.slope)].joined(separator: ","))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("pairs.csv"), atomically: true, encoding: .utf8)
        let summary = Self.cubeSummary(pairs)
        try summary.write(to: out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        print(summary)
    }

    static func cubeSummary(_ pairs: [CubePair]) -> String {
        let same = pairs.filter { $0.light == "same" }, changed = pairs.filter { $0.light == "changed" }
        var md = "# Cube++: exposure jumps between neighbouring frames, as shot\n\n"
        md += "\(pairs.count) same-body neighbours within 600 s: same light \(same.count), changed \(changed.count), "
        md += "between \(pairs.count - same.count - changed.count) (SeriesMeasureTests' cube label). The cube's gray printed through "
        md += "Portra 400 on Neutral at each frame's smoothed aim, as `SeriesMeasureTests.gates` prints it.\n\n"
        md += "## The cube's gray, same light\n\n"
        let deltas = same.map(\.deltaGrayLightness)
        md += "|ΔL*| mean \(String(format: "%.2f", G.mean(deltas.map(abs)))), median / p90 / max \(spread(deltas)); over 3 L*: "
        md += "\(deltas.filter { abs($0) > 3 }.count), over 5 L*: \(deltas.filter { abs($0) > 5 }.count) of \(same.count). "
        md += "Split by RollSmoothing: \(same.filter(\.split.splits).count) (" + ["time", "EV", "flash", "WB", "hist"].map { rule in
            "\(rule) \(same.filter { $0.split.fired.contains(rule) }.count)"
        }.joined(separator: ", ") + ").\n\n"
        let total = deltas.map { $0 * $0 }.reduce(0, +)
        md += "Share of same-light ΔL*² by cause (projection; slope × term, rendering the rest):\n\n| cause | share | mean \\|L*\\| |\n|---|---|---|\n"
        for (key, name) in [("exposureNotFollowed", "(i) exposure change the print did not undo"), ("framing", "(ii) placement responding to framing"),
                            ("smoothing", "(iii) smoothing"), ("rendering", "rendering beyond the slope")] {
            let share = same.map { ($0.contributions[key] ?? 0) * $0.deltaGrayLightness }.reduce(0, +) / max(total, 1e-9)
            md += "| \(name) | \(String(format: "%.0f%%", share * 100)) | \(String(format: "%.2f", G.mean(same.map { abs($0.contributions[key] ?? 0) }))) |\n"
        }
        md += "\nIn stops, |exposure not followed| \(spread(same.map { $0.terms["exposureNotFollowed"] ?? 0 })), |framing| "
        md += "\(spread(same.map { $0.terms["framing"] ?? 0 })), |smoothing| \(spread(same.map { $0.terms["smoothing"] ?? 0 })), "
        md += "|camera ΔEV| \(spread(same.map(\.deltaEV))).\n"

        md += "\n## The diagnostic matcher on same and changed light\n\n| | same light | changed light |\n|---|---|---|\n"
        func quartiles(_ v: [Double]) -> String {
            let s = v.sorted()
            guard !s.isEmpty else { return "–" }
            return [0.1, 0.25, 0.5, 0.75, 0.9].map { String(format: "%.2f", s[min(s.count - 1, Int($0 * Double(s.count)))]) }.joined(separator: " / ")
        }
        md += "| aligned | \(same.filter { $0.match != nil }.count) of \(same.count) | \(changed.filter { $0.match != nil }.count) of \(changed.count) |\n"
        md += "| NCC p10 / p25 / p50 / p75 / p90 | \(quartiles(same.compactMap { $0.match?.correlation })) | \(quartiles(changed.compactMap { $0.match?.correlation })) |\n"
        md += "| overlap p10 / p25 / p50 / p75 / p90 | \(quartiles(same.compactMap { $0.match?.overlap })) | \(quartiles(changed.compactMap { $0.match?.overlap })) |\n"
        md += "| \\|l\\| p10 / p25 / p50 / p75 / p90 | \(quartiles(same.compactMap { $0.match?.light.map(abs) })) | \(quartiles(changed.compactMap { $0.match?.light.map(abs) })) |\n"
        md += "\nPairs the matcher links (NCC ≥ x, overlap ≥ y, and with |l| ≤ 0.5 or without that test):\n\n"
        md += "| NCC ≥ | overlap ≥ | same linked | changed linked | same linked, \\|l\\| ≤ 0.5 | changed linked, \\|l\\| ≤ 0.5 |\n|---|---|---|---|---|---|\n"
        for correlation in [0.5, 0.6, 0.7, 0.8, 0.9] {
            for overlap in [0.3, 0.5] {
                func linked(_ p: CubePair, light: Bool) -> Bool {
                    guard let m = p.match else { return false }
                    return m.correlation >= correlation && m.overlap >= overlap && (!light || abs(m.light ?? .infinity) <= linkLight)
                }
                md += "| \(correlation) | \(overlap) | \(same.filter { linked($0, light: false) }.count) | \(changed.filter { linked($0, light: false) }.count) | "
                md += "\(same.filter { linked($0, light: true) }.count) | \(changed.filter { linked($0, light: true) }.count) |\n"
            }
        }
        let good = same.filter { ($0.match?.correlation ?? 0) >= linkCorrelation && ($0.match?.overlap ?? 0) >= linkOverlap }
        md += "\nOn same-light pairs with NCC ≥ \(linkCorrelation) and overlap ≥ \(linkOverlap) (\(good.count)): |d − Δg| (matcher's shift against the cube's) "
        md += "\(spread(good.compactMap { p in p.match.map { $0.shift - p.deltaGray } })), |l − Δ absolute gray| "
        md += "\(spread(good.compactMap { p in p.match?.light.map { $0 - p.deltaAbsoluteGray } })), matched-region |ΔL*| "
        md += "\(spread(good.compactMap { $0.match?.deltaRegionLightness })) against the cube's \(spread(good.map(\.deltaGrayLightness))).\n"
        let jumps = same.filter { abs($0.deltaGrayLightness) > jumpLightness }
        md += "Same-light jumps over \(jumpLightness) L* on the cube: \(jumps.count); the matcher links \(jumps.filter { p in good.contains { $0.from == p.from && $0.to == p.to } }.count) of them.\n"
        return md
    }
}

/// A DIAGNOSTIC matcher: a probe for `RollDiagnosticsMeasureTests`, not the product's matching, which
/// the plan's stages 2 and 3 build. It lines two frames up by a similarity without rotation, a scale of
/// 0.5x to 2x in eighth-octave steps and a translation, on log-luminance maps of about 64 columns made
/// from their analysis grids, and scores each alignment by the normalized cross-correlation over the
/// cells both frames see unclipped and above the analysis floor, each map's mean over them taken out, so
/// an exposure shift leaves the score alone. Coarse to fine: every alignment on maps a quarter the size,
/// then the best three refined. It cannot tell a moved subject from a changed scene or two similar
/// layouts apart, nor turn a frame; `cubeppDiagnostics` measures how well it separates measured light.
enum DiagnosticMatcher {
    /// A frame's log2 luminance and mean light on a coarse grid, rows from the bottom; NaN where a cell
    /// is clipped, at the floor, or masked (all zero).
    struct Map {
        var width: Int
        var height: Int
        var log: [Float]
        var rgb: [SIMD3<Float>]
        /// The valid cells' centres, as fractions of the map's width, with their index.
        var cells: [(x: Float, y: Float, index: Int)]

        var aspect: Float { Float(height) / Float(width) }

        /// The cell under `x`, `y` (fractions of the width), when it is on the map and valid.
        func value(_ x: Float, _ y: Float) -> (Int, Float)? {
            let fx = x * Float(width), fy = y * Float(width)
            guard fx >= 0, fy >= 0, fx < Float(width), fy < Float(height) else { return nil }
            let index = Int(fy) * width + Int(fx)
            let v = log[index]
            return v.isNaN ? nil : (index, v)
        }
    }

    struct Alignment {
        var scale: Float
        var tx: Float
        var ty: Float
        var correlation: Double
        /// The smaller of the shares of each frame the other covers.
        var overlap: Double
        var cells: Int
    }

    struct Match {
        var alignment: Alignment
        var cells: Int
        /// The median of frame j's log2 luminance less frame i's over aligned cells, and its MAD.
        var shift: Float
        var mad: Float
        /// Aligned cells within three robust deviations (a quarter stop at least) of `shift`: each
        /// frame's mean light there.
        var inliers: [(SIMD3<Float>, SIMD3<Float>)]
    }

    static func make(width: Int, height: Int, rgb: [SIMD3<Float>], valid: [Bool]) -> Map {
        var log = [Float](repeating: .nan, count: width * height), cells: [(x: Float, y: Float, index: Int)] = []
        for index in log.indices where valid[index] {
            log[index] = log2((rgb[index] * Rec2020.luma).sum())
            cells.append(((Float(index % width) + 0.5) / Float(width), (Float(index / width) + 0.5) / Float(width), index))
        }
        return Map(width: width, height: height, log: log, rgb: rgb, cells: cells)
    }

    /// `grid` in blocks of cells about `columns` across: a block is valid when three quarters of its
    /// cells are wholly unclipped, not masked and above the analysis floor, and holds their mean light.
    static func map(_ grid: ExposureAnalyzer.Grid, columns: Int = 64) -> Map {
        let factor = max(1, Int((Double(grid.width) / Double(columns)).rounded()))
        let width = max(1, grid.width / factor), height = max(1, grid.height / factor)
        let floor = 0.18 * exp2(ExposureAnalyzer.floorStops)
        var rgb = [SIMD3<Float>](repeating: .zero, count: width * height), valid = [Bool](repeating: false, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                var sum = SIMD3<Float>(repeating: 0), n = 0
                for y in (row * factor)..<(row * factor + factor) {
                    for x in (column * factor)..<(column * factor + factor) {
                        let k = y * grid.width + x, v = grid.light[k]
                        guard grid.unclipped[k] >= 0.99, grid.all[k] != .zero, (v * Rec2020.luma).sum() > floor else { continue }
                        sum += v
                        n += 1
                    }
                }
                guard n * 4 >= factor * factor * 3 else { continue }
                rgb[row * width + column] = sum / Float(n)
                valid[row * width + column] = true
            }
        }
        return make(width: width, height: height, rgb: rgb, valid: valid)
    }

    /// `map` in blocks of `factor` by `factor`, valid where half a block is.
    static func coarse(_ map: Map, factor: Int = 4) -> Map {
        let width = max(1, map.width / factor), height = max(1, map.height / factor)
        var rgb = [SIMD3<Float>](repeating: .zero, count: width * height), valid = [Bool](repeating: false, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                var sum = SIMD3<Float>(repeating: 0), n = 0
                for y in (row * factor)..<min(map.height, row * factor + factor) {
                    for x in (column * factor)..<min(map.width, column * factor + factor) where !map.log[y * map.width + x].isNaN {
                        sum += map.rgb[y * map.width + x]
                        n += 1
                    }
                }
                guard n * 2 >= factor * factor else { continue }
                rgb[row * width + column] = sum / Float(n)
                valid[row * width + column] = true
            }
        }
        return make(width: width, height: height, rgb: rgb, valid: valid)
    }

    /// The smaller of the shares of `a` and of `b` that each other covers when `a`'s point p lands on
    /// `b`'s s·p + t.
    static func overlap(_ a: Map, _ b: Map, scale s: Float, tx: Float, ty: Float) -> Double {
        let x = max(0, min(1, (1 - tx) / s) - max(0, -tx / s))
        let y = max(0, min(a.aspect, (b.aspect - ty) / s) - max(0, -ty / s))
        let area = Double(x * y)
        return min(area / Double(a.aspect), area * Double(s * s) / Double(b.aspect))
    }

    /// The normalized cross-correlation of `a`'s valid cells with the cells of `b` they land on.
    static func correlation(_ a: Map, _ b: Map, scale s: Float, tx: Float, ty: Float, minimumCells: Int) -> (r: Double, n: Int)? {
        var n = 0.0, sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
        for cell in a.cells {
            guard let hit = b.value(s * cell.x + tx, s * cell.y + ty) else { continue }
            let va = Double(a.log[cell.index]), vb = Double(hit.1)
            n += 1
            sa += va
            sb += vb
            saa += va * va
            sbb += vb * vb
            sab += va * vb
        }
        guard Int(n) >= minimumCells else { return nil }
        let covariance = sab - sa * sb / n, varianceA = saa - sa * sa / n, varianceB = sbb - sb * sb / n
        guard varianceA > 1e-6, varianceB > 1e-6 else { return nil }
        return (covariance / (varianceA * varianceB).squareRoot(), Int(n))
    }

    /// The best alignment of `a` onto `b` that covers at least the link's overlap of each, or `nil` for none: the
    /// highest correlation wins, so a smaller overlap allowed would win on chance agreement of few cells.
    static func align(_ a: Map, _ b: Map) -> Alignment? {
        let ca = coarse(a), cb = coarse(b)
        let minimumOverlap = RollDiagnosticsMeasureTests.linkOverlap
        var candidates: [Alignment] = []
        let step = 1 / Float(cb.width)
        for k in -8...8 {
            let s = exp2(Float(k) / 8)
            var best: Alignment?
            var tx = -s + step
            while tx < 1 {
                var ty = -s * ca.aspect + step
                while ty < cb.aspect {
                    let share = overlap(ca, cb, scale: s, tx: tx, ty: ty)
                    if share >= minimumOverlap, let r = correlation(ca, cb, scale: s, tx: tx, ty: ty, minimumCells: 12),
                       r.r > best?.correlation ?? -2 {
                        best = Alignment(scale: s, tx: tx, ty: ty, correlation: r.r, overlap: share, cells: r.n)
                    }
                    ty += step
                }
                tx += step
            }
            if let best { candidates.append(best) }
        }
        var best: Alignment?
        let fine = 1 / Float(b.width)
        for candidate in candidates.sorted(by: { $0.correlation > $1.correlation }).prefix(3) {
            for j in -4...4 {
                let s = candidate.scale * exp2(Float(j) / 32)
                for u in -4...4 {
                    for v in -4...4 {
                        let tx = candidate.tx + Float(u) * fine, ty = candidate.ty + Float(v) * fine
                        let share = overlap(a, b, scale: s, tx: tx, ty: ty)
                        guard share >= minimumOverlap, let r = correlation(a, b, scale: s, tx: tx, ty: ty, minimumCells: 40),
                              r.r > best?.correlation ?? -2 else { continue }
                        best = Alignment(scale: s, tx: tx, ty: ty, correlation: r.r, overlap: share, cells: r.n)
                    }
                }
            }
        }
        return best
    }

    static func median(_ values: [Float]) -> Float {
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// `a` aligned onto `b`, with the exposure shift between them and the cells that agree with it.
    static func match(_ a: Map, _ b: Map) -> Match? {
        guard let alignment = align(a, b) else { return nil }
        var differences: [Float] = [], pairs: [(SIMD3<Float>, SIMD3<Float>)] = []
        for cell in a.cells {
            guard let hit = b.value(alignment.scale * cell.x + alignment.tx, alignment.scale * cell.y + alignment.ty) else { continue }
            differences.append(hit.1 - a.log[cell.index])
            pairs.append((a.rgb[cell.index], b.rgb[hit.0]))
        }
        guard !differences.isEmpty else { return nil }
        let shift = median(differences), mad = median(differences.map { abs($0 - shift) })
        let limit = max(0.25, 3 * 1.4826 * mad)
        let inliers = zip(differences, pairs).filter { abs($0.0 - shift) <= limit }.map(\.1)
        return Match(alignment: alignment, cells: differences.count, shift: shift, mad: mad, inliers: inliers)
    }
}
