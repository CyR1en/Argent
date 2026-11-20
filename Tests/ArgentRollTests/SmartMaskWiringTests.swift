import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// A smart mask renders in the app from the library's seeds: the sheet and the frame view through `FilmPreviews.maskSeeds` (the model
/// sets `StoredMaskSeeds` over its `MaskRasterStore`), and a develop from the seeds its lane loaded and checked (`MaskSeeds`). On a CC0
/// sample, with a seed that holds the top third of the frame.
@Suite(.serialized, .rawDecodes) struct SmartMaskWiringTests {
    private static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples")
    private static let sample = samples.appendingPathComponent("ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")
    static var hasSample: Bool { FileManager.default.fileExists(atPath: sample.path) }

    /// The top 30 % of the frame, as a sky seed 512 × 341 would hold it.
    private static func topSeed() throws -> MaskRaster {
        try MaskRaster(width: 512, height: 341, plane: (0..<(512 * 341)).map { $0 / 512 < 102 ? 255 : 0 })
    }

    private static func sky(_ ref: RasterRef, exposure: Float = -1) throws -> MaskSet {
        let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        return try MaskSet(masks: [Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: ref, frame: frame)))],
                                        adjustments: try ManualAdjustments(exposureEV: exposure))])
    }

    @Test(.enabled(if: SmartMaskWiringTests.hasSample))
    func theSheetAndTheFrameViewRenderASmartMaskFromTheStore() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeToyStock(id: "kodak-portra-400", in: directory)
        let films = try FilmPreviews(stocks: StockLibrary.load(from: directory).stocks, decoderChoices: DecoderChoices(route: .raw9))
        let store = MaskRasterStore(library: directory.appendingPathComponent("library"))
        let ref = try store.store(try Self.topSeed())
        let seeds = StoredMaskSeeds(store: store)
        films.maskSeeds = seeds
        let frame = try #require(await RollScanner.scan(Self.samples).frames.first { $0.name.contains("Large") })
        let plain = try MaskFixtures.settings(.empty), masked = try MaskFixtures.settings(try Self.sky(ref))

        // The sheet, tier 1 from its own 960 px decode.
        let sheet = try #require(await films.film(frame, stock: 0, settings: plain, maxPixelSize: 336))
        let sheetMasked = try #require(await films.film(frame, stock: 0, settings: masked, maxPixelSize: 336))
        let top = try wiringLightness(sheetMasked, 0..<0.1) - wiringLightness(sheet, 0..<0.1)
        let bottom = try wiringLightness(sheetMasked, 0.85..<1) - wiringLightness(sheet, 0.85..<1)
        #expect(top < -3 && abs(bottom) < 0.5, "top \(top), bottom \(bottom)")
        // The frame view, tier 2 at 1201 px: the same seed, loaded once.
        let view = try #require(await films.frameFilm(frame, stock: 0, settings: plain, pixels: 1201))
        let viewMasked = try #require(await films.frameFilm(frame, stock: 0, settings: masked, pixels: 1201))
        #expect(try wiringLightness(viewMasked, 0..<0.1) - wiringLightness(view, 0..<0.1) < -3)
        #expect(seeds.keptCount == 1)
        // A seed the library does not hold shows no film rather than the frame without its mask.
        let lost = try MaskRaster(width: 64, height: 48, plane: [UInt8](repeating: 9, count: 64 * 48)).ref
        #expect(await films.film(frame, stock: 0, settings: try MaskFixtures.settings(try Self.sky(lost)), maxPixelSize: 336) == nil)
    }

    /// The overlay reads the selection as the print does (task H): the refined field on the frame view's held decode, at the
    /// overlay's size, built once; a second ask, at the same size or another, runs no refinement, and the field differs from the seed
    /// stretched only where refinement moved its edge. Without a held decode there is none, and the overlay shows the seed.
    @Test(.enabled(if: SmartMaskWiringTests.hasSample))
    func theOverlayReadsTheRefinedFieldOnTheHeldDecode() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeToyStock(id: "kodak-portra-400", in: directory)
        let films = try FilmPreviews(stocks: StockLibrary.load(from: directory).stocks, decoderChoices: DecoderChoices(route: .raw9))
        let store = MaskRasterStore(library: directory.appendingPathComponent("library"))
        let seed = try Self.topSeed()
        let ref = try store.store(seed)
        films.maskSeeds = StoredMaskSeeds(store: store)
        let frame = try #require(await RollScanner.scan(Self.samples).frames.first { $0.name.contains("Large") })
        let maskFrame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let selection = SmartSelection(kind: .sky, raster: ref, frame: maskFrame)
        #expect(films.refinedSelection(selection, on: frame, lens: .default, width: 1024, height: 683) == nil, "no decode held yet")

        _ = try #require(await films.frameFilm(frame, stock: 0, settings: try MaskFixtures.settings(try Self.sky(ref)), pixels: 1201))
        let builds = films.maskRefinerStatistics.builds
        let field = try #require(films.refinedSelection(selection, on: frame, lens: .default, width: 1024, height: 683))
        #expect(field.count == 1024 * 683)
        // The print's render refined it already: the overlay reads the kept field, and again from its own copy.
        #expect(films.maskRefinerStatistics.builds == builds && builds > 0)
        #expect(films.refinedSelection(selection, on: frame, lens: .default, width: 1024, height: 683) == field)
        let draft = try #require(films.refinedSelection(selection, on: frame, lens: .default, width: 512, height: 341))
        #expect(draft.count == 512 * 341 && films.maskRefinerStatistics.builds == builds)
        // Sky at the top, none at the bottom, and the edge where the seed's is, give or take the refinement's reach.
        func row(_ values: [UInt8], _ y: Int, width: Int) -> Double { Double(values[(y * width)..<((y + 1) * width)].reduce(0) { $0 + Int($1) }) / Double(width) }
        #expect(row(field, 20, width: 1024) > 250 && row(field, 600, width: 1024) < 5)
        let edge = (0..<683).first { row(field, $0, width: 1024) < 128 } ?? 0
        #expect(abs(edge - 683 * 102 / 341) < 20, "the refined edge at row \(edge)")
        #expect(films.heldBytes > 0)
        films.removeAll()
        #expect(films.refinedSelection(selection, on: frame, lens: .default, width: 1024, height: 683) == nil)
    }

    /// The overlay's sharp raster reads the decode the film on screen was made from: its own texels at that film's size, and where only a smaller decode
    /// is held (a film outlives its decode) it waits for the film's, one decode, rather than read another picture's edge.
    @Test(.enabled(if: SmartMaskWiringTests.hasSample))
    func aRegionIsReadFromTheDecodeItsFilmWasMadeFrom() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeToyStock(id: "kodak-portra-400", in: directory)
        let films = try FilmPreviews(stocks: StockLibrary.load(from: directory).stocks, decoderChoices: DecoderChoices(route: .raw9))
        let frame = try #require(await RollScanner.scan(Self.samples).frames.first { $0.name.contains("Large") })
        let mask = Mask(components: [MaskComponent(shape: .linear(.init(full: MaskPoint(x: 0.5, y: 0), zero: MaskPoint(x: 0.5, y: 0.6))))])
        let half = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        _ = try #require(await films.frameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: 1201))
        let decodes = films.decodeCount

        let small = try #require(await films.regionCoverage(of: mask, version: MaskSet.currentVersion, on: frame, lens: .default, pixels: 1201, fractions: half))
        #expect(abs(small.width - 601) <= 1 && small.values.count == small.width * small.height)
        #expect(films.decodeCount == decodes, "the film's own decode is held")

        let large = try #require(await films.regionCoverage(of: mask, version: MaskSet.currentVersion, on: frame, lens: .default, pixels: 2402, fractions: half))
        #expect(abs(large.width - 1201) <= 1, "its own texels, not the smaller decode's")
        #expect(films.decodeCount == decodes + 1 && films.keepsFrameDecode(frame, lens: .default, pixels: 2402))
    }

    @Test(.enabled(if: SmartMaskWiringTests.hasSample))
    func aDevelopPrintsASmartMaskFromTheSeedsItsLaneHolds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArgentSmartDevelop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                          exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
        let controls = RollControls()
        // Each develop in a roll folder and a library of its own, the library holding the seed: a second develop of the frame beside the
        // first would meet the recipe the first saved.
        func develop(_ masks: (RasterRef) throws -> MaskSet, into name: String) async throws -> CGImage {
            let place = root.appendingPathComponent(name), folder = place.appendingPathComponent("roll")
            let library = place.appendingPathComponent("library")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let raw = folder.appendingPathComponent(Self.sample.lastPathComponent)
            do { try FileManager.default.linkItem(at: Self.sample, to: raw) } catch { try FileManager.default.copyItem(at: Self.sample, to: raw) }
            let frame = try #require(await RollScanner.scan(folder).frames.first)
            let baseline = AutomaticBaseline(sourceSHA256: try RecipeStore.sha256(of: frame.url), stockID: stock.id, stockDigest: stock.digest,
                                             controls: controls, aim: PrintAim(), analysisVersion: ExposureAnalysis.currentVersion,
                                             baseRender: Recipe.Render(settings: controls.settings(for: stock, aim: PrintAim()), grain: .off))
            let ref = try MaskRasterStore(library: library).store(try Self.topSeed())
            let recipe = try Recipe.make(frame: frame, byteCount: RecipeStore.byteCount(of: frame.url), stock: stock, stockDigest: stock.digest,
                                         roll: controls, own: FrameControls(),
                                         manual: ManualEdit(adjustments: try ManualAdjustments(masks: try masks(ref)), baseline: baseline))
            let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: library)
            defer { developer.trim() }
            let outcomes = await developer.develop([RollDeveloper.Job(frame: frame, recipe: recipe)], to: place.appendingPathComponent("out"),
                                                   output: OutputSettings(size: .longEdge2048))
            guard case .developed(let file) = outcomes[0] else { throw CocoaError(.fileWriteUnknown, userInfo: ["outcome": "\(outcomes)"]) }
            let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
            return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let plain = try await develop({ _ in .empty }, into: "plain"), masked = try await develop({ try Self.sky($0) }, into: "masked")
        let top = try wiringLightness(masked, 0..<0.1) - wiringLightness(plain, 0..<0.1)
        let bottom = try wiringLightness(masked, 0.85..<1) - wiringLightness(plain, 0.85..<1)
        #expect(top < -3 && abs(bottom) < 0.5, "top \(top), bottom \(bottom)")
    }
}

/// The mean CIE L* of the rows of `image` in `band`, fractions of its height from the top, from its sRGB codes.
private func wiringLightness(_ image: CGImage, _ band: Range<Double>) throws -> Double {
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
