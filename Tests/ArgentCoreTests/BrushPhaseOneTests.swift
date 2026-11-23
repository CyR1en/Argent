import CryptoKit
import Foundation
import Metal
import Testing
@testable import ArgentCore

/// A frame without a brush renders and bakes without changing Phase 1's gradient path: the bytes of gradient-only coverage arrays
/// (still `bceb32a`'s digest, before the brush could bake) and of masked renders through the toy stock (originally `bceb32a`;
/// re-recorded on `main` at `e5bca7c7` on 2026-11-23, macOS 27.2 build 26B123, after scene gamut compression, `RenderGraph.version`
/// 2026-11-19-1).
@Suite struct BrushPhaseOneIdentityTests {
    static let sets: [[Mask]] = {
        func linear(_ fx: Float, _ fy: Float, _ zx: Float, _ zy: Float, _ operation: MaskOperation = .add, invert: Bool = false) -> MaskComponent {
            MaskComponent(operation: operation, shape: .linear(.init(full: MaskPoint(x: fx, y: fy), zero: MaskPoint(x: zx, y: zy))), invert: invert)
        }
        func radial(_ x: Float, _ y: Float, _ a: Float, _ b: Float, feather: Float, _ operation: MaskOperation = .add, invert: Bool = false) -> MaskComponent {
            MaskComponent(operation: operation, shape: .radial(.init(center: MaskPoint(x: x, y: y), semiAxisA: a, semiAxisB: b, angle: 0.4, feather: feather)),
                          invert: invert)
        }
        let id = { (n: Int) in UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
        return [
            [Mask(id: id(1), components: [linear(0.5, 0.1, 0.5, 0.6)])],
            [Mask(id: id(1), components: [radial(0.5, 0.33, 0.3, 0.2, feather: 50), linear(0.2, 0.6, 0.4, 0.1, .subtract)]),
             Mask(id: id(2), components: [radial(0.2, 0.2, 0.1, 0.3, feather: 0, invert: true)]),
             Mask(id: id(3), components: [linear(0.9, 0.6, 0.1, 0.0), radial(0.7, 0.4, 0.2, 0.25, feather: 25, .intersect)]),
             Mask(id: id(4), components: [radial(0.6, 0.3, 0.4, 0.1, feather: 85)]),
             Mask(id: id(5), components: [linear(0.0, 0.0, 1.0, 0.66, invert: true)])],
        ]
    }()

    /// Every slice's half floats, in order, for each set at two picture shapes.
    static func coverageDigest(_ gpu: GPU) throws -> String {
        var hash = SHA256()
        let cache = MaskFieldCache(device: gpu.device, queue: gpu.queue)
        for picture in [try MaskSpace(width: 7008, height: 4672), try MaskSpace(width: 3000, height: 3000)] {
            for masks in sets {
                let coverage = try #require(try cache.coverage(for: MaskSet(masks: masks), picture: picture))
                let texture = coverage.texture, width = texture.width, height = texture.height
                for slice in 0..<coverage.sliceCount {
                    var bytes = [UInt8](repeating: 0, count: width * height * 8)
                    bytes.withUnsafeMutableBytes {
                        texture.getBytes($0.baseAddress!, bytesPerRow: width * 8, bytesPerImage: 0,
                                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, slice: slice)
                    }
                    hash.update(data: bytes)
                }
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The masked edits' renders through the toy stock, one digest.
    static func renderDigest(_ gpu: GPU) throws -> String {
        let values = [try ManualAdjustments(exposureEV: -1.2, contrast: 30, highlights: -40),
                      try ManualAdjustments(exposureEV: 0.8, shadows: 45, whites: -20, blacks: 15)]
        let edits = try sets.map { masks in
            let withValues = masks.enumerated().map { index, mask in
                Mask(id: mask.id, components: mask.components, amount: index == 2 ? 1.5 : 1, adjustments: values[index % 2])
            }
            return try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 0.3, highlights: -20).settingMasks(try MaskSet(masks: withValues)),
                                            referenceStops: 0.4)
        }
        return try LightCompilerBaselineTests.digest(stock: LightCompilerBaselineTests.toyStock(), gpu: gpu, edits: edits)
    }

    @Test func gradientCoverageIsPhaseOnesBytes() throws {
        let digest = try Self.coverageDigest(try GPU())
        MaskRender.report("phase-one coverage digest \(digest)")
        #expect(digest == "51bdbe22eae5d63fed643dcf1f3a80425f3d521efb9fe03545db6179b339ea18")
    }

    /// Recorded on `main` at `e5bca7c7` on 2026-11-23 (macOS 27.2 build 26B123), after scene gamut compression,
    /// `RenderGraph.version` 2026-11-19-1.
    @Test func gradientRendersArePhaseOnesBytes() throws {
        let digest = try Self.renderDigest(try GPU())
        MaskRender.report("phase-one render digest \(digest)")
        #expect(digest == "c866ef8fc85d6de336166042dcdccdf4e777f65f5e5b9e73400cdd0cafa0c886")
    }
}
