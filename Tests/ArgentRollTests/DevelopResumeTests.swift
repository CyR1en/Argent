import ArgentCore
import Foundation
import Testing
@testable import ArgentRoll

@Suite struct DevelopResumeTests {
    private static var stock: Stock {
        Stock(id: "resume-test", displayName: "Resume test", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
              exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
    }

    private static func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func job(_ raw: URL, previousOutput: URL? = nil,
                            output: OutputSettings = OutputSettings()) -> RollDeveloper.Job {
        let frame = Frame(id: 0, url: raw, info: ARWFrameInfo())
        var recipe = Recipe(frame: frame, byteCount: RecipeStore.byteCount(of: raw), stock: stock, stockDigest: stock.digest,
                            roll: RollControls(), own: FrameControls(), grain: output.grain)
        if let previousOutput {
            let pins = DecodePins(version: DecodePins.currentVersion, decoderVersion: AppleRawDecoder.pinnedDecoderVersion,
                                  baselineExposure: 0, shadowBias: 0, sharpness: 0, boost: 0, boostShadow: 0,
                                  gamutMapping: false, highlightRecovery: true, extendedDynamicRange: 1,
                                  neutralChromaticity: .init(x: 0.33, y: 0.35), moireReduction: nil, contrast: 0, detail: 0,
                                  anchorDecodedMidTone: 0.08, anchorVersion: "1", exposureGainStops: 1,
                                  luminanceNoiseReduction: 0.4, colorNoiseReduction: 0.5, lensCorrection: true,
                                  scale: 1, draftMode: false)
            recipe.develops.append(.init(date: Date(), software: "Argent test", output: output, file: previousOutput.path,
                                         width: 1, height: 1, render: recipe.render, decode: pins, readback: nil,
                                         stockDigest: stock.digest, renderVersion: RenderGraph.version))
        }
        return RollDeveloper.Job(frame: frame, recipe: recipe)
    }

    @Test func removingAnUnrelatedLowerNumberedFileStillSkipsTheRecordedOutput() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("DSC1.ARW")
        try Data("raw stand-in; any attempt to decode it fails".utf8).write(to: raw)
        let lower = folder.appendingPathComponent("DSC1.jpg")
        let developed = folder.appendingPathComponent("DSC1 2.jpg")
        try Data("unrelated".utf8).write(to: lower)
        try Data("developed".utf8).write(to: developed)
        let output = OutputSettings()
        var job = Self.job(raw, previousOutput: developed, output: output)
        job.recipe.raw.sha256 = try RecipeStore.sha256(of: raw)
        let developer = try RollDeveloper(stocks: [Self.stock], software: "Argent test",
                                          library: folder.appendingPathComponent("recipes"),
                                          digests: SourceDigests(settle: 0), decoderChoices: DecoderChoices(route: .apple))

        #expect(await developer.develop([job], to: folder, output: output) == [.alreadyDeveloped(developed)])
        try FileManager.default.removeItem(at: lower)
        #expect(await developer.develop([job], to: folder, output: output) == [.alreadyDeveloped(developed)])
        #expect(!FileManager.default.fileExists(atPath: lower.path))
    }

    @Test func recordedOutputsAreReusedOnlyInTheirDestinationAndFormat() throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let raw = folder.appendingPathComponent("DSC1.ARW")
        let jpeg = OutputSettings()
        let previous = folder.appendingPathComponent("DSC1 2.jpg")
        let job = Self.job(raw, previousOutput: previous, output: jpeg)

        #expect(RollDeveloper.files(for: [job], in: destination, output: jpeg) == [destination.appendingPathComponent("DSC1.jpg")])
        let heic = OutputSettings(format: .heic)
        #expect(RollDeveloper.files(for: [job], in: folder, output: heic) == [folder.appendingPathComponent("DSC1.heic")])
        #expect(RollDeveloper.files(for: [job], in: folder, output: jpeg) == [previous])
    }

    /// A copy of a roll shares its recipes, receipts and all: an output its record says was developed
    /// from a raw still elsewhere is that raw's (#20). One from a raw no longer there, or replaced by
    /// another file, is a moved roll's, and one recorded without its raw is reused as before.
    @Test func recordedOutputsOfARawStillElsewhereAreNotReused() throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("roll/DSC1.ARW")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: original)
        let developed = folder.appendingPathComponent("DSC1.jpg")
        try Data("developed".utf8).write(to: developed)
        var copy = Self.job(folder.appendingPathComponent("roll copy/DSC1.ARW"), previousOutput: developed)
        copy.recipe.develops[0].outputSource = SourceStamp.of(developed)
        copy.recipe.develops[0].rawFile = original.path
        copy.recipe.develops[0].rawSource = SourceStamp.of(original)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: original.path)

        #expect(RollDeveloper.files(for: [copy], in: folder, output: OutputSettings()) == [folder.appendingPathComponent("DSC1 2.jpg")])
        #expect(RestoredRoll(frames: [copy.frame], recipes: [copy.recipe]).destination == nil)
        try FileManager.default.removeItem(at: original)
        #expect(RollDeveloper.files(for: [copy], in: folder, output: OutputSettings()) == [developed])
        #expect(RestoredRoll(frames: [copy.frame], recipes: [copy.recipe]).destination?.canonicalPath == folder.canonicalPath)
        try Data("another photo".utf8).write(to: original)
        #expect(RollDeveloper.files(for: [copy], in: folder, output: OutputSettings()) == [developed])
        copy.recipe.develops[0].rawFile = nil
        #expect(RollDeveloper.files(for: [copy], in: folder, output: OutputSettings()) == [developed])
    }

    @Test func newFramesDoNotTakeARecordedNameWhoseOutputIsMissing() throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = Self.job(folder.appendingPathComponent("card-a/DSC1.ARW"))
        let recorded = folder.appendingPathComponent("DSC1.jpg")
        let second = Self.job(folder.appendingPathComponent("card-b/DSC1.ARW"), previousOutput: recorded)

        #expect(RollDeveloper.files(for: [first, second], in: folder, output: OutputSettings())
                == [folder.appendingPathComponent("DSC1 2.jpg"), recorded])
    }

    @Test func duplicateNamesNeverShareAnOutputOrReplaceAnUnrelatedFile() throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let unrelated = folder.appendingPathComponent("DSC1.jpg")
        try Data("unrelated".utf8).write(to: unrelated)
        let recorded = folder.appendingPathComponent("DSC1 2.jpg")
        let first = Self.job(folder.appendingPathComponent("card-a/DSC1.ARW"), previousOutput: recorded)
        let second = Self.job(folder.appendingPathComponent("card-b/DSC1.ARW"), previousOutput: recorded)

        #expect(RollDeveloper.files(for: [first, second], in: folder, output: OutputSettings())
                == [recorded, folder.appendingPathComponent("DSC1 3.jpg")])
        #expect(try Data(contentsOf: unrelated) == Data("unrelated".utf8))
    }

    /// A develop resumes only at the settled Auto decision it was made at: one at another revision is
    /// made again, and one made before decisions were settled, which recorded none, still matches
    /// (docs/research/auto/sequence-consistency.md, stage 4).
    @Test func aDevelopAtAnotherAutoRevisionIsMadeAgain() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("DSC1.ARW")
        try Data("raw stand-in; any attempt to decode it fails".utf8).write(to: raw)
        let file = folder.appendingPathComponent("DSC1.jpg")
        try Data("developed".utf8).write(to: file)
        let developer = try RollDeveloper(stocks: [Self.stock], software: "Argent test",
                                          library: folder.appendingPathComponent("recipes"),
                                          digests: SourceDigests(settle: 0), decoderChoices: DecoderChoices(route: .apple))
        let first = String(repeating: "1", count: 64), second = String(repeating: "2", count: 64)
        func job(recorded: String?, now: String?) throws -> RollDeveloper.Job {
            var job = Self.job(raw, previousOutput: file)
            job.recipe.raw.sha256 = try RecipeStore.sha256(of: raw)
            job.recipe.develops[0].autoRevision = recorded
            job.autoRevision = now
            return job
        }
        let recorded = try job(recorded: first, now: first).recipe
        #expect(recorded.lastDevelopMatches(file: file, output: OutputSettings(), autoRevision: first))
        #expect(!recorded.lastDevelopMatches(file: file, output: OutputSettings(), autoRevision: second))
        #expect(!recorded.lastDevelopMatches(file: file, output: OutputSettings()))

        #expect(await developer.develop([try job(recorded: first, now: first)], to: folder, output: OutputSettings())
                == [.alreadyDeveloped(file)])
        #expect(await developer.develop([try job(recorded: nil, now: second)], to: folder, output: OutputSettings())
                == [.alreadyDeveloped(file)])
        let outcomes = await developer.develop([try job(recorded: first, now: second)], to: folder, output: OutputSettings())
        guard case .failed = outcomes[0] else {
            Issue.record("A develop at another revision must be made again, and the stand-in cannot be decoded: \(outcomes)")
            return
        }
        #expect(try Data(contentsOf: file) == Data("developed".utf8))
    }

    @Test func aChangedRawCannotUseAnOldFrameHeaderEvenWithoutAMeasurement() throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("DSC1.ARW")
        try Data("raw a".utf8).write(to: raw)
        let source = try #require(SourceStamp.of(raw))
        let unmeasured = Self.job(raw)
        #expect(!unmeasured.recipe.isMeasured)
        let captured = RollDeveloper.Job(frame: unmeasured.frame, recipe: unmeasured.recipe, frameSource: source)

        #expect(RollDeveloper.checkingSource(captured, digests: SourceDigests()).job != nil)
        try Data("raw b".utf8).write(to: raw)
        let checked = RollDeveloper.checkingSource(captured, digests: SourceDigests())

        guard case .failed(let reason) = checked else {
            Issue.record("A raw replaced after its header snapshot must fail before decoding")
            return
        }
        #expect(reason.contains("changed after its header was read"))
    }

    @Test func aRawReplacedAfterItsCheckCannotSkipAnOldOutput() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let raws = (0..<4).map { folder.appendingPathComponent("DSC\($0).ARW") }
        let files = (0..<4).map { folder.appendingPathComponent("DSC\($0).jpg") }
        var jobs: [RollDeveloper.Job] = []
        for (raw, file) in zip(raws, files) {
            try Data("original raw".utf8).write(to: raw)
            try Data("original output".utf8).write(to: file)
            var job = Self.job(raw, previousOutput: file)
            job.recipe.raw.sha256 = try RecipeStore.sha256(of: raw)
            job.recipe.editRevision = 1
            jobs.append(job)
        }
        let digests = SourceDigests(settle: 0)
        let developer = try RollDeveloper(stocks: [Self.stock], software: "Argent test",
            library: folder.appendingPathComponent("recipes"), digests: digests,
            decoderChoices: DecoderChoices(route: .apple), recipeWriter: RecipeWriter(digests: digests))
        let continueChecks = DispatchSemaphore(value: 0)
        developer.observeCheck = { index in
            // The other two check lanes wait, so only frame 0's completed check can
            // take ticket 3. Replace its raw before the whole checking batch returns.
            if index == 1 || index == 2 {
                if continueChecks.wait(timeout: .now() + 5) == .timedOut { Issue.record("Source checks did not reach ticket 3") }
            } else if index == 3 {
                do { try Data("replacement raw with different bytes".utf8).write(to: raws[0], options: .atomic) }
                catch { Issue.record("Could not replace the raw: \(error)") }
                continueChecks.signal()
                continueChecks.signal()
            }
        }
        let outcomes = await developer.develop(jobs, to: folder, output: OutputSettings())
        guard case .failed(let reason) = outcomes[0] else {
            Issue.record("A queued snapshot of the replaced raw must fail before resuming")
            return
        }
        #expect(reason.contains("raw changed after it was checked"))
        #expect(Array(outcomes.dropFirst()) == files.dropFirst().map { .alreadyDeveloped($0) })
        #expect(try Data(contentsOf: files[0]) == Data("original output".utf8))
    }

    @Test(arguments: [false, true])
    func aChangedInstalledStockCannotSkipACapturedRecipe(manual: Bool) async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("DSC1.ARW"), file = folder.appendingPathComponent("DSC1.jpg")
        try Data("raw stand-in; any attempt to decode it fails".utf8).write(to: raw)
        try Data("original output".utf8).write(to: file)
        let sha = try RecipeStore.sha256(of: raw)
        var job = Self.job(raw, previousOutput: file)
        job.recipe.raw.sha256 = sha
        if manual {
            let controls = RollControls(), aim = PrintAim()
            let baseline = AutomaticBaseline(sourceSHA256: sha, stockID: Self.stock.id, stockDigest: Self.stock.digest,
                controls: controls, aim: aim, analysisVersion: ExposureAnalysis.currentVersion,
                baseRender: Recipe.Render(settings: controls.settings(for: Self.stock, aim: aim), grain: .natural))
            let edit = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.7), baseline: baseline)
            job.recipe = try Recipe.make(frame: job.frame, byteCount: RecipeStore.byteCount(of: raw),
                stock: Self.stock, stockDigest: Self.stock.digest, roll: controls, own: FrameControls(),
                grain: .natural, previous: job.recipe, manual: edit)
            job.recipe.develops[0].render = job.recipe.render
            job.recipe.develops[0].renderVersion = RenderGraph.version(for: job.recipe.render.settings)
        }
        job.recipe.editRevision = 1
        let changed = Stock(id: Self.stock.id, displayName: Self.stock.displayName, status: "synthetic", boxSpeed: 400,
            densityRange: 2.5, exposurePerUnit: SIMD3(0.9, 0.85, 0.8),
            negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
        #expect(changed.digest != Self.stock.digest)
        let digests = SourceDigests(settle: 0)
        let developer = try RollDeveloper(stocks: [changed], software: "Argent test",
            library: folder.appendingPathComponent("recipes"), digests: digests,
            decoderChoices: DecoderChoices(route: .apple), recipeWriter: RecipeWriter(digests: digests))
        let outcomes = await developer.develop([job], to: folder, output: OutputSettings())
        let recovery = manual ? "update the automatic baseline first" : "develop again to use its current version"
        #expect(outcomes == [.failed("DSC1: the stock changed; \(recovery)")])
        #expect(try Data(contentsOf: file) == Data("original output".utf8))
    }

    @Test func aReplacedStampedOutputKeepsItsBytesAndGetsANewName() throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("DSC1.jpg")
        try Data("original output".utf8).write(to: file)
        var job = Self.job(folder.appendingPathComponent("DSC1.ARW"), previousOutput: file)
        let originalStamp = try #require(SourceStamp.of(file))
        job.recipe.develops[0].outputSource = originalStamp
        var legacy = job.recipe.develops[0]
        legacy.outputSource = nil
        job.recipe.develops.insert(legacy, at: 0)
        try Data("replacement output".utf8).write(to: file, options: .atomic)

        #expect(RollDeveloper.files(for: [job], in: folder, output: OutputSettings())
                == [folder.appendingPathComponent("DSC1 2.jpg")])
        #expect(try Data(contentsOf: file) == Data("replacement output".utf8))
    }

    @Test func cancellationAfterAdmissionStopsBeforeDecode() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("DSC1.ARW"), destination = folder.appendingPathComponent("out")
        try Data("raw stand-in; any attempt to decode it fails".utf8).write(to: raw)
        var captured = Self.job(raw)
        captured.recipe.editRevision = 1
        let job = captured
        let digests = SourceDigests(settle: 0)
        let developer = try RollDeveloper(stocks: [Self.stock], software: "Argent test",
            library: folder.appendingPathComponent("recipes"), digests: digests,
            decoderChoices: DecoderChoices(route: .apple), recipeWriter: RecipeWriter(digests: digests))
        let (admissions, admitted) = AsyncStream<Void>.makeStream()
        let continueAdmission = DispatchSemaphore(value: 0)
        developer.observeStage = { _, stage, begins in
            if stage == .admit, !begins {
                admitted.yield(())
                if continueAdmission.wait(timeout: .now() + 15) == .timedOut { Issue.record("Admission did not resume after cancellation") }
            }
        }
        let task = Task {
            defer { admitted.finish() }
            return await developer.develop([job], to: destination, output: OutputSettings())
        }
        var reachedAdmission = false
        for await _ in admissions { reachedAdmission = true; break }
        task.cancel()
        continueAdmission.signal()

        #expect(reachedAdmission)
        #expect(await task.value == [.stopped])
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    /// A second develop in one session builds its jobs from recipes read before the first one's
    /// receipts were saved. Its frames' own outputs, replaced by that develop, are still theirs.
    @Test func aJobCapturedBeforeTheLastReceiptStillSkipsTheOutputItRecords() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("DSC1.ARW"), destination = folder.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("raw stand-in; any attempt to decode it fails".utf8).write(to: raw)
        let file = destination.appendingPathComponent("DSC1.jpg"), library = folder.appendingPathComponent("recipes")
        let digests = SourceDigests(settle: 0), writer = RecipeWriter(digests: digests)
        // Developed in an earlier session: the recipe the roll opened with records that file.
        try Data("earlier develop".utf8).write(to: file)
        var opened = Self.job(raw, previousOutput: file)
        opened.recipe.develops[0].date = Date(timeIntervalSince1970: 1000)
        opened.recipe.develops[0].outputSource = SourceStamp.of(file)
        opened.recipe.editRevision = 1
        let captured = try await writer.commit(recipe: opened.recipe, for: opened.frame, library: library)
        // This session's first develop replaced it and saved its receipt.
        try Data("this session's develop".utf8).write(to: file, options: .atomic)
        var receipt = captured
        receipt.develops.append(captured.develops[0])
        receipt.develops[1].date = Date(timeIntervalSince1970: 2000)
        receipt.develops[1].outputSource = SourceStamp.of(file)
        _ = try await writer.mergeExport(recipe: receipt, for: opened.frame, library: library)
        let developer = try RollDeveloper(stocks: [Self.stock], software: "Argent test", library: library, digests: digests,
            decoderChoices: DecoderChoices(route: .apple), recipeWriter: writer)

        let job = RollDeveloper.Job(frame: opened.frame, recipe: captured)
        #expect(await developer.develop([job], to: destination, output: OutputSettings()) == [.alreadyDeveloped(file)])
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["DSC1.jpg"])
    }

    /// A destination holding another roll's raw of the frame's name holds that raw's sidecar too.
    /// Developing there leaves that sidecar untouched and writes no output sidecar of its own.
    @Test func anotherRawsSidecarBesideTheOutputIsLeftUntouchedAndNoOutputSidecarIsWritten() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let roll = folder.appendingPathComponent("roll"), destination = folder.appendingPathComponent("other roll")
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let raw = roll.appendingPathComponent("DSC1.ARW"), foreign = destination.appendingPathComponent("DSC1.ARW")
        try Data("raw stand-in; any attempt to decode it fails".utf8).write(to: raw)
        try Data("another roll's raw".utf8).write(to: foreign)
        let sidecar = RecipeStore.besideRaw(foreign), file = destination.appendingPathComponent("DSC1.jpg")
        let library = folder.appendingPathComponent("recipes")
        let digests = SourceDigests(settle: 0), writer = RecipeWriter(digests: digests)
        var future = Self.job(foreign).recipe
        future.version = Recipe.currentVersion + 1
        let foreignBytes = try future.encoded()
        try foreignBytes.write(to: sidecar)
        var captured = Self.job(raw)
        captured.recipe.editRevision = 1
        let developer = try RollDeveloper(stocks: [Self.stock], software: "Argent test", library: library, digests: digests,
            decoderChoices: DecoderChoices(route: .apple), recipeWriter: writer)

        let outcomes = await developer.develop([captured], to: destination, output: OutputSettings())
        guard case .failed(let reason) = outcomes[0] else {
            Issue.record("The stand-in raw cannot be decoded")
            return
        }
        #expect(!reason.contains("output recipe"))
        try Data("developed".utf8).write(to: file)
        var receipt = Self.job(raw, previousOutput: file).recipe
        receipt.raw.sha256 = try RecipeStore.sha256(of: raw)
        receipt.editRevision = 1
        _ = try await writer.mergeExport(recipe: receipt, for: captured.frame, library: library)
        #expect(try Data(contentsOf: sidecar) == foreignBytes)
        #expect(!FileManager.default.fileExists(atPath: file.appendingPathExtension(Recipe.fileExtension).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
                == ["DSC1.ARW", "DSC1.argent", "DSC1.jpg"])
    }

    @Test(arguments: [false, true])
    func aStrayFutureOutputSidecarDoesNotBlockResumeAndStaysUntouched(besideRaw: Bool) async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let rawFolder = besideRaw ? folder : folder.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: rawFolder, withIntermediateDirectories: true)
        let raw = rawFolder.appendingPathComponent("DSC1.ARW"), file = folder.appendingPathComponent("DSC1.jpg")
        try Data("raw stand-in; any attempt to decode it fails".utf8).write(to: raw)
        try Data("original output".utf8).write(to: file)
        var job = Self.job(raw, previousOutput: file)
        job.recipe.raw.sha256 = try RecipeStore.sha256(of: raw)
        job.recipe.editRevision = 1
        job.recipe.develops[0].outputSource = SourceStamp.of(file)
        var future = job.recipe
        future.version = Recipe.currentVersion + 1
        let sidecar = besideRaw ? file.appendingPathExtension(Recipe.fileExtension)
            : file.deletingPathExtension().appendingPathExtension(Recipe.fileExtension)
        let futureBytes = try future.encoded()
        try futureBytes.write(to: sidecar)
        let digests = SourceDigests(settle: 0)
        let developer = try RollDeveloper(stocks: [Self.stock], software: "Argent test",
            library: folder.appendingPathComponent("recipes"), digests: digests,
            decoderChoices: DecoderChoices(route: .apple), recipeWriter: RecipeWriter(digests: digests))

        #expect(await developer.develop([job], to: folder, output: OutputSettings()) == [.alreadyDeveloped(file)])
        #expect(try Data(contentsOf: file) == Data("original output".utf8))
        #expect(try Data(contentsOf: sidecar) == futureBytes)

        // Changing a setting to force re-develop also ignores the stray output sidecar rather than failing on it.
        var changed = job
        changed.recipe.render.printExposure += 0.5
        let outcomes = await developer.develop([changed], to: folder, output: OutputSettings())
        guard case .failed(let reason) = outcomes[0] else {
            Issue.record("The stand-in raw cannot be decoded")
            return
        }
        #expect(!reason.contains("output recipe"))
        #expect(try Data(contentsOf: file) == Data("original output".utf8))
        #expect(try Data(contentsOf: sidecar) == futureBytes)
    }
}
