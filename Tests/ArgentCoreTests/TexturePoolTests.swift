import Metal
import Testing
@testable import ArgentCore

@Suite struct TexturePoolTests {
    private func identity(_ texture: MTLTexture) -> ObjectIdentifier { ObjectIdentifier(texture as AnyObject) }

    @Test func reusesATextureOnceItsLeaseEnds() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = TexturePool(device: device)
        var first: ObjectIdentifier
        do {
            let lease = try pool.acquire(width: 64, height: 32)
            first = identity(lease.texture)
            withExtendedLifetime(lease) { #expect(pool.idleCount == 0) }
        }
        #expect(pool.idleCount == 1)

        let again = try pool.acquire(width: 64, height: 32)
        #expect(identity(again.texture) == first)
        #expect(pool.allocationCount == 1)
        #expect(pool.idleCount == 0)
    }

    @Test func keepsATextureCheckedOutWhileItIsHeld() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = TexturePool(device: device)
        let held = try pool.acquire(width: 16, height: 16)
        let other = try pool.acquire(width: 16, height: 16)
        withExtendedLifetime((held, other)) {
            #expect(identity(held.texture) != identity(other.texture))
            #expect(pool.allocationCount == 2)
        }
    }

    @Test func doesNotMixSizesOrUsages() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = TexturePool(device: device)
        do {
            _ = try pool.acquire(width: 16, height: 16)
        }
        let differentSize = try pool.acquire(width: 16, height: 17)
        let differentUsage = try pool.acquire(width: 16, height: 16, usage: .shaderRead)
        withExtendedLifetime((differentSize, differentUsage)) {
            #expect(differentSize.height == 17)
            #expect(differentUsage.texture.usage == .shaderRead)
            #expect(pool.allocationCount == 3)
            #expect(pool.idleCount == 1)
        }
    }

    /// A field in `rg32Float` and a frame in `rgba16Float` of one size are kept apart, at the
    /// same eight bytes a pixel.
    @Test func doesNotMixFormats() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = TexturePool(device: device)
        do {
            _ = try pool.acquire(width: 16, height: 16, pixelFormat: .rg32Float)
        }
        #expect(pool.idleByteCount == 16 * 16 * 8)
        let frame = try pool.acquire(width: 16, height: 16)
        let field = try pool.acquire(width: 16, height: 16, pixelFormat: .rg32Float)
        withExtendedLifetime((frame, field)) {
            #expect(frame.texture.pixelFormat == .rgba16Float && field.texture.pixelFormat == .rg32Float)
            #expect(pool.allocationCount == 2)
            #expect(pool.idleCount == 0)
        }
    }

    @Test func freesTexturesReturnedPastTheIdleCap() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Room for exactly one 4 by 4 rgba16Float texture, which is 128 bytes.
        let pool = TexturePool(device: device, maxIdleBytes: 128)
        do {
            let first = try pool.acquire(width: 4, height: 4)
            let second = try pool.acquire(width: 4, height: 4)
            withExtendedLifetime((first, second)) {}
        }
        #expect(pool.allocationCount == 2)
        #expect(pool.idleCount == 1)
    }

    @Test func trimDropsIdleTextures() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = TexturePool(device: device)
        do {
            _ = try pool.acquire(width: 8, height: 8)
        }
        #expect(pool.idleCount == 1)
        pool.trim()
        #expect(pool.idleCount == 0)
    }

    @Test func unpooledTexturesNeverEnterThePool() throws {
        let gpu = try GPU()
        let before = gpu.texturePool.idleCount
        do {
            let lease = PooledTexture(unpooled: try gpu.makeTexture(width: 8, height: 8))
            #expect(lease.width == 8)
        }
        #expect(gpu.texturePool.idleCount == before)
    }
}
