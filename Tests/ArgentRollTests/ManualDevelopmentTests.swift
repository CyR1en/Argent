import ArgentCore
import Foundation
import Testing
@testable import ArgentRoll

@Suite struct ManualDevelopmentTests {
    private struct Scene {
        let root: URL
        let library: URL
        let frame: Frame
        let stock: Stock
        let writer: RecipeWriter
        let sha: String
        let aim = PrintAim(level: -0.3, cast: SIMD3(0.1, -0.05, -0.05))
        let controls = RollControls()

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ArgentManual-\(UUID().uuidString)")
            library = root.appendingPathComponent("library", isDirectory: true)
            let roll = root.appendingPathComponent("roll", isDirectory: true)
            try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
            let raw = roll.appendingPathComponent("frame.ARW")
            try Data(repeating: 71, count: 4096).write(to: raw)
            frame = Frame(id: 0, url: raw, info: ARWFrameInfo(captureDate: Date(timeIntervalSince1970: 1000)))
            stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                          exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
            let digests = SourceDigests(settle: 0)
            sha = try digests.digest(of: raw).sha256
            writer = RecipeWriter(digests: digests)
        }

        func baseline(sha: String? = nil) -> AutomaticBaseline {
            AutomaticBaseline(sourceSHA256: sha ?? self.sha, stockID: stock.id, stockDigest: stock.digest,
                              controls: controls, aim: aim, analysisVersion: ExposureAnalysis.currentVersion,
                              baseRender: Recipe.Render(settings: controls.settings(for: stock, aim: aim), grain: .off))
        }

        func recipe(exposure: Float = 0.7, revision: UInt64 = 12, previous: Recipe? = nil,
                    baseline: AutomaticBaseline? = nil, lineage: String? = nil, curves: ToneCurves = .identity,
                    for frame: Frame? = nil) throws -> Recipe {
            var recipe = try Recipe.make(frame: frame ?? self.frame, byteCount: 4096, stock: stock, stockDigest: stock.digest,
                roll: controls, own: FrameControls(), analysis: ExposureAnalysis(meanStops: -0.3, validWeight: 1),
                aim: aim, grain: .off, previous: previous,
                manual: ManualEdit(adjustments: try ManualAdjustments(exposureEV: exposure, curves: curves), baseline: baseline ?? self.baseline()),
                editRevision: revision, editLineage: lineage)
            recipe.raw.sha256 = baseline?.sourceSHA256 ?? sha
            return recipe
        }

        /// Another raw, `name` in `folder` of the scene, its 4096 bytes all `byte`: the scene's own
        /// frame's bytes unless told otherwise.
        func raw(_ name: String, in folder: String = "roll", byte: UInt8 = 71) throws -> Frame {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try Data(repeating: byte, count: 4096).write(to: url)
            return Frame(id: 1, url: url, info: ARWFrameInfo(captureDate: Date(timeIntervalSince1970: 1000)))
        }

        /// `recipe` as a develop leaves it, with the receipt of `name`, which it writes.
        func exported(_ recipe: Recipe, to name: String) throws -> (recipe: Recipe, output: URL) {
            let output = root.appendingPathComponent("out", isDirectory: true).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: output)
            var exported = recipe
            exported.develops.append(.init(date: Date(timeIntervalSince1970: 3000), software: "Argent test", output: OutputSettings(),
                file: output.path, width: 40, height: 20, render: recipe.render, decode: nil, readback: nil,
                stockDigest: stock.digest, renderVersion: RenderGraph.version(for: recipe.render.settings), outputSource: SourceStamp.of(output)))
            return (exported, output)
        }
    }

    @Test func curveRecipesRoundTripAndRequireV3WithoutUpgradingSliderOnlyIntent() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let curves = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve,
                                   blue: ChannelCurve.identity.setting(.shadows, to: 25))
        let legacy = try scene.recipe()
        #expect(legacy.version == 2)
        let recipe = try scene.recipe(curves: curves)
        #expect(recipe.version == 3)
        let saved = try await scene.writer.commit(recipe: recipe, for: scene.frame, library: scene.library)
        let restored = try #require(try await scene.writer.load(for: scene.frame, library: scene.library))
        #expect(restored.manual?.adjustments.curves == curves)
        #expect(restored.manual?.baseline == saved.manual?.baseline)
        #expect(restored.render.manual?.adjustments.curves == curves)
        #expect(restored.version == 3)
        var mislabeled = recipe; mislabeled.version = 2
        #expect(throws: Recipe.ReadFailure.self) { try Recipe.decodeStrict(mislabeled.encoded()) }
    }

    @Test func curveExportReceiptsKeepTheirSnapshotWhenTheWorkingCurveChanges() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let first = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve)
        let newer = try first.setting(.red, to: ToneCurves.Preset.liftedBlacks.curve)
        let saved = try await scene.writer.commit(recipe: scene.recipe(curves: first), for: scene.frame, library: scene.library)
        let edited = try await scene.writer.commit(recipe: scene.recipe(revision: 13, previous: saved, curves: newer), for: scene.frame, library: scene.library)
        let output = scene.root.appendingPathComponent("curve.jpg")
        try Data([1,2,3]).write(to: output)
        var exported = saved
        exported.develops.append(.init(date: Date(timeIntervalSince1970: 2000), software: "Argent curve test", output: OutputSettings(),
            file: output.path, width: 40, height: 20, render: saved.render, decode: nil, readback: nil,
            stockDigest: scene.stock.digest, renderVersion: RenderGraph.version(for: saved.render.settings), outputSource: SourceStamp.of(output)))
        let merged = try await scene.writer.mergeExport(recipe: exported, for: scene.frame, library: scene.library)
        #expect(merged.manual == edited.manual && merged.editRevision == 13)
        #expect(merged.develops.last?.render.manual?.adjustments.curves == first)
        #expect(merged.version == 3)
        #expect(!FileManager.default.fileExists(atPath: output.deletingPathExtension().appendingPathExtension("argent").path))
        let bytes = try RecipeStore.sha256(of: scene.frame.url)
        #expect(bytes == scene.sha)
    }

    /// An edit keeps the Light compiler it was recorded with through saving, restoring, resolving
    /// and its develop receipts; a new edit takes the current one. A develop made under the older
    /// compiler still matches, so it is not made again.
    @Test(arguments: [ManualRenderSettings.regionsVersion, ManualRenderSettings.exposedBaseVersion, ManualRenderSettings.currentVersion])
    func eachLightCompilerRoundTripsThroughRecipesAndResolvesAsRecorded(version: String) async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let values = try ManualAdjustments(exposureEV: 0.4, contrast: 25, highlights: -30)
        do {
            let edit = ManualEdit(adjustments: values, baseline: scene.baseline(), curveVersion: version)
            var recipe = try Recipe.make(frame: scene.frame, byteCount: 4096, stock: scene.stock, stockDigest: scene.stock.digest,
                roll: scene.controls, own: FrameControls(), analysis: ExposureAnalysis(meanStops: -0.3, validWeight: 1),
                aim: scene.aim, grain: .off, manual: edit, editRevision: 12)
            recipe.raw.sha256 = scene.sha
            #expect(recipe.render.manual?.version == version && recipe.version == 2)
            let (exported, output) = try scene.exported(recipe, to: "frame-\(version).jpg")
            _ = try await scene.writer.commit(recipe: exported, for: scene.frame, library: scene.library)
            let restored = try #require(try await scene.writer.load(for: scene.frame, library: scene.library))
            #expect(restored.manual?.curveVersion == version && restored.render.manual?.version == version)
            #expect(restored.develops.last?.render.manual?.version == version)
            // The receipt's render version is the one this build gives the restored settings, so the
            // develop is not made again (`Recipe.lastDevelopMatches`).
            #expect(restored.develops.last?.renderVersion == RenderGraph.version(for: restored.render.settings))
            #expect(restored.develops.last?.renderVersion == RenderGraph.version + "+manual-" + version)
            #expect(restored.develops.last?.file == output.path)
            let resolved = try DevelopmentResolver.resolve(stock: scene.stock, stockDigest: scene.stock.digest, controls: scene.controls,
                aim: scene.aim, manual: restored.manual, grain: 0, grainSeed: 0)
            #expect(resolved.manual.version == version && resolved.manual.adjustments == values)
            #expect(RenderGraph.version(for: resolved) == RenderGraph.version + "+manual-" + version)
        }
        #expect(ManualEdit(adjustments: values, baseline: scene.baseline()).curveVersion == ManualRenderSettings.currentVersion)
    }

    @Test func resolvedBaselineStaysPinnedAndExistingChoicesStayLive() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let recipe = try scene.recipe()
        let edit = try #require(recipe.manual)
        let changedAim = PrintAim(level: 1.1, cast: SIMD3(-0.3, 0.1, 0.2))
        let pinned = try DevelopmentResolver.resolve(stock: scene.stock, stockDigest: scene.stock.digest,
            controls: scene.controls, aim: changedAim, manual: edit, grain: 1, grainSeed: 44)
        #expect(pinned.labBalance == edit.baseline.baseRender.settings.labBalance)
        #expect(pinned.manual.adjustments.exposureEV == 0.7)
        #expect(pinned.manual.referenceStops == scene.aim.level)
        #expect(pinned.grain == 1 && pinned.grainSeed == 44)
        let warm = RollControls(labBalance: .warm)
        let switched = try DevelopmentResolver.resolve(stock: scene.stock, stockDigest: scene.stock.digest,
            controls: warm, aim: changedAim, manual: edit, grain: 0, grainSeed: 0)
        #expect(switched.labBalance == warm.settings(for: scene.stock, aim: scene.aim).labBalance)
        var comparison = edit
        comparison.adjustments = .identity
        let auto = try DevelopmentResolver.resolve(stock: scene.stock, stockDigest: scene.stock.digest,
            controls: scene.controls, aim: changedAim, manual: comparison, grain: 0, grainSeed: 0)
        #expect(auto.labBalance == pinned.labBalance && auto.manual.isIdentity)
        let reset = try DevelopmentResolver.resolve(stock: scene.stock, stockDigest: scene.stock.digest,
            controls: scene.controls, aim: changedAim, manual: nil, grain: 0, grainSeed: 0)
        #expect(reset.labBalance != pinned.labBalance && reset.manual.isIdentity)
    }

    @Test func previousAnalysisBaselineAndItsStoredRenderSurviveCurrentAutoAndResume() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        var baseline = scene.baseline()
        baseline.analysisVersion = "2026-10-07-4"
        var saved = try scene.recipe(baseline: baseline)
        saved.analysis?.version = "2026-10-07-4"
        let file = scene.root.appendingPathComponent("pinned.jpg")
        let decode = DecodePins(version: DecodePins.currentVersion, decoderVersion: AppleRawDecoder.pinnedDecoderVersion,
            baselineExposure: 0, shadowBias: 0, sharpness: 0, boost: 0, boostShadow: 0, gamutMapping: false,
            highlightRecovery: true, extendedDynamicRange: 1, neutralChromaticity: .init(x: 0.33, y: 0.35),
            moireReduction: 1, contrast: 0, detail: 0, anchorDecodedMidTone: 0.08, anchorVersion: "1",
            exposureGainStops: 1, luminanceNoiseReduction: 0.4, colorNoiseReduction: 0.5,
            lensCorrection: true, scale: 1, draftMode: false)
        saved.develops.append(.init(date: Date(), software: "Argent before face fix", output: OutputSettings(),
            file: file.path, width: 10, height: 10, render: saved.render, decode: decode, readback: nil,
            stockDigest: scene.stock.digest, renderVersion: RenderGraph.version(for: saved.render.settings)))
        let read = try Recipe.decodeStrict(saved.encoded())
        let edit = try #require(read.manual)
        #expect(edit.baseline == baseline)
        let current = ExposureAnalysis(meanStops: 3, validWeight: 1,
            faces: [FaceMeasure(box: [0.4, 0.3, 0.2, 0.3], levelStops: 0, area: 0.04)])
        let liveAim = PrintAim(level: AutoPrint.levelStops(current), cast: AutoBalance.cast(current))
        #expect(liveAim != edit.baseline.aim)
        let refreshed = try Recipe.make(frame: scene.frame, byteCount: 4096, stock: scene.stock,
            stockDigest: scene.stock.digest, roll: scene.controls, own: FrameControls(), analysis: current,
            aim: liveAim, previous: read, manual: edit, editRevision: read.editRevision, editLineage: read.editLineage)
        #expect(refreshed.analysis == current && refreshed.analysis?.isCurrent == true)
        #expect(refreshed.manual?.baseline == baseline)
        #expect(refreshed.printLevel == baseline.aim.level)
        #expect(refreshed.printCast == [baseline.aim.cast.x, baseline.aim.cast.y, baseline.aim.cast.z])
        #expect(refreshed.render == saved.render)
        #expect(refreshed.lastDevelopMatches(file: file, output: OutputSettings()))
    }

    @Test func changedStockAndUnavailableResolverRequireAnExplicitBaselineUpdate() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        var edit = try #require(try scene.recipe().manual)
        #expect(throws: DevelopmentResolver.Failure.stockChanged(scene.stock.displayName)) {
            try DevelopmentResolver.resolve(stock: scene.stock, stockDigest: "another bake", controls: scene.controls,
                                            aim: scene.aim, manual: edit, grain: 0, grainSeed: 0)
        }
        edit.baseline.resolverVersion = "unavailable"
        let unchanged = try DevelopmentResolver.resolve(stock: scene.stock, stockDigest: scene.stock.digest,
            controls: scene.controls, aim: PrintAim(level: 1), manual: edit, grain: 0, grainSeed: 0)
        #expect(unchanged.labBalance == edit.baseline.baseRender.settings.labBalance)
        #expect(throws: DevelopmentResolver.Failure.unsupportedResolver("unavailable")) {
            try DevelopmentResolver.resolve(stock: scene.stock, stockDigest: scene.stock.digest,
                controls: RollControls(labBalance: .warm), aim: scene.aim, manual: edit, grain: 0, grainSeed: 0)
        }
    }

    @Test func aV1SidecarCannotEraseProtectedManualEdits() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        var legacy = Recipe(frame: scene.frame, byteCount: 4096, stock: scene.stock, stockDigest: scene.stock.digest,
                            roll: RollControls(labBalance: .neutral), own: FrameControls())
        legacy.version = 1
        legacy.raw.sha256 = scene.sha
        try legacy.encoded().write(to: RecipeStore.besideRaw(scene.frame.url))
        let saved = try await scene.writer.commit(recipe: scene.recipe(), for: scene.frame, library: scene.library)
        #expect(FileManager.default.fileExists(atPath: RecipeStore.besideRaw(scene.frame.url).appendingPathExtension("v1-backup").path))
        let lineage = try #require(saved.editLineage)
        #expect(FileManager.default.fileExists(atPath: RecipeWriter.journalURL(sha256: scene.sha, lineage: lineage, library: scene.library).path))
        // What an old binary does: ignores v2 and writes its ordinary v1 sidecar.
        legacy.develops.append(.init(date: Date(timeIntervalSince1970: 2100), software: "Argent v1", output: OutputSettings(),
            file: scene.root.appendingPathComponent("legacy.jpg").path, width: 40, height: 20, render: legacy.render,
            decode: nil, readback: nil, stockDigest: scene.stock.digest, renderVersion: RenderGraph.version))
        try legacy.encoded().write(to: RecipeStore.besideRaw(scene.frame.url), options: .atomic)
        let restored = try #require(try await scene.writer.load(for: scene.frame, library: scene.library))
        #expect(restored.manual == saved.manual && restored.editRevision == 12)
        #expect(restored.develops == legacy.develops)
        let published = try Recipe.decodeStrict(Data(contentsOf: RecipeStore.besideRaw(scene.frame.url)))
        #expect(published.version == 2 && published.manual == saved.manual)
        #expect(published.develops == legacy.develops)
    }

    @Test func aNewerPublishedEditKeepsProtectedCurveExportHistory() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let curves = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve)
        let saved = try await scene.writer.commit(recipe: scene.recipe(curves: curves), for: scene.frame, library: scene.library)
        let output = scene.root.appendingPathComponent("protected-curve.jpg")
        try Data("curve print".utf8).write(to: output)
        var exported = saved
        exported.develops.append(.init(date: Date(timeIntervalSince1970: 2200), software: "Argent", output: OutputSettings(),
            file: output.path, width: 40, height: 20, render: saved.render, decode: nil, readback: nil,
            stockDigest: scene.stock.digest, renderVersion: RenderGraph.version(for: saved.render.settings), outputSource: SourceStamp.of(output)))
        _ = try await scene.writer.mergeExport(recipe: exported, for: scene.frame, library: scene.library)
        // Another writer saw the edit before its export receipt, then published newer intent.
        var newer = try scene.recipe(exposure: 1.4, revision: 13, previous: saved)
        newer.editDate = Date(timeIntervalSince1970: 2300)
        #expect(newer.version == 2 && newer.develops.isEmpty)
        try newer.encoded().write(to: RecipeStore.besideRaw(scene.frame.url), options: .atomic)
        let restored = try #require(try await scene.writer.load(for: scene.frame, library: scene.library))
        #expect(restored.editRevision == 13 && restored.manual == newer.manual && restored.render == newer.render)
        #expect(restored.develops == exported.develops && restored.version == 3)
        let journal = RecipeWriter.journalURL(sha256: scene.sha, lineage: try #require(saved.editLineage), library: scene.library)
        let protected = try Recipe.decodeStrict(Data(contentsOf: journal))
        let published = try Recipe.decodeStrict(Data(contentsOf: RecipeStore.besideRaw(scene.frame.url)))
        #expect(protected == restored)
        #expect(published == restored)
    }

    @Test func anExportWithUnsafeLineageCreatesNoSavedRecipeOrRetryState() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let output = scene.root.appendingPathComponent("unsafe.jpg")
        try Data("print".utf8).write(to: output)
        let snapshot = try scene.recipe(lineage: "../outside")
        do {
            _ = try await scene.writer.mergeExport(recipe: snapshot, for: scene.frame, library: scene.library)
            Issue.record("An unsafe export lineage was accepted")
        } catch RecipeWriter.Failure.unsafeLineage { }
        try await scene.writer.flush(library: scene.library)
        #expect(!FileManager.default.fileExists(atPath: output.deletingPathExtension().appendingPathExtension("argent").path))
        #expect(!FileManager.default.fileExists(atPath: RecipeStore.besideRaw(scene.frame.url).path))
        #expect(!FileManager.default.fileExists(atPath: scene.library.path))
    }

    @Test func exportOfRevision12PreservesRevision13AndWritesNoOutputSidecar() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        var exported = try await scene.writer.commit(recipe: scene.recipe(), for: scene.frame, library: scene.library)
        let edited = try await scene.writer.commit(recipe: scene.recipe(exposure: 1.4, revision: 13, previous: exported),
                                                   for: scene.frame, library: scene.library)
        let output = scene.root.appendingPathComponent("image.jpg")
        try Data("exported image".utf8).write(to: output)
        exported.develops.append(.init(date: Date(timeIntervalSince1970: 2000.123456), software: "Argent test", output: OutputSettings(),
            file: output.path, width: 40, height: 20, render: exported.render, decode: nil, readback: nil,
            stockDigest: scene.stock.digest, renderVersion: RenderGraph.version(for: exported.render.settings), outputSource: SourceStamp.of(output)))
        let merged = try await scene.writer.mergeExport(recipe: exported, for: scene.frame, library: scene.library)
        #expect(merged.editRevision == 13 && merged.manual == edited.manual && merged.render == edited.render)
        #expect(merged.develops.count == 1 && merged.develops[0].render == exported.render)
        #expect(!FileManager.default.fileExists(atPath: output.deletingPathExtension().appendingPathExtension("argent").path))
        let current = try #require(try await scene.writer.load(for: scene.frame, library: scene.library))
        #expect(current.editRevision == 13 && current.manual == edited.manual && current.develops.count == 1)
        let replayed = try await scene.writer.mergeExport(recipe: exported, for: scene.frame, library: scene.library)
        #expect(replayed.editRevision == 13 && replayed.develops.count == 1)
        let staleAcknowledgement = try await scene.writer.commit(recipe: exported, for: scene.frame, library: scene.library)
        #expect(staleAcknowledgement.editRevision == 13 && staleAcknowledgement.manual == edited.manual)
    }

    @Test func futureRecipesAndConflictingExternalLineagesArePreserved() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let saved = try await scene.writer.commit(recipe: scene.recipe(), for: scene.frame, library: scene.library)
        var future = saved
        future.version = 99
        let bytes = try future.encoded()
        let sidecar = RecipeStore.besideRaw(scene.frame.url)
        try bytes.write(to: sidecar, options: .atomic)
        await #expect(throws: Recipe.ReadFailure.unsupportedVersion(99)) {
            try await scene.writer.load(for: scene.frame, library: scene.library)
        }
        await #expect(throws: Recipe.ReadFailure.unsupportedVersion(99)) {
            try await scene.writer.commit(recipe: saved, for: scene.frame, library: scene.library)
        }
        #expect(try Data(contentsOf: sidecar) == bytes)
        var external = saved
        external.editLineage = "independent-editor"
        try external.encoded().write(to: sidecar, options: .atomic)
        do {
            _ = try await scene.writer.load(for: scene.frame, library: scene.library)
            Issue.record("An independent lineage was accepted")
        } catch RecipeWriter.Failure.conflict { }
    }

    @Test func replacedRawHoldsItsOldRefinementsUntilExplicitReapplication() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let saved = try await scene.writer.commit(recipe: scene.recipe(), for: scene.frame, library: scene.library)
        try Data(repeating: 72, count: 4096).write(to: scene.frame.url)
        do {
            _ = try await scene.writer.load(for: scene.frame, library: scene.library)
            Issue.record("The replaced RAW inherited manual refinements")
        } catch RecipeWriter.Failure.sourceChanged(let held) {
            #expect(held.manual == saved.manual)
        }
        let newSHA = try RecipeStore.sha256(of: scene.frame.url)
        let reapplied = try scene.recipe(revision: 13, baseline: scene.baseline(sha: newSHA), lineage: "reapplied")
        let acknowledged = try await scene.writer.commit(recipe: reapplied, for: scene.frame, library: scene.library)
        #expect(acknowledged.manual?.baseline.sourceSHA256 == newSHA)
        #expect(FileManager.default.fileExists(atPath: RecipeWriter.journalURL(sha256: scene.sha,
            lineage: try #require(saved.editLineage), library: scene.library).path))
    }

    /// Two byte-identical raws of one roll, as when sony_a7_iv_09 was replaced by a copy of 13
    /// (smoke test, 2026-10-22): one roll's lineage, the same SHA-256, two files. Each keeps its
    /// own working record, edit and receipts, so neither develops into the other's output.
    @Test func twinRawsOfOneRollKeepTheirOwnRecordsAndReceipts() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let twin = try scene.raw("twin.ARW")
        #expect(try RecipeStore.sha256(of: twin.url) == scene.sha)
        let first = try await scene.writer.commit(recipe: scene.recipe(lineage: "roll"), for: scene.frame, library: scene.library)
        let second = try await scene.writer.commit(recipe: scene.recipe(exposure: -0.4, revision: 13, lineage: "roll", for: twin),
                                                   for: twin, library: scene.library)
        #expect(second.develops.isEmpty && second.editRevision == 13)
        let mine = try scene.exported(first, to: "frame.jpg")
        _ = try await scene.writer.mergeExport(recipe: mine.recipe, for: scene.frame, library: scene.library)
        let theirs = try scene.exported(second, to: "twin.jpg")
        _ = try await scene.writer.mergeExport(recipe: theirs.recipe, for: twin, library: scene.library)

        let frame = try #require(try await scene.writer.load(for: scene.frame, library: scene.library))
        #expect(frame.raw.fileName == "frame.ARW" && frame.manual?.adjustments.exposureEV == 0.7)
        #expect(frame.develops.map(\.file) == [mine.output.path])
        let copy = try #require(try await scene.writer.load(for: twin, library: scene.library))
        #expect(copy.raw.fileName == "twin.ARW" && copy.manual?.adjustments.exposureEV == -0.4)
        #expect(copy.develops.map(\.file) == [theirs.output.path])
        for raw in [scene.frame, twin] {
            let sidecar = try Recipe.decodeStrict(Data(contentsOf: RecipeStore.besideRaw(raw.url)))
            #expect(sidecar.raw.fileName == raw.url.lastPathComponent && sidecar.develops.count == 1)
        }
        // A later save of the copy under the roll's lineage, made before it learned its own, still lands on its record.
        let again = try await scene.writer.commit(recipe: scene.recipe(exposure: -0.6, revision: 14, lineage: "roll", for: twin),
                                                  for: twin, library: scene.library)
        #expect(again.editLineage == copy.editLineage && again.develops.map(\.file) == [theirs.output.path])
        #expect(try await scene.writer.load(for: scene.frame, library: scene.library)?.manual?.adjustments.exposureEV == 0.7)
    }

    /// A raw replaced by bytes another roll has a working record of, under that roll's lineage, as
    /// DSC04059 was by a copy of sony_a7_iv_38 (smoke test, 2026-10-22): its save, which holds the
    /// edit of the bytes it had, is neither refused for the other lineage nor given the other roll's
    /// record, and that record stays as it was. Under another name, as there, or the same.
    @Test(arguments: ["other.ARW", "frame.ARW"])
    func aRawReplacedByAnotherRollsRawSavesUnderItsOwnLineage(otherName: String) async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let other = try scene.raw(otherName, in: "other roll", byte: 72)
        let otherSHA = try RecipeStore.sha256(of: other.url)
        let theirs = try await scene.writer.commit(recipe: scene.recipe(exposure: 1.2, baseline: scene.baseline(sha: otherSHA),
            lineage: "other-roll", for: other), for: other, library: scene.library)
        let mine = try await scene.writer.commit(recipe: scene.recipe(lineage: "this-roll"), for: scene.frame, library: scene.library)
        let edit = try #require(mine.manual)
        try Data(contentsOf: other.url).write(to: scene.frame.url, options: .atomic)
        do {
            let adopted = try await scene.writer.load(for: scene.frame, library: scene.library)
            Issue.record("The replaced RAW opened with another record, lineage \(adopted?.editLineage ?? "none")")
        } catch RecipeWriter.Failure.sourceChanged(let held) {
            #expect(held.manual == edit)
        }
        // What the app saves on finding the raw replaced: the edit held, under its roll's lineage.
        var held = try Recipe.make(frame: scene.frame, byteCount: 4096, stock: scene.stock, stockDigest: scene.stock.digest,
            roll: scene.controls, own: FrameControls(), aim: scene.aim, previous: mine, manual: nil,
            editRevision: 13, editLineage: "this-roll", heldManual: edit)
        held.raw.sha256 = otherSHA
        let saved = try await scene.writer.commit(recipe: held, for: scene.frame, library: scene.library)
        #expect(saved.editLineage == "this-roll" && saved.manual == nil && saved.heldManual == edit && saved.develops.isEmpty)
        let reopened = try #require(try await scene.writer.load(for: scene.frame, library: scene.library))
        #expect(reopened.editLineage == "this-roll" && reopened.heldManual == edit && reopened.manual == nil)
        let untouched = try #require(try await scene.writer.load(for: other, library: scene.library))
        #expect(untouched.raw.fileName == otherName && untouched.editLineage == "other-roll")
        #expect(untouched.manual == theirs.manual && untouched.editRevision == theirs.editRevision)
    }

    /// Twins on a locked card, where only the journal keeps each one's edit: each keeps its own record.
    @Test func twinsOnALockedCardKeepTheirOwnJournalRecords() async throws {
        let scene = try Scene()
        let twin = try scene.raw("twin.ARW"), roll = scene.frame.url.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roll.path)
            try? FileManager.default.removeItem(at: scene.root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roll.path)
        _ = try await scene.writer.commit(recipe: scene.recipe(lineage: "roll"), for: scene.frame, library: scene.library)
        _ = try await scene.writer.commit(recipe: scene.recipe(exposure: -0.4, revision: 13, lineage: "roll", for: twin),
                                          for: twin, library: scene.library)
        #expect(!FileManager.default.fileExists(atPath: RecipeStore.besideRaw(scene.frame.url).path))
        let frame = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(frame?.raw.fileName == "frame.ARW" && frame?.manual?.adjustments.exposureEV == 0.7)
        let copy = try await scene.writer.load(for: twin, library: scene.library)
        #expect(copy?.raw.fileName == "twin.ARW" && copy?.manual?.adjustments.exposureEV == -0.4)
    }

    /// On a locked card, an untouched twin's develop arrives under the roll's lineage, as the app gives
    /// a frame with no recipe: its receipt goes to its own record, and the frame keeps its own.
    @Test func anUntouchedTwinsReceiptLeavesTheFramesRecordOnALockedCard() async throws {
        let scene = try Scene()
        let twin = try scene.raw("twin.ARW"), roll = scene.frame.url.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roll.path)
            try? FileManager.default.removeItem(at: scene.root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roll.path)
        _ = try await scene.writer.commit(recipe: scene.recipe(lineage: "roll"), for: scene.frame, library: scene.library)
        var untouched = try Recipe.make(frame: twin, byteCount: 4096, stock: scene.stock, stockDigest: scene.stock.digest,
            roll: scene.controls, own: FrameControls(), aim: scene.aim, editRevision: 20, editLineage: "roll")
        untouched.raw.sha256 = scene.sha
        let receipt = try scene.exported(untouched, to: "twin.jpg")
        _ = try await scene.writer.mergeExport(recipe: receipt.recipe, for: twin, library: scene.library)
        let frame = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(frame?.raw.fileName == "frame.ARW" && frame?.manual?.adjustments.exposureEV == 0.7 && frame?.develops.isEmpty == true)
        let copy = try await scene.writer.load(for: twin, library: scene.library)
        #expect(copy?.raw.fileName == "twin.ARW" && copy?.develops.map(\.file) == [receipt.output.path])
        #expect(!FileManager.default.fileExists(atPath: receipt.output.deletingPathExtension().appendingPathExtension("argent").path))
    }

    /// A frame developed and then copied over another of its roll, the smoke test's order: the copy,
    /// read before it is ever saved, has none of the frame's record, and develops to its own name.
    @Test func aTwinReadBeforeItsFirstSaveTakesNoneOfTheFramesRecord() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let first = try await scene.writer.commit(recipe: scene.recipe(lineage: "roll"), for: scene.frame, library: scene.library)
        let mine = try scene.exported(first, to: "frame.jpg")
        _ = try await scene.writer.mergeExport(recipe: mine.recipe, for: scene.frame, library: scene.library)
        let twin = try scene.raw("twin.ARW")
        let copy = try await scene.writer.load(for: twin, library: scene.library)
        #expect(copy?.manual == nil && copy?.develops.isEmpty != false, "the copy read \(copy?.develops.map(\.file) ?? [])")
        var job = try Recipe.make(frame: twin, byteCount: 4096, stock: scene.stock, stockDigest: scene.stock.digest,
            roll: scene.controls, own: FrameControls(), aim: scene.aim, previous: copy)
        job.raw.sha256 = scene.sha
        let files = RollDeveloper.files(for: [RollDeveloper.Job(frame: twin, recipe: job)],
                                        in: mine.output.deletingLastPathComponent(), output: OutputSettings())
        #expect(files.map(\.lastPathComponent) == ["twin.jpg"])
    }

    /// What a build before 2026-10-22 left of twins: the twin's save over the frame's record, the
    /// frame's receipt merged into it, and that record republished beside the twin and then beside
    /// the frame. Neither is taken for the other's, and the twin does not develop into the frame's output.
    @Test func twinsMergedByAnEarlierBuildAreReadApart() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let twin = try scene.raw("twin.ARW")
        let first = try await scene.writer.commit(recipe: scene.recipe(lineage: "roll"), for: scene.frame, library: scene.library)
        let mine = try scene.exported(first, to: "frame.jpg")
        let developed = try await scene.writer.mergeExport(recipe: mine.recipe, for: scene.frame, library: scene.library)
        var shared = try scene.recipe(exposure: -0.4, revision: 13, lineage: "roll", for: twin)
        shared.develops = developed.develops
        shared.editDate = Date(timeIntervalSince1970: 4000)
        try shared.encoded().write(to: RecipeWriter.journalURL(sha256: scene.sha, lineage: "roll", library: scene.library), options: .atomic)
        try shared.encoded().write(to: RecipeStore.besideRaw(twin.url), options: .atomic)

        let frame = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(frame?.raw.fileName == "frame.ARW" && frame?.manual?.adjustments.exposureEV == 0.7)
        let copy = try #require(try await scene.writer.load(for: twin, library: scene.library))
        #expect(copy.raw.fileName == "twin.ARW" && copy.manual?.adjustments.exposureEV == -0.4)
        let files = RollDeveloper.files(for: [RollDeveloper.Job(frame: twin, recipe: copy)],
                                        in: mine.output.deletingLastPathComponent(), output: OutputSettings())
        #expect(files.map(\.lastPathComponent) == ["twin.jpg"])

        try shared.encoded().write(to: RecipeStore.besideRaw(scene.frame.url), options: .atomic)
        let overwritten = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(overwritten?.raw.fileName != "twin.ARW" && overwritten?.manual?.adjustments.exposureEV != -0.4)
    }

    /// A raw replaced by its roll's twin, its edit saved held under the twin lineage beside the other
    /// raw's record, and put back while the app was closed: it opens to its own record, edit and
    /// receipts, and the other raw's record is as it was.
    @Test func aRawPutBackWhileClosedAfterItsTwinReplacedItOpensToItsOwnRecord() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let other = try scene.raw("other.ARW", byte: 72)
        let otherSHA = try RecipeStore.sha256(of: other.url)
        let theirs = try await scene.writer.commit(recipe: scene.recipe(exposure: 1.2, baseline: scene.baseline(sha: otherSHA),
            lineage: "roll", for: other), for: other, library: scene.library)
        let first = try await scene.writer.commit(recipe: scene.recipe(lineage: "roll"), for: scene.frame, library: scene.library)
        let mine = try scene.exported(first, to: "frame.jpg")
        _ = try await scene.writer.mergeExport(recipe: mine.recipe, for: scene.frame, library: scene.library)
        let edit = try #require(first.manual), original = try Data(contentsOf: scene.frame.url)
        try Data(contentsOf: other.url).write(to: scene.frame.url, options: .atomic)
        var held = try Recipe.make(frame: scene.frame, byteCount: 4096, stock: scene.stock, stockDigest: scene.stock.digest,
            roll: scene.controls, own: FrameControls(), aim: scene.aim, previous: first, manual: nil,
            editRevision: 14, editLineage: "roll", heldManual: edit)
        held.raw.sha256 = otherSHA
        let saved = try await scene.writer.commit(recipe: held, for: scene.frame, library: scene.library)
        #expect(saved.editLineage != "roll" && saved.heldManual == edit)

        try original.write(to: scene.frame.url, options: .atomic)
        let reopened = try #require(try await scene.writer.load(for: scene.frame, library: scene.library))
        #expect(reopened.manual == edit && reopened.heldManual == nil && reopened.develops.map(\.file) == [mine.output.path])
        let kept = try #require(try await scene.writer.load(for: other, library: scene.library))
        #expect(kept.raw.fileName == "other.ARW" && kept.manual == theirs.manual)
    }

    /// Two rolls' records of one raw under its name and two lineages, and a third copy with neither a
    /// sidecar nor a binding: its save is refused, as its opening is, rather than written over either.
    @Test func aCopyOfARawTwoRollsEditedApartIsNotSavedOverEither() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let mine = try await scene.writer.commit(recipe: scene.recipe(lineage: "roll-a"), for: scene.frame, library: scene.library)
        let b = try scene.raw("frame.ARW", in: "roll b")
        _ = try await scene.writer.commit(recipe: scene.recipe(exposure: -0.4, lineage: "roll-b", for: b), for: b, library: scene.library)
        let c = try scene.raw("frame.ARW", in: "roll c")
        await #expect(throws: RecipeWriter.Failure.self) { try await scene.writer.load(for: c, library: scene.library) }
        var empty = try Recipe.make(frame: c, byteCount: 4096, stock: scene.stock, stockDigest: scene.stock.digest,
            roll: scene.controls, own: FrameControls(), aim: scene.aim, editRevision: 20, editLineage: "roll-a")
        empty.raw.sha256 = scene.sha
        await #expect(throws: RecipeWriter.Failure.self) { try await scene.writer.commit(recipe: empty, for: c, library: scene.library) }
        let kept = try #require(try await scene.writer.load(for: scene.frame, library: scene.library))
        #expect(kept.manual == mine.manual && kept.editRevision == mine.editRevision)
    }

    /// Two locked cards mounted in turn at one path, each with the same file name and edited in its
    /// own session: the first card back opens with its edit, saves it to its one record, and a copy of
    /// its raws elsewhere opens with the newest edit.
    @Test func aLockedCardsEditComesBackAfterAnotherCardAtTheSamePath() async throws {
        let scene = try Scene()
        let card = scene.root.appendingPathComponent("card", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: card.path)
            try? FileManager.default.removeItem(at: scene.root)
        }
        func insert(_ byte: UInt8) throws -> Frame {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: card.path)
            let raw = try scene.raw("DSC00001.ARW", in: "card", byte: byte)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: card.path)
            return raw
        }
        let one = try insert(71)
        _ = try await scene.writer.commit(recipe: scene.recipe(lineage: "card-one", for: one), for: one, library: scene.library)
        let two = try insert(72), twoSHA = try RecipeStore.sha256(of: two.url)
        #expect(try await scene.writer.load(for: two, library: scene.library) == nil)
        _ = try await scene.writer.commit(recipe: scene.recipe(exposure: -0.4, baseline: scene.baseline(sha: twoSHA),
            lineage: "card-two", for: two), for: two, library: scene.library)
        let back = try insert(71)
        let reopened = try #require(try await scene.writer.load(for: back, library: scene.library))
        #expect(reopened.manual?.adjustments.exposureEV == 0.7 && reopened.editLineage == "card-one")
        _ = try await scene.writer.commit(recipe: scene.recipe(exposure: 0.9, revision: 30, lineage: "card-one", for: back),
                                          for: back, library: scene.library)
        let copied = try scene.raw("DSC00001.ARW", in: "disk")
        #expect(try await scene.writer.load(for: copied, library: scene.library)?.manual?.adjustments.exposureEV == 0.9)
    }

    /// Raws renumbered after the first is deleted (DSC2 to DSC1, DSC3 to DSC2), with their sidecars
    /// or without: each opens with the edit of its own bytes, never the deleted frame's, though its
    /// records name a file beside it.
    @Test(arguments: [true, false])
    func renumberedRawsKeepTheirOwnEdits(sidecarsMoved: Bool) async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let one = try scene.raw("DSC1.ARW", byte: 71), two = try scene.raw("DSC2.ARW", byte: 72), three = try scene.raw("DSC3.ARW", byte: 73)
        for (frame, exposure) in [(one, Float(0.7)), (two, -0.4), (three, 0.2)] {
            let sha = try RecipeStore.sha256(of: frame.url)
            _ = try await scene.writer.commit(recipe: scene.recipe(exposure: exposure, baseline: scene.baseline(sha: sha),
                lineage: "roll", for: frame), for: frame, library: scene.library)
        }
        let files = FileManager.default
        try files.removeItem(at: one.url)
        try files.moveItem(at: two.url, to: one.url)
        try files.moveItem(at: three.url, to: two.url)
        if sidecarsMoved {
            try files.removeItem(at: RecipeStore.besideRaw(one.url))
            try files.moveItem(at: RecipeStore.besideRaw(two.url), to: RecipeStore.besideRaw(one.url))
            try files.moveItem(at: RecipeStore.besideRaw(three.url), to: RecipeStore.besideRaw(two.url))
        }
        let first = try await scene.writer.load(for: one, library: scene.library)
        #expect(first?.manual?.adjustments.exposureEV == -0.4)
        let second = try await scene.writer.load(for: two, library: scene.library)
        #expect(second?.manual?.adjustments.exposureEV == 0.2)
    }

    /// A raw renamed alone, its old name gone, and then edited: its save continues its one record,
    /// so a copy of the roll with neither sidecars nor bindings opens with the edit.
    @Test func aRenamedRawsSaveKeepsItsOneRecord() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        _ = try await scene.writer.commit(recipe: scene.recipe(lineage: "roll"), for: scene.frame, library: scene.library)
        let renamed = Frame(id: 0, url: scene.frame.url.deletingLastPathComponent().appendingPathComponent("A1.ARW"), info: scene.frame.info)
        try FileManager.default.moveItem(at: scene.frame.url, to: renamed.url)
        let loaded = try #require(try await scene.writer.load(for: renamed, library: scene.library))
        #expect(loaded.manual?.adjustments.exposureEV == 0.7)
        _ = try await scene.writer.commit(recipe: scene.recipe(exposure: 0.9, revision: 13, lineage: "roll", for: renamed),
                                          for: renamed, library: scene.library)
        let records = try FileManager.default.contentsOfDirectory(
            atPath: RecipeWriter.journalURL(sha256: scene.sha, lineage: "roll", library: scene.library).deletingLastPathComponent().path)
        #expect(records == ["roll.json"])
        let copy = try scene.raw("A1.ARW", in: "copy")
        #expect(try await scene.writer.load(for: copy, library: scene.library)?.manual?.adjustments.exposureEV == 0.9)
    }

    /// Twins an earlier build merged, the copy named as a numbered develop of the frame would be
    /// ("frame 2"): the frame's develop does not take the copy's output for its own.
    @Test func aFramesDevelopLeavesATwinNamedAsItsNumberedOutput() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        _ = try scene.raw("frame 2.ARW")
        var merged = try scene.exported(try scene.recipe(lineage: "roll"), to: "frame.jpg").recipe
        var copy = try #require(try scene.exported(merged, to: "frame 2.jpg").recipe.develops.last)
        copy.date = Date(timeIntervalSince1970: 4000)
        merged.develops.append(copy)
        let files = RollDeveloper.files(for: [RollDeveloper.Job(frame: scene.frame, recipe: merged)],
                                        in: scene.root.appendingPathComponent("out"), output: OutputSettings())
        #expect(files.map(\.lastPathComponent) == ["frame.jpg"])
    }

    /// A develop's receipt whose journal write failed stays to be saved; once the raw
    /// it was made from is replaced, a flush lets it go rather than fail on it every time. An edit
    /// still waiting for a replaced raw is still refused, for the app to save it again.
    @Test func aStaleReceiptIsLetGoAndAStaleEditIsNot() async throws {
        let scene = try Scene()
        let journal = RecipeWriter.journalURL(sha256: scene.sha, lineage: "roll", library: scene.library).deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: journal.path)
            try? FileManager.default.removeItem(at: scene.root)
        }
        let other = try scene.raw("other.ARW")
        let saved = try await scene.writer.commit(recipe: scene.recipe(lineage: "roll"), for: scene.frame, library: scene.library)
        let receipt = try scene.exported(saved, to: "frame.jpg")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: journal.path)
        await #expect(throws: (any Error).self) {
            try await scene.writer.mergeExport(recipe: receipt.recipe, for: scene.frame, library: scene.library)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: journal.path)
        try Data(repeating: 72, count: 4096).write(to: scene.frame.url, options: .atomic)
        #expect(try await scene.writer.flush(library: scene.library).isEmpty)

        _ = try await scene.writer.commit(recipe: scene.recipe(lineage: "roll", for: other), for: other, library: scene.library)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: journal.path)
        await #expect(throws: (any Error).self) {
            try await scene.writer.commit(recipe: scene.recipe(exposure: 1.1, revision: 14, lineage: "roll", for: other),
                                          for: other, library: scene.library)
        }
        try Data(repeating: 73, count: 4096).write(to: other.url, options: .atomic)
        await #expect(throws: RecipeWriter.Failure.self) { try await scene.writer.flush(library: scene.library) }
    }

    @Test func aFailedWorkingSaveCanBeRetriedAtTheFlushBarrier() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try Data("not a directory".utf8).write(to: scene.library)
        do {
            _ = try await scene.writer.commit(recipe: scene.recipe(), for: scene.frame, library: scene.library)
            Issue.record("Saving into a file succeeded")
        } catch { }
        try FileManager.default.removeItem(at: scene.library)
        try await scene.writer.flush(library: scene.library)
        let restored = try #require(try await scene.writer.load(for: scene.frame, library: scene.library))
        #expect(restored.manual?.adjustments.exposureEV == 0.7 && restored.editRevision == 12)
    }

    /// A flush is one library's: another library's failing write neither fails it nor is retried by it,
    /// and waits for its own library's flush, as each model flushes only the library it saves to.
    @Test func aFlushLeavesAnotherLibrarysFailingWriteToItsOwnFlush() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let other = scene.root.appendingPathComponent("other library", isDirectory: true)
        let copy = try scene.raw("frame.ARW", in: "copy")
        try Data("not a directory".utf8).write(to: other)
        await #expect(throws: (any Error).self) {
            try await scene.writer.commit(recipe: scene.recipe(lineage: "copy", for: copy), for: copy, library: other)
        }
        _ = try await scene.writer.commit(recipe: scene.recipe(lineage: "roll"), for: scene.frame, library: scene.library)
        #expect(try await scene.writer.flush(library: scene.library).isEmpty)
        await #expect(throws: (any Error).self) { try await scene.writer.flush(library: other) }

        try FileManager.default.removeItem(at: other)
        #expect(Array(try await scene.writer.flush(library: other).keys) == [copy.url])
        #expect(try await scene.writer.flush(library: other).isEmpty)
        #expect(try await scene.writer.load(for: copy, library: other)?.editLineage == "copy")
        #expect(try await scene.writer.load(for: scene.frame, library: scene.library)?.editLineage == "roll")
    }

    /// A flush takes its library's writes before it persists any, so the first, which creates a library
    /// reached through a symlink, cannot leave the rest pending as another library's.
    @Test func aFlushThatCreatesItsLibraryPersistsEveryWriteOfIt() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let real = scene.root.appendingPathComponent("real", isDirectory: true)
        let link = scene.root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let library = link.appendingPathComponent("library", isDirectory: true)
        // A file where the library goes, so each commit fails and stays pending.
        try Data("not a directory".utf8).write(to: real.appendingPathComponent("library"))
        let frames = try [("a.ARW", UInt8(72)), ("b.ARW", 73), ("c.ARW", 74)].map { try scene.raw($0.0, in: "copy", byte: $0.1) }
        for frame in frames {
            let sha = try RecipeStore.sha256(of: frame.url)
            await #expect(throws: (any Error).self) {
                try await scene.writer.commit(recipe: scene.recipe(baseline: scene.baseline(sha: sha), lineage: "roll", for: frame),
                                              for: frame, library: library)
            }
        }
        try FileManager.default.removeItem(at: real.appendingPathComponent("library"))
        #expect(Set(try await scene.writer.flush(library: library).keys) == Set(frames.map(\.url)))
        #expect(try await scene.writer.flush(library: library).isEmpty)
    }
    @Test func rollChoicesFollowTheEditRevisionEvenWhenAnOlderExportFinishesLater() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        var older = try scene.recipe(revision: 12)
        older.roll = RollControls(labBalance: .warm)
        older.editDate = Date(timeIntervalSince1970: 3000)
        older.develops.append(.init(date: Date(timeIntervalSince1970: 4000), software: "Argent", output: OutputSettings(),
            file: "/tmp/old.jpg", width: 10, height: 10, render: older.render, decode: nil, readback: nil,
            stockDigest: scene.stock.digest, renderVersion: RenderGraph.version))
        var newer = try scene.recipe(revision: 13)
        newer.roll = RollControls(labBalance: .cool)
        newer.editDate = Date(timeIntervalSince1970: 2000)
        let otherFrame = Frame(id: 1, url: scene.root.appendingPathComponent("other.ARW"), info: ARWFrameInfo())
        let restored = RestoredRoll(frames: [scene.frame, otherFrame], recipes: [older, newer])
        #expect(restored.controls == newer.roll)
        #expect(restored.destination?.path == "/tmp")
    }

    @Test func unavailableCurveVersionRestoresIntentButCannotResolvePixels() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let recipe = try scene.recipe()
        var json = try #require(JSONSerialization.jsonObject(with: recipe.encoded()) as? [String: Any])
        var manual = try #require(json["manual"] as? [String: Any])
        manual["curveVersion"] = "future-curve"
        json["manual"] = manual
        var render = try #require(json["render"] as? [String: Any])
        var mapping = try #require(render["manual"] as? [String: Any])
        mapping["version"] = "future-curve"
        render["manual"] = mapping
        json["render"] = render
        let restored = try Recipe.decodeStrict(JSONSerialization.data(withJSONObject: json))
        let edit = try #require(restored.manual)
        #expect(edit.adjustments == recipe.manual?.adjustments)
        #expect(edit.curveVersion == "future-curve")
        #expect(throws: ManualDevelopmentError.self) {
            try DevelopmentResolver.resolve(stock: scene.stock, stockDigest: scene.stock.digest,
                controls: scene.controls, aim: scene.aim, manual: edit, grain: 0, grainSeed: 0)
        }
    }

    @Test func aReadOnlyCardCanMigrateThroughItsProtectedLibrary() async throws {
        let scene = try Scene()
        let roll = scene.frame.url.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roll.path)
            try? FileManager.default.removeItem(at: scene.root)
        }
        var legacy = Recipe(frame: scene.frame, byteCount: 4096, stock: scene.stock, stockDigest: scene.stock.digest,
                            roll: scene.controls, own: FrameControls())
        legacy.version = 1
        legacy.raw.sha256 = scene.sha
        let sidecar = RecipeStore.besideRaw(scene.frame.url)
        try legacy.encoded().write(to: sidecar)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roll.path)
        let saved = try await scene.writer.commit(recipe: scene.recipe(), for: scene.frame, library: scene.library)
        #expect(saved.version == 2 && saved.manual != nil)
        let restored = try #require(try await scene.writer.load(for: scene.frame, library: scene.library))
        #expect(restored.manual == saved.manual && restored.editRevision == saved.editRevision)
        let backupFolder = scene.library.appendingPathComponent("ManualDevelopment/v2/Backups").appendingPathComponent(scene.sha)
        #expect((try FileManager.default.contentsOfDirectory(atPath: backupFolder.path)).count == 1)
    }

    @Test func undoingReapplyCanSaveNeutralPixelsAndKeepTheOldSourceIntent() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let original = try await scene.writer.commit(recipe: scene.recipe(), for: scene.frame, library: scene.library)
        let held = try #require(original.manual)
        try Data(repeating: 72, count: 4096).write(to: scene.frame.url)
        let newSHA = try RecipeStore.sha256(of: scene.frame.url)
        let reapplied = try await scene.writer.commit(recipe: scene.recipe(revision: 13,
            baseline: scene.baseline(sha: newSHA), lineage: "new-source"), for: scene.frame, library: scene.library)
        var undone = try Recipe.make(frame: scene.frame, byteCount: 4096, stock: scene.stock, stockDigest: scene.stock.digest,
            roll: scene.controls, own: FrameControls(), aim: scene.aim, previous: reapplied, manual: nil,
            editRevision: 14, editLineage: reapplied.editLineage, heldManual: held)
        undone.raw.sha256 = newSHA
        let saved = try await scene.writer.commit(recipe: undone, for: scene.frame, library: scene.library)
        #expect(saved.manual == nil && saved.render.manual == nil && saved.heldManual == held)
        let reopened = try #require(try await scene.writer.load(for: scene.frame, library: scene.library))
        #expect(reopened.manual == nil && reopened.heldManual == held && reopened.raw.sha256 == newSHA)
        #expect(FileManager.default.fileExists(atPath: RecipeWriter.journalURL(sha256: scene.sha,
            lineage: try #require(original.editLineage), library: scene.library).path))
    }

    @Test func unrevisionedLegacyIdentityChoicesAcquireANewRevisionBeforeTheirReceipt() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        var warm = Recipe(frame: scene.frame, byteCount: 4096, stock: scene.stock, stockDigest: scene.stock.digest,
                          roll: scene.controls, own: FrameControls(labBalance: .warm))
        warm.raw.sha256 = scene.sha
        let first = try await scene.writer.commit(recipe: warm, for: scene.frame, library: scene.library)
        var cool = Recipe(frame: scene.frame, byteCount: 4096, stock: scene.stock, stockDigest: scene.stock.digest,
                          roll: scene.controls, own: FrameControls(labBalance: .cool), previous: first)
        cool.raw.sha256 = scene.sha
        #expect(cool.editRevision == nil)
        var acknowledged = try await scene.writer.commit(recipe: cool, for: scene.frame, library: scene.library)
        #expect(acknowledged.editRevision == (first.editRevision ?? 0) + 1)
        let output = scene.root.appendingPathComponent("identity.jpg")
        try Data("cool print".utf8).write(to: output)
        acknowledged.develops.append(.init(date: Date(timeIntervalSince1970: 5000), software: "Argent", output: OutputSettings(),
            file: output.path, width: 10, height: 10, render: acknowledged.render, decode: nil, readback: nil,
            stockDigest: scene.stock.digest, renderVersion: RenderGraph.version, outputSource: SourceStamp.of(output)))
        let current = try await scene.writer.mergeExport(recipe: acknowledged, for: scene.frame, library: scene.library)
        #expect(current.render == cool.render && current.render != warm.render)
        #expect(current.frame.labBalance == .cool && current.develops.last?.render == cool.render)
    }

    @Test func aNewerSaveRetainsTheReceiptOfAnExportWhoseJournalWriteFailed() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        var exported = try await scene.writer.commit(recipe: scene.recipe(), for: scene.frame, library: scene.library)
        let edited = try await scene.writer.commit(recipe: scene.recipe(exposure: 1.4, revision: 13, previous: exported),
                                                   for: scene.frame, library: scene.library)
        let folder = RecipeWriter.journalURL(sha256: scene.sha, lineage: try #require(edited.editLineage), library: scene.library)
            .deletingLastPathComponent()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let output = scene.root.appendingPathComponent("failed-journal.jpg")
        try Data("exported image".utf8).write(to: output)
        exported.develops.append(.init(date: Date(timeIntervalSince1970: 2000.123456), software: "Argent", output: OutputSettings(),
            file: output.path, width: 10, height: 10, render: exported.render, decode: nil, readback: nil,
            stockDigest: scene.stock.digest, renderVersion: RenderGraph.version(for: exported.render.settings), outputSource: SourceStamp.of(output)))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        do {
            _ = try await scene.writer.mergeExport(recipe: exported, for: scene.frame, library: scene.library)
            Issue.record("Writing to the locked journal succeeded")
        } catch { }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let newer = try await scene.writer.commit(recipe: scene.recipe(exposure: 1.8, revision: 14, previous: edited),
                                                  for: scene.frame, library: scene.library)
        #expect(newer.editRevision == 14 && newer.manual?.adjustments.exposureEV == 1.8)
        #expect(newer.develops.count == 1 && newer.develops[0].render == exported.render)
    }

    @Test func explicitlyDiscardingFailedRetryStateLeavesThePriorDurableRecipeIntact() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let saved = try await scene.writer.commit(recipe: scene.recipe(), for: scene.frame, library: scene.library)
        let journal = RecipeWriter.journalURL(sha256: scene.sha, lineage: try #require(saved.editLineage), library: scene.library)
        let priorBytes = try Data(contentsOf: journal)
        let directory = journal.deletingLastPathComponent()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        do {
            _ = try await scene.writer.commit(recipe: scene.recipe(exposure: 1.4, revision: 13, previous: saved),
                                               for: scene.frame, library: scene.library)
            Issue.record("Saving to the locked journal succeeded")
        } catch { }
        await scene.writer.discardPending(for: [scene.frame], library: scene.library)
        // The directory stays locked: success proves that the barrier no longer retries rev13.
        try await scene.writer.flush(library: scene.library)
        #expect(try Data(contentsOf: journal) == priorBytes)
        let restored = try #require(try await scene.writer.load(for: scene.frame, library: scene.library))
        #expect(restored.editRevision == 12 && restored.manual == saved.manual)
    }

    /// The Original starting point of the scene's raw through its stock with `controls`
    /// (docs/manual-development.md, "Starting from Original").
    private func original(_ scene: Scene, controls: RollControls? = nil) -> AutomaticBaseline {
        let controls = controls ?? scene.controls
        return .original(sourceSHA256: scene.sha, stockID: scene.stock.id, stockDigest: scene.stock.digest, controls: controls,
                         baseRender: Recipe.Render(settings: controls.settings(for: scene.stock, aim: PrintAim()), grain: .off))
    }

    /// An Original prints at the neutral aim whatever Auto aims the frame at: with Lab balance on Auto
    /// at the daylight reference, as Neutral does, its cast being zero; Neutral, Warm and Cool as
    /// chosen; and with Rated at's lab compensation, which is a control, not Auto. Its Light reference is 0.
    @Test(arguments: RollControls.LabBalance.allCases)
    func anOriginalResolvesAtTheNeutralAimUnderEachLabBalanceAndRating(labBalance: RollControls.LabBalance) throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let autoAim = PrintAim(level: -0.6, cast: SIMD3(0.2, -0.1, -0.1))
        for ratedAt in RollControls.RatedAt.allCases {
            let controls = RollControls(ratedAt: ratedAt, labBalance: labBalance)
            let neutral = RollControls(ratedAt: ratedAt, labBalance: .neutral).settings(for: scene.stock)
            #expect(ratedAt == .boxSpeed || neutral.labBalance != .zero, "Rated at \(ratedAt) has no lab compensation to keep")
            let expected = labBalance == .auto ? neutral.labBalance : neutral.labBalance + labBalance.printBalance
            // Pinned under these controls, and pinned under others and resolved under these.
            for pinned in [controls, RollControls()] {
                let edit = ManualEdit(adjustments: .identity, baseline: original(scene, controls: pinned))
                let resolved = try DevelopmentResolver.resolve(stock: scene.stock, stockDigest: scene.stock.digest,
                    controls: controls, aim: autoAim, manual: edit, grain: 0, grainSeed: 0)
                #expect(resolved.labBalance == expected, "\(labBalance) \(ratedAt)")
                #expect(resolved.ratedAt == neutral.ratedAt && resolved.printExposure == 0 && resolved.manual.isIdentity)
                let auto = try DevelopmentResolver.resolve(stock: scene.stock, stockDigest: scene.stock.digest,
                    controls: controls, aim: autoAim, manual: nil, grain: 0, grainSeed: 0)
                #expect(auto.labBalance != resolved.labBalance)
                var refined = edit
                refined.adjustments = try ManualAdjustments(exposureEV: 0.5, highlights: -20)
                let adjusted = try DevelopmentResolver.resolve(stock: scene.stock, stockDigest: scene.stock.digest,
                    controls: controls, aim: autoAim, manual: refined, grain: 0, grainSeed: 0)
                #expect(adjusted.labBalance == expected && adjusted.manual.referenceStops == 0)
            }
        }
        // Auto with a neutral aim is the same print: the origin, not the aim, tells them apart.
        let automatic = RollControls(labBalance: .auto)
        #expect(automatic.settings(for: scene.stock, aim: PrintAim()) == RollControls(labBalance: .neutral).settings(for: scene.stock))
    }

    /// An Original with identity values is kept through recipe write, read and validation, at
    /// version 4; it never reads back as an Auto pin, and an Auto pin is written as before.
    @Test func anIdentityOriginalPersistsAtV4AndNeverReadsAsAnAutoPin() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let edit = ManualEdit(adjustments: .identity, baseline: original(scene))
        var recipe = try Recipe.make(frame: scene.frame, byteCount: 4096, stock: scene.stock, stockDigest: scene.stock.digest,
            roll: scene.controls, own: FrameControls(), analysis: ExposureAnalysis(meanStops: -0.3, validWeight: 1),
            aim: scene.aim, grain: .off, manual: edit, editRevision: 12)
        recipe.raw.sha256 = scene.sha
        #expect(recipe.version == 4 && recipe.requiredVersion == 4)
        #expect(recipe.manual == edit && recipe.render.manual == nil)
        #expect(recipe.printLevel == 0 && recipe.printCast == [0, 0, 0])
        let encoded = try recipe.encoded()
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""origin" : "original""#))
        let read = try Recipe.decodeStrict(encoded)
        #expect(read.manual == edit && read.manual?.baseline.origin == .original)
        _ = try await scene.writer.commit(recipe: recipe, for: scene.frame, library: scene.library)
        let restored = try #require(try await scene.writer.load(for: scene.frame, library: scene.library))
        #expect(restored.manual == edit && restored.version == 4)
        let sidecar = try Recipe.decodeStrict(Data(contentsOf: RecipeStore.besideRaw(scene.frame.url)))
        #expect(sidecar.manual?.baseline.origin == .original)
        #expect(RestoredRoll(frames: [scene.frame], recipes: [restored]).manualEdits[scene.frame.url] == edit)

        // Labelled for a reader before Original, it is refused rather than read as an Auto pin.
        var mislabeled = recipe; mislabeled.version = 3
        #expect(throws: Recipe.ReadFailure.invalid("an Original starting point requires recipe version 4")) {
            try Recipe.decodeStrict(mislabeled.encoded())
        }
        // So is an origin this build does not know, and an Original away from the neutral aim.
        let unknown = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: #""origin" : "original""#,
                                                                                   with: #""origin" : "elsewhere""#)
        #expect(throws: Recipe.ReadFailure.self) { try Recipe.decodeStrict(Data(unknown.utf8)) }
        var moved = recipe; moved.manual?.baseline.aim = scene.aim
        #expect(throws: Recipe.ReadFailure.invalid("an Original starting point must be at the neutral aim")) {
            try Recipe.decodeStrict(moved.encoded())
        }
        let movedEdit = try #require(moved.manual)
        #expect(throws: DevelopmentResolver.Failure.invalidBaseline) {
            try DevelopmentResolver.resolve(stock: scene.stock, stockDigest: scene.stock.digest, controls: scene.controls,
                                            aim: scene.aim, manual: movedEdit, grain: 0, grainSeed: 0)
        }
        // A held Original needs version 4 as well.
        var held = recipe; held.manual = nil; held.heldManual = edit
        #expect(held.requiredVersion == 4)
        // An Auto pin, even at the neutral aim, is written without an origin and stays at version 2.
        var neutralAuto = scene.baseline(); neutralAuto.aim = PrintAim()
        let auto = try scene.recipe(baseline: neutralAuto)
        #expect(auto.version == 2 && auto.manual?.baseline.origin == .auto)
        #expect(!String(decoding: try auto.encoded(), as: UTF8.self).contains("origin"))
    }

    /// Develop's recipe for an Original carries it, and renders apart from Auto's where Auto's aim is
    /// not neutral, so a develop made under Auto is made again; where Auto's aim is neutral the two are
    /// one print, and one file.
    @Test func anOriginalsDevelopRecipeCarriesItAndRendersApartFromAuto() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let analysis = ExposureAnalysis(meanStops: -0.3, validWeight: 1)
        func make(_ manual: ManualEdit?, aim: PrintAim, previous: Recipe? = nil) throws -> Recipe {
            var recipe = try Recipe.make(frame: scene.frame, byteCount: 4096, stock: scene.stock, stockDigest: scene.stock.digest,
                roll: scene.controls, own: FrameControls(), analysis: analysis, aim: aim, grain: .off, sharpen: true,
                previous: previous, manual: manual, editRevision: 12)
            recipe.raw.sha256 = scene.sha
            return recipe
        }
        let decode = DecodePins(version: DecodePins.currentVersion, decoderVersion: AppleRawDecoder.pinnedDecoderVersion,
            baselineExposure: 0, shadowBias: 0, sharpness: 0, boost: 0, boostShadow: 0, gamutMapping: false,
            highlightRecovery: true, extendedDynamicRange: 1, neutralChromaticity: .init(x: 0.33, y: 0.35),
            moireReduction: 1, contrast: 0, detail: 0, anchorDecodedMidTone: 0.08, anchorVersion: "1",
            exposureGainStops: 1, luminanceNoiseReduction: 0.4, colorNoiseReduction: 0.5,
            lensCorrection: true, scale: 1, draftMode: false)
        let output = scene.root.appendingPathComponent("frame.jpg")
        try Data([1, 2, 3]).write(to: output)
        /// `recipe` with the receipt of a develop of it to `output`.
        func developed(_ recipe: Recipe) -> Recipe {
            var developed = recipe
            developed.develops.append(.init(date: Date(), software: "Argent test", output: OutputSettings(), file: output.path,
                width: 10, height: 10, render: recipe.render, decode: decode, readback: nil, stockDigest: scene.stock.digest,
                renderVersion: RenderGraph.version(for: recipe.render.settings)))
            return developed
        }
        let edit = ManualEdit(adjustments: .identity, baseline: original(scene))
        let automatic = developed(try make(nil, aim: scene.aim))
        #expect(automatic.lastDevelopMatches(file: output, output: OutputSettings()))
        let fromOriginal = try make(edit, aim: scene.aim, previous: automatic)
        #expect(fromOriginal.manual?.baseline.origin == .original && fromOriginal.version == 4)
        #expect(fromOriginal.render != automatic.render)
        #expect(fromOriginal.render == Recipe.Render(settings: try DevelopmentResolver.resolve(stock: scene.stock,
            stockDigest: scene.stock.digest, controls: scene.controls, aim: PrintAim(), manual: nil, grain: 0,
            grainSeed: scene.frame.grainSeed, sharpen: true), grain: .off))
        #expect(!fromOriginal.lastDevelopMatches(file: output, output: OutputSettings()))
        let neutralAuto = developed(try make(nil, aim: PrintAim()))
        let neutralOriginal = try make(edit, aim: PrintAim(), previous: neutralAuto)
        #expect(neutralOriginal.render == neutralAuto.render)
        #expect(neutralOriginal.lastDevelopMatches(file: output, output: OutputSettings()))
    }
}
