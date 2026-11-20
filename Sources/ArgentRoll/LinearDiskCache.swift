import ArgentCore
import CryptoKit
import Foundation
import Metal

/// The contact sheet's scene-linear decodes kept on disk, so a roll opened again renders from
/// files instead of decoding every raw again: 0.7 ms to read one into a texture against about
/// 160 ms to decode it (measured, docs/M2-shell.md section 8).
///
/// Each entry is one file in Caches named by its key: the raw's content (the SHA-256 of the whole
/// raw, `SourceDigests`, so a raw changed anywhere, even at the same size, is a miss), the decode pins' version, the decoder that made it (RAW 8, RAW 9
/// or the in-house one, `DecoderChoices`, so a frame from one is never read back for another), the
/// preview size, the macOS build, since an update may change what Apple's decoder returns, and the entries' own
/// `version`. The pixels are the
/// half-float texture as it is, 4.7 MB at 960 by 640; LZFSE saved a third for 560 ms a frame.
/// Least recently used entries go first once the folder passes `limitBytes`.
public final class LinearDiskCache: @unchecked Sendable {
    public let folder: URL
    public let limitBytes: Int
    private static let magic = Data("ARGENT-LINEAR-1\n".utf8)
    private let lock = NSLock()
    private let pending = NSCondition()
    private var pendingByteCount = 0
    private struct PendingWrite {
        let operation: DispatchWorkItem
        var hasWaiter = false
    }
    private var pendingWrites: [PendingWrite] = []
    private let pendingLimitBytes: Int
    private let write: @Sendable (Data, URL) throws -> Void

    /// Bytes reserved by copies and writes not yet finished.
    var pendingBytes: Int { pending.withLock { pendingByteCount } }
    private var storesSinceTrim = 0
    private let writeQueue = DispatchQueue(label: "Argent linear previews: disk", qos: .utility)

    private struct Header: Codable {
        var width: Int
        var height: Int
        var scale: Float
        var decoderVersion: String
        var pins: DecodePins?
        var readback: DecodeReadback?
        /// The picture's full size. An entry written before it was recorded has neither, and is read as before: its frame takes its own
        /// size for a mask's field, which at the sheet's size has the picture's aspect.
        var pictureWidth: Int?
        var pictureHeight: Int?
    }

    /// At most 64 MiB of pending payloads by default: about thirteen 960 by 640 frames.
    public convenience init(folder: URL = LinearDiskCache.defaultFolder, limitBytes: Int = 3 << 30,
                            pendingLimitBytes: Int = 64 << 20) {
        self.init(folder: folder, limitBytes: limitBytes, pendingLimitBytes: pendingLimitBytes,
                  write: { try $0.write(to: $1, options: .atomic) })
    }

    init(folder: URL, limitBytes: Int = 3 << 30, pendingLimitBytes: Int = 64 << 20,
         write: @escaping @Sendable (Data, URL) throws -> Void) {
        self.folder = folder
        self.limitBytes = limitBytes
        self.pendingLimitBytes = max(0, pendingLimitBytes)
        self.write = write
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        writeQueue.async { [self] in trim() }
    }

    /// Caches/Argent/Linear Previews, inside the app's container when sandboxed; a test process may not
    /// use it (`Caches`).
    public static var defaultFolder: URL {
        Caches.folder.appendingPathComponent("Linear Previews", isDirectory: true)
    }

    /// The key for `raw` decoded to `longSide` pixels with today's pins by the decoder whose
    /// version is `decoderVersion`; `nil` if the raw cannot be read whole. Reads the raw whole
    /// unless `digests` knows its version.
    public static func key(for raw: URL, longSide: Int, decoderVersion: String, lensCorrection: Bool = true, digests: SourceDigests = .shared) -> String? {
        guard let content = try? digests.digest(of: raw) else { return nil }
        return key(sha256: content.sha256, longSide: longSide, decoderVersion: decoderVersion, lensCorrection: lensCorrection)
    }

    /// The entries' version, in every key. 2 since 2026-10-29: before it, RAW 9 decodes made two at once
    /// could keep a tile of RAW 9's network black or garbled (`AppleRawDecoder`), as 36 of the 83 RAW 9
    /// entries in the owner's cache did, so no entry written before it is read (docs/decoder.md section 18).
    public static let version = "2"

    /// The key for a raw whose SHA-256 is `sha256`, as `key(for:longSide:decoderVersion:digests:)`.
    public static func key(sha256: String, longSide: Int, decoderVersion: String, lensCorrection: Bool = true) -> String {
        var hash = SHA256()
        let context = "\(version)|\(sha256)|\(DecodePins.currentVersion)|\(decoderVersion)|\(longSide)|"
            + ProcessInfo.processInfo.operatingSystemVersionString + (lensCorrection ? "" : "|decoder-lens-off")
        hash.update(data: Data(context.utf8))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ key: String) -> URL { folder.appendingPathComponent(key).appendingPathExtension("linear") }

    /// The entry for `key` in a texture from `pool`, or `nil` if there is none or it cannot be
    /// read. A hit counts as a use for eviction.
    public func load(_ key: String, pool: TexturePool) -> LinearFrame? {
        let url = file(key)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count > Self.magic.count + 4, data.prefix(Self.magic.count) == Self.magic
        else { return nil }
        var offset = Self.magic.count
        let length = data[offset..<offset + 4].withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        offset += 4
        guard length <= data.count - offset,
              let header = try? JSONDecoder().decode(Header.self, from: data[offset..<offset + length])
        else { return nil }
        offset += length
        guard header.width > 0, header.height > 0 else { return nil }
        let rowBytes = header.width.multipliedReportingOverflow(by: 8)
        let pixelBytes = rowBytes.partialValue.multipliedReportingOverflow(by: header.height)
        guard !rowBytes.overflow, !pixelBytes.overflow, data.count - offset == pixelBytes.partialValue,
              let texture = try? pool.acquire(width: header.width, height: header.height)
        else { return nil }
        data[offset...].withUnsafeBytes { pixels in
            texture.texture.replace(region: MTLRegionMake2D(0, 0, header.width, header.height), mipmapLevel: 0,
                                    withBytes: pixels.baseAddress!, bytesPerRow: rowBytes.partialValue)
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        let picture = header.pictureWidth.flatMap { width in header.pictureHeight.flatMap { try? MaskSpace(width: width, height: $0) } }
        return LinearFrame(image: texture, decoderVersion: header.decoderVersion, scale: header.scale,
                           pins: header.pins, readback: header.readback, picture: picture)
    }

    /// Waits for room, copies `frame` out of its texture, and writes it in the background.
    public func store(_ frame: LinearFrame, key: String) {
        let header = Header(width: frame.width, height: frame.height, scale: frame.scale,
                            decoderVersion: frame.decoderVersion, pins: frame.pins, readback: frame.readback,
                            pictureWidth: frame.picture?.width, pictureHeight: frame.picture?.height)
        guard let json = try? JSONEncoder().encode(header) else { return }
        let rowBytes = frame.width * 8
        let payloadBytes = Self.magic.count + 4 + json.count + rowBytes * frame.height
        pending.lock()
        while pendingByteCount > 0 && payloadBytes > pendingLimitBytes - pendingByteCount {
            if let write = pendingWrites.first, !write.hasWaiter {
                pendingWrites[0].hasWaiter = true
                pending.unlock()
                // A work-item wait donates the blocked producer's priority to the writer.
                write.operation.wait()
                pending.lock()
            } else {
                pending.wait()
            }
        }
        pendingByteCount += payloadBytes
        pending.unlock()
        var data = Self.magic
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(json)
        let start = data.count
        data.append(Data(count: rowBytes * frame.height))
        data.withUnsafeMutableBytes { buffer in
            frame.texture.getBytes(buffer.baseAddress! + start, bytesPerRow: rowBytes,
                                   from: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0)
        }
        let url = file(key), payload = data
        let operation = DispatchWorkItem { [self] in
            defer {
                pending.lock()
                pendingByteCount -= payloadBytes
                pendingWrites.removeFirst()
                pending.broadcast()
                pending.unlock()
            }
            try? write(payload, url)
            let due = lock.withLock {
                storesSinceTrim += 1
                guard storesSinceTrim >= 32 else { return false }
                storesSinceTrim = 0
                return true
            }
            if due { trim() }
        }
        pending.lock()
        pendingWrites.append(PendingWrite(operation: operation))
        writeQueue.async(execute: operation)
        pending.broadcast()
        pending.unlock()
    }

    /// Waits for the writes queued so far, for tests.
    public func flush() { writeQueue.sync {} }

    /// Deletes the least recently used entries until the folder is under `limitBytes`.
    public func trim() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
        else { return }
        var entries = files.filter { $0.pathExtension == "linear" }.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > limitBytes else { return }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > limitBytes {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    /// Empties the cache.
    public func removeAll() {
        writeQueue.sync {
            for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
