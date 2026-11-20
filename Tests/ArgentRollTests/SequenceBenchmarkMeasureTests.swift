import ArgentCore
import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import ArgentRoll

/// The frozen benchmark of sequence-aware print levels (docs/research/auto/sequence-consistency.md,
/// sections 2 and 3, with the amendments made before any candidate was scored): any configuration
/// of `SequenceAims` scored against Auto as shipped, roll smoothing (`SequenceAims.Method.control`),
/// on the protocol's development or test split, gate by gate. It holds no candidate logic: every
/// level is `SequenceAims.resolve`'s, and a pair counts as linked only when that result's `links`
/// join its two frames. Runs only with ARGENT_MEASURE=1 and a file of configurations:
///
///     swift build -c release --build-tests -Xswiftc -enable-testing
///     ARGENT_MEASURE=1 ARGENT_CUBEPP_GRID=cells ARGENT_CUBEPP_COHORT=docs/research/auto/gate-protocol/cubepp-cohort-2234.txt \
///       ARGENT_SEQUENCE_CONFIGS=<configs.json> ARGENT_SEQUENCE_OUT=<evidence>/benchmark/runs/<run> \
///       swift test -c release -Xswiftc -enable-testing --skip-build --filter SequenceBenchmarkMeasureTests
///
/// The configurations are `[{"name", "method": "control" | "smoothing" | "render", "parameters": {…}}]`,
/// the parameters `SequenceAims.Parameters`' keys, any left out at their defaults and any other
/// refused; control is always scored as well, as the comparison. ARGENT_SEQUENCE_PROTOCOL names the
/// protocol (benchmark/protocol.json by default), refused unless it is the frozen one.
/// ARGENT_SEQUENCE_SPLIT is dev, the default, or test, which is refused unless ARGENT_SEQUENCE_FROZEN
/// is the configurations file's SHA-256 and the file lies under benchmark/frozen (`split`), and
/// unless the file holds exactly the frozen candidates (`frozenCandidates`). A development run goes
/// to ARGENT_SEQUENCE_OUT, a new folder under benchmark/runs; the test split is scored once, into
/// benchmark/runs/test-<the frozen file's SHA-256, 12 digits>, refused when a run of that name exists
/// (`runFolder`). A run writes summary.md, results.json and pairs.csv. Those paths are under the
/// evidence root, ~/Documents/ArgentResearch/auto-sequence-20261022.noindex.
///
/// For a tuning sweep on the development split (`Options`, refused on the test split, which scores
/// everything): ARGENT_SEQUENCE_STOCKS names the stocks scored, Portra 400 among them (all six by
/// default); ARGENT_SEQUENCE_G6 and ARGENT_SEQUENCE_G7 are all (the default), none or the
/// configurations whose leave-one-out and whose timings are computed; ARGENT_SEQUENCE_AGREEMENT is
/// all (the default), none or the configurations whose links are checked against full renders
/// (`Agreement`). The matcher's pairs are kept across configurations (`Evidence`), so each is
/// matched once for each setting of the evidence, and checked against `SequenceEvidence.links`
/// once for each; each configuration's wall time is reported by part.
///
/// Each session is resolved as a roll of its own: links reach at most `maximumGap` seconds and roll
/// smoothing's clusters two minutes, while sessions lie more than 30 minutes apart, so that is the
/// roll's own result, and leaving a frame out touches one session. Cube++ (the 2,234-frame cohort,
/// the cache's cell grids) is scored as shot, the primary scenario, and with one exposure per scene
/// (`SeriesMeasureTests.Scenario`); its frames are measured as `SeriesMeasureTests.analysis` measures
/// them, with the cache's Vision boxes metered over the grid. The a7 IV frames are decoded as the
/// sheet decodes them (`RollDiagnosticsMeasureTests.measure`), kept under the evidence root's
/// benchmark/cache so a sweep decodes each once, and measured by `ExposureAnalyzer.measure`. The data
/// is loaded once and the configurations scored in turn; the a7 IV renders, one a frame, stock and
/// level, are the only GPU work. Nothing of the other split's frames is measured: its primary pairs
/// are only counted.
@Suite(.serialized) struct SequenceBenchmarkMeasureTests {
    typealias D = RollDiagnosticsMeasureTests
    typealias G = GateMeasureTests
    typealias L = LabBalanceMeasureTests
    typealias M = FrameViewMeasureTests
    typealias S = SeriesMeasureTests

    // MARK: The frozen protocol

    /// The evidence root of the pre-registration, outside Git.
    static let evidence = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/ArgentResearch/auto-sequence-20261022.noindex")
    /// benchmark/protocol.json as frozen on 2026-10-22 (section 2, "Files").
    static let protocolSHA256 = "f17bec3859f959bf7929bf22c3188b1638aab67ccafe9a25b1e6d3f90dcba17a"
    /// The session bootstrap's resamples and seed (section 3, G1).
    static let resampleCount = 2_000
    static let seed: UInt64 = 20_261_022
    /// A session chains one body's or folder's captures at most this far apart (section 2, "Split").
    static let sessionGap: TimeInterval = 30 * 60
    /// The two raw.pixls.us folders are one shoot, the event the protocol's units name
    /// (benchmark/a7iv/README.md, "Order and sessions").
    static let events = ["pixls-samples-s01": "pixls-2023-10-19", "pixls-ilce-7m4-samples-s01": "pixls-2023-10-19"]
    /// The primary stock, Portra 400, which the gates read unless they say otherwise.
    static let primaryStock = "kodak-portra-400"
    /// What every frame develops with: Auto at box speed, as the region lightness is defined.
    static let controls = RollControls(labBalance: .auto)

    /// The gates' thresholds and the benchmark's fixed constructions (section 3, "Gates").
    enum Threshold {
        /// G1: p90 at most this share of control's, and the target p90 in L*.
        static let ratio = 0.70
        static let target = 3.0
        /// G2: the mean signed region change against control, either way, in L*.
        static let meanChange = 1.5
        /// G3: the largest share of changed-light pairs linked, the lowest median change of their
        /// region difference against control in L*, and the a7 IV boundaries counted.
        static let falseLinks = 0.05
        static let flattening = -0.5
        static let boundaryConfidence = 0.6
        /// Cube++'s changed-light pairs: a frame's next and next-but-one within this many seconds.
        static let changedSeconds: TimeInterval = 600
        /// G4: the worst jump's allowance over control's, in L*; fixed-content frames this many
        /// seconds apart; boxes moved this share of their size and scaled by this.
        static let faceWorst = 0.5
        static let fixedContentSeconds: TimeInterval = 2
        static let faceMove: Float = 0.05
        static let faceScale: Float = 1.15
        /// G5: the largest mean and single-frame rise, in points, of the share of matte points whose
        /// print leaves the Print LUT's domain (amendment 1, `Printing.lost`).
        static let paperMean = 0.5
        static let paperFrame = 5.0
        /// The thresholds G5 first named, paper white and black in L*, reported beside the gate and
        /// not gated: paper black prints at L* 3.8 to 6.3, which `paperBlack` never reaches
        /// (amendment 1); with black within `stockBlackMargin` L* of the stock's own paper black too.
        static let paperWhite = 99.0
        static let paperBlack = 1.0
        static let stockBlackMargin = 0.5
        /// Cube++'s matte cells: at least this share of their pixels unclipped.
        static let matteCell: Float = 0.99
        /// a7 IV's matte points: every this many pixels of the decode each way.
        static let matteStride = 2
        /// G6: the p95 movement, and the movements listed, in stops.
        static let stability = 0.1
        static let listed = 0.25
        /// G7: per frame in a release build, for a roll of `syntheticFrames` chained `syntheticGap` apart.
        static let milliseconds = 40.0
        static let megabytes = 100.0
        static let syntheticFrames = 340
        static let syntheticGap: TimeInterval = 31 * 60
        static let timedRuns = 5
        /// The longest link a configuration may ask for: anything longer could cross a session.
        static let maximumGap = 1_800.0
    }

    // MARK: The split's guard

    enum Split: String, Codable, CaseIterable {
        case dev, test
    }

    /// Why a run is refused.
    struct Refusal: Error, CustomStringConvertible {
        var description: String

        init(_ description: String) { self.description = description }
    }

    /// The SHA-256 of `data`, in lowercase hex.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The split a run may score. The development split is the default. The test split is scored
    /// once, for configurations frozen first (section 3, "Freeze"): only with `frozen` equal to the
    /// SHA-256 of exactly the bytes the run reads as its configurations (`configs`), and with their
    /// file, its symbolic links resolved (`configsPath`), lying under `frozenFolder`. Any other value,
    /// a different case or an empty one too, is refused rather than taken for the development split.
    static func split(_ requested: String?, configs: Data, configsPath: String, frozen: String?,
                      frozenFolder: String) throws -> Split {
        guard let requested else { return .dev }
        switch requested {
        case Split.dev.rawValue:
            return .dev
        case Split.test.rawValue:
            guard let frozen, !frozen.isEmpty else {
                throw Refusal("the test split needs ARGENT_SEQUENCE_FROZEN, the frozen configurations' SHA-256")
            }
            let digest = sha256(configs)
            guard frozen.lowercased() == digest else {
                throw Refusal("ARGENT_SEQUENCE_FROZEN \(frozen) is not the configurations' SHA-256 \(digest)")
            }
            let file = URL(fileURLWithPath: configsPath).standardizedFileURL.path
            let folder = URL(fileURLWithPath: frozenFolder).standardizedFileURL.path
            guard file.hasPrefix(folder + "/") else {
                throw Refusal("the test split scores only configurations frozen under \(folder), not \(file)")
            }
            return .test
        default:
            throw Refusal("ARGENT_SEQUENCE_SPLIT is dev or test, not \"\(requested)\"")
        }
    }

    /// The configurations the test split scores (amendment 6): control, which every run scores
    /// first, "A" (smoothing) at `SequenceAims.Parameters.frozenSmoothing`, "B" (render) at
    /// `frozenRender`, and optionally "R" (render), `frozenRender` with faces weighed by their
    /// reliability; nothing else, so the constants scored are the ones frozen in the code.
    static func frozenCandidates(_ configurations: [Configuration]) throws {
        var ablation = SequenceAims.Parameters.frozenRender
        ablation.faceReliability = true
        let frozen = ["A": Configuration(name: "A", method: .smoothing, parameters: .frozenSmoothing),
                      "B": Configuration(name: "B", method: .render, parameters: .frozenRender),
                      "R": Configuration(name: "R", method: .render, parameters: ablation)]
        guard configurations.first == .control else { throw Refusal("the test split scores control first") }
        let candidates = configurations.dropFirst(), names = candidates.map(\.name)
        guard Set(names).count == names.count, Set(names) == ["A", "B"] || Set(names) == ["A", "B", "R"] else {
            throw Refusal("the test split scores control, A, B and optionally R, not \(configurations.map(\.name))")
        }
        for candidate in candidates where candidate != frozen[candidate.name] {
            throw Refusal("\(candidate.name) is not \(frozen[candidate.name]!.method.rawValue) at the constants frozen in SequenceAims.Parameters")
        }
    }

    /// The folder a run writes (amendment 6), `runs` being benchmark/runs: on the development split
    /// `requested`, ARGENT_SEQUENCE_OUT, which may not take the test split's names; on the test split
    /// test-<the first 12 hex digits of the frozen configurations' SHA-256>, refused when `existing`,
    /// the names in `runs`, holds that name or one that begins with it, so each frozen file is
    /// scored once. ARGENT_SEQUENCE_OUT may name only that folder there.
    static func runFolder(_ split: Split, requested: String?, configsSHA256: String, runs: String, existing: [String]) throws -> String {
        let runs = URL(fileURLWithPath: runs).standardizedFileURL.path
        switch split {
        case .dev:
            guard let requested else { throw Refusal("ARGENT_SEQUENCE_OUT names the run's folder") }
            let path = URL(fileURLWithPath: requested).standardizedFileURL.path
            let first = path.hasPrefix(runs + "/") ? path.dropFirst(runs.count + 1).split(separator: "/").first.map(String.init) ?? "" : ""
            // In any case: the test split counts any case as its run, and APFS takes them for one name.
            guard !first.lowercased().hasPrefix("test-") else { throw Refusal("\(runs)/test-… holds the test split's runs, not \(path)") }
            return path
        case .test:
            let name = "test-" + configsSHA256.lowercased().prefix(12)
            // Once for the study, not once per file: a frozen file written again with other bytes
            // would otherwise score the candidates a second time.
            if let run = existing.sorted().first(where: { $0.lowercased().hasPrefix("test-") }) {
                throw Refusal("the test split is scored once: \(runs)/\(run) holds its run")
            }
            let path = runs + "/" + name
            if let requested, URL(fileURLWithPath: requested).standardizedFileURL.path != path {
                throw Refusal("the test split's run goes to \(path), not \(requested)")
            }
            return path
        }
    }

    /// What a development run may leave out or add for a tuning sweep, from the environment. The
    /// test split takes the defaults, every stock and every configuration's G6 and G7, and no
    /// agreement check, which renders the test split's links; anything else there is refused.
    struct Options: Equatable {
        /// The stocks scored, Portra 400 first and the others in the library's order.
        var stocks: [String]
        /// The configurations whose forced leave-one-out (G6) and whose timings (G7) are computed.
        var stability: Set<String>
        var cost: Set<String>
        /// The configurations whose links' CPU lightness is compared with full renders (`Agreement`).
        var agreement: Set<String>
    }

    /// ARGENT_SEQUENCE_STOCKS, a comma-separated subset of `stocks` (the library's ids, Portra 400
    /// first) holding Portra 400; ARGENT_SEQUENCE_G6, ARGENT_SEQUENCE_G7 and
    /// ARGENT_SEQUENCE_AGREEMENT, all, none or comma-separated names of `configurations`. Unset,
    /// each is all.
    static func options(_ environment: [String: String], split: Split, configurations: [String], stocks: [String]) throws -> Options {
        func list(_ value: String) -> [String] { value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        func names(_ key: String) throws -> Set<String> {
            guard let value = environment[key], value != "all" else { return Set(configurations) }
            if value == "none" { return [] }
            let named = list(value)
            guard !named.isEmpty, Set(named).isSubset(of: configurations) else {
                throw Refusal("\(key) is all, none or names among \(configurations), not \"\(value)\"")
            }
            return Set(named)
        }
        var chosen = stocks
        if let value = environment["ARGENT_SEQUENCE_STOCKS"] {
            let named = Set(list(value))
            guard named.isSubset(of: stocks), named.contains(primaryStock) else {
                throw Refusal("ARGENT_SEQUENCE_STOCKS names stocks among \(stocks), \(primaryStock) one of them, not \"\(value)\"")
            }
            chosen = stocks.filter { named.contains($0) }
        }
        let options = Options(stocks: chosen, stability: try names("ARGENT_SEQUENCE_G6"), cost: try names("ARGENT_SEQUENCE_G7"),
                              agreement: split == .test ? [] : try names("ARGENT_SEQUENCE_AGREEMENT"))
        if split == .test {
            guard options.stocks == stocks else { throw Refusal("the test split scores all six stocks") }
            guard options.stability == Set(configurations), options.cost == Set(configurations) else {
                throw Refusal("the test split computes G6 and G7 for every configuration")
            }
            guard environment["ARGENT_SEQUENCE_AGREEMENT"] == nil else {
                throw Refusal("the agreement with full renders is a development diagnostic")
            }
        }
        return options
    }

    // MARK: Inputs

    /// benchmark/protocol.json, the parts the scorer reads.
    struct ProtocolFile: Decodable {
        var version: Int
        /// Each unit, a session or an event, and its split.
        var units: [String: String]
        var cubepp: Cubepp
        var a7iv: A7iv

        struct Cubepp: Decodable {
            var pairs: [CubePair]
        }

        struct CubePair: Decodable {
            var id: String
            var a: String
            var b: String
            var session: String
            /// same, overlap, different or unclear.
            var subject: String?
            var scene: String?
            var split: String?
        }

        struct A7iv: Decodable {
            var pairs: [A7Pair]
            var boundaries: [Boundary]
            var frames: [A7Frame]
            var folders: [String: Folder]
        }

        struct A7Pair: Decodable {
            var id: String
            var a: String
            var b: String
            var folderA: String
            var folderB: String
            /// x, y, width and height as fractions of the upright frame from the top left.
            var boxA: [Float]
            var boxB: [Float]
            var samePhysicalSurface: Bool
            var sceneType: String
            var split: String?
        }

        struct Boundary: Decodable {
            var folder: String
            var a: String
            var b: String
            var confidence: Double
            var split: String?
        }

        struct A7Frame: Decodable {
            var folder: String
            var file: String
            var session: String
        }

        struct Folder: Decodable {
            var path: String
        }
    }

    /// One configuration scored: a method and its constants.
    struct Configuration: Codable, Equatable {
        var name: String
        var method: SequenceAims.Method
        var parameters: SequenceAims.Parameters

        init(name: String, method: SequenceAims.Method, parameters: SequenceAims.Parameters = .init()) {
            self.name = name
            self.method = method
            self.parameters = parameters
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            method = try c.decode(SequenceAims.Method.self, forKey: .method)
            parameters = try c.decodeIfPresent(SequenceAims.Parameters.self, forKey: .parameters) ?? .init()
        }

        /// Auto as shipped, the comparison every run scores first.
        static let control = Configuration(name: "control", method: .control)
    }

    /// The configurations in `data`, control first. A key `SequenceAims.Parameters` does not have is
    /// refused rather than left at its default, and so is a link long enough to cross a session.
    static func configurations(_ data: Data) throws -> [Configuration] {
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SequenceAims.Parameters()))
        let known = Set(try #require(defaults as? [String: Any]).keys)
        let entries = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                                   "the configurations are a JSON array of objects")
        for entry in entries {
            let name = entry["name"] as? String ?? "?"
            try #require(Set(entry.keys).isSubset(of: ["name", "method", "parameters"]), "\(name): unknown keys \(entry.keys.sorted())")
            let keys = Set((entry["parameters"] as? [String: Any] ?? [:]).keys)
            try #require(keys.isSubset(of: known), "\(name): unknown parameters \(keys.subtracting(known).sorted())")
        }
        var all = [Configuration.control]
        for configuration in try JSONDecoder().decode([Configuration].self, from: data) where configuration != .control {
            try #require(!all.contains { $0.name == configuration.name }, "configuration names are unique: \(configuration.name)")
            all.append(configuration)
        }
        for configuration in all {
            try #require(configuration.parameters.maximumGap <= Threshold.maximumGap,
                         "\(configuration.name): maximumGap \(configuration.parameters.maximumGap) s could cross a session")
        }
        return all
    }

    /// ARGENT_SEQUENCE_OUT: a new or empty folder under the evidence root's benchmark/runs, which
    /// lies outside the repository; every run is kept.
    static func outputFolder(_ path: String?) throws -> URL {
        let out = URL(fileURLWithPath: try #require(path, "ARGENT_SEQUENCE_OUT names the run's folder"))
        let runs = evidence.appendingPathComponent("benchmark/runs").canonicalPath + "/"
        let canonical = out.canonicalPath + "/"
        try #require(canonical.hasPrefix(runs) && canonical != runs, "write runs in a folder under \(runs)")
        try #require(!canonical.hasPrefix(M.root.canonicalPath + "/"), "write runs outside the repository")
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        try #require(existing.isEmpty, "\(out.path) already holds a run")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    // MARK: The benchmark's data

    /// Where a pair or frame comes from (section 3, G1's breakdown).
    enum Source: String, Codable, CaseIterable {
        case cubepp, owner, corpora
    }

    enum Scenario: String, Codable, CaseIterable {
        /// Every source as shot: the primary scenario.
        case asShot = "as shot"
        /// Cube++ with each run of frames re-exposed at its median EV (`SeriesMeasureTests.Scenario`).
        case oneExposure = "one exposure per scene"
    }

    /// One frame as the benchmark holds it.
    struct Item {
        var name: String
        var source: Source
        var frame: Frame
        var analysis: ExposureAnalysis
        var descriptor: SequenceDescriptor
        /// Cube++: the cube's gray, its two gray faces' mean light in the decode, as the scenario exposed it.
        var cube: SIMD3<Float>?
        /// Cube++: the descriptor cells the cube's mask touches (`maskedCells`), which G4 and G5 leave
        /// out (amendment 4).
        var masked: [Bool]?
        /// a7 IV: the decode's key in the benchmark's cache, and the evaluation boxes on this frame.
        var decode: String?
        var boxes: [[Float]] = []
        /// a7 IV: the analysis grid the descriptor was built from, which places its cells on the
        /// decode's pixels.
        var grid: GridSize?
        /// A frame with faces, as shot: its analysis with them dropped, and with each box moved and
        /// grown and metered again over the same grid (G4's fixed content).
        var withoutFaces: ExposureAnalysis?
        var movedFaces: ExposureAnalysis?
    }

    /// An analysis grid's cells and the decode they cover (`ExposureAnalyzer.Grid`): cell column `c`
    /// holds pixel columns `c · step` up to `step` more, within the frame, and rows likewise from
    /// the picture's bottom.
    struct GridSize: Equatable {
        var width: Int
        var height: Int
        var step: Int
        var frameWidth: Int
        var frameHeight: Int

        init(_ grid: ExposureAnalyzer.Grid) {
            (width, height, step, frameWidth, frameHeight) = (grid.width, grid.height, grid.step, grid.frameWidth, grid.frameHeight)
        }

        /// The pixels of cell `column`, `row`.
        func pixels(_ column: Int, _ row: Int) -> Int {
            max(0, min(step, frameWidth - column * step)) * max(0, min(step, frameHeight - row * step))
        }
    }

    /// One session of the split: a roll of its own, in capture order.
    struct Session {
        var unit: String
        var items: [Item]
    }

    /// A pair whose region lightness is scored, its frames indexed into one session.
    struct Pair {
        var id: String
        var source: Source
        var scene: String
        /// The pair's unit among the split's, for the bootstrap.
        var unit: Int
        var session: Int
        var a: Int
        var b: Int
        /// a7 IV: each frame's box, indexed into its item's.
        var boxes: (Int, Int)?
    }

    /// An a7 IV light-change boundary between two neighbouring frames, which may lie in two sessions.
    struct Boundary {
        var id: String
        var a: (session: Int, item: Int)
        var b: (session: Int, item: Int)
    }

    /// G4's fixed content: a frame, then its variant, then the frame again.
    struct FixedContent {
        var name: String
        var variant: String
        var source: Source
        var items: [Item]
    }

    /// The split's data, loaded once for every configuration.
    struct Benchmark {
        var split: Split
        /// The split's units, sorted, and the resamples of their indices.
        var units: [String]
        var draws: [[Int]]
        /// Every session of the scenario: as shot, Cube++'s and then the a7 IV's from `a7`; with one
        /// exposure per scene Cube++'s alone, at the same indices.
        var sessions: [Scenario: [Session]]
        var a7: Range<Int>
        /// P, and Cube++'s changed-light pairs, per scenario: Cube++'s alone with one exposure per scene.
        var primary: [Scenario: [Pair]]
        var changed: [Scenario: [Pair]]
        var boundaries: [Boundary]
        var fixedContent: [FixedContent]
        var counts: Counts
    }

    /// What the run holds, P on both splits counted.
    struct Counts: Codable {
        /// P on each split, by source and in all.
        var primary: [String: [String: Int]]
        /// Cube++ pairs labelled the same subject on each split, before the cube's same-light rule.
        var cubeppSameSubject: [String: Int]
        /// a7 IV pairs on each split whose boxes are the same kind of surface, not the same one.
        var a7ivOtherSurface: [String: Int]
        var units: Int
        var sessions: Int
        var frames: [String: Int]
        var changedLight: Int
        var boundaries: Int
        var faceFrames: Int
        var decoderRoute: String
    }

    // MARK: Cube++

    /// SeriesMeasureTests' label from the cube's light: the same within a third of a stop, 10 mired
    /// and 0.1 green; changed past two thirds, 20 mired or 0.2 green; `nil` between.
    static func sameLight(_ a: S.Shot, _ b: S.Shot) -> Bool? {
        let light = abs(a.absoluteGray - b.absoluteGray)
        let (rbA, gA) = AutoBalance.axes(a.light), (rbB, gB) = AutoBalance.axes(b.light)
        let redBlue = Double(abs(rbA - rbB) / AutoBalance.stopsPerMired), green = Double(abs(gA - gB))
        return light <= 1.0 / 3 && redBlue <= 10 && green <= 0.1 ? true : light > 2.0 / 3 || redBlue > 20 || green > 0.2 ? false : nil
    }

    /// `shot`'s grid as `SeriesMeasureTests.analysis` reads it, the masked cube left out, with its
    /// light scaled by `shift` stops.
    static func cubeGrid(_ shot: S.Shot, shift: Double) -> ExposureAnalyzer.Grid {
        var grid = shot.frame.analysisGrid
        let scale = Float(exp2(shift))
        for index in grid.light.indices {
            if grid.all[index] == .zero { grid.weight[index] = 0 }
            grid.light[index] *= scale
            grid.all[index] *= scale
        }
        return grid
    }

    /// The cells of `descriptor`, built from `grid`, that hold a grid cell with no light at all, the
    /// cube's mask (`cubeGrid`), each holding the grid cells `SequenceDescriptor.gridSpan` gives it.
    static func maskedCells(_ descriptor: SequenceDescriptor, grid: ExposureAnalyzer.Grid) -> [Bool] {
        var masked = [Bool](repeating: false, count: descriptor.width * descriptor.height)
        for v in 0..<descriptor.height {
            let rows = SequenceDescriptor.gridSpan(v, of: descriptor.height, over: grid.height)
            for u in 0..<descriptor.width {
                let columns = SequenceDescriptor.gridSpan(u, of: descriptor.width, over: grid.width)
                masked[v * descriptor.width + u] = rows.contains { row in columns.contains { grid.all[row * grid.width + $0] == .zero } }
            }
        }
        return masked
    }

    /// G4's fixed content for a frame with faces: its analysis with the faces dropped, and with each
    /// box moved by a twentieth of its size right and down and grown by 15 % about its middle, metered
    /// again over the same grid.
    static func fixedContent(_ analysis: ExposureAnalysis, grid: ExposureAnalyzer.Grid) -> (ExposureAnalysis, ExposureAnalysis)? {
        guard !analysis.faces.isEmpty else { return nil }
        var without = analysis
        without.faces = []
        var moved = analysis
        moved.faces = FaceMeter.meter(analysis.faces.map { face in
            let w = face.box[2] * Threshold.faceScale, h = face.box[3] * Threshold.faceScale
            let x = face.box[0] + face.box[2] * (0.5 + Threshold.faceMove), y = face.box[1] + face.box[3] * (0.5 + Threshold.faceMove)
            return FaceMeter.Detection(box: CGRect(x: CGFloat(x - w / 2), y: CGFloat(y - h / 2), width: CGFloat(w), height: CGFloat(h)),
                                       confidence: face.confidence)
        }, grid: grid)
        return (without, moved)
    }

    /// One Cube++ frame as shot, and with `shift` stops more light and the exposure time `time` that
    /// gives it: measured as `SeriesMeasureTests.analysis` measures it, with the cache's Vision boxes
    /// metered over the grid (their confidence unknown), and described from the same grid.
    static func cubeItems(_ shot: S.Shot, index: Int, shift: Double, time: Double) -> (Item, Item) {
        let boxes = (shot.frame.prepared.faces ?? []).filter { $0.count == 4 }
            .map { CGRect(x: CGFloat($0[0]), y: CGFloat($0[1]), width: CGFloat($0[2]), height: CGFloat($0[3])) }
        let faces = shot.frame.prepared.grayFaces.map { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : SIMD3<Double>() }
        let cube = SIMD3<Float>(faces.reduce(SIMD3<Double>(), +) / Double(faces.count))
        func item(_ shift: Double, exposureTime: Double, variants: Bool) -> Item {
            let grid = cubeGrid(shot, shift: shift)
            var analysis = ExposureAnalyzer.analyze(grid: grid)
            analysis.asShotTemperature = shot.frame.prepared.asShotTemperature
            analysis.faces = FaceMeter.meter(boxes, grid: grid)
            let frame = Frame(id: index, url: URL(fileURLWithPath: "/cubepp/\(shot.id).CR2"),
                              info: ARWFrameInfo(model: shot.camera, captureDate: shot.date, exposureTime: exposureTime,
                                                 fNumber: shot.fNumber, iso: shot.iso, flashFired: shot.flash))
            let descriptor = SequenceDescriptor(grid: grid)
            var item = Item(name: shot.id, source: .cubepp, frame: frame, analysis: analysis,
                            descriptor: descriptor, cube: cube * Float(exp2(shift)), masked: maskedCells(descriptor, grid: grid))
            if variants, let fixed = fixedContent(analysis, grid: grid) {
                item.withoutFaces = fixed.0
                item.movedFaces = fixed.1
            }
            return item
        }
        return (item(0, exposureTime: shot.exposureTime, variants: true), item(shift, exposureTime: time, variants: false))
    }

    struct CubeData {
        var sessions: [Scenario: [Session]]
        var primary: [Pair]
        var changed: [Pair]
        var counted: [Split: Int]
        var sameSubject: [Split: Int]
    }

    /// Cube++'s sessions in the split, as shot and with one exposure per scene, its primary and
    /// changed-light pairs there, and its primary pairs on both splits counted.
    static func cubepp(_ file: ProtocolFile, split: Split, unitIndex: [String: Int]) throws -> CubeData {
        let cameras = try S.loadShots()
        try #require(cameras.reduce(0) { $0 + $1.count } == L.expectedFrameCount, "Cube++ sequence cohort is incomplete")
        // Sessions as the protocol made them (benchmark/cubepp/sessions.csv): one body's frames chained
        // by gaps of at most 30 minutes, numbered over the bodies in order of their names.
        var sessionOf: [String: String] = [:], shotOf: [String: S.Shot] = [:], count = 0
        for shots in cameras {
            var previous: Date?
            for shot in shots {
                if previous.map({ shot.date.timeIntervalSince($0) > sessionGap }) ?? true { count += 1 }
                sessionOf[shot.id] = String(format: "S%03d", count)
                shotOf[shot.id] = shot
                previous = shot.date
            }
        }
        let units = Set(file.units.keys.filter { $0.range(of: #"^S\d{3}$"#, options: .regularExpression) != nil })
        try #require(Set(sessionOf.values) == units, "Cube++ sessions as the protocol's units")
        for pair in file.cubepp.pairs {
            try #require(sessionOf[pair.a] == pair.session && sessionOf[pair.b] == pair.session, "\(pair.id) lies in \(pair.session)")
        }

        // P counted on both splits: labelled the same subject, and the same light by the cube.
        var counted: [Split: Int] = [:], sameSubject: [Split: Int] = [:]
        for s in Split.allCases {
            let labelled = file.cubepp.pairs.filter { $0.split == s.rawValue && $0.subject == "same" }
            sameSubject[s] = labelled.count
            counted[s] = try labelled.filter { sameLight(try #require(shotOf[$0.a]), try #require(shotOf[$0.b])) == true }.count
        }

        // The split's frames, both scenarios: one exposure per scene as SeriesMeasureTests.Scenario
        // re-exposes a camera's frames, over its whole sequence.
        var sessions: [Scenario: [Session]] = [.asShot: [], .oneExposure: []]
        var place: [String: (session: Int, item: Int)] = [:]
        for shots in cameras {
            var shifts = [Double](repeating: 0, count: shots.count), times = shots.map(\.exposureTime)
            for scene in S.scenes(shots) {
                let ev = G.median(scene.map { shots[$0].ev })
                for index in scene {
                    shifts[index] = shots[index].ev - ev
                    times[index] = shots[index].fNumber * shots[index].fNumber / exp2(ev + log2(Double(shots[index].iso) / 100))
                }
            }
            var start = 0
            while start < shots.count {
                let unit = sessionOf[shots[start].id]!
                var end = start
                while end < shots.count, sessionOf[shots[end].id] == unit { end += 1 }
                defer { start = end }
                guard file.units[unit] == split.rawValue else { continue }
                var asShot: [Item] = [], oneExposure: [Item] = []
                for j in start..<end {
                    let (a, b) = autoreleasepool { cubeItems(shots[j], index: j - start, shift: shifts[j], time: times[j]) }
                    place[shots[j].id] = (sessions[.asShot]!.count, j - start)
                    asShot.append(a)
                    oneExposure.append(b)
                }
                sessions[.asShot]!.append(Session(unit: unit, items: asShot))
                sessions[.oneExposure]!.append(Session(unit: unit, items: oneExposure))
            }
        }

        var primary: [Pair] = []
        for pair in file.cubepp.pairs where pair.split == split.rawValue && pair.subject == "same" {
            guard sameLight(shotOf[pair.a]!, shotOf[pair.b]!) == true else { continue }
            let a = try #require(place[pair.a]), b = try #require(place[pair.b])
            primary.append(Pair(id: pair.id, source: .cubepp, scene: pair.scene ?? "unknown", unit: try #require(unitIndex[pair.session]),
                                session: a.session, a: a.item, b: b.item))
        }
        try #require(primary.count == counted[split], "every Cube++ pair of P is in the split's sessions")
        // Changed light: each frame with its next and next-but-one of the same body within 600 s whose
        // cube says the light changed (the protocol holds only pairs within half a stop).
        var changed: [Pair] = []
        for shots in cameras {
            for i in shots.indices {
                for j in [i + 1, i + 2] where j < shots.count && shots[j].date.timeIntervalSince(shots[i].date) <= Threshold.changedSeconds {
                    guard let a = place[shots[i].id], let b = place[shots[j].id], a.session == b.session,
                          sameLight(shots[i], shots[j]) == false else { continue }
                    changed.append(Pair(id: "\(shots[i].id)>\(shots[j].id)", source: .cubepp, scene: "",
                                        unit: unitIndex[sessionOf[shots[i].id]!]!, session: a.session, a: a.item, b: b.item))
                }
            }
        }
        return CubeData(sessions: sessions, primary: primary, changed: changed, counted: counted, sameSubject: sameSubject)
    }

    // MARK: a7 IV

    /// The a7 IV decodes, kept on disk, and their renders through each stock, each made once.
    final class Renders {
        /// A render: the frame, the stock, and the aim's level and cast bit for bit.
        struct Key: Hashable {
            var frame: String
            var stock: String
            var aim: SIMD4<UInt32>

            init(_ item: Item, _ stock: Stock, _ aim: PrintAim) {
                frame = item.name
                self.stock = stock.id
                self.aim = SIMD4(aim.level.bitPattern, aim.cast.x.bitPattern, aim.cast.y.bitPattern, aim.cast.z.bitPattern)
            }
        }

        /// What a render gives: each box's median L*; G5's matte points of the decode and those whose
        /// print leaves the Print LUT's domain at the render's aim (amendment 1, `Printing.lost`);
        /// every matte pixel and those printed at the L* thresholds G5 first named, with paper black
        /// as G5 named it and the stock's own (`atPaper`, not gated); and, when asked for, each
        /// analysis grid cell's mean L* (`cellLightness`).
        struct Measure {
            var boxes: [Double]
            var points: Int
            var lost: Int
            var paper: SIMD2<Double>
            var matte: Int
            var cells: [Float]?
        }

        let gpu: GPU
        let choices: DecoderChoices
        let decoder: ChosenDecoder
        let cache: LinearDiskCache
        let renderers: [String: FilmRenderer]
        let digests: [String: String]
        private(set) var measures: [Key: Measure] = [:]
        private(set) var decodes = 0
        private(set) var renders = 0
        private(set) var renderTime: Duration = .zero

        init(stocks: [Stock], cache folder: URL) throws {
            let gpu = try GPU(maxIdlePoolBytes: 256 << 20), choices = DecoderChoices()
            self.gpu = gpu
            self.choices = choices
            decoder = ChosenDecoder(gpu: gpu, choices: choices, contextPerDecode: true, inHouseAtOnce: FilmPreviews.inHouseDecodesAtOnce)
            cache = LinearDiskCache(folder: folder, limitBytes: 16 << 30)
            renderers = Dictionary(uniqueKeysWithValues: try stocks.map { ($0.id, try FilmRenderer(gpu: gpu, stock: $0)) })
            digests = Dictionary(uniqueKeysWithValues: stocks.map { ($0.id, $0.digest) })
        }

        /// The cache's key for `url`: its name, size and modification time, with what
        /// `LinearDiskCache` adds (the pins, the decoder, the sheet's size and the macOS build).
        func key(_ url: URL, name: String) throws -> String {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = try #require(values.fileSize), modified = try #require(values.contentModificationDate)
            let identity = "\(name)|\(size)|\(modified.timeIntervalSince1970)"
            return LinearDiskCache.key(sha256: identity, longSide: FilmPreviews.previewLongSide, decoderVersion: choices.decoderVersion(for: url))
        }

        /// `url`'s sheet decode: from the cache when it holds it, or decoded as the sheet decodes it
        /// (`RollDiagnosticsMeasureTests.measure`) and kept.
        func decode(_ url: URL, key: String) throws -> LinearFrame {
            if let cached = cache.load(key, pool: gpu.texturePool) { return cached }
            var options = DecodeOptions()
            options.maxLongSide = FilmPreviews.previewLongSide
            let decoded = try decoder.decode(url, options: options)
            decodes += 1
            cache.store(decoded, key: key)
            return decoded
        }

        func measure(_ item: Item, _ stock: Stock, _ aim: PrintAim) -> Measure? { measures[Key(item, stock, aim)] }

        /// Renders `item` at each aim as the app resolves its settings, grain off and halation and
        /// sharpening on, wherever that render is not measured yet, or with `cells` not measured
        /// cell by cell.
        func render(_ item: Item, aims: [(Stock, PrintAim)], cells: Bool = false) throws {
            let missing = aims.filter { measures[Key(item, $0.0, $0.1)].map { cells && $0.cells == nil } ?? true }
            guard !missing.isEmpty else { return }
            try autoreleasepool {
                let decoded = try decode(item.frame.url, key: try #require(item.decode))
                let source = ExposureAnalyzer.pixels(of: decoded.texture)
                let matte = SequenceBenchmarkMeasureTests.matte(source)
                let points = SequenceBenchmarkMeasureTests.mattePoints(source, matte: matte, width: decoded.width, height: decoded.height)
                var dyes: [Printing.Key: [SIMD3<Float>]] = [:]
                for (stock, aim) in missing {
                    let key = Key(item, stock, aim)
                    guard measures[key].map({ cells && $0.cells == nil }) ?? true else { continue }
                    let clock = ContinuousClock(), start = clock.now
                    let settings = try DevelopmentResolver.resolve(stock: stock, stockDigest: digests[stock.id]!,
                                                                   controls: SequenceBenchmarkMeasureTests.controls, aim: aim,
                                                                   manual: nil, grain: 0, grainSeed: item.frame.grainSeed, sharpen: true)
                    let rendered = try renderers[stock.id]!.render(decoded, settings: settings)
                    let pixels = ExposureAnalyzer.pixels(of: rendered.image.texture)
                    var grid: GridSize?
                    if cells { grid = try #require(item.grid, "\(item.name) has its analysis grid") as GridSize }
                    var measure = SequenceBenchmarkMeasureTests.measure(pixels, width: decoded.width, height: decoded.height, boxes: item.boxes,
                                                                        matte: matte, black: SequenceBenchmarkMeasureTests.paper(stock, white: false),
                                                                        grid: grid)
                    renders += 1
                    renderTime += clock.now - start
                    // G5: the matte points' dye amounts, once a stock and exposure, against the aim's offset.
                    let printing = Printing(stock, aim)
                    if dyes[printing.key] == nil { dyes[printing.key] = SequenceBenchmarkMeasureTests.parallelMap(points) { printing.dyes($0) } }
                    measure.points = points.count
                    measure.lost = dyes[printing.key]!.reduce(0) { $0 + (printing.lost(dyes: $1) ? 1 : 0) }
                    measures[key] = measure
                }
            }
        }

        /// Forgets the renders' cell-by-cell lightness, which only the agreement check reads.
        func dropCells() {
            measures = measures.mapValues { measure in
                var kept = measure
                kept.cells = nil
                return kept
            }
        }
    }

    /// How points of a frame print at an aim on a stock, on the CPU as `SequenceAims.Response`
    /// prints them: the rating's exposure, the negative's log encoding and its Negative LUT, then
    /// the print offset of the production settings for the aim (`controls`), which carries the
    /// level and the cast.
    struct Printing {
        /// What the dye amounts depend on: the stock and the exposure, bit for bit.
        struct Key: Hashable {
            var stock: String
            var gain: UInt32
        }

        var stock: Stock
        var gain: Float
        var offset: SIMD3<Float>

        init(_ stock: Stock, _ aim: PrintAim) {
            let settings = SequenceBenchmarkMeasureTests.controls.settings(for: stock, aim: aim)
            self.stock = stock
            gain = exp2(settings.exposureStops(boxSpeed: stock.boxSpeed))
            offset = settings.printOffset(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
        }

        var key: Key { Key(stock: stock.id, gain: gain.bitPattern) }

        /// The negative's dye amounts for `rgb`, linear working-space light.
        func dyes(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
            let encoding = stock.negative.encoding, exposed = GamutCompression.compress(rgb * gain)
            return stock.negative.sample(encoded: SIMD3(encoding.encode(exposed.x), encoding.encode(exposed.y), encoding.encode(exposed.z)))
        }

        /// Whether a point of these dye amounts loses its detail in the print (amendment 1): the
        /// dyes plus the print offset leave 0...1 in a channel, which the Print LUT clamps
        /// (`synthetic_print.py`'s `printClipped`).
        func lost(dyes: SIMD3<Float>) -> Bool {
            let input = dyes + offset
            return any(input .< 0) || any(input .> 1)
        }

        /// L* of a point of these dye amounts printed, as `RollDiagnosticsMeasureTests.printedLightness` prints it.
        func lightness(dyes: SIMD3<Float>) -> Double {
            let printed = stock.print.sample(encoded: (dyes + offset).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1)))
            return GateMeasureTests.lightness(Double((printed * Rec2020.luma).sum()))
        }
    }

    /// `transform` of each of `values`, in parallel, in order.
    static func parallelMap<T: Sendable, U: Sendable>(_ values: [T], chunk: Int = 4_096, _ transform: @Sendable (T) -> U) -> [U] {
        guard !values.isEmpty else { return [] }
        let chunks = (values.count + chunk - 1) / chunk
        var parts = [[U]](repeating: [], count: chunks)
        parts.withUnsafeMutableBufferPointer { buffer in
            let target = UncheckedBox(buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: chunks) { k in
                target.value[k] = values[(k * chunk)..<min(values.count, (k + 1) * chunk)].map(transform)
            }
        }
        return parts.flatMap { $0 }
    }

    /// `count` values of `body`, worked out in parallel, in order of their index.
    static func parallel<T: Sendable>(_ count: Int, _ body: @Sendable (Int) -> T) -> [T] {
        var out = [T?](repeating: nil, count: count)
        out.withUnsafeMutableBufferPointer { buffer in
            let target = UncheckedBox(buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: count) { target.value[$0] = body($0) }
        }
        return out.map { $0! }
    }

    /// Which pixels of a decode are matte: not clipped by `ExposureAnalyzer.grid`'s rule (under 97 % of
    /// the frame's brightest value once that could have clipped) and lighter than its floor, five
    /// stops under mid-gray.
    static func matte(_ pixels: [Float16]) -> [Bool] {
        func rgb(_ i: Int) -> SIMD3<Float> { SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])) }
        func finite(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }
        var brightest: Float = 0
        for i in stride(from: 0, to: pixels.count, by: 4) where finite(rgb(i)) { brightest = max(brightest, rgb(i).max()) }
        let clip = brightest >= 0.18 * exp2(ExposureAnalyzer.clipFloorStops) ? brightest * 0.97 : .infinity
        let floor = 0.18 * exp2(ExposureAnalyzer.floorStops)
        return stride(from: 0, to: pixels.count, by: 4).map { i in
            let v = rgb(i)
            return finite(v) && v.max() < clip && (v * Rec2020.luma).sum() > floor
        }
    }

    /// G5's matte points of an a7 IV decode (amendment 1): the matte pixels (`matte`) of every
    /// `Threshold.matteStride`th column and row, their light.
    static func mattePoints(_ pixels: [Float16], matte: [Bool], width: Int, height: Int) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for y in stride(from: 0, to: height, by: Threshold.matteStride) {
            for x in stride(from: 0, to: width, by: Threshold.matteStride) where matte[y * width + x] {
                let i = 4 * (y * width + x)
                points.append(SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])))
            }
        }
        return points
    }

    /// A Cube++ frame's G5 at `aim` on `stock`: its matte descriptor cells, nearly all pixels
    /// unclipped and none of the cube's mask (amendment 4), and the shares of them whose print
    /// leaves the Print LUT's domain (amendment 1) and printed at the L* thresholds G5 first named;
    /// `nil` with none.
    static func cellShares(_ item: Item, _ stock: Stock, _ aim: PrintAim) -> Shares? {
        let d = item.descriptor, printing = Printing(stock, aim), black = paper(stock, white: false)
        var lost = 0, printed = SIMD2<Double>(), n = 0
        for k in 0..<(d.width * d.height) where d.unclipped[k] >= Threshold.matteCell && !(item.masked?[k] ?? false) {
            let rgb = SIMD3(d.rgb[3 * k], d.rgb[3 * k + 1], d.rgb[3 * k + 2])
            guard rgb != .zero, rgb.x.isFinite, rgb.y.isFinite, rgb.z.isFinite else { continue }
            let dyes = printing.dyes(rgb)
            n += 1
            if printing.lost(dyes: dyes) { lost += 1 }
            printed += atPaper(printing.lightness(dyes: dyes), black: black)
        }
        return n > 0 ? Shares(lost: Double(lost) / Double(n), paper: printed / Double(n)) : nil
    }

    /// One frame's G5 at one aim: the share of its matte points whose print leaves the Print LUT's
    /// domain, which the gate reads, and the shares printed at the L* thresholds G5 first named,
    /// with paper black as named and the stock's own.
    struct Shares {
        var lost: Double
        var paper: SIMD2<Double>
    }

    /// The L* of `stock`'s paper black or white: its Print LUT at no dye or at full dye amounts.
    static func paper(_ stock: Stock, white: Bool) -> Double {
        G.lightness(Double((stock.print.sample(encoded: SIMD3(repeating: white ? 1 : 0)) * Rec2020.luma).sum()))
    }

    /// Whether a print's `lightness` is at paper white or black: as G5 sets them, and with black the
    /// stock's own (`Threshold.stockBlackMargin`).
    static func atPaper(_ lightness: Double, black: Double) -> SIMD2<Double> {
        let white = lightness >= Threshold.paperWhite
        return SIMD2(white || lightness <= Threshold.paperBlack ? 1 : 0, white || lightness <= black + Threshold.stockBlackMargin ? 1 : 0)
    }

    /// `box`, fractions of the upright frame from the top left, shrunk by a tenth on each side, as
    /// pixel columns and rows from the picture's bottom.
    static func pixels(of box: [Float], width: Int, height: Int) -> (xs: Range<Int>, ys: Range<Int>) {
        func at(_ v: Float, _ n: Int) -> Int { min(max(Int((v * Float(n)).rounded()), 0), n) }
        let x0 = at(box[0] + box[2] / 10, width), x1 = at(box[0] + box[2] * 9 / 10, width)
        let y0 = at(1 - (box[1] + box[3] * 9 / 10), height), y1 = at(1 - (box[1] + box[3] / 10), height)
        return (x0..<max(x0, x1), y0..<max(y0, y1))
    }

    /// A render's measures: each box's median per-pixel L* (`GateMeasureTests.lightness` of Rec. 2020
    /// luminance), its matte pixels and those printed at paper white or black, `black` the stock's,
    /// and with `grid` each of its cells' mean L*. G5's points are counted by `Renders.render`.
    static func measure(_ pixels: [Float16], width: Int, height: Int, boxes: [[Float]], matte: [Bool], black: Double,
                        grid: GridSize?) -> Renders.Measure {
        var lightness = [Double](repeating: 0, count: width * height)
        for k in lightness.indices {
            let i = 4 * k
            lightness[k] = G.lightness(0.2627 * Double(pixels[i]) + 0.6780 * Double(pixels[i + 1]) + 0.0593 * Double(pixels[i + 2]))
        }
        let medians = boxes.map { box -> Double in
            let (xs, ys) = Self.pixels(of: box, width: width, height: height)
            return G.median(ys.flatMap { y in xs.map { lightness[y * width + $0] } })
        }
        var paper = SIMD2<Double>(), count = 0
        for k in lightness.indices where matte[k] {
            count += 1
            paper += atPaper(lightness[k], black: black)
        }
        return Renders.Measure(boxes: medians, points: 0, lost: 0, paper: paper, matte: count,
                               cells: grid.map { cellLightness(lightness, width: width, height: height, grid: $0) })
    }

    /// The mean of `lightness`, a value a pixel, over each cell of `grid`.
    static func cellLightness(_ lightness: [Double], width: Int, height: Int, grid: GridSize) -> [Float] {
        var cells = [Float](repeating: .nan, count: grid.width * grid.height)
        for row in 0..<grid.height {
            for column in 0..<grid.width {
                var sum = 0.0, n = 0
                for y in (row * grid.step)..<min(row * grid.step + grid.step, height) {
                    for x in (column * grid.step)..<min(column * grid.step + grid.step, width) {
                        sum += lightness[y * width + x]
                        n += 1
                    }
                }
                if n > 0 { cells[row * grid.width + column] = Float(sum / Double(n)) }
            }
        }
        return cells
    }

    /// The mean L* of a render over a region of its frame's descriptor, `low` to `high` in its cells
    /// from the bottom-left: each analysis grid cell the region covers, weighted by its pixels and
    /// the share of it covered, the region placed on the grid as the descriptor holds the grid
    /// (`SequenceDescriptor.gridSpan`) and linearly inside each of its cells; `nil` for none.
    static func regionLightness(_ cells: [Float], grid: GridSize, descriptor: SequenceDescriptor,
                                low: SIMD2<Float>, high: SIMD2<Float>) -> Double? {
        func onGrid(_ x: Float, _ count: Int, _ gridCount: Int) -> Double {
            let x = min(max(x, 0), Float(count)), index = min(Int(x), count - 1)
            let span = SequenceDescriptor.gridSpan(index, of: count, over: gridCount)
            return Double(span.lowerBound) + Double(x - Float(index)) * Double(span.count)
        }
        let x0 = onGrid(low.x, descriptor.width, grid.width), x1 = onGrid(high.x, descriptor.width, grid.width)
        let y0 = onGrid(low.y, descriptor.height, grid.height), y1 = onGrid(high.y, descriptor.height, grid.height)
        guard x1 > x0, y1 > y0 else { return nil }
        var sum = 0.0, total = 0.0
        for row in Int(y0)..<min(Int(y1.rounded(.up)), grid.height) {
            let wy = min(Double(row + 1), y1) - max(Double(row), y0)
            for column in Int(x0)..<min(Int(x1.rounded(.up)), grid.width) {
                let wx = min(Double(column + 1), x1) - max(Double(column), x0)
                let value = cells[row * grid.width + column]
                guard wx > 0, wy > 0, value.isFinite else { continue }
                let weight = wx * wy * Double(grid.pixels(column, row))
                sum += weight * Double(value)
                total += weight
            }
        }
        return total > 0 ? sum / total : nil
    }

    struct A7Data {
        var sessions: [Session]
        var primary: [Pair]
        var boundaries: [Boundary]
        var counted: [Split: [Source: Int]]
        var otherSurface: [Split: Int]
    }

    /// The a7 IV sessions in the split, each measured from its sheet decode, the split's primary pairs
    /// with their boxes and its boundaries; and the primary pairs on both splits counted.
    static func a7iv(_ file: ProtocolFile, split: Split, unitIndex: [String: Int], renders: Renders, firstSession: Int) throws -> A7Data {
        var counted: [Split: [Source: Int]] = [:], otherSurface: [Split: Int] = [:]
        for s in Split.allCases {
            let pairs = file.a7iv.pairs.filter { $0.split == s.rawValue }
            counted[s] = [.owner: pairs.filter { $0.samePhysicalSurface && $0.folderA == "owner-misc" }.count,
                          .corpora: pairs.filter { $0.samePhysicalSurface && $0.folderA != "owner-misc" }.count]
            otherSurface[s] = pairs.filter { !$0.samePhysicalSurface }.count
        }

        let folders = file.a7iv.folders.mapValues { $0.path.hasPrefix("/") ? URL(fileURLWithPath: $0.path) : M.root.appendingPathComponent($0.path) }
        var byUnit: [String: [(folder: String, url: URL, info: ARWFrameInfo)]] = [:]
        for frame in file.a7iv.frames {
            let unit = events[frame.session] ?? frame.session
            let assigned = try #require(file.units[unit], "\(frame.session) belongs to a unit")
            guard assigned == split.rawValue else { continue }
            let url = try #require(folders[frame.folder]).appendingPathComponent(frame.file)
            let info = try ARWFrameInfo.read(from: url)
            byUnit[unit, default: []].append((frame.folder, url, info))
        }
        var sessions: [Session] = [], place: [String: (session: Int, item: Int)] = [:]
        for unit in byUnit.keys.sorted() {
            // Capture order, as the roll scan orders it; the two raw.pixls.us folders merge here.
            let frames = byUnit[unit]!.sorted { a, b in
                switch (a.info.captureDate, b.info.captureDate) {
                case let (x?, y?) where x != y: return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending
                }
            }
            var items: [Item] = []
            for (index, frame) in frames.enumerated() {
                let name = "\(frame.folder)/\(frame.url.lastPathComponent)"
                let item: Item = try autoreleasepool {
                    let key = try renders.key(frame.url, name: name)
                    let decoded = try renders.decode(frame.url, key: key)
                    let (analysis, descriptor) = ExposureAnalyzer.measure(decoded, workingSpace: renders.gpu.workingColorSpace, info: frame.info)
                    let noise = DecodedNoise.appleDecode(model: frame.info.model, iso: frame.info.iso, pins: decoded.pins)
                    let grid = ExposureAnalyzer.grid(pixels: ExposureAnalyzer.pixels(of: decoded.texture), width: decoded.width,
                                                     height: decoded.height, noise: noise)
                    try #require(SequenceDescriptor(grid: grid) == descriptor, "\(name)'s descriptor is its analysis grid's")
                    var item = Item(name: name, source: frame.folder == "owner-misc" ? .owner : .corpora,
                                    frame: Frame(id: index, url: frame.url, info: frame.info), analysis: analysis,
                                    descriptor: descriptor, decode: key, grid: GridSize(grid))
                    if !analysis.faces.isEmpty {
                        let fixed = try #require(fixedContent(analysis, grid: grid))
                        item.withoutFaces = fixed.0
                        item.movedFaces = fixed.1
                    }
                    return item
                }
                place[name] = (sessions.count, index)
                items.append(item)
            }
            sessions.append(Session(unit: unit, items: items))
        }
        renders.cache.flush()

        var primary: [Pair] = []
        for pair in file.a7iv.pairs where pair.split == split.rawValue && pair.samePhysicalSurface {
            let a = try #require(place["\(pair.folderA)/\(pair.a)"]), b = try #require(place["\(pair.folderB)/\(pair.b)"])
            try #require(a.session == b.session, "\(pair.id) lies in one unit")
            sessions[a.session].items[a.item].boxes.append(pair.boxA)
            sessions[b.session].items[b.item].boxes.append(pair.boxB)
            primary.append(Pair(id: pair.id, source: pair.folderA == "owner-misc" ? .owner : .corpora, scene: pair.sceneType,
                                unit: try #require(unitIndex[sessions[a.session].unit]), session: firstSession + a.session,
                                a: a.item, b: b.item,
                                boxes: (sessions[a.session].items[a.item].boxes.count - 1, sessions[b.session].items[b.item].boxes.count - 1)))
        }
        var boundaries: [Boundary] = []
        for boundary in file.a7iv.boundaries where boundary.split == split.rawValue && boundary.confidence >= Threshold.boundaryConfidence {
            let a = try #require(place["\(boundary.folder)/\(boundary.a)"]), b = try #require(place["\(boundary.folder)/\(boundary.b)"])
            boundaries.append(Boundary(id: "\(boundary.folder)/\(boundary.a)>\(boundary.b)",
                                       a: (firstSession + a.session, a.item), b: (firstSession + b.session, b.item)))
        }
        return A7Data(sessions: sessions, primary: primary, boundaries: boundaries, counted: counted, otherSurface: otherSurface)
    }

    // MARK: Rolls

    /// `items` as one roll in their order, on `stock`.
    static func input(_ items: [Item], stock: Stock) -> SequenceAims.Input {
        var frames: [Frame] = [], analyses: [URL: ExposureAnalysis] = [:], descriptors: [URL: SequenceDescriptor] = [:]
        for item in items {
            frames.append(Frame(id: frames.count, url: item.frame.url, info: item.frame.info))
            analyses[item.frame.url] = item.analysis
            descriptors[item.frame.url] = item.descriptor
        }
        return SequenceAims.Input(frames: frames, analyses: analyses, descriptors: descriptors, stock: stock, controls: controls)
    }

    /// G4's rolls: every frame of the split with a face, between two copies of itself with its faces
    /// dropped, and with its boxes moved and grown, 2 s apart with its own header otherwise.
    static func fixedContent(_ sessions: [Session]) throws -> [FixedContent] {
        var rolls: [FixedContent] = []
        for item in sessions.flatMap(\.items) {
            guard let without = item.withoutFaces, let moved = item.movedFaces else { continue }
            let date = try #require(item.frame.info.captureDate)
            for (variant, middle) in [("faces dropped", without), ("faces moved", moved)] {
                let items = [item.analysis, middle, item.analysis].enumerated().map { k, analysis in
                    var copy = item, info = item.frame.info
                    info.captureDate = date + Double(k) * Threshold.fixedContentSeconds
                    copy.analysis = analysis
                    copy.frame = Frame(id: k, url: URL(fileURLWithPath: "/fixed-content/\(variant)/\(item.name)/\(k)"), info: info)
                    return copy
                }
                rolls.append(FixedContent(name: item.name, variant: variant, source: item.source, items: items))
            }
        }
        return rolls
    }

    /// G7's long roll: the split's sessions, largest first, chained 31 minutes apart until it holds 340 frames.
    static func synthetic(_ sessions: [Session]) throws -> [Item] {
        var items: [Item] = [], last: Date?
        let ordered = sessions.sorted { $0.items.count > $1.items.count || ($0.items.count == $1.items.count && $0.unit < $1.unit) }
        for session in ordered where items.count < Threshold.syntheticFrames {
            let first = try #require(session.items.first?.frame.info.captureDate)
            let start = last.map { $0 + Threshold.syntheticGap } ?? first
            for item in session.items.prefix(Threshold.syntheticFrames - items.count) {
                var copy = item, info = item.frame.info
                info.captureDate = start + (try #require(info.captureDate)).timeIntervalSince(first)
                copy.frame = Frame(id: items.count, url: item.frame.url, info: info)
                items.append(copy)
                last = info.captureDate
            }
        }
        try #require(items.count == Threshold.syntheticFrames, "the split holds \(Threshold.syntheticFrames) frames")
        return items
    }

    // MARK: The matcher's pairs

    /// The matcher's pairs, kept across configurations. A pair's link depends only on its two frames
    /// and the evidence's parameters (`SequenceEvidence.link`; `neighbours` only picks the pairs), so
    /// each pair is matched once for each `Setting`, and a session's links, or its links without one
    /// frame (G6), are put together from the pairs as `SequenceEvidence.links` walks them (`links`).
    /// Once for each setting and `neighbours` the links put together are checked to be
    /// `SequenceEvidence.links`' bit for bit on every session of both scenarios (`prepare`).
    final class Evidence {
        /// What the matcher reads of `SequenceAims.Parameters`, `neighbours` aside, bit for bit.
        struct Setting: Hashable {
            var maximumGap: UInt64
            var minimumOverlap: UInt32
            var minimumCorrelation: UInt32
            var minimumDetail: UInt32
            var lightTolerance: UInt32
            var maximumSamples: Int

            init(_ p: SequenceAims.Parameters) {
                maximumGap = p.maximumGap.bitPattern
                minimumOverlap = p.minimumOverlap.bitPattern
                minimumCorrelation = p.minimumCorrelation.bitPattern
                minimumDetail = p.minimumDetail.bitPattern
                lightTolerance = p.lightTolerance.bitPattern
                maximumSamples = p.maximumSamples
            }
        }

        /// A frame of the benchmark: its scenario, its session there and its index in the session.
        struct FrameKey: Hashable {
            var scenario: Scenario
            var session: Int
            var item: Int
        }

        /// Two frames of a session, the earlier first, under one setting.
        struct PairKey: Hashable {
            var earlier: FrameKey
            var later: Int
            var setting: Setting
        }

        struct PyramidKey: Hashable {
            var frame: FrameKey
            var minimumDetail: UInt32
        }

        struct Check: Hashable {
            var setting: Setting
            var neighbours: Int
        }

        private var pyramids: [PyramidKey: SequenceEvidence.Pyramid?] = [:]
        /// Each pair's link, its frames the items' indices in their session; `nil` for none.
        private var pairs: [PairKey: SequenceAims.Link?] = [:]
        private var placed: [PairKey: [Footprint?]] = [:]
        private var checked: Set<Check> = []
        /// The pairs matched, and each check against `SequenceEvidence.links`: its parameters and seconds.
        private(set) var matched = 0
        private(set) var checks: [String: Double] = [:]

        func pyramid(_ frame: FrameKey, _ item: Item, minimumDetail: Float) -> SequenceEvidence.Pyramid? {
            let key = PyramidKey(frame: frame, minimumDetail: minimumDetail.bitPattern)
            if let known = pyramids[key] { return known }
            let made = SequenceEvidence.Pyramid(item.descriptor, minimumDetail: minimumDetail)
            pyramids.updateValue(made, forKey: key)
            return made
        }

        /// Matches every pair of `sessions` up to `span` frames apart not matched yet for
        /// `parameters`' setting, in parallel; then, once for the setting and `neighbours`, checks
        /// the links put together against `SequenceEvidence.links` on every session.
        func prepare(_ sessions: [Scenario: [Session]], parameters: SequenceAims.Parameters, span: Int, stock: Stock) throws {
            let setting = Setting(parameters)
            var frames: [(PyramidKey, SequenceDescriptor)] = []
            for scenario in Scenario.allCases {
                for (s, session) in (sessions[scenario] ?? []).enumerated() {
                    for (k, item) in session.items.enumerated() {
                        let key = PyramidKey(frame: FrameKey(scenario: scenario, session: s, item: k), minimumDetail: setting.minimumDetail)
                        if pyramids[key] == nil { frames.append((key, item.descriptor)) }
                    }
                }
            }
            let minimumDetail = parameters.minimumDetail
            let made = SequenceBenchmarkMeasureTests.parallelMap(frames.map(\.1), chunk: 16) {
                SequenceEvidence.Pyramid($0, minimumDetail: minimumDetail)
            }
            for (k, frame) in frames.enumerated() { pyramids.updateValue(made[k], forKey: frame.0) }

            var jobs: [(key: PairKey, earlier: SequenceEvidence.Side, later: SequenceEvidence.Side, gap: Double)] = []
            for scenario in Scenario.allCases {
                for (s, session) in (sessions[scenario] ?? []).enumerated() {
                    let items = session.items
                    for i in items.indices {
                        let frame = FrameKey(scenario: scenario, session: s, item: i)
                        guard let a = pyramid(frame, items[i], minimumDetail: minimumDetail), let start = items[i].frame.info.captureDate else { continue }
                        for j in (i + 1)..<min(items.count, i + 1 + max(span, 0)) {
                            let key = PairKey(earlier: frame, later: j, setting: setting)
                            guard pairs[key] == nil, let end = items[j].frame.info.captureDate,
                                  let b = pyramid(FrameKey(scenario: scenario, session: s, item: j), items[j], minimumDetail: minimumDetail)
                            else { continue }
                            let gap = abs(end.timeIntervalSince(start))
                            guard gap <= parameters.maximumGap else { continue }
                            jobs.append((key, (i, items[i].frame.info, items[i].analysis, a), (j, items[j].frame.info, items[j].analysis, b), gap))
                        }
                    }
                }
            }
            let pending = jobs
            let found = SequenceBenchmarkMeasureTests.parallel(pending.count) { k in
                SequenceEvidence.link(earlier: pending[k].earlier, later: pending[k].later, gap: pending[k].gap, parameters: parameters, tuning: .standard)
            }
            for (k, job) in pending.enumerated() { pairs.updateValue(found[k], forKey: job.key) }
            matched += pending.count

            let check = Check(setting: setting, neighbours: parameters.neighbours)
            guard !checked.contains(check) else { return }
            let clock = ContinuousClock(), start = clock.now
            for scenario in Scenario.allCases {
                let list = sessions[scenario] ?? []
                let assembled = list.indices.map {
                    links(scenario, $0, members: Array(list[$0].items.indices), items: list[$0].items, parameters: parameters)
                }
                let direct = SequenceBenchmarkMeasureTests.parallel(list.count) {
                    SequenceEvidence.links(SequenceBenchmarkMeasureTests.input(list[$0].items, stock: stock), parameters: parameters)
                }
                for s in list.indices {
                    try #require(SequenceBenchmarkMeasureTests.identical(assembled[s], direct[s]),
                                 "the kept pairs give \(list[s].unit)'s links \(scenario.rawValue) as SequenceEvidence.links does")
                }
            }
            checked.insert(check)
            let name = String(format: "neighbours %ld, maximumGap %g, minimumOverlap %g, minimumCorrelation %g, minimumDetail %g, "
                              + "lightTolerance %g, maximumSamples %ld", parameters.neighbours, parameters.maximumGap, parameters.minimumOverlap,
                              parameters.minimumCorrelation, parameters.minimumDetail, parameters.lightTolerance, parameters.maximumSamples)
            checks[name] = FrameViewMeasureTests.ms(clock.now - start) / 1000
        }

        /// The links among session `s`'s items `members` (indices, in capture order) as one roll, as
        /// `SequenceEvidence.links` finds them on that roll: each frame against the next `neighbours`
        /// members within `maximumGap` seconds, a pair not matched yet matched now. Their frames
        /// are indices into `members`.
        func links(_ scenario: Scenario, _ s: Int, members: [Int], items: [Item], parameters: SequenceAims.Parameters) -> [SequenceAims.Link] {
            let setting = Setting(parameters)
            let reach = min(max(parameters.neighbours, 0), members.count)
            guard reach > 0 else { return [] }
            var links: [SequenceAims.Link] = []
            for (i, a) in members.enumerated() {
                let frame = FrameKey(scenario: scenario, session: s, item: a)
                guard let earlier = pyramid(frame, items[a], minimumDetail: parameters.minimumDetail),
                      let start = items[a].frame.info.captureDate else { continue }
                for j in (i + 1)..<min(members.count, i + 1 + reach) {
                    let b = members[j]
                    guard let later = pyramid(FrameKey(scenario: scenario, session: s, item: b), items[b], minimumDetail: parameters.minimumDetail),
                          let end = items[b].frame.info.captureDate else { continue }
                    let gap = abs(end.timeIntervalSince(start))
                    guard gap <= parameters.maximumGap else { continue }
                    let key = PairKey(earlier: frame, later: b, setting: setting)
                    let found: SequenceAims.Link?
                    if let known = pairs[key] {
                        found = known
                    } else {
                        found = SequenceEvidence.link(earlier: (a, items[a].frame.info, items[a].analysis, earlier),
                                                      later: (b, items[b].frame.info, items[b].analysis, later),
                                                      gap: gap, parameters: parameters, tuning: .standard)
                        pairs.updateValue(found, forKey: key)
                        matched += 1
                    }
                    guard var link = found else { continue }
                    link.earlier = i
                    link.later = j
                    links.append(link)
                }
            }
            return links
        }

        /// Where the matched points of `link`, between session `s`'s items `a` and `b`, lie
        /// (`Footprint`), each found again in the match of the two frames: the source's cell
        /// whose light is the point's there bit for bit, and whose light read in the other frame
        /// is the point's there; `nil` for a point found nowhere.
        func footprints(_ scenario: Scenario, _ s: Int, _ a: Int, _ b: Int, items: [Item], link: SequenceAims.Link,
                        parameters: SequenceAims.Parameters) -> [Footprint?] {
            let key = PairKey(earlier: FrameKey(scenario: scenario, session: s, item: a), later: b, setting: Setting(parameters))
            if let known = placed[key] { return known }
            var found = [Footprint?](repeating: nil, count: link.weights.count)
            defer { placed[key] = found }
            guard let pa = pyramid(key.earlier, items[a], minimumDetail: parameters.minimumDetail),
                  let pb = pyramid(FrameKey(scenario: scenario, session: s, item: b), items[b], minimumDetail: parameters.minimumDetail),
                  let match = SequenceEvidence.match(pa, pb, parameters: parameters, tuning: .standard) else { return found }
            let (source, target) = match.earlierIsSource ? (pa, pb) : (pb, pa)
            func bits(_ v: SIMD3<Float>) -> SIMD3<UInt32> { SIMD3(v.x.bitPattern, v.y.bitPattern, v.z.bitPattern) }
            var cells: [SIMD3<UInt32>: [Int]] = [:]
            for cell in source.levels[0].cells { cells[bits(source.levels[0].rgb[cell.index]), default: []].append(cell.index) }
            let half = SIMD2<Float>(repeating: match.alignment.scale / 2)
            for k in found.indices where k < link.earlierSamples.count && k < link.laterSamples.count {
                let (s, t) = match.earlierIsSource ? (link.earlierSamples[k], link.laterSamples[k]) : (link.laterSamples[k], link.earlierSamples[k])
                for cell in cells[bits(s)] ?? [] {
                    let point = SIMD2(Float(cell % source.width) + 0.5, Float(cell / source.width) + 0.5)
                    let q = match.alignment.map(point, width: source.width, height: source.height)
                    guard bits(SequenceEvidence.sampledLight(target.levels[match.targetLevel], level: match.targetLevel, at: q)) == bits(t) else { continue }
                    let own = (low: point - 0.5, high: point + 0.5), other = (low: q - half, high: q + half)
                    found[k] = match.earlierIsSource ? Footprint(earlier: own, later: other) : Footprint(earlier: other, later: own)
                    break
                }
            }
            return found
        }
    }

    /// Where a link's matched point lies in its two frames, in each one's descriptor cells from the
    /// bottom-left: the cell it was read from in the frame the matcher walked (the source), and
    /// that cell's square as the alignment lands it in the other, where the point was read
    /// bilinearly.
    struct Footprint {
        var earlier: (low: SIMD2<Float>, high: SIMD2<Float>)
        var later: (low: SIMD2<Float>, high: SIMD2<Float>)
    }

    /// Whether two lists of links are the same bit for bit.
    static func identical(_ a: [SequenceAims.Link], _ b: [SequenceAims.Link]) -> Bool {
        func bits(_ v: [SIMD3<Float>]) -> [UInt32] { v.flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] } }
        return a.count == b.count && zip(a, b).allSatisfy { x, y in
            x.earlier == y.earlier && x.later == y.later && x.shift.bitPattern == y.shift.bitPattern
                && x.lightChange?.bitPattern == y.lightChange?.bitPattern && x.confidence.bitPattern == y.confidence.bitPattern
                && x.overlap.bitPattern == y.overlap.bitPattern && x.correlation.bitPattern == y.correlation.bitPattern
                && x.weights.map(\.bitPattern) == y.weights.map(\.bitPattern)
                && bits(x.earlierSamples) == bits(y.earlierSamples) && bits(x.laterSamples) == bits(y.laterSamples)
        }
    }

    /// Whether two results are the same bit for bit.
    static func identical(_ a: SequenceAims.Result, _ b: SequenceAims.Result) -> Bool {
        func bits(_ aim: PrintAim) -> SIMD4<UInt32> {
            SIMD4(aim.level.bitPattern, aim.cast.x.bitPattern, aim.cast.y.bitPattern, aim.cast.z.bitPattern)
        }
        return a.aims.mapValues(bits) == b.aims.mapValues(bits) && a.initial.mapValues(\.bitPattern) == b.initial.mapValues(\.bitPattern)
            && a.residual.mapValues(\.bitPattern) == b.residual.mapValues(\.bitPattern) && identical(a.links, b.links)
    }

    // MARK: Scoring one configuration

    /// Two frames of a roll, in either order.
    struct Edge: Hashable {
        var a: Int
        var b: Int

        init(_ x: Int, _ y: Int) {
            a = min(x, y)
            b = max(x, y)
        }
    }

    /// One configuration on one stock: every session of each scenario resolved.
    struct Run {
        var results: [Scenario: [SequenceAims.Result]] = [:]
        var edges: [Scenario: [Set<Edge>]] = [:]
        /// Each session's frames by the component of the result's links that holds them, -1 for none.
        var components: [Scenario: [[Int]]] = [:]

        func aim(_ scenario: Scenario, _ session: Int, _ item: Item) throws -> PrintAim {
            try #require(results[scenario]![session].aims[item.frame.url], "\(item.name) has an aim")
        }

        func linked(_ scenario: Scenario, _ session: Int, _ a: Int, _ b: Int) -> Bool {
            edges[scenario]![session].contains(Edge(a, b))
        }

        /// Whether a chain of the result's links joins two frames (amendment 5).
        func joined(_ scenario: Scenario, _ session: Int, _ a: Int, _ b: Int) -> Bool {
            let component = components[scenario]![session]
            return component[a] >= 0 && component[a] == component[b]
        }
    }

    /// Each of `count` frames' component of `links` (`SequenceAims.groups`), -1 for a frame no link touches.
    static func components(_ links: [SequenceAims.Link], count: Int) -> [Int] {
        var component = [Int](repeating: -1, count: count)
        for (index, group) in SequenceAims.groups(links, count: count).enumerated() {
            for frame in group { component[frame] = index }
        }
        return component
    }

    /// A pair's region L* at each end, its levels, and whether the result links its frames.
    struct Scored {
        var lightness: [Double]
        var levels: [Float]
        var linked: Bool

        var delta: Double { lightness[1] - lightness[0] }
    }

    struct Movement: Codable {
        var removed: String
        var moved: String
        var stops: Double
    }

    /// What one configuration gives, before it is set against control.
    struct Score {
        var configuration: Configuration
        var runs: [String: Run] = [:]
        /// Per stock and scenario, aligned with the benchmark's pairs.
        var primary: [String: [Scenario: [Scored]]] = [:]
        var changed: [String: [Scenario: [Scored]]] = [:]
        /// Portra 400: each boundary linked, and Cube++'s changed-light pairs and the boundaries whose
        /// frames a chain of links joins (amendment 5).
        var boundaries: [Bool] = []
        var changedJoined: [Scenario: [Bool]] = [:]
        var boundariesJoined: [Bool] = []
        /// Frames with no link, every stock and scenario, and those not at their own level bit for bit.
        var unlinked = 0
        var unlinkedMoved: [String] = []
        /// Portra 400: each fixed-content roll's jump and levels.
        var jumps: [Double] = []
        var jumpLevels: [[Float]] = []
        /// Per stock: each frame's G5 at its aim, as shot, in the order of the sessions' items; `nil`
        /// with no matte point.
        var detail: [String: [Shares?]] = [:]
        /// Portra 400: forced leave-one-out, when it is computed (`Options.stability`), each
        /// removal's largest movement and every movement.
        var stability = false
        var removals: [Double] = []
        var movements: [Double] = []
        var listed: [Movement] = []
        var agreement: Agreement?
        /// `nil` when not computed (`Options.cost`).
        var cost: Cost?
        /// Wall time in all and by part, in seconds.
        var seconds = 0.0
        var timings: [String: Double] = [:]
    }

    /// Mean L* over a descriptor's cells that hold light, the cube's mask left out (amendment 4),
    /// printed on the CPU at `settings`: the whole-frame lightness G4 compares, the same for every method.
    static func wholeLightness(_ item: Item, _ settings: DevelopSettings, stock: Stock) -> Double {
        let d = item.descriptor
        var sum = 0.0, n = 0
        for k in 0..<(d.width * d.height) where !(item.masked?[k] ?? false) {
            let rgb = SIMD3(d.rgb[3 * k], d.rgb[3 * k + 1], d.rgb[3 * k + 2])
            guard rgb != .zero, rgb.x.isFinite, rgb.y.isFinite, rgb.z.isFinite else { continue }
            sum += D.printedLightness(rgb, settings, stock: stock)
            n += 1
        }
        return n > 0 ? sum / Double(n) : .nan
    }

    /// The CPU measures of Cube++ frames and of fixed content, each made once a frame, stock and aim.
    final class Memo {
        var detail: [Renders.Key: Shares?] = [:]
        var whole: [Renders.Key: Double] = [:]
    }

    /// Times `configuration` on `items` in a release build: the median of `Threshold.timedRuns` after
    /// one to warm, and what it holds, descriptors and links.
    static func cost(_ configuration: Configuration, _ items: [Item], stock: Stock) -> (milliseconds: Double, bytes: Int, links: Int) {
        let roll = input(items, stock: stock)
        let result = SequenceAims.resolve(roll, method: configuration.method, parameters: configuration.parameters)
        let clock = ContinuousClock()
        let times = (0..<Threshold.timedRuns).map { _ in
            M.ms(clock.measure { _ = SequenceAims.resolve(roll, method: configuration.method, parameters: configuration.parameters) })
        }
        let descriptors = roll.descriptors.values.reduce(0) {
            $0 + MemoryLayout<SequenceDescriptor>.stride + ($1.rgb.count + $1.unclipped.count + $1.detail.count) * MemoryLayout<Float>.stride
        }
        let links = result.links.reduce(0) {
            $0 + MemoryLayout<SequenceAims.Link>.stride + ($1.earlierSamples.count + $1.laterSamples.count) * MemoryLayout<SIMD3<Float>>.stride
                + $1.weights.count * MemoryLayout<Float>.stride
        }
        return (G.median(times), descriptors + links, result.links.count)
    }

    struct Cost: Codable {
        var largestSession = ""
        var largestFrames = 0
        var largestMilliseconds = 0.0
        var syntheticFrames = 0
        var syntheticMilliseconds = 0.0
        var syntheticMegabytes = 0.0
        var syntheticLinks = 0

        var largestPerFrame: Double { largestMilliseconds / Double(max(largestFrames, 1)) }
        var syntheticPerFrame: Double { syntheticMilliseconds / Double(max(syntheticFrames, 1)) }
    }

    /// `configuration` on the split: every session resolved on every stock, the a7 IV frames rendered at
    /// their levels, and what each gate reads. A candidate's links come from the kept pairs
    /// (`Evidence`) and go to `SequenceAims.resolve(_:links:method:parameters:)`, the path the
    /// public `resolve` takes once it has matched them, which three sessions check.
    static func score(_ configuration: Configuration, _ bench: Benchmark, stocks: [Stock], renders: Renders, memo: Memo,
                      evidence: Evidence, options: Options) throws -> Score {
        let clock = ContinuousClock(), start = clock.now
        var score = Score(configuration: configuration), mark = start
        func lap(_ part: String) {
            score.timings[part, default: 0] += M.ms(clock.now - mark) / 1000
            mark = clock.now
        }
        let method = configuration.method, parameters = configuration.parameters
        let stability = options.stability.contains(configuration.name)
        let primary = stocks[0], asShot = bench.sessions[.asShot]!

        // Each session's links, the same on every stock; control reads none. G6 also needs each
        // frame matched with the one just past its neighbours, which a removal brings within reach.
        var links: [Scenario: [[SequenceAims.Link]]] = [:]
        if method != .control {
            try evidence.prepare(bench.sessions, parameters: parameters, span: max(parameters.neighbours, 0) + (stability ? 1 : 0), stock: primary)
        }
        for scenario in Scenario.allCases {
            links[scenario] = bench.sessions[scenario]!.enumerated().map { s, session in
                method == .control ? [] : evidence.links(scenario, s, members: Array(session.items.indices), items: session.items, parameters: parameters)
            }
        }
        lap("links")
        for stock in stocks {
            var run = Run()
            for scenario in Scenario.allCases {
                let sessions = bench.sessions[scenario]!, found = links[scenario]!
                let results = parallel(sessions.count) { s in
                    SequenceAims.resolve(input(sessions[s].items, stock: stock), links: found[s], method: method, parameters: parameters)
                }
                run.results[scenario] = results
                run.edges[scenario] = results.map { Set($0.links.map { Edge($0.earlier, $0.later) }) }
                run.components[scenario] = zip(sessions, results).map { components($1.links, count: $0.items.count) }
            }
            score.runs[stock.id] = run
        }
        // The public resolve, which matches its own links, gives the same on the sessions with the most links.
        let solved = score.runs[primary.id]!.results[.asShot]!
        let busiest = asShot.indices.sorted { a, b in
            solved[a].links.count != solved[b].links.count ? solved[a].links.count > solved[b].links.count : a < b
        }
        for s in busiest.prefix(3) {
            let direct = SequenceAims.resolve(input(asShot[s].items, stock: primary), method: method, parameters: parameters)
            try #require(identical(direct, solved[s]), "\(configuration.name): \(asShot[s].unit) resolves as SequenceAims.resolve resolves it")
        }
        lap("resolve")

        // The a7 IV frames rendered at their levels on every stock.
        for s in bench.a7 {
            for item in asShot[s].items {
                try renders.render(item, aims: try stocks.map { ($0, try score.runs[$0.id]!.aim(.asShot, s, item)) })
            }
        }
        lap("renders")

        for stock in stocks {
            let run = score.runs[stock.id]!
            func lightness(_ pair: Pair, _ scenario: Scenario, end: Int) throws -> (Double, Float) {
                let item = bench.sessions[scenario]![pair.session].items[end == 0 ? pair.a : pair.b]
                let aim = try run.aim(scenario, pair.session, item)
                if let cube = item.cube {
                    return (D.printedLightness(cube, controls.settings(for: stock, aim: aim), stock: stock), aim.level)
                }
                let box = try #require(pair.boxes.map { end == 0 ? $0.0 : $0.1 })
                return (try #require(renders.measure(item, stock, aim)).boxes[box], aim.level)
            }
            func scored(_ pairs: [Pair], _ scenario: Scenario) throws -> [Scored] {
                try pairs.map { pair in
                    let a = try lightness(pair, scenario, end: 0), b = try lightness(pair, scenario, end: 1)
                    return Scored(lightness: [a.0, b.0], levels: [a.1, b.1], linked: run.linked(scenario, pair.session, pair.a, pair.b))
                }
            }
            for scenario in Scenario.allCases {
                score.primary[stock.id, default: [:]][scenario] = try scored(bench.primary[scenario]!, scenario)
                score.changed[stock.id, default: [:]][scenario] = try scored(bench.changed[scenario]!, scenario)
                // A frame no link reaches keeps its own level exactly (section 3).
                for (s, session) in bench.sessions[scenario]!.enumerated() {
                    let reached = Set(run.edges[scenario]![s].flatMap { [$0.a, $0.b] })
                    for (k, item) in session.items.enumerated() where !reached.contains(k) {
                        score.unlinked += 1
                        if try run.aim(scenario, s, item).level.bitPattern != AutoPrint.levelStops(item.analysis).bitPattern {
                            score.unlinkedMoved.append("\(stock.id) \(scenario.rawValue) \(item.name)")
                        }
                    }
                }
            }
            // G5: each frame's matte points at its aim, as shot; Cube++'s cells on the CPU, those not
            // worked out yet in parallel, and the a7 IV pixels with their renders.
            var cubes: [(key: Renders.Key, item: Item, aim: PrintAim)] = [], seen = Set<Renders.Key>()
            for (s, session) in asShot.enumerated() {
                for item in session.items where item.cube != nil {
                    let aim = try run.aim(.asShot, s, item), key = Renders.Key(item, stock, aim)
                    if memo.detail[key] == nil, seen.insert(key).inserted { cubes.append((key, item, aim)) }
                }
            }
            let pending = cubes
            let shares = parallel(pending.count) { cellShares(pending[$0].item, stock, pending[$0].aim) }
            for (k, cube) in pending.enumerated() { memo.detail.updateValue(shares[k], forKey: cube.key) }
            var detail: [Shares?] = []
            for (s, session) in asShot.enumerated() {
                for item in session.items {
                    let aim = try run.aim(.asShot, s, item)
                    if item.cube != nil {
                        detail.append(try #require(memo.detail[Renders.Key(item, stock, aim)]))
                    } else {
                        let measure = try #require(renders.measure(item, stock, aim))
                        detail.append(measure.points > 0 ? Shares(lost: Double(measure.lost) / Double(measure.points),
                                                                  paper: measure.matte > 0 ? measure.paper / Double(measure.matte) : .zero) : nil)
                    }
                }
            }
            score.detail[stock.id] = detail
        }
        lap("detail")

        let run = score.runs[primary.id]!
        score.boundaries = bench.boundaries.map { $0.a.session == $0.b.session && run.linked(.asShot, $0.a.session, $0.a.item, $0.b.item) }
        score.boundariesJoined = bench.boundaries.map { $0.a.session == $0.b.session && run.joined(.asShot, $0.a.session, $0.a.item, $0.b.item) }
        for scenario in Scenario.allCases {
            score.changedJoined[scenario] = bench.changed[scenario]!.map { run.joined(scenario, $0.session, $0.a, $0.b) }
        }
        // G4: the fixed-content rolls' jumps in whole-frame L*.
        let rolls = bench.fixedContent
        let fixed = parallel(rolls.count) { SequenceAims.resolve(input(rolls[$0].items, stock: primary), method: method, parameters: parameters) }
        for (roll, result) in zip(rolls, fixed) {
            var levels: [Float] = [], whole: [Double] = []
            for item in roll.items {
                let aim = try #require(result.aims[item.frame.url])
                let key = Renders.Key(item, primary, aim)
                if memo.whole[key] == nil { memo.whole[key] = wholeLightness(item, controls.settings(for: primary, aim: aim), stock: primary) }
                levels.append(aim.level)
                whole.append(memo.whole[key]!)
            }
            score.jumps.append(zip(whole, whole.dropFirst()).map { abs($1 - $0) }.max() ?? 0)
            score.jumpLevels.append(levels)
        }
        lap("faces")

        // G6: forced leave-one-out within each session, each session without the frame resolved on
        // its links put together from the kept pairs, the removals in parallel.
        if stability {
            score.stability = true
            var removals: [(session: Int, removed: Int, links: [SequenceAims.Link])] = []
            for (s, session) in asShot.enumerated() where session.items.count > 1 {
                for k in session.items.indices {
                    let members = session.items.indices.filter { $0 != k }
                    let links = method == .control ? [] : evidence.links(.asShot, s, members: members, items: session.items, parameters: parameters)
                    removals.append((s, k, links))
                }
            }
            let jobs = removals
            let without = parallel(jobs.count) { r in
                var rest = asShot[jobs[r].session].items
                rest.remove(at: jobs[r].removed)
                return SequenceAims.resolve(input(rest, stock: primary), links: jobs[r].links, method: method, parameters: parameters).aims
            }
            // The public resolve gives the same without the middle frame of the sessions with the most links.
            for s in busiest.prefix(3) where asShot[s].items.count > 1 {
                let middle = asShot[s].items.count / 2
                var rest = asShot[s].items
                rest.remove(at: middle)
                let direct = SequenceAims.resolve(input(rest, stock: primary), method: method, parameters: parameters).aims
                let r = try #require(jobs.firstIndex { $0.session == s && $0.removed == middle })
                try #require(direct.mapValues(\.level.bitPattern) == without[r].mapValues(\.level.bitPattern)
                             && direct.mapValues(\.cast) == without[r].mapValues(\.cast),
                             "\(configuration.name): \(asShot[s].unit) without \(asShot[s].items[middle].name) resolves as SequenceAims.resolve resolves it")
            }
            for (removal, aims) in zip(jobs, without) {
                let session = asShot[removal.session], full = run.results[.asShot]![removal.session].aims
                var largest = 0.0
                for (k, item) in session.items.enumerated() where k != removal.removed {
                    guard let before = full[item.frame.url]?.level, let after = aims[item.frame.url]?.level else { continue }
                    let moved = Double(abs(after - before))
                    largest = max(largest, moved)
                    score.movements.append(moved)
                    if moved > Threshold.listed {
                        score.listed.append(Movement(removed: session.items[removal.removed].name, moved: item.name, stops: moved))
                    }
                }
                score.removals.append(largest)
            }
        }
        lap("stability")

        if options.agreement.contains(configuration.name) {
            score.agreement = try agreement(score, bench, stock: primary, renders: renders, evidence: evidence)
            renders.dropCells()
        }
        lap("agreement")

        // G7: the split's largest session and a synthetic 340-frame roll, timed with the public resolve.
        if options.cost.contains(configuration.name) {
            let largest = asShot.max { $0.items.count < $1.items.count || ($0.items.count == $1.items.count && $0.unit > $1.unit) }!
            let long = try synthetic(asShot)
            let (largestTime, _, _) = cost(configuration, largest.items, stock: primary)
            let (syntheticTime, bytes, linkCount) = cost(configuration, long, stock: primary)
            score.cost = Cost(largestSession: largest.unit, largestFrames: largest.items.count, largestMilliseconds: largestTime,
                              syntheticFrames: long.count, syntheticMilliseconds: syntheticTime,
                              syntheticMegabytes: Double(bytes) / 1_048_576, syntheticLinks: linkCount)
        }
        lap("cost")
        score.seconds = M.ms(clock.now - start) / 1000
        return score
    }

    /// The plan's check of the CPU's lightness against full renders (docs/auto-exposure-consistency-plan.md,
    /// "verify agreement with full renders"), on the development split, not gated: on each a7 IV link of a
    /// configuration, Portra 400 as shot, the CPU response lightness of the link's matched points in each
    /// frame at its solved level (`SequenceAims.Response`, the points B prints) against the mean L* of the
    /// full render at that level over the same points' areas (`Footprint`, `regionLightness`), weighted alike.
    struct Agreement: Codable {
        var links: Int
        var points: Int
        /// Matched points not found again in the match, left out on both sides.
        var unplaced: Int
        /// |CPU − render| L* of each frame of each link: median, p90 and largest, and the mean CPU less render.
        var frameMedian: Double
        var frameP90: Double
        var frameMax: Double
        var frameMeanSigned: Double
        /// The same for the difference between a link's two frames, the later less the earlier.
        var linkMedian: Double
        var linkP90: Double
        var linkMax: Double
        var linkMeanSigned: Double
        /// The median |later − earlier| by the CPU and by the renders.
        var cpuDifference: Double
        var renderDifference: Double
    }

    static func agreement(_ score: Score, _ bench: Benchmark, stock: Stock, renders: Renders, evidence: Evidence) throws -> Agreement {
        let run = score.runs[stock.id]!, parameters = score.configuration.parameters
        func finite(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }
        var frames: [Double] = [], differences: [Double] = [], cpu: [Double] = [], rendered: [Double] = []
        var links = 0, points = 0, unplaced = 0
        for s in bench.a7 {
            let session = bench.sessions[.asShot]![s]
            for link in run.results[.asShot]![s].links {
                let ends = [session.items[link.earlier], session.items[link.later]]
                let aims = try ends.map { try run.aim(.asShot, s, $0) }
                for (item, aim) in zip(ends, aims) { try renders.render(item, aims: [(stock, aim)], cells: true) }
                let placed = evidence.footprints(.asShot, s, link.earlier, link.later, items: session.items, link: link, parameters: parameters)
                let cells = try zip(ends, aims).map { item, aim in try #require(renders.measure(item, stock, aim)?.cells) }
                // The points B prints (`RenderedLink.points`), with each one's render L* in both frames.
                var kept: [(k: Int, lightness: [Double])] = []
                for k in link.weights.indices where link.weights[k] > 0 && link.weights[k].isFinite && k < link.earlierSamples.count
                    && k < link.laterSamples.count && finite(link.earlierSamples[k]) && finite(link.laterSamples[k]) {
                    points += 1
                    guard let footprint = placed[k] else {
                        unplaced += 1
                        continue
                    }
                    let areas = [footprint.earlier, footprint.later]
                    let lightness = try (0..<2).map { end in
                        let grid = try #require(ends[end].grid, "\(ends[end].name) has its analysis grid")
                        let found = regionLightness(cells[end], grid: grid, descriptor: ends[end].descriptor, low: areas[end].low, high: areas[end].high)
                        return try #require(found, "\(ends[end].name): a matched point's area holds pixels")
                    }
                    kept.append((k, lightness))
                }
                guard !kept.isEmpty else { continue }
                links += 1
                let weights = kept.map { link.weights[$0.k] }, total = weights.reduce(0) { $0 + Double($1) }
                var sides: [(cpu: Double, render: Double)] = []
                for end in 0..<2 {
                    let samples = kept.map { end == 0 ? link.earlierSamples[$0.k] : link.laterSamples[$0.k] }
                    let print = SequenceAims.FramePrint(stock: stock, controls: controls, cast: aims[end].cast)
                    let response = SequenceAims.Response(samples: samples, weights: weights, print: print, stock: stock)
                    let side = (cpu: Double(response.lightness(at: aims[end].level)),
                                render: zip(kept, weights).reduce(0) { $0 + Double($1.1) * $1.0.lightness[end] } / total)
                    sides.append(side)
                    frames.append(side.cpu - side.render)
                }
                let cpuDifference = sides[1].cpu - sides[0].cpu, renderDifference = sides[1].render - sides[0].render
                differences.append(cpuDifference - renderDifference)
                cpu.append(abs(cpuDifference))
                rendered.append(abs(renderDifference))
            }
        }
        let f = frames.map(abs).sorted(), d = differences.map(abs).sorted()
        return Agreement(links: links, points: points, unplaced: unplaced,
                         frameMedian: G.median(f), frameP90: quantile(f, 0.9), frameMax: f.last ?? .nan, frameMeanSigned: G.mean(frames),
                         linkMedian: G.median(d), linkP90: quantile(d, 0.9), linkMax: d.last ?? .nan, linkMeanSigned: G.mean(differences),
                         cpuDifference: G.median(cpu.sorted()), renderDifference: G.median(rendered.sorted()))
    }

    // MARK: Against control

    /// The codebase's quantile: the value at ⌊q·n⌋ of the sorted values, the last at most
    /// (`SeriesMeasureTests.spread`); not a number for none.
    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int(q * Double(sorted.count)))]
    }

    /// `count` resamples of `units` unit indices with replacement, drawn by SplitMix64 from `seed`.
    static func draws(units: Int, count: Int, seed: UInt64) -> [[Int]] {
        var generator = D.SeededGenerator(state: seed)
        return (0..<count).map { _ in (0..<units).map { _ in Int(generator.next() % UInt64(units)) } }
    }

    /// G1 on one set of pairs.
    struct Consistency: Codable {
        var n: Int
        var median: Double
        var p90: Double
        var max: Double
        var controlMedian: Double
        var controlP90: Double
        var controlMax: Double
        /// p90 against control's, and its one-sided 95 % session-bootstrap upper bound: the 95th
        /// percentile of the ratio over resamples of the split's units, those holding no pair left out.
        var ratio: Double
        var upperBound: Double
        var emptyResamples: Int
        /// The pairs the result links directly, and their share.
        var linked: Int
        var coverage: Double
        var withinTarget: Bool
    }

    static func consistency(_ candidate: [Double], _ control: [Double], linked: [Bool], units: [Int], bench: Benchmark) -> Consistency {
        let a = candidate.map(abs), c = control.map(abs)
        let sa = a.sorted(), sc = c.sorted()
        func ratio(_ x: Double, _ y: Double) -> Double { y > 0 ? x / y : (x > 0 ? .infinity : 1) }
        var byUnit = [[Int]](repeating: [], count: bench.units.count)
        for (k, unit) in units.enumerated() { byUnit[unit].append(k) }
        var ratios: [Double] = [], empty = 0
        for draw in bench.draws {
            var x: [Double] = [], y: [Double] = []
            for unit in draw {
                for k in byUnit[unit] {
                    x.append(a[k])
                    y.append(c[k])
                }
            }
            guard !x.isEmpty else {
                empty += 1
                continue
            }
            ratios.append(ratio(quantile(x.sorted(), 0.9), quantile(y.sorted(), 0.9)))
        }
        let p90 = quantile(sa, 0.9), linkedCount = linked.filter { $0 }.count
        return Consistency(n: a.count, median: G.median(sa), p90: p90, max: sa.last ?? .nan, controlMedian: G.median(sc),
                           controlP90: quantile(sc, 0.9), controlMax: sc.last ?? .nan,
                           ratio: a.isEmpty ? .nan : ratio(p90, quantile(sc, 0.9)), upperBound: quantile(ratios.sorted(), 0.95),
                           emptyResamples: empty, linked: linkedCount, coverage: a.isEmpty ? .nan : Double(linkedCount) / Double(a.count),
                           withinTarget: p90 <= Threshold.target)
    }

    struct ConsistencyGate: Codable {
        /// Portra 400, as shot, every pair of P.
        var all: Consistency
        var bySource: [String: Consistency]
        var byScene: [String: Consistency]
        var byStock: [String: Consistency]
        /// Cube++'s pairs of P with one exposure per scene, the secondary scenario.
        var oneExposure: Consistency
    }

    struct Placement: Codable {
        var p90ByStock: [String: Double]
        var controlP90ByStock: [String: Double]
        var worseStocks: [String]
        /// The mean of each P region's L* less control's, Portra 400, and by stock.
        var meanSignedChange: Double
        var meanSignedChangeByStock: [String: Double]
        /// Frames no link reaches, over every stock and scenario, and those off their own level.
        var unlinkedFrames: Int
        var unlinkedMoved: Int
        var unlinkedMovedExamples: [String]
    }

    struct RealLight: Codable {
        var cubeppChanged: Int
        var cubeppLinked: Int
        var boundaries: Int
        var boundariesLinked: Int
        var share: Double
        /// The median over Cube++'s changed-light pairs of |ΔL*| less control's, the cube's gray.
        var medianChange: Double
        var oneExposureLinked: Int
        var oneExposureMedianChange: Double
        /// Reported beside the gate (amendment 5): the pairs and boundaries whose frames a chain of
        /// links joins, and their share.
        var cubeppJoined: Int
        var boundariesJoined: Int
        var joinedShare: Double
        var oneExposureJoined: Int
    }

    struct FaceRoll: Codable {
        var frame: String
        var variant: String
        var source: String
        var jump: Double
        var controlJump: Double
        var levels: [Double]
        var controlLevels: [Double]
    }

    struct Faces: Codable {
        var rolls: Int
        var median: Double
        var p90: Double
        var max: Double
        var controlP90: Double
        var controlMax: Double
        var bySource: [String: [Double]]
        var worst: [FaceRoll]
    }

    struct Detail: Codable {
        /// Portra 400: frames with matte points, the mean and largest rise of the share of them whose
        /// print leaves the Print LUT's domain (amendment 1), in points, and control's own share.
        var frames: Int
        var meanRise: Double
        var maxRise: Double
        var controlMeanShare: Double
        /// Frames with any matte point lost, under this configuration and control.
        var framesLost: Int
        var controlFramesLost: Int
        var worst: [String]
        /// The mean and largest rise by source and by stock.
        var bySource: [String: [Double]]
        var byStock: [String: [Double]]
        /// Not gated: the same at the L* thresholds G5 first named, paper white 99 and black 1, and
        /// with black within 0.5 L* of the stock's own paper black.
        var lightness: [String: Double]
        var stockBlack: [String: Double]
    }

    struct Stability: Codable {
        var removals: Int
        var p95: Double
        var max: Double
        /// Over every frame of every removal rather than each removal's largest.
        var pooledP95: Double
        var listed: [Movement]
    }

    struct Verdict: Codable {
        var gate: String
        /// `nil` when the run did not compute the gate (`Options`).
        var pass: Bool?
        var detail: String
    }

    struct LinkRecord: Codable {
        var session: String
        var from: String
        var to: String
        var shift: Double
        var lightChange: Double?
        var confidence: Double
        var overlap: Double
        var correlation: Double
        var samples: Int
    }

    struct FrameRecord: Codable {
        var name: String
        var session: String
        var own: Double
        var level: Double
        var linked: Bool
    }

    struct ConfigurationResult: Codable {
        var name: String
        var method: String
        var parameters: SequenceAims.Parameters
        /// Every aim on every stock and scenario equal to control's.
        var identicalToControl: Bool
        var g1: ConsistencyGate
        var g2: Placement
        var g3: RealLight
        var g4: Faces
        var g5: Detail
        /// `nil` when not computed (ARGENT_SEQUENCE_G6 and ARGENT_SEQUENCE_G7).
        var g6: Stability?
        var g7: Cost?
        /// The pre-registered gates; none for control.
        var gates: [Verdict]
        /// The development split's check of the CPU's lightness against full renders, when asked for.
        var agreement: Agreement?
        /// Wall time in all and by part, in seconds.
        var seconds: Double
        var timings: [String: Double]
        /// Portra 400, as shot.
        var links: [LinkRecord]
        var frames: [FrameRecord]
    }

    static func result(_ score: Score, against control: Score, _ bench: Benchmark, stocks: [Stock]) -> ConfigurationResult {
        let primary = stocks[0].id
        func consistency(_ stock: String, _ scenario: Scenario, _ subset: [Int]) -> Consistency {
            let s = score.primary[stock]![scenario]!, c = control.primary[stock]![scenario]!, pairs = bench.primary[scenario]!
            return Self.consistency(subset.map { s[$0].delta }, subset.map { c[$0].delta }, linked: subset.map { s[$0].linked },
                                    units: subset.map { pairs[$0].unit }, bench: bench)
        }
        let pairs = bench.primary[.asShot]!, all = Array(pairs.indices)
        let scenes = Set(pairs.map(\.scene)).sorted()
        let g1 = ConsistencyGate(
            all: consistency(primary, .asShot, all),
            bySource: Dictionary(uniqueKeysWithValues: Source.allCases.map { source in
                (source.rawValue, consistency(primary, .asShot, all.filter { pairs[$0].source == source }))
            }),
            byScene: Dictionary(uniqueKeysWithValues: scenes.map { scene in (scene, consistency(primary, .asShot, all.filter { pairs[$0].scene == scene })) }),
            byStock: Dictionary(uniqueKeysWithValues: stocks.map { ($0.id, consistency($0.id, .asShot, all)) }),
            oneExposure: consistency(primary, .oneExposure, Array(bench.primary[.oneExposure]!.indices)))

        func signedChange(_ stock: String) -> Double {
            let s = score.primary[stock]![.asShot]!, c = control.primary[stock]![.asShot]!
            return G.mean(zip(s, c).flatMap { [$0.lightness[0] - $1.lightness[0], $0.lightness[1] - $1.lightness[1]] })
        }
        let g2 = Placement(
            p90ByStock: g1.byStock.mapValues(\.p90), controlP90ByStock: g1.byStock.mapValues(\.controlP90),
            worseStocks: stocks.map(\.id).filter { g1.byStock[$0]!.p90 > g1.byStock[$0]!.controlP90 },
            meanSignedChange: signedChange(primary),
            meanSignedChangeByStock: Dictionary(uniqueKeysWithValues: stocks.map { ($0.id, signedChange($0.id)) }),
            unlinkedFrames: score.unlinked, unlinkedMoved: score.unlinkedMoved.count,
            unlinkedMovedExamples: Array(score.unlinkedMoved.prefix(20)))

        func change(_ scenario: Scenario) -> Double {
            G.median(zip(score.changed[primary]![scenario]!, control.changed[primary]![scenario]!).map { abs($0.delta) - abs($1.delta) })
        }
        let cubeLinked = score.changed[primary]![.asShot]!.filter(\.linked).count
        let boundariesLinked = score.boundaries.filter { $0 }.count
        let changedCount = bench.changed[.asShot]!.count + bench.boundaries.count
        let g3 = RealLight(cubeppChanged: bench.changed[.asShot]!.count, cubeppLinked: cubeLinked, boundaries: bench.boundaries.count,
                           boundariesLinked: boundariesLinked,
                           share: changedCount > 0 ? Double(cubeLinked + boundariesLinked) / Double(changedCount) : .nan,
                           medianChange: change(.asShot),
                           oneExposureLinked: score.changed[primary]![.oneExposure]!.filter(\.linked).count,
                           oneExposureMedianChange: change(.oneExposure),
                           cubeppJoined: score.changedJoined[.asShot]!.filter { $0 }.count,
                           boundariesJoined: score.boundariesJoined.filter { $0 }.count,
                           joinedShare: changedCount > 0
                               ? Double(score.changedJoined[.asShot]!.filter { $0 }.count + score.boundariesJoined.filter { $0 }.count) / Double(changedCount)
                               : .nan,
                           oneExposureJoined: score.changedJoined[.oneExposure]!.filter { $0 }.count)

        let rolls = bench.fixedContent.indices.map { k in
            FaceRoll(frame: bench.fixedContent[k].name, variant: bench.fixedContent[k].variant, source: bench.fixedContent[k].source.rawValue,
                     jump: score.jumps[k], controlJump: control.jumps[k], levels: score.jumpLevels[k].map(Double.init),
                     controlLevels: control.jumpLevels[k].map(Double.init))
        }
        let jumps = score.jumps.sorted(), controlJumps = control.jumps.sorted()
        let g4 = Faces(rolls: rolls.count, median: G.median(jumps), p90: quantile(jumps, 0.9), max: jumps.last ?? .nan,
                       controlP90: quantile(controlJumps, 0.9), controlMax: controlJumps.last ?? .nan,
                       bySource: Dictionary(uniqueKeysWithValues: Source.allCases.map { source in
                           let j = rolls.filter { $0.source == source.rawValue }.map(\.jump).sorted()
                           return (source.rawValue, [Double(j.count), quantile(j, 0.9), j.last ?? .nan])
                       }),
                       worst: Array(rolls.sorted { $0.jump > $1.jump }.prefix(10)))

        let items = bench.sessions[.asShot]!.flatMap(\.items)
        // The share G5 reads (`lost`, amendment 1), or with `c` 0 or 1 the L* thresholds' as first named,
        // paper black as named or the stock's own.
        func share(_ shares: Shares, _ c: Int?) -> Double { c.map { shares.paper[$0] } ?? shares.lost }
        func rises(_ stock: String, _ source: Source? = nil, _ c: Int? = nil) -> [(String, Double)] {
            zip(items, zip(score.detail[stock]!, control.detail[stock]!)).compactMap { item, shares in
                guard source.map({ item.source == $0 }) ?? true, let a = shares.0, let b = shares.1 else { return nil }
                return (item.name, (share(a, c) - share(b, c)) * 100)
            }
        }
        func spread(_ r: [(String, Double)]) -> [Double] { [G.mean(r.map(\.1)), r.map(\.1).max() ?? .nan] }
        func shares(_ s: Score, _ c: Int?) -> [Double] { s.detail[primary]!.compactMap { $0.map { share($0, c) } } }
        func diagnostic(_ c: Int) -> [String: Double] {
            let r = rises(primary, nil, c)
            return ["meanRise": G.mean(r.map(\.1)), "maxRise": r.map(\.1).max() ?? .nan, "controlMeanShare": G.mean(shares(control, c)) * 100,
                    "framesAtPaper": Double(shares(score, c).filter { $0 > 0 }.count),
                    "controlFramesAtPaper": Double(shares(control, c).filter { $0 > 0 }.count)]
        }
        let rise = rises(primary)
        let g5 = Detail(frames: rise.count, meanRise: G.mean(rise.map(\.1)), maxRise: rise.map(\.1).max() ?? .nan,
                        controlMeanShare: G.mean(shares(control, nil)) * 100,
                        framesLost: shares(score, nil).filter { $0 > 0 }.count, controlFramesLost: shares(control, nil).filter { $0 > 0 }.count,
                        worst: rise.sorted { $0.1 > $1.1 }.prefix(5).map { "\($0.0) \(String(format: "%+.2f", $0.1))" },
                        bySource: Dictionary(uniqueKeysWithValues: Source.allCases.map { ($0.rawValue, spread(rises(primary, $0))) }),
                        byStock: Dictionary(uniqueKeysWithValues: stocks.map { ($0.id, spread(rises($0.id))) }),
                        lightness: diagnostic(0), stockBlack: diagnostic(1))

        let removals = score.removals.sorted()
        let g6 = score.stability
            ? Stability(removals: removals.count, p95: quantile(removals, 0.95), max: removals.last ?? .nan,
                        pooledP95: quantile(score.movements.sorted(), 0.95), listed: score.listed.sorted { $0.stops > $1.stops })
            : nil

        var identical = true
        for (stock, run) in score.runs {
            for scenario in Scenario.allCases where zip(run.results[scenario]!, control.runs[stock]!.results[scenario]!).contains(where: { $0.aims != $1.aims }) {
                identical = false
            }
        }

        var gates: [Verdict] = []
        if score.configuration != .control {
            let a = g1.all
            gates = [
                Verdict(gate: "G1", pass: a.ratio <= Threshold.ratio && a.upperBound < 1,
                        detail: String(format: "ratio %.3f (≤ %.2f), bound %.3f (< 1)", a.ratio, Threshold.ratio, a.upperBound)),
                Verdict(gate: "G2", pass: g2.worseStocks.isEmpty && abs(g2.meanSignedChange) <= Threshold.meanChange && g2.unlinkedMoved == 0,
                        detail: String(format: "%ld of %ld stocks worse, mean change %+.2f L* (±%.1f), %ld of %ld unlinked frames moved",
                                       g2.worseStocks.count, stocks.count, g2.meanSignedChange, Threshold.meanChange, g2.unlinkedMoved,
                                       g2.unlinkedFrames)),
                Verdict(gate: "G3", pass: g3.share <= Threshold.falseLinks && g3.medianChange >= Threshold.flattening,
                        detail: String(format: "%.1f%% linked (≤ %.0f%%), median change %+.2f L* (≥ %.1f); %.1f%% joined through links",
                                       g3.share * 100, Threshold.falseLinks * 100, g3.medianChange, Threshold.flattening, g3.joinedShare * 100)),
                Verdict(gate: "G4", pass: g4.p90 <= g4.controlP90 && g4.max <= g4.controlMax + Threshold.faceWorst,
                        detail: String(format: "p90 %.2f (control %.2f), worst %.2f (control %.2f + %.1f)",
                                       g4.p90, g4.controlP90, g4.max, g4.controlMax, Threshold.faceWorst)),
                Verdict(gate: "G5", pass: g5.meanRise <= Threshold.paperMean && g5.maxRise <= Threshold.paperFrame,
                        detail: String(format: "mean rise %+.3f points (≤ %.1f), largest %+.2f (≤ %.0f)",
                                       g5.meanRise, Threshold.paperMean, g5.maxRise, Threshold.paperFrame)),
                Verdict(gate: "G6", pass: g6.map { $0.p95 <= Threshold.stability },
                        detail: g6.map { String(format: "p95 %.3f stop (≤ %.1f), %ld movements over %.2f", $0.p95, Threshold.stability,
                                                $0.listed.count, Threshold.listed) } ?? "not computed (ARGENT_SEQUENCE_G6)"),
                Verdict(gate: "G7", pass: score.cost.map { $0.largestPerFrame < Threshold.milliseconds && $0.syntheticPerFrame < Threshold.milliseconds
                            && $0.syntheticMegabytes < Threshold.megabytes },
                        detail: score.cost.map { String(format: "%.3f ms a frame (largest session), %.3f (340 frames), %.2f MB", $0.largestPerFrame,
                                                        $0.syntheticPerFrame, $0.syntheticMegabytes) } ?? "not computed (ARGENT_SEQUENCE_G7)"),
            ]
        }

        let run = score.runs[primary]!
        var links: [LinkRecord] = [], frames: [FrameRecord] = []
        for (s, session) in bench.sessions[.asShot]!.enumerated() {
            let result = run.results[.asShot]![s]
            for link in result.links {
                links.append(LinkRecord(session: session.unit, from: session.items[link.earlier].name, to: session.items[link.later].name,
                                        shift: Double(link.shift), lightChange: link.lightChange.map(Double.init),
                                        confidence: Double(link.confidence), overlap: Double(link.overlap),
                                        correlation: Double(link.correlation), samples: link.weights.count))
            }
            let reached = Set(run.edges[.asShot]![s].flatMap { [$0.a, $0.b] })
            for (k, item) in session.items.enumerated() {
                frames.append(FrameRecord(name: item.name, session: session.unit, own: Double(AutoPrint.levelStops(item.analysis)),
                                          level: Double(result.aims[item.frame.url]?.level ?? .nan), linked: reached.contains(k)))
            }
        }
        return ConfigurationResult(name: score.configuration.name, method: score.configuration.method.rawValue,
                                   parameters: score.configuration.parameters, identicalToControl: identical,
                                   g1: g1, g2: g2, g3: g3, g4: g4, g5: g5, g6: g6, g7: score.cost, gates: gates,
                                   agreement: score.agreement, seconds: score.seconds, timings: score.timings, links: links, frames: frames)
    }

    // MARK: The run

    struct Results: Codable {
        var created: String
        var split: String
        var protocolSHA256: String
        var configurationsSHA256: String
        var configurationsPath: String
        var counts: Counts
        /// The stocks scored, Portra 400 first, and the configurations whose G6 and agreement with
        /// full renders were computed (`Options`).
        var stocks: [String]
        var stability: [String]
        var cost: [String]
        var agreement: [String]
        /// Each stock's paper black and white, L* of its Print LUT at no dye and at full dye amounts.
        var paper: [String: [Double]]
        var conventions: [String]
        var timings: [String: Double]
        /// The pairs matched, and each evidence setting's check against `SequenceEvidence.links`, in seconds.
        var pairsMatched: Int
        var evidenceChecks: [String: Double]
        var configurations: [ConfigurationResult]
    }

    /// How the pre-registration's words are read where it leaves a choice (reported with every run).
    static let conventions = [
        "Quantiles take the value at floor(q·n) of the sorted values (SeriesMeasureTests.spread); the bootstrap bound is that 95th percentile of the p90 ratio over 2,000 resamples of the split's units (sessions, or the raw.pixls.us event) with replacement, SplitMix64 seeded 20261022, the same resamples for every configuration; a resample holding no pair of the set is left out and counted.",
        "Region ΔL* is the later frame's region less the earlier's; G1 reads its magnitude. Coverage counts a pair of P linked only when one of Result.links joins its two frames directly.",
        "Cube++ region: the mean light of the cube's two gray faces in the decode (their colour kept, so Auto filtration acts on it), scaled with the scenario's exposure, printed on the CPU through the stock's two LUTs at the frame's aim with RollControls(labBalance: .auto) at box speed.",
        "a7 IV region: the 960-pixel sheet decode rendered by FilmRenderer with DevelopmentResolver.resolve at the frame's aim, Auto at box speed (not the owner's recipe), grain 0, halation and sharpening on; median per-pixel L* over the box shrunk by a tenth of its size on each side, pixel edges rounded.",
        "Every method is resolved on each stock (the input carries the stock); G1's gate, G3 to G7 read Portra 400, G2 reads all six (the stocks scored, when a development run names fewer).",
        "A candidate's links are SequenceEvidence's: each pair of a session's frames is matched once for each setting of the evidence's parameters (SequenceEvidence.link) and kept, each session's links put together from the pairs as SequenceEvidence.links walks them, and checked to be SequenceEvidence.links' bit for bit on every session of both scenarios once for each setting and neighbours; levels come from SequenceAims.resolve(_:links:method:parameters:), checked against the public SequenceAims.resolve on the three sessions with the most links for each configuration.",
        "G2's mean signed change is over both regions of every pair of P. The isolated-frame check covers every frame no link reaches, every stock and scenario; it binds the candidates, and control's count is reported for reference.",
        "G3: Cube++ pairs are each frame with its next and next-but-one of the same body within 600 s whose cube says changed light, in the split; a7 IV boundaries are those in the split with confidence ≥ 0.6, a boundary across two sessions counting as not linked; the median change is over Cube++'s pairs only. The gate counts direct links; pairs whose frames share a component of the result's links (SequenceAims.groups) are reported beside it (amendment 5).",
        "G4: the face boxes move by 5 % of their size to the right and down and grow 15 % about their middle, keeping Vision's confidence; whole-frame L* is the mean over descriptor cells holding light (not zero), Cube++'s cells touched by the cube's mask left out (amendment 4), printed on the CPU at each frame's aim.",
        "G5 (amendment 1): a matte point loses its detail when its dye amounts plus the print offset leave 0…1 in any channel at the frame's aim (synthetic_print.py's printClipped), on the CPU: the Negative LUT at the rating's exposure and DevelopSettings.printOffset of RollControls(labBalance: .auto) at the frame's PrintAim, as SequenceAims.Response prints. a7 IV matte points are every second pixel each way of the 960-pixel decode that is unclipped by ExposureAnalyzer's rule and over its floor (−5 stops); Cube++'s are descriptor cells with unclipped ≥ 0.99 holding light and no cell of the cube's mask (amendment 4). Rises are candidate less control per frame, in points. The L* thresholds first named (99 and 1, and black within 0.5 L* of the stock's own paper black), on every matte pixel of the a7 IV renders and on the same Cube++ cells, are reported beside the gate, not gated.",
        "G6: each removal's largest movement among the session's other frames, then the p95 over removals (amendment 5); sessions of one frame are skipped. The session without the frame is resolved on its links put together from the kept pairs, those a removal brings within reach matched too, and checked against the public SequenceAims.resolve without the middle frame of the three sessions with the most links.",
        "Agreement with full renders (development only, not gated): on each a7 IV link, Portra 400 as shot, the CPU response lightness of the matched points B prints (SequenceAims.Response at each frame's solved level, weighted as the link weighs them) against the render's mean L* over the same points: in the frame the matcher walked, the descriptor cell the point was read from; in the other, that cell's square as the alignment lands it; each area's analysis grid cells weighted by their pixels and the share covered. Points are found again from the match of the two frames, bit for bit.",
        "G7: the median of five timed resolves after one to warm, divided by the frames; memory counts descriptors (their arrays) and links (samples and weights).",
    ]

    @Test(.enabled(if: FrameViewMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_SEQUENCE_CONFIGS"] != nil))
    func benchmark() throws {
        let environment = ProcessInfo.processInfo.environment
        let clock = ContinuousClock(), started = clock.now
        var timings: [String: Double] = [:]

        // 1. The frozen protocol, the configurations and the split they may score.
        let protocolURL = URL(fileURLWithPath: environment["ARGENT_SEQUENCE_PROTOCOL"]
                              ?? Self.evidence.appendingPathComponent("benchmark/protocol.json").path)
        let protocolData = try Data(contentsOf: protocolURL)
        try #require(Self.sha256(protocolData) == Self.protocolSHA256, "\(protocolURL.path) is not the frozen protocol")
        let file = try JSONDecoder().decode(ProtocolFile.self, from: protocolData)
        try #require(file.version == 1)
        let configsURL = URL(fileURLWithPath: try #require(environment["ARGENT_SEQUENCE_CONFIGS"]))
        let configsData = try Data(contentsOf: configsURL)
        let split = try Self.split(environment["ARGENT_SEQUENCE_SPLIT"], configs: configsData, configsPath: configsURL.canonicalPath,
                                   frozen: environment["ARGENT_SEQUENCE_FROZEN"],
                                   frozenFolder: Self.evidence.appendingPathComponent("benchmark/frozen").canonicalPath)
        let configurations = try Self.configurations(configsData)
        if split == .test { try Self.frozenCandidates(configurations) }
        try #require(L.cellGrids, "ARGENT_CUBEPP_GRID=cells: Cube++ is measured on the cache's cell grids")
        let cohort = try #require(environment["ARGENT_CUBEPP_COHORT"], "ARGENT_CUBEPP_COHORT names the 2,234-frame cohort")
        try #require(cohort.canonicalPath == M.root.appendingPathComponent("docs/research/auto/gate-protocol/cubepp-cohort-2234.txt").canonicalPath,
                     "ARGENT_CUBEPP_COHORT is docs/research/auto/gate-protocol/cubepp-cohort-2234.txt")
        let library = StockLibrary.load(from: M.root.appendingPathComponent("build/stocks")).stocks
        try #require(library.count == 6 && library.first?.id == Self.primaryStock, "the six stocks are baked, Portra 400 first")
        let options = try Self.options(environment, split: split, configurations: configurations.map(\.name), stocks: library.map(\.id))
        let stocks = library.filter { options.stocks.contains($0.id) }
        // The run's folder last, once nothing else can refuse it: a test run made is the test split's one.
        let runs = Self.evidence.appendingPathComponent("benchmark/runs").canonicalPath
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: runs)) ?? []
        let out = try Self.outputFolder(try Self.runFolder(split, requested: environment["ARGENT_SEQUENCE_OUT"],
                                                           configsSHA256: Self.sha256(configsData), runs: runs, existing: existing))
        print("SEQUENCE \(split.rawValue) split, \(configurations.count) configurations: \(configurations.map(\.name).joined(separator: ", ")); "
              + "stocks \(options.stocks.joined(separator: ", ")); G6 for \(options.stability.sorted()); agreement for \(options.agreement.sorted())")

        // 2. The split's data, once.
        let units = file.units.filter { $0.value == split.rawValue }.keys.sorted()
        let unitIndex = Dictionary(uniqueKeysWithValues: units.enumerated().map { ($1, $0) })
        var mark = clock.now
        let cube = try Self.cubepp(file, split: split, unitIndex: unitIndex)
        timings["cubeppLoad"] = M.ms(clock.now - mark) / 1000
        mark = clock.now
        let renders = try Renders(stocks: stocks, cache: Self.evidence.appendingPathComponent("benchmark/cache"))
        let a7 = try Self.a7iv(file, split: split, unitIndex: unitIndex, renders: renders, firstSession: cube.sessions[.asShot]!.count)
        timings["a7ivLoad"] = M.ms(clock.now - mark) / 1000
        timings["a7ivDecodes"] = Double(renders.decodes)
        let asShot = cube.sessions[.asShot]! + a7.sessions
        let bench = Benchmark(
            split: split, units: units, draws: Self.draws(units: units.count, count: Self.resampleCount, seed: Self.seed),
            sessions: [.asShot: asShot, .oneExposure: cube.sessions[.oneExposure]!],
            a7: cube.sessions[.asShot]!.count..<asShot.count,
            primary: [.asShot: cube.primary + a7.primary, .oneExposure: cube.primary],
            changed: [.asShot: cube.changed, .oneExposure: cube.changed], boundaries: a7.boundaries,
            fixedContent: try Self.fixedContent(asShot),
            counts: Counts(
                primary: Dictionary(uniqueKeysWithValues: Split.allCases.map { s in
                    let c = cube.counted[s]!, owner = a7.counted[s]![.owner]!, corpora = a7.counted[s]![.corpora]!
                    return (s.rawValue, ["cubepp": c, "owner": owner, "corpora": corpora, "all": c + owner + corpora])
                }),
                cubeppSameSubject: Dictionary(uniqueKeysWithValues: Split.allCases.map { ($0.rawValue, cube.sameSubject[$0]!) }),
                a7ivOtherSurface: Dictionary(uniqueKeysWithValues: Split.allCases.map { ($0.rawValue, a7.otherSurface[$0]!) }),
                units: units.count, sessions: asShot.count,
                frames: Dictionary(uniqueKeysWithValues: Source.allCases.map { source in
                    (source.rawValue, asShot.flatMap(\.items).filter { $0.source == source }.count)
                }),
                changedLight: cube.changed.count, boundaries: a7.boundaries.count,
                faceFrames: asShot.flatMap(\.items).filter { $0.withoutFaces != nil }.count, decoderRoute: "\(renders.choices.route)"))
        try #require(Set(asShot.map(\.unit)) == Set(units), "every unit of the split is a session")
        print("SEQUENCE \(bench.counts.sessions) sessions, frames \(bench.counts.frames), P \(bench.primary[.asShot]!.count), "
              + "changed light \(bench.counts.changedLight), boundaries \(bench.counts.boundaries), face frames \(bench.counts.faceFrames)")

        // 3. Each configuration, then each against control.
        let memo = Memo(), evidence = Evidence()
        var scores: [Score] = []
        for configuration in configurations {
            let rendersBefore = renders.renderTime
            let score = try autoreleasepool { try Self.score(configuration, bench, stocks: stocks, renders: renders, memo: memo, evidence: evidence,
                                                             options: options) }
            scores.append(score)
            timings["render \(configuration.name)"] = M.ms(renders.renderTime - rendersBefore) / 1000
            timings["score \(configuration.name)"] = score.seconds
            print("SEQUENCE scored \(configuration.name) in \(String(format: "%.1f", score.seconds)) s: "
                  + score.timings.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.1f", $0.value))" }.joined(separator: ", "))
        }
        timings["renders"] = Double(renders.renders)
        let results = scores.map { Self.result($0, against: scores[0], bench, stocks: stocks) }
        timings["total"] = M.ms(clock.now - started) / 1000

        // 4. What was found, outside the repository.
        let formatter = ISO8601DateFormatter()
        let report = Results(created: formatter.string(from: Date()), split: split.rawValue, protocolSHA256: Self.protocolSHA256,
                             configurationsSHA256: Self.sha256(configsData), configurationsPath: configsURL.canonicalPath,
                             counts: bench.counts, stocks: options.stocks,
                             stability: configurations.map(\.name).filter(options.stability.contains),
                             cost: configurations.map(\.name).filter(options.cost.contains),
                             agreement: configurations.map(\.name).filter(options.agreement.contains),
                             paper: Dictionary(uniqueKeysWithValues: stocks.map { ($0.id, [Self.paper($0, white: false), Self.paper($0, white: true)]) }),
                             conventions: Self.conventions, timings: timings, pairsMatched: evidence.matched,
                             evidenceChecks: evidence.checks, configurations: results)
        try D.encoder.encode(report).write(to: out.appendingPathComponent("results.json"))
        try Self.csv(scores, bench, stocks: stocks).write(to: out.appendingPathComponent("pairs.csv"), atomically: true, encoding: .utf8)
        let summary = Self.summary(report, stocks: stocks)
        try summary.write(to: out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        print(summary)
    }

    // MARK: Output

    static func csv(_ scores: [Score], _ bench: Benchmark, stocks: [Stock]) -> String {
        var lines = ["configuration,stock,scenario,set,pair,source,scene,unit,from,to,levelFrom,levelTo,lightnessFrom,lightnessTo,deltaLightness,linked"]
        for score in scores {
            for stock in stocks {
                for scenario in Scenario.allCases {
                    for (set, pairs, scored) in [("P", bench.primary[scenario]!, score.primary[stock.id]![scenario]!),
                                                 ("changed", bench.changed[scenario]!, score.changed[stock.id]![scenario]!)] {
                        for (pair, s) in zip(pairs, scored) {
                            let session = bench.sessions[scenario]![pair.session]
                            lines.append([score.configuration.name, stock.id, scenario.rawValue, set, pair.id, pair.source.rawValue, pair.scene,
                                          session.unit, session.items[pair.a].name, session.items[pair.b].name,
                                          String(format: "%.5f", s.levels[0]), String(format: "%.5f", s.levels[1]),
                                          String(format: "%.3f", s.lightness[0]), String(format: "%.3f", s.lightness[1]),
                                          String(format: "%.3f", s.delta), "\(s.linked)"].joined(separator: ","))
                        }
                    }
                }
            }
            for (boundary, linked) in zip(bench.boundaries, score.boundaries) {
                let a = bench.sessions[.asShot]![boundary.a.session], b = bench.sessions[.asShot]![boundary.b.session]
                lines.append([score.configuration.name, stocks[0].id, Scenario.asShot.rawValue, "boundary", boundary.id, "", "", a.unit,
                              a.items[boundary.a.item].name, b.items[boundary.b.item].name, "", "", "", "", "", "\(linked)"].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The parts of a configuration's wall time, in the order `score` runs them.
    static let timingParts = ["links", "resolve", "renders", "detail", "faces", "stability", "agreement", "cost"]

    static func n(_ x: Double, _ digits: Int = 2) -> String { x.isFinite ? String(format: "%.\(digits)f", x) : "–" }

    static func summary(_ report: Results, stocks: [Stock]) -> String {
        let results = report.configurations, control = results[0]
        let names = Dictionary(uniqueKeysWithValues: stocks.map { ($0.id, $0.displayName) })
        var md = "# Sequence benchmark, \(report.split) split\n\n"
        md += "\(report.created). Protocol `\(report.protocolSHA256.prefix(12))…`, configurations `\(report.configurationsSHA256.prefix(12))…` "
        md += "(`\(report.configurationsPath)`), decoder route \(report.counts.decoderRoute). Portra 400 and as shot unless stated; "
        md += "region ΔL* between the two frames of a pair (docs/research/auto/sequence-consistency.md, sections 2 and 3, as amended).\n\n"
        if report.stocks.count < 6 || report.stability.count < results.count || report.cost.count < results.count {
            md += "**A partial development run:** stocks \(report.stocks.joined(separator: ", ")); G6 computed for "
            md += report.stability.isEmpty ? "none" : report.stability.joined(separator: ", ")
            md += "; G7 for " + (report.cost.isEmpty ? "none" : report.cost.joined(separator: ", ")) + ".\n\n"
        }

        md += "## The primary set P\n\n| split | Cube++ | owner | corpora | all | Cube++ labelled same | a7 IV other surface |\n|---|---|---|---|---|---|---|\n"
        for split in Split.allCases {
            let p = report.counts.primary[split.rawValue]!
            md += "| \(split.rawValue) | \(p["cubepp"]!) | \(p["owner"]!) | \(p["corpora"]!) | \(p["all"]!) | "
            md += "\(report.counts.cubeppSameSubject[split.rawValue]!) | \(report.counts.a7ivOtherSurface[split.rawValue]!) |\n"
        }
        let c = report.counts
        md += "\nThis split: \(c.units) units, \(c.sessions) sessions; frames Cube++ \(c.frames["cubepp"]!), owner \(c.frames["owner"]!), "
        md += "corpora \(c.frames["corpora"]!); \(c.changedLight) Cube++ changed-light pairs, \(c.boundaries) a7 IV boundaries (confidence ≥ 0.6), "
        md += "\(c.faceFrames) frames with faces.\n\n"

        func row(_ name: String, _ x: Consistency) -> String {
            "| \(name) | \(x.n) | \(n(x.median)) | \(n(x.p90)) | \(n(x.max)) | \(n(x.ratio, 3)) | \(n(x.upperBound, 3)) | "
                + "\(n(x.coverage * 100, 1))% | \(x.p90 <= Threshold.target ? "yes" : "no") |\n"
        }
        let header = "| configuration | n | median | p90 | max | p90 / control's | 95 % bound | coverage | p90 ≤ 3 |\n|---|---|---|---|---|---|---|---|---|\n"
        md += "## G1 consistency\n\n" + header
        for r in results { md += row(r.name, r.g1.all) }
        md += "\nControl: median \(n(control.g1.all.median)), p90 \(n(control.g1.all.p90)), max \(n(control.g1.all.max)) L*.\n"
        md += "\n### By source\n\n" + header.replacingOccurrences(of: "| configuration |", with: "| configuration, source |")
        for r in results {
            for source in Source.allCases { md += row("\(r.name), \(source.rawValue)", r.g1.bySource[source.rawValue]!) }
        }
        md += "\n### By scene type\n\n" + header.replacingOccurrences(of: "| configuration |", with: "| configuration, scene |")
        for r in results {
            for scene in r.g1.byScene.keys.sorted() { md += row("\(r.name), \(scene)", r.g1.byScene[scene]!) }
        }
        md += "\n### Cube++ with one exposure per scene (secondary)\n\n" + header
        for r in results { md += row(r.name, r.g1.oneExposure) }

        md += "\n## G2 placement\n\np90 region |ΔL*| on P by stock (control's in brackets); mean signed region change against control; "
        md += "frames no link reaches that are off `AutoPrint.levelStops`, over every stock and scenario.\n\n"
        md += "| configuration | " + stocks.map { names[$0.id]! }.joined(separator: " | ") + " | worse | mean change | unlinked moved |\n"
        md += "|---|" + String(repeating: "---|", count: stocks.count + 3) + "\n"
        for r in results {
            md += "| \(r.name) | " + stocks.map { "\(n(r.g2.p90ByStock[$0.id]!)) (\(n(r.g2.controlP90ByStock[$0.id]!)))" }.joined(separator: " | ")
            md += " | \(r.g2.worseStocks.count) | \(String(format: "%+.2f", r.g2.meanSignedChange)) | \(r.g2.unlinkedMoved) of \(r.g2.unlinkedFrames) |\n"
        }

        md += "\n## G3 real light\n\nThe gate counts direct links; beside it, the pairs whose frames a chain of links joins (amendment 5).\n\n"
        md += "| configuration | Cube++ changed linked | boundaries linked | share | median change of \\|ΔL*\\| | one exposure: linked, median change "
        md += "| joined: Cube++, boundaries, share | one exposure joined |\n|---|---|---|---|---|---|---|---|\n"
        for r in results {
            let g = r.g3
            md += "| \(r.name) | \(g.cubeppLinked) of \(g.cubeppChanged) | \(g.boundariesLinked) of \(g.boundaries) | \(n(g.share * 100, 1))% | "
            md += "\(String(format: "%+.2f", g.medianChange)) | \(g.oneExposureLinked), \(String(format: "%+.2f", g.oneExposureMedianChange)) | "
            md += "\(g.cubeppJoined), \(g.boundariesJoined), \(n(g.joinedShare * 100, 1))% | \(g.oneExposureJoined) |\n"
        }

        md += "\n## G4 faces on fixed content\n\nLargest whole-frame L* step between neighbours of [f, f′, f].\n\n"
        md += "| configuration | rolls | median | p90 | max | control p90 | control max |\n|---|---|---|---|---|---|---|\n"
        for r in results {
            let g = r.g4
            md += "| \(r.name) | \(g.rolls) | \(n(g.median)) | \(n(g.p90)) | \(n(g.max)) | \(n(g.controlP90)) | \(n(g.controlMax)) |\n"
        }
        if let worst = control.g4.worst.first {
            md += "\nControl's worst: \(worst.frame) (\(worst.variant)), \(n(worst.jump)) L*, levels \(worst.levels.map { n($0, 3) }.joined(separator: ", ")).\n"
        }

        md += "\n## G5 detail\n\nShare of matte points, a7 IV decode pixels (every second each way) or Cube++ cells, whose print leaves the "
        md += "Print LUT's domain (dye amounts plus the print offset outside 0…1 in a channel, amendment 1), candidate less control, in points.\n\n"
        md += "| configuration | frames | mean rise | largest rise | control's mean share | frames losing detail (control's) | worst |\n"
        md += "|---|---|---|---|---|---|---|\n"
        for r in results {
            md += "| \(r.name) | \(r.g5.frames) | \(String(format: "%+.3f", r.g5.meanRise)) | \(String(format: "%+.2f", r.g5.maxRise)) | "
            md += "\(n(r.g5.controlMeanShare, 4)) | \(r.g5.framesLost) (\(r.g5.controlFramesLost)) | \(r.g5.worst.prefix(3).joined(separator: "; ")) |\n"
        }
        md += "\nBy source and stock, mean and largest rise:\n\n| configuration | " + Source.allCases.map(\.rawValue).joined(separator: " | ") + " | "
        md += stocks.map { names[$0.id]! }.joined(separator: " | ") + " |\n|---|" + String(repeating: "---|", count: Source.allCases.count + stocks.count) + "\n"
        for r in results {
            let cells = Source.allCases.map { r.g5.bySource[$0.rawValue]! } + stocks.map { r.g5.byStock[$0.id]! }
            md += "| \(r.name) | " + cells.map { "\(String(format: "%+.3f", $0[0])), \(String(format: "%+.2f", $0[1]))" }.joined(separator: " | ") + " |\n"
        }
        md += "\nNot gated: the L* thresholds G5 first named, paper white (L* ≥ \(n(Threshold.paperWhite, 0))) or black "
        md += "(L* ≤ \(n(Threshold.paperBlack, 0))), on every matte pixel of the a7 IV renders and the same Cube++ cells; and with black within "
        md += "\(n(Threshold.stockBlackMargin, 1)) L* of the stock's own paper black. The stocks' paper black and white: "
        md += stocks.map { "\(names[$0.id]!) \(n(report.paper[$0.id]![0], 2)) and \(n(report.paper[$0.id]![1], 2))" }.joined(separator: ", ") + " L*.\n\n"
        md += "| configuration | thresholds | mean rise | largest rise | control's mean share | frames at paper (control's) |\n|---|---|---|---|---|---|\n"
        for r in results {
            for (label, b) in [("L* 99 and 1", r.g5.lightness), ("stock's black", r.g5.stockBlack)] {
                md += "| \(r.name) | \(label) | \(String(format: "%+.3f", b["meanRise"]!)) | \(String(format: "%+.2f", b["maxRise"]!)) | "
                md += "\(n(b["controlMeanShare"]!, 4)) | \(Int(b["framesAtPaper"]!)) (\(Int(b["controlFramesAtPaper"]!))) |\n"
            }
        }

        md += "\n## G6 stability\n\nForced leave-one-out in every session: each removal's largest movement among the other frames, in stops.\n\n"
        md += "| configuration | removals | p95 | max | pooled p95 | over 0.25 |\n|---|---|---|---|---|---|\n"
        for r in results {
            guard let g = r.g6 else {
                md += "| \(r.name) | not computed | | | | |\n"
                continue
            }
            md += "| \(r.name) | \(g.removals) | \(n(g.p95, 3)) | \(n(g.max, 3)) | \(n(g.pooledP95, 3)) | \(g.listed.count) |\n"
        }
        for r in results {
            guard let g = r.g6, !g.listed.isEmpty else { continue }
            md += "\n\(r.name), movements over \(Threshold.listed) stop: "
            md += g.listed.prefix(40).map { "\($0.removed) → \($0.moved) \(n($0.stops, 3))" }.joined(separator: "; ")
            md += g.listed.count > 40 ? "; … (\(g.listed.count) in all, results.json)\n" : "\n"
        }

        md += "\n## G7 cost\n\nRelease build, Portra 400.\n\n| configuration | largest session | ms a frame | 340-frame roll ms a frame | MB held | links |\n"
        md += "|---|---|---|---|---|---|\n"
        for r in results {
            guard let g = r.g7 else {
                md += "| \(r.name) | not computed | | | | |\n"
                continue
            }
            md += "| \(r.name) | \(g.largestSession) (\(g.largestFrames)) | \(n(g.largestPerFrame, 4)) | \(n(g.syntheticPerFrame, 4)) | "
            md += "\(n(g.syntheticMegabytes, 2)) | \(g.syntheticLinks) |\n"
        }

        md += "\n## Gates\n\n| configuration | identical to control | " + (1...7).map { "G\($0)" }.joined(separator: " | ") + " |\n"
        md += "|---|---|" + String(repeating: "---|", count: 7) + "\n"
        for r in results.dropFirst() {
            md += "| \(r.name) | \(r.identicalToControl ? "yes" : "no") | "
            md += r.gates.map { $0.pass.map { $0 ? "pass" : "fail" } ?? "–" }.joined(separator: " | ") + " |\n"
        }
        for r in results.dropFirst() {
            md += "\n\(r.name): " + r.gates.map { "\($0.gate) \($0.detail)" }.joined(separator: "; ") + ".\n"
        }

        let checked = results.filter { $0.agreement != nil }
        if !checked.isEmpty {
            md += "\n## Agreement with full renders (development diagnostic)\n\nEach a7 IV link's matched points, Portra 400 as shot: the CPU "
            md += "response's mean L* at each frame's solved level against the full render's over the same points' areas, |CPU − render| in L*.\n\n"
            md += "| configuration | links | points (not found again) | frame: median, p90, max | frame: mean CPU − render | "
            md += "between the frames: median, p90, max | between: mean | median \\|Δ\\| CPU, render |\n|---|---|---|---|---|---|---|---|\n"
            for r in checked {
                let a = r.agreement!
                md += "| \(r.name) | \(a.links) | \(a.points) (\(a.unplaced)) | \(n(a.frameMedian)), \(n(a.frameP90)), \(n(a.frameMax)) | "
                md += "\(String(format: "%+.2f", a.frameMeanSigned)) | \(n(a.linkMedian)), \(n(a.linkP90)), \(n(a.linkMax)) | "
                md += "\(String(format: "%+.2f", a.linkMeanSigned)) | \(n(a.cpuDifference)), \(n(a.renderDifference)) |\n"
            }
        }

        md += "\n## Wall time (s)\n\n| configuration | all | " + timingParts.joined(separator: " | ") + " |\n|---|---|"
        md += String(repeating: "---|", count: timingParts.count) + "\n"
        for r in results {
            md += "| \(r.name) | \(n(r.seconds, 1)) | " + timingParts.map { n(r.timings[$0] ?? 0, 1) }.joined(separator: " | ") + " |\n"
        }
        md += "\nPairs matched \(report.pairsMatched); each evidence setting checked against SequenceEvidence.links once: "
        md += report.evidenceChecks.sorted { $0.key < $1.key }.map { "\($0.key) in \(n($0.value, 1)) s" }.joined(separator: "; ") + ".\n"

        md += "\n## Conventions\n\n" + report.conventions.map { "- \($0)\n" }.joined()
        md += "\n## Timings (s)\n\n" + report.timings.sorted { $0.key < $1.key }.map { "- \($0.key): \(n($0.value, 1))\n" }.joined()
        return md
    }
}

/// The test split's guards (`SequenceBenchmarkMeasureTests.split`, `frozenCandidates`, `runFolder`,
/// `options`), which need no data.
@Suite struct SequenceBenchmarkGuardTests {
    typealias B = SequenceBenchmarkMeasureTests

    let configs = Data(#"[{"name": "render", "method": "render", "parameters": {"matchWeight": 2}}]"#.utf8)
    let frozen = "/research/benchmark/frozen"

    @Test func theDevelopmentSplitIsTheDefault() throws {
        #expect(try B.split(nil, configs: configs, configsPath: "/anywhere/configs.json", frozen: nil, frozenFolder: frozen) == .dev)
        #expect(try B.split("dev", configs: configs, configsPath: "/anywhere/configs.json", frozen: nil, frozenFolder: frozen) == .dev)
    }

    @Test func theTestSplitNeedsTheFrozenConfigurations() throws {
        let path = frozen + "/render.json", digest = B.sha256(configs)
        func split(_ requested: String?, path: String = "/research/benchmark/frozen/render.json", hash: String?) throws -> B.Split {
            try B.split(requested, configs: configs, configsPath: path, frozen: hash, frozenFolder: frozen)
        }
        // Without the hash, with an empty or a wrong one, or with the hash of other bytes.
        #expect(throws: B.Refusal.self) { try split("test", hash: nil) }
        #expect(throws: B.Refusal.self) { try split("test", hash: "") }
        #expect(throws: B.Refusal.self) { try split("test", hash: String(repeating: "0", count: 64)) }
        #expect(throws: B.Refusal.self) { try split("test", hash: B.sha256(configs + Data("\n".utf8))) }
        // The right hash, but the file is not under the frozen folder.
        #expect(throws: B.Refusal.self) { try split("test", path: "/research/benchmark/render.json", hash: digest) }
        #expect(throws: B.Refusal.self) { try split("test", path: frozen + "/../render.json", hash: digest) }
        #expect(throws: B.Refusal.self) { try split("test", path: frozen + "-draft/render.json", hash: digest) }
        #expect(throws: B.Refusal.self) { try split("test", path: frozen, hash: digest) }
        // A split that is neither.
        for requested in ["Test", "TEST", "", "all", "test "] {
            #expect(throws: B.Refusal.self) { try split(requested, hash: digest) }
        }
        #expect(try split("test", path: path, hash: digest) == .test)
        #expect(try split("test", path: path, hash: digest.uppercased()) == .test)
    }

    @Test func theTestSplitScoresOnlyTheFrozenCandidates() throws {
        var ablation = SequenceAims.Parameters.frozenRender
        ablation.faceReliability = true
        let a = B.Configuration(name: "A", method: .smoothing, parameters: .frozenSmoothing)
        let b = B.Configuration(name: "B", method: .render, parameters: .frozenRender)
        let r = B.Configuration(name: "R", method: .render, parameters: ablation)
        try B.frozenCandidates([.control, a, b])
        try B.frozenCandidates([.control, a, b, r])
        try B.frozenCandidates([.control, b, r, a])
        // A missing candidate, one too many, a name used twice, or control left out.
        #expect(throws: B.Refusal.self) { try B.frozenCandidates([.control, a]) }
        #expect(throws: B.Refusal.self) { try B.frozenCandidates([.control, b, r]) }
        #expect(throws: B.Refusal.self) { try B.frozenCandidates([.control, a, b, r, B.Configuration(name: "C", method: .render)]) }
        #expect(throws: B.Refusal.self) { try B.frozenCandidates([.control, a, b, b]) }
        #expect(throws: B.Refusal.self) { try B.frozenCandidates([a, b]) }
        // Constants that are not the frozen ones, or the wrong method under a candidate's name.
        var moved = SequenceAims.Parameters.frozenRender
        moved.matchWeight += 1
        #expect(throws: B.Refusal.self) { try B.frozenCandidates([.control, a, B.Configuration(name: "B", method: .render, parameters: moved)]) }
        var linked = SequenceAims.Parameters.frozenSmoothing
        linked.neighbours += 1
        #expect(throws: B.Refusal.self) { try B.frozenCandidates([.control, B.Configuration(name: "A", method: .smoothing, parameters: linked), b]) }
        #expect(throws: B.Refusal.self) { try B.frozenCandidates([.control, B.Configuration(name: "A", method: .render, parameters: .frozenSmoothing), b]) }
        #expect(throws: B.Refusal.self) { try B.frozenCandidates([.control, a, b, B.Configuration(name: "R", method: .render, parameters: .frozenRender)]) }
    }

    @Test func theTestSplitIsScoredOnce() throws {
        let runs = "/research/benchmark/runs", digest = B.sha256(configs), name = "test-" + digest.prefix(12)
        func folder(_ split: B.Split, _ requested: String?, existing: [String] = ["dev-01", "tune-04-frozen"]) throws -> String {
            try B.runFolder(split, requested: requested, configsSHA256: digest, runs: runs, existing: existing)
        }
        #expect(try folder(.test, nil) == runs + "/" + name)
        #expect(try folder(.test, runs + "/" + name) == runs + "/" + name)
        #expect(try B.runFolder(.test, requested: nil, configsSHA256: digest.uppercased(), runs: runs, existing: []) == runs + "/" + name)
        // A second test run, of this frozen file or of any other.
        #expect(throws: B.Refusal.self) { try folder(.test, nil, existing: [name]) }
        #expect(throws: B.Refusal.self) { try folder(.test, nil, existing: ["dev-01", name + "-retry"]) }
        #expect(throws: B.Refusal.self) { try folder(.test, nil, existing: ["dev-01", "test-000000000000"]) }
        #expect(throws: B.Refusal.self) { try folder(.test, nil, existing: ["TEST-000000000000"]) }
        // The test run elsewhere.
        #expect(throws: B.Refusal.self) { try folder(.test, runs + "/elsewhere") }
        #expect(throws: B.Refusal.self) { try folder(.test, runs + "/" + name + "-2") }
        // A development run goes where it is asked, but never under a test run's name.
        #expect(try folder(.dev, runs + "/dev-02") == runs + "/dev-02")
        #expect(try folder(.dev, runs + "/sweep/test-like") == runs + "/sweep/test-like")
        #expect(throws: B.Refusal.self) { try folder(.dev, nil) }
        #expect(throws: B.Refusal.self) { try folder(.dev, runs + "/" + name) }
        #expect(throws: B.Refusal.self) { try folder(.dev, runs + "/test-anything/inner") }
        #expect(throws: B.Refusal.self) { try folder(.dev, runs + "/sweep/../test-x") }
        // Nor in another case, which the test split counts as its run and APFS takes for the same name.
        #expect(throws: B.Refusal.self) { try folder(.dev, runs + "/TEST-" + digest.prefix(12)) }
        #expect(throws: B.Refusal.self) { try folder(.dev, runs + "/Test-anything") }
    }

    @Test func aSweepMayLeaveOutOnlyOnTheDevelopmentSplit() throws {
        let stocks = ["kodak-portra-400", "kodak-portra-160", "kodak-gold-200"], names = ["control", "A", "B"]
        func options(_ environment: [String: String], _ split: B.Split = .dev) throws -> B.Options {
            try B.options(environment, split: split, configurations: names, stocks: stocks)
        }
        let all = try options([:])
        #expect(all == B.Options(stocks: stocks, stability: Set(names), cost: Set(names), agreement: Set(names)))
        #expect(try options(["ARGENT_SEQUENCE_G7": "none"]).cost.isEmpty)
        #expect(try options(["ARGENT_SEQUENCE_STOCKS": "kodak-gold-200, kodak-portra-400"]).stocks == ["kodak-portra-400", "kodak-gold-200"])
        #expect(try options(["ARGENT_SEQUENCE_G6": "none"]).stability.isEmpty)
        #expect(try options(["ARGENT_SEQUENCE_G6": "A,B"]).stability == ["A", "B"])
        #expect(try options(["ARGENT_SEQUENCE_AGREEMENT": "B"]).agreement == ["B"])
        #expect(try options(["ARGENT_SEQUENCE_AGREEMENT": "all"]).agreement == Set(names))
        // Portra 400 always, and only stocks and configurations there are.
        #expect(throws: B.Refusal.self) { try options(["ARGENT_SEQUENCE_STOCKS": "kodak-gold-200"]) }
        #expect(throws: B.Refusal.self) { try options(["ARGENT_SEQUENCE_STOCKS": "kodak-portra-400,fuji"]) }
        #expect(throws: B.Refusal.self) { try options(["ARGENT_SEQUENCE_G6": "C"]) }
        #expect(throws: B.Refusal.self) { try options(["ARGENT_SEQUENCE_G6": ""]) }
        #expect(throws: B.Refusal.self) { try options(["ARGENT_SEQUENCE_AGREEMENT": "A,C"]) }
        // The test split scores every stock and every configuration's G6, and renders no agreement check.
        #expect(try options([:], .test) == B.Options(stocks: stocks, stability: Set(names), cost: Set(names), agreement: []))
        #expect(try options(["ARGENT_SEQUENCE_G6": "all", "ARGENT_SEQUENCE_STOCKS": stocks.joined(separator: ",")], .test).stocks == stocks)
        #expect(throws: B.Refusal.self) { try options(["ARGENT_SEQUENCE_STOCKS": "kodak-portra-400"], .test) }
        #expect(throws: B.Refusal.self) { try options(["ARGENT_SEQUENCE_G6": "none"], .test) }
        #expect(throws: B.Refusal.self) { try options(["ARGENT_SEQUENCE_G6": "A,B"], .test) }
        #expect(throws: B.Refusal.self) { try options(["ARGENT_SEQUENCE_G7": "none"], .test) }
        #expect(throws: B.Refusal.self) { try options(["ARGENT_SEQUENCE_AGREEMENT": "none"], .test) }
    }
}
