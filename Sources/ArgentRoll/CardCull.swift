import ArgentCore
import Foundation

public struct CardCull: Sendable {
    /// The raws `RollScanner.rawFiles` finds in the folder, in capture order; `verdicts[i]` is
    /// `frames[i]`'s fate.
    public var frames: [CullInput]
    public var verdicts: [CullVerdict]

    public init(frames: [CullInput], verdicts: [CullVerdict]) {
        self.frames = frames
        self.verdicts = verdicts
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noFolder(URL)
        case unreadable(URL)
        case rawGone(URL)

        public var description: String {
            switch self {
            case .noFolder(let folder): return "no folder at \(folder.path)"
            case .unreadable(let folder): return "cannot read \(folder.path)"
            case .rawGone(let raw): return "\(raw.path) went away during the cull"
            }
        }
    }

    static let lanes = ProcessInfo.processInfo.activeProcessorCount

    /// Scores every raw in `folder` from its IFD0 preview, `lanes` at once, and decides each one's
    /// fate with `settings`. The folder is only read. A raw whose header or preview cannot be read
    /// has no scores; one that is gone by the end of the cull, as every raw on an ejected card is,
    /// ends it with `Failure.rawGone`. `progress` hears how many frames are scored or found
    /// unreadable and of how many: once before the first, then after each until the cull stops,
    /// one call at a time, on no particular thread. Cancelling the task stops the cull between
    /// frames and throws `CancellationError`.
    public static func run(folder: URL, settings: CullSettings = CullSettings(),
                           progress: @escaping @Sendable (_ scored: Int, _ total: Int) -> Void = { _, _ in }) async throws -> CardCull {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.noFolder(folder)
        }
        guard (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil else {
            throw Failure.unreadable(folder)
        }
        let files = RollScanner.rawFiles(in: folder)
        let depth = URL(fileURLWithPath: folder.canonicalPath).pathComponents.count
        let paths = files.map { URL(fileURLWithPath: $0.canonicalPath).pathComponents.dropFirst(depth).joined(separator: "/") }
        let pass = Pass(paths.map { CullInput(path: $0, captureDate: nil, scores: nil) })
        progress(0, files.count)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    DispatchQueue.concurrentPerform(iterations: max(1, min(lanes, files.count))) { _ in
                        while let index = pass.take() {
                            // Vision autoreleases each preview's buffers, and a lane is one block that
                            // would otherwise hold them all until it ends.
                            let frame = autoreleasepool { input(files[index], path: paths[index]) }
                            if frame.scores == nil, !FileManager.default.fileExists(atPath: files[index].path) {
                                pass.halt(.rawGone(files[index]))
                            } else {
                                pass.finish(index, frame, progress)
                            }
                        }
                    }
                    continuation.resume()
                }
            }
        } onCancel: {
            pass.halt(.cancelled)
        }
        let (frames, stop) = pass.result
        switch stop {
        case .cancelled: throw CancellationError()
        case .rawGone(let raw): throw Failure.rawGone(raw)
        case nil: break
        }
        if let gone = files.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
            throw Failure.rawGone(gone)
        }
        let verdicts = Cull.verdicts(frames, settings: settings)
        let byPath = Dictionary(uniqueKeysWithValues: frames.map { ($0.path, $0) })
        return CardCull(frames: verdicts.map { byPath[$0.path]! }, verdicts: verdicts)
    }

    private static func input(_ url: URL, path: String) -> CullInput {
        guard let info = try? ARWFrameInfo.read(from: url) else { return CullInput(path: path, captureDate: nil, scores: nil) }
        let scores = info.preview
            .flatMap { try? EmbeddedJPEG.image(at: $0, in: url, maxPixelSize: .max, orientation: .up) }
            .flatMap { try? PreviewScoring.scores(of: $0, orientation: info.orientation) }
        return CullInput(path: path, captureDate: info.captureDate, scores: scores)
    }
}

private final class Pass: @unchecked Sendable {
    enum Stop { case cancelled, rawGone(URL) }

    private let stateLock = NSLock()
    private let progressLock = NSLock()
    private var frames: [CullInput]
    private var taken = 0
    private var scored = 0
    private var stop: Stop?

    init(_ frames: [CullInput]) { self.frames = frames }

    func take() -> Int? {
        stateLock.withLock {
            guard stop == nil, taken < frames.count else { return nil }
            defer { taken += 1 }
            return taken
        }
    }

    func finish(_ index: Int, _ frame: CullInput, _ progress: (Int, Int) -> Void) {
        progressLock.withLock {
            let count: (scored: Int, total: Int)? = stateLock.withLock {
                guard stop == nil else { return nil }
                frames[index] = frame
                scored += 1
                return (scored, frames.count)
            }
            if let count { progress(count.scored, count.total) }
        }
    }

    func halt(_ reason: Stop) { stateLock.withLock { stop = stop ?? reason } }

    var result: (frames: [CullInput], stop: Stop?) { stateLock.withLock { (frames, stop) } }
}
