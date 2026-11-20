import CoreGraphics
import Foundation
import Metal
import Testing
@testable import ArgentCore
@testable import ArgentRoll

@Suite(.serialized, .rawDecodes) struct LensPreviewTests {
    private static let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")
    private static var hasSample: Bool { FileManager.default.fileExists(atPath: sample.path) }

    private func scene() throws -> (URL, Frame, [Stock]) {
        let folder = try temporaryFolder()
        let raw = folder.appendingPathComponent("frame.ARW")
        try FileManager.default.copyItem(at: Self.sample, to: raw)
        try writeToyStock(id: "toy", in: folder)
        return (folder, Frame(id: 0, url: raw, info: try ARWFrameInfo.read(from: raw)), StockLibrary.load(from: folder).stocks)
    }

    private func bytes(_ image: CGImage) throws -> Data { try #require(image.dataProvider?.data as Data?) }

    @MainActor
    @Test(.enabled(if: LensPreviewTests.hasSample))
    func aColdSynchronousLookupLeavesTheLensMemoEmptyUntilTheSheetDecodes() async throws {
        let (folder, frame, stocks) = try scene()
        defer { try? FileManager.default.removeItem(at: folder) }
        let films = try FilmPreviews(stocks: stocks)
        let settings = DevelopSettings()
        #expect(films.decodeCount == 0 && films.lensCount == 0)
        #expect(films.cachedFilm(frame, stock: 0, settings: settings, maxPixelSize: 336) == nil)
        #expect(!films.hasLinearPreview(frame, lens: .default))
        #expect(films.lensCount == 0)

        let decoded = try #require(await films.film(frame, stock: 0, settings: settings, maxPixelSize: 336))
        #expect(films.decodeCount == 1 && films.lensCount == 1)
        #expect(films.hasLinearPreview(frame, lens: .default))
        #expect(films.cachedFilm(frame, stock: 0, settings: settings, maxPixelSize: 336) === decoded)
    }

    @Test(.enabled(if: LensPreviewTests.hasSample))
    func autoAndTheDescriptorReadTheLensOffDecodeLiveFromDiskAndWhenSeeded() async throws {
        let (folder, frame, stocks) = try scene()
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = LinearDiskCache(folder: folder.appendingPathComponent("cache"))
        let gpu = try GPU(), decoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        var options = DecodeOptions()
        options.maxLongSide = FilmPreviews.previewLongSide
        options.lensCorrection = false
        let decoded = try decoder.decode(frame.url, options: options)
        let expected = ExposureAnalyzer.measure(decoded, workingSpace: gpu.workingColorSpace, info: frame.info)
        for mode in ["live", "disk", "seeded"] {
            let films = try FilmPreviews(stocks: stocks, diskCache: disk, decoderChoices: DecoderChoices(route: .apple))
            var analysis = expected.analysis
            if mode == "seeded" {
                analysis.meanStops += 1
                films.seedAnalysis(analysis, for: frame, source: try #require(SourceStamp.of(frame.url)))
            }
            _ = try #require(await films.film(frame, stock: 0, settings: DevelopSettings(), maxPixelSize: 336))
            #expect(await films.analysis(frame) == analysis, "\(mode)")
            #expect(await films.descriptor(frame) == expected.descriptor, "\(mode)")
            #expect(films.diskHitCount == (mode == "live" ? 0 : 1))
            disk.flush()
            films.removeAll()
        }
    }

    @Test(.enabled(if: LensPreviewTests.hasSample))
    func decoderCorrectedDiskEntriesAreIgnoredAndStagePicturesSurviveReload() async throws {
        let (folder, frame, stocks) = try scene()
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = LinearDiskCache(folder: folder.appendingPathComponent("cache"))
        let gpu = try GPU(), decoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        var on = DecodeOptions()
        on.maxLongSide = FilmPreviews.previewLongSide
        let onKey = try #require(LinearDiskCache.key(for: frame.url, longSide: FilmPreviews.previewLongSide, decoderVersion: "8"))
        let offKey = try #require(LinearDiskCache.key(for: frame.url, longSide: FilmPreviews.previewLongSide,
                                                    decoderVersion: "8", lensCorrection: false))
        #expect(onKey != offKey)
        disk.store(try decoder.decode(frame.url, options: on), key: onKey)
        disk.flush()
        let films = try FilmPreviews(stocks: stocks, diskCache: disk, decoderChoices: DecoderChoices(route: .apple))
        let stageKey = films.key(frame, lens: .default)
        let stage = try #require(await films.film(frame, stock: 0, settings: DevelopSettings(), maxPixelSize: 336))
        #expect(films.diskHitCount == 0 && films.decodeCount == 1)
        disk.flush()
        let off = try #require(disk.load(offKey, pool: gpu.texturePool))
        #expect(off.lens == nil && off.pins?.lensCorrection == false)
        #expect(disk.load(onKey, pool: gpu.texturePool)?.pins?.lensCorrection == true)
        let reloaded = try FilmPreviews(stocks: stocks, diskCache: disk, decoderChoices: DecoderChoices(route: .apple))
        let cached = try #require(await reloaded.film(frame, stock: 0, settings: DevelopSettings(), maxPixelSize: 336))
        #expect(try bytes(cached) == bytes(stage))
        #expect(reloaded.diskHitCount == 1 && reloaded.decodeCount == 0)
        let models = MaskModels(directory: nil, ledgerFile: folder.appendingPathComponent("ledger.json"))
        let masks = BundledSmartMasks(films: films, models: models, app: "Argent test")
        let staged = try #require(await masks.picture(of: frame, lens: .default, stopped: { false }))
        let stagedPicture = try #require(staged.content as? BundledSmartMasks.Picture)
        #expect(!stagedPicture.input.source.lensCorrection)
        let kept = try #require(await masks.picture(of: frame, lens: .default, stopped: { false }))
        #expect((kept.content as? BundledSmartMasks.Picture)?.key == stagedPicture.key)
        let keptStage = try #require(await reloaded.film(frame, stock: 0, settings: DevelopSettings(), maxPixelSize: 336))
        #expect(try bytes(keptStage) == bytes(stage))
        // A replacement at the same path must resolve its header again.
        try #require(films.lensCorrection(for: frame, settings: .default) != nil)
        try Data([1, 2, 3]).write(to: frame.url, options: .atomic)
        #expect(films.lensCorrection(for: frame, settings: .default)?.status.distortion == .none("none in the file"))
        let replacement = films.key(frame, lens: .default)
        #expect(replacement != stageKey)
        #expect(replacement.hasSuffix("|" + ResolvedLensCorrection.uncorrected("none in the file").digest))
    }

    @Test(.enabled(if: LensPreviewTests.hasSample), arguments: ["default", "vignette=100,vignette-midpoint=0", "vignette=-100,vignette-midpoint=100"])
    func neutralAndMaskReadersUseTheSceneAtTheSheetFrameAndRefinedSizes(_ arguments: String) async throws {
        let (folder, frame, stocks) = try scene()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gpu = try GPU(), stage = try LensStage(gpu: gpu), decoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let intent = try LensSettings(arguments: arguments)
        let develop = try settings(arguments)
        let lens = LensResolver.correction(for: frame.url, settings: intent)
        let films = try FilmPreviews(stocks: stocks, decoderChoices: DecoderChoices(route: .apple))
        let renderer = try FilmRenderer(gpu: gpu, stock: stocks[0])
        var sheetOptions = DecodeOptions()
        sheetOptions.maxLongSide = FilmPreviews.previewLongSide
        sheetOptions.lensCorrection = false
        let sheet = try stage.correct(decoder.decode(frame.url, options: sheetOptions), with: lens)
        let expectedSheet = try films.displayImage(renderer.render(sheet, settings: develop).image.texture,
                                                    space: .displayP3, maxPixelSize: 336)
        let shownSheet = try #require(await films.film(frame, stock: 0, settings: develop, maxPixelSize: 336))
        #expect(try bytes(shownSheet) == bytes(expectedSheet))
        for pixels in [960, 1201, 2560] {
            let neutral = try #require(await films.frameNeutral(frame, lens: intent, pixels: pixels))
            let held = try #require(films.frameDecode(of: frame, lens: intent, pixels: pixels))
            var options = FilmPreviews.frameDecodeOptions(longSide: pixels)
            options.lensCorrection = false
            let scene = try stage.correct(decoder.decode(frame.url, options: options), with: lens)
            #expect(held.lens == lens && held.pins?.lensCorrection == false)
            #expect(ExposureAnalyzer.pixels(of: held.texture) == ExposureAnalyzer.pixels(of: scene.texture))
            #expect(try bytes(neutral) == bytes(films.displayImage(scene.texture, space: .displayP3, maxPixelSize: pixels)))
        }
        #expect(await films.refineFrame(frame, lens: intent, pixels: 2560))
        let refined = try #require(films.frameDecode(of: frame, lens: intent, pixels: 2560))
        let refinedNeutral = try #require(await films.frameNeutral(frame, lens: intent, pixels: 2560))
        #expect(refined.lens == lens)
        #expect(try bytes(refinedNeutral) == bytes(films.displayImage(refined.texture, space: .displayP3, maxPixelSize: 2560)))
        let mask = try #require(await films.maskInputPicture(frame, lens: intent))
        let expectedMask = try MaskInputPictureMaker(gpu: gpu).make(from: refined)
        #expect(mask.digest == expectedMask.digest && !mask.source.lensCorrection)
        let own = try FilmPreviews(stocks: stocks, decoderChoices: DecoderChoices(route: .apple))
        let ownMask = try #require(await own.maskInputPicture(frame, lens: intent))
        var options = FilmPreviews.frameDecodeOptions(longSide: MaskInputPicture.longSide)
        options.lensCorrection = false
        let maskScene = try stage.correct(decoder.decode(frame.url, options: options), with: lens)
        #expect(ownMask.digest == (try MaskInputPictureMaker(gpu: gpu).make(from: maskScene)).digest)
    }
}

extension LensPreviewTests {
    private static func entered(_ gate: DispatchSemaphore) -> Bool { gate.wait(timeout: .now() + 10) == .success }

    private func settings(_ arguments: String) throws -> DevelopSettings {
        DevelopSettings(manual: try ManualRenderSettings(adjustments: .identity.settingLens(LensSettings(arguments: arguments)), referenceStops: 0))
    }

    @Test func inactiveHueHandlesDoNotChangeRenderedImageKeys() throws {
        for exposure: Float in [0, 0.5] {
            let adjustments = try ManualAdjustments(exposureEV: exposure)
            var plain = DevelopSettings()
            plain.manual = try ManualRenderSettings(adjustments: adjustments, referenceStops: 1)
            var handles = plain
            handles.manual = try ManualRenderSettings(
                adjustments: adjustments.settingLens(LensSettings(arguments: "defringe-purple-hue=0:100,defringe-green-hue=0:100")),
                referenceStops: 1)
            func key(_ settings: DevelopSettings) -> RenderedImageKey {
                .film("same-scene", stock: 0, stockID: "toy", settings: settings, space: .sRGB, pixels: 336)
            }
            #expect(key(plain) == key(handles))
            #expect(Set([key(plain), key(handles)]).count == 1)
            #expect(RenderGraph.version(for: plain) == RenderGraph.version(for: handles))
        }
    }

    @Test(.enabled(if: LensPreviewTests.hasSample))
    func lensChangesRestageWithoutDecodeAndKeepTheNeighbours() async throws {
        let (folder, frame, stocks) = try scene()
        defer { try? FileManager.default.removeItem(at: folder) }
        let films = try FilmPreviews(stocks: stocks, decoderChoices: DecoderChoices(route: .apple))
        let side = 600
        var neighbours: [Frame] = []
        for index in 1...2 {
            let raw = folder.appendingPathComponent("neighbour\(index).ARW")
            try FileManager.default.copyItem(at: frame.url, to: raw)
            neighbours.append(Frame(id: index, url: raw, info: frame.info))
        }
        for neighbour in neighbours { await films.holdFrameDecode(neighbour, lens: .default, pixels: side) }
        _ = try #require(await films.frameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: side))
        let before = try #require(films.frameDecode(of: frame, lens: .default, pixels: side))
        let count = films.decodeCount
        for amount in [110, 120, 130, 140, 150] {
            let settings = try settings("distortion-amount=\(amount)")
            let film = try #require(await films.frameFilm(frame, stock: 0, settings: settings, pixels: side))
            let after = try #require(films.frameDecode(of: frame, lens: settings.lens, pixels: side))
            #expect(after.image !== before.image && after.lens?.digest != before.lens?.digest)
            #expect(after.lens?.digest == LensResolver.correction(for: frame.url, settings: settings.lens).digest)
            #expect(films.cachedFrameFilm(frame, stock: 0, settings: settings, pixels: side) === film)
            #expect(films.decodeCount == count)
            #expect(films.frameDecodeStatistic.split(separator: ",").count == 3)
            #expect(neighbours.allSatisfy { films.keepsFrameDecode($0, lens: .default, pixels: side) })
        }
        let new = try settings("distortion-amount=150")
        #expect(films.frameDecode(of: frame, lens: .default, pixels: side) == nil)
        #expect(films.keepsFrameDecode(frame, lens: new.lens, pixels: side))
    }

    @Test(.enabled(if: LensPreviewTests.hasSample))
    func thirtyLensAmountsReplaceOneManualFilmAndKeepAnotherFrame() async throws {
        let (folder, frame, stocks) = try scene()
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("neighbour.ARW")
        try FileManager.default.copyItem(at: frame.url, to: raw)
        let neighbour = Frame(id: 1, url: raw, info: frame.info)
        let films = try FilmPreviews(stocks: stocks, filmCacheBytes: 0, frameImageBytes: 2 << 20,
                                     decoderChoices: DecoderChoices(route: .apple))
        let other = try #require(await films.frameFilm(neighbour, stock: 0, settings: DevelopSettings(), pixels: 300))
        var previous: DevelopSettings?
        for amount in 101...130 {
            var current = try settings("distortion-amount=\(amount)")
            current.manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 0.5, lens: current.lens), referenceStops: 0)
            let film = try #require(await films.frameFilm(frame, stock: 0, settings: current, pixels: 300))
            #expect(films.cachedFrameFilm(frame, stock: 0, settings: current, pixels: 300) === film)
            if let previous { #expect(films.cachedFrameFilm(frame, stock: 0, settings: previous, pixels: 300) == nil) }
            #expect(films.renderedCacheCount == 2)
            previous = current
        }
        #expect(films.cachedFrameFilm(neighbour, stock: 0, settings: DevelopSettings(), pixels: 300) === other)
    }

    @Test(.enabled(if: LensPreviewTests.hasSample))
    func aFilmInFlightKeepsItsOwnKeyWhenTheLensSettingsMove() async throws {
        let (folder, frame, stocks) = try scene()
        defer { try? FileManager.default.removeItem(at: folder) }
        let films = try FilmPreviews(stocks: stocks, decoderChoices: DecoderChoices(route: .apple))
        let old = try settings("distortion-amount=150"), new = try settings("distortion=off")
        // Resolve both before the old film lands: lookups must resolve their own settings, even after keepKey runs.
        let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        films.observeWork = { note in
            if note.hasPrefix("frame-render ") && note.hasSuffix(" +") {
                began.signal()
                _ = release.wait(timeout: .now() + 10)
            }
        }
        defer { release.signal(); films.observeWork = nil }
        let pending = Task { await films.frameFilm(frame, stock: 0, settings: old, pixels: 600) }
        let started = await Task.detached { Self.entered(began) }.value
        try #require(started)
        _ = films.lensCorrection(for: frame, settings: new.lens)
        #expect(films.cachedFrameFilm(frame, stock: 0, settings: new, pixels: 600) == nil)
        release.signal()
        let image = try #require(await pending.value)
        #expect(films.cachedFrameFilm(frame, stock: 0, settings: old, pixels: 600) === image)
        #expect(films.cachedFrameFilm(frame, stock: 0, settings: new, pixels: 600) == nil)
        #expect(films.key(frame, lens: new.lens) != films.key(frame, lens: old.lens))
        // Resolving another lens alone does not supersede a render. Requesting its film does.
        films.observeWork = nil
        let replacement = try #require(await films.frameFilm(frame, stock: 0, settings: new, pixels: 600))
        #expect(films.cachedFrameFilm(frame, stock: 0, settings: new, pixels: 600) === replacement)
        #expect(films.cachedFrameFilm(frame, stock: 0, settings: old, pixels: 600) == nil)
        #expect(films.renderedCacheCount == 1)
    }

    @Test(.enabled(if: LensPreviewTests.hasSample))
    func aRefinementFinishingAfterALensChangeUsesTheReplacingEntriesLens() async throws {
        let (folder, frame, stocks) = try scene()
        defer { try? FileManager.default.removeItem(at: folder) }
        let films = try FilmPreviews(stocks: stocks, decoderChoices: DecoderChoices(route: .apple))
        await films.holdFrameDecode(frame, lens: .default, pixels: 600)
        let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        films.observeWork = { note in
            if note.hasPrefix("refine ") && note.hasSuffix(" +") {
                began.signal()
                _ = release.wait(timeout: .now() + 10)
            }
        }
        defer { release.signal(); films.observeWork = nil }
        let pending = Task { await films.refineFrame(frame, lens: .default, pixels: 600) }
        let started = await Task.detached { Self.entered(began) }.value
        try #require(started)
        let new = try LensSettings(arguments: "distortion-amount=150")
        await films.holdFrameDecode(frame, lens: new, pixels: 600)
        release.signal()
        #expect(await pending.value)
        #expect(films.isFrameDecodeRefined(frame, lens: new, pixels: 600))
        let decoded = try #require(films.frameDecode(of: frame, lens: new, pixels: 600))
        #expect(decoded.lens?.digest == LensResolver.correction(for: frame.url, settings: new).digest)
        let count = films.decodeCount
        await films.holdFrameDecode(frame, lens: .default, pixels: 600)
        #expect(films.isFrameDecodeRefined(frame, lens: .default, pixels: 600) && films.decodeCount == count)
    }

    @Test func printLimitsIgnoreLensSettings() throws {
        #expect(FilmPreviews.printLimitsProbe(try settings("distortion-amount=150")) == FilmPreviews.printLimitsProbe(DevelopSettings()))
    }
}

extension LensPreviewTests {
    @Test(.enabled(if: LensPreviewTests.hasSample))
    func aLensOnlyEditWithoutACurveHasAutosPixels() throws {
        let (folder, _, stocks) = try scene()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gpu = try GPU(), renderer = try FilmRenderer(gpu: gpu, stock: stocks[0])
        let image = try gpu.texturePool.acquire(width: 12, height: 8)
        let pixels = [Float16](repeating: 0.18, count: 12 * 8 * 4)
        pixels.withUnsafeBytes {
            image.texture.replace(region: MTLRegionMake2D(0, 0, 12, 8), mipmapLevel: 0,
                                  withBytes: $0.baseAddress!, bytesPerRow: 12 * 8)
        }
        let frame = try LensStage(gpu: gpu).correct(LinearFrame(image: image, decoderVersion: "synthetic", scale: 1),
                                                  with: .uncorrected("none in the file"))
        let auto = try renderer.render(frame, settings: DevelopSettings())
        let edited = try renderer.render(frame, settings: settings("distortion=off"))
        #expect(ExposureAnalyzer.pixels(of: auto.image.texture) == ExposureAnalyzer.pixels(of: edited.image.texture))
    }
}

extension LensPreviewTests {
    @Test(.enabled(if: LensPreviewTests.hasSample))
    func defringeChangesTheSceneKeyWhileAutoAndPrintLimitsStayTheSame() async throws {
        let (folder, frame, stocks) = try scene()
        defer { try? FileManager.default.removeItem(at: folder) }
        let films = try FilmPreviews(stocks: stocks, decoderChoices: DecoderChoices(route: .apple))
        let on = try settings("defringe-purple=10")
        #expect(films.key(frame, lens: on.lens) != films.key(frame, lens: .default))
        #expect(FilmPreviews.printLimitsProbe(on) == FilmPreviews.printLimitsProbe(DevelopSettings()))
        _ = try #require(await films.film(frame, stock: 0, settings: DevelopSettings(), maxPixelSize: 336))
        let before = try #require(await films.analysis(frame))
        _ = try #require(await films.film(frame, stock: 0, settings: on, maxPixelSize: 336))
        #expect(await films.analysis(frame) == before)
        let off = try settings("defringe-purple-hue=0:100")
        #expect(films.key(frame, lens: off.lens) == films.key(frame, lens: .default))
    }
}
