import ArgentCore
import Foundation
import Metal
import Testing
@testable import ArgentRoll

@Suite struct LinearDiskCacheBackpressureTests {
    private func frame(_ gpu: GPU) throws -> LinearFrame {
        let image = try gpu.texturePool.acquire(width: 12, height: 8)
        let pixels = [Float16](repeating: 0.5, count: 12 * 8 * 4)
        pixels.withUnsafeBytes {
            image.texture.replace(region: MTLRegionMake2D(0, 0, 12, 8), mipmapLevel: 0,
                                  withBytes: $0.baseAddress!, bytesPerRow: 96)
        }
        return LinearFrame(image: image, decoderVersion: "8", scale: 1)
    }

    /// Twenty stores on threads of their own, against a limit that holds two; their writes held until the test lets them go.
    ///
    /// What it waits for it waits on, as long as a test can take: a write begun, and every store made once the writes go. The
    /// writer is the cache's own queue, at utility, which a thread of the process's pools serves only when the suites beside this
    /// one leave it one; on a busy Mac the first write had not begun after 5 s. The producers once waited on those threads too,
    /// and twenty of them waiting for room held as many of the threads those suites share.
    @Test func boundsConcurrentStoresAndFlushWaitsForWrites() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gpu = try GPU(), frame = try frame(gpu)
        let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        let cache = LinearDiskCache(folder: folder, pendingLimitBytes: 2048) { data, url in
            entered.signal()
            gate.wait()
            try data.write(to: url, options: .atomic)
        }
        let producers = DispatchGroup()
        for index in 0..<20 {
            producers.enter()
            Thread {
                cache.store(frame, key: "\(index)")
                #expect(cache.pendingBytes <= 2048)
                producers.leave()
            }.start()
        }
        #expect(entered.wait(timeout: .now() + 60) == .success)
        defer { for _ in 0..<20 { gate.signal() } }
        #expect(producers.wait(timeout: .now() + 0.1) == .timedOut)
        #expect(cache.pendingBytes > 0 && cache.pendingBytes <= 2048)
        let flushed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { cache.flush(); flushed.signal() }
        #expect(flushed.wait(timeout: .now() + 0.1) == .timedOut)
        for _ in 0..<20 { gate.signal() }
        #expect(producers.wait(timeout: .now() + 60) == .success)
        cache.flush()
        #expect(cache.pendingBytes == 0)
        for index in 0..<20 {
            let loaded = try #require(cache.load("\(index)", pool: gpu.texturePool))
            var pixels = [Float16](repeating: 0, count: 12 * 8 * 4)
            pixels.withUnsafeMutableBytes {
                loaded.texture.getBytes($0.baseAddress!, bytesPerRow: 96,
                                        from: MTLRegionMake2D(0, 0, 12, 8), mipmapLevel: 0)
            }
            #expect(pixels.allSatisfy { $0 == 0.5 })
        }
    }

    @Test func oversizedFrameAndFailureReleaseReservation() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gpu = try GPU(), frame = try frame(gpu)
        let cache = LinearDiskCache(folder: folder, pendingLimitBytes: 1) { data, url in
            if url.lastPathComponent == "fail.linear" { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        }
        cache.flush()
        #expect(cache.pendingBytes == 0)
        cache.store(frame, key: "fail")
        cache.store(frame, key: "ok")
        cache.flush()
        #expect(cache.pendingBytes == 0)
        #expect(cache.load("fail", pool: gpu.texturePool) == nil)
        #expect(cache.load("ok", pool: gpu.texturePool) != nil)
    }
}
