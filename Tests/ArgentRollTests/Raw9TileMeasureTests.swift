import CryptoKit
import Foundation
import Metal
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// Hunts RAW 9 decodes with a damaged tile: the black and gray squares found in the sheet's disk cache
/// on 2026-10-28 (docs/decoder.md section 18). Gated; each run is one process, so a shell loop gives
/// cold starts:
///
///     ARGENT_MEASURE=1 swift test -c release -Xswiftc -enable-testing --skip-build --filter Raw9TileMeasureTests
///
/// ARGENT_TILE_PATH: `buffer` renders as the sheet does (one render into a command buffer of Argent's),
/// `task` through a Core Image task of its own (the develop's way) in one tile, `develop` at full size in
/// the develop's 1024-pixel tiles. ARGENT_TILE_LANES decodes at once, ARGENT_TILE_ROUNDS rounds,
/// ARGENT_TILE_FILES raws (comma-separated paths; default the three Bayer samples), ARGENT_TILE_OUT a
/// folder for each decode's pixels, so runs can be compared to a clean reference.
@Suite(.serialized) struct Raw9TileMeasureTests {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { environment["ARGENT_MEASURE"] != nil }
    static let samples = InHouseDecoderMeasureTests.root.appendingPathComponent("samples")

    @Test(.enabled(if: enabled))
    func hunt() throws {
        let path = Self.environment["ARGENT_TILE_PATH"] ?? "buffer"
        let lanes = Self.environment["ARGENT_TILE_LANES"].flatMap(Int.init) ?? 2
        let rounds = Self.environment["ARGENT_TILE_ROUNDS"].flatMap(Int.init) ?? 1
        let out = Self.environment["ARGENT_TILE_OUT"].map { URL(fileURLWithPath: $0) }
        let all = ["ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW", "ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW",
                   "ILCE-7M4_DSC06677_FullFrame-Raw-Compressed.ARW", "ILCE-7M4_DSC06675_FullFrame-LossLess-Compressed-Medium.ARW",
                   "ILCE-7M4_DSC06676_FullFrame-LossLess-Compressed-Small.ARW"].map { Self.samples.appendingPathComponent($0) }
        let named = Self.environment["ARGENT_TILE_FILES"]
        let files = named == "all" ? all
            : named.map { $0.split(separator: ",").map { URL(fileURLWithPath: String($0)) } } ?? Array(all.prefix(3))
        // As the previews: one GPU, a Core Image context a decode. ARGENT_TILE_GPUS=1 gives each lane a GPU,
        // its own command queue, of its own; ARGENT_TILE_SHARED=1 one shared Core Image context.
        let ownGPUs = Self.environment["ARGENT_TILE_GPUS"] == "1"
        let shared = Self.environment["ARGENT_TILE_SHARED"] == "1"
        let gpu = try GPU(maxIdlePoolBytes: 64 << 20)
        let decoders = try (0..<lanes).map { lane in
            AppleRawDecoder(gpu: ownGPUs && lane > 0 ? try GPU(maxIdlePoolBytes: 64 << 20) : gpu, contextPerDecode: !shared)
        }
        // ARGENT_TILE_VERSION 9 (RAW 9, the default) or 8; ARGENT_TILE_SIDE the long side (960; 0 full size);
        // ARGENT_TILE_FILL=1 fills it as the frame view does.
        var options = DecodeOptions()
        options.appleDecoder = Self.environment["ARGENT_TILE_VERSION"] == "8" ? .classic : .learned
        let side = Self.environment["ARGENT_TILE_SIDE"].flatMap(Int.init) ?? 960
        options.maxLongSide = side > 0 ? side : nil
        options.fillsMaxLongSide = Self.environment["ARGENT_TILE_FILL"] == "1"
        switch path {
        case "buffer": break
        case "task": options.tileSize = 1 << 14; options.learnedTileSize = 1 << 14
        case "develop": options.tileSize = 768; options.learnedTileSize = 1024
        default: Issue.record("unknown path \(path)"); return
        }
        let decodeOptions = options
        var jobs: [(round: Int, url: URL)] = []
        for round in 0..<rounds { for url in files { jobs.append((round, url)) } }
        let state = HuntState(jobs: jobs, decoders: decoders)
        let start = Date()
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
            while let job = state.take() {
                autoreleasepool {
                    let began = Date().timeIntervalSince(start)
                    let line: String
                    do {
                        let frame = try state.decoders[lane].decode(job.url, options: decodeOptions)
                        let pixels = ExposureAnalyzer.pixels(of: frame.texture)
                        let report = Self.zeros(pixels, width: frame.width, height: frame.height)
                        let hash = pixels.withUnsafeBytes { SHA256.hash(data: Data($0)) }.prefix(8)
                            .map { String(format: "%02x", $0) }.joined()
                        if let out {
                            let name = "\(job.url.deletingPathExtension().lastPathComponent)-\(path)-r\(job.round).f16"
                            try? pixels.withUnsafeBytes { Data($0) }.write(to: out.appendingPathComponent(name))
                        }
                        line = String(format: "TILE %@ lane %d round %d %@ %dx%d start %.2f s took %.2f s hash %@ %@", path, lane,
                                      job.round, job.url.lastPathComponent, frame.width, frame.height, began,
                                      Date().timeIntervalSince(start) - began, hash, report)
                    } catch {
                        line = "TILE \(path) lane \(lane) round \(job.round) \(job.url.lastPathComponent) FAILED \(error)"
                    }
                    state.note(line)
                    print(line)
                }
            }
        }
        let lines = state.lines
        #expect(lines.count == jobs.count)
    }

    /// The sheet's decodes kept on disk under one key in several caches (ARGENT_TILE_CACHES, folders of
    /// copies: loading an entry touches its file), where the copies differ: each copy's zero pixels and
    /// the print level and cast Auto takes from it, as the previews measure a decode.
    @Test(.enabled(if: enabled))
    func entries() throws {
        let folders = (Self.environment["ARGENT_TILE_CACHES"] ?? "").split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let caches = folders.map { LinearDiskCache(folder: $0, limitBytes: .max) }
        var keys: [String: [Int]] = [:]
        for (index, folder) in folders.enumerated() {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".linear") {
                keys[String(name.dropLast(7)), default: []].append(index)
            }
        }
        for (key, holders) in keys.sorted(by: { $0.key < $1.key }) where holders.count > 1 {
            var copies: [(folder: String, hash: String, zeros: String, level: Float, cast: SIMD3<Float>)] = []
            for index in holders {
                autoreleasepool {
                    guard let frame = caches[index].load(key, pool: gpu.texturePool), frame.decoderVersion == "9" else { return }
                    let pixels = ExposureAnalyzer.pixels(of: frame.texture)
                    let hash = pixels.withUnsafeBytes { SHA256.hash(data: Data($0)) }.prefix(8).map { String(format: "%02x", $0) }.joined()
                    let analysis = ExposureAnalyzer.measure(frame, workingSpace: gpu.workingColorSpace).analysis
                    copies.append((folders[index].lastPathComponent, hash, Self.zeros(pixels, width: frame.width, height: frame.height),
                                   AutoPrint.levelStops(analysis), AutoBalance.cast(analysis)))
                }
            }
            guard Set(copies.map(\.hash)).count > 1 else { continue }
            for copy in copies {
                print(String(format: "ENTRY %@ %@ %@ level %+.4f cast %+.4f %+.4f %+.4f %@", String(key.prefix(12)), copy.folder, copy.hash,
                             copy.level, copy.cast.x, copy.cast.y, copy.cast.z, copy.zeros))
            }
        }
    }

    /// The hunt's queue of decodes and what they printed, shared by its lanes.
    final class HuntState: @unchecked Sendable {
        private let lock = NSLock()
        private let jobs: [(round: Int, url: URL)]
        private var next = 0
        private(set) var lines: [String] = []
        let decoders: [AppleRawDecoder]
        init(jobs: [(round: Int, url: URL)], decoders: [AppleRawDecoder]) { self.jobs = jobs; self.decoders = decoders }
        func take() -> (round: Int, url: URL)? {
            lock.withLock {
                guard next < jobs.count else { return nil }
                defer { next += 1 }
                return jobs[next]
            }
        }
        func note(_ line: String) { lock.withLock { lines.append(line) } }
    }

    /// Pixels whose red, green and blue are all exactly zero, and their bounding box: a tile RAW 9 left
    /// black. A clean decode of the samples has none.
    static func zeros(_ pixels: [Float16], width: Int, height: Int) -> String {
        var count = 0, minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                guard pixels[i] == 0, pixels[i + 1] == 0, pixels[i + 2] == 0 else { continue }
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return count == 0 ? "zeros 0" : "zeros \(count) x \(minX)-\(maxX) y \(minY)-\(maxY)"
    }
}
