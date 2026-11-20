@testable import ArgentCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ArgentRoll

/// Masks between the previews and the develop: the print's limits without them, what the previews keep of them and let go, what a
/// develop weighs a frame with masks at and holds of them, and the frame view and the develop showing one gradient.
enum MaskFixtures {
    /// A linear gradient at Exposure `ev`, Full at the top of the picture and Zero `zero` long sides down.
    static func linear(_ ev: Float = -1.5, zero: Float = 0.45) throws -> Mask {
        Mask(components: [MaskComponent(shape: .linear(.init(full: MaskPoint(x: 0.5, y: 0), zero: MaskPoint(x: 0.5, y: zero))))],
             adjustments: try ManualAdjustments(exposureEV: ev))
    }

    /// `count` linear gradients, each moving a little Exposure, or Highlights alone.
    static func masks(_ count: Int, highlights: Bool = false) throws -> MaskSet {
        try MaskSet(masks: (0..<count).map { index in
            Mask(components: [MaskComponent(shape: .linear(.init(full: MaskPoint(x: 0.5, y: Float(index) * 0.01),
                                                                 zero: MaskPoint(x: 0.5, y: 0.4 + Float(index) * 0.01))))],
                 adjustments: highlights ? try ManualAdjustments(highlights: -20) : try ManualAdjustments(exposureEV: -0.1))
        })
    }

    static func settings(_ masks: MaskSet, panel: ManualAdjustments = .identity) throws -> DevelopSettings {
        DevelopSettings(manual: try ManualRenderSettings(adjustments: panel.settingMasks(masks), referenceStops: 0.4))
    }
}

@Suite struct MaskBudgetTests {
    /// A frame's masks cost their coverage array, a slice of 2048 by the aspect for each four masks, the tables, and the local base
    /// field when only a mask asks for it; a frame whose masks change nothing costs nothing, as it renders today's kernels.
    @Test func aFrameWithMasksCostsItsSlicesItsTablesAndABaseOnlyItAsksFor() throws {
        let slice = 2048 * 1365 * 8, tables = 181_936, base = 3 * 1024 * 683 * 8
        func cost(_ settings: DevelopSettings, _ width: Int = 7008, _ height: Int = 4672) -> Int {
            DevelopBudget.maskCost(settings: settings, width: width, height: height)
        }
        #expect(cost(DevelopSettings()) == 0)
        #expect(try cost(MaskFixtures.settings(.empty)) == 0)
        #expect(try cost(MaskFixtures.settings(MaskFixtures.masks(1))) == slice + tables)
        #expect(try cost(MaskFixtures.settings(MaskFixtures.masks(4))) == slice + tables)
        #expect(try cost(MaskFixtures.settings(MaskFixtures.masks(5))) == 2 * slice + tables)
        #expect(try cost(MaskFixtures.settings(MaskFixtures.masks(16))) == 4 * slice + tables)
        // Either way up, the same; a square frame's slice is 2048 square.
        #expect(try cost(MaskFixtures.settings(MaskFixtures.masks(16)), 4672, 7008) == 4 * slice + tables)
        #expect(try cost(MaskFixtures.settings(MaskFixtures.masks(4)), 4000, 4000) == 2048 * 2048 * 8 + tables)
        // Masks that change no pixel: all at 0, or off, take today's kernels and no coverage.
        let idle = try MaskSet(masks: [Mask(components: try MaskFixtures.masks(1).masks[0].components)])
        #expect(try cost(MaskFixtures.settings(idle)) == 0)
        var off = try MaskFixtures.masks(2).masks
        off = off.map { var mask = $0; mask.isEnabled = false; return mask }
        #expect(try cost(MaskFixtures.settings(MaskSet(masks: off))) == 0)
        // A mask's Highlights needs the base field, unless the panel's or the tone step already does.
        #expect(try cost(MaskFixtures.settings(MaskFixtures.masks(4, highlights: true))) == slice + tables + base)
        #expect(try cost(MaskFixtures.settings(MaskFixtures.masks(4, highlights: true), panel: try ManualAdjustments(shadows: 10)))
                == slice + tables)
        var toned = try MaskFixtures.settings(MaskFixtures.masks(4, highlights: true))
        toned.tone = PrintTone(burn: 0.2, dodge: 0)
        #expect(toned.tone.isActive && cost(toned) == slice + tables)
    }

    /// A frame's masks are weighed with it, and count beside the footprint for the frames after it until its film passes are done,
    /// whatever the floor and so in every format, where the film passes of HEIC count only above the reference floor.
    @Test func masksStillToComeCountInEveryFormatUntilTheirFilmPassesAreDone() {
        let footprint = MaskFootprint(500)
        // The floor at the reference: no excess, so the film passes do not count, and frames fit under 3000.
        let gate = MemoryGate(ceiling: 3000, maxInFlight: 3, floorReference: 1 << 40, floorQuiet: 0.01,
                              pendingWindow: 0, loneWait: 0.1, footprint: { footprint.value })
        // Alone, weighed with its masks: 2500 + 300 + 300 is over 3000.
        footprint.value = 2500
        #expect(!gate.admit(decode: 300, masks: 300, frame: 0, stopped: { true }))
        footprint.value = 2300
        #expect(gate.admit(decode: 300, filmPasses: 400, masks: 300, frame: 0, stopped: { true }))
        #expect(gate.masksStillToCome == 300)
        // Frame 0's masks count for frame 1, its film passes do not: 2300 + 300 + 300 fits, 2401 + 300 + 300 does not.
        footprint.value = 2401
        #expect(!gate.admit(decode: 300, frame: 1, stopped: { true }))
        footprint.value = 2400
        #expect(gate.admit(decode: 300, frame: 1, stopped: { true }))
        // Once frame 0's film passes are done, its masks are gone.
        gate.filmPassesDone(frame: 0)
        #expect(gate.masksStillToCome == 0)
        footprint.value = 2700
        #expect(gate.admit(decode: 300, frame: 2, stopped: { true }))
        gate.leave(frame: 0); gate.leave(frame: 1); gate.leave(frame: 2)
        // Leaving takes a frame's masks with it.
        footprint.value = 500
        #expect(gate.admit(decode: 300, masks: 200, frame: 3, stopped: { true }))
        gate.leave(frame: 3)
        #expect(gate.masksStillToCome == 0)
        gate.leave()
    }
}

private final class MaskFootprint: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int
    init(_ bytes: Int) { self.bytes = bytes }
    var value: Int {
        get { lock.withLock { bytes } }
        set { lock.withLock { bytes = newValue } }
    }
}

@Suite struct MaskPrintLimitsTests {
    /// The print's own ends are the stock's and the panel's: a frame's masks play no part in the probe, which neither renders through
    /// them nor asks for a field, and a mask's slider does not key a probe of its own.
    @Test func thePrintsLimitsLeaveTheMasksOut() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeToyStock(id: "toy", in: directory)
        let films = try FilmPreviews(stocks: StockLibrary.load(from: directory).stocks)
        let panel = try ManualAdjustments(exposureEV: 0.5, blacks: -40)
        let plain = try #require(await films.printLimits(stock: 0, settings: MaskFixtures.settings(.empty, panel: panel)))
        let masked = try MaskFixtures.settings(MaskSet(masks: [MaskFixtures.linear(-3), MaskFixtures.linear(2)]), panel: panel)
        #expect(await films.printLimits(stock: 0, settings: masked) == plain)
        #expect(films.maskFieldStatistics == MaskFieldCache.Statistics())
        #expect(films.maskBytes == (0, 0, 0))

        // The probe keeps the panel and drops the masks, so two edits differing only in a mask's slider key one probe.
        let probe = try #require(FilmPreviews.printLimitsProbe(masked))
        #expect(probe.manual.adjustments.masks.isEmpty && probe.manual.adjustments.exposureEV == 0.5 && probe.manual.adjustments.blacks == -40)
        #expect(probe.manual.referenceStops == masked.manual.referenceStops && probe.manual.version == masked.manual.version)
        let moved = try MaskFixtures.settings(MaskSet(masks: [MaskFixtures.linear(-1), MaskFixtures.linear(2)]), panel: panel)
        #expect(moved != masked && FilmPreviews.printLimitsProbe(moved) == probe)
        // Without masks the probe is today's.
        let unmasked = try MaskFixtures.settings(.empty, panel: panel)
        #expect(FilmPreviews.printLimitsProbe(unmasked)?.manual == unmasked.manual)
    }
}

@Suite(.serialized, .rawDecodes) struct MaskPreviewSampleTests {
    private static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples")
    private static var hasSamples: Bool {
        FileManager.default.fileExists(atPath: samples.appendingPathComponent("ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW").path)
    }

    private func previews(in directory: URL) throws -> FilmPreviews {
        try writeToyStock(id: "kodak-portra-400", in: directory)
        return try FilmPreviews(stocks: StockLibrary.load(from: directory).stocks, decoderChoices: DecoderChoices(route: .raw9))
    }

    /// The sheet, the strip and the frame view render a frame through its masks, from one field: the picture's, whichever decode
    /// asked. What the previews keep of the masks is counted for the develop's gate, and a develop's trim or a new roll lets it go.
    @Test(.enabled(if: MaskPreviewSampleTests.hasSamples))
    func theSheetAndTheFrameViewRenderThroughOneFieldAndLetItGo() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let films = try previews(in: directory)
        let frame = try #require(await RollScanner.scan(Self.samples).frames.first { $0.name.contains("Large") })
        let plain = try MaskFixtures.settings(.empty)
        let masked = try MaskFixtures.settings(MaskSet(masks: [MaskFixtures.linear(-1.5)]))

        let sheet = try #require(await films.film(frame, stock: 0, settings: plain, maxPixelSize: 336))
        let sheetMasked = try #require(await films.film(frame, stock: 0, settings: masked, maxPixelSize: 336))
        #expect(films.maskFieldStatistics.bakes == 1 && films.maskFieldStatistics.allocations == 1)
        // Darker at the top, the same at the bottom.
        let (top, bottom) = (try bandLightness(sheetMasked, 0..<0.1) - bandLightness(sheet, 0..<0.1),
                             try bandLightness(sheetMasked, 0.85..<1) - bandLightness(sheet, 0.85..<1))
        #expect(top < -3 && abs(bottom) < 0.5, "top \(top), bottom \(bottom)")

        // The frame view's decode at another size reads the same field: no bake.
        #expect(await films.frameFilm(frame, stock: 0, settings: masked, pixels: 1201) != nil)
        #expect(films.maskFieldStatistics.bakes == 1 && films.maskFieldStatistics.hits >= 1)
        // A slider bakes nothing either.
        let moved = try MaskFixtures.settings(MaskSet(masks: [MaskFixtures.linear(-1)]))
        #expect(await films.frameFilm(frame, stock: 0, settings: moved, pixels: 1201) != nil)
        #expect(films.maskFieldStatistics.bakes == 1 && films.maskFieldStatistics.allocations == 1)

        // While a develop runs the previews keep one array, and two again after it.
        #expect(films.maskFieldLimit == MaskFieldCache.defaultMaximumBytes)
        films.isDevelopRunning = true
        #expect(films.maskFieldLimit == FilmPreviews.developMaskFieldBytes && films.maskBytes.coverage == 2048 * 1365 * 8)
        films.isDevelopRunning = false
        #expect(films.maskFieldLimit == MaskFieldCache.defaultMaximumBytes)
        // Held, and counted: one slice at 3:2, the tables of the one stock.
        let held = films.maskBytes
        #expect(held.coverage == 2048 * 1365 * 8 && held.tables == 181_936, "\(held)")
        let before = films.heldBytes
        films.trimForDevelop()
        #expect(films.maskBytes == (0, 0, 0))
        #expect(films.heldBytes <= before - held.coverage - held.tables)
        // Made again on the next render, and a new roll lets it go too.
        #expect(await films.film(frame, stock: 0, settings: masked, maxPixelSize: 336) != nil)
        #expect(films.maskBytes.coverage > 0)
        films.removeAll()
        #expect(films.maskBytes.coverage == 0)
    }

    /// When the frame view's scaled decode is refined, the picture keeps its field: the refined decode knows the same full-size
    /// picture, so the render after it bakes nothing and the gradient lies where it lay.
    @Test(.enabled(if: MaskPreviewSampleTests.hasSamples))
    func refiningTheFrameViewsDecodeKeepsItsField() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let films = try previews(in: directory)
        let frame = try #require(await RollScanner.scan(Self.samples).frames.first { $0.name.contains("Raw-Compressed") })
        let masked = try MaskFixtures.settings(MaskSet(masks: [MaskFixtures.linear(-1.5)]))
        let pixels = 1201
        let fast = try #require(await films.frameFilm(frame, stock: 0, settings: masked, pixels: pixels))
        let scaled = try #require(films.frameDecode(of: frame, lens: .default, pixels: pixels))
        let baked = films.maskFieldStatistics
        #expect(baked.bakes == 1)
        #expect(await films.refineFrame(frame, lens: .default, pixels: pixels))
        let refined = try #require(films.frameDecode(of: frame, lens: .default, pixels: pixels))
        #expect(refined.texture !== scaled.texture && refined.picture != nil && refined.picture == scaled.picture,
                "\(String(describing: scaled.picture)) \(String(describing: refined.picture)) \(scaled.width)x\(scaled.height) \(refined.width)x\(refined.height)")
        let film = try #require(await films.frameFilm(frame, stock: 0, settings: masked, pixels: pixels))
        #expect(film !== fast)
        let after = films.maskFieldStatistics
        #expect(after.bakes == baked.bakes && after.allocations == baked.allocations && after.hits > baked.hits)
        // The gradient lies where it lay: each band's lightness moves by what the refinement moves the unmasked frame by, or less.
        for band in [0.0..<0.1, 0.2..<0.3, 0.4..<0.5] {
            let step = try bandLightness(film, band) - bandLightness(fast, band)
            #expect(abs(step) < 1, "band \(band): \(step)")
        }
    }

    /// A develop prints the gradient the frame view showed: the frame view's refined film at 2048 pixels against the develop resized to
    /// them, band by band down the gradient, beside the same pair without masks, so the masks' own share of their difference shows.
    @Test(.enabled(if: MaskPreviewSampleTests.hasSamples))
    func aDevelopPrintsTheGradientTheFrameViewShowed() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let stocks = root.appendingPathComponent("stocks")
        try FileManager.default.createDirectory(at: stocks, withIntermediateDirectories: true)
        let films = try previews(in: stocks)
        let stock = films.stocks[0], controls = RollControls()
        let output = OutputSettings(format: .tiff16, size: .longEdge2048)
        var bands: [String: [Double]] = [:]
        for (label, masks) in [("plain", MaskSet.empty), ("masked", try MaskSet(masks: [MaskFixtures.linear(-1.5)]))] {
            // A copy of the raw and a library each, as each recipe is a first edit of its frame.
            let folder = root.appendingPathComponent("roll-\(label)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW"
            try FileManager.default.copyItem(at: Self.samples.appendingPathComponent(name), to: folder.appendingPathComponent(name))
            let frame = try #require(await RollScanner.scan(folder).frames.first)
            let baseline = AutomaticBaseline(sourceSHA256: try RecipeStore.sha256(of: frame.url), stockID: stock.id, stockDigest: stock.digest,
                                             controls: controls, aim: PrintAim(), analysisVersion: ExposureAnalysis.currentVersion,
                                             baseRender: Recipe.Render(settings: controls.settings(for: stock, aim: PrintAim()), grain: .off))
            let made = try Recipe.make(frame: frame, byteCount: RecipeStore.byteCount(of: frame.url), stock: stock, stockDigest: stock.digest,
                                       roll: controls, own: FrameControls(),
                                       manual: ManualEdit(adjustments: try ManualAdjustments(masks: masks), baseline: baseline))
            let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: root.appendingPathComponent("library-\(label)"))
            let outcomes = await developer.develop([RollDeveloper.Job(frame: frame, recipe: made)], to: root.appendingPathComponent("out-\(label)"),
                                                   output: output)
            guard case .developed(let file) = try #require(outcomes.first) else { Issue.record("\(outcomes)"); return }
            // The develop keeps no coverage after its frame.
            #expect(developer.heldReport.contains("mask fields 0 MB"), "\(developer.heldReport)")
            let developed = try #require(CGImageSourceCreateWithURL(file as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            #expect(await films.frameFilm(frame, stock: 0, settings: made.render.settings, pixels: 2048) != nil)
            #expect(await films.refineFrame(frame, lens: .default, pixels: 2048))
            let shown = try #require(await films.frameFilm(frame, stock: 0, settings: made.render.settings, pixels: 2048))
            #expect(shown.width == developed.width && abs(shown.height - developed.height) <= 1, "\(shown.width)x\(shown.height) \(developed.width)x\(developed.height)")
            let twelfths = (0..<12).map { Double($0) / 12..<Double($0 + 1) / 12 }
            bands[label] = try twelfths.map { try bandLightness(developed, $0) - bandLightness(shown, $0) }
            bands[label + " effect"] = try twelfths.map { try bandLightness(shown, $0) }
        }
        let plain = try #require(bands["plain"]), masked = try #require(bands["masked"])
        let effect = zip(try #require(bands["masked effect"]), try #require(bands["plain effect"])).map { $0 - $1 }
        let excess = zip(masked, plain).map { $0 - $1 }
        print("MEASURE mask develop against frame view, L* by twelfth: effect \(effect.map { String(format: "%.2f", $0) }), develop − frame view"
              + " plain \(plain.map { String(format: "%.3f", $0) }), the masks' own \(excess.map { String(format: "%.3f", $0) })")
        #expect(effect[0] < -3 && abs(effect[11]) < 0.2, "\(effect)")
        #expect(excess.allSatisfy { abs($0) < 0.1 }, "\(excess)")
    }
}

/// The mean CIE L* of the rows of `image` in `band`, fractions of its height from the top, from its sRGB codes.
private func bandLightness(_ image: CGImage, _ band: Range<Double>) throws -> Double {
    let width = image.width, height = image.height
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8, space: space,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let data = try #require(context.data).assumingMemoryBound(to: UInt16.self)
    func linear(_ code: UInt16) -> Double {
        let v = Double(code) / 65535
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    let rows = Int(band.lowerBound * Double(height))..<max(Int(band.lowerBound * Double(height)) + 1, Int(band.upperBound * Double(height)))
    var total = 0.0, count = 0
    for row in rows {
        for column in 0..<width {
            let p = (row * width + column) * 4
            let y = 0.2126 * linear(data[p]) + 0.7152 * linear(data[p + 1]) + 0.0722 * linear(data[p + 2])
            total += y > 216.0 / 24389 ? 116 * cbrt(y) - 16 : y * 24389 / 27
            count += 1
        }
    }
    return total / Double(max(count, 1))
}
