import ArgentCore
import CryptoKit
import Foundation

/// Auto's settled decisions for a roll: one fixed snapshot of its frames and their measurements,
/// resolved once by the sequence method (`SequenceAims`) and published at once, kept on disk, and
/// used again on reopen and by Develop, so a frame's print no longer depends on the order its
/// measurement arrived in, on which frame was opened first, or on how much of the roll was measured
/// when it was shown (docs/research/auto/sequence-consistency.md, "Stage 4 either way"; the plan's
/// step 4, docs/auto-exposure-consistency-plan.md).
///
/// A decision is named by its revision, a fingerprint of what it was resolved from: this version,
/// the method, each frame's raw and measurement, and the parameters, the stock and controls when the
/// method reads them. The same inputs give the same revision and the same aims, bit for bit.
public enum AutoDecisions {
    /// Changes when a decision changes for the same measurements, so a kept decision is resolved
    /// again rather than reused.
    /// 2026-10-22-1: the first: one fixed snapshot of the whole roll, resolved once by `method`.
    /// 2026-11-05-2: aims carry a tone step, and the aim is fitted to Lightroom's Auto on the a7 IV
    /// (docs/research/auto/balance-research.md, section 7d).
    public static let version = "2026-11-25-1"
    /// Roll smoothing remains the prior; the detail check refines its settled aims.
    public static let method: SequenceAims.Method = .detail
    /// `method`'s constants: the frozen ones of a candidate, the defaults for the control, which
    /// reads none of them.
    public static var parameters: SequenceAims.Parameters { parameters(for: method) }

    public static func parameters(for method: SequenceAims.Method) -> SequenceAims.Parameters {
        switch method {
        case .control, .detail: SequenceAims.Parameters()
        case .smoothing: SequenceAims.Parameters.frozenSmoothing
        case .render: SequenceAims.Parameters.frozenRender
        }
    }

    /// Whether `method`'s aims depend on the stock, Rated at and Lab balance.
    public static func readsStock(_ method: SequenceAims.Method) -> Bool { method == .render || method == .detail }

    /// Whether `method` reads the frames' spatial samples.
    public static func readsDescriptors(_ method: SequenceAims.Method) -> Bool { method != .control }

    /// Whether `method`'s aims depend on its `SequenceAims.Parameters`: the candidates' do; the
    /// control reads none of them, so its revision and a kept decision of it leave them out, and a
    /// change of the defaults cannot develop a roll smoothing's roll again.
    public static func readsParameters(_ method: SequenceAims.Method) -> Bool { method == .smoothing || method == .render }

    /// A frame's own aim, from its measurement alone: what it shows while its roll is not yet
    /// settled, rather than roll smoothing over a roll partly measured, which moved 38 of the
    /// owner's 80 frames by more than a tenth of a stop as the roll loaded (the pre-registration,
    /// section 1).
    public static func ownAim(_ analysis: ExposureAnalysis) -> PrintAim {
        AutoPrint.aim(analysis)
    }

    // MARK: Inputs

    /// A frame's raw as a decision saw it: its name, size and capture time, its SHA-256 where
    /// `SourceDigests` knew it for that version, and its stamp; no stamp for a raw that was gone.
    public struct Identity: Sendable, Equatable {
        public var fileName: String
        public var byteCount: Int
        public var captureDate: Date?
        public var sha256: String?
        public var stamp: SourceStamp?

        public init(fileName: String, byteCount: Int, captureDate: Date?, sha256: String?, stamp: SourceStamp?) {
            self.fileName = fileName
            self.byteCount = byteCount
            self.captureDate = captureDate
            self.sha256 = sha256
            self.stamp = stamp
        }

        /// `frame`'s raw at version `stamp`, with its SHA-256 if `digests` already knows it for that
        /// version; nothing is read.
        public init(_ frame: Frame, stamp: SourceStamp?, digests: SourceDigests = .shared) {
            let known = stamp == nil ? nil : digests.known(frame.url)
            self.init(fileName: frame.url.lastPathComponent, byteCount: stamp.map { Int($0.size) } ?? 0,
                      captureDate: frame.info.captureDate, sha256: known?.source == stamp ? known?.sha256 : nil, stamp: stamp)
        }

        /// What the revision reads of it: the content's SHA-256 when known, else the version's stamp
        /// without its device, which a share mounted again gives anew.
        var fingerprint: String {
            let content = sha256.map { "sha256 \($0)" }
                ?? stamp.map { "stamp \($0.inode) \($0.size) \($0.modified) \($0.changed)" } ?? "missing"
            return "\(fileName) \(byteCount) \(content)"
        }

        /// Whether `current`, the raw at the same path now, is this one: the same name and size, and
        /// the same SHA-256 where both know it, else the same version of the file
        /// (`SourceStamp.isSameVersion(atSamePathAs:)`). A raw that was gone matches only while it is.
        public func matches(_ current: Identity) -> Bool {
            guard fileName == current.fileName, byteCount == current.byteCount else { return false }
            if let kept = sha256, let now = current.sha256 { return kept == now }
            switch (stamp, current.stamp) {
            case (nil, nil): return true
            case let (kept?, now?): return kept.isSameVersion(atSamePathAs: now)
            default: return false
            }
        }
    }

    /// One roll's decision inputs, fixed when every frame has a measurement or has failed for good
    /// and its saved choices are restored: what `decide` resolves.
    public struct Snapshot: Sendable {
        /// The frames in capture order, their measurements and descriptors, the stock and controls.
        public var input: SequenceAims.Input
        /// The stock's digest (`Stock.digest`), for a method that reads the stock.
        public var stockDigest: String
        public var frameStockDigests: [URL: String]
        /// Each frame's raw as it was measured, or failed to be.
        public var identities: [URL: Identity]
        /// Frames whose measurement failed for good: they print at `PrintAim()`, the fallback.
        public var failed: Set<URL>

        public init(input: SequenceAims.Input, stockDigest: String, identities: [URL: Identity], failed: Set<URL> = [],
                    frameStockDigests: [URL: String]? = nil) {
            self.input = input
            self.stockDigest = stockDigest
            self.frameStockDigests = frameStockDigests ?? input.frameStocks.mapValues(\.digest)
            self.identities = identities
            self.failed = failed
        }
    }

    // MARK: Decisions

    /// A roll's aims as one revision decided them.
    public struct Decision: Sendable, Equatable {
        /// Every frame's aim: its resolved aim, or `PrintAim()` for a frame whose measurement failed.
        public var aims: [URL: PrintAim]
        /// The frames whose measurement had failed, which print at `PrintAim()`: one measured since
        /// is a new input to the roll's decision.
        public var failed: Set<URL>
        /// What is kept of it on disk, by file name, its revision included.
        public var record: Record

        public init(aims: [URL: PrintAim], failed: Set<URL> = [], record: Record) {
            self.aims = aims
            self.failed = failed
            self.record = record
        }

        public var revision: String { record.revision }
    }

    /// Resolves `snapshot` with `method`: the aims `SequenceAims.resolve` gives the measured frames,
    /// `PrintAim()` for those that failed, and the record and revision of that.
    public static func decide(_ snapshot: Snapshot, method: SequenceAims.Method = method,
                              parameters: SequenceAims.Parameters? = nil) -> Decision {
        let parameters = parameters ?? Self.parameters(for: method)
        let input = snapshot.input
        let resolved = SequenceAims.resolve(input, method: method, parameters: parameters)
        var aims: [URL: PrintAim] = [:], failed: Set<URL> = []
        var members: [Record.Member] = []
        for frame in input.frames {
            let analysis = snapshot.failed.contains(frame.url) ? nil : input.analyses[frame.url]
            // Every method aims every measured frame; its own aim stands in should one not.
            let aim = analysis.map { resolved.aims[frame.url] ?? ownAim($0) } ?? PrintAim()
            aims[frame.url] = aim
            if analysis == nil { failed.insert(frame.url) }
            let identity = snapshot.identities[frame.url] ?? Identity(frame, stamp: nil)
            members.append(Record.Member(identity, analysisVersion: analysis?.version,
                                         initial: analysis.map(AutoPrint.levelStops), aim: aim,
                                         status: analysis == nil ? .failed : .measured))
        }
        let controls = readsStock(method) ? Record.Controls(stockID: input.stock.id, stockDigest: snapshot.stockDigest,
                                                            roll: input.controls,
                                                            frames: ownControls(input.frames, input.frameControls, method: method),
                                                            frameStockDigests: method == .detail
                                                                ? names(input.frames, snapshot.frameStockDigests) : nil) : nil
        let record = Record(method: method, parameters: digest(of: parameters),
                            revision: revision(of: snapshot, method: method, parameters: parameters),
                            controls: controls, frames: members)
        return Decision(aims: aims, failed: failed, record: record)
    }

    /// The decision `record` keeps, for `frames` as `identities` say their raws are now; `nil` unless
    /// it is one for them: decided by this version and method, of the same frames or an ordered subset
    /// (`Identity.matches`), from measurements of the current version, and with the same parameters,
    /// stock and controls where the method reads them. Its revision and aims are the kept ones,
    /// whatever measuring them again would give. A measurement of another version is made again, so
    /// its roll is printed again (`ExposureAnalysis.currentVersion`), and so is its decision. Culling
    /// preserves the original revision and surviving aims; the returned record keeps only surviving
    /// members, so saving it makes a later addition require another resolution.
    public static func restored(_ record: Record, frames: [Frame], identities: [URL: Identity],
                                stockDigest: String?, controls: RollControls, frameControls: [URL: FrameControls],
                                frameStockDigests: [URL: String] = [:],
                                method: SequenceAims.Method = method, parameters: SequenceAims.Parameters? = nil) -> Decision? {
        let parameters = parameters ?? Self.parameters(for: method)
        guard record.decisionVersion == version, record.method == method,
              !readsParameters(method) || record.parameters == digest(of: parameters),
              record.frames.count >= frames.count,
              Set(record.frames.map(\.fileName)).count == record.frames.count else { return nil }
        var keptRecord = record
        if readsStock(method) {
            let names = Set(frames.map { $0.url.lastPathComponent })
            guard let kept = record.controls, kept.stockDigest == stockDigest, kept.roll == controls,
                  kept.frames.filter({ names.contains($0.key) }) == ownControls(frames, frameControls, method: method),
                  method != .detail || kept.frameStockDigests?.filter({ names.contains($0.key) })
                    == Self.names(frames, frameStockDigests) else { return nil }
            keptRecord.controls?.frames = kept.frames.filter { names.contains($0.key) }
            keptRecord.controls?.frameStockDigests = kept.frameStockDigests?.filter { names.contains($0.key) }
        }
        var aims: [URL: PrintAim] = [:], failed: Set<URL> = []
        var members = record.frames.makeIterator(), retained: [Record.Member] = []
        for frame in frames {
            var member = members.next()
            while let next = member, next.fileName != frame.url.lastPathComponent { member = members.next() }
            guard let member, let now = identities[frame.url], member.identity.matches(now),
                  member.status == .failed || member.analysisVersion == ExposureAnalysis.currentVersion else { return nil }
            retained.append(member)
            aims[frame.url] = member.aim
            if member.status == .failed { failed.insert(frame.url) }
        }
        keptRecord.frames = retained
        return Decision(aims: aims, failed: failed, record: keptRecord)
    }

    /// The fingerprint of what `snapshot` is resolved from by `method`: this version, the method, each
    /// frame in order by its raw (`Identity`) and the SHA-256 of its encoded measurement or its
    /// failure, and only where the method reads them its parameters' digest, each frame's descriptor,
    /// and the stock's digest and the controls. A SHA-256, in hex.
    public static func revision(of snapshot: Snapshot, method: SequenceAims.Method,
                                parameters: SequenceAims.Parameters) -> String {
        let input = snapshot.input
        var lines = ["camera.argent.auto-decision \(version)", "method \(method.rawValue)"]
        if readsParameters(method) { lines[1] += " parameters \(digest(of: parameters))" }
        let stock = readsStock(method), descriptors = readsDescriptors(method)
        if stock { lines.append("stock \(snapshot.stockDigest) roll \(jsonText(input.controls))") }
        if method == .detail { lines.append("descriptor-version \(SequenceDescriptor.version)") }
        let own = ownControls(input.frames, input.frameControls, method: method)
        for frame in input.frames {
            let identity = snapshot.identities[frame.url] ?? Identity(frame, stamp: nil)
            var line = "frame \(identity.fingerprint)"
            if !snapshot.failed.contains(frame.url), let analysis = input.analyses[frame.url] {
                line += " analysis \(sha256(jsonData(analysis)))"
                if descriptors { line += " descriptor \(input.descriptors[frame.url].map { digest(of: $0, readsNoise: method == .detail) } ?? "none")" }
            } else {
                line += " failed"
            }
            if stock, let controls = own[identity.fileName] { line += " own \(jsonText(controls))" }
            if method == .detail, let digest = snapshot.frameStockDigests[frame.url] { line += " stock \(digest)" }
            lines.append(line)
        }
        return sha256(Data(lines.joined(separator: "\n").utf8))
    }

    /// The SHA-256 of `parameters` encoded with sorted keys, which a kept decision names.
    public static func digest(of parameters: SequenceAims.Parameters) -> String { sha256(jsonData(parameters)) }

    private static func digest(of descriptor: SequenceDescriptor, readsNoise: Bool) -> String {
        var hash = SHA256()
        [descriptor.width, descriptor.height].withUnsafeBufferPointer { hash.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        for values in [descriptor.rgb, descriptor.unclipped, descriptor.detail] {
            values.withUnsafeBufferPointer { hash.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        }
        if readsNoise, let noise = descriptor.noise {
            [noise.read.x, noise.read.y, noise.read.z, noise.shot.x, noise.shot.y, noise.shot.z].withUnsafeBufferPointer {
                hash.update(bufferPointer: UnsafeRawBufferPointer($0))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Each frame's own controls, by file name, where it has any.
    public static func ownControls(_ frames: [Frame], _ own: [URL: FrameControls],
                                   method: SequenceAims.Method = method) -> [String: FrameControls] {
        names(frames, own.compactMapValues { controls in
            let used = method == .detail ? FrameControls(ratedAt: controls.ratedAt, labBalance: controls.labBalance,
                                                         monochromeFilter: controls.monochromeFilter, paperGrade: controls.paperGrade) : controls
            return used.isEmpty ? nil : used
        })
    }

    public static func names<Value>(_ frames: [Frame], _ values: [URL: Value]) -> [String: Value] {
        Dictionary(frames.compactMap { frame in values[frame.url].map { (frame.url.lastPathComponent, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    private static func jsonData<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data("unencodable".utf8)
    }

    private static func jsonText<T: Encodable>(_ value: T) -> String { String(decoding: jsonData(value), as: UTF8.self) }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Records

    /// A settled decision as kept on disk (`AutoDecisionStore`): small, by file name, enough to tell
    /// on reopen whether it is still the roll's and to print it again without resolving it.
    public struct Record: Sendable, Equatable, Codable {
        public static let formatName = "camera.argent.auto-decisions"
        /// The file's layout; a later one is preserved, never read or written over.
        public static let currentVersion = 1

        public var format = Record.formatName
        public var version = Record.currentVersion
        /// `AutoDecisions.version` when it was decided.
        public var decisionVersion = AutoDecisions.version
        public var method: SequenceAims.Method
        /// The SHA-256 of the method's parameters (`AutoDecisions.digest(of:)`), which a kept
        /// decision must match on reopen only for a method that reads them (`readsParameters`).
        public var parameters: String
        public var revision: String
        /// The stock and controls the aims were resolved through, for a method that reads them;
        /// absent otherwise, since a change of them leaves such a decision standing.
        public var controls: Controls?
        /// Remaining members in capture order. Culling projects this list without changing the
        /// revision that originally resolved their aims.
        public var frames: [Member]

        public init(method: SequenceAims.Method, parameters: String, revision: String, controls: Controls? = nil,
                    frames: [Member]) {
            self.method = method
            self.parameters = parameters
            self.revision = revision
            self.controls = controls
            self.frames = frames
        }

        /// One frame of a kept decision.
        public struct Member: Sendable, Equatable, Codable {
            public enum Status: String, Sendable, Codable {
                case measured
                /// Its raw could not be decoded or its header read: it printed at `PrintAim()`.
                case failed
            }

            public var fileName: String
            public var byteCount: Int
            public var captureDate: Date?
            public var sha256: String?
            public var stamp: SourceStamp?
            /// The measurement's version (`ExposureAnalysis.version`); absent for a failed frame.
            public var analysisVersion: String?
            /// Its own level before the roll was resolved (`AutoPrint.levelStops`); absent when failed.
            public var initial: Float?
            /// The aim it prints at.
            public var aim: PrintAim
            public var status: Status

            public init(_ identity: Identity, analysisVersion: String?, initial: Float?, aim: PrintAim, status: Status) {
                fileName = identity.fileName
                byteCount = identity.byteCount
                captureDate = identity.captureDate
                sha256 = identity.sha256
                stamp = identity.stamp
                self.analysisVersion = analysisVersion
                self.initial = initial
                self.aim = aim
                self.status = status
            }

            public var identity: Identity {
                Identity(fileName: fileName, byteCount: byteCount, captureDate: captureDate, sha256: sha256, stamp: stamp)
            }
        }

        /// The stock and controls a stock-reading method resolved through.
        public struct Controls: Sendable, Equatable, Codable {
            public var stockID: String
            public var stockDigest: String
            public var roll: RollControls
            /// Each frame's own Rated at or Lab balance, by file name, where it has any.
            public var frames: [String: FrameControls]
            public var frameStockDigests: [String: String]?

            public init(stockID: String, stockDigest: String, roll: RollControls, frames: [String: FrameControls],
                        frameStockDigests: [String: String]? = nil) {
                self.stockID = stockID
                self.stockDigest = stockDigest
                self.roll = roll
                self.frames = frames
                self.frameStockDigests = frameStockDigests
            }
        }
    }
}

/// Where each roll's settled Auto decision is kept (`AutoDecisions.Record`): one JSON file a roll in
/// the recipe library, `AutoDecisions/v1/<SHA-256 of the roll folder's canonical path>.json`, written
/// whole and atomically with sorted keys. Not in the frames' recipes: an untouched roll has none, and
/// a decision across many files could not be written at once (docs/research/auto/
/// sequence-consistency.md, stage 4). A file this build cannot read, or one a later build wrote, is
/// left as it is: read as none, and never written over.
public struct AutoDecisionStore: Sendable {
    /// What is kept for a roll.
    public enum Stored: Sendable, Equatable {
        case none
        case record(AutoDecisions.Record)
        /// Not a decision this build can read: another format, damaged, or inaccessible.
        case unreadable
        /// A decision in a later layout than `AutoDecisions.Record.currentVersion`.
        case future(Int)
    }

    /// The recipe library the decisions are kept in; tests give their own.
    public let library: URL

    public init(library: URL = RecipeStore.defaultLibrary) {
        self.library = library
    }

    public var folder: URL { library.appendingPathComponent("AutoDecisions/v1", isDirectory: true) }

    /// The file kept for the roll at `roll`, a folder or a card.
    public func file(for roll: URL) -> URL {
        let name = SHA256.hash(data: Data(roll.canonicalPath.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name).appendingPathExtension("json")
    }

    public func stored(for roll: URL) -> Stored {
        let data: Data
        do {
            data = try Data(contentsOf: file(for: roll))
        } catch CocoaError.fileReadNoSuchFile {
            return .none
        } catch {
            return .unreadable
        }
        struct Header: Decodable { var format: String; var version: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.format == AutoDecisions.Record.formatName
        else { return .unreadable }
        guard header.version <= AutoDecisions.Record.currentVersion else { return .future(header.version) }
        guard let record = try? JSONDecoder().decode(AutoDecisions.Record.self, from: data), record.version >= 1,
              record.revision.count == 64, record.revision.allSatisfy(\.isHexDigit)
        else { return .unreadable }
        return .record(record)
    }

    /// The decision kept for `roll`, when there is one this build can read.
    public func record(for roll: URL) -> AutoDecisions.Record? {
        if case .record(let record) = stored(for: roll) { return record }
        return nil
    }

    /// Keeps `record` as `roll`'s, in place of the one there, unless the file there is one this build
    /// cannot read or a later build wrote, which stays: `false` then.
    @discardableResult
    public func save(_ record: AutoDecisions.Record, for roll: URL) throws -> Bool {
        switch stored(for: roll) {
        case .unreadable, .future: return false
        case .none, .record: break
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: file(for: roll), options: .atomic)
        return true
    }
}
