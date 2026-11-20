import ArgentCore
import Foundation
import Testing
@testable import ArgentRoll

/// A smart-mask engine that runs no model: it answers each kind from a table, can hold its finds until a test lets them go, and
/// records how many ran at once and how often the Sky model was let go. Shared with the app's tests by copy.
final class FakeSmartEngine: SmartMaskEngine, @unchecked Sendable {
    let lock = NSLock()
    var answers: [SmartKind: SmartResult] = [:]
    var failure: (any Error)?
    var finds: [SmartKind] = []
    var running = 0, mostRunning = 0
    var unloads = 0
    var skyLoaded = false
    var pictures = 0
    /// Pictures are not made until this is false; the frames whose picture was given up meanwhile, in order.
    var holdsPictures = false
    var picturesLetGo: [String] = []
    var holds = false
    /// Whether a Subject find let a bundled model go, as `BundledSmartMasks` tells the queue.
    var releasesModels = false
    private var held: [CheckedContinuation<Void, Never>] = []
    var stages: [SmartStage] = [.finding]

    func availability(of kind: SmartKind) -> SmartAvailability { .available }
    var pins: SmartModelPins { SmartModelPins() }

    func picture(of frame: Frame, lens: LensSettings, stopped: @escaping @Sendable () -> Bool) async -> SmartPictureHandle? {
        lock.withLock { pictures += 1 }
        // A picture that takes its time, as a decode does, and is given up when whoever asked lets go.
        while lock.withLock({ holdsPictures }) {
            if Task.isCancelled || stopped() {
                lock.withLock { picturesLetGo.append(frame.url.lastPathComponent) }
                return nil
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return SmartPictureHandle(frame: frame.url, content: 0)
    }

    func find(_ kind: SmartKind, on picture: SmartPictureHandle, frame: Frame, sourceSHA256: String,
              stage: @escaping @Sendable (SmartStage) -> Void) async throws -> (SmartResult, MaskFrame) {
        lock.withLock {
            finds.append(kind)
            running += 1
            mostRunning = max(mostRunning, running)
            if kind == .sky { skyLoaded = true }
        }
        defer { lock.withLock { running -= 1 } }
        for next in lock.withLock({ stages }) { stage(next) }
        if lock.withLock({ holds }) { await withCheckedContinuation { continuation in lock.withLock { held.append(continuation) } } }
        if let failure = lock.withLock({ failure }) { throw failure }
        let answer = lock.withLock { answers[kind] } ?? .seed(Self.seed(kind))
        return (answer, try Self.maskFrame())
    }

    func unloadSky() async -> Bool {
        lock.withLock {
            defer { skyLoaded = false }
            if skyLoaded { unloads += 1 }
            return skyLoaded
        }
    }

    func releasePictures() {}

    func takeReleasedModels() -> Bool { lock.withLock { releasesModels } }

    /// Lets every held find go on.
    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { held = [] }
            return held
        }
        for continuation in waiting { continuation.resume() }
    }

    var heldCount: Int { lock.withLock { held.count } }

    static func maskFrame() throws -> MaskFrame { try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true) }

    static func provenance(_ kind: SmartKind, engine: String? = nil, revision: String = "1", parameters: [String: String] = [:]) -> RasterProvenance {
        RasterProvenance(engine: engine ?? (kind == .sky ? "coreai:test" : kind == .person ? AppleSegmentation.personEngine : AppleSegmentation.subjectEngine),
                         engineRevision: revision, parameters: parameters, operatingSystem: "test", app: "test",
                         input: .init(kind: "neutral-print", width: 2560, height: 1707, colorSpace: "sRGB", sourceSHA256: String(repeating: "0", count: 64)),
                         created: Date(timeIntervalSince1970: 0))
    }

    /// A 32 × 32 seed whose left half is selected; the kind's own number in its first pixel, so seeds of two kinds differ.
    static func seed(_ kind: SmartKind, value: UInt8 = 255) -> SmartSeed {
        var plane = [UInt8](repeating: 0, count: 32 * 32)
        for y in 0..<32 { for x in 0..<16 { plane[y * 32 + x] = value } }
        plane[1] = UInt8(SmartKind.allCases.firstIndex(of: kind)! + 1)
        return SmartSeed(kind: kind, raster: try! MaskRaster(width: 32, height: 32, plane: plane), provenance: provenance(kind))
    }
}

/// The smart masks' queue (`MaskInference`) with a fake engine: one selection at a time, behind a develop's frames; asks of the same
/// frame and kind joined; Background answered from Subject's run; a cancelled ask let go; and DA3 let go with the Masks tab and
/// before a develop.
@Suite(.serialized) struct MaskInferenceTests {
    private func frame(_ name: String = "DSC1.ARW") throws -> (Frame, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-mask-inference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        return (Frame(id: 0, url: url, info: ARWFrameInfo()), folder)
    }

    private final class Stages: @unchecked Sendable {
        let lock = NSLock()
        var seen: [SmartStage] = []
        func add(_ stage: SmartStage) { lock.withLock { seen.append(stage) } }
        var all: [SmartStage] { lock.withLock { seen } }
    }

    @Test func aClickFindsItsSelectionAndSaysWhereItStandsFromTheStart() async throws {
        let (frame, folder) = try frame()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = FakeSmartEngine(), queue = MaskInference(engine: engine, turns: DecodeTurns())
        let stages = Stages()
        let asked = queue.ask(.sky, on: frame, sourceSHA256: "abc", lens: .default) { stages.add($0) }
        // Told at once, before anything ran: the row names its wait from its first frame.
        #expect(stages.all.first == .queued)
        let outcome = await asked.outcome.value
        guard case .found(let seed, let maskFrame) = outcome else { Issue.record("\(outcome)"); return }
        #expect(seed.kind == .sky && maskFrame.width == 7008)
        #expect(stages.all.contains(.reading) && stages.all.contains(.finding))
        #expect(queue.statistics.runs == 1)
    }

    @Test func asksOfOneFrameAndKindJoinAndBackgroundIsSubjectsRun() async throws {
        let (frame, folder) = try frame()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = FakeSmartEngine()
        engine.holds = true
        let queue = MaskInference(engine: engine, turns: DecodeTurns())
        let first = queue.ask(.subject, on: frame, sourceSHA256: "abc", lens: .default)
        let second = queue.ask(.subject, on: frame, sourceSHA256: "abc", lens: .default)
        let background = queue.ask(.background, on: frame, sourceSHA256: "abc", lens: .default)
        while engine.heldCount == 0 { await Task.yield() }
        engine.release()
        let a = await first.outcome.value, b = await second.outcome.value, c = await background.outcome.value
        guard case .found(let subject, _) = a, case .found(let again, _) = b, case .found(let inverse, _) = c else {
            Issue.record("\(a) \(b) \(c)"); return
        }
        #expect(engine.finds == [.subject])
        #expect(subject.raster == again.raster && inverse.raster == subject.raster)
        #expect(inverse.kind == .background && subject.kind == .subject)
        #expect(queue.statistics.runs == 1 && queue.statistics.joined == 2)
        // Made once, answered at once after: a second mask of the kind waits for nothing.
        let later = await queue.ask(.background, on: frame, sourceSHA256: "abc", lens: .default).outcome.value
        guard case .found(let kept, _) = later else { Issue.record("\(later)"); return }
        #expect(kept.raster == subject.raster && kept.kind == .background && queue.statistics.kept == 1)
        #expect(engine.finds == [.subject])
    }

    @Test func oneSelectionRunsAtATimeAndAFrameSwitchKeepsEachToItsFrame() async throws {
        let (one, folder) = try frame("DSC1.ARW"), (two, folder2) = try frame("DSC2.ARW")
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: folder2) }
        let engine = FakeSmartEngine(), queue = MaskInference(engine: engine, turns: DecodeTurns())
        engine.answers = [.person: .seed(FakeSmartEngine.seed(.person, value: 200))]
        let sky = queue.ask(.sky, on: one, sourceSHA256: "one", lens: .default), person = queue.ask(.person, on: two, sourceSHA256: "two", lens: .default)
        let a = await sky.outcome.value, b = await person.outcome.value
        guard case .found(let skySeed, _) = a, case .found(let personSeed, _) = b else { Issue.record("\(a) \(b)"); return }
        #expect(skySeed.kind == .sky && personSeed.kind == .person && skySeed.raster != personSeed.raster)
        #expect(engine.mostRunning == 1)
    }

    @Test func aCancelledAskIsLetGoAndItsRunStops() async throws {
        let (frame, folder) = try frame()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = FakeSmartEngine()
        engine.holds = true
        let queue = MaskInference(engine: engine, turns: DecodeTurns())
        let running = queue.ask(.sky, on: frame, sourceSHA256: "abc", lens: .default)
        while engine.heldCount == 0 { await Task.yield() }
        // Queued behind it: cancelled before it starts, it never reaches the engine.
        let queued = queue.ask(.person, on: frame, sourceSHA256: "abc", lens: .default)
        queue.cancel(queued.ticket)
        queue.cancel(running.ticket)
        #expect(!queue.isRunning(on: frame.url))
        engine.release()
        #expect(await running.outcome.value == .cancelled)
        #expect(await queued.outcome.value == .cancelled)
        await queue.waitUntilIdle()
        #expect(engine.finds == [.sky])
        // Nothing was kept of a cancelled run: the next click asks again.
        engine.holds = false
        guard case .found = await queue.ask(.sky, on: frame, sourceSHA256: "abc", lens: .default).outcome.value else { Issue.record("not found"); return }
        #expect(engine.finds == [.sky, .sky])
    }

    @Test func nothingFoundAndAFailureAreAnswersAndAFailureIsNotKept() async throws {
        let (frame, folder) = try frame()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = FakeSmartEngine(), queue = MaskInference(engine: engine, turns: DecodeTurns())
        engine.answers = [.person: .nothingFound(.person, FakeSmartEngine.provenance(.person))]
        guard case .nothingFound(.person, _, _) = await queue.ask(.person, on: frame, sourceSHA256: "abc", lens: .default).outcome.value else {
            Issue.record("expected nothing found"); return
        }
        engine.failure = MaskError.invalid("Vision failed")
        guard case .failed(let why) = await queue.ask(.subject, on: frame, sourceSHA256: "abc", lens: .default).outcome.value else {
            Issue.record("expected a failure"); return
        }
        #expect(why.contains("Vision failed"))
        engine.failure = nil
        guard case .found = await queue.ask(.subject, on: frame, sourceSHA256: "abc", lens: .default).outcome.value else { Issue.record("not found"); return }
        #expect(engine.finds == [.person, .subject, .subject])
    }

    /// A develop's frames go first: a selection asked while one is in flight waits for it, says so, and runs once it is written.
    @Test func aDevelopsFrameGoesFirstAndTheSelectionSaysItWaits() async throws {
        let (frame, folder) = try frame()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = FakeSmartEngine(), turns = DecodeTurns(), queue = MaskInference(engine: engine, turns: turns)
        turns.isDevelopRunning = true
        #expect(turns.admitFrame(fits: { _ in true }, stopped: { false }) == false)
        let stages = Stages()
        let asked = queue.ask(.subject, on: frame, sourceSHA256: "abc", lens: .default) { stages.add($0) }
        let deadline = Date().addingTimeInterval(5)
        while !stages.all.contains(.waitingForDevelop), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(stages.all.contains(.waitingForDevelop))
        #expect(engine.finds.isEmpty)
        turns.frameLeft()
        guard case .found = await asked.outcome.value else { Issue.record("not found"); return }
        #expect(engine.finds == [.subject])
        // And a develop's frame waits for a model under way: none runs beside one.
        engine.holds = true
        let sky = queue.ask(.sky, on: frame, sourceSHA256: "abc", lens: .default)
        while engine.heldCount == 0 { await Task.yield() }
        #expect(turns.counts.previewsRunning == 1)
        engine.release()
        _ = await sky.outcome.value
        turns.isDevelopRunning = false
    }

    /// DA3 stays loaded while the Masks tab is open, and goes with the tab, before a develop, and after a click made while one runs.
    @Test func theSkyModelGoesWithTheTabAndBeforeADevelop() async throws {
        let (frame, folder) = try frame()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = FakeSmartEngine(), turns = DecodeTurns(), queue = MaskInference(engine: engine, turns: turns)
        queue.tabOpened()
        queue.tabShows(frame, lens: .default)
        _ = await queue.ask(.sky, on: frame, sourceSHA256: "abc", lens: .default).outcome.value
        await queue.waitUntilIdle()
        #expect(engine.skyLoaded && engine.unloads == 0)
        // The next frame's tab before the last one's goes: still open.
        queue.tabOpened()
        queue.tabClosed()
        await queue.waitUntilIdle()
        #expect(engine.skyLoaded && engine.unloads == 0 && queue.isTabOpen)
        queue.tabClosed()
        await queue.waitUntilIdle()
        #expect(!engine.skyLoaded && engine.unloads == 1)
        // With the tab closed, a Sky click lets the model go after it.
        queue.forget(frame.url)
        _ = await queue.ask(.sky, on: frame, sourceSHA256: "abc", lens: .default).outcome.value
        #expect(!engine.skyLoaded && engine.unloads == 2)
        // Open again: kept, until a develop starts.
        queue.tabOpened()
        queue.forget(frame.url)
        _ = await queue.ask(.sky, on: frame, sourceSHA256: "abc", lens: .default).outcome.value
        #expect(engine.skyLoaded)
        queue.developWillStart()
        await queue.waitUntilIdle()
        #expect(!engine.skyLoaded && engine.unloads == 3)
        // While a develop runs, a click lets it go after.
        turns.isDevelopRunning = true
        queue.forget(frame.url)
        _ = await queue.ask(.sky, on: frame, sourceSHA256: "abc", lens: .default).outcome.value
        #expect(!engine.skyLoaded && engine.unloads == 4)
        turns.isDevelopRunning = false
        #expect(queue.statistics.unloads == 4)
    }

    /// S3OD and ViTMatte go inside the click, and the queue holds a render's count for the footprint to settle, as it does when DA3 goes.
    /// The picture the Masks tab makes ahead is its frame's alone: showing another frame lets go of the one being made, and closing
    /// the tab lets go of the last, so arrowing through a roll with the tab open leaves no decode behind for a frame already left.
    @Test func thePictureMadeAheadGoesWithItsFrame() async throws {
        let (first, folder) = try frame()
        defer { try? FileManager.default.removeItem(at: folder) }
        let second = Frame(id: 1, url: folder.appendingPathComponent("DSC2.ARW"), info: ARWFrameInfo())
        let third = Frame(id: 2, url: folder.appendingPathComponent("DSC3.ARW"), info: ARWFrameInfo())
        let engine = FakeSmartEngine(), queue = MaskInference(engine: engine, turns: DecodeTurns())
        engine.holdsPictures = true
        func settled(_ condition: @Sendable () -> Bool) async {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        }
        queue.tabOpened()
        queue.tabShows(first, lens: .default)
        await settled { engine.lock.withLock { engine.pictures } == 1 }
        // The same frame shown again leaves its picture being made, and asks for no other.
        queue.tabShows(first, lens: .default)
        try await Task.sleep(for: .milliseconds(20))
        #expect(engine.lock.withLock { engine.pictures } == 1 && engine.lock.withLock { engine.picturesLetGo }.isEmpty)
        queue.tabShows(second, lens: .default)
        await settled { engine.lock.withLock { engine.picturesLetGo } == ["DSC1.ARW"] }
        #expect(engine.lock.withLock { engine.picturesLetGo } == ["DSC1.ARW"], "the frame left is let go, and the one shown is not")
        queue.tabShows(third, lens: .default)
        await settled { engine.lock.withLock { engine.picturesLetGo }.count == 2 }
        #expect(engine.lock.withLock { engine.picturesLetGo } == ["DSC1.ARW", "DSC2.ARW"])
        // The tab closing lets go of the last.
        queue.tabClosed()
        await settled { engine.lock.withLock { engine.picturesLetGo }.count == 3 }
        #expect(engine.lock.withLock { engine.picturesLetGo } == ["DSC1.ARW", "DSC2.ARW", "DSC3.ARW"] && !queue.isTabOpen)
        // One made ahead and left alone is made: nothing lets it go.
        engine.lock.withLock { engine.holdsPictures = false }
        queue.tabOpened()
        queue.tabShows(first, lens: .default)
        await settled { engine.lock.withLock { engine.pictures } == 4 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(engine.lock.withLock { engine.picturesLetGo }.count == 3 && engine.lock.withLock { engine.pictures } == 4)
        queue.tabClosed()
        await queue.waitUntilIdle()
    }

    @Test func aSubjectClickThatLoadedAModelSettlesAndNoOtherDoes() async throws {
        let (frame, folder) = try frame()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = FakeSmartEngine(), turns = DecodeTurns(), queue = MaskInference(engine: engine, turns: turns)
        engine.releasesModels = true
        _ = await queue.ask(.subject, on: frame, sourceSHA256: "abc", lens: .default).outcome.value
        #expect(queue.statistics.unloads == 1, "the settle ran after a Subject click that loaded models")
        queue.forget(frame.url)
        _ = await queue.ask(.background, on: frame, sourceSHA256: "abc", lens: .default).outcome.value
        #expect(queue.statistics.unloads == 2, "Background is Subject's run, and settles too")
        // Person loads nothing; an engine that says it let go nothing causes no settle; and Sky's is its own.
        queue.forget(frame.url)
        _ = await queue.ask(.person, on: frame, sourceSHA256: "abc", lens: .default).outcome.value
        #expect(queue.statistics.unloads == 2)
        engine.releasesModels = false
        queue.forget(frame.url)
        _ = await queue.ask(.subject, on: frame, sourceSHA256: "abc", lens: .default).outcome.value
        #expect(queue.statistics.unloads == 2)
    }

    /// A seed made with an earlier model is stale; one from the model this build makes it with, or a provenance that cannot say, is not.
    @Test func aSeedFromAnEarlierModelIsStaleAndNothingElseIs() {
        let da3 = ModelProvenance(recipeID: "da3-2", weightsSHA256: "w2", canarySHA256: "c", fileSHA256: "f")
        let eomt = ModelProvenance(recipeID: "eomt-1", weightsSHA256: "e1", canarySHA256: "c", fileSHA256: "f")
        let pins = SmartModelPins(sky: da3, water: eomt)
        func sky(_ recipe: String, _ weights: String = "w2", ran: Bool = false, eomtRecipe: String = "eomt-1") -> RasterProvenance {
            var p = ["model.recipe": recipe, "model.weights": weights, "veto": WaterVeto.version, "gate.revision": "2", "veto.ran": String(ran)]
            if ran { p["eomt.recipe"] = eomtRecipe; p["eomt.weights"] = "e1" }
            return FakeSmartEngine.provenance(.sky, parameters: p)
        }
        #expect(!pins.isStale(sky("da3-2"), kind: .sky))
        #expect(pins.isStale(sky("da3-1"), kind: .sky))
        #expect(pins.isStale(sky("da3-2", "w1"), kind: .sky))
        // A different conversion of the same model is the same model: the file's hash is not compared.
        #expect(!pins.isStale(sky("da3-2", ran: true), kind: .sky))
        #expect(pins.isStale(sky("da3-2", ran: true, eomtRecipe: "eomt-0"), kind: .sky))
        // EoMT did not shape a seed the gate kept it from.
        #expect(!pins.isStale(sky("da3-2", ran: false, eomtRecipe: "eomt-0"), kind: .sky))
        #expect(!SmartModelPins().isStale(sky("da3-1"), kind: .sky))
        #expect(!pins.isStale(FakeSmartEngine.provenance(.subject), kind: .subject))
        #expect(pins.isStale(FakeSmartEngine.provenance(.subject, revision: "0"), kind: .background))
        #expect(pins.isStale(FakeSmartEngine.provenance(.person, revision: "0"), kind: .person))
        #expect(pins.pin(for: .sky) != SmartModelPins(sky: eomt, water: eomt).pin(for: .sky))

        // The square DA3 was given (task H): a seed that records none was cut from the edge-repeated square, and is stale once the
        // build gives it the mirrored one; one that records the build's square is not.
        let mirrored = SmartModelPins(sky: da3, water: eomt, skySquare: SkyModelRunner.squareRecipe)
        func squared(_ square: String?) -> RasterProvenance {
            var p = ["model.recipe": "da3-2", "model.weights": "w2", "veto": WaterVeto.version, "gate.revision": "2", "veto.ran": "false"]
            p["model.square"] = square
            return FakeSmartEngine.provenance(.sky, parameters: p)
        }
        #expect(SkyModelRunner.squareRecipe != SmartModelPins.edgeSkySquare)
        #expect(mirrored.isStale(squared(nil), kind: .sky))
        #expect(mirrored.isStale(squared(SmartModelPins.edgeSkySquare), kind: .sky))
        #expect(!mirrored.isStale(squared(SkyModelRunner.squareRecipe), kind: .sky))
        #expect(mirrored.pin(for: .sky) != pins.pin(for: .sky))

        // Subject: a Vision seed in an existing record is offered Update once this build has the new models, never before, and never by itself (decision 22).
        let s3od = ModelProvenance(recipeID: "s3od-1", weightsSHA256: "s1", canarySHA256: "c", fileSHA256: "f")
        let vit = ModelProvenance(recipeID: "vit-1", weightsSHA256: "v1", canarySHA256: "c", fileSHA256: "f")
        let current = SmartModelPins(sky: da3, water: eomt, subject: s3od, matte: vit)
        #expect(!pins.isStale(FakeSmartEngine.provenance(.subject), kind: .subject), "a build without the new Subject offers nothing")
        #expect(current.isStale(FakeSmartEngine.provenance(.subject), kind: .subject), "today's Vision seed, on a build with the models")
        #expect(current.isStale(FakeSmartEngine.provenance(.subject), kind: .background))
        func subject(_ recipe: String = "s3od-1", _ weights: String = "s1", design: String? = SubjectDesign.version, gate: Bool = false, gateRecipe: String = "eomt-1", edge: String = "crisp", matteRecipe: String = "vit-1") -> RasterProvenance {
            var p = ["model.recipe": recipe, "model.weights": weights, "gate.ran": String(gate), "edge": edge]
            if let design { p["design"] = design }
            if gate { p["eomt.recipe"] = gateRecipe; p["eomt.weights"] = "e1" }
            if edge == "matte" { p["matte.recipe"] = matteRecipe; p["matte.weights"] = "v1" }
            return FakeSmartEngine.provenance(.subject, engine: "coreai:\(recipe)", parameters: p)
        }
        #expect(!current.isStale(subject(), kind: .subject))
        #expect(!current.isStale(subject(edge: "matte"), kind: .subject))
        #expect(!current.isStale(subject(gate: true), kind: .background))
        #expect(current.isStale(subject("s3od-0"), kind: .subject))
        #expect(current.isStale(subject("s3od-1", "s0"), kind: .subject))
        #expect(current.isStale(subject(design: "older"), kind: .subject))
        #expect(!current.isStale(subject(design: nil), kind: .subject), "a provenance that cannot say is not called stale")
        #expect(current.isStale(subject(edge: "matte", matteRecipe: "vit-0"), kind: .subject))
        #expect(!current.isStale(subject(edge: "crisp", matteRecipe: "vit-0"), kind: .subject), "the matte did not shape a crisp seed")
        #expect(current.isStale(subject(gate: true, gateRecipe: "eomt-0"), kind: .subject))
        #expect(!current.isStale(subject(gate: false, gateRecipe: "eomt-0"), kind: .subject), "EoMT did not run")
        #expect(current.pin(for: .subject) != pins.pin(for: .subject) && current.pin(for: .subject).contains("s3od-1@s1"))
        // A Vision seed from an absent-model build, once the model is back: stale too, so Update is offered.
        #expect(current.isStale(FakeSmartEngine.provenance(.subject, parameters: ["fallback": "s3od is unavailable"]), kind: .subject))
    }
}
