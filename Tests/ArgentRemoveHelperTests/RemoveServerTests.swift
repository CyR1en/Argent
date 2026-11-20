import ArgentCore
import ArgentRoll
import Darwin
import Foundation
import Testing
@testable import ArgentRemoveHelper

/// The helper's process, driven as the app drives it: `FolderEngine` in its launched mode on a temporary folder. With `--fake` it
/// holds no model and draws what `FakeRemovalEngine` draws, so every rule of the folder is proven in seconds; the same rules with
/// the graphs are `WithTheGraphs.Server`'s.
@Suite struct RemoveServerTests {
    @Test func aLaunchedHelperLoadsRunsTellsItsStepsAndGoesWhenUnloaded() async throws {
        let root = try Helper.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = Helper(["--fake", "--fake-load-seconds", "0.3"])
        defer { helper.stopAll() }
        let engine = FolderEngine(root: root, launcher: helper.launcher, unloadLimit: 20)
        #expect(engine.state == .idle && helper.processes.isEmpty, "no process and no memory until it is asked")

        engine.load()
        await Helper.until("the helper is ready") { engine.state == .ready }
        let served = try #require(Helper.engineFile(root))
        #expect(served.pid == helper.processes[0].processIdentifier)
        #expect(served.engine == FakeRemovalEngine.engineID && served.weights == FakeRemovalEngine.weightsID)

        let job = try Helper.job(steps: 5)
        let steps = StepPairs()
        let output = try await engine.run(job) { steps.add($0, $1) }
        #expect(output == (try await FakeRemovalEngine().run(job) { _, _ in }))
        #expect(steps.all == (1...5).map { [$0, 5] })

        await engine.unload()
        #expect(!helper.processes[0].isRunning && helper.processes[0].terminationStatus == 0, "unloaded is the process gone, with status 0")
        #expect(Helper.engineFile(root)?.state == .idle, "its last word")
        #expect(engine.state == .idle)
    }

    @Test func aWishToLoadAlreadyThereWhenItStartsIsObeyed() async throws {
        let root = try Helper.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("loaded".utf8).write(to: root.appendingPathComponent(RemovalFolder.wantFile))
        // An old wish too: the helper is started only when the app wants the model.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: root.appendingPathComponent(RemovalFolder.wantFile).path)
        let helper = Helper(["--fake"])
        defer { helper.stopAll() }
        let process = try helper.launcher(root)
        await Helper.until("it loads with nothing more said") {
            Helper.engineFile(root).map { $0.pid == process.processIdentifier && $0.state == .ready } ?? false
        }
    }

    @Test func aWishToUnloadLeftByTheLastSessionDoesNotEndTheNextButANewOneDoes() async throws {
        let root = try Helper.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let want = root.appendingPathComponent(RemovalFolder.wantFile)
        try Data("unloaded".utf8).write(to: want)
        let helper = Helper(["--fake"])
        defer { helper.stopAll() }
        let process = try helper.launcher(root)
        await Helper.until("it beats") { Helper.engineFile(root)?.pid == process.processIdentifier }
        let firstBeat = try #require(Helper.engineFile(root)).beat
        await Helper.until("it beats again") { (Helper.engineFile(root)?.beat ?? 0) > firstBeat }
        #expect(process.isRunning && Helper.engineFile(root)?.state == .idle)
        try Data("loaded".utf8).write(to: want)
        await Helper.until("it loads") { Helper.engineFile(root)?.state == .ready }
        try Data("unloaded".utf8).write(to: want)
        await Helper.until("it has gone") { !process.isRunning }
        #expect(process.terminationStatus == 0 && Helper.engineFile(root)?.state == .idle)
    }

    @Test func cancelStopsTheRunBetweenTwoStepsAndTheHelperServesTheNext() async throws {
        let root = try Helper.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = Helper(["--fake", "--fake-step-seconds", "0.2"])
        defer { helper.stopAll() }
        let engine = FolderEngine(root: root, launcher: helper.launcher, unloadLimit: 20)
        let steps = StepPairs()
        let run = Task { try await engine.run(try Helper.job(steps: 30)) { steps.add($0, $1) } }
        await Helper.until("two steps are done") { steps.all.count >= 2 }
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(steps.all.count < 30, "it stopped between two steps")
        #expect(helper.processes.count == 1 && helper.processes[0].isRunning, "a cancel is not an unload")
        let job = try Helper.job(steps: 2)
        #expect(try await engine.run(job) { _, _ in } == (try await FakeRemovalEngine().run(job) { _, _ in }))
    }

    @Test func jobsAreServedOneAtATimeInTheOrderTheyCame() async throws {
        let root = try Helper.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = Helper(["--fake", "--fake-step-seconds", "0.05"])
        defer { helper.stopAll() }
        let engine = FolderEngine(root: root, launcher: helper.launcher, unloadLimit: 20)
        engine.load()
        await Helper.until("ready") { engine.state == .ready }
        let order = Order()
        let first = Task { _ = try await engine.run(try Helper.job(steps: 10, seed: 1)) { _, _ in }; order.add(1) }
        await Helper.until("the first runs") { engine.state == .running }
        let second = Task { _ = try await engine.run(try Helper.job(steps: 2, seed: 2)) { _, _ in }; order.add(2) }
        try await first.value
        try await second.value
        #expect(order.all == [1, 2], "the short job waited for the long one")
    }

    @Test func unloadingDuringARunFailsItAndTheProcessIsGoneAtOnce() async throws {
        let root = try Helper.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = Helper(["--fake", "--fake-step-seconds", "0.5"])
        defer { helper.stopAll() }
        let engine = FolderEngine(root: root, launcher: helper.launcher, unloadLimit: 20)
        let steps = StepPairs()
        let run = Task { try await engine.run(try Helper.job(steps: 40)) { steps.add($0, $1) } }
        await Helper.until("a step is done") { !steps.all.isEmpty }
        let started = ContinuousClock.now
        await engine.unload()
        let gone = (ContinuousClock.now - started).seconds
        #expect(gone < 1, "within the develop's 2 s, mid-step: \(gone) s")
        #expect(helper.processes[0].terminationStatus == 0)
        await #expect(throws: RemovalRunFailure.self) { try await run.value }
    }

    @Test func prepareJsonCompilesForTheSizeBeforeTheJobThatHasIt() async throws {
        let root = try Helper.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = Helper(["--fake", "--fake-compile-seconds", "1.5"])
        defer { helper.stopAll() }
        let engine = FolderEngine(root: root, launcher: helper.launcher, unloadLimit: 20)
        engine.load()
        await Helper.until("ready") { engine.state == .ready }

        // A size nobody announced: the job pays the compile, and says `preparing` until its first step.
        let states = StateLog(engine)
        var started = ContinuousClock.now
        _ = try await engine.run(try Helper.job(width: 64, height: 96, steps: 2)) { _, _ in }
        let cold = (ContinuousClock.now - started).seconds
        states.stop()
        #expect(cold >= 1.5 && states.all.contains(.preparing(nil)))

        // Announced while the selection is made: compiled while idle, saying so; the job then runs warm.
        let announced = StateLog(engine)
        engine.prepare(width: 96, height: 64)
        await Helper.until("it has compiled") { announced.all.contains { if case .preparing = $0 { true } else { false } } && engine.state == .ready }
        announced.stop()
        started = ContinuousClock.now
        _ = try await engine.run(try Helper.job(width: 96, height: 64, steps: 2)) { _, _ in }
        let warm = (ContinuousClock.now - started).seconds
        #expect(warm < 1, "warm: \(warm) s against \(cold) s cold")
    }

    @Test func aSizeAnnouncedToTheLastProcessIsAnnouncedAgainToTheNextAndAStaleOneIsNotCompiled() async throws {
        let root = try Helper.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = Helper(["--fake", "--fake-compile-seconds", "0.3"])
        defer { helper.stopAll() }
        let engine = FolderEngine(root: root, launcher: helper.launcher, unloadLimit: 20)
        for _ in 0..<2 {
            engine.load()
            await Helper.until("ready") { engine.state == .ready }
            let states = StateLog(engine)
            engine.prepare(width: 96, height: 64)
            await Helper.until("it compiles for the size") { states.all.contains { if case .preparing = $0 { true } else { false } } }
            await Helper.until("ready again") { engine.state == .ready }
            states.stop()
            await engine.unload()
        }
        #expect(helper.processes.count == 2)

        // The file the last process was told stays; a process started on it does not compile for it.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(RemovalFolder.prepareFile).path))
        let states = StateLog(engine)
        engine.load()
        await Helper.until("ready") { engine.state == .ready }
        try await Task.sleep(for: .seconds(1))
        states.stop()
        #expect(!states.all.contains { if case .preparing = $0 { true } else { false } }, "\(states.all)")
    }

    @Test func theOneTimePreparationSaysPreparingWithItsFraction() async throws {
        let root = try Helper.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = Helper(["--fake", "--fake-prepares", "--fake-prepare-seconds", "1"])
        defer { helper.stopAll() }
        let engine = FolderEngine(root: root, launcher: helper.launcher, unloadLimit: 20)
        let states = StateLog(engine)
        engine.load()
        await Helper.until("ready") { engine.state == .ready }
        states.stop()
        let fractions = states.all.compactMap { if case .preparing(let fraction?) = $0 { fraction } else { nil } }
        #expect(fractions.count >= 2 && fractions == fractions.sorted(), "\(states.all)")
    }

    @Test func aModelThatCannotLoadFailsTheJobWithTheReason() async throws {
        let root = try Helper.folder(), empty = try Helper.folder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: empty)
        }
        let helper = Helper(["--models", empty.path])
        defer { helper.stopAll() }
        let engine = FolderEngine(root: root, launcher: helper.launcher, unloadLimit: 20)
        do {
            _ = try await engine.run(try Helper.job(width: 64, height: 64)) { _, _ in }
            Issue.record("a job ran with no model")
        } catch let failure as RemovalRunFailure {
            guard case .failed(let why) = failure else { Issue.record("\(failure)"); return }
            #expect(why.contains("objectclear-object-encoder.aimodel is not in"), "\(why)")
        }
        await engine.unload()
        #expect(!helper.processes[0].isRunning)
    }

    @Test func aJobLeftByAnEarlierSessionIsFailedNotRun() async throws {
        let root = try Helper.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = root.appendingPathComponent("jobs/left", isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try JSONEncoder().encode(RemovalFolder.Job(try Helper.job())).write(to: left.appendingPathComponent(RemovalFolder.jobFile))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)],
                                              ofItemAtPath: left.appendingPathComponent(RemovalFolder.jobFile).path)
        let helper = Helper(["--fake"])
        defer { helper.stopAll() }
        _ = try helper.launcher(root)
        await Helper.until("it is failed") {
            (try? Data(contentsOf: left.appendingPathComponent(RemovalFolder.statusFile)))
                .flatMap { try? JSONDecoder().decode(RemovalFolder.Status.self, from: $0) }?.state == .failed
        }
    }
}

// MARK: Support

/// The helper's executable, built beside the suites (`ARGENT_REMOVE_HELPER` names another, a release build for the measurements),
/// and the processes a launcher started.
final class Helper: @unchecked Sendable {
    static let executable: URL = {
        if let path = ProcessInfo.processInfo.environment["ARGENT_REMOVE_HELPER"] { return URL(fileURLWithPath: path) }
        let products = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }?.bundleURL.deletingLastPathComponent()
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/debug")
        return products.appendingPathComponent("argent-remove")
    }()

    private let arguments: [String]
    private let log: URL?
    private let lock = NSLock()
    private var started: [Process] = []

    /// `log`, if given, gathers the helper's own lines, which say its times and its footprint.
    init(_ arguments: [String], log: URL? = nil) {
        self.arguments = arguments
        self.log = log
    }

    var processes: [Process] { lock.withLock { started } }

    var launcher: FolderEngine.Launcher {
        { [self] root in
            let process = Process()
            process.executableURL = Self.executable
            process.arguments = ["--root", root.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            if let log {
                if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: log)
                handle.seekToEndOfFile()
                process.standardError = handle
            } else {
                process.standardError = FileHandle.nullDevice
            }
            try process.run()
            lock.withLock { started.append(process) }
            return process
        }
    }

    /// Ends the processes still running, and waits for each to be gone, ten seconds at most. The wait asks the process each
    /// hundredth of a second and is not `waitUntilExit`: twice on 2026-11-18, in whole runs of the suites, that call never
    /// came back from a process that had already gone (the one a test leaves loaded), and the run hung until it was killed.
    /// A process still there at the ten seconds is killed, and the test that left it is told.
    func stopAll() {
        for process in processes where process.isRunning {
            process.terminate()
            let limit = Date().addingTimeInterval(10)
            while process.isRunning, Date() < limit { usleep(10_000) }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                Issue.record("a helper did not end within ten seconds of being asked to, and was killed")
            }
        }
    }

    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-remove-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func engineFile(_ root: URL) -> RemovalFolder.Engine? {
        (try? Data(contentsOf: root.appendingPathComponent(RemovalFolder.engineFile)))
            .flatMap { try? JSONDecoder().decode(RemovalFolder.Engine.self, from: $0) }
    }

    static func job(width: Int = 48, height: Int = 32, steps: Int = 4, seed: UInt64 = 11) throws -> RemovalJob {
        var image = [UInt8](repeating: 0, count: width * height * 3), mask = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * width + x
                image[p * 3] = UInt8((x * 5 + y) % 256)
                image[p * 3 + 1] = UInt8((x * x + y * 7) % 256)
                image[p * 3 + 2] = UInt8((x ^ y) * 4 % 256)
                if (width / 4..<width / 2).contains(x), (height / 4..<height / 2).contains(y) { mask[p] = 255 }
            }
        }
        return try RemovalJob(width: width, height: height, image: image, mask: mask, steps: steps, seed: seed)
    }

    /// Waits on the helper's own files, with a bound generous enough for a loaded Mac: a minute, or `seconds`.
    static func until(_ what: String, seconds: Double = 60, sourceLocation: SourceLocation = #_sourceLocation,
                      _ condition: @Sendable () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting until \(what)", sourceLocation: sourceLocation)
    }
}

final class StepPairs: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [[Int]] = []
    func add(_ done: Int, _ of: Int) { lock.withLock { steps.append([done, of]) } }
    var all: [[Int]] { lock.withLock { steps } }
}

final class Order: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int] = []
    func add(_ item: Int) { lock.withLock { items.append(item) } }
    var all: [Int] { lock.withLock { items } }
}

/// Every state an engine says, as it changes, read every 5 ms until stopped.
final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [RemovalEngineState] = []
    private var stopped = false

    init(_ engine: FolderEngine) {
        Thread.detachNewThread { [self] in
            while !lock.withLock({ stopped }) {
                let state = engine.state
                lock.withLock { if states.last != state { states.append(state) } }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    func stop() { lock.withLock { stopped = true } }
    var all: [RemovalEngineState] { lock.withLock { states } }
}
