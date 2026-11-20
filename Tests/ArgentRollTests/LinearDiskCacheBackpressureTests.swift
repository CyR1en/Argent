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
            DispatchQueue.global().async {
                cache.store(frame, key: "\(index)")
                #expect(cache.pendingBytes <= 2048)
                producers.leave()
            }
        }
        #expect(entered.wait(timeout: .now() + 5) == .success)
        defer { for _ in 0..<20 { gate.signal() } }
        #expect(producers.wait(timeout: .now() + 0.1) == .timedOut)
        #expect(cache.pendingBytes > 0 && cache.pendingBytes <= 2048)
        let flushed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { cache.flush(); flushed.signal() }
        #expect(flushed.wait(timeout: .now() + 0.1) == .timedOut)
        for _ in 0..<20 { gate.signal() }
        #expect(producers.wait(timeout: .now() + 10) == .success)
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
