import ArgentCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ArgentRoll

/// The SPEC performance targets the engine answers for alone (docs/SPEC.md#performance-targets, M5):
/// T4 a frame developed to JPEG, T5 and T6 a roll's throughput and the develop's peak footprint, and
/// T8 the output's stability across builds. Each develops through `RollDeveloper` set up as the app
/// sets it up, its defaults with the six stocks, and with the app's default render: Portra 400,
/// Natural grain, capture sharpening, sRGB at full size. The raws are linked into a scratch roll so
/// no recipe lands beside the originals. They need the samples (and the corpus for the gate roll) and
/// build/stocks, and run only with ARGENT_MEASURE=1, in a release build with testing on, one process
/// a test; scripts/measure/m5/engine.zsh runs them all:
///
///     ARGENT_MEASURE=1 [ARGENT_REPEATS=20] swift test -c release -Xswiftc -enable-testing --skip-build --filter PerformanceTargetMeasureTests/singleFrame
///     ARGENT_MEASURE=1 ARGENT_ROLL=<folder> [ARGENT_FORMAT=0|1|2] swift test ... --filter PerformanceTargetMeasureTests/roll
///     ARGENT_MEASURE=1 ARGENT_OUTPUT_REFERENCE=<folder> [ARGENT_RECORD=1] swift test ... --filter PerformanceTargetMeasureTests/outputStability
@Suite(.serialized) struct PerformanceTargetMeasureTests {
    typealias M = FrameViewMeasureTests
    static var enabled: Bool { M.enabled }
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// The six stocks, as the app's developer gets them, and the one the app's develops default to.
    static func stocks() throws -> (all: [Stock], used: Stock) {
        let all = StockLibrary.load(from: DecoderSwitchMeasureTests.stocks).stocks
        return (all, try #require(all.first { $0.id == "kodak-portra-400" }))
    }

    /// A scratch roll of hard links to `files`, so the develop's recipes land in the scratch folder. A
    /// link changes its raw's status time, so it waits out `SourceDigests`' settle before the raws are
    /// read, as a camera's raws are long settled; a digest read sooner is not kept.
    static func roll(_ files: [URL], in root: URL) async throws -> [Frame] {
        let folder = root.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            let link = folder.appendingPathComponent(file.lastPathComponent)
            do { try FileManager.default.linkItem(at: file, to: link) } catch { try FileManager.default.copyItem(at: file, to: link) }
        }
        try await Task.sleep(for: .nanoseconds(SourceDigests.shared.settleNanoseconds + 100_000_000))
        return await RollScanner.scan(folder).frames
    }

    /// Each frame's job as the app's Develop makes it with nothing changed, less the auto measurement:
    /// the print aim is the default one, which costs the render nothing more or less.
    static func jobs(_ frames: [Frame], stock: Stock) throws -> [RollDeveloper.Job] {
        try frames.map { frame in
            RollDeveloper.Job(frame: frame, recipe: try Recipe.make(
                frame: frame, byteCount: RecipeStore.byteCount(of: frame.url), stock: stock, stockDigest: stock.digest,
                roll: RollControls(), own: FrameControls(), grain: OutputSettings().grain, sharpen: true))
        }
    }

    /// The raws' SHA-256 put in the shared digests, as the sheet's previews put them there before a
    /// develop, each read in a pool of its own: `SourceDigests.read` leaves its chunks to the calling
    /// thread's pool, and the develop's check holds them until it ends (480 MB for ten lossless L raws,
    /// measured), which would raise the gate's floor for the whole develop.
    static func hash(_ frames: [Frame]) throws {
        for frame in frames { _ = try autoreleasepool { try SourceDigests.shared.digest(of: frame.url) } }
    }

    /// How many frames the run's route gives each decoder by their headers, RAW 9, the in-house decoder
    /// and RAW 8, and how many of those RAW 9 or the in-house decoder took fell back to RAW 8 during the run.
    static func decoders(_ frames: [Frame], _ choices: DecoderChoices) -> String {
        let byHeader = frames.map { DecoderChoice.of($0.url, route: choices.route) }
        func count(_ decoder: DecoderChoice) -> Int { byHeader.filter { $0 == decoder }.count }
        let fellBack = zip(frames, byHeader).filter { $1 != .apple && choices.choice(for: $0.url) != $1 }.map(\.0)
        return "\(DecoderSwitchMeasureTests.routeName(choices.route)), of \(frames.count) frames by header RAW 9 \(count(.raw9)), "
            + "in-house \(count(.inHouse)), RAW 8 \(count(.apple)), "
            + "\(fellBack.count) fell back to RAW 8\(fellBack.isEmpty ? "" : " (\(fellBack.map(\.name).joined(separator: ", ")))")"
    }

    static func failures(_ outcomes: [RollDeveloper.Outcome]) -> [String] {
        outcomes.compactMap { if case .failed(let reason) = $0 { reason } else { nil } }
    }

    /// T4: the CC0 lossless L sample (or ARGENT_FRAME) developed alone to a full-size JPEG, decode to
    /// file, ARGENT_REPEATS times (20) after one develop that compiles the shaders. Each is a develop of
    /// a one-frame roll into a new folder, trimmed after as the app trims, with the raw's SHA-256 known.
    @Test(.enabled(if: enabled))
    func singleFrame() async throws {
        let repeats = Self.environment["ARGENT_REPEATS"].flatMap(Int.init) ?? 20
        let file = Self.environment["ARGENT_FRAME"].map { URL(fileURLWithPath: $0) } ?? InHouseDecoderMeasureTests.lossless
        let (stocks, stock) = try Self.stocks()
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let frames = try await Self.roll([file], in: root)
        let jobs = try Self.jobs(frames, stock: stock)
        try Self.hash(frames)
        let developer = try RollDeveloper(stocks: stocks, software: "Argent measure", library: root.appendingPathComponent("library"))
        let clock = ContinuousClock()
        var times: [Double] = [], first = 0.0, bytes = 0
        for pass in 0...repeats {
            let out = root.appendingPathComponent("out-\(pass)")
            let start = clock.now
            let outcomes = await developer.develop(jobs, to: out, output: OutputSettings())
            let ms = M.ms(clock.now - start)
            developer.trim()
            guard case .developed(let written) = outcomes[0] else {
                Issue.record("pass \(pass): \(outcomes[0])")
                return
            }
            if pass == 0 { first = ms } else { times.append(ms) }
            bytes = (try? FileManager.default.attributesOfItem(atPath: written.path)[.size] as? Int) ?? 0
            try? FileManager.default.removeItem(at: out)
        }
        print(String(format: "MEASURE T4 one frame to full-size JPEG, decode to file: %@; first develop %.1f ms; %@; %.1f MB; load %@",
                     M.summary(times), first, Self.decoders(frames, developer.decoderChoices), Double(bytes) / 1e6,
                     InHouseDecoderMeasureTests.loadAverage()))
    }

    /// T5 and T6: the roll in ARGENT_ROLL developed at full size to JPEG, or HEIC or 16-bit TIFF with
    /// ARGENT_FORMAT 1 or 2, with the raws' SHA-256 known (`hash`, timed apart), or with none known and
    /// read in the develop's check with ARGENT_UNHASHED=1. The frames a second over the whole develop,
    /// after the raws' check (the first frame let in), from the first frame written to the last, and
    /// over the slowest run of 30 frames written; and the process's peak footprint during the develop.
    @Test(.enabled(if: enabled && environment["ARGENT_ROLL"] != nil))
    func roll() async throws {
        let index = Self.environment["ARGENT_FORMAT"].flatMap(Int.init) ?? 0
        let format: OutputSettings.Format = [.jpeg, .heic, .tiff16][index]
        let files = RollScanner.rawFiles(in: URL(fileURLWithPath: Self.environment["ARGENT_ROLL"]!))
        let (stocks, stock) = try Self.stocks()
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let frames = try await Self.roll(files, in: root)
        let jobs = try Self.jobs(frames, stock: stock)
        let clock = ContinuousClock()
        let unhashed = Self.environment["ARGENT_UNHASHED"] != nil
        let hashing = clock.now
        if !unhashed { try Self.hash(frames) }
        let hashed = M.ms(clock.now - hashing) / 1000
        // ARGENT_DECODE_TILE replaces RAW 9's decode tile, 0 for decodes rendered whole, for measuring.
        // Left unset, RollDeveloper picks the tile from each develop's memory target.
        let explicitTile: Int?? = Self.environment["ARGENT_DECODE_TILE"].flatMap(Int.init).map { $0 > 0 ? $0 : nil }
        let developer = try RollDeveloper(stocks: stocks, software: "Argent measure", library: root.appendingPathComponent("library"),
                                          digests: unhashed ? SourceDigests() : .shared, learnedDecodeTile: explicitTile)
        let start = clock.now
        let admitted = Stamps(), written = Stamps()
        developer.observeStage = { _, stage, begins in if stage == .admit, begins { admitted.note(M.ms(clock.now - start) / 1000) } }
        var outcomes: [RollDeveloper.Outcome] = []
        let (base, peak) = await peakFootprint {
            outcomes = await developer.develop(jobs, to: root.appendingPathComponent("out"), output: OutputSettings(format: format)) { _, outcome in
                if case .developed = outcome { written.note(M.ms(clock.now - start) / 1000) }
            }
        }
        let seconds = M.ms(clock.now - start) / 1000
        let checked = admitted.values.first ?? 0, done = written.values
        let window = min(30, done.count - 1)
        var slowest = Double.infinity
        if window > 0 {
            for i in 0..<(done.count - window) { slowest = min(slowest, Double(window) / max(done[i + window] - done[i], 1e-9)) }
        }
        let steady = done.count > 1 ? Double(done.count - 1) / max(done.last! - done.first!, 1e-9) : 0
        let failed = Self.failures(outcomes)
        print(String(format: "MEASURE T5 %d frames to full-size %@: %d written, %d failed, in %.1f s; %.2f frames a second overall, %.2f after the raws' check (%.1f s), %.2f first to last written, %.2f over the slowest %d; %@; %@; load %@",
                     jobs.count, format.title, done.count, failed.count, seconds, Double(done.count) / seconds,
                     Double(done.count) / max(seconds - checked, 1e-9), checked, steady, window > 0 ? slowest : 0, window,
                     unhashed ? "no SHA-256 known" : String(format: "SHA-256 known, read before in %.1f s", hashed),
                     Self.decoders(frames, developer.decoderChoices), InHouseDecoderMeasureTests.loadAverage()))
        let usedTile = developer.lastLearnedDecodeTile
        print("MEASURE T6 develop to \(format.title), \(jobs.count) frames, RAW 9 decode tile \(usedTile.map(String.init) ?? "whole"): footprint \(base >> 20) MB at start, peak \(peak >> 20) MB "
              + "(target 2000), budget \((developer.lastMemoryTarget ?? developer.memoryTarget) >> 20) MB; \(developer.lastGateReport ?? "no gate report")")
        for reason in failed.prefix(5) { print("MEASURE failed: \(reason)") }
        #expect(failed.isEmpty, "\(failed.count) of \(jobs.count) frames failed")
    }

    /// T8: the five CC0 samples, one in each raw mode, RAW 9's three and RAW 8's two, developed to full-size 16-bit
    /// TIFF and compared with the TIFFs a build recorded in ARGENT_OUTPUT_REFERENCE, pixel by pixel
    /// in CIEDE2000 against D65; with ARGENT_RECORD=1 this build records them there instead, into a
    /// folder with no TIFFs. A frame is within the target when its mean is under 0.5; a frame not
    /// compared leaves the verdict INCOMPLETE, with the frames compared of the frames developed.
    @Test(.enabled(if: enabled && environment["ARGENT_OUTPUT_REFERENCE"] != nil))
    func outputStability() async throws {
        let reference = URL(fileURLWithPath: Self.environment["ARGENT_OUTPUT_REFERENCE"]!)
        let record = Self.environment["ARGENT_RECORD"] != nil
        let references = (try? FileManager.default.contentsOfDirectory(atPath: reference.path))?.filter { $0.hasSuffix(".tif") } ?? []
        if record { #expect(references.isEmpty, "\(reference.path) already holds references") } else {
            #expect(!references.isEmpty, "no references in \(reference.path); record them first with ARGENT_RECORD=1")
        }
        let files = RollScanner.rawFiles(in: M.root.appendingPathComponent("samples")).sorted { $0.path < $1.path }
        try #require(files.count == 5)
        let (stocks, stock) = try Self.stocks()
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let frames = try await Self.roll(files, in: root)
        let developer = try RollDeveloper(stocks: stocks, software: "Argent measure", library: root.appendingPathComponent("library"))
        let out = record ? reference : root.appendingPathComponent("out")
        let outcomes = await developer.develop(try Self.jobs(frames, stock: stock), to: out, output: OutputSettings(format: .tiff16))
        try #require(Self.failures(outcomes).isEmpty, "\(Self.failures(outcomes))")
        let decoders = Self.decoders(frames, developer.decoderChoices)
        if record {
            print("MEASURE T8 recorded \(outcomes.count) references in \(reference.path); \(decoders)")
            return
        }
        var worst = 0.0, compared = 0
        for outcome in outcomes {
            let file = try #require(outcome.file)
            let name = file.lastPathComponent
            guard let new = Self.pixels(file), let old = Self.pixels(reference.appendingPathComponent(name)) else {
                Issue.record("\(name): no reference, or a file that cannot be read")
                continue
            }
            guard new.width == old.width, new.height == old.height, new.space == old.space else {
                Issue.record("\(name): \(new.width) × \(new.height) \(new.space) against the reference's \(old.width) × \(old.height) \(old.space)")
                continue
            }
            let d = Self.deltaE(new.values, old.values)
            worst = max(worst, d.mean)
            compared += 1
            print(String(format: "MEASURE T8 %@: dE2000 per pixel mean %.4f, p95 %.2f, p99 %.2f, max %.2f, %.4f%% of pixels over 0.5, %.4f%% identical",
                         name, d.mean, d.p95, d.p99, d.max, 100 * d.over, 100 * d.same))
        }
        let verdict = compared < outcomes.count ? "INCOMPLETE \(compared)/\(outcomes.count)" : worst < 0.5 ? "within" : "OVER"
        print(String(format: "MEASURE T8 output stability against %@: worst frame's mean dE2000 %.4f over %d of %d frames (target under 0.5), %@",
                     reference.path, worst, compared, outcomes.count, verdict))
        print("MEASURE T8 decoders: \(decoders); RAW 9 decode tile \(developer.lastLearnedDecodeTile.map(String.init) ?? "whole"), budget \((developer.lastMemoryTarget ?? developer.memoryTarget) >> 20) MB")
    }

    /// A 16-bit file's pixels as stored, drawn into its own colour space: RGBA, 16 bits a channel.
    static func pixels(_ url: URL) -> (width: Int, height: Int, space: String, values: [UInt16])? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let space = image.colorSpace else { return nil }
        let (width, height) = (image.width, image.height)
        var values = [UInt16](repeating: 0, count: width * height * 4)
        let drawn = values.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 16,
                                          bytesPerRow: width * 8, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (width, height, (space.name as String?) ?? "unnamed", values) : nil
    }

    /// CIEDE2000 per pixel between two sRGB pictures: the mean, the 95th and 99th percentiles (to
    /// 0.01), the largest, and the shares of pixels over 0.5 and identical.
    static func deltaE(_ a: [UInt16], _ b: [UInt16]) -> (mean: Double, p95: Double, p99: Double, max: Double, over: Double, same: Double) {
        let linear = (0...65535).map { v -> Double in
            let c = Double(v) / 65535
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        // Linear sRGB into linear Rec. 2020, which `Colour.lab` takes.
        func lab(_ p: [UInt16], _ i: Int) -> SIMD3<Double> {
            let r = linear[Int(p[i])], g = linear[Int(p[i + 1])], b = linear[Int(p[i + 2])]
            return Colour.lab(SIMD3(0.627404 * r + 0.329283 * g + 0.043313 * b,
                                    0.069097 * r + 0.919540 * g + 0.011362 * b,
                                    0.016391 * r + 0.088013 * g + 0.895595 * b))
        }
        var bins = [Int](repeating: 0, count: 2001)
        var sum = 0.0, largest = 0.0, over = 0, same = 0
        let count = a.count / 4
        for i in stride(from: 0, to: a.count, by: 4) {
            guard a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] else {
                same += 1
                bins[0] += 1
                continue
            }
            let e = Colour.deltaE2000(lab(a, i), lab(b, i))
            sum += e
            largest = max(largest, e)
            if e > 0.5 { over += 1 }
            bins[min(Int(e * 100), 2000)] += 1
        }
        func percentile(_ q: Double) -> Double {
            var seen = 0
            for (bin, n) in bins.enumerated() {
                seen += n
                if Double(seen) >= q * Double(count) { return Double(bin) / 100 }
            }
            return 20
        }
        return (sum / Double(count), percentile(0.95), percentile(0.99), largest, Double(over) / Double(count), Double(same) / Double(count))
    }
}

/// Times in seconds noted from several threads, in order.
final class Stamps: @unchecked Sendable {
    private let lock = NSLock()
    private var stamps: [Double] = []
    func note(_ value: Double) { lock.withLock { stamps.append(value) } }
    var values: [Double] { lock.withLock { stamps.sorted() } }
}
