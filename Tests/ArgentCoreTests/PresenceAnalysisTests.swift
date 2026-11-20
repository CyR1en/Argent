import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Fields made by hand, so the cache is tested without package B's builds: each part a small `rg32Float` texture, as a real one is.
final class HandMadeAnalysisBuilder: PresenceAnalysisBuilding, @unchecked Sendable {
    let device: MTLDevice
    /// Throws for these parts, as a build that fails would.
    var failing: PresenceAnalysis.Parts = []
    private let lock = NSLock()

    init(device: MTLDevice) { self.device = device }

    func field(width: Int = 16, height: Int = 12) throws -> MTLTexture {
        try GPU.makeTexture(device: device, width: width, height: height, usage: .shaderRead, pixelFormat: .rg32Float)
    }

    func clarity(of frame: LinearFrame, constants: PresenceConstants) throws -> PresenceAnalysis.ClarityFields {
        if lock.withLock({ failing.contains(.clarity) }) { throw PresenceError.notBuilt("a failing clarity", package: "test") }
        return .init(positive: try field(), negative: try field())
    }

    func texture(of frame: LinearFrame, constants: PresenceConstants) throws -> PresenceAnalysis.TextureBand {
        if lock.withLock({ failing.contains(.texture) }) { throw PresenceError.notBuilt("a failing texture", package: "test") }
        return .init(coefficients: try field(width: 40, height: 30), field: constants.texture.field(decodeLongSide: frame.width, fullLongSide: frame.width))
    }

    func haze(of frame: LinearFrame, constants: PresenceConstants) throws -> PresenceAnalysis.HazeEstimate {
        if lock.withLock({ failing.contains(.haze) }) { throw PresenceError.notBuilt("a failing haze", package: "test") }
        return .init(transmission: try field(), airlight: SIMD3(0.8, 0.85, 0.9))
    }
}

@Suite struct PresenceAnalysisTests {
    static let constants = PresenceConstants.named(Presence.currentVersion)!

    /// A decode of `width` pixels on its long side: a lease of its own, so a serial of its own.
    static func frame(_ gpu: GPU, width: Int = 1024, height: Int = 8) throws -> LinearFrame {
        LinearFrame(image: PooledTexture(unpooled: try gpu.makeTexture(width: width, height: height)), decoderVersion: "test", scale: 1)
    }

    static func cache(_ gpu: GPU, maximumBytes: Int = PresenceAnalyses.defaultMaximumBytes) -> (PresenceAnalyses, HandMadeAnalysisBuilder) {
        let builder = HandMadeAnalysisBuilder(device: gpu.device)
        return (PresenceAnalyses(builder: builder, maximumBytes: maximumBytes), builder)
    }

    /// Warm: the first nonzero scene control builds its part; a step of it, Clarity crossing zero, and another stock's render build
    /// nothing, since nothing in an analysis depends on a value or a stock.
    @Test func aStepBuildsNothingAndClarityCrossingZeroToo() throws {
        let gpu = try GPU()
        let (cache, _) = Self.cache(gpu)
        let frame = try Self.frame(gpu)
        let first = try cache.analysis(of: frame, parts: .needed(by: try Presence([.clarity: 20])), constants: Self.constants)
        #expect(cache.statistics.clarityBuilds == 1 && cache.statistics.builds == 1 && first.parts == .clarity)
        for value: Float in [21, 35, -40, -100, 5] {
            let step = try cache.analysis(of: frame, parts: .needed(by: try Presence([.clarity: value])), constants: Self.constants)
            #expect(step === first)
        }
        #expect(cache.statistics.builds == 1 && cache.statistics.hits == 5)
        #expect(try cache.analysis(of: frame, parts: .needed(by: try Presence([.saturation: 50])), constants: Self.constants).parts == .clarity,
                "a print control asks for nothing new")
    }

    /// Cold, a missing part: only it is built, and the new analysis shares the parts already made.
    @Test func aMissingPartIsBuiltAloneAndTheRestIsShared() throws {
        let gpu = try GPU()
        let (cache, _) = Self.cache(gpu)
        let frame = try Self.frame(gpu)
        let clarity = try cache.analysis(of: frame, parts: .clarity, constants: Self.constants)
        let both = try cache.analysis(of: frame, parts: [.clarity, .texture], constants: Self.constants)
        #expect(cache.statistics.clarityBuilds == 1 && cache.statistics.textureBuilds == 1)
        #expect(both !== clarity && both.parts == [.clarity, .texture] && clarity.parts == .clarity, "the old one is not changed")
        #expect(both.clarity?.positive === clarity.clarity?.positive && both.clarity?.negative === clarity.clarity?.negative)
        let all = try cache.analysis(of: frame, parts: [.clarity, .texture, .haze], constants: Self.constants)
        #expect(cache.statistics.builds == 3 && all.texture?.coefficients === both.texture?.coefficients)
        #expect(cache.residentBytes == all.bytes, "one analysis kept for the decode, the replaced ones let go")
    }

    /// Cold: another decode, or the same decode under another constants version, builds again.
    @Test func anotherDecodeOrConstantsVersionBuildsAgain() throws {
        let gpu = try GPU()
        let (cache, _) = Self.cache(gpu)
        let frame = try Self.frame(gpu), other = try Self.frame(gpu)
        _ = try cache.analysis(of: frame, parts: .haze, constants: Self.constants)
        _ = try cache.analysis(of: other, parts: .haze, constants: Self.constants)
        let c = Self.constants
        let next = PresenceConstants(version: "test-next", source: "", texture: c.texture, clarity: c.clarity, dehaze: c.dehaze,
                                     saturation: c.saturation, vibrance: c.vibrance, detailLimitStops: c.detailLimitStops)
        _ = try cache.analysis(of: frame, parts: .haze, constants: next)
        #expect(cache.statistics.hazeBuilds == 3 && cache.statistics.hits == 0)
        _ = try cache.analysis(of: frame, parts: .haze, constants: Self.constants)
        #expect(cache.statistics.hits == 1)
    }

    /// Cold, an eviction: the oldest analysis goes past the limit, and its decode builds again.
    @Test func anEvictedAnalysisIsBuiltAgain() throws {
        let gpu = try GPU()
        let (sizing, _) = Self.cache(gpu)
        let one = try sizing.analysis(of: try Self.frame(gpu), parts: .clarity, constants: Self.constants).bytes
        let (cache, _) = Self.cache(gpu, maximumBytes: one + one / 2)
        let first = try Self.frame(gpu), second = try Self.frame(gpu)
        _ = try cache.analysis(of: first, parts: .clarity, constants: Self.constants)
        _ = try cache.analysis(of: second, parts: .clarity, constants: Self.constants)
        #expect(cache.statistics.evictions == 1 && cache.residentBytes == one)
        _ = try cache.analysis(of: first, parts: .clarity, constants: Self.constants)
        #expect(cache.statistics.clarityBuilds == 3 && cache.statistics.hits == 0)
        cache.removeAll()
        #expect(cache.residentBytes == 0)
    }

    /// Cold, a decode under 1024 pixels (the sheet's, the strip's) and a develop's limit of 0: built for each request, never kept.
    @Test func aSmallDecodeAndADevelopKeepNothing() throws {
        let gpu = try GPU()
        let (cache, _) = Self.cache(gpu)
        let small = try Self.frame(gpu, width: 960, height: 640)
        for _ in 0..<3 { _ = try cache.analysis(of: small, parts: .texture, constants: Self.constants) }
        #expect(cache.statistics.textureBuilds == 3 && cache.statistics.unkept == 3 && cache.residentBytes == 0)
        let (develop, _) = Self.cache(gpu, maximumBytes: 0)
        let frame = try Self.frame(gpu)
        for _ in 0..<2 { _ = try develop.analysis(of: frame, parts: [.clarity, .haze], constants: Self.constants) }
        #expect(develop.statistics.builds == 4 && develop.statistics.unkept == 2 && develop.residentBytes == 0)
    }

    /// Bytes are what Metal allocated, not the texels times eight.
    @Test func bytesAreWhatMetalAllocated() throws {
        let gpu = try GPU()
        let (cache, _) = Self.cache(gpu)
        let analysis = try cache.analysis(of: try Self.frame(gpu), parts: [.clarity, .texture, .haze], constants: Self.constants)
        let textures = [analysis.clarity?.positive, analysis.clarity?.negative, analysis.texture?.coefficients, analysis.haze?.transmission]
        #expect(analysis.bytes == textures.compactMap { $0?.allocatedSize }.reduce(0, +))
        #expect(analysis.bytes >= textures.compactMap { $0.map { $0.width * $0.height * 8 } }.reduce(0, +))
        #expect(cache.residentBytes == analysis.bytes)
    }

    /// A build that fails leaves what was kept as it was.
    @Test func aFailedBuildKeepsWhatWasKept() throws {
        let gpu = try GPU()
        let (cache, builder) = Self.cache(gpu)
        let frame = try Self.frame(gpu)
        let kept = try cache.analysis(of: frame, parts: .clarity, constants: Self.constants)
        builder.failing = .texture
        #expect(throws: PresenceError.self) { try cache.analysis(of: frame, parts: [.clarity, .texture], constants: Self.constants) }
        #expect(try cache.analysis(of: frame, parts: .clarity, constants: Self.constants) === kept)
    }

    /// Two lanes asking for one decode's analysis at once build it once.
    @Test func twoLanesBuildOnce() throws {
        let gpu = try GPU()
        let (cache, _) = Self.cache(gpu)
        /// One decode handed to every lane, as the frame view's and a sheet's renders share one.
        struct Shared: @unchecked Sendable { let frame: LinearFrame }
        let shared = Shared(frame: try Self.frame(gpu))
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            _ = try? cache.analysis(of: shared.frame, parts: [.clarity, .haze], constants: Self.constants)
        }
        #expect(cache.statistics.builds == 2 && cache.statistics.hits == 7)
    }

    /// What a develop's gate counts: each part kept and each build's working set, with Metal's rounding, and nothing for print controls.
    @Test func aDevelopCountsEachPartItNeeds() throws {
        let width = 7008, height = 4672
        func bytes(_ values: [Presence.Control: Float]) throws -> Int {
            PresenceAnalyses.developBytes(try Presence(values), width: width, height: height)
        }
        #expect(try bytes([.saturation: 100, .vibrance: -100]) == 0 && (try bytes([:])) == 0)
        let clarity = 1024 * 683 * 8 * PresenceAnalyses.clarityTexturesWhileMade
        #expect(try bytes([.clarity: -30]) == clarity + clarity / 16)
        let texture = 3504 * 2336 * 8 + PresenceAnalyses.textureWorkingSetBudget
        #expect(try bytes([.texture: 30]) == texture + texture / 16)
        let haze = 1024 * 683 * (8 + PresenceAnalyses.hazeWorkingBytesPerTexel)
        let all = clarity + texture + haze
        #expect(try bytes([.texture: 30, .clarity: 30, .dehaze: 30, .saturation: 10]) == all + all / 16)
        #expect((170_000_000...190_000_000).contains(all + all / 16), "about 181 MB at 33 MP")
    }

    @Test func thePartsFollowTheControls() throws {
        #expect(PresenceAnalysis.Parts.needed(by: .identity) == [])
        #expect(PresenceAnalysis.Parts.needed(by: try Presence([.texture: 1, .dehaze: -1, .vibrance: 3])) == [.texture, .haze])
        for control in Presence.Control.allCases {
            #expect(PresenceAnalysis.Parts.read(by: control).isEmpty == (control.placement == .print), "\(control)")
        }
    }
}
