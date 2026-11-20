import Foundation

/// The folder an engine's process serves and the app reads (docs/remove-plan.md, section 4.5): the bundled helper serves it, and
/// a PyTorch bridge served the same layout until the helper passed its gate, which is how the app came to have one client
/// (`FolderEngine`) that knows nothing of a model.
///
///     engine.json                 the server's state, rewritten on each change and every `beatInterval`
///     want                        the client's wish, one word: `loaded` or `unloaded`
///     jobs/<id>/job.json          the job's settings, then image.png and mask.png beside it: the client's
///     jobs/<id>/status.json       the server's: where the job is
///     jobs/<id>/out.png           the model's picture, and attn.png, its attention map: the server's, before `done`
///     jobs/<id>/cancel            the client's: stop between two steps
///     prepare.json                the client's: the size the next job will have, as soon as something is selected
///
/// Every file is written under a temporary name beside its own and renamed into place, so a reader never sees a part. A job's
/// folder is the client's to make and to remove; `job.json` is renamed last, and it is what tells the server the job is whole. The
/// pictures are 8 bits a channel at the job's size: image.png and out.png in red, green and blue, mask.png and attn.png in gray.
/// A server serves one job at a time, in the order their `job.json` arrived. Unloading is its process exiting.
///
/// `prepare.json` is a hint and never a promise. The bundled model compiles for each working size at its first call with it, five
/// to eight seconds in every process (measured in package H1), so a server that has such a cost pays it while the selection is
/// still being made and the removal that follows runs warm. A server with no such cost may ignore the file.
public enum RemovalFolder {
    public static let engineFile = "engine.json"
    public static let wantFile = "want"
    public static let jobsFolder = "jobs"
    public static let jobFile = "job.json"
    public static let imageFile = "image.png"
    public static let maskFile = "mask.png"
    public static let statusFile = "status.json"
    public static let outputFile = "out.png"
    public static let attentionFile = "attn.png"
    public static let cancelFile = "cancel"
    public static let prepareFile = "prepare.json"

    /// How often a live server rewrites `engine.json`.
    public static let beatInterval: TimeInterval = 1

    /// What `want` holds.
    public enum Want: String, Sendable {
        case loaded, unloaded
    }

    /// `engine.json`.
    public struct Engine: Codable, Sendable, Equatable {
        public enum State: String, Codable, Sendable {
            case idle, preparing, loading, ready, running
        }
        public var state: State
        /// How far the one-time preparation is, 0 to 1, where the server can tell.
        public var preparing: Double?
        /// Which engine this is (`RemovalOutput.engine`) and its weights' SHA-256.
        public var engine: String
        public var weights: String
        public var pid: Int32
        /// When this was written, in seconds since 1970.
        public var beat: Double

        public init(state: State, preparing: Double? = nil, engine: String, weights: String, pid: Int32, beat: Double) {
            self.state = state; self.preparing = preparing; self.engine = engine; self.weights = weights; self.pid = pid; self.beat = beat
        }

        /// The state as the app's rows say it.
        public var engineState: RemovalEngineState {
            switch state {
            case .idle: .idle
            case .preparing: .preparing(preparing)
            case .loading: .loading
            case .ready: .ready
            case .running: .running
            }
        }
    }

    /// `prepare.json`: the working size the next job is expected to have.
    public struct Prepare: Codable, Sendable, Equatable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width; self.height = height
        }
    }

    /// `job.json`: a `RemovalJob`'s settings; its pictures are the two PNGs beside it.
    public struct Job: Codable, Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var steps: Int
        public var guidance: Float
        public var seed: UInt64

        public init(_ job: RemovalJob) {
            width = job.width; height = job.height; steps = job.steps; guidance = job.guidance; seed = job.seed
        }
    }

    /// `status.json`.
    public struct Status: Codable, Sendable, Equatable {
        public enum State: String, Codable, Sendable {
            case queued, running, done, failed, cancelled
        }
        public var state: State
        /// The steps finished and the job's count, while it runs.
        public var step: Int?
        public var steps: Int?
        /// Why it failed.
        public var error: String?

        public init(state: State, step: Int? = nil, steps: Int? = nil, error: String? = nil) {
            self.state = state; self.step = step; self.steps = steps; self.error = error
        }
    }
}
