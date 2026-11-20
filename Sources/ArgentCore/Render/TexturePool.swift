import Foundation
import Metal

/// Hands out full-frame `rgba16Float` textures, and fields in `rg32Float`, and takes them back
/// when the lease ends.
///
/// A 33 MP frame is 262 MB. Allocating one per pass cost 20 to 110 ms of wall time
/// against 7 ms of GPU time in the M0 spike, so a roll allocates its working set once
/// and reuses it. Safe to call from any thread.
public final class TexturePool: @unchecked Sendable {
    struct Key: Hashable {
        let width: Int
        let height: Int
        let usage: UInt
        let pixelFormat: UInt

        /// `rgba16Float` and `rg32Float` are both eight bytes a pixel.
        var byteCount: Int { width * height * 8 }
    }

    private let device: MTLDevice
    private let maxIdleBytes: Int
    private var keepsIdle = true
    private let lock = NSLock()
    private var idle: [Key: [MTLTexture]] = [:]
    private var idleBytes = 0
    private var allocations = 0

    /// `maxIdleBytes` caps what the pool keeps while nothing is using it. A texture
    /// returned past the cap is freed instead, so a roll that mixes frame sizes cannot
    /// pin memory. The default holds three full-size frames.
    public init(device: MTLDevice, maxIdleBytes: Int = 800_000_000) {
        self.device = device
        self.maxIdleBytes = maxIdleBytes
    }

    /// Textures the pool has had to create, as opposed to reuse. Steady state is zero growth.
    public var allocationCount: Int { lock.withLock { allocations } }

    /// Textures waiting for reuse.
    public var idleCount: Int { lock.withLock { idle.values.reduce(0) { $0 + $1.count } } }

    /// The bytes of the textures waiting for reuse.
    public var idleByteCount: Int { lock.withLock { idleBytes } }

    /// `pixelFormat` is `rgba16Float`, or `rg32Float` for two channels at full precision.
    public func acquire(width: Int, height: Int, usage: MTLTextureUsage = [.shaderRead, .shaderWrite],
                        pixelFormat: MTLPixelFormat = .rgba16Float) throws -> PooledTexture {
        precondition(pixelFormat == .rgba16Float || pixelFormat == .rg32Float, "unsupported pool format")
        let key = Key(width: width, height: height, usage: usage.rawValue, pixelFormat: pixelFormat.rawValue)
        let reused: MTLTexture? = lock.withLock {
            guard let texture = idle[key]?.popLast() else { return nil }
            idleBytes -= key.byteCount
            return texture
        }
        if let reused { return PooledTexture(texture: reused, pool: self, key: key) }

        let texture = try GPU.makeTexture(device: device, width: width, height: height, usage: usage,
                                          pixelFormat: pixelFormat)
        lock.withLock { allocations += 1 }
        return PooledTexture(texture: texture, pool: self, key: key)
    }

    /// Frees every idle texture, for example under memory pressure.
    public func trim() {
        lock.withLock {
            idle.removeAll()
            idleBytes = 0
        }
    }

    /// Whether a texture given back is kept for reuse, up to `maxIdleBytes`; turning it off frees the
    /// idle ones, and until it is on again each texture given back is freed.
    public var keepsIdleTextures: Bool {
        get { lock.withLock { keepsIdle } }
        set {
            lock.withLock {
                keepsIdle = newValue
                if !newValue {
                    idle.removeAll()
                    idleBytes = 0
                }
            }
        }
    }

    fileprivate func recycle(_ texture: MTLTexture, key: Key) {
        lock.withLock {
            guard keepsIdle, idleBytes + key.byteCount <= maxIdleBytes else { return }
            idle[key, default: []].append(texture)
            idleBytes += key.byteCount
        }
    }
}

/// A texture on loan from a `TexturePool`. It goes back to the pool when the last
/// reference is released, so keep it alive until the GPU has finished with it.
public final class PooledTexture {
    public let texture: MTLTexture
    private let home: (pool: TexturePool, key: TexturePool.Key)?
    /// A number no other `PooledTexture` of this process has had, for caches keyed by what a texture held when it was made, such as a
    /// smart mask's refinement of one decode (`MaskGuideID`). A texture the pool hands out again is a new loan with a new serial, so an
    /// entry keyed by it can never be mistaken for another decode's, as an object's address could once the object is gone.
    public let serial: UInt64 = PooledTexture.serials.next()

    fileprivate init(texture: MTLTexture, pool: TexturePool, key: TexturePool.Key) {
        self.texture = texture
        self.home = (pool, key)
    }

    /// Wraps a texture that no pool owns, so code that allocates its own can still hand
    /// one to the render graph.
    public init(unpooled texture: MTLTexture) {
        self.texture = texture
        self.home = nil
    }

    public var width: Int { texture.width }
    public var height: Int { texture.height }

    private final class Serials: @unchecked Sendable {
        private let lock = NSLock()
        private var last: UInt64 = 0
        func next() -> UInt64 { lock.withLock { last += 1; return last } }
    }
    private static let serials = Serials()

    deinit {
        if let home { home.pool.recycle(texture, key: home.key) }
    }
}
