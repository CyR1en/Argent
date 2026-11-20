import ArgentCore
import Foundation
import Testing
@testable import ArgentRoll

/// Roll smoothing on real capture sequences with a gray in every frame, behind
/// docs/research/rolls.md. Runs only with ARGENT_MEASURE=1:
///
///     ARGENT_MEASURE=1 swift test -c release -Xswiftc -enable-testing --filter SeriesMeasureTests
///
/// The data is Cube++ (Ershov et al., IEEE Access 2020; Zenodo record 4153431; CC BY 4.0), as
/// `LabBalanceMeasureTests.prepare` cached it under references/corpus/cubepp: each frame's
/// analysis grid with the SpyderCube masked out and the light on the cube's two 18 percent gray
/// faces, plus the archive's per-frame EXIF (`markup/Cube++/auxiliary/extra/exif`). Cube++ was shot
/// on three Canon bodies (one 550D, two 600D), nearly all in aperture priority or program, so its
/// frames form real sequences, seconds to minutes apart, and every frame carries a gray: under one
/// light the same gray should print the same, which is what a roll printed by one lab means.
/// "One exposure per scene" re-exposes each run of frames at its median EV, as a photographer in
/// manual would have shot it. `measure` and `gates` print what docs/research/rolls.md reports.
@Suite(.serialized) struct SeriesMeasureTests {
    typealias L = LabBalanceMeasureTests

    /// One Cube++ frame with what roll smoothing reads from its header.
    struct Shot {
        var frame: L.Frame
        var camera: String
        var date: Date
        var exposureTime: Double
        var fNumber: Double
        var iso: Int
        var flash: Bool
        /// EXIF ExposureProgram: 1 manual, 2 program, 3 aperture priority, 4 shutter priority.
        var program: Int
        var bias: Double
        /// The cube's gray in the decode, stops against mid-gray: the two gray faces' mean
        /// luminance, so a face turned from the sun and one toward it average out.
        var gray: Double

        var id: String { frame.prepared.id }
        var ev: Double { log2(fNumber * fNumber / exposureTime) - log2(Double(iso) / 100) }
        /// The cube's gray in absolute terms, its decoded level plus the light the camera
        /// exposed for: the same under the same light whatever the exposure.
        var absoluteGray: Double { gray + ev }
        /// The measured light, red, green and blue stops summing to zero.
        var light: SIMD3<Float> { L.zeroSum(frame.truth) }
    }

    /// Every cached frame with its EXIF, in capture order per camera.
    static func loadShots() throws -> [[Shot]] {
        let exif = L.corpus.appendingPathComponent("markup/Cube++/auxiliary/extra/exif")
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy:MM:dd HH:mm:ss"
        var shots: [Shot] = []
        let luma = SIMD3<Double>(0.2627, 0.6780, 0.0593)
        for frame in try L.loadFrames() {
            let url = exif.appendingPathComponent("\(frame.prepared.id).json")
            guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  let text = (json["Composite:SubSecDateTimeOriginal"] ?? json["EXIF:DateTimeOriginal"]) as? String,
                  var date = format.date(from: String(text.prefix(19))),
                  let t = json["EXIF:ExposureTime"] as? Double, let n = json["EXIF:FNumber"] as? Double,
                  let iso = json["EXIF:ISO"] as? Int
            else { continue }
            if text.count > 20, let fraction = Double("0" + text.dropFirst(19)) { date += fraction }
            let faces = frame.prepared.grayFaces.map { ($0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) * luma : .zero).sum() }
            let model = json["EXIF:Model"] as? String ?? "", serial = json["MakerNotes:InternalSerialNumber"] as? String ?? ""
            shots.append(Shot(frame: frame, camera: "\(model) \(serial)", date: date, exposureTime: t, fNumber: n, iso: iso,
                              flash: ((json["EXIF:Flash"] as? Int) ?? 0) & 1 == 1,
                              program: json["EXIF:ExposureProgram"] as? Int ?? 0,
                              bias: json["EXIF:ExposureCompensation"] as? Double ?? 0,
                              gray: log2(faces.reduce(0, +) / Double(faces.count) / 0.18)))
        }
        return Dictionary(grouping: shots, by: \.camera).sorted { $0.key < $1.key }.map { $0.value.sorted { $0.date < $1.date } }
    }

    /// The shipped analysis of `shot`'s grid with its light scaled by `shift` stops, as if the
    /// camera had given it that much more exposure, and the masked cube left out rather than read
    /// as black.
    static func analysis(_ shot: Shot, shift: Double = 0) -> ExposureAnalysis {
        var grid = shot.frame.analysisGrid
        let scale = Float(exp2(shift))
        for index in grid.light.indices {
            if grid.all[index] == .zero { grid.weight[index] = 0 }
            grid.light[index] *= scale
            grid.all[index] *= scale
        }
        var analysis = ExposureAnalyzer.analyze(grid: grid)
        // Preserve the historical face-free sequence protocol. Prepared face boxes are not
        // attached here, so this suite does not establish consistency for portrait sequences.
        analysis.asShotTemperature = shot.frame.prepared.asShotTemperature
        return analysis
    }

    /// A roll of `shots` for `RollSmoothing`: each shot's header with its exposure time
    /// replaced by `exposureTimes` when given.
    static func roll(_ shots: [Shot], exposureTimes: [Double]? = nil) -> [Frame] {
        shots.enumerated().map { index, shot in
            Frame(id: index, url: URL(fileURLWithPath: "/cubepp/\(shot.id).CR2"),
                  info: ARWFrameInfo(model: shot.camera, captureDate: shot.date, exposureTime: exposureTimes?[index] ?? shot.exposureTime,
                                     fNumber: shot.fNumber, iso: shot.iso, flashFired: shot.flash))
        }
    }

    /// Runs of a camera's frames no more than two minutes apart whose exposed light moves by
    /// at most one EV from frame to frame: what a photographer shooting in manual would most
    /// likely meet with one exposure.
    static func scenes(_ shots: [Shot]) -> [[Int]] {
        var scenes: [[Int]] = []
        for index in shots.indices {
            if index > 0, shots[index].date.timeIntervalSince(shots[index - 1].date) <= RollSmoothing.timeGap,
               abs(shots[index].ev - shots[index - 1].ev) <= RollSmoothing.evJump {
                scenes[scenes.count - 1].append(index)
            } else {
                scenes.append([index])
            }
        }
        return scenes
    }

    /// One way of shooting a camera's sequence: the shots, each one's exposure shift against
    /// the frame as shot, its analysis, and the roll smoothing sees.
    struct Scenario {
        var shots: [Shot]
        var shifts: [Double]
        var analyses: [ExposureAnalysis]
        var frames: [Frame]
        /// Argent's clusters, as indices into `shots`.
        var clusters: [[Int]]

        /// Each shot's exposed light, scene EV100.
        var evs: [Double] { frames.map { $0.info.sceneEV100 ?? 0 } }
        /// The cube's gray in each frame as this scenario exposed it.
        var grays: [Double] { zip(shots, shifts).map { $0.gray + $1 } }

        init(_ shots: [Shot], oneExposurePerScene: Bool, gates: Gates? = nil) {
            self.shots = shots
            var shifts = [Double](repeating: 0, count: shots.count)
            var times = shots.map(\.exposureTime)
            if oneExposurePerScene {
                for scene in SeriesMeasureTests.scenes(shots) {
                    let ev = GateMeasureTests.median(scene.map { shots[$0].ev })
                    for index in scene {
                        // The same aperture and ISO, the shutter that gives the scene's EV.
                        shifts[index] = shots[index].ev - ev
                        times[index] = shots[index].fNumber * shots[index].fNumber / exp2(ev + log2(Double(shots[index].iso) / 100))
                    }
                }
            }
            self.shifts = shifts
            analyses = zip(shots, shifts).map { SeriesMeasureTests.analysis($0, shift: $1) }
            frames = SeriesMeasureTests.roll(shots, exposureTimes: times)
            let byURL = Dictionary(uniqueKeysWithValues: zip(frames.map(\.url), analyses))
            let index = Dictionary(uniqueKeysWithValues: frames.enumerated().map { ($1.url, $0) })
            clusters = RollSmoothing.clusters(frames, analyses: byURL).map { $0.map { index[$0.url]! } }
            if let gates {
                let opened = SeriesMeasureTests.clusters(frames, analyses, gates: gates)
                if gates.isShipped { precondition(opened == clusters, "the opened splits must reproduce RollSmoothing's") }
                clusters = opened
            }
        }

        var analysesByURL: [URL: ExposureAnalysis] { Dictionary(uniqueKeysWithValues: zip(frames.map(\.url), analyses)) }
    }

    /// The splits with their thresholds opened up: `RollSmoothing.splits` with these in place of
    /// its constants, `nil` leaving a split out.
    struct Gates {
        var name: String
        var time: TimeInterval = RollSmoothing.timeGap
        var ev: Double? = RollSmoothing.evJump
        var mired: Float? = RollSmoothing.whiteBalanceMired
        var histogram: Float? = RollSmoothing.histogramDistance

        var isShipped: Bool {
            time == RollSmoothing.timeGap && ev == RollSmoothing.evJump && mired == RollSmoothing.whiteBalanceMired
                && histogram == RollSmoothing.histogramDistance
        }
    }

    static func clusters(_ frames: [Frame], _ analyses: [ExposureAnalysis], gates: Gates) -> [[Int]] {
        var clusters: [[Int]] = []
        for (i, frame) in frames.enumerated() {
            var split = true
            if i > 0, let a = frames[i - 1].info.captureDate, let b = frame.info.captureDate, abs(b.timeIntervalSince(a)) <= gates.time {
                split = false
                let p = analyses[i - 1], q = analyses[i]
                if let limit = gates.ev, let x = frames[i - 1].info.sceneEV100, let y = frame.info.sceneEV100, abs(x - y) > limit { split = true }
                if let x = frames[i - 1].info.flashFired, let y = frame.info.flashFired, x != y { split = true }
                if let limit = gates.mired, let x = p.asShotTemperature, let y = q.asShotTemperature, x > 0, y > 0,
                   abs(1e6 / x - 1e6 / y) > limit { split = true }
                if let limit = gates.histogram, let d = p.histogramDistance(to: q), d > limit { split = true }
            }
            if split { clusters.append([i]) } else { clusters[clusters.count - 1].append(i) }
        }
        return clusters
    }

    /// Print levels for a scenario: each frame's bounded level pulled toward its cluster's median,
    /// keeping `keep` of its departure and at most `cap` stops of it, in the frame's own level
    /// (as `RollSmoothing` does) or in absolute light, its level plus the EV it was exposed for.
    static func levels(_ s: Scenario, keep: Float, cap: Float, absolute: Bool = false) -> [Float] {
        var levels = [Float](repeating: 0, count: s.shots.count)
        let evs = s.evs
        for cluster in s.clusters {
            let own = cluster.map { AutoPrint.levelStops(s.analyses[$0]) }
            let offsets = cluster.map { absolute ? Float(evs[$0]) : 0 }
            let values = zip(own, offsets).map { $0 + $1 }
            let median = RollSmoothing.median(values)
            for (k, index) in cluster.enumerated() {
                let pulled = median + min(max(keep * (values[k] - median), -cap), cap) - offsets[k]
                levels[index] = min(max(pulled, -AutoPrint.bound), AutoPrint.darkenLimit)
            }
        }
        return levels
    }

    /// The print rules compared: none, each frame on its own, the shipped smoothing (through
    /// `RollSmoothing` itself), and variants of its two constants and of the light it smooths.
    static func rules(_ s: Scenario) -> [(String, [Float])] {
        let aims = RollSmoothing.aims(s.frames, analyses: s.analysesByURL)
        let shipped = s.frames.map { aims[$0.url]!.level }
        var rules: [(String, [Float])] = [
            ("no adjustment", [Float](repeating: 0, count: s.shots.count)),
            ("each frame alone", s.analyses.map { AutoPrint.levelStops($0) }),
            ("shipped: keep 0.5, cap 1/3", shipped),
        ]
        for (keep, cap) in [(Float(0.75), Float(1.0 / 3)), (0.25, 1.0 / 3), (0, 0), (0.5, 1.0 / 6), (0.5, 0.5), (0.5, .infinity)] {
            rules.append((String(format: "keep %.2f, cap %@", keep, cap.isFinite ? String(format: "%.2f", cap) : "none"),
                          levels(s, keep: keep, cap: cap)))
        }
        for (keep, cap) in [(Float(0.5), Float(1.0 / 3)), (0.5, .infinity), (0, 0)] {
            rules.append((String(format: "absolute light, keep %.2f, cap %@", keep, cap.isFinite ? String(format: "%.2f", cap) : "none"),
                          levels(s, keep: keep, cap: cap, absolute: true)))
        }
        return rules
    }

    /// The pooled standard deviation of `values` within `groups`, and the groups counted.
    static func pooledSD(_ values: [Double], _ groups: [[Int]]) -> Double {
        var sum = 0.0, degrees = 0
        for group in groups where group.count > 1 {
            let mean = group.map { values[$0] }.reduce(0, +) / Double(group.count)
            sum += group.map { (values[$0] - mean) * (values[$0] - mean) }.reduce(0, +)
            degrees += group.count - 1
        }
        return degrees > 0 ? (sum / Double(degrees)).squareRoot() : 0
    }

    /// The share of the frames in `groups` lying more than `limit` from their group's median.
    static func shareAway(_ values: [Double], _ groups: [[Int]], _ limit: Double) -> (Int, Int) {
        var away = 0, count = 0
        for group in groups where group.count > 1 {
            let median = GateMeasureTests.median(group.map { values[$0] })
            away += group.filter { abs(values[$0] - median) > limit }.count
            count += group.count
        }
        return (away, count)
    }

    /// Each frame's print level against its cluster's median, pooled over clusters of two or more:
    /// the per-frame departures a roll keeps, in the units of an editor's exposure setting.
    static func departures(_ levels: [Float], _ clusters: [[Int]]) -> [Double] {
        var out: [Double] = []
        for cluster in clusters where cluster.count > 1 {
            let median = RollSmoothing.median(cluster.map { levels[$0] })
            out += cluster.map { Double(levels[$0] - median) }
        }
        return out
    }

    /// The size of departures: median, 90th percentile and largest, and the shares within a sixth
    /// and a third of a stop.
    static func spread(_ values: [Double]) -> String {
        let a = values.map(abs).sorted()
        guard let last = a.last else { return "n 0" }
        func at(_ q: Double) -> Double { a[min(a.count - 1, Int(q * Double(a.count)))] }
        func share(_ limit: Double) -> Double { Double(a.filter { $0 <= limit + 1e-6 }.count) / Double(a.count) * 100 }
        let exact = "; exact within 1/6 \(a.filter { $0 <= 1.0 / 6 + 1e-6 }.count)/\(a.count), 1/3 \(a.filter { $0 <= 1.0 / 3 + 1e-6 }.count)/\(a.count)"
        return String(format: "n %d, |departure| median %.3f, p90 %.3f, max %.3f; within 1/6 stop %.0f%%, 1/3 %.0f%%",
                      a.count, at(0.5), at(0.9), last, share(1.0 / 6), share(1.0 / 3))
            + exact
    }

    /// CIE L*, a*, b* of a display-linear Rec. 2020 colour against white at 1 (D65).
    static func lab(_ rgb: SIMD3<Float>) -> SIMD3<Double> {
        let c = SIMD3<Double>(rgb)
        let x = 0.6369580 * c.x + 0.1446169 * c.y + 0.1688810 * c.z
        let y = 0.2627002 * c.x + 0.6779981 * c.y + 0.0593017 * c.z
        let z = 0.0000000 * c.x + 0.0280727 * c.y + 1.0609851 * c.z
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        let fx = f(max(x, 0) / 0.95047), fy = f(max(y, 0)), fz = f(max(z, 0) / 1.08883)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// A gray exposed `stops` against a metered mid-gray, its channels carrying `light`, printed
    /// through `stock` with `settings`, display-linear.
    static func printedGray(_ stops: Double, light: SIMD3<Float> = .zero, _ settings: DevelopSettings, stock: Stock) -> SIMD3<Float> {
        L.printed(SIMD3(repeating: Float(stops)) + light, settings, stock: stock)
    }

    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func measure() throws {
        let cameras = try Self.loadShots()
        try #require(cameras.reduce(0, { $0 + $1.count }) == L.expectedFrameCount,
                     "Cube++ sequence cohort is incomplete")
        let stock = try Stock.load(from: FrameViewMeasureTests.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let neutral = RollControls(labBalance: .neutral)
        let total = cameras.map(\.count).reduce(0, +)
        print("SERIES \(total) Cube++ frames on \(cameras.count) cameras: " + cameras.map { "\($0[0].camera) \($0.count)" }.joined(separator: ", "))
        let programs = Dictionary(grouping: cameras.flatMap { $0 }, by: \.program).mapValues(\.count).sorted { $0.key < $1.key }
        print("SERIES exposure programs (1 manual, 2 program, 3 aperture, 4 shutter): \(programs)")
        print("SERIES frames with exposure compensation: \(cameras.flatMap { $0 }.filter { $0.bias != 0 }.count)")

        // 1. The splits against the measured light, on neighbouring frames up to two minutes apart.
        var pairs: [(same: Bool?, ev: Double, mired: Double, histogram: Double, light: Double, redBlue: Double, green: Double)] = []
        var levelGaps: [(gap: Double, histogram: Double)] = []
        for shots in cameras {
            let analyses = shots.map { Self.analysis($0) }
            for i in shots.indices.dropFirst() where shots[i].date.timeIntervalSince(shots[i - 1].date) <= RollSmoothing.timeGap {
                let a = shots[i - 1], b = shots[i]
                let light = abs(a.absoluteGray - b.absoluteGray)
                let (rbA, gA) = AutoBalance.axes(a.light), (rbB, gB) = AutoBalance.axes(b.light)
                let redBlue = Double(abs(rbA - rbB) / AutoBalance.stopsPerMired), green = Double(abs(gA - gB))
                let same: Bool? = light <= 1.0 / 3 && redBlue <= 10 && green <= 0.1 ? true
                    : light > 2.0 / 3 || redBlue > 20 || green > 0.2 ? false : nil
                let kelvin = (analyses[i - 1].asShotTemperature ?? 0, analyses[i].asShotTemperature ?? 0)
                let mired = kelvin.0 > 0 && kelvin.1 > 0 ? Double(abs(1e6 / kelvin.0 - 1e6 / kelvin.1)) : 0
                let histogram = Double(analyses[i - 1].histogramDistance(to: analyses[i]) ?? 0)
                pairs.append((same, abs(a.ev - b.ev), mired, histogram, light, redBlue, green))
                if abs(a.ev - b.ev) <= RollSmoothing.evJump {
                    levelGaps.append((Double(abs(AutoPrint.levelStops(analyses[i - 1]) - AutoPrint.levelStops(analyses[i]))), histogram))
                }
            }
        }
        // The histogram split and the level: two frames whose bounded levels differ by more than
        // two thirds of a stop are the only ones the cap can hold (half of the gap past a third).
        for gap in [1.0 / 3, 2.0 / 3] {
            let wide = levelGaps.filter { $0.gap > gap }
            print(String(format: "SERIES neighbours within two minutes and one EV: %d; bounded levels over %.2f stops apart %d, of which the histogram splits %d",
                         levelGaps.count, gap, wide.count, wide.filter { $0.histogram > Double(RollSmoothing.histogramDistance) }.count))
        }
        // The same neighbours with one exposure per scene, as a photographer in manual would give
        // them: a change of light now moves the histogram, a change of framing still does.
        var manual: [(same: Bool?, histogram: Double)] = []
        for shots in cameras {
            let s = Scenario(shots, oneExposurePerScene: true)
            for i in shots.indices.dropFirst() where shots[i].date.timeIntervalSince(shots[i - 1].date) <= RollSmoothing.timeGap {
                let a = shots[i - 1], b = shots[i]
                let light = abs(a.absoluteGray - b.absoluteGray)
                let (rbA, gA) = AutoBalance.axes(a.light), (rbB, gB) = AutoBalance.axes(b.light)
                let redBlue = Double(abs(rbA - rbB) / AutoBalance.stopsPerMired), green = Double(abs(gA - gB))
                manual.append((light <= 1.0 / 3 && redBlue <= 10 && green <= 0.1 ? true : light > 2.0 / 3 || redBlue > 20 || green > 0.2 ? false : nil,
                               Double(s.analyses[i - 1].histogramDistance(to: s.analyses[i]) ?? 0)))
            }
        }
        for threshold in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
            let sameM = manual.filter { $0.same == true }, changedM = manual.filter { $0.same == false }
            print(String(format: "SERIES one exposure per scene, histogram threshold %.2f: same light split %d of %d (%.1f%%), changed split %d of %d",
                         threshold, sameM.filter { $0.histogram > threshold }.count, sameM.count,
                         Double(sameM.filter { $0.histogram > threshold }.count) / Double(max(1, sameM.count)) * 100,
                         changedM.filter { $0.histogram > threshold }.count, changedM.count))
        }
        let kept = levelGaps.filter { $0.histogram <= Double(RollSmoothing.histogramDistance) }
        print(String(format: "SERIES neighbours the histogram keeps together (%d): level gap median %.3f, p90 %.3f, max %.3f",
                     kept.count, GateMeasureTests.median(kept.map(\.gap)), kept.map(\.gap).sorted()[min(kept.count - 1, Int(0.9 * Double(kept.count)))],
                     kept.map(\.gap).max() ?? 0))
        let same = pairs.filter { $0.same == true }, changed = pairs.filter { $0.same == false }
        print("SERIES neighbours within two minutes: \(pairs.count); same light \(same.count) (gray within 1/3 stop, 10 mired, 0.1 green), changed \(changed.count) (over 2/3 stop, 20 mired or 0.2 green), between \(pairs.count - same.count - changed.count)")
        func percentiles(_ v: [Double]) -> String {
            let s = v.sorted()
            guard !s.isEmpty else { return "-" }
            return [0.25, 0.5, 0.75, 0.9].map { String(format: "%.2f", s[min(s.count - 1, Int($0 * Double(s.count)))]) }.joined(separator: " / ")
        }
        for (name, values, limit) in [("EV", pairs.map(\.ev), RollSmoothing.evJump), ("camera WB, mired", pairs.map(\.mired), Double(RollSmoothing.whiteBalanceMired)),
                                      ("histogram, stops", pairs.map(\.histogram), Double(RollSmoothing.histogramDistance))] {
            let onSame = zip(pairs, values).filter { $0.0.same == true }.map(\.1), onChanged = zip(pairs, values).filter { $0.0.same == false }.map(\.1)
            print(String(format: "SERIES split on %@ (over %.2f): same light %d of %d, changed %d of %d; quartiles, median, 90th: same %@, changed %@",
                         name, limit, onSame.filter { $0 > limit }.count, onSame.count, onChanged.filter { $0 > limit }.count, onChanged.count,
                         percentiles(onSame), percentiles(onChanged)))
        }
        let anySplit: ((same: Bool?, ev: Double, mired: Double, histogram: Double, light: Double, redBlue: Double, green: Double)) -> Bool = {
            $0.ev > RollSmoothing.evJump || $0.mired > Double(RollSmoothing.whiteBalanceMired) || $0.histogram > Double(RollSmoothing.histogramDistance)
        }
        print(String(format: "SERIES any split: same light %d of %d split, changed light %d of %d split (missed %d)",
                     same.filter(anySplit).count, same.count, changed.filter(anySplit).count, changed.count, changed.filter { !anySplit($0) }.count))
        for threshold in [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
            print(String(format: "SERIES histogram threshold %.2f: same light split %d of %d, changed split %d of %d",
                         threshold, same.filter { $0.histogram > threshold }.count, same.count, changed.filter { $0.histogram > threshold }.count, changed.count))
        }
        for threshold in [10.0, 20.0, 30.0, 50.0] {
            print(String(format: "SERIES camera WB threshold %.0f mired: same light split %d of %d, changed split %d of %d",
                         threshold, same.filter { $0.mired > threshold }.count, same.count, changed.filter { $0.mired > threshold }.count, changed.count))
        }

        // 2. Exposure: the cube's gray printed through Portra 400 within Argent's clusters, as shot
        // and with one exposure per scene.
        for oneExposure in [false, true] {
            let scenarios = cameras.map { Scenario($0, oneExposurePerScene: oneExposure) }
            let name = oneExposure ? "one exposure per scene" : "as shot"
            var sizes: [Int] = []
            for s in scenarios { sizes += s.clusters.map(\.count) }
            let multi = sizes.filter { $0 > 1 }
            print("SERIES \(name): \(sizes.count) clusters, \(multi.count) of two or more frames holding \(multi.reduce(0, +)) frames, largest \(sizes.max() ?? 0)")
            // The light's own spread within the clusters: no print can do better without a gray card.
            var floorValues: [Double] = [], groups: [[Int]] = [], offset = 0
            for s in scenarios {
                floorValues += s.shots.map(\.absoluteGray)
                groups += s.clusters.map { $0.map { $0 + offset } }
                offset += s.shots.count
            }
            print(String(format: "SERIES %@: the gray's absolute light within clusters, pooled SD %.3f stops", name, Self.pooledSD(floorValues, groups)))
            let ruleNames = Self.rules(scenarios[0]).map(\.0)
            for (r, ruleName) in ruleNames.enumerated() {
                var stops: [Double] = [], lightness: [Double] = [], moved: [Double] = []
                for s in scenarios {
                    let levels = Self.rules(s)[r].1
                    let shipped = Self.rules(s)[2].1
                    for (i, gray) in s.grays.enumerated() {
                        let printed = Self.printedGray(gray, neutral.settings(for: stock, level: levels[i]), stock: stock)
                        stops.append(gray - Double(levels[i]))
                        lightness.append(GateMeasureTests.lightness(Double((printed * SIMD3(0.2627, 0.6780, 0.0593)).sum())))
                        moved.append(Double(abs(levels[i] - shipped[i])))
                    }
                }
                let (jnd, n) = Self.shareAway(lightness, groups, 2.3), (third, _) = Self.shareAway(lightness, groups, 5)
                print(String(format: "SERIES %@ | %-40@ printed gray within clusters: SD %.3f stops, %.2f L*; frames over 2.3 L* from their cluster's median %4.1f%%, over 5 L* %4.1f%% (n %d)",
                             name, ruleName as NSString, Self.pooledSD(stops, groups), Self.pooledSD(lightness, groups),
                             Double(jnd) / Double(n) * 100, Double(third) / Double(n) * 100, n))
            }
            // The per-frame departures a print keeps against its cluster's median, the quantity an
            // editor's exposure setting departs by within a sequence (docs/research/rolls.md).
            for r in [1, 2] {
                var all: [Double] = []
                for s in scenarios { all += Self.departures(Self.rules(s)[r].1, s.clusters) }
                print("SERIES \(name) | \(ruleNames[r]): departures from the cluster's median print, \(Self.spread(all))")
            }
        }

        // 3. Colour: the cube's gray after the print's filtration, each frame alone or as its
        // cluster, against the measured light (off design, as in M3-auto section 12) and within
        // the cluster (a* and b* through Portra 400, PPR10K's group-level consistency on a gray).
        let scenarios = cameras.map { Scenario($0, oneExposurePerScene: false) }
        let auto = RollControls(labBalance: .auto)
        var offAlone: [Double] = [], offCluster: [Double] = [], groups: [[Int]] = [], offset = 0
        var a: [String: [Double]] = [:], b: [String: [Double]] = [:]
        for s in scenarios {
            let aims = RollSmoothing.aims(s.frames, analyses: s.analysesByURL)
            for (i, shot) in s.shots.enumerated() {
                let alone = AutoBalance.cast(s.analyses[i]), cluster = aims[s.frames[i].url]!.cast
                let ideal = AutoBalance.correction(for: shot.light)
                offAlone.append(L.degrees(AutoBalance.correction(for: alone), ideal))
                offCluster.append(L.degrees(AutoBalance.correction(for: cluster), ideal))
                for (rule, settings) in [("no filtration", neutral.settings(for: stock)),
                                         ("each frame alone", auto.settings(for: stock, aim: PrintAim(cast: alone))),
                                         ("cluster's median (shipped)", auto.settings(for: stock, aim: PrintAim(cast: cluster))),
                                         ("perfect estimate", auto.settings(for: stock, aim: PrintAim(cast: shot.light)))] {
                    let c = Self.lab(Self.printedGray(0, light: shot.light, settings, stock: stock))
                    a[rule, default: []].append(c.y)
                    b[rule, default: []].append(c.z)
                }
            }
            groups += s.clusters.map { $0.map { $0 + offset } }
            offset += s.shots.count
        }
        let inMulti = Set(groups.filter { $0.count > 1 }.flatMap { $0 })
        let alone = inMulti.map { offAlone[$0] }, cluster = inMulti.map { offCluster[$0] }
        print(String(format: "SERIES colour, frames in clusters of two or more (%d): off design, each frame alone median %.2f mean %.2f within 3 degrees %.1f%%; cluster's median %.2f, %.2f, %.1f%%",
                     inMulti.count, GateMeasureTests.median(alone), GateMeasureTests.mean(alone), L.percentWithin(alone, 3),
                     GateMeasureTests.median(cluster), GateMeasureTests.mean(cluster), L.percentWithin(cluster, 3)))
        print("SERIES colour exact within 3 degrees: alone \(L.withinCount(alone, 3)), cluster median \(L.withinCount(cluster, 3))")
        for rule in ["no filtration", "each frame alone", "cluster's median (shipped)", "perfect estimate"] {
            let sa = Self.pooledSD(a[rule]!, groups), sb = Self.pooledSD(b[rule]!, groups)
            let glc = groups.filter { $0.count > 1 }.map { g -> Double in
                func variance(_ v: [Double]) -> Double { let m = v.reduce(0, +) / Double(v.count); return v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count) }
                return variance(g.map { a[rule]![$0] }) + variance(g.map { b[rule]![$0] })
            }
            print(String(format: "SERIES colour | %-28@ printed gray within clusters: SD a* %.2f, b* %.2f; group-level consistency (var a* + var b*) mean %.2f, median %.2f",
                         rule as NSString, sa, sb, GateMeasureTests.mean(glc), GateMeasureTests.median(glc)))
        }

        // 4. Brackets made from every frame, -2 to +2 stops: the level must follow the exposure,
        // so the print lands where the design puts it.
        var worst = 0.0, within = 0, count = 0
        for shot in cameras.flatMap({ $0 }) {
            let base = Self.analysis(shot).meanStops
            for shift in [-2.0, -1, 1, 2] {
                let level = Self.analysis(shot, shift: shift).meanStops
                let error = abs(Double(level - base) - shift)
                // Inside the floor and the clip, where the level should follow exactly.
                guard Double(base) + shift > -4, Double(base) + shift < 3 else { continue }
                worst = max(worst, error)
                within += error <= 0.05 ? 1 : 0
                count += 1
            }
        }
        print(String(format: "SERIES brackets: the level follows -2 to +2 stops within 0.05 on %d of %d (%.1f%%), worst %.3f", within, count,
                     Double(within) / Double(max(count, 1)) * 100, worst))

        // 5. Truth-free: dropping one frame from a cluster of three or more moves the others' print
        // by under 0.1 stop (M3-research section 5).
        for oneExposure in [false, true] {
            var drops = 0, over = 0, worstDrop: Float = 0
            for shots in cameras {
                let s = Scenario(shots, oneExposurePerScene: oneExposure)
                let aims = RollSmoothing.aims(s.frames, analyses: s.analysesByURL)
                for cluster in s.clusters where cluster.count >= 3 {
                    for dropped in cluster {
                        let after = RollSmoothing.aims(s.frames.filter { $0.url != s.frames[dropped].url }, analyses: s.analysesByURL)
                        var moved: Float = 0
                        for index in cluster where index != dropped {
                            moved = max(moved, abs(after[s.frames[index].url]!.level - aims[s.frames[index].url]!.level))
                        }
                        drops += 1
                        over += moved > 0.1 ? 1 : 0
                        worstDrop = max(worstDrop, moved)
                    }
                }
            }
            print(String(format: "SERIES %@: dropping one frame of a cluster of three or more moves another by over 0.1 stop on %d of %d drops, worst %.3f",
                         oneExposure ? "one exposure per scene" : "as shot", over, drops, worstDrop))
        }
    }

    /// The splits and the smoothing judged on neighbouring frames up to ten minutes apart, whose
    /// light the cube measured, so that every way of clustering is judged on the same pairs:
    /// under the same light the gray should print the same, and the colour Auto leaves should be
    /// where its design puts it for each frame's light.
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func gates() throws {
        let cameras = try Self.loadShots()
        try #require(cameras.reduce(0, { $0 + $1.count }) == L.expectedFrameCount,
                     "Cube++ sequence cohort is incomplete")
        let stock = try Stock.load(from: FrameViewMeasureTests.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let neutral = RollControls(labBalance: .neutral), auto = RollControls(labBalance: .auto)
        let variants: [Gates] = [
            Gates(name: "shipped (120 s, 1 EV, 20 mired, histogram 0.5)"),
            Gates(name: "histogram 0.75", histogram: 0.75),
            Gates(name: "histogram 1.0", histogram: 1.0),
            Gates(name: "histogram 1.5", histogram: 1.5),
            Gates(name: "no histogram", histogram: nil),
            Gates(name: "30 mired, no histogram", mired: 30, histogram: nil),
            Gates(name: "time and EV only", mired: nil, histogram: nil),
            Gates(name: "time only", ev: nil, mired: nil, histogram: nil),
            Gates(name: "300 s, 1 EV, 30 mired, no histogram", time: 300, mired: 30, histogram: nil),
            Gates(name: "60 s, 1 EV, 30 mired, no histogram", time: 60, mired: 30, histogram: nil),
            Gates(name: "every frame alone", time: -1),
        ]
        let smoothings: [(String, Float, Float, Bool)] = [("keep 0.5, cap 1/3", 0.5, 1.0 / 3, false), ("keep 0.25, cap 1/3", 0.25, 1.0 / 3, false),
                                                           ("keep 0, cap 0", 0, 0, false), ("absolute, keep 0.5, cap 1/3", 0.5, 1.0 / 3, true),
                                                           ("absolute, keep 0, cap 0", 0, 0, true)]
        for oneExposure in [false, true] {
            let name = oneExposure ? "one exposure per scene" : "as shot"
            // The pairs, by the measured light.
            var pairs: [(camera: Int, i: Int, same: Bool?)] = []
            for (c, shots) in cameras.enumerated() {
                for i in shots.indices.dropFirst() where shots[i].date.timeIntervalSince(shots[i - 1].date) <= 600 {
                    let a = shots[i - 1], b = shots[i]
                    let light = abs(a.absoluteGray - b.absoluteGray)
                    let (rbA, gA) = AutoBalance.axes(a.light), (rbB, gB) = AutoBalance.axes(b.light)
                    let redBlue = Double(abs(rbA - rbB) / AutoBalance.stopsPerMired), green = Double(abs(gA - gB))
                    pairs.append((c, i, light <= 1.0 / 3 && redBlue <= 10 && green <= 0.1 ? true
                        : light > 2.0 / 3 || redBlue > 20 || green > 0.2 ? false : nil))
                }
            }
            print("GATES \(name): \(pairs.count) neighbours within ten minutes, same light \(pairs.filter { $0.same == true }.count), changed \(pairs.filter { $0.same == false }.count)")
            for gates in variants {
                let scenarios = cameras.map { Scenario($0, oneExposurePerScene: oneExposure, gates: gates) }
                let multi = scenarios.flatMap(\.clusters).filter { $0.count > 1 }
                // Colour: each frame filtered by its cluster's median cast.
                var off: [Double] = [], ab: [[SIMD2<Double>]] = [], perCamera: [String] = []
                for s in scenarios {
                    var casts = [SIMD3<Float>](repeating: .zero, count: s.shots.count)
                    for cluster in s.clusters {
                        let all = cluster.map { AutoBalance.cast(s.analyses[$0]) }
                        let median = SIMD3(RollSmoothing.median(all.map(\.x)), RollSmoothing.median(all.map(\.y)), RollSmoothing.median(all.map(\.z)))
                        for index in cluster { casts[index] = median - SIMD3(repeating: median.sum() / 3) }
                    }
                    var row: [SIMD2<Double>] = [], own: [Double] = []
                    for (i, shot) in s.shots.enumerated() {
                        own.append(L.degrees(AutoBalance.correction(for: casts[i]), AutoBalance.correction(for: shot.light)))
                        off.append(own.last!)
                        let c = Self.lab(Self.printedGray(0, light: shot.light, auto.settings(for: stock, aim: PrintAim(cast: casts[i])), stock: stock))
                        row.append(SIMD2(c.y, c.z))
                    }
                    ab.append(row)
                    perCamera.append(String(format: "%.1f%%", L.percentWithin(own, 3)))
                }
                let sameColour = pairs.filter { $0.same == true }.map { p -> Double in
                    let d = ab[p.camera][p.i] - ab[p.camera][p.i - 1]
                    return (d * d).sum().squareRoot()
                }
                var line = String(format: "GATES %@ | %-40@ clusters of 2+: %3d holding %3d frames | colour: off design median %.2f, within 3 degrees %.1f%%, same-light neighbours' gray a*b* apart %.2f",
                                  name, gates.name as NSString, multi.count, multi.map(\.count).reduce(0, +),
                                  GateMeasureTests.median(off), L.percentWithin(off, 3), GateMeasureTests.mean(sameColour))
                print(line + " (by camera " + perCamera.joined(separator: ", ") + ")")
                // What the shipped smoothing does inside these clusters: how far it moves frames from
                // their own level, how often the cap holds a frame, and the departures it keeps.
                var moved: [Double] = [], capped = 0, count = 0, kept: [Double] = []
                for s in scenarios {
                    let levels = Self.levels(s, keep: RollSmoothing.pull, cap: RollSmoothing.maximumDeviation)
                    for cluster in s.clusters {
                        let own = cluster.map { AutoPrint.levelStops(s.analyses[$0]) }
                        let median = RollSmoothing.median(own)
                        for (k, index) in cluster.enumerated() {
                            moved.append(Double(abs(levels[index] - own[k])))
                            capped += abs(RollSmoothing.pull * (own[k] - median)) > RollSmoothing.maximumDeviation ? 1 : 0
                            count += 1
                        }
                    }
                    kept += Self.departures(levels, s.clusters)
                }
                print(String(format: "GATES %@ | %-40@ shipped smoothing moves frames by mean %.3f stops, p90 %.3f; the cap holds %d of %d frames; departures kept: %@",
                             name, gates.name as NSString, GateMeasureTests.mean(moved), moved.sorted()[Int(0.9 * Double(moved.count))],
                             capped, count, Self.spread(kept)))
                // Truth-free: drop each frame of a cluster of three or more and re-cluster the rest.
                var drops = 0, over = 0, worstDrop: Float = 0
                for s in scenarios {
                    let before = Self.levels(s, keep: RollSmoothing.pull, cap: RollSmoothing.maximumDeviation)
                    for cluster in s.clusters where cluster.count >= 3 {
                        for dropped in cluster {
                            var t = s
                            t.shots.remove(at: dropped); t.shifts.remove(at: dropped)
                            t.analyses.remove(at: dropped); t.frames.remove(at: dropped)
                            t.clusters = Self.clusters(t.frames, t.analyses, gates: gates)
                            let after = Self.levels(t, keep: RollSmoothing.pull, cap: RollSmoothing.maximumDeviation)
                            var moved: Float = 0
                            for index in cluster where index != dropped {
                                moved = max(moved, abs(after[index > dropped ? index - 1 : index] - before[index]))
                            }
                            drops += 1
                            over += moved > 0.1 ? 1 : 0
                            worstDrop = max(worstDrop, moved)
                        }
                    }
                }
                print(String(format: "GATES %@ | %-40@ dropping one frame of a cluster of three or more moves another by over 0.1 stop on %d of %d drops, worst %.3f",
                             name, gates.name as NSString, over, drops, worstDrop))
                for (label, keep, cap, absolute) in smoothings {
                    var printed: [[Double]] = []
                    for s in scenarios {
                        let levels = Self.levels(s, keep: keep, cap: cap, absolute: absolute)
                        printed.append(zip(s.grays, levels).map { gray, level in
                            GateMeasureTests.lightness(Double((Self.printedGray(gray, neutral.settings(for: stock, level: level), stock: stock)
                                * SIMD3(0.2627, 0.6780, 0.0593)).sum()))
                        })
                    }
                    func apart(_ same: Bool?) -> [Double] {
                        pairs.filter { $0.same == same }.map { abs(printed[$0.camera][$0.i] - printed[$0.camera][$0.i - 1]) }
                    }
                    let s = apart(true), c = apart(false)
                    let byCamera = cameras.indices.map { k -> String in
                        let v = pairs.filter { $0.same == true && $0.camera == k }.map { abs(printed[$0.camera][$0.i] - printed[$0.camera][$0.i - 1]) }
                        return String(format: "%.2f", GateMeasureTests.mean(v))
                    }.joined(separator: ", ")
                    line = String(format: "GATES %@ | %-40@ | %-28@ gray L* apart: same light mean %.2f, over 5 L* %4.1f%%; changed light mean %.2f",
                                  name, gates.name as NSString, label as NSString, GateMeasureTests.mean(s),
                                  Double(s.filter { $0 > 5 }.count) / Double(max(s.count, 1)) * 100, GateMeasureTests.mean(c))
                    print(line + " (same light by camera " + byCamera + ")")
                }
            }
        }
    }
}
