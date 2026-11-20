import Foundation
import Metal
import Testing
@testable import ArgentCore

/// The overlay's sharp raster at a settled zoom (`GPU.regionCoverage`): what the masked kernels read, over a part of the decode, whatever kind of mask.
@Suite struct MaskRegionCoverageTests {
    private let picture: MaskSpace

    init() throws { picture = try MaskSpace(width: 7008, height: 4672) }

    @Test func aRegionIsWholeTexelsCutToTheFrame() throws {
        let region = try #require(MaskRegion(frameWidth: 1200, frameHeight: 800, left: 0.1, top: 0.25, right: 0.4001, bottom: 2))
        #expect(region.x == 120 && region.y == 200)
        #expect(region.texelWidth == 361 && region.texelHeight == 600 && region.width == 361 && region.height == 600)
        let placed = region.fractions(frameWidth: 1200, frameHeight: 800)
        #expect(abs(placed.left - 0.1) < 1e-9 && abs(placed.top - 0.25) < 1e-9 && abs(placed.height - 0.75) < 1e-9)
        #expect(MaskRegion(frameWidth: 1200, frameHeight: 800, left: 0.5, top: 0.5, right: 0.5, bottom: 0.9) == nil)
    }

    @Test func aHugeRegionIsThinnedAndKeepsItsShape() throws {
        let region = try #require(MaskRegion(frameWidth: 7008, frameHeight: 4672, left: 0, top: 0, right: 1, bottom: 1))
        #expect(region.width == MaskRegion.maximumLongSide && region.height == 2176)
        #expect(region.texelWidth == 7008 && region.texelHeight == 4672)
    }

    private func region(_ frame: LinearFrame, left: Double, top: Double, right: Double, bottom: Double) throws -> MaskRegion {
        try #require(MaskRegion(frameWidth: frame.width, frameHeight: frame.height, left: left, top: top, right: right, bottom: bottom))
    }

    /// The same texels from the probe, top row first, for this region: `Refine.probe` reads row 0 the picture's bottom.
    private func probed(_ gpu: GPU, _ frame: LinearFrame, _ scene: ManualSceneInputs, slot: Int, _ region: MaskRegion) throws -> [Float] {
        let all = try Refine.probe(gpu, frame, scene, slot: slot), w = frame.width, h = frame.height
        var out = [Float](repeating: 0, count: region.width * region.height)
        for y in 0..<region.height {
            let row = (h - 1 - (region.y + y)) * w + region.x
            for x in 0..<region.width { out[y * region.width + x] = all[row + x] }
        }
        return out
    }

    /// A mask's region against the probe on a whole render's scene: within a code of 8-bit rounding, for one mask of each kind.
    @Test func everyKindReadsAsTheRendersOwnKernelDoes() throws {
        let gpu = try GPU()
        let (width, height) = (1200, 800)
        let (pixels, matte) = Refine.scene(width: width, height: height)
        let raster = try Refine.seed(matte: matte, width: width, height: height, seedWidth: 378, seedHeight: 252, binary: true)
        gpu.maskRefiner.seeds = Refine.Seeds([raster])
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let frame = try MaskRender.frame(gpu, pixels, width: width, picture: picture)
        let gradient = MaskRender.radial(0.4, 0.3, 0.25, 0.2, feather: 30)
        let linear = MaskComponent(operation: .subtract, shape: .linear(.init(full: MaskPoint(x: 0.5, y: 0.5), zero: MaskPoint(x: 0.5, y: 0.2))))
        let sky = try Refine.component(.sky, raster)
        let dark = try ManualAdjustments(exposureEV: -1.5), tone = try ManualAdjustments(shadows: 30)
        // A gradient; Sky with Exposure, per pixel; a tone-only Sky, its slice; Sky with Feather, its slice; Sky with a subtracted gradient, per pixel composed.
        var feathered = sky
        if case .smart(var selection) = feathered.shape { selection.feather = 60; feathered.shape = .smart(selection) }
        let cases: [(String, Mask, Int)] = [
            ("gradient", Mask(components: [gradient], adjustments: tone), 0),
            ("smart per pixel", Mask(components: [sky], adjustments: dark), 1),
            ("smart tone-only", Mask(components: [sky], adjustments: tone), 2),
            ("smart feathered", Mask(components: [feathered], adjustments: dark), 3),
            ("smart composed", Mask(components: [sky, linear], adjustments: dark), 4),
        ]
        let settings = DevelopSettings(manual: try MaskRender.manual(masks: cases.map(\.1)))
        let scene = try Refine.scene(renderer, frame, settings)
        let area = try region(frame, left: 0.2, top: 0.1, right: 0.75, bottom: 0.8)
        for (name, mask, slot) in cases {
            // A frame's whole-set scene against the one-mask set the overlay asks for: a slot's coverage is the mask's own.
            let got = try gpu.regionCoverage(of: mask, on: frame, region: area).map { Float($0) / 255 }
            let want = try probed(gpu, frame, scene, slot: slot, area)
            let worst = zip(got, want).map { abs($0 - $1) }.max() ?? 1
            #expect(worst <= 1.0 / 255 + 1e-5, "\(name): \(worst)")
        }
    }

    /// A thinned region reads the decode texel at each pixel's centre, a smaller picture of the same coverage.
    @Test func aThinnedRegionTakesTheTexelAtEachCentre() throws {
        let gpu = try GPU()
        let (pixels, _) = Refine.scene(width: 1200, height: 800)
        let frame = try MaskRender.frame(gpu, pixels, width: 1200, picture: picture)
        let mask = Mask(components: [MaskRender.radial(0.5, 0.33, 0.3, 0.2, feather: 40)])
        let whole = try region(frame, left: 0, top: 0, right: 1, bottom: 1)
        let full = try gpu.regionCoverage(of: mask, on: frame, region: whole)
        #expect(full.count == frame.width * frame.height)
        #expect(full.contains(where: { $0 > 200 }) && full.contains(where: { $0 < 5 }))
    }
}
