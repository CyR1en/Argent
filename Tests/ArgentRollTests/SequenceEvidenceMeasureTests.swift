import ArgentCore
import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import ArgentRoll

/// The sequence evidence (`SequenceEvidence.links`) on the development split of the frozen sequence
/// benchmark: the matcher rule of docs/research/auto/sequence-consistency.md section 3 ("Tuning, on dev
/// only": recall of dev P pairs with false links at most 5 % of dev changed-light pairs and of dev pairs
/// labelled different within 120 s). Runs only with ARGENT_MEASURE=1 and the protocol:
///
///     ARGENT_MEASURE=1 ARGENT_CUBEPP_GRID=cells \
///       ARGENT_CUBEPP_COHORT=$PWD/docs/research/auto/gate-protocol/cubepp-cohort-2234.txt \
///       ARGENT_SEQUENCE_PROTOCOL=<evidence root>/benchmark/protocol.json ARGENT_SEQUENCE_OUT=<folder> \
///       swift test -c release -Xswiftc -enable-testing --skip-build --filter SequenceEvidenceMeasureTests
///
/// The protocol must hash to `protocolDigest`. Only frames of development sessions are measured,
/// described or matched; of the test split this counts pairs and nothing else.
///
/// - **Cube++** (Ershov et al., IEEE Access 2020; CC BY 4.0), as `SeriesMeasureTests` reads it: each frame's
///   cell grid, its analysis as `SeriesMeasureTests.analysis` makes it with the faces of the cache's boxes
///   metered on it, and `SequenceDescriptor(grid:)`. Sessions are the benchmark's (`cubepp/sessions.csv`
///   beside the protocol, checked against its pairs). P: dev pairs labelled same whose cube passes
///   `SeriesMeasureTests`' same-light rule. Overlap: dev pairs labelled overlap. Changed light: every
///   dev neighbour and skip-one of one body within 600 s whose cube the rule calls changed (the
///   protocol keeps only pairs within half a stop, so they are enumerated here). Different: dev pairs
///   labelled different within 120 s. The shift's error is |shift − Δ gray| of the cube on linked
///   same-light pairs (the cube is masked out of the matching).
/// - **a7 IV**: the development sessions' raws decoded as the sheet decodes them (`FilmPreviews`' direct
///   960-pixel decode) and measured with `ExposureAnalyzer.measure`, faces included; cached under the
///   output folder. P: dev pairs whose boxes lie on the same physical surface. Reported besides: the
///   same pairs matched alone, whatever their distance in the roll, and links across the labelled
///   boundaries.
/// - **Unrelated textures** (`SequenceScenes.unrelated`): 60 pairs of synthetic scenes, so chance links
///   show whatever the data.
///
/// Settings (`settings()`): ARGENT_SEQUENCE_BASE moves the shipped constants; ARGENT_SEQUENCE_SWEEP=grid
/// crosses the values ARGENT_SEQUENCE_GRID lists, and `axes` varies each alone about the base. The
/// shipped constants came from these runs (2026-10-22, logs under the evidence root's
/// `evidence/` and `logs/`):
///
///     ARGENT_SEQUENCE_SWEEP=grid ARGENT_SEQUENCE_BASE="detailCorrelation=0.2" \
///       ARGENT_SEQUENCE_GRID="minimumCorrelation=0.4|0.5|0.6;agreeingBlocks=3|4;blockSide=8|10;blockShift=0.25|0.35"
///     ARGENT_SEQUENCE_SWEEP=axes ARGENT_SEQUENCE_GRID="minimumCorrelation=0.3|0.4|0.6|0.7|0.8;agreeingBlocks=2|4|5|6;…"
///
/// Each run appends a line a setting to runs.csv and writes summary.md, pairs.csv (each P pair, each
/// overlap pair and each false link under the base) and missed.csv (where matching stops for each P pair
/// left unlinked) under ARGENT_SEQUENCE_OUT, which must lie outside the repository and the photographs.
@Suite(.serialized) struct SequenceEvidenceMeasureTests {
    typealias G = GateMeasureTests
    typealias L = LabBalanceMeasureTests
    typealias M = FrameViewMeasureTests
    typealias S = SeriesMeasureTests

    /// SHA-256 of the frozen protocol (docs/research/auto/sequence-consistency.md, section 2).
    static let protocolDigest = "f17bec3859f959bf7929bf22c3188b1638aab67ccafe9a25b1e6d3f90dcba17a"
    /// The matcher rule's ceilings on false links.
    static let falseLinkLimit = 0.05

    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    // MARK: The protocol

    struct BenchmarkProtocol: Decodable {
        struct CubePair: Decodable {
            var id: String
            var a: String
            var b: String
            var body: String
            var session: String
            var split: String
            var subject: String
            var seconds: Double
            var skip: Int
        }
        struct Cube: Decodable { var pairs: [CubePair] }
        struct Folder: Decodable { var path: String }
        struct A7Frame: Decodable {
            var file: String
            var folder: String
            var session: String
        }
        struct A7Pair: Decodable {
            var id: String
            var a: String
            var b: String
            var folderA: String
            var folderB: String
            var sessionA: String
            var sessionB: String
            var split: String?
            var kind: String
            var samePhysicalSurface: Bool
            var secondsApart: Double
            var sceneType: String
        }
        struct A7Boundary: Decodable {
            var a: String
            var b: String
            var folder: String
            var kind: String
            var split: String?
        }
        struct A7: Decodable {
            var folders: [String: Folder]
            var frames: [A7Frame]
            var pairs: [A7Pair]
            var boundaries: [A7Boundary]
        }
        var cubepp: Cube
        var a7iv: A7
        var units: [String: String]
    }

    /// The protocol ARGENT_SEQUENCE_PROTOCOL names, refused unless it is the frozen one.
    static func loadProtocol() throws -> (BenchmarkProtocol, URL) {
        let url = URL(fileURLWithPath: try #require(environment["ARGENT_SEQUENCE_PROTOCOL"], "ARGENT_SEQUENCE_PROTOCOL names protocol.json"))
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try #require(digest == protocolDigest, "protocol.json is not the frozen protocol (\(digest))")
        return (try JSONDecoder().decode(BenchmarkProtocol.self, from: data), url)
    }

    /// ARGENT_SEQUENCE_OUT, made if need be; refused inside the repository or any of `refusing`.
    static func outputFolder(refusing folders: [URL]) throws -> URL {
        let out = URL(fileURLWithPath: try #require(environment["ARGENT_SEQUENCE_OUT"], "ARGENT_SEQUENCE_OUT names the output folder"))
        let path = out.canonicalPath + "/"
        for folder in [M.root] + folders {
            try #require(!path.hasPrefix(folder.canonicalPath + "/"), "write outside \(folder.path)")
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    // MARK: The development split

    /// One development frame: its key (Cube++ id, or folder/file), the frame, its measurement and the
    /// cube's gray in the decode where there is one.
    struct Shot: Sendable {
        var key: String
        var frame: Frame
        var analysis: ExposureAnalysis
        var descriptor: SequenceDescriptor
        var gray: Double?
    }

    /// One development session's frames in capture order: a roll as the evidence sees it.
    struct Session: Sendable {
        var name: String
        var source: String
        var shots: [Shot]

        var input: SequenceAims.Input {
            SequenceAims.Input(frames: shots.map(\.frame),
                               analyses: Dictionary(uniqueKeysWithValues: shots.map { ($0.frame.url, $0.analysis) }),
                               descriptors: Dictionary(uniqueKeysWithValues: shots.map { ($0.frame.url, $0.descriptor) }),
                               stock: SequenceEvidenceMeasureTests.stock, controls: RollControls())
        }
    }

    /// The evidence reads no stock.
    static let stock = Stock(id: "none", displayName: "None", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                             exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 2), print: LUT3D.identity(size: 2))

    /// A labelled pair of development frames, by key.
    struct Pair: Hashable, Sendable {
        var a: String
        var b: String
        var source: String
        var id: String
        /// The cube's Δ gray (later less earlier, stops in the decode), Cube++ only.
        var deltaGray: Double?
        var seconds: Double

        var key: String { a + "|" + b }
    }

    /// The development split's sessions and labelled pairs.
    struct Split: Sendable {
        var sessions: [Session]
        var primary: [Pair]
        var overlap: [Pair]
        var changed: [Pair]
        var different: [Pair]
        var sameLight: [Pair]
        var boundaries: [Pair]
        var testCounts: [String: Int]
    }

    /// The cube's light rule of `SeriesMeasureTests`: same (⅓ stop, 10 mired, 0.1 green), changed (past ⅔
    /// stop, 20 mired or 0.2 green), or between (`nil`).
    static func cubeLight(_ a: S.Shot, _ b: S.Shot) -> Bool? {
        let light = abs(a.absoluteGray - b.absoluteGray)
        let (rbA, gA) = AutoBalance.axes(a.light), (rbB, gB) = AutoBalance.axes(b.light)
        let redBlue = Double(abs(rbA - rbB) / AutoBalance.stopsPerMired), green = Double(abs(gA - gB))
        return light <= 1.0 / 3 && redBlue <= 10 && green <= 0.1 ? true : light > 2.0 / 3 || redBlue > 20 || green > 0.2 ? false : nil
    }

    static func cubeSplit(_ benchmark: BenchmarkProtocol, protocolURL: URL) throws -> Split {
        let cameras = try S.loadShots()
        try #require(cameras.reduce(0, { $0 + $1.count }) == L.expectedFrameCount, "Cube++ sequence cohort is incomplete")
        // The benchmark's sessions, checked against every pair of the protocol.
        let table = try String(contentsOf: protocolURL.deletingLastPathComponent().appendingPathComponent("cubepp/sessions.csv"), encoding: .utf8)
        var sessionOf: [String: String] = [:]
        // Written with CRLF line ends, one grapheme each.
        for line in table.split(whereSeparator: \.isNewline).dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if fields.count >= 2 { sessionOf[fields[0]] = fields[1] }
        }
        for pair in benchmark.cubepp.pairs {
            try #require(sessionOf[pair.a] == pair.session && sessionOf[pair.b] == pair.session, "\(pair.id)'s session")
        }
        let labels = Dictionary(uniqueKeysWithValues: benchmark.cubepp.pairs.map { ($0.a + "|" + $0.b, $0) })
        var counts: [String: Int] = [:]
        for pair in benchmark.cubepp.pairs where pair.split == "test" { counts["cubepp test " + pair.subject, default: 0] += 1 }
        counts["cubepp test different within 120 s"] = benchmark.cubepp.pairs.filter { $0.split == "test" && $0.subject == "different" && $0.seconds <= 120 }.count

        var split = Split(sessions: [], primary: [], overlap: [], changed: [], different: [], sameLight: [], boundaries: [], testCounts: counts)
        var protocolDev = 0, enumeratedDev = 0
        for shots in cameras {
            // Development frames only, by session, in capture order.
            let dev = shots.filter { sessionOf[$0.id].flatMap { benchmark.units[$0] } == "dev" }
            var runs: [[S.Shot]] = []
            for shot in dev {
                if let last = runs.last?.last, sessionOf[last.id] == sessionOf[shot.id] { runs[runs.count - 1].append(shot) } else { runs.append([shot]) }
            }
            for run in runs {
                let frames = S.roll(run)
                var session = Session(name: sessionOf[run[0].id]!, source: "cubepp", shots: [])
                for (shot, frame) in zip(run, frames) {
                    let grid = shot.frame.analysisGrid
                    var analysis = S.analysis(shot)
                    let boxes = (shot.frame.prepared.faces ?? []).filter { $0.count == 4 }
                        .map { CGRect(x: CGFloat($0[0]), y: CGFloat($0[1]), width: CGFloat($0[2]), height: CGFloat($0[3])) }
                    analysis.faces = FaceMeter.meter(boxes, grid: grid)
                    session.shots.append(Shot(key: shot.id, frame: frame, analysis: analysis, descriptor: SequenceDescriptor(grid: grid),
                                              gray: shot.gray))
                }
                split.sessions.append(session)
                // Neighbours and skip-ones within 600 s, labelled by the cube and the labellers.
                for i in run.indices {
                    for j in (i + 1)..<min(i + 3, run.count) {
                        let a = run[i], b = run[j], seconds = b.date.timeIntervalSince(a.date)
                        guard seconds <= 600 else { continue }
                        let light = cubeLight(a, b)
                        let label = labels[a.id + "|" + b.id]
                        if abs(a.absoluteGray - b.absoluteGray) <= 0.5 { enumeratedDev += 1 }
                        if label?.split == "dev" { protocolDev += 1 }
                        let pair = Pair(a: a.id, b: b.id, source: "cubepp", id: label?.id ?? "\(a.id)-\(b.id)", deltaGray: b.gray - a.gray,
                                        seconds: seconds)
                        if light == false { split.changed.append(pair) }
                        if light == true { split.sameLight.append(pair) }
                        guard let label, label.split == "dev" else { continue }
                        if label.subject == "same", light == true { split.primary.append(pair) }
                        if label.subject == "overlap" { split.overlap.append(pair) }
                        if label.subject == "different", label.seconds <= 120 { split.different.append(pair) }
                    }
                }
            }
        }
        let protocolPairs = benchmark.cubepp.pairs.filter { $0.split == "dev" }.count
        print("SEQUENCE Cube++ dev: \(split.sessions.count) sessions, \(split.sessions.reduce(0) { $0 + $1.shots.count }) frames; "
              + "protocol dev pairs \(protocolPairs), found \(protocolDev), enumerated within half a stop \(enumeratedDev)")
        #expect(protocolDev == protocolPairs, "every dev pair of the protocol is a neighbour or skip-one within 600 s")
        return split
    }

    /// The measurements of a7 IV development frames, cached by folder, file and size.
    struct Cached: Codable {
        var key: String
        var bytes: Int
        var analysis: ExposureAnalysis
        var width: Int
        var height: Int
        var rgb: [Float]
        var unclipped: [Float]
        var detail: [Float]
    }

    static func a7Split(_ benchmark: BenchmarkProtocol, out: URL) throws -> Split {
        let a7 = benchmark.a7iv
        func folder(_ name: String) throws -> URL {
            let path = try #require(a7.folders[name]?.path, "folder \(name)")
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : M.root.appendingPathComponent(path)
        }
        let dev = a7.frames.filter { benchmark.units[$0.session] == "dev" }
        var counts: [String: Int] = [:]
        counts["a7iv test same surface"] = a7.pairs.filter { $0.split == "test" && $0.samePhysicalSurface }.count
        counts["a7iv test boundaries"] = a7.boundaries.filter { $0.split == "test" }.count

        let cacheURL = out.appendingPathComponent("a7iv-dev-measurements.json")
        var cache: [String: Cached] = [:]
        if let data = try? Data(contentsOf: cacheURL), let entries = try? JSONDecoder().decode([Cached].self, from: data) {
            cache = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        }
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = ChosenDecoder(gpu: gpu, choices: DecoderChoices(), contextPerDecode: true,
                                    inHouseAtOnce: FilmPreviews.inHouseDecodesAtOnce)
        var shots: [(session: String, shot: Shot)] = []
        for entry in dev {
            let url = try folder(entry.folder).appendingPathComponent(entry.file)
            let key = entry.folder + "/" + entry.file
            let info = try ARWFrameInfo.read(from: url)
            let bytes = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            let measured: Cached = try autoreleasepool {
                if let hit = cache[key], hit.bytes == bytes, hit.analysis.isCurrent { return hit }
                var options = DecodeOptions()
                options.maxLongSide = FilmPreviews.previewLongSide
                let sheet = try decoder.decode(url, options: options)
                let (analysis, descriptor) = ExposureAnalyzer.measure(sheet, workingSpace: gpu.workingColorSpace, info: info)
                return Cached(key: key, bytes: bytes, analysis: analysis, width: descriptor.width, height: descriptor.height,
                              rgb: descriptor.rgb, unclipped: descriptor.unclipped, detail: descriptor.detail)
            }
            cache[key] = measured
            var descriptor = SequenceDescriptor(grid: ExposureAnalyzer.grid(pixels: [], width: 0, height: 0))
            descriptor.width = measured.width
            descriptor.height = measured.height
            descriptor.rgb = measured.rgb
            descriptor.unclipped = measured.unclipped
            descriptor.detail = measured.detail
            shots.append((entry.session, Shot(key: key, frame: Frame(id: 0, url: url, info: info), analysis: measured.analysis,
                                              descriptor: descriptor, gray: nil)))
        }
        try JSONEncoder().encode(cache.values.sorted { $0.key < $1.key }).write(to: cacheURL)

        var split = Split(sessions: [], primary: [], overlap: [], changed: [], different: [], sameLight: [], boundaries: [], testCounts: counts)
        for name in Set(shots.map(\.session)).sorted() {
            let ordered = shots.filter { $0.session == name }.map(\.shot).sorted {
                ($0.frame.info.captureDate ?? .distantPast, $0.key) < ($1.frame.info.captureDate ?? .distantPast, $1.key)
            }
            split.sessions.append(Session(name: name, source: "a7iv", shots: ordered.enumerated().map { index, shot in
                var shot = shot
                shot.frame = Frame(id: index, url: shot.frame.url, info: shot.frame.info)
                return shot
            }))
        }
        for pair in a7.pairs where pair.split == "dev" && pair.samePhysicalSurface {
            split.primary.append(Pair(a: pair.folderA + "/" + pair.a, b: pair.folderB + "/" + pair.b, source: "a7iv", id: pair.id,
                                      deltaGray: nil, seconds: pair.secondsApart))
        }
        for boundary in a7.boundaries where boundary.split == "dev" {
            split.boundaries.append(Pair(a: boundary.folder + "/" + boundary.a, b: boundary.folder + "/" + boundary.b, source: "a7iv",
                                         id: boundary.kind, deltaGray: nil, seconds: 0))
        }
        print("SEQUENCE a7 IV dev: \(split.sessions.count) sessions, \(shots.count) frames, \(split.primary.count) P pairs, "
              + "\(split.boundaries.count) boundaries")
        return split
    }

    // MARK: Runs

    struct Setting: Sendable {
        var name: String
        var parameters: SequenceAims.Parameters
        var tuning: SequenceEvidence.Tuning
    }

    /// What one setting links on the development split.
    struct Row: Sendable {
        var setting: Setting
        var links: [String: SequenceAims.Link]
        var primary: (Int, Int)
        var primaryCube: (Int, Int)
        var primaryA7: (Int, Int)
        var overlap: (Int, Int)
        var changed: (Int, Int)
        var different: (Int, Int)
        var boundaries: (Int, Int)
        /// The same at confidence `minimumConfidence` or more.
        var confidentPrimary: Int
        var confidentChanged: Int
        var confidentDifferent: Int
        var shiftErrors: [Double]
        /// The same over pairs the labellers called the same subject or overlapping.
        var labelledShiftErrors: [Double]
        /// Pairs of unrelated synthetic textures matched (`SequenceScenes.unrelated`): chance links.
        var chance: (Int, Int)

        var feasible: Bool {
            Double(changed.0) <= falseLinkLimit * Double(changed.1) && Double(different.0) <= falseLinkLimit * Double(different.1)
        }
    }

    /// Unrelated synthetic scenes, the same for every setting.
    static let unrelated = SequenceScenes.unrelated(60)

    static func run(_ setting: Setting, on splits: [Split]) async -> Row {
        let sessions = splits.flatMap(\.sessions)
        let found = await withTaskGroup(of: [(String, SequenceAims.Link)].self) { group in
            for session in sessions {
                group.addTask {
                    SequenceEvidence.links(session.input, parameters: setting.parameters, tuning: setting.tuning).map {
                        (session.shots[$0.earlier].key + "|" + session.shots[$0.later].key, $0)
                    }
                }
            }
            var all: [(String, SequenceAims.Link)] = []
            for await links in group { all += links }
            return all
        }
        let links = Dictionary(found, uniquingKeysWith: { a, _ in a })
        let chance = await withTaskGroup(of: Bool.self) { group in
            for (a, b) in unrelated {
                group.addTask {
                    guard let pa = SequenceEvidence.Pyramid(a, minimumDetail: setting.parameters.minimumDetail),
                          let pb = SequenceEvidence.Pyramid(b, minimumDetail: setting.parameters.minimumDetail) else { return false }
                    return SequenceEvidence.match(pa, pb, parameters: setting.parameters, tuning: setting.tuning) != nil
                }
            }
            var matched = 0
            for await one in group where one { matched += 1 }
            return matched
        }
        func count(_ pairs: [Pair]) -> (Int, Int) { (pairs.filter { links[$0.key] != nil }.count, pairs.count) }
        func confident(_ pairs: [Pair]) -> Int {
            pairs.filter { (links[$0.key]?.confidence ?? 0) >= setting.parameters.minimumConfidence }.count
        }
        let primary = splits.flatMap(\.primary), changed = splits.flatMap(\.changed), different = splits.flatMap(\.different)
        let labelled = Set(splits.flatMap(\.sameLight).map(\.key))
        func shiftError(_ pair: Pair) -> Double? {
            links[pair.key].flatMap { link in pair.deltaGray.map { abs(Double(link.shift) - $0) } }
        }
        return Row(setting: setting, links: links, primary: count(primary),
                   primaryCube: count(primary.filter { $0.source == "cubepp" }), primaryA7: count(primary.filter { $0.source == "a7iv" }),
                   overlap: count(splits.flatMap(\.overlap)), changed: count(changed), different: count(different),
                   boundaries: count(splits.flatMap(\.boundaries)), confidentPrimary: confident(primary), confidentChanged: confident(changed),
                   confidentDifferent: confident(different),
                   shiftErrors: splits.flatMap(\.sameLight).compactMap(shiftError),
                   labelledShiftErrors: splits.flatMap { $0.primary + $0.overlap }.filter { labelled.contains($0.key) }.compactMap(shiftError),
                   chance: (chance, unrelated.count))
    }

    static func percent(_ x: (Int, Int)) -> String {
        "\(x.0)/\(x.1) (" + String(format: "%.1f%%", 100 * Double(x.0) / Double(max(x.1, 1))) + ")"
    }

    static func quantiles(_ values: [Double]) -> String {
        let s = values.sorted()
        guard !s.isEmpty else { return "–" }
        return [0.5, 0.9].map { String(format: "%.3f", s[min(s.count - 1, Int($0 * Double(s.count)))]) }.joined(separator: " / ")
            + String(format: " / %.3f (n=%d)", s.last!, s.count)
    }

    static let header = "setting,feasible,P,P cube,P a7,overlap,changed,different120,boundaries a7,chance,P conf,changed conf,different conf,"
        + "shift err median / p90 / max,shift err labelled,neighbours,maximumGap,minimumOverlap,minimumCorrelation,minimumDetail,lightTolerance,"
        + "blockSide,blockCells,structuredShare,blockSpread,blockShift,cellShift,agreeingBlocks,agreeingShare,detailCorrelation,redBlue,greenMagenta"

    static func line(_ row: Row) -> String {
        let p = row.setting.parameters, t = row.setting.tuning
        return [row.setting.name, row.feasible ? "yes" : "no", percent(row.primary), percent(row.primaryCube), percent(row.primaryA7),
                percent(row.overlap), percent(row.changed), percent(row.different), percent(row.boundaries), percent(row.chance),
                "\(row.confidentPrimary)", "\(row.confidentChanged)", "\(row.confidentDifferent)", quantiles(row.shiftErrors), quantiles(row.labelledShiftErrors),
                "\(p.neighbours)", "\(p.maximumGap)", "\(p.minimumOverlap)", "\(p.minimumCorrelation)", "\(p.minimumDetail)",
                "\(p.lightTolerance)", "\(t.blockSide)", "\(t.blockCells)", "\(t.structuredShare)", "\(t.blockSpread)", "\(t.blockShift)",
                "\(t.cellShift)", "\(t.agreeingBlocks)", "\(t.agreeingShare)", "\(t.detailCorrelation)", "\(t.redBlue)", "\(t.greenMagenta)"]
            .map { $0.contains(",") ? "\"\($0)\"" : $0 }.joined(separator: ",")
    }

    /// Sets the constant `name` of `setting` to `value`; false for a name it does not know.
    static func set(_ name: String, _ value: Double, in setting: inout Setting) -> Bool {
        let v = Float(value)
        switch name {
        case "neighbours": setting.parameters.neighbours = Int(value)
        case "maximumGap": setting.parameters.maximumGap = value
        case "minimumOverlap": setting.parameters.minimumOverlap = v
        case "minimumCorrelation": setting.parameters.minimumCorrelation = v
        case "minimumDetail": setting.parameters.minimumDetail = v
        case "lightTolerance": setting.parameters.lightTolerance = v
        case "candidates": setting.tuning.candidates = Int(value)
        case "blockSide": setting.tuning.blockSide = Int(value)
        case "blockCells": setting.tuning.blockCells = Int(value)
        case "structuredShare": setting.tuning.structuredShare = v
        case "blockSpread": setting.tuning.blockSpread = v
        case "blockShift": setting.tuning.blockShift = v
        case "cellShift": setting.tuning.cellShift = v
        case "agreeingBlocks": setting.tuning.agreeingBlocks = Int(value)
        case "agreeingShare": setting.tuning.agreeingShare = v
        case "detailCorrelation": setting.tuning.detailCorrelation = v
        case "redBlue": setting.tuning.redBlue = v
        case "greenMagenta": setting.tuning.greenMagenta = v
        default: return false
        }
        return true
    }

    /// The settings asked for. ARGENT_SEQUENCE_BASE moves the shipped constants, as `name=value`
    /// separated by commas. ARGENT_SEQUENCE_SWEEP is `grid`, every combination of the values that
    /// ARGENT_SEQUENCE_GRID lists as `name=value|value` separated by semicolons, or `axes`, each value
    /// of each name it lists varied alone about the base; unset, the base alone.
    static func settings() -> [Setting] {
        var base = Setting(name: "shipped", parameters: SequenceAims.Parameters(), tuning: .standard)
        for assignment in (environment["ARGENT_SEQUENCE_BASE"] ?? "").split(separator: ",") {
            let parts = assignment.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let value = Double(parts[1]), set(parts[0], value, in: &base) { base.name = "base" }
        }
        let axes: [(String, [Double])] = (environment["ARGENT_SEQUENCE_GRID"] ?? "").split(separator: ";").compactMap { axis in
            let parts = axis.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1].split(separator: "|").compactMap { Double($0) })
        }
        switch environment["ARGENT_SEQUENCE_SWEEP"] {
        case "grid":
            var settings = [base]
            for (name, values) in axes {
                settings = settings.flatMap { setting in
                    values.map { value in
                        var s = setting
                        _ = set(name, value, in: &s)
                        s.name = (setting.name == base.name ? "" : setting.name + " ") + "\(name)=\(value)"
                        return s
                    }
                }
            }
            return settings
        case "axes":
            var settings = [base]
            for (name, values) in axes {
                for value in values {
                    var s = base
                    _ = set(name, value, in: &s)
                    s.name = "\(name)=\(value)"
                    settings.append(s)
                }
            }
            return settings
        default:
            return [base]
        }
    }

    /// Where matching `a` and `b` stops: the first of ever looser settings, from `base`, under which their
    /// descriptors match, with the match; time and order left aside.
    static func ladder(_ a: Shot, _ b: Shot, from base: Setting) -> String {
        let rungs: [(String, (inout Setting) -> Void)] = [
            ("shipped", { _ in }),
            ("correlation 0.6", { $0.parameters.minimumCorrelation = 0.6 }),
            ("2 blocks, share 0.4", { $0.tuning.agreeingBlocks = 2; $0.tuning.agreeingShare = 0.4 }),
            ("overlap 0.25", { $0.parameters.minimumOverlap = 0.25 }),
            ("loose blocks", { $0.tuning.structuredShare = 0.25; $0.tuning.blockSpread = 0.05; $0.tuning.blockShift = 0.5 }),
            ("8 candidates", { $0.tuning.candidates = 8 }),
            ("correlation 0.4, 1 block", { $0.parameters.minimumCorrelation = 0.4; $0.tuning.agreeingBlocks = 1; $0.tuning.agreeingShare = 0.2 }),
        ]
        var setting = base
        for (name, loosen) in rungs {
            loosen(&setting)
            guard let pa = SequenceEvidence.Pyramid(a.descriptor, minimumDetail: setting.parameters.minimumDetail),
                  let pb = SequenceEvidence.Pyramid(b.descriptor, minimumDetail: setting.parameters.minimumDetail) else { return "no descriptor" }
            guard let m = SequenceEvidence.match(pa, pb, parameters: setting.parameters, tuning: setting.tuning) else { continue }
            let light = a.frame.info.sceneEV100.flatMap { ea in b.frame.info.sceneEV100.map { m.shift - Float(ea - $0) } }
            return [name, "\(m.structuredBlocks)", "\(m.agreeingBlocks)", String(format: "%.3f", m.correlation),
                    String(format: "%.3f", m.detailCorrelation), String(format: "%.3f", m.overlap),
                    String(format: "%.3f", m.alignment.scale), "\(m.alignment.turns)", String(format: "%.3f", m.shift),
                    light.map { String(format: "%.3f", $0) } ?? "", String(format: "%.3f", m.colour.x), String(format: "%.3f", m.colour.y)]
                .joined(separator: ",")
        }
        return "never"
    }

    @Test(.enabled(if: FrameViewMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_SEQUENCE_PROTOCOL"] != nil))
    func developmentSplit() async throws {
        let (benchmark, protocolURL) = try Self.loadProtocol()
        let owner = benchmark.a7iv.folders.values.map(\.path).filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        let out = try Self.outputFolder(refusing: [L.corpus.resolvingSymlinksInPath()] + owner)
        let cube = try Self.cubeSplit(benchmark, protocolURL: protocolURL)
        let a7 = try Self.a7Split(benchmark, out: out)
        let splits = [cube, a7]
        print("SEQUENCE test split, counted only: " + cube.testCounts.merging(a7.testCounts) { a, _ in a }
            .sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        print("SEQUENCE dev pairs: P \(cube.primary.count + a7.primary.count) (Cube++ \(cube.primary.count), a7 IV \(a7.primary.count)), "
              + "overlap \(cube.overlap.count), changed light \(cube.changed.count), different within 120 s \(cube.different.count), "
              + "same light \(cube.sameLight.count), a7 IV boundaries \(a7.boundaries.count)")

        // Every setting asked for.
        var rows: [Row] = []
        for setting in Self.settings() {
            let row = await Self.run(setting, on: splits)
            print("SEQUENCE " + Self.line(row))
            rows.append(row)
        }
        let log = out.appendingPathComponent("runs.csv")
        if !FileManager.default.fileExists(atPath: log.path) { try (Self.header + "\n").write(to: log, atomically: true, encoding: .utf8) }
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(rows.map { Self.line($0) + "\n" }.joined().utf8))
        try handle.close()

        // The shipped constants: each P pair and each false link, and the time a pair takes.
        let shipped = try #require(rows.first { $0.setting.name == "shipped" } ?? rows.first)
        var lines = ["kind,id,a,b,seconds,linked,shift,lightChange,deltaGray,overlap,correlation,confidence,samples"]
        func number(_ x: Float?) -> String { x.map { String(format: "%.3f", $0) } ?? "" }
        func describe(_ kind: String, _ pairs: [Pair], onlyLinked: Bool) {
            for pair in pairs {
                let link = shipped.links[pair.key]
                guard link != nil || !onlyLinked else { continue }
                var fields = [kind, pair.id, pair.a, pair.b, String(format: "%.1f", pair.seconds), link == nil ? "no" : "yes"]
                fields += [number(link?.shift), number(link?.lightChange), number(pair.deltaGray.map(Float.init))]
                fields += [number(link?.overlap), number(link?.correlation), number(link?.confidence), link.map { "\($0.weights.count)" } ?? ""]
                lines.append(fields.joined(separator: ","))
            }
        }
        describe("P", splits.flatMap(\.primary), onlyLinked: false)
        describe("overlap", cube.overlap, onlyLinked: false)
        describe("changed", cube.changed, onlyLinked: true)
        describe("different", cube.different, onlyLinked: true)
        describe("boundary", a7.boundaries, onlyLinked: true)
        try (lines.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("pairs.csv"), atomically: true, encoding: .utf8)

        // Each P pair the shipped constants leave unlinked: the first of ever looser settings that matches it.
        let shots = Dictionary(uniqueKeysWithValues: splits.flatMap(\.sessions).flatMap(\.shots).map { ($0.key, $0) })
        var missed = ["id,a,b,seconds,rung,structured,agreeing,correlation,detail,overlap,scale,turns,shift,lightChange,redBlue,greenMagenta"]
        for pair in splits.flatMap(\.primary) where shipped.links[pair.key] == nil {
            guard let a = shots[pair.a], let b = shots[pair.b] else { continue }
            missed.append("\(pair.id),\(pair.a),\(pair.b),\(String(format: "%.1f", pair.seconds)),"
                          + Self.ladder(a, b, from: shipped.setting))
        }
        try (missed.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("missed.csv"), atomically: true, encoding: .utf8)

        // The matcher alone on each a7 IV P pair, whatever lies between its frames.
        let byKey = Dictionary(uniqueKeysWithValues: a7.sessions.flatMap(\.shots).map { ($0.key, $0) })
        var alone = 0
        for pair in a7.primary {
            guard let a = byKey[pair.a], let b = byKey[pair.b],
                  let pa = SequenceEvidence.Pyramid(a.descriptor, minimumDetail: shipped.setting.parameters.minimumDetail),
                  let pb = SequenceEvidence.Pyramid(b.descriptor, minimumDetail: shipped.setting.parameters.minimumDetail) else { continue }
            if SequenceEvidence.link(earlier: (0, a.frame.info, a.analysis, pa), later: (1, b.frame.info, b.analysis, pb), gap: 0,
                                     parameters: shipped.setting.parameters, tuning: shipped.setting.tuning) != nil { alone += 1 }
        }

        // Time: the Cube++ development sessions one at a time, per pair compared.
        var compared = 0
        for session in cube.sessions {
            let frames = session.shots.map(\.frame)
            for i in frames.indices {
                for j in (i + 1)..<min(frames.count, i + 1 + shipped.setting.parameters.neighbours)
                where abs(frames[j].info.captureDate!.timeIntervalSince(frames[i].info.captureDate!)) <= shipped.setting.parameters.maximumGap {
                    compared += 1
                }
            }
        }
        let clock = ContinuousClock()
        var elapsed = Duration.zero
        for session in cube.sessions {
            let input = session.input
            elapsed += clock.measure { _ = SequenceEvidence.links(input, parameters: shipped.setting.parameters, tuning: shipped.setting.tuning) }
        }
        let perPair = M.ms(elapsed) / Double(max(compared, 1))
        // Each pair alone, its frames' pyramids built: the search and verification. And synthetic frames of
        // one scene, landscape against portrait, which search three turns.
        var each: [Double] = []
        for session in cube.sessions {
            let pyramids = session.shots.map { SequenceEvidence.Pyramid($0.descriptor, minimumDetail: shipped.setting.parameters.minimumDetail) }
            for i in pyramids.indices {
                for j in (i + 1)..<min(pyramids.count, i + 1 + shipped.setting.parameters.neighbours) {
                    guard let a = pyramids[i], let b = pyramids[j] else { continue }
                    each.append(M.ms(clock.measure {
                        _ = SequenceEvidence.match(a, b, parameters: shipped.setting.parameters, tuning: shipped.setting.tuning)
                    }))
                }
            }
        }
        var turned: [Double] = []
        for seed in 0..<20 as Range<UInt64> {
            let texture = SequenceScenes.texture(seed)
            let landscape = SequenceScenes.descriptor(stops: texture)
            let portrait = SequenceScenes.descriptor(width: 43, height: 64, view: { SIMD2($0.y, 43 - $0.x) }, stops: texture)
            guard let a = SequenceEvidence.Pyramid(landscape, minimumDetail: shipped.setting.parameters.minimumDetail),
                  let b = SequenceEvidence.Pyramid(portrait, minimumDetail: shipped.setting.parameters.minimumDetail) else { continue }
            turned.append(M.ms(clock.measure { _ = SequenceEvidence.match(a, b, parameters: shipped.setting.parameters, tuning: shipped.setting.tuning) }))
        }
        func spread(_ values: [Double]) -> String {
            let s = values.sorted()
            guard !s.isEmpty else { return "–" }
            return String(format: "median %.2f, p90 %.2f, max %.2f ms (n=%d)", s[s.count / 2], s[Int(0.9 * Double(s.count - 1))], s.last!, s.count)
        }

        var md = "# Sequence evidence on the development split\n\n"
        md += "Protocol \(Self.protocolDigest.prefix(8))…; \(splits.flatMap(\.sessions).count) development sessions, "
        md += "\(splits.flatMap(\.sessions).reduce(0) { $0 + $1.shots.count }) frames. Test split counted only: "
        md += cube.testCounts.merging(a7.testCounts) { a, _ in a }.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
            .joined(separator: ", ") + ".\n\n"
        md += "| setting | feasible | P | P Cube++ | P a7 IV | overlap | changed light | different ≤ 120 s | a7 IV boundaries | unrelated textures | shift error median / p90 / max | the same, labelled same or overlap |\n"
        md += "|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for row in rows {
            md += "| \(row.setting.name) | \(row.feasible ? "yes" : "no") | \(Self.percent(row.primary)) | \(Self.percent(row.primaryCube)) | "
            md += "\(Self.percent(row.primaryA7)) | \(Self.percent(row.overlap)) | \(Self.percent(row.changed)) | \(Self.percent(row.different)) | "
            md += "\(Self.percent(row.boundaries)) | \(Self.percent(row.chance)) | \(Self.quantiles(row.shiftErrors)) | \(Self.quantiles(row.labelledShiftErrors)) |\n"
        }
        md += "\nShipped constants: at confidence ≥ \(shipped.setting.parameters.minimumConfidence), P \(shipped.confidentPrimary), "
        md += "changed \(shipped.confidentChanged), different \(shipped.confidentDifferent). The a7 IV P pairs matched alone, "
        md += "whatever their distance in the roll: \(alone) of \(a7.primary.count). "
        md += String(format: "Time: %.2f ms a pair compared by `links` (%d pairs, %d Cube++ sessions, one thread); ", perPair, compared,
                     cube.sessions.count)
        md += "each pair matched alone \(spread(each)); landscape against portrait \(spread(turned)).\n"
        try md.write(to: out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        print(md)
    }
}
