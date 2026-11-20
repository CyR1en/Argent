import ArgentCore
import CryptoKit
import Foundation
import Metal
import Testing
@testable import ArgentRoll

/// What an on-disk cache of the sheet's 960-pixel linear decodes would cost against decoding
/// again, behind docs/M2-shell.md section 8. Runs only with ARGENT_MEASURE=1:
///
///     ARGENT_MEASURE=1 swift test --filter PreviewCacheMeasureTests
@Suite(.serialized) struct PreviewCacheMeasureTests {
    typealias M = FrameViewMeasureTests

    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func decodeAgainstACacheFile() throws {
        let clock = ContinuousClock()
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = AppleRawDecoder(gpu: gpu)
        let files = M.files()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for url in files { _ = try? Data(contentsOf: url).count }

        var decode: [Double] = [], copyOut: [Double] = [], writePlain: [Double] = [], writeLZ: [Double] = []
        var readPlain: [Double] = [], readLZ: [Double] = [], hashWhole: [Double] = [], hashHead: [Double] = []
        var plainBytes = 0, lzBytes = 0
        for (index, url) in files.enumerated() {
            var options = DecodeOptions()
            options.maxLongSide = FilmPreviews.previewLongSide
            var start = clock.now
            let frame = try decoder.decode(url, options: options)
            decode.append(M.ms(clock.now - start))

            start = clock.now
            let rowBytes = frame.width * 8
            var bytes = Data(count: rowBytes * frame.height)
            bytes.withUnsafeMutableBytes { buffer in
                frame.texture.getBytes(buffer.baseAddress!, bytesPerRow: rowBytes,
                                       from: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0)
            }
            copyOut.append(M.ms(clock.now - start))

            let plain = folder.appendingPathComponent("\(index).plain")
            start = clock.now
            try bytes.write(to: plain)
            writePlain.append(M.ms(clock.now - start))
            plainBytes += bytes.count

            let lz = folder.appendingPathComponent("\(index).lzfse")
            start = clock.now
            let compressed = try (bytes as NSData).compressed(using: .lzfse) as Data
            try compressed.write(to: lz)
            writeLZ.append(M.ms(clock.now - start))
            lzBytes += compressed.count

            for (file, isCompressed) in [(plain, false), (lz, true)] {
                start = clock.now
                var read = try Data(contentsOf: file)
                if isCompressed { read = try (read as NSData).decompressed(using: .lzfse) as Data }
                let texture = try gpu.texturePool.acquire(width: frame.width, height: frame.height)
                read.withUnsafeBytes { buffer in
                    texture.texture.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0,
                                            withBytes: buffer.baseAddress!, bytesPerRow: rowBytes)
                }
                let elapsed = M.ms(clock.now - start)
                if isCompressed { readLZ.append(elapsed) } else { readPlain.append(elapsed) }
                #expect(read == bytes)
            }

            start = clock.now
            _ = try RecipeStore.sha256(of: url)
            hashWhole.append(M.ms(clock.now - start))
            start = clock.now
            let handle = try FileHandle(forReadingFrom: url)
            let head = try handle.read(upToCount: 256 << 10) ?? Data()
            try handle.close()
            var hash = SHA256()
            hash.update(data: head)
            withUnsafeBytes(of: RecipeStore.byteCount(of: url)) { hash.update(bufferPointer: $0) }
            _ = hash.finalize()
            hashHead.append(M.ms(clock.now - start))
        }
        print("MEASURE 960 px decode: \(M.summary(decode))")
        print("MEASURE copy out of the texture: \(M.summary(copyOut))")
        print("MEASURE write plain: \(M.summary(writePlain)), \(plainBytes / files.count / 1024) KB a frame")
        print("MEASURE compress and write LZFSE: \(M.summary(writeLZ)), \(lzBytes / files.count / 1024) KB a frame")
        print("MEASURE read plain into a texture: \(M.summary(readPlain))")
        print("MEASURE read LZFSE into a texture: \(M.summary(readLZ))")
        print("MEASURE SHA-256 of the whole raw, warm: \(M.summary(hashWhole))")
        print("MEASURE SHA-256 of the first 256 KB and the size: \(M.summary(hashHead))")
    }
}
