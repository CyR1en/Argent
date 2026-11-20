import ArgentCore
import CryptoKit
import Darwin
import Foundation
import Metal
import Testing
@testable import ArgentRoll

/// One scenario per process: ARGENT_CACHE_SCENARIO=slow, burst, or paced with ARGENT_MEASURE=1.
/// ARGENT_CACHE_UNBOUNDED=1 disables backpressure; ARGENT_CACHE_RUN names the output folder.
@Suite(.serialized) struct LinearDiskCacheMeasureTests {
    private final class Samples: @unchecked Sendable {
        var rows: [[String: Double]] = []
        var previousEnd: Double?
    }

    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func pendingWrites() throws {
        let environment = ProcessInfo.processInfo.environment
        let scenario = environment["ARGENT_CACHE_SCENARIO"] ?? "slow"
        let unbounded = environment["ARGENT_CACHE_UNBOUNDED"] == "1"
        let gpu = try GPU()
        let image = try gpu.texturePool.acquire(width: 960, height: 640)
        let pixels = [Float16](repeating: 0.5, count: 960 * 640 * 4)
        pixels.withUnsafeBytes {
            image.texture.replace(region: MTLRegionMake2D(0, 0, 960, 640), mipmapLevel: 0,
                                  withBytes: $0.baseAddress!, bytesPerRow: 960 * 8)
        }
        let frame = LinearFrame(image: image, decoderVersion: "8", scale: 1)
        let run = environment["ARGENT_CACHE_RUN"] ?? UUID().uuidString
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("argent-cache-measure/\(run)")
        let samples = Samples()
        let wake = DispatchSemaphore(value: 0)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .global(qos: .userInitiated))
        timer.setEventHandler { wake.signal() }
        timer.resume()
        defer { timer.cancel() }
        func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
        let cache = LinearDiskCache(folder: root, pendingLimitBytes: unbounded ? .max : 64 << 20) { data, url in
            let start = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
            let qos = qos_class_self().rawValue
            if scenario == "slow" {
                if environment["ARGENT_CACHE_SLEEP"] == "1" {
                    Thread.sleep(forTimeInterval: 0.05)
                } else {
                    timer.schedule(deadline: .now() + .milliseconds(50), leeway: .nanoseconds(0))
                    wake.wait()
                }
            }
            let awake = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
            try data.write(to: url, options: .atomic)
            let end = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
            samples.rows.append(["start": start, "sleep": awake - start, "write": end - awake,
                                 "gap": samples.previousEnd.map { start - $0 } ?? 0, "qos": Double(qos)])
            samples.previousEnd = end
        }
        let count = scenario == "paced" ? 30 : 100
        let start = now()
        var peakPending = 0, longestStore = 0.0
        for index in 0..<count {
            let storeStart = now()
            cache.store(frame, key: "\(index)")
            longestStore = max(longestStore, now() - storeStart)
            peakPending = max(peakPending, cache.pendingBytes)
            if scenario == "paced", index + 1 < count { Thread.sleep(forTimeInterval: 0.16) }
        }
        let flushStart = now()
        if environment["ARGENT_CACHE_DELAY_FLUSH"] == "1" { Thread.sleep(forTimeInterval: 2) }
        cache.flush()
        let elapsed = now() - start
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var hash = SHA256()
        for index in 0..<count {
            hash.update(data: try Data(contentsOf: root.appendingPathComponent("\(index).linear")))
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let result: [String: Any] = ["run": run, "scenario": scenario, "unbounded": unbounded,
                                    "seconds": elapsed, "peakRSSBytes": usage.ru_maxrss,
                                    "peakPending": peakPending, "longestStore": longestStore,
                                    "flushStart": flushStart, "sha256": digest, "samples": samples.rows]
        let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        try json.write(to: root.appendingPathComponent("measurement.json"))
        print("CACHE-MEASURE \(String(decoding: json, as: UTF8.self))")
    }
}
