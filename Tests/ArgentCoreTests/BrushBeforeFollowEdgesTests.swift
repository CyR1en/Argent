import CryptoKit
import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Plain brush strokes before Follow edges, byte for byte (the brief's rule: every earlier mask renders and writes what it did). The
/// digests below were taken by this same test at `8f7bcb5`, before Follow edges was built, and are not to be moved by it.
@Suite struct BrushBeforeFollowEdgesTests {
    private static let picture = try! MaskSpace(width: 7008, height: 4672)

    static func sha(_ bytes: some DataProtocol) -> String { SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined() }
    static func sha(_ bits: [UInt16]) -> String { bits.withUnsafeBytes { sha(Data($0)) } }
    static func sha(_ values: [Float]) -> String { values.withUnsafeBytes { sha(Data($0)) } }

    static func id(_ n: UInt8) -> UUID { UUID(uuid: (n, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, n)) }

    static func strokes() throws -> [BrushStroke] {
        [try Brush.stroke(Brush.path(60, seed: 11, start: MaskPoint(x: 0.35, y: 0.3)), radius: 0.03, feather: 0.6, flow: 0.7),
         try Brush.stroke(Brush.path(40, seed: 12, start: MaskPoint(x: 0.4, y: 0.32)), radius: 0.012, feather: 0.2, flow: 1, erase: true),
         try Brush.stroke([MaskPoint(x: 0.1, y: 0.5), MaskPoint(x: 0.9, y: 0.55)], radius: 0.05, feather: 1, flow: 0.4)]
    }

    /// Brushes alone, with a gradient, subtracted and inverted, over one and two masks.
    static func sets() throws -> [[Mask]] {
        let all = try strokes()
        let brush = MaskComponent(shape: .brush(BrushPaint(frame: Brush.frame, strokes: all)))
        let one = MaskComponent(shape: .brush(BrushPaint(frame: Brush.frame, strokes: [all[0]])))
        let subtract = MaskComponent(operation: .subtract, shape: .brush(BrushPaint(frame: Brush.frame, strokes: [all[1], all[2]])))
        return [[Mask(id: id(1), components: [brush], adjustments: try ManualAdjustments(exposureEV: 1))],
                [Mask(id: id(2), components: [MaskRender.linear(0.5, 0.1, 0.5, 0.6), subtract], adjustments: try ManualAdjustments(contrast: 30, shadows: 25))],
                [Mask(id: id(3), components: [MaskComponent(shape: one.shape, invert: true)], adjustments: try ManualAdjustments(exposureEV: -0.8)),
                 Mask(id: id(4), components: [MaskRender.radial(0.5, 0.35, 0.3, 0.2), subtract], adjustments: try ManualAdjustments(highlights: -40))]]
    }

    @Test func plainStrokesRenderAsBeforeFollowEdges() throws {
        let gpu = try GPU()
        let (pixels, _) = Refine.scene(width: 1200, height: 800)
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        var renders: [String] = [], slices: [String] = [], identities: [String] = [], records: [String] = [], digests: [String] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for masks in try Self.sets() {
            let frame = try MaskRender.frame(gpu, pixels, width: 1200, picture: Self.picture)
            let settings = DevelopSettings(halation: true, sharpen: true, manual: try MaskRender.manual(try ManualAdjustments(shadows: 20), masks: masks, reference: 0.3))
            renders.append(Self.sha(MaskRender.bits(try renderer.render(frame, settings: settings).image.texture)))
            let scene = try Refine.scene(renderer, frame, settings)
            let inputs = try #require(scene.masks)
            slices.append(Self.sha(inputs.coverage.values(slot: 0)))
            identities.append(inputs.coverage.identity)
            let set = try MaskSet(masks: masks)
            records.append(Self.sha(try encoder.encode(set)))
            digests.append(set.digest)
        }
        MaskRender.report("plain strokes: renders \(renders) slices \(slices) identities \(identities) records \(records) digests \(digests)")
        #expect(renders == ["79e7681afb38bc14b1d808c05b0336bb4fa705a43ba4ca3479eaea2b2ec7d6b0",
                           "093bf15c8bcded04d04597e76bf3aca4c82f9847ba5a9ef03a69c27272bdfff8",
                           "7e867e3a8eef5bdb936807ae47fb641a8ff54b533bf67b75d137843a08fb9182"])
        #expect(slices == ["8b78409fb406747177620ce675667b17d8bc494f374da5a3d0b5fd1a28ba98a3",
                           "2cd53cf4ed2db64710266b1d180ebc63b348c504eb57e304e7551814e376cacd",
                           "0b0ff0ebdda3cdcec7858f1227bdb94d418985df9316b25633d1d9001b395e07"])
        #expect(identities == ["9620005daf20456113e66fe9d5556ecaa968e78248137315e3177970b7518035",
                           "c3edccb61454ff520aea6b1c4b1b86dad105c8ae66427f691f6a7de862bdd326",
                           "60144d2fe25183c5246f5d657c93fa715d4b3c3c93c71ceebb89c6256e1bfc60"])
        #expect(records == ["02d76f241bb15646fd287bb19fe0efefb4452da512476dcaca94281fa25d2b5e",
                           "37e58abb70fdd20628ffd76875903909ab10bbde5e07b6953fe2add02932e4a0",
                           "c5a4f8e07407aab9d255e463a686a10c95d8834c5646a0ea62f86d3100214629"])
        #expect(digests == ["c7ac261f501e59a8819f6a608e028c23cca7424086861fd1781a3f12d1815d29",
                           "caae5f9b970ee5b402f0bd6f8e5d57a6936036abcac5981ca65c7c027fc08181",
                           "2cdf83754958767889f8a6e48ef16a6fb7b24c71751561334146b53b8d6dec8c"])
    }

    /// A stroke painted live onto a brush with strokes, its canvas at the release, and the same strokes replayed from nothing.
    @Test func plainCanvasesAsBeforeFollowEdges() throws {
        let gpu = try GPU()
        let all = try Self.strokes()
        let mask = Brush.brushMask([all[0], all[1]], id: Self.id(9))
        let session = try BrushStrokeSession(cache: Brush.cache(gpu), picture: Self.picture, mask: mask, component: 0,
                                             settings: BrushSettings(radius: 0.02, feather: 0.4, flow: 0.55))
        for point in Brush.path(50, seed: 21, start: MaskPoint(x: 0.5, y: 0.25)) { try session.add(point) }
        let stroke = try #require(try session.end())
        let live = Self.sha(Brush.bits(session.live))
        let replayed = try Brush.cache(gpu).canvas(for: BrushCanvasKey(size: session.size, version: MaskSet.currentVersion,
                                                                      strokes: [all[0], all[1], stroke]))
        let replay = Self.sha(Brush.bits(replayed.texture))
        MaskRender.report("plain canvases: live \(live) replay \(replay)")
        #expect(live == replay)
        #expect(live == "4ba2c0bbd7415545ce7eecfd7eb05e394b402fa1d1c034f86be86a7b8d58ae47")
    }
}
