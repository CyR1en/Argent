import Foundation
import Testing
@testable import ArgentCore

/// The removal that needs no model (`RemovalPipeline.healed`, docs/remove-plan.md, section 18): a speck on a smooth sky is
/// filled from the sky round it, and anything else is left to the model.
@Suite struct RemovalHealTests {
    typealias Pipeline = RemovalPipeline

    static let frameWidth = 3000, frameHeight = 2000
    static let made = Date(timeIntervalSince1970: 1_800_000_000)

    /// A value in -1 to 1 that depends on the pixel and the channel and on nothing else.
    static func chance(_ x: Int, _ y: Int, _ k: Int) -> Float {
        var z = UInt64(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663 ^ k &* 83_492_791) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24) * 2 - 1
    }

    /// A blue sky with no grain: a level that bends across the frame, as a sky does toward a lens's corner.
    static func sky(_ x: Int, _ y: Int) -> [Float] {
        let u = Float(x) / Float(frameWidth), v = Float(y) / Float(frameHeight)
        let level = 0.2 * (1 + 0.25 * u + 0.15 * v + 0.1 * u * u - 0.05 * u * v)
        return [0.35 * level, 0.6 * level, level]
    }

    enum Scene { case sky, weave, horizon, shadow, stripes, faintStripes }

    /// The frame's light at a pixel: the sky with grain of 1 % of its level, a speck of dust that darkens it wherever `object`
    /// says, and what the scene adds.
    static func light(_ x: Int, _ y: Int, object: Bool, scene: Scene, objectMiddle: (x: Int, y: Int)) -> [Float] {
        var value = sky(x, y)
        switch scene {
        case .sky: break
        case .weave:
            let weave = 1 + 0.15 * sin(Float(x) / 7) * cos(Float(y) / 11)
            value = value.map { $0 * weave }
        case .horizon:
            // A darker land from 110 pixels under the object's middle: 30 pixels under its edge, inside the ring.
            if y > objectMiddle.y + 110 { value = value.map { $0 * 0.7 } }
        case .shadow:
            // The object's shadow, a tenth darker, to its right and outside its mask.
            let dx = x - objectMiddle.x, dy = y - objectMiddle.y
            if dx > 0 && dx < 140 && abs(dy) < 40 { value = value.map { $0 * 0.9 } }
        case .stripes, .faintStripes:
            // Stripes nine pixels apart, a fifth of the level or a twentieth: a box of nine averages them away and a mean
            // of three hardly sees them, so neither the departure nor the grain says they are there.
            let stripe = 1 + (scene == .stripes ? 0.2 : 0.05) * sin(2 * Float.pi * Float(x) / 9)
            value = value.map { $0 * stripe }
        }
        for k in 0..<3 { value[k] *= 1 + 0.0173 * chance(x, y, k) }
        return object ? value.map { $0 * 0.85 } : value
    }

    /// A disc 160 pixels across at the frame's (1200, 1040), selected on a picture a quarter of the frame's size.
    static func prepared(_ scene: Scene, seed: UInt64 = 7) throws -> Pipeline.Prepared {
        let width = 750, height = 500
        var coverage = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            coverage[y * width + x] = UInt8(min(max(20 - hypot(Float(x) + 0.5 - 300, Float(y) + 0.5 - 260) + 0.5, 0), 1) * 255)
        } }
        let selection = try Pipeline.Selection(width: width, height: height, coverage: coverage)
        let plan = try Pipeline.plan(selection, geometry: nil, frameWidth: frameWidth, frameHeight: frameHeight)
        let box = plan.box
        var rgb = [Float16](repeating: 0, count: box.width * box.height * 3)
        for y in 0..<box.height { for x in 0..<box.width {
            let p = y * box.width + x
            let value = light(box.x + x, box.y + y, object: plan.object[p] != 0, scene: scene, objectMiddle: (1200, 1040))
            for k in 0..<3 { rgb[p * 3 + k] = Float16(value[k]) }
        } }
        let crop = try Pipeline.Crop(box: box, rgb: rgb, decoder: "test-decoder-1")
        return try Pipeline.prepare(crop, plan: plan, seed: seed)
    }

    static func hole(_ prepared: Pipeline.Prepared) -> [UInt8] {
        let job = prepared.job
        return Pipeline.changedArea(object: job.mask, attention: [UInt8](repeating: 0, count: job.width * job.height), width: job.width,
                                    height: job.height, growth: Pipeline.changedGrowth(shortSide: min(job.width, job.height)))
    }

    @Test func aSpeckOnASmoothSkyIsFilledFromTheSkyRoundIt() throws {
        let prepared = try Self.prepared(.sky)
        let job = prepared.job, w = job.width, h = job.height, box = prepared.plan.box
        #expect(w == 512 && h == 512 && box.width == 512, "the crop is worked at its own size")
        let patch = try #require(try Pipeline.healed(prepared, faces: [], made: Self.made))
        let hole = Self.hole(prepared)
        let inside = hole.indices.filter { hole[$0] != 0 }
        #expect(inside.count > 20_000 && inside.count < 40_000)

        // Outside the hole the patch is the crop, to a half float's rounding.
        for p in 0..<(w * h) where hole[p] == 0 {
            for k in 0..<3 { #expect(patch.rgb[p * 3 + k] == Float16(prepared.original[p * 3 + k])) }
        }
        // Inside it the speck is gone: the fill is the sky that was under it, in its level, to a fifth of a percent over the
        // hole and within the grain at every pixel.
        var fillSum = [Double](repeating: 0, count: 3), skySum = fillSum, dustSum = fillSum
        var worst: Float = 0, grainSquares = 0.0
        for p in inside {
            let sky = Self.sky(box.x + p % w, box.y + p / w)
            for k in 0..<3 {
                let fill = Float(patch.rgb[p * 3 + k]), share = fill / sky[k] - 1
                fillSum[k] += Double(fill); skySum[k] += Double(sky[k]); dustSum[k] += Double(prepared.original[p * 3 + k])
                worst = max(worst, abs(share)); grainSquares += Double(share * share)
            }
        }
        for k in 0..<3 {
            #expect(abs(fillSum[k] / skySum[k] - 1) < 0.002, "channel \(k): \(fillSum[k] / skySum[k])")
            #expect(dustSum[k] / skySum[k] < 0.9, "the speck was there")
        }
        #expect(worst < 0.05, "\(worst)")
        // And it has the sky's grain, 1 % of the level, not a smooth disc.
        let grain = Float((grainSquares / Double(inside.count * 3)).squareRoot())
        #expect(grain > 0.008 && grain < 0.013, "\(grain)")

        // The alphas are the model's path's: the object is the mask the model would have had, the effects the hole.
        #expect(patch.objectAlpha.map { $0 >= 128 ? 255 : 0 } == job.mask && patch.effectsAlpha.map { $0 >= 128 ? 255 : 0 } == hole)
        #expect(patch.effectsAlpha.indices.allSatisfy { patch.effectsAlpha[$0] >= patch.objectAlpha[$0] })
        // The notes say no model drew it, and making it again reads back the same mask.
        let notes = patch.notes
        #expect(notes.engine == Pipeline.healEngine && notes.weights == nil && notes.steps == nil && notes.guidance == nil)
        #expect(notes.seed == 7 && notes.decoder == "test-decoder-1" && notes.frameWidth == 3000 && notes.frameHeight == 2000)
        #expect(notes.made == Self.made && notes.face == nil && notes.growth == Pipeline.maskGrowth)
        #expect(try Pipeline.plan(retrying: patch, frameWidth: 3000, frameHeight: 2000).box == box)
        #expect(try RemovalPatch(decoding: patch.encoded()) == patch)
    }

    @Test func theSameSeedLaysTheSameGrainAndAnotherLaysItOtherwise() throws {
        let first = try #require(try Pipeline.healed(try Self.prepared(.sky), faces: [], made: Self.made))
        let same = try #require(try Pipeline.healed(try Self.prepared(.sky), faces: [], made: Self.made))
        let other = try #require(try Pipeline.healed(try Self.prepared(.sky, seed: 8), faces: [], made: Self.made))
        #expect(first == same)
        #expect(first.rgb != other.rgb && first.objectAlpha == other.objectAlpha && first.effectsAlpha == other.effectsAlpha)
    }

    @Test func theSkysRingIsSmoothAndMeasuresAsItWasMade() throws {
        let prepared = try Self.prepared(.sky)
        let job = prepared.job
        let surround = try #require(Pipeline.surround(of: Self.hole(prepared), in: prepared.original, width: job.width, height: job.height))
        #expect(surround.isSmooth)
        #expect(surround.departure < 0.004 && surround.largest < 0.02, "\(surround.departure) \(surround.largest)")
        // All it keeps beyond its fit is its grain, and the fit inside the hole stays within what the ring shows.
        #expect(surround.total < 0.012 && surround.total < 1.3 * surround.grain && surround.beyond == 0, "\(surround.total) \(surround.beyond)")
        // What a 3 by 3 mean leaves of grain of 1 %: a little under it.
        #expect(surround.grain > 0.007 && surround.grain < 0.011, "\(surround.grain)")
        #expect(surround.ring.count { $0 != 0 } > 20_000)
    }

    @Test(arguments: [Scene.weave, .horizon, .shadow, .stripes, .faintStripes])
    func whatIsNotSmoothIsLeftToTheModel(_ scene: Scene) throws {
        let prepared = try Self.prepared(scene)
        let job = prepared.job
        let surround = try #require(Pipeline.surround(of: Self.hole(prepared), in: prepared.original, width: job.width, height: job.height))
        #expect(!surround.isSmooth, "\(scene): departure \(surround.departure), largest \(surround.largest), grain \(surround.grain)")
        #expect(try Pipeline.healed(prepared, faces: []) == nil)
    }

    /// Stripes pass the two measures that are smoothed, and are caught by what the ring keeps in all against its grain.
    @Test func regularStripesAreToldFromGrainByHowMuchOfThemIsFine() throws {
        for (scene, least) in [(Scene.stripes, Float(5)), (.faintStripes, 3)] {
            let prepared = try Self.prepared(scene)
            let job = prepared.job
            let surround = try #require(Pipeline.surround(of: Self.hole(prepared), in: prepared.original, width: job.width, height: job.height))
            #expect(surround.total > least * surround.grain, "\(scene): \(surround.total) against \(surround.grain)")
            #expect(surround.grain <= Pipeline.healGrainLimit, "its fine part alone would have passed")
        }
    }

    /// What lies beyond the ring is not read: a field four times as bright, from the first pixel past the ring, leaves a
    /// flat fill flat. Before, the smoothing taken from each tile reached past the ring and put a dark mark in the fill.
    @Test func nothingBeyondTheRingReachesTheFill() throws {
        let w = 512, h = 512
        var hole = [UInt8](repeating: 0, count: w * h)
        for y in 192..<320 { for x in 192..<320 { hole[y * w + x] = 255 } }
        let flat = [Float](repeating: 0.25, count: w * h * 3)
        let ring = try #require(Pipeline.surround(of: hole, in: flat, width: w, height: h)).ring
        var original = flat
        for p in 0..<(w * h) where ring[p] == 0 && hole[p] == 0 { for k in 0..<3 { original[p * 3 + k] = 1 } }
        #expect(ring.count { $0 != 0 } > 20_000 && original.count { $0 == 1 } > 600_000)

        let surround = try #require(Pipeline.surround(of: hole, in: original, width: w, height: h))
        #expect(surround.isSmooth && surround.total == 0 && surround.ring == ring)
        for seed in [UInt64(7), 8, 9] {
            let fill = try #require(Pipeline.healFill(original, hole: hole, surround: surround, width: w, height: h, seed: seed))
            var worst: Float = 0
            for p in 0..<(w * h) where hole[p] != 0 { for k in 0..<3 { worst = max(worst, abs(fill[p * 3 + k] - 0.25)) } }
            #expect(worst < 1e-4, "seed \(seed): \(worst)")
            #expect(fill.indices.allSatisfy { hole[$0 / 3] != 0 || fill[$0] == original[$0] }, "outside the hole nothing is touched")
        }
    }

    /// A hole against the frame's edge has a ring on one side, and a fit that bends there is not carried across the hole:
    /// a ring falling from 0.25 to 0.225, bending as it goes, would give a fill under nothing at the far edge.
    @Test func aHoleAgainstTheFramesEdgeIsNotFilledFromOneSide() throws {
        let w = 512, h = 512
        var hole = [UInt8](repeating: 0, count: w * h), original = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            if x < 360 { hole[y * w + x] = 255 }
            let along = Float(x - 360) / 96, value = 0.25 - 0.025 * along * along
            for k in 0..<3 { original[(y * w + x) * 3 + k] = value }
        } }
        let surround = try #require(Pipeline.surround(of: hole, in: original, width: w, height: h))
        #expect(surround.departure < 0.001 && surround.total < 0.001, "the ring itself is as smooth as a ring can be")
        #expect(surround.trend[0] < 0, "the fit at the far edge: \(surround.trend[0])")
        #expect(surround.beyond > 1 && !surround.isSmooth, "\(surround.beyond)")

        // The same ring round a hole it surrounds, at the top of a bowl, is within what the ring shows.
        var middle = [UInt8](repeating: 0, count: w * h), bowl = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            let dx = Float(x - 256) / 256, dy = Float(y - 256) / 256
            if abs(x - 256) < 64 && abs(y - 256) < 64 { middle[y * w + x] = 255 }
            for k in 0..<3 { bowl[(y * w + x) * 3 + k] = 0.25 - 0.05 * (dx * dx + dy * dy) }
        } }
        let round = try #require(Pipeline.surround(of: middle, in: bowl, width: w, height: h))
        #expect(round.beyond == 0 && round.isSmooth, "\(round.beyond)")
    }

    @Test func aCancelledTaskStopsIt() async throws {
        let prepared = try Self.prepared(.sky)
        let task = Task { () -> RemovalPatch? in
            withUnsafeCurrentTask { $0?.cancel() }
            return try Pipeline.healed(prepared, faces: [])
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func aHoleThatLeavesNoRingIsLeftToTheModel() {
        // The whole raster, and all of it but a corner.
        let w = 128, h = 128
        let flat = [Float](repeating: 0.2, count: w * h * 3)
        #expect(Pipeline.surround(of: [UInt8](repeating: 255, count: w * h), in: flat, width: w, height: h) == nil)
        var most = [UInt8](repeating: 255, count: w * h)
        for y in 0..<8 { for x in 0..<8 { most[y * w + x] = 0 } }
        #expect(Pipeline.surround(of: most, in: flat, width: w, height: h) == nil)
        #expect(Pipeline.surround(of: [UInt8](repeating: 0, count: w * h), in: flat, width: w, height: h) == nil)
    }
}
