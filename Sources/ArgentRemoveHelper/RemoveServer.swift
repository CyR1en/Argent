import ArgentCore
import Darwin
import Foundation

/// What the server needs of a model: the bundled ObjectClear (`ObjectClearModel`), or none at all (`FakeModel`) for the suites that
/// prove the folder's rules in milliseconds.
protocol RemovalModel: AnyObject, Sendable {
    /// `RemovalOutput.engine`, and the weights' SHA-256.
    var engine: String { get }
    var weights: String { get }
    /// Whether the one-time preparation has to run before the first load: after an install, a new model or a macOS update.
    func needsPreparation() -> Bool
    /// The one-time preparation, telling how far it is, 0 to 1.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func load() async throws
    /// Whether a job of this size runs without compiling first.
    func isWarm(width: Int, height: Int) async -> Bool
    /// Compiles for a size ahead of the job that will have it, telling how far it is.
    func warm(width: Int, height: Int, progress: @escaping @Sendable (Double) -> Void) async throws
    /// One job: the picture, `H x W x 3`, and the attention map, `H x W`. `step` is told each finished step and stops the run by
    /// throwing.
    func run(_ job: RemovalFolder.Job, image: [UInt8], mask: [UInt8], step: @escaping (Int) async throws -> Void) async throws
        -> (picture: [UInt8], attention: [UInt8])
}

/// The job could not be run as it was given; the model was not touched.
struct RefusedJob: Error {
    let why: String
}

/// The client asked the run to stop, or took the job's folder away.
struct CancelledJob: Error {}

/// Serves a `RemovalFolder` with a model, as the PyTorch bridge served it until this passed its gate (Git has it): the other server of the same
/// folder, and this one's reference for what the layout does not spell out (docs/remove-plan.md, section 4.5).
///
/// - `engine.json` says this process's state, its engine, its weights and its id, rewritten on each change and every second.
/// - It loads when `want` says `loaded`, a wish already there when it starts included, or when a job comes. A model that cannot be
///   loaded fails every job with the reason, so the row can say it.
/// - `unloaded` is this process ending with status 0, at once, from a thread of its own, in a load or in a step: a job in flight
///   or waiting is marked failed, `engine.json` says `idle` as its last word, and the process is gone with its memory. It also
///   ends when its parent has gone, and when nothing has been asked of it for `idle` seconds.
/// - One job at a time, in the order their `job.json` arrived; `status.json` at each step; `cancel` honoured between two steps.
/// - `prepare.json`: while nothing runs, the size it names is compiled for, saying `preparing`; once for each writing of it after
///   the process started.
/// - A run that fails inside the model ends the process too: a GPU that answered with zeros is not trusted
///   with the next job.
final class RemoveServer: @unchecked Sendable {
    struct Options {
        var root: URL
        var beat: TimeInterval = RemovalFolder.beatInterval
        var poll: TimeInterval = 0.05
        /// A job older than this at the start was left by an app that has gone, and is failed.
        var stale: TimeInterval = 30
        /// Seconds with nothing asked before the model is let go; 0 for never. The app does it after two minutes; this is for an
        /// app that died with the model loaded and a parent that did not.
        var idle: TimeInterval = 600
    }

    private let options: Options
    private let model: any RemovalModel
    private let jobs: URL
    private let lock = NSLock()
    // Under the lock.
    private var state: RemovalFolder.Engine.State = .idle
    private var preparing: Double?
    private var current: String?
    private var queue: [String] = []
    private var leaving = false
    private var told = Date.distantPast
    // The serving task's own.
    private var known = Set<String>()
    private var refusal: String?
    private var active = Date()
    private var prepared: FileIdentity?
    private var seen: FileIdentity?
    private let parent = getppid()
    /// The wish as it was when the process started: an `unloaded` there then was the last session's.
    private let wishAtStart: (word: String?, identity: FileIdentity?)

    init(options: Options, model: any RemovalModel) {
        self.options = options
        self.model = model
        jobs = options.root.appendingPathComponent(RemovalFolder.jobsFolder, isDirectory: true)
        wishAtStart = Self.want(in: options.root)
        seen = wishAtStart.identity
        // A size announced to an earlier process is no news to this one: only a writing after the start is a hint.
        prepared = FileIdentity(options.root.appendingPathComponent(RemovalFolder.prepareFile))
    }

    /// Serves until the process ends. Never returns.
    func serve() async -> Never {
        try? FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        // Pieces of an engine.json a process that died mid-write left.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: options.root.path)) ?? []
        where name.hasPrefix(".\(RemovalFolder.engineFile).tmp-") {
            try? FileManager.default.removeItem(at: options.root.appendingPathComponent(name))
        }
        tell()
        let watcher = Thread { [self] in watch() }
        watcher.qualityOfService = .userInitiated
        watcher.start()
        say("\(model.engine) serves \(options.root.path) (pid \(getpid())), idle")
        arrivals(first: true)
        while true {
            arrivals()
            let wish = Self.want(in: options.root)
            if wish.identity != seen {
                seen = wish.identity
                active = Date()
            }
            if lock.withLock({ state }) == .idle, refusal == nil, wish.word == RemovalFolder.Want.loaded.rawValue || !lock.withLock({ queue.isEmpty }) {
                await load()
            }
            if let refusal {
                for name in lock.withLock({ () -> [String] in defer { queue = [] }; return queue }) { status(name, .failed, error: refusal) }
            }
            if lock.withLock({ state }) == .ready {
                if let next = lock.withLock({ queue.isEmpty ? nil : queue.removeFirst() }) {
                    await run(next)
                    continue
                }
                await prepareAhead()
            }
            if options.idle > 0, -active.timeIntervalSinceNow > options.idle {
                leave("nothing asked for \(Int(options.idle)) s: unloaded")
            }
            try? await Task.sleep(for: .seconds(options.poll))
        }
    }

    // MARK: Loading

    private func load() async {
        let began = Date()
        do {
            if model.needsPreparation() {
                become(.preparing, 0)
                let started = Date()
                try await model.prepare { [weak self] fraction in self?.progress(fraction) }
                say("prepared in \(Self.seconds(since: started))\(Self.footprint())")
            }
            become(.loading)
            try await model.load()
        } catch {
            let why = "The model did not load: \(Self.reason(error))"
            say(why)
            refusal = why
            become(.idle)
            return
        }
        active = Date()
        become(.ready)
        say("loaded in \(Self.seconds(since: began))\(Self.footprint())")
    }

    /// Compiles for the size `prepare.json` names, once for each writing of it.
    private func prepareAhead() async {
        let file = options.root.appendingPathComponent(RemovalFolder.prepareFile)
        guard let identity = FileIdentity(file), identity != prepared else { return }
        prepared = identity
        guard let data = try? Data(contentsOf: file), let size = try? JSONDecoder().decode(RemovalFolder.Prepare.self, from: data),
              Self.isWorkingSize(size.width, size.height), await !model.isWarm(width: size.width, height: size.height) else { return }
        let started = Date()
        become(.preparing, 0)
        do {
            try await model.warm(width: size.width, height: size.height) { [weak self] fraction in self?.progress(fraction) }
            say("compiled for \(size.width) x \(size.height) in \(Self.seconds(since: started))\(Self.footprint())")
            become(.ready)
        } catch {
            leave("compiling for \(size.width) x \(size.height) failed: \(Self.reason(error)); unloaded, for the model may not be whole")
        }
    }

    // MARK: Running

    private func run(_ name: String) async {
        let folder = jobs.appendingPathComponent(name, isDirectory: true)
        let job: RemovalFolder.Job
        do {
            job = try JSONDecoder().decode(RemovalFolder.Job.self, from: Data(contentsOf: folder.appendingPathComponent(RemovalFolder.jobFile)))
        } catch {
            status(name, .failed, error: "job.json cannot be read: \(Self.reason(error))")
            return
        }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(RemovalFolder.cancelFile).path) {
            status(name, .cancelled)
            return
        }
        let began = Date(), steps = job.steps
        let size = "\(job.width) x \(job.height), \(steps) steps at \(job.guidance)"
        lock.withLock { current = name }
        defer {
            lock.withLock { current = nil }
            active = Date()
        }
        // A size not compiled for says `preparing` until its first step, so the queue does not take the compile for silence.
        let warm = await model.isWarm(width: job.width, height: job.height)
        become(warm ? .running : .preparing)
        var firstStep: Date?, lastStep: Date?
        let step: (Int) async throws -> Void = { [self] done in
            if done > 0 { become(.running) }
            if done == 1 { firstStep = Date() }
            if done == steps { lastStep = Date() }
            let written = status(name, .running, step: done, steps: steps)
            arrivals()
            if !written || FileManager.default.fileExists(atPath: folder.appendingPathComponent(RemovalFolder.cancelFile).path) {
                throw CancelledJob()
            }
        }
        do {
            try await step(0)
            guard Self.isWorkingSize(job.width, job.height), (1...100).contains(job.steps), job.guidance.isFinite, job.guidance >= 1 else {
                throw RefusedJob(why: "a job is a working size, multiples of \(RemovalPatch.sideMultiple), 1 to 100 steps at a guidance of 1 or more")
            }
            guard let image = Pictures.pixels(of: folder.appendingPathComponent(RemovalFolder.imageFile), width: job.width, height: job.height, channels: 3),
                  let mask = Pictures.pixels(of: folder.appendingPathComponent(RemovalFolder.maskFile), width: job.width, height: job.height, channels: 1) else {
                throw RefusedJob(why: "image.png and mask.png are not 8-bit PNGs of the job's size")
            }
            let drawn = try await model.run(job, image: image, mask: mask, step: step)
            do {
                try Self.place(try Pictures.png(drawn.picture, width: job.width, height: job.height, channels: 3),
                               at: folder.appendingPathComponent(RemovalFolder.outputFile))
                try Self.place(try Pictures.png(drawn.attention, width: job.width, height: job.height, channels: 1),
                               at: folder.appendingPathComponent(RemovalFolder.attentionFile))
            } catch {
                throw CancelledJob()  // the client took the folder away
            }
            guard status(name, .done) else { throw CancelledJob() }
            let phases = [firstStep.map { "first step at \(String(format: "%.2f", $0.timeIntervalSince(began)))" },
                          lastStep.map { "last at \(String(format: "%.2f", $0.timeIntervalSince(began)))" }].compactMap { $0 }
            say("\(name): \(size)\(warm ? "" : ", a new size"), done in \(Self.seconds(since: began)) (\(phases.joined(separator: ", ")))"
                + Self.footprint())
        } catch is CancelledJob {
            status(name, .cancelled)
            say("\(name): \(size), cancelled after \(Self.seconds(since: began))")
        } catch let refused as RefusedJob {
            status(name, .failed, error: refused.why)
            say("\(name): refused: \(refused.why)")
        } catch {
            status(name, .failed, error: Self.reason(error))
            lock.withLock { current = nil }
            leave("\(name): failed: \(Self.reason(error)); unloaded, for the model may not be whole")
        }
        become(.ready)
    }

    // MARK: The folder

    private func say(_ text: String) {
        let stamp = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        FileHandle.standardError.write(Data("\(stamp) \(text)\n".utf8))
    }

    /// Writes `engine.json`. Once the process is leaving only its last word is written.
    private func tell(last: Bool = false) {
        lock.withLock {
            if leaving && !last { return }
            let engine = RemovalFolder.Engine(state: last ? .idle : state, preparing: !last && state == .preparing ? preparing : nil,
                                              engine: model.engine, weights: model.weights, pid: getpid(), beat: Date().timeIntervalSince1970)
            if let data = try? JSONEncoder().encode(engine) {
                try? Self.place(data, at: options.root.appendingPathComponent(RemovalFolder.engineFile))
            }
            told = Date()
        }
    }

    private func become(_ state: RemovalFolder.Engine.State, _ preparing: Double? = nil) {
        let changed = lock.withLock { () -> Bool in
            defer { self.state = state; self.preparing = preparing }
            return self.state != state || self.preparing != preparing
        }
        if changed { tell() }
    }

    /// A fraction of a preparation, told at most ten times a second.
    private func progress(_ fraction: Double) {
        let due = lock.withLock { () -> Bool in
            preparing = min(max(fraction, 0), 1)
            return -told.timeIntervalSinceNow >= 0.1
        }
        if due { tell() }
    }

    /// Writes a job's `status.json`. False when it could not: the client took the folder away, or the process is leaving.
    @discardableResult
    private func status(_ name: String, _ state: RemovalFolder.Status.State, step: Int? = nil, steps: Int? = nil, error: String? = nil,
                        forced: Bool = false) -> Bool {
        lock.withLock {
            if leaving && !forced { return false }
            guard let data = try? JSONEncoder().encode(RemovalFolder.Status(state: state, step: step, steps: steps, error: error)) else { return false }
            return (try? Self.place(data, at: jobs.appendingPathComponent(name).appendingPathComponent(RemovalFolder.statusFile))) != nil
        }
    }

    /// Jobs whose `job.json` has come since the last look join the queue in the order they came; a waiting job the client
    /// cancelled or took away leaves it.
    private func arrivals(first: Bool = false) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: jobs.path)) ?? []
        var came: [(when: Int, name: String)] = []
        for name in names where !name.hasPrefix(".") && !known.contains(name) {
            var info = stat()
            // Not whole yet: job.json is renamed into place last.
            guard stat(jobs.appendingPathComponent(name).appendingPathComponent(RemovalFolder.jobFile).path, &info) == 0 else { continue }
            came.append((info.st_mtimespec.tv_sec * 1_000_000_000 + info.st_mtimespec.tv_nsec, name))
        }
        for (when, name) in came.sorted(by: { ($0.when, $0.name) < ($1.when, $1.name) }) {
            known.insert(name)
            take(name, when: when, first: first)
        }
        let waiting = lock.withLock { queue }
        for name in waiting {
            let folder = jobs.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(RemovalFolder.cancelFile).path) {
                lock.withLock { queue.removeAll { $0 == name } }
                status(name, .cancelled)
            } else if !FileManager.default.fileExists(atPath: folder.path) {
                lock.withLock { queue.removeAll { $0 == name } }
            }
        }
        known.formIntersection(names)
    }

    private func take(_ name: String, when: Int, first: Bool) {
        let folder = jobs.appendingPathComponent(name, isDirectory: true)
        if let data = try? Data(contentsOf: folder.appendingPathComponent(RemovalFolder.statusFile)) {
            // An earlier server's job. One it did not finish is failed, so its client stops waiting for it.
            if let left = try? JSONDecoder().decode(RemovalFolder.Status.self, from: data), left.state == .queued || left.state == .running {
                status(name, .failed, error: "the engine stopped during this job")
            }
            return
        }
        if first, Date().timeIntervalSince1970 - Double(when) / 1e9 > options.stale {
            status(name, .failed, error: "left from an earlier session")
            return
        }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(RemovalFolder.cancelFile).path) {
            status(name, .cancelled)
            return
        }
        let behind = lock.withLock { current != nil || !queue.isEmpty }
        if behind { status(name, .queued) }
        lock.withLock { queue.append(name) }
    }

    // MARK: Leaving

    /// A thread of its own: the beat, the wish to unload, the parent's going. It must be heard while the serving task is inside a
    /// load or a step.
    private func watch() {
        let atStart = wishAtStart
        while true {
            Thread.sleep(forTimeInterval: options.poll)
            let wish = Self.want(in: options.root)
            // A wish to unload already there at the start was the last session's.
            if wish.word == RemovalFolder.Want.unloaded.rawValue, wish.identity != atStart.identity || atStart.word != wish.word {
                leave("unloaded")
            }
            if getppid() != parent { leave("the app has gone: unloaded") }
            if lock.withLock({ -told.timeIntervalSinceNow }) >= options.beat { tell() }
        }
    }

    /// Ends the process, and with it the model's memory: `engine.json`'s last word is `idle`, so the client need not wait for the
    /// beat to stop. Every job in flight or waiting is failed first.
    private func leave(_ why: String) -> Never {
        let names = lock.withLock { () -> [String]? in
            if leaving { return nil }
            leaving = true
            return [current].compactMap { $0 } + queue
        }
        // Another thread is already leaving; it ends the process.
        guard let names else { while true { Thread.sleep(forTimeInterval: 60) } }
        for name in names { status(name, .failed, error: "the engine was unloaded", forced: true) }
        tell(last: true)
        say("\(why)\(Self.footprint())")
        _exit(0)
    }

    // MARK: Support

    struct FileIdentity: Equatable {
        let inode: UInt64
        let modified: Int

        init?(_ url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            inode = info.st_ino
            modified = info.st_mtimespec.tv_sec * 1_000_000_000 + info.st_mtimespec.tv_nsec
        }
    }

    /// The client's wish: its word, and what tells this writing of it from any other.
    static func want(in root: URL) -> (word: String?, identity: FileIdentity?) {
        let file = root.appendingPathComponent(RemovalFolder.wantFile)
        let identity = FileIdentity(file)
        let word = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (word, identity)
    }

    static func isWorkingSize(_ width: Int, _ height: Int) -> Bool {
        let multiple = RemovalPatch.sideMultiple
        return PatchRef.sideRange.contains(width) && PatchRef.sideRange.contains(height) && width.isMultiple(of: multiple) && height.isMultiple(of: multiple)
    }

    /// Writes `data` under a temporary name beside `url` and renames it into place, so a reader never sees a part.
    static func place(_ data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(getpid())-\(UUID().uuidString)")
        try data.write(to: temporary)
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    static func reason(_ error: any Error) -> String {
        if let error = error as? ObjectClearError { return error.description }
        if let error = error as? RefusedJob { return error.why }
        return error.localizedDescription
    }

    static func seconds(since date: Date) -> String {
        String(format: "%.2f s", -date.timeIntervalSinceNow)
    }

    /// This process's footprint now and at its most, as the system counts it for the develop's gate, and its most resident memory,
    /// most of it the graphs' files mapped clean.
    static func footprint() -> String {
        guard let usage = Self.usage() else { return "" }
        var resources = rusage()
        getrusage(RUSAGE_SELF, &resources)
        return String(format: ", footprint %.2f GB, peak %.2f GB, most resident %.2f GB", Double(usage.now) / 1e9, Double(usage.peak) / 1e9,
                      Double(resources.ru_maxrss) / 1e9)
    }

    static func usage() -> (now: UInt64, peak: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        return (info.ri_phys_footprint, info.ri_lifetime_max_phys_footprint)
    }
}
