import ArgentCore
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The model behind a folder: the app's client of `RemovalFolder`, which the bundled helper serves (docs/remove-plan.md,
/// section 4.5). It writes the app's wish and its jobs, reads what the server writes, and knows nothing of a model. Every file it
/// writes goes under a temporary name beside its own and is renamed into place.
///
/// The server is a process a closure starts on the folder. With no process the engine is `idle`, present and holding nothing;
/// `load` starts one, and that process's exit, asked for or not, is the model unloaded. `unload` writes the wish and returns
/// when the process has exited, ending it if it has not gone within `unloadLimit`.
///
/// Safe to call from any thread.
public final class FolderEngine: RemovalEngine, @unchecked Sendable {
    /// Starts a server on the folder and returns its process, running.
    public typealias Launcher = @Sendable (_ root: URL) throws -> Process

    /// How often a run reads its job's status, and an unload looks for the server's going.
    public static let poll: Duration = .milliseconds(50)
    /// How long `unload` waits for a server to go: what a develop will wait for (docs/remove-plan.md, section 4.5).
    public static let unloadLimit: TimeInterval = 2
    /// How long a server is given to hear a wish to load. Until then `state` answers `loading` for an idle server that was just
    /// asked, so the queue never takes the moment between the wish and its hearing for a model that will not load.
    static let hearing: TimeInterval = 2 * RemovalFolder.beatInterval
    /// How old a job's folder is before a later run removes it: its client died and nothing else would.
    static let abandonedAge: TimeInterval = 3600

    public let root: URL
    private let launcher: Launcher
    private let poll: Duration
    private let unloadLimit: TimeInterval

    private let lock = NSLock()
    /// The process this engine launched, while it has one; why the last launch failed, if it did.
    private var process: Process?
    private var failure: String?
    /// The wish last written, and when it last was `loaded`.
    private var wish: RemovalFolder.Want?
    private var asked: Date?
    private var prepared: RemovalFolder.Prepare?

    /// - Parameter launcher: starts a server on `root`.
    public init(root: URL, launcher: @escaping Launcher, poll: Duration = FolderEngine.poll,
                unloadLimit: TimeInterval = FolderEngine.unloadLimit) {
        self.root = root
        self.launcher = launcher
        self.poll = poll
        self.unloadLimit = unloadLimit
    }

    private var jobs: URL { root.appendingPathComponent(RemovalFolder.jobsFolder, isDirectory: true) }

    // MARK: The engine

    public var state: RemovalEngineState {
        let (served, asked, failure) = lock.withLock { (server(), self.asked, self.failure) }
        switch served {
        case .none: return failure.map { .absent($0) } ?? .idle
        case .starting: return .loading
        case .serving(let engine):
            if engine.state == .idle, let asked, -asked.timeIntervalSinceNow < Self.hearing { return .loading }
            return engine.engineState
        }
    }

    public func load() {
        lock.withLock {
            let served = server()
            // The wish is in the folder before the server starts, so it reads it as its first.
            try? FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
            wishLoaded(served)
            guard case .none = served else { return }
            do {
                process = try launcher(root)
                failure = nil
                // A size announced to the last process is news to this one, which takes only what is written after it starts.
                prepared = nil
            } catch {
                process = nil
                failure = "The model's process did not start: \(error.localizedDescription)"
            }
        }
    }

    public func unload() async {
        let leaving = lock.withLock { () -> (process: Process, holdsNothing: Bool)? in
            asked = nil
            guard let process, process.isRunning else { return nil }
            // A server that has loaded nothing has nothing to give back and may not go by itself: it is this engine's own
            // process, and is told to. One that holds a model says `idle` only as its last word, and is left to go.
            var holdsNothing = true
            if case .serving(let engine) = server(), engine.state != .idle { holdsNothing = false }
            write(.unloaded)
            return (process, holdsNothing)
        }
        guard let (process, nothing) = leaving else { return }
        var holdsNothing = nothing
        let deadline = Date(timeIntervalSinceNow: unloadLimit)
        while process.isRunning, Date() < deadline {
            if holdsNothing, let engine = engineFile(), engine.pid == process.processIdentifier, engine.state == .idle {
                holdsNothing = false
                process.terminate()
            }
            await Self.pause(poll)
        }
        if process.isRunning {
            // It did not go when asked, and it holds the memory a develop is waiting for.
            kill(process.processIdentifier, SIGKILL)
            while process.isRunning { await Self.pause(poll) }
        }
        lock.withLock { if self.process === process { self.process = nil } }
    }

    public func run(_ job: RemovalJob, step: @escaping @Sendable (Int, Int) -> Void) async throws -> RemovalOutput {
        // A run cancelled before it began asks nothing of the server.
        try Task.checkCancellation()
        load()
        if case .absent(let why) = state { throw RemovalRunFailure.failed(why) }
        sweep()
        let folder = jobs.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.place(try Self.png(job.image, width: job.width, height: job.height, channels: 3),
                           at: folder.appendingPathComponent(RemovalFolder.imageFile))
            try Self.place(try Self.png(job.mask, width: job.width, height: job.height, channels: 1),
                           at: folder.appendingPathComponent(RemovalFolder.maskFile))
            // Last: it is what tells the server the job is whole.
            try Self.place(try JSONEncoder().encode(RemovalFolder.Job(job)), at: folder.appendingPathComponent(RemovalFolder.jobFile))
        } catch {
            throw RemovalRunFailure.failed("The job could not be written: \(error.localizedDescription)")
        }

        var reported = 0, count = job.steps, asksToStop = false
        while true {
            if Task.isCancelled, !asksToStop {
                asksToStop = true
                try? Self.place(Data(), at: folder.appendingPathComponent(RemovalFolder.cancelFile))
            }
            let status = (try? Data(contentsOf: folder.appendingPathComponent(RemovalFolder.statusFile)))
                .flatMap { try? JSONDecoder().decode(RemovalFolder.Status.self, from: $0) }
            switch status?.state {
            case nil:
                // Not taken yet. A server that started since the wish was written has not read it: it is made again.
                lock.withLock {
                    let served = server()
                    if case .serving = served { wishLoaded(served) }
                }
            case .queued?: break
            case .running?:
                count = status?.steps ?? count
                // Every step is told, in order, though two may have ended between two looks.
                if let done = status?.step, done > reported {
                    for finished in (reported + 1)...done { step(finished, count) }
                    reported = done
                }
            case .done?:
                // Asked to stop as the last step ended: the picture is there and nobody waits for it.
                if asksToStop { throw CancellationError() }
                if reported < count {
                    for finished in (reported + 1)...count { step(finished, count) }
                }
                return try output(of: job, in: folder)
            case .failed?:
                if asksToStop { throw CancellationError() }
                throw RemovalRunFailure.failed(status?.error ?? "the engine gave no reason")
            case .cancelled?:
                throw CancellationError()
            }
            if let why = departure() {
                if asksToStop { throw CancellationError() }
                throw RemovalRunFailure.failed(why)
            }
            await Self.pause(poll)
        }
    }

    // MARK: The server

    private enum Server {
        /// Nobody serves: no process has been launched, or the one that was has gone.
        case none
        /// A launched process that has not yet written its own `engine.json`.
        case starting
        case serving(RemovalFolder.Engine)
    }

    /// `engine.json` as it stands, whatever its age.
    private func engineFile() -> RemovalFolder.Engine? {
        (try? Data(contentsOf: root.appendingPathComponent(RemovalFolder.engineFile)))
            .flatMap { try? JSONDecoder().decode(RemovalFolder.Engine.self, from: $0) }
    }

    /// Who serves the folder now. Under the lock.
    private func server() -> Server {
        guard let process, process.isRunning else { return .none }
        // An `engine.json` of another process is the last server's.
        guard let engine = engineFile(), engine.pid == process.processIdentifier else { return .starting }
        return .serving(engine)
    }

    /// Writes the wish to load, unless the server has heard it or was asked a moment ago. Under the lock.
    private func wishLoaded(_ served: Server) {
        if wish == .loaded {
            if case .serving(let engine) = served, engine.state != .idle { return }
            if let asked, -asked.timeIntervalSinceNow < Self.hearing { return }
        }
        if write(.loaded) { asked = Date() }
    }

    /// The size the next job will have, for a server that compiles for a size (`RemovalFolder.prepareFile`). Written only where a
    /// server is there to read it, and not twice for one size.
    public func prepare(width: Int, height: Int) {
        lock.withLock {
            let size = RemovalFolder.Prepare(width: width, height: height)
            guard size != prepared, case .serving = server(), let data = try? JSONEncoder().encode(size) else { return }
            if (try? Self.place(data, at: root.appendingPathComponent(RemovalFolder.prepareFile))) != nil { prepared = size }
        }
    }

    /// Under the lock. False when the wish could not be written, so the next asking writes it.
    @discardableResult private func write(_ want: RemovalFolder.Want) -> Bool {
        do {
            try Self.place(Data(want.rawValue.utf8), at: root.appendingPathComponent(RemovalFolder.wantFile))
            wish = want
            return true
        } catch {
            wish = nil
            return false
        }
    }

    /// Why the server is no longer there to finish a job, if it is not.
    private func departure() -> String? {
        lock.withLock { process?.isRunning == true } ? nil : "The model's process stopped"
    }

    /// A wait that a cancelled task still waits: a run asked to stop goes on reading until the server says it has.
    private static func pause(_ duration: Duration) async {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }

    // MARK: Files

    /// Writes `data` under a temporary name beside `url` and renames it into place, so the server never reads a part.
    private static func place(_ data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temporary)
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Removes the folders of jobs whose client died before it could: a run's folder lives for seconds, and these are an hour old.
    /// Only a folder named as this client names one is touched.
    private func sweep() {
        let old = Date(timeIntervalSinceNow: -Self.abandonedAge)
        let folders = (try? FileManager.default.contentsOfDirectory(at: jobs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            guard let changed = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  changed < old else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func output(of job: RemovalJob, in folder: URL) throws -> RemovalOutput {
        guard let image = Self.pixels(of: folder.appendingPathComponent(RemovalFolder.outputFile), width: job.width, height: job.height, channels: 3),
              let attention = Self.pixels(of: folder.appendingPathComponent(RemovalFolder.attentionFile), width: job.width, height: job.height, channels: 1) else {
            throw RemovalRunFailure.failed("The engine's pictures are not 8-bit PNGs of the job's size")
        }
        guard let engine = engineFile() else { throw RemovalRunFailure.failed("The engine does not say which it is") }
        return try RemovalOutput(width: job.width, height: job.height, image: image, attention: attention,
                                 engine: engine.engine, weights: engine.weights)
    }

    // MARK: Pictures

    /// An 8-bit PNG of exactly `width` by `height`: gray for one channel, red, green and blue for three. Row 0 is the top.
    static func png(_ bytes: [UInt8], width: Int, height: Int, channels: Int) throws -> Data {
        let space = channels == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let out = NSMutableData()
        guard bytes.count == width * height * channels, let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * channels,
                                  bytesPerRow: width * channels, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw RemovalError.invalid("a job's picture could not be made")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RemovalError.invalid("a job's picture could not be written") }
        return out as Data
    }

    /// The bytes of an 8-bit PNG of that size and that many channels, as stored: read from the decoded image's own buffer and
    /// never drawn, so no colour conversion can touch a value. Anything else is `nil`.
    static func pixels(of url: URL, width: Int, height: Int, channels: Int) -> [UInt8]? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              image.width == width, image.height == height, image.bitsPerComponent == 8,
              image.colorSpace?.model == (channels == 1 ? .monochrome : .rgb),
              image.byteOrderInfo == .orderDefault || image.byteOrderInfo == .order32Big else { return nil }
        // Where the first colour sits in a pixel: a decoder may pad it to four bytes, before or after.
        let pixel = image.bitsPerPixel / 8, rowBytes = image.bytesPerRow
        let first: Int
        switch image.alphaInfo {
        case .none where pixel == channels: first = 0
        case .noneSkipLast where pixel == channels + 1: first = 0
        case .noneSkipFirst where pixel == channels + 1: first = 1
        default: return nil
        }
        guard rowBytes >= width * pixel, let data = image.dataProvider?.data,
              CFDataGetLength(data) >= rowBytes * (height - 1) + width * pixel, let base = CFDataGetBytePtr(data) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * channels)
        bytes.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                let row = base + y * rowBytes
                if pixel == channels {
                    memcpy(out.baseAddress! + y * width * channels, row, width * channels)
                } else {
                    for x in 0..<width {
                        for channel in 0..<channels { out[(y * width + x) * channels + channel] = row[x * pixel + first + channel] }
                    }
                }
            }
        }
        return bytes
    }
}
