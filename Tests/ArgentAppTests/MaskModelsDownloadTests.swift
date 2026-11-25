import ArgentCore
import ArgentRoll
import Foundation
import Observation
import Testing
@testable import ArgentApp

/// State, observation, entry points, and modal guards for the mask models' licence and download screen (`MaskModelsDownload`).
@MainActor @Suite(.serialized) struct MaskModelsDownloadTests {
    private func header(_ url: URL) throws {
        func u16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255)] }
        func u32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(n >> (8 * $0) & 255) } }
        var b: [UInt8] = [0x49, 0x49] + u16(42) + u32(8)
        b += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(26) + u32(0)
        b += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(100) + u16(0) + u32(0)
        try Data(b).write(to: url, options: .atomic)
    }

    private func fixture() async throws -> (RollModel, Frame, URL, SessionSmartEngine) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-mask-models-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try header(folder.appendingPathComponent("DSC1.ARW"))
        let library = folder.appendingPathComponent("Recipes", isDirectory: true)
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: library), flagStore: FlagStore(library: library),
                              recipeLibrary: library, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        await model.open(folder)
        if let restore = model.manualRestoreTask { await restore.value }
        if let analysis = model.analysisTask { await analysis.value }
        let frame = try #require(model.roll?.frames.first)
        model.selection = frame.id
        model.openFrame()
        let verified = try SourceDigests.shared.digest(of: frame.url)
        model.manualReadySources[frame.url] = verified
        model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 0.3, validWeight: 1), source: verified.source), for: frame)
        if let balance = model.balanceTask { await balance.value }
        let pin = AutomaticBaseline(sourceSHA256: verified.sha256, stockID: "test", stockDigest: "digest",
            controls: .init(), aim: PrintAim(level: -0.65), analysisVersion: ExposureAnalysis.currentVersion,
            baseRender: Recipe.Render(settings: DevelopSettings(), grain: .off))
        model.manualEdits[frame.url] = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.5), baseline: pin)
        model.followSelectionFlag()
        let engine = SessionSmartEngine()
        engine.availabilities = [
            .sky: .needsModels(BundledSmartMasks.needsModels(.sky)),
            .subject: .needsModels(BundledSmartMasks.needsModels(.subject)),
            .background: .needsModels(BundledSmartMasks.needsModels(.background)),
        ]
        model.smartMasks.inference = MaskInference(engine: engine, turns: DecodeTurns())
        return (model, frame, folder, engine)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func unseenBackgroundFailureSurvivesShowAndResetsOnlyAfterSeenClose() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-mask-models-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = ContinuationGate()
        let download = MaskModelsDownload()
        download.folder = { folder }
        download.installer = { _, _, _ in
            try await gate.wait()
            throw MaskModelPack.Failure.download("offline")
        }

        download.show()
        download.start()
        try await waitFor { gate.isWaiting }
        // Close while running: download continues in the background.
        download.close()
        #expect(!download.isShown && download.isRunning)

        // Fails while hidden.
        gate.resume()
        try await waitFor { !download.isRunning }
        guard case .failed(let why) = download.phase else { Issue.record("expected failed, got \(download.phase)"); return }
        #expect(why.contains("offline"))

        // Closing while already hidden does not erase the unseen error.
        download.close()
        #expect(download.phase == .failed(why))

        // Reopening shows the unseen error and Try Again instead of erasing it.
        download.show()
        #expect(download.isShown && download.phase == .failed(why))

        // Closing after the user has seen it resets to idle.
        download.close()
        #expect(!download.isShown && download.phase == .idle)
    }

    @Test func generationIgnoresStaleStepsAndProgressIsMonotonicAndClamped() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-mask-models-gen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let run1Gate = ContinuationGate()
        let run2Gate = ContinuationGate()
        let callbacks = CallbackBox()
        let installedCount = CounterBox()

        let download = MaskModelsDownload()
        download.folder = { folder }
        download.onInstalled = { installedCount.increment() }
        download.installer = { _, _, step in
            let index = callbacks.record(step)
            if index == 1 {
                try? await run1Gate.wait()
                // Run 1 finishes late without noticing cancellation, simulating a race after cancel + restart.
                return
            } else {
                try await run2Gate.wait()
            }
        }

        download.start()
        let gen1 = download.generation
        try await waitFor { run1Gate.isWaiting }
        // Cancel run 1 and immediately start run 2: run 2 waits for run 1 to return, so two installs never share the folder.
        download.cancel()
        #expect(download.phase == .idle)
        download.start()
        let gen2 = download.generation
        #expect(gen2 > gen1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(callbacks.count == 1 && !run2Gate.isWaiting, "run 2 began while run 1 was still running")

        // A stale step from run 1 is ignored; its late return does not finish run 2, which starts only then.
        download.advance(to: .unpacking, run: gen1)
        #expect(download.phase == .running(.downloading(0)))
        run1Gate.resume()
        try await waitFor { run2Gate.isWaiting }
        #expect(download.phase == .running(.downloading(0)) && installedCount.value == 0)

        // Run 2's progress is clamped, ignores non-finite values, and never moves backwards.
        download.advance(to: .downloading(.nan), run: gen2)
        download.advance(to: .downloading(.infinity), run: gen2)
        download.advance(to: .downloading(-0.5), run: gen2)
        #expect(download.phase == .running(.downloading(0)))
        download.advance(to: .downloading(0.4), run: gen2)
        #expect(download.phase == .running(.downloading(0.4)))
        download.advance(to: .downloading(0.2), run: gen2)
        #expect(download.phase == .running(.downloading(0.4)))
        download.advance(to: .downloading(1.5), run: gen2)
        #expect(download.phase == .running(.downloading(1)))
        download.advance(to: .checking, run: gen2)
        #expect(download.phase == .running(.checking))
        download.advance(to: .downloading(0.9), run: gen2)
        #expect(download.phase == .running(.checking))
        download.advance(to: .unpacking, run: gen2)
        #expect(download.phase == .running(.unpacking))
        download.advance(to: .checking, run: gen2)
        #expect(download.phase == .running(.unpacking))

        run2Gate.resume()
        try await waitFor { download.phase == .done }
        #expect(installedCount.value == 1)
    }

    /// Quit waits for the download to clean up, a running one or one already stopped and still returning, but never past its limit.
    @Test func cancelForQuitWaitsForTheDrainButNotPastItsLimit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-mask-models-quit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let returned = CounterBox()
        let stuck = ContinuationGate()

        // One that never notices it was cancelled: Quit goes on at the limit.
        let deaf = MaskModelsDownload()
        deaf.folder = { folder }
        deaf.installer = { _, _, _ in try? await stuck.wait() }
        deaf.start()
        try await waitFor { stuck.isWaiting }
        let began = ContinuousClock.now
        await deaf.cancelForQuit(limit: .milliseconds(200))
        let waited = ContinuousClock.now - began
        #expect(waited >= .milliseconds(150) && waited < .seconds(2), "waited \(waited)")
        stuck.resume()

        // One stopped before Quit and still returning: Quit waits for it, though Stop already let go of it.
        let draining = MaskModelsDownload()
        draining.folder = { folder }
        draining.installer = { _, _, _ in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            try? await Task.sleep(for: .milliseconds(50))
            returned.increment()
            throw CancellationError()
        }
        draining.start()
        try await Task.sleep(for: .milliseconds(20))
        draining.cancel()
        #expect(!draining.isRunning && returned.value == 0)
        await draining.cancelForQuit(limit: .seconds(5))
        #expect(returned.value == 1)
    }

    @Test func onInstalledRefreshesSmartMasksObservationAndPins() async throws {
        let (model, _, folder, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(model.smartAvailability(.subject).isAvailable == false)
        #expect(model.smartMasks.pins?.subject == nil)

        let availabilityObserved = CounterBox()
        let pinsObserved = CounterBox()
        withObservationTracking {
            _ = model.smartAvailability(.subject)
        } onChange: {
            availabilityObserved.increment()
        }
        withObservationTracking {
            _ = model.smartMasks.pins
        } onChange: {
            pinsObserved.increment()
        }

        model.maskModels.installer = { _, _, _ in
            engine.lock.withLock {
                engine.availabilities[.sky] = .available
                engine.availabilities[.subject] = .available
                engine.availabilities[.background] = .available
                engine.current.subject = ModelProvenance(recipeID: "s3od-test", weightsSHA256: "w", canarySHA256: "c", fileSHA256: "f")
            }
        }
        model.maskModels.start()
        try await waitFor { model.maskModels.phase == .done }

        #expect(availabilityObserved.value == 1, "availability(of:) observed modelsVersion")
        #expect(pinsObserved.value == 1, "pins observed modelsVersion")
        #expect(model.smartAvailability(.subject) == .available)
        #expect(model.smartAvailability(.background) == .available)
        #expect(model.smartAvailability(.sky) == .available, "Sky's model comes in the same download")
        #expect(model.smartMasks.pins?.subject?.recipeID == "s3od-test")

        // Replacing inference also clears cachedPins and notifies observers.
        let replacedObserved = CounterBox()
        withObservationTracking {
            _ = model.smartMasks.pins
        } onChange: {
            replacedObserved.increment()
        }
        let freshEngine = SessionSmartEngine()
        freshEngine.current.subject = ModelProvenance(recipeID: "s3od-fresh", weightsSHA256: "w2", canarySHA256: "c2", fileSHA256: "f2")
        model.smartMasks.inference = MaskInference(engine: freshEngine, turns: DecodeTurns())
        #expect(replacedObserved.value == 1)
        #expect(model.smartMasks.pins?.subject?.recipeID == "s3od-fresh")
    }

    @Test func entryPointsOpenMaskModelsScreenWhenModelsAreMissing() async throws {
        let (model, frame, folder, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Mask > New Subject Mask opens the licence screen and adds no mask.
        model.maskEditor.isPickerOpen = true
        model.perform(.newSmart(.subject))
        #expect(model.maskModels.isShown && !model.maskEditor.isPickerOpen && model.masks(for: frame).isEmpty)
        model.maskModels.close()

        // Mask > New Background Mask does the same.
        model.perform(.newSmart(.background))
        #expect(model.maskModels.isShown && model.masks(for: frame).isEmpty)
        model.maskModels.close()

        // Mask > New Sky Mask too: a build without DA3 offers it with the others.
        model.maskEditor.isPickerOpen = true
        model.perform(.newSmart(.sky))
        #expect(model.maskModels.isShown && !model.maskEditor.isPickerOpen && model.masks(for: frame).isEmpty)
        model.maskModels.close()

        // Try Again on a pending/failed Subject mask opens the licence screen, and on a Sky one: a paste or an Undo can bring one to a build without its models.
        for kind in [SmartKind.subject, .sky] {
            let pending = Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: kind)))])
            let adjustments = model.manualAdjustments(for: frame)
            model.manualEdits[frame.url]?.adjustments = adjustments.settingMasks(try adjustments.masks.appending(pending))
            model.retrySelection(pending.id, for: frame)
            #expect(model.maskModels.isShown, "\(kind)")
            model.maskModels.close()
        }
    }

    @Test func sheetGuardsMenuStateAndIgnoresProgressTicks() async throws {
        let (model, _, folder, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }

        let before = model.menuState
        #expect(!before.isShowingMaskModels && !before.isSheetShown && before.actsOnRoll && before.actsOnFrames)

        let changes = CounterBox()
        withObservationTracking { _ = model.menuState } onChange: { changes.increment() }
        model.maskModels.show()
        #expect(changes.value == 1 && model.isSheetShown)
        let up = model.menuState
        #expect(up.isShowingMaskModels && up.isSheetShown && !up.actsOnRoll && !up.actsOnFrames)

        // Download progress does not trigger menuState observation.
        let gate = ContinuationGate()
        model.maskModels.installer = { _, _, step in
            step(.downloading(0.25))
            try await gate.wait()
        }
        model.maskModels.start()
        try await waitFor { gate.isWaiting }
        let progressChanges = CounterBox()
        withObservationTracking { _ = model.menuState } onChange: { progressChanges.increment() }
        model.maskModels.advance(to: .downloading(0.6), run: model.maskModels.generation)
        model.maskModels.advance(to: .checking, run: model.maskModels.generation)
        model.maskModels.advance(to: .unpacking, run: model.maskModels.generation)
        #expect(progressChanges.value == 0)
        model.maskModels.cancel()
        gate.resume()

        model.maskModels.close()
        #expect(!model.isSheetShown && model.menuState == before)
    }

    @Test func rollModelDerivesDownloadedModelsBesideRecipeLibrary() async throws {
        let (model, _, folder, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let expected = folder.appendingPathComponent("Models", isDirectory: true)
        #expect(model.downloadedModelsFolder == expected)
        #expect(model.maskModels.folder() == expected)
        #expect(MaskModelsDownload.notCommercial.contains("non-commercial") && MaskModelsDownload.notCommercial.contains("Apache 2.0"))
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var resumed = false

    var isWaiting: Bool { lock.withLock { continuation != nil } }

    func wait() async throws {
        try await withCheckedThrowingContinuation { cont in
            let already: Bool = lock.withLock {
                if resumed { return true }
                continuation = cont
                return false
            }
            if already { cont.resume() }
        }
    }

    func resume() {
        let cont: CheckedContinuation<Void, any Error>? = lock.withLock {
            resumed = true
            defer { continuation = nil }
            return continuation
        }
        cont?.resume()
    }
}

private final class CallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    /// One more install began; its number.
    func record(_ step: @escaping @Sendable (MaskModelPack.Step) -> Void) -> Int {
        lock.withLock {
            calls += 1
            return calls
        }
    }
    var count: Int { lock.withLock { calls } }
}

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
