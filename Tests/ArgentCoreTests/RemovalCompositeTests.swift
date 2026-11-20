import Foundation
import Metal
import Testing
@testable import ArgentCore

/// The seam of docs/remove-plan.md, section 4.3, in the render: a resolved correction carries its frame's removals and names those
/// that are on, and the lens stage lays their patches into the decode before its warp. The composite is held to a reference on the
/// CPU written from the plan's words, in double precision, at full size and at a preview's sizes.
@Suite struct RemovalCompositeTests {
    // MARK: what the tests are made of

    private struct Random {
        var state: UInt64
        /// SplitMix64, in 0..<1.
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
    }

    /// The one picture these frames are of, at full size.
    private static let full = (width: 300, height: 200)

    /// A decode of the picture `width` by `height` pixels in size, filled with noise over a slope, so no two texels agree and a
    /// texel laid a row or a column off is found.
    private func decode(_ gpu: GPU, width: Int = RemovalCompositeTests.full.width, height: Int = RemovalCompositeTests.full.height,
                        of full: (width: Int, height: Int) = RemovalCompositeTests.full, seed: UInt64 = 7) throws -> LinearFrame {
        let image = try gpu.texturePool.acquire(width: width, height: height)
        var random = Random(state: seed), pixels = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<3 {
                    pixels[(y * width + x) * 4 + c] = Float16(0.05 + 0.4 * Double(x + 2 * y + 7 * c) / Double(width + 2 * height) + 3 * random.next())
                }
            }
        }
        pixels.withUnsafeBytes {
            image.texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        let whole = width == full.width && height == full.height
        return LinearFrame(image: image, decoderVersion: "removal-test", scale: whole ? 1 : Float(max(width, height)) / Float(max(full.width, full.height)),
                           picture: try MaskSpace(width: full.width, height: full.height))
    }

    /// The same pixels in a texture of their own, with no lens tag: a second decode of the frame.
    private func again(_ frame: LinearFrame, _ gpu: GPU) throws -> LinearFrame {
        let image = try gpu.texturePool.acquire(width: frame.width, height: frame.height)
        pixels(frame).withUnsafeBytes {
            image.texture.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0, withBytes: $0.baseAddress!,
                                  bytesPerRow: frame.width * 8)
        }
        return LinearFrame(image: image, decoderVersion: frame.decoderVersion, scale: frame.scale, picture: frame.picture)
    }

    private func pixels(_ frame: LinearFrame) -> [Float16] { ExposureAnalyzer.pixels(of: frame.texture) }

    /// A patch `width` by `height` over a box: noise for its light, the object's alpha a disc with a soft rim, its effects' alpha a
    /// wider one, so each has texels at 0, at 255 and between.
    private func patch(x: Int = 41, y: Int = 23, boxWidth: Int = 150, boxHeight: Int = 113, width: Int = 64, height: Int = 48,
                       seed: UInt64 = 3) throws -> RemovalPatch {
        var random = Random(state: seed), rgb = [Float16](repeating: 0, count: width * height * 3)
        for i in rgb.indices { rgb[i] = Float16(0.02 + 2 * random.next()) }
        func disc(_ inner: Double, _ outer: Double) -> [UInt8] {
            (0..<(width * height)).map { i in
                let dx = (Double(i % width) + 0.5) / Double(width) - 0.5, dy = (Double(i / width) + 0.5) / Double(height) - 0.45
                return UInt8((255 * min(1, max(0, (outer - hypot(dx, dy)) / (outer - inner)))).rounded())
            }
        }
        return try RemovalPatch(box: RemovalPatch.Box(x: x, y: y, width: boxWidth, height: boxHeight), width: width, height: height,
                                rgb: rgb, objectAlpha: disc(0.12, 0.22), effectsAlpha: disc(0.2, 0.38))
    }

    private func removing(_ removals: [Removal], _ base: ResolvedLensCorrection = .identity) -> ResolvedLensCorrection { base.removing(removals) }

    private func warp(_ knots: [Double] = [1, 1.04], gain: [Double] = [1, 1]) throws -> ResolvedLensCorrection {
        try ResolvedLensCorrection(red: RadialTable(knots: knots), green: RadialTable(knots: knots), blue: RadialTable(knots: knots),
                                   gain: RadialTable(knots: gain), status: .init(distortion: .file), width: Self.full.width, height: Self.full.height)
    }

    // MARK: the reference

    /// A patch's planes at one level of its chain, top row first.
    private struct Planes {
        var width: Int, height: Int
        var rgb: [Float16], object: [UInt8], effects: [UInt8]
    }

    /// The level below: half the sides, rounded down, each texel the mean of the area of the level above it covers, a half float's
    /// nearest for light and the nearest code for an alpha. The area is counted in whole numbers, a texel above cut each way into
    /// as many parts as the level below has texels, so a mean that lies exactly between two half floats rounds as a tie does,
    /// to the even one, and not to whichever side a sum of fractions falls.
    private func halved(_ level: Planes) -> Planes {
        let width = max(1, level.width / 2), height = max(1, level.height / 2)
        var out = Planes(width: width, height: height, rgb: [], object: [], effects: [])
        for j in 0..<height {
            for i in 0..<width {
                var sums = [Double](repeating: 0, count: 5), area = 0
                // The texels above that the output texel reaches: those from where its span starts to where it ends.
                for sy in (j * level.height / height)...(((j + 1) * level.height - 1) / height) {
                    let tall = min((sy + 1) * height, (j + 1) * level.height) - max(sy * height, j * level.height)
                    for sx in (i * level.width / width)...(((i + 1) * level.width - 1) / width) {
                        let broad = min((sx + 1) * width, (i + 1) * level.width) - max(sx * width, i * level.width)
                        let at = sy * level.width + sx
                        for c in 0..<3 { sums[c] += Double(level.rgb[at * 3 + c]) * Double(tall * broad) }
                        sums[3] += Double(level.object[at]) * Double(tall * broad)
                        sums[4] += Double(level.effects[at]) * Double(tall * broad)
                        area += tall * broad
                    }
                }
                out.rgb += (0..<3).map { Float16(sums[$0] / Double(area)) }
                out.object.append(UInt8((sums[3] / Double(area)).rounded()))
                out.effects.append(UInt8((sums[4] / Double(area)).rounded()))
            }
        }
        return out
    }

    private func weights(_ t: Double) -> [Double] {
        let t2 = t * t, t3 = t2 * t
        return [-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1, -1.5 * t3 + 2 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2]
    }

    /// One patch as a frame of one size reads it: the level of its chain nearest one texel to a texel of the frame, the alpha its
    /// removal picks, and its box counted from the picture's bottom, as a texture's rows count.
    private struct Laid {
        var level: Planes, index: Int, alpha: [UInt8]
        var width: Int, height: Int, full: (width: Int, height: Int)
        var left: Int, bottom: Int, boxWidth: Int, boxHeight: Int
    }

    private func laid(_ patch: RemovalPatch, includesEffects: Bool, width: Int, height: Int, of full: (width: Int, height: Int)) -> Laid {
        let box = patch.box
        let density = max(Double(patch.width) * Double(full.width) / Double(width) / Double(box.width),
                          Double(patch.height) * Double(full.height) / Double(height) / Double(box.height))
        var level = Planes(width: patch.width, height: patch.height, rgb: patch.rgb, object: patch.objectAlpha, effects: patch.effectsAlpha)
        var index = 0
        if density > 1 {
            let wanted = Int(log2(density).rounded())
            while index < wanted, level.width > 1 || level.height > 1 { level = halved(level); index += 1 }
        }
        return Laid(level: level, index: index, alpha: includesEffects ? level.effects : level.object, width: width, height: height, full: full,
                    left: box.x, bottom: full.height - box.y - box.height, boxWidth: box.width, boxHeight: box.height)
    }

    /// Where texel `q` of a frame's side reads a side of a patch's level, or `nil` where its centre is outside the box: the level
    /// texel at or before it and the fraction past that. The texel's centre is `(q + 1/2) * full / frame` full-size pixels along;
    /// the box takes it from `start` up to `start + length`; and it reads the level at that distance into the box, in level
    /// texels, less the half texel a texel's centre lies at. In whole numbers, over the common denominator `2 * frame * length`,
    /// so a centre on a box's edge or on a level texel's centre is placed as arithmetic places it.
    private func tap(_ q: Int, frame: Int, full: Int, start: Int, length: Int, level: Int) -> (base: Int, t: Double)? {
        let centre = (2 * q + 1) * full
        guard centre >= 2 * frame * start, centre < 2 * frame * (start + length) else { return nil }
        let numerator = (centre - 2 * frame * start) * level - frame * length, denominator = 2 * frame * length
        var base = numerator / denominator
        if numerator < 0, base * denominator != numerator { base -= 1 }
        return (base, Double(numerator - base * denominator) / Double(denominator))
    }

    /// What the patch makes of the texel at `x`, `y` (the picture's bottom row first, as a texture's) holding `under`: red, green
    /// and blue as the stage should write them before a half float rounds them, or `nil` where the patch leaves the texel alone.
    /// A texel takes a patch where its centre, carried to the full-size picture by its fraction of the frame, lies in the patch's
    /// box; it reads the patch's level by Catmull-Rom with the warp's limiter; and the alpha mixes the two.
    private func mixed(_ under: [Double], x: Int, y: Int, _ laid: Laid) -> [Double]? {
        let level = laid.level, limit = Double((LensStage.limiterRatio - 1) / (LensStage.limiterRatio + 1))
        guard let u = tap(x, frame: laid.width, full: laid.full.width, start: laid.left, length: laid.boxWidth, level: level.width),
              let v = tap(y, frame: laid.height, full: laid.full.height, start: laid.bottom, length: laid.boxHeight, level: level.height)
        else { return nil }
        let wx = weights(u.t), wy = weights(v.t)
        var sum = [Double](repeating: 0, count: 4)
        var lowest = [Double](repeating: .infinity, count: 4), highest = [Double](repeating: -.infinity, count: 4)
        var nearLowest = lowest, nearHighest = highest
        for j in 0..<4 {
            for i in 0..<4 {
                let sx = min(max(u.base - 1 + i, 0), level.width - 1)
                // The level's rows count from the top, and `v` from the patch's bottom.
                let sy = level.height - 1 - min(max(v.base - 1 + j, 0), level.height - 1)
                let at = sy * level.width + sx
                let tap = (0..<3).map { Double(level.rgb[at * 3 + $0]) } + [Double(laid.alpha[at]) / 255]
                for c in 0..<4 {
                    sum[c] += wy[j] * wx[i] * tap[c]
                    lowest[c] = min(lowest[c], tap[c]); highest[c] = max(highest[c], tap[c])
                    if (1...2).contains(i) && (1...2).contains(j) {
                        nearLowest[c] = min(nearLowest[c], tap[c]); nearHighest[c] = max(nearHighest[c], tap[c])
                    }
                }
            }
        }
        for c in 0..<4 where highest[c] - lowest[c] > limit * (abs(highest[c]) + abs(lowest[c])) {
            sum[c] = min(max(sum[c], nearLowest[c]), nearHighest[c])
        }
        let a = min(max(sum[3], lowest[3]), highest[3])
        guard a > 0 else { return nil }
        return (0..<3).map { under[$0] * (1 - a) + sum[$0] * a }
    }

    /// What laying `shown` into `decode` comes to (RGBA, the picture's bottom row first): each value as the stage should write it
    /// before a half float rounds it, whether a patch moved the texel at all, and the level each patch was read from. A patch laid
    /// after another reads what the first wrote, rounded as the texture holds it.
    private func reference(_ decode: [Float16], width: Int, height: Int, of full: (width: Int, height: Int) = RemovalCompositeTests.full,
                           laying shown: [(patch: RemovalPatch, includesEffects: Bool)]) -> (values: [Double], moved: [Bool], levels: [Int]) {
        var values = decode.map(Double.init), moved = [Bool](repeating: false, count: width * height), levels: [Int] = []
        for (patch, includesEffects) in shown {
            values = values.map { Double(Float16($0)) }
            let laid = laid(patch, includesEffects: includesEffects, width: width, height: height, of: full)
            levels.append(laid.index)
            for y in 0..<height {
                for x in 0..<width {
                    let at = (y * width + x) * 4
                    guard let made = mixed(Array(values[at..<at + 3]), x: x, y: y, laid) else { continue }
                    values.replaceSubrange(at..<at + 3, with: made)
                    moved[y * width + x] = true
                }
            }
        }
        return (values, moved, levels)
    }

    /// A half float's rounding, in its steps: the nearest half float is half a step from the value it rounds, and the kernel's
    /// single precision moves the value it rounds by under a hundredth of one.
    private static let rounding = 0.51

    /// How far `actual` is from `expected` at its worst, in steps of a half float at the expected value, and how many texels a
    /// patch moved. A texel no patch moved must hold the decode's own bits.
    private func compare(_ actual: [Float16], _ expected: (values: [Double], moved: [Bool], levels: [Int]), decode: [Float16],
                         _ what: String) -> (steps: Double, moved: Int) {
        var worst = 0.0, kept = true
        for i in actual.indices {
            if !expected.moved[i / 4] { kept = kept && actual[i].bitPattern == decode[i].bitPattern; continue }
            let rounded = Float16(expected.values[i])
            worst = max(worst, abs(Double(actual[i]) - expected.values[i]) / Double(rounded.nextUp - rounded))
        }
        #expect(kept, "\(what): a texel outside every patch's coverage keeps the decode's bits")
        #expect(worst <= Self.rounding, "\(what): \(worst) half-float steps from the reference")
        return (worst, expected.moved.filter { $0 }.count)
    }

    // MARK: the correction

    @Test func aCorrectionCarriesItsRemovalsAndNamesThoseThatAreOn() throws {
        let a = Removal(patch: try patch().ref), b = Removal(patch: try patch(seed: 4).ref)
        for base in [ResolvedLensCorrection.identity, try warp(), try warp().defringing(DefringeParameters(try LensSettings.Defringe(purpleAmount: 10)))] {
            #expect(base.removals.isEmpty && !base.digest.contains("+remove-"))
            #expect(base.removing([]) == base)
            let on = base.removing([a, b])
            #expect(on.removals == [a, b])
            #expect(on.digest == base.digest + "+remove-" + (try #require([a, b].renderDigest)))
            #expect(on.isIdentity == base.isIdentity && on.geometry == base.geometry && on.defringe == base.defringe)
            // A removal that is off is as if absent, and the list is still carried.
            let off = base.removing([a.setting(isOn: false), b.setting(isOn: false)])
            #expect(off.digest == base.digest && off.removals.count == 2)
            #expect(base.removing([a.setting(isOn: false), b]).digest == base.removing([b]).digest)
            // Their order and each one's alpha are what is composited.
            #expect(base.removing([b, a]).digest != on.digest)
            #expect(base.removing([a.setting(includesEffects: false), b]).digest != on.digest)
            // The other values are set with the removals kept, in either order.
            let fringe = DefringeParameters(try LensSettings.Defringe(greenAmount: 5))
            #expect(on.defringing(fringe) == base.defringing(fringe).removing([a, b]))
            #expect(on.defringing(base.defringe) == on)
            #expect(try on.reframed(scale: on.scale) == on)
            // The render graph's version is built from the digest, and follows it.
            let settings = DevelopSettings()
            #expect(RenderGraph.version(for: settings, lens: on) == RenderGraph.version(for: settings, lens: base) + "+remove-" + [a, b].renderDigest!)
            #expect(RenderGraph.version(for: settings, lens: off) == RenderGraph.version(for: settings, lens: base))
            #expect(RenderGraph.namesLens(RenderGraph.version(for: settings, lens: on)))
        }
    }

    @Test func theResolverPassesTheSettingsRemovalsThrough() throws {
        let removals = [Removal(patch: try patch().ref), Removal(patch: try patch(seed: 4).ref, isOn: false, includesEffects: false)]
        let picture = try MaskSpace(width: 7008, height: 4672)
        let curve = SonyLensCorrection(distortionSetting: 17, distortion: LensCorrectionTests.sampleCurve)
        let files = [LensFile(correction: curve, picture: picture, metadata: nil), LensFile(correction: nil, picture: picture, metadata: nil),
                     LensFile(correction: nil, picture: nil, metadata: nil)]
        for file in files {
            for arguments in ["default", "distortion=off", "distortion-amount=40", "distortion-amount=200", "vignette=30", "defringe-purple=10"] {
                let values = try LensSettings(arguments: arguments)
                let plain = LensResolver.resolve(file, settings: values)
                let removed = LensResolver.resolve(file, settings: try values.settingRemovals(removals))
                #expect(plain.removals.isEmpty)
                #expect(removed.removals == removals)
                #expect(removed.digest == plain.digest + "+remove-" + removals.renderDigest!)
                #expect(removed == plain.removing(removals))
                let hidden = LensResolver.resolve(file, settings: try values.settingRemovals(removals.map { $0.setting(isOn: false) }))
                #expect(hidden.digest == plain.digest)
            }
        }
    }

    // MARK: no removal

    @Test func withNoRemovalOnTheStageIsAsItWas() throws {
        let gpu = try GPU(), shown = try patch(), absent = try patch(seed: 9)
        let stage = try LensStage(gpu: gpu, patches: FixedPatchSource([shown])), before = try LensStage(gpu: gpu)
        let input = try decode(gpu), original = pixels(input)
        let fringe = DefringeParameters(try LensSettings.Defringe(purpleAmount: 10))
        let none: [[Removal]] = [[], [Removal(patch: shown.ref, isOn: false)],
                                 // On, and its patch is nowhere to be found: skipped, so nothing is laid.
                                 [Removal(patch: absent.ref)], [Removal(patch: shown.ref, isOn: false), Removal(patch: absent.ref)]]
        for removals in none {
            // The identity path hands the decode's own lease back and takes nothing from the pool.
            let allocations = gpu.texturePool.allocationCount
            let same = try stage.correct(input, with: removing(removals))
            #expect(same.image === input.image && gpu.texturePool.allocationCount == allocations)
            #expect(same.lens?.removals == removals)
            for base in [try warp(), try warp(gain: [1, 1.5]), ResolvedLensCorrection.identity.defringing(fringe), try warp().defringing(fringe)] {
                let expected = pixels(try before.correct(input, with: base))
                #expect(pixels(try stage.correct(input, with: removing(removals, base))) == expected)
                let (scene, spare) = try stage.correct(try again(input, gpu), with: removing(removals, base), reusingDecode: true)
                #expect(pixels(scene) == expected && spare != nil)
            }
            if removals.allSatisfy({ !$0.isOn }) { #expect(removing(removals, try warp()).digest == (try warp()).digest) }
        }
        #expect(pixels(input) == original)
        // Nothing of the composite was made: no kernel, no texture, no pass.
        #expect(stage.removalStatistics == (0, 0) && stage.keptPatchBytes == 0)
        // And as many textures were taken from the pool as a stage with no patches takes for the same work.
        var counts: [Int] = []
        for patches in [FixedPatchSource([shown]), nil] {
            let gpu = try GPU(maxIdlePoolBytes: 0), stage = try LensStage(gpu: gpu, patches: patches), input = try decode(gpu)
            let start = gpu.texturePool.allocationCount
            for removals in (patches == nil ? [[], [], [], []] : none) {
                _ = try stage.correct(input, with: removing(removals))
                _ = try stage.correct(input, with: removing(removals, try warp().defringing(fringe)))
            }
            counts.append(gpu.texturePool.allocationCount - start)
        }
        #expect(counts[0] == counts[1])
    }

    // MARK: one removal

    /// The frame's sizes the composite is held to: the develop's, the frame view's and the sheet's kinds, down to a thumbnail, with
    /// sides that divide the picture's and sides that do not.
    private static let sizes = [(300, 200), (150, 100), (97, 65), (75, 50), (48, 32), (30, 20), (19, 13)]

    @Test func oneRemovalIsTheReferenceToAHalfFloatsRoundingAtFullSizeAndAtAPreviews() throws {
        let gpu = try GPU(), made = try patch(), stage = try LensStage(gpu: gpu, patches: FixedPatchSource([made]))
        var worst = 0.0, levels = Set<Int>()
        for (width, height) in Self.sizes {
            let input = try decode(gpu, width: width, height: height), original = pixels(input)
            for includesEffects in [true, false] {
                let removal = Removal(patch: made.ref, includesEffects: includesEffects)
                let result = try stage.correct(input, with: removing([removal]))
                #expect(result.image !== input.image && result.lens?.removals == [removal])
                let expected = reference(original, width: width, height: height, laying: [(made, includesEffects)])
                let found = compare(pixels(result), expected, decode: original, "\(width)x\(height) effects \(includesEffects)")
                #expect(found.moved > 0, "the patch reaches \(width)x\(height)")
                worst = max(worst, found.steps)
                levels.formUnion(expected.levels)
            }
            // The two alphas are two pictures: the object alone is the smaller.
            let alone = pixels(try stage.correct(input, with: removing([Removal(patch: made.ref, includesEffects: false)])))
            #expect(alone != pixels(try stage.correct(input, with: removing([Removal(patch: made.ref)]))))
            #expect(pixels(input) == original, "a preview's decode is left as it was")
        }
        // The patch's own pixels at the develop's size, and its chain's levels below it on the previews.
        #expect(levels == [0, 1, 2, 3])
        print("RemovalCompositeTests: one removal, worst \(worst) half-float steps over \(Self.sizes.count) sizes and both alphas")
    }

    @Test func aPatchOfAnySidesAndABoxAtTheFramesEdgeAreTheReference() throws {
        let gpu = try GPU()
        // Odd sides, so the chain's levels do not halve evenly; a box in the picture's corner; one that leaves the picture; and a
        // patch larger than its box, as a full-size fill of a small object would be.
        let patches = [try patch(x: 60, y: 40, boxWidth: 131, boxHeight: 97, width: 51, height: 37, seed: 11),
                       try patch(x: 0, y: 0, boxWidth: 90, boxHeight: 70, width: 48, height: 32, seed: 12),
                       try patch(x: 222, y: 141, boxWidth: 120, boxHeight: 96, width: 40, height: 32, seed: 13),
                       try patch(x: 100, y: 80, boxWidth: 40, boxHeight: 30, width: 96, height: 72, seed: 14)]
        var worst = 0.0
        for made in patches {
            let stage = try LensStage(gpu: gpu, patches: FixedPatchSource([made]))
            for (width, height) in Self.sizes {
                let input = try decode(gpu, width: width, height: height), original = pixels(input)
                let result = pixels(try stage.correct(input, with: removing([Removal(patch: made.ref)])))
                let expected = reference(original, width: width, height: height, laying: [(made, true)])
                worst = max(worst, compare(result, expected, decode: original, "\(made.width)x\(made.height) at \(width)x\(height)").steps)
            }
        }
        print("RemovalCompositeTests: other patches and boxes, worst \(worst) half-float steps")
    }

    @Test func fullCoverageIsThePatchAloneAndNoneIsTheDecodeAlone() throws {
        // A flat patch over light sixteen stops above it: what the weights' sum rounds to must not let any of the decode through.
        let gpu = try GPU(), width = 32, height = 32
        let rgb = [Float16](repeating: 0.0625, count: width * height * 3)
        let inside = (0..<(width * height)).map { UInt8($0 % width < width / 2 ? 255 : 0) }
        let made = try RemovalPatch(box: RemovalPatch.Box(x: 20, y: 20, width: 128, height: 128), width: width, height: height, rgb: rgb,
                                    objectAlpha: inside, effectsAlpha: inside)
        let stage = try LensStage(gpu: gpu, patches: FixedPatchSource([made]))
        let input = try decode(gpu)
        var bright = pixels(input)
        for i in bright.indices where i % 4 != 3 { bright[i] = 4096 }
        bright.withUnsafeBytes {
            input.texture.replace(region: MTLRegionMake2D(0, 0, input.width, input.height), mipmapLevel: 0, withBytes: $0.baseAddress!,
                                  bytesPerRow: input.width * 8)
        }
        let result = pixels(try stage.correct(input, with: removing([Removal(patch: made.ref)])))
        var covered = 0, clear = 0, wrong = 0
        for y in 0..<input.height {
            for x in 0..<input.width {
                // From the picture's top, the box's rows 20 to 147. Its left half is covered and its right half is not, but for the
                // texels whose taps reach across the edge between them.
                let top = input.height - 1 - y, value = result[(y * input.width + x) * 4]
                if (20..<148).contains(top), (20..<76).contains(x) {
                    covered += 1
                    if value != 0.0625 { wrong += 1 }
                } else if !(20..<148).contains(top) || !(20..<92).contains(x) {
                    clear += 1
                    if value != 4096 { wrong += 1 }
                }
            }
        }
        #expect(wrong == 0 && covered == 56 * 128 && clear == 300 * 200 - 72 * 128)
    }

    // MARK: several

    @Test func twoOverlappingRemovalsAreLaidInTheirOrder() throws {
        let gpu = try GPU()
        let first = try patch(), second = try patch(x: 120, y: 60, boxWidth: 120, boxHeight: 90, width: 48, height: 32, seed: 5)
        let stage = try LensStage(gpu: gpu, patches: FixedPatchSource([first, second]))
        var worst = 0.0, throughout = 0.0
        for (width, height) in [(300, 200), (97, 65), (48, 32)] {
            let input = try decode(gpu, width: width, height: height), original = pixels(input)
            let a = Removal(patch: first.ref), b = Removal(patch: second.ref, includesEffects: false)
            let forward = pixels(try stage.correct(input, with: removing([a, b])))
            let backward = pixels(try stage.correct(input, with: removing([b, a])))
            // Each is laid over what the one before it wrote: the second over the stage's own picture of the first alone, and the
            // first over the second alone, each to one rounding.
            let onlyFirst = pixels(try stage.correct(input, with: removing([a]))), onlySecond = pixels(try stage.correct(input, with: removing([b])))
            worst = max(worst, compare(forward, reference(onlyFirst, width: width, height: height, laying: [(second, false)]),
                                       decode: onlyFirst, "the second over the first at \(width)x\(height)").steps)
            worst = max(worst, compare(backward, reference(onlySecond, width: width, height: height, laying: [(first, true)]),
                                       decode: onlySecond, "the first over the second at \(width)x\(height)").steps)
            // And from the decode, the reference alone lays both: two roundings, the texture's after the first and the last.
            for (laid, order, what) in [(forward, [(first, true), (second, false)], "first then second"), (backward, [(second, false), (first, true)], "second then first")] {
                let expected = reference(original, width: width, height: height, laying: order)
                for i in laid.indices where expected.moved[i / 4] {
                    let rounded = Float16(expected.values[i])
                    throughout = max(throughout, abs(Double(laid[i]) - expected.values[i]) / Double(rounded.nextUp - rounded))
                }
                #expect(zip(laid, original).enumerated().allSatisfy { expected.moved[$0.offset / 4] || $0.element.0 == $0.element.1 }, "\(what) at \(width)x\(height)")
            }
            #expect(forward != backward, "where they overlap the later one lies on top")
        }
        #expect(throughout <= 2)
        print("RemovalCompositeTests: two overlapping removals, worst \(worst) half-float steps a patch, \(throughout) over both")
    }

    @Test func aPatchOfTheModelsSizeIsTheReferenceOverABoxOfARealFramesSize() throws {
        // The numbers of a real removal: the model's largest raster, 512 by 1328, over a box 1590 by 4100 pixels of a 33 MP frame.
        // At the develop's size the frame here is the box with a margin, since only the box's texels are laid; at the frame view's
        // and the sheet's it is the whole picture. The reference is taken at texels spread over the box, its corners among them.
        let gpu = try GPU(), width = 512, height = 1328
        var random = Random(state: 31), rgb = [Float16](repeating: 0, count: width * height * 3)
        for i in rgb.indices { rgb[i] = Float16(0.02 + 2 * random.next()) }
        let alphas = (0..<2).map { which in
            (0..<(width * height)).map { i -> UInt8 in
                let dx = (Double(i % width) + 0.5) / Double(width) - 0.5, dy = (Double(i / width) + 0.5) / Double(height) - 0.5
                return UInt8((255 * min(1, max(0, (which == 0 ? 0.3 : 0.6) - hypot(dx, dy)) * 6)).rounded())
            }
        }
        var worst = 0.0, levels: [Int] = []
        let cases: [(frame: (Int, Int), full: (Int, Int), box: (Int, Int))] = [((1600, 4200), (1600, 4200), (5, 50)), ((2190, 1460), (7008, 4672), (2000, 300)),
                                                                             ((960, 640), (7008, 4672), (2000, 300))]
        for (frame, full, box) in cases {
            let made = try RemovalPatch(box: RemovalPatch.Box(x: box.0, y: box.1, width: 1590, height: 4100), width: width, height: height,
                                        rgb: rgb, objectAlpha: alphas[0], effectsAlpha: alphas[1])
            let stage = try LensStage(gpu: gpu, patches: FixedPatchSource([made]))
            let input = try decode(gpu, width: frame.0, height: frame.1, of: full), original = pixels(input)
            let result = pixels(try stage.correct(input, with: removing([Removal(patch: made.ref)])))
            let laid = laid(made, includesEffects: true, width: frame.0, height: frame.1, of: full)
            levels.append(laid.index)
            var moved = 0
            for y in Array(stride(from: 0, to: frame.1, by: 29)) + [frame.1 - 1] {
                for x in Array(stride(from: 0, to: frame.0, by: 31)) + [frame.0 - 1] {
                    let at = (y * frame.0 + x) * 4
                    guard let expected = mixed((0..<3).map { Double(original[at + $0]) }, x: x, y: y, laid) else {
                        #expect(result[at..<at + 4] == original[at..<at + 4])
                        continue
                    }
                    moved += 1
                    for c in 0..<3 {
                        let rounded = Float16(expected[c])
                        worst = max(worst, abs(Double(result[at + c]) - expected[c]) / Double(rounded.nextUp - rounded))
                    }
                }
            }
            #expect(moved > 50, "\(frame): \(moved) of the texels looked at were laid")
        }
        #expect(worst <= Self.rounding, "\(worst) half-float steps from the reference")
        #expect(levels == [0, 0, 1])
        print("RemovalCompositeTests: the model's size, worst \(worst) half-float steps")
    }

    @Test func aRemovalThatIsOffAndOneWhosePatchIsMissingAreSkipped() throws {
        let gpu = try GPU()
        let first = try patch(), second = try patch(x: 120, y: 60, boxWidth: 120, boxHeight: 90, width: 48, height: 32, seed: 5)
        let lost = try patch(x: 10, y: 100, boxWidth: 80, boxHeight: 60, seed: 6)
        let stage = try LensStage(gpu: gpu, patches: FixedPatchSource([first, second]))
        let input = try decode(gpu), original = pixels(input)
        let only = pixels(try stage.correct(input, with: removing([Removal(patch: second.ref)])))
        _ = compare(only, reference(original, width: input.width, height: input.height, laying: [(second, true)]), decode: original, "the second alone")
        let before = stage.removalStatistics
        // The first is off and another's patch is in no store: what is left is the second alone, bit for bit.
        let lists = [[Removal(patch: first.ref, isOn: false), Removal(patch: second.ref)],
                     [Removal(patch: lost.ref), Removal(patch: second.ref)],
                     [Removal(patch: first.ref, isOn: false), Removal(patch: second.ref), Removal(patch: lost.ref)]]
        for removals in lists {
            #expect(pixels(try stage.correct(input, with: removing(removals))) == only)
        }
        #expect(stage.removalStatistics.composites == before.composites + lists.count)
        // A patch of the right name and another size is not the one the removal names.
        let wrong = Removal(patch: try PatchRef(id: second.identity, width: second.width + 16, height: second.height))
        #expect(try stage.correct(input, with: removing([wrong])).image === input.image)
        // A stage that was given no patches lays none.
        #expect(try LensStage(gpu: gpu).correct(input, with: removing([Removal(patch: second.ref)])).image === input.image)
    }

    // MARK: the lens values

    @Test func theLensValuesActOnAPatchAsOnTheRestOfTheDecode() throws {
        let gpu = try GPU(), made = try patch()
        let stage = try LensStage(gpu: gpu, patches: FixedPatchSource([made])), plain = try LensStage(gpu: gpu)
        let input = try decode(gpu), original = pixels(input)
        let removals = [Removal(patch: made.ref)]
        // What the patch contributes to the decode: the decode with it laid in, and nothing else done.
        let laid = try stage.correct(input, with: removing(removals))
        let untouched = pixels(laid)
        #expect(untouched != original)
        let file = SonyLensCorrection(distortionSetting: 17, distortion: LensCorrectionTests.peaked)
        let picture = try MaskSpace(width: Self.full.width, height: Self.full.height)
        var pictures = Set<[UInt16]>()
        for arguments in ["default", "distortion-amount=0", "distortion-amount=50", "distortion-amount=160", "distortion=off",
                          "vignette=60", "vignette=-40,vignette-midpoint=20", "defringe-purple=12", "defringe-green=9,defringe-green-hue=20:80",
                          "distortion-amount=130,vignette=25,defringe-purple=6"] {
            let values = try LensSettings(arguments: arguments)
            let without = LensResolver.resolve(file, picture: picture, settings: values)
            let with = LensResolver.resolve(file, picture: picture, settings: try values.settingRemovals(removals))
            #expect(with.digest == without.digest + "+remove-" + removals.renderDigest!)
            // The stage's picture of the frame is its picture, with the same lens values and no removal, of the decode the patch
            // was laid into: the patch went in before the warp, so no lens value reaches what it put there.
            let composited = LinearFrame(image: laid.image, decoderVersion: laid.decoderVersion, scale: laid.scale, picture: laid.picture)
            let expected = pixels(try plain.correct(composited, with: without))
            let scene = try stage.correct(input, with: with)
            #expect(pixels(scene) == expected, "\(arguments)")
            #expect(scene.lens == with)
            // A develop, which writes into its decode, makes the same picture.
            let (developed, _) = try stage.correct(try again(input, gpu), with: with, reusingDecode: true)
            #expect(pixels(developed) == expected, "\(arguments), in place")
            pictures.insert(expected.map(\.bitPattern))
        }
        #expect(pictures.count == 9, "each lens value but Distortion off and its amount at 0 makes a picture of its own")
        #expect(pixels(laid) == untouched && pixels(input) == original)
        // The patch was uploaded once for all of it.
        #expect(stage.removalStatistics.uploads == 1)
    }

    // MARK: where the pixels go

    @Test func aPreviewKeepsItsDecodeAndADevelopWritesIntoIt() throws {
        let made = try patch(), removals = [Removal(patch: made.ref)]
        let fringe = try #require(DefringeParameters(try LensSettings.Defringe(purpleAmount: 10)))
        for warped in [false, true] { for repaired in [false, true] {
            let what = "warp \(warped), defringe \(repaired)"
            let gpu = try GPU(maxIdlePoolBytes: 0), stage = try LensStage(gpu: gpu, patches: FixedPatchSource([made]))
            let base = try (warped ? warp() : .identity).defringing(repaired ? fringe : nil)
            let input = try decode(gpu), original = pixels(input)
            // A preview: the decode is kept, for Auto and for the next lens move.
            let scene = try stage.correct(input, with: removing(removals, base))
            let expected = pixels(scene)
            #expect(scene.image !== input.image && pixels(input) == original, "\(what)")
            #expect(expected != pixels(try stage.correct(input, with: base)), "\(what): the removal shows")
            // A develop: the same picture, from as many textures as a frame with no removal takes, and no patch kept after it.
            var counts: [Int] = []
            for removed in [true, false] {
                let developer = try LensStage(gpu: gpu, patches: FixedPatchSource([made]))
                var decoded: LinearFrame! = try again(input, gpu)
                weak let lease = decoded.image
                let start = gpu.texturePool.allocationCount
                let (developed, spare) = try developer.correct(decoded, with: removed ? removing(removals, base) : base, reusingDecode: true)
                counts.append(gpu.texturePool.allocationCount - start)
                if removed {
                    #expect(pixels(developed) == expected, "\(what)")
                    #expect(developer.removalStatistics == (1, 1) && developer.keptPatchBytes == 0, "\(what)")
                }
                // The decode's texture is the scene or the spare, as it is with no removal.
                #expect((developed.image === decoded.image) == (warped == repaired), "\(what)")
                #expect((spare === decoded.image) == (warped != repaired), "\(what)")
                #expect((spare == nil) == (!warped && !repaired), "\(what)")
                decoded = nil
                withExtendedLifetime((developed, spare)) {}
                #expect(lease != nil, "\(what): the decode's texture lives on in the scene or the spare")
            }
            #expect(counts[0] == counts[1], "\(what): \(counts)")
        } }
    }

    @Test func aPatchIsUploadedOnceAndTheKeptOnesAreBounded() throws {
        let gpu = try GPU()
        let patches = try (0..<4).map { try patch(x: 10 + 30 * $0, y: 20, boxWidth: 100, boxHeight: 75, seed: UInt64(20 + $0)) }
        let stage = try LensStage(gpu: gpu, patches: FixedPatchSource(patches))
        let input = try decode(gpu), small = try decode(gpu, width: 48, height: 32)
        let one = [Removal(patch: patches[0].ref)]
        // The same patch at the frame view's size, at the sheet's, under other lens values and with its other alpha: one upload.
        for frame in [input, small, input] {
            for base in [ResolvedLensCorrection.identity, try warp(), try warp([1, 1.02], gain: [1, 1.3])] {
                _ = try stage.correct(frame, with: removing(one, base))
                _ = try stage.correct(frame, with: removing([one[0].setting(includesEffects: false)], base))
            }
        }
        #expect(stage.removalStatistics == (1, 18))
        // Ten bytes a texel, and with its chain a third more texels than its own: 64 by 48, then 32 by 24, down to one.
        let kept = stage.keptPatchBytes
        #expect(kept == (3072 + 768 + 192 + 48 + 12 + 2 + 1) * 10)
        _ = try stage.correct(input, with: removing(patches.map { Removal(patch: $0.ref) }))
        #expect(stage.removalStatistics == (4, 22) && stage.keptPatchBytes == 4 * kept)
        stage.removeKeptPatches()
        #expect(stage.keptPatchBytes == 0)
        _ = try stage.correct(input, with: removing(one))
        #expect(stage.removalStatistics == (5, 23) && stage.keptPatchBytes == kept)

        // The bound, on the composite itself: the least recently used go first, and a patch larger than the bound is not kept.
        let composite = try RemovalComposite(gpu: gpu)
        composite.maximumBytes = 2 * kept
        func lay(_ index: Int) throws { _ = try composite.composited([(patches[index], true)], onto: input, inPlace: false, bandRows: 512) }
        try lay(0); try lay(1)
        #expect(composite.statistics.uploads == 2 && composite.residentBytes == 2 * kept)
        try lay(0)
        try lay(2)
        #expect(composite.statistics.uploads == 3 && composite.residentBytes == 2 * kept)
        try lay(0)
        #expect(composite.statistics.uploads == 3, "used after the second, so the second went")
        try lay(1)
        #expect(composite.statistics.uploads == 4 && composite.residentBytes == 2 * kept)
        composite.maximumBytes = kept - 1
        #expect(composite.residentBytes == 0)
        try lay(3); try lay(3)
        #expect(composite.statistics.uploads == 6 && composite.residentBytes == 0)
        #expect(RemovalComposite.defaultMaximumBytes == 128 << 20 && LensStage.defaultKeptPatchBytes == 128 << 20)
        // The stage's own bound reaches its composite, made or not yet.
        let late = try LensStage(gpu: gpu, patches: FixedPatchSource(patches))
        late.maximumKeptPatchBytes = kept
        for index in 0..<3 { _ = try late.correct(input, with: removing([Removal(patch: patches[index].ref)])) }
        #expect(late.keptPatchBytes == kept && late.removalStatistics == (3, 3))
        late.maximumKeptPatchBytes = 0
        #expect(late.keptPatchBytes == 0 && late.maximumKeptPatchBytes == 0)
    }

    @Test func theCompositesBandsHaveIdenticalBytes() throws {
        let gpu = try GPU(), made = try patch(), stage = try LensStage(gpu: gpu, patches: FixedPatchSource([made]))
        let input = try decode(gpu)
        var results: [[UInt16]] = []
        for rows in [512, 7, 1] {
            stage.bandRows = rows
            results.append(pixels(try stage.correct(input, with: removing([Removal(patch: made.ref)]))).map(\.bitPattern))
        }
        #expect(results[0] == results[1] && results[0] == results[2])
    }

    // MARK: the chain

    @Test func aPatchsChainIsEachLevelsAreaMean() throws {
        for (width, height) in [(64, 48), (51, 37), (16, 80)] {
            let made = try patch(width: width, height: height, seed: UInt64(width))
            var level = RemovalComposite.Level(made)
            var expected = Planes(width: width, height: height, rgb: made.rgb, object: made.objectAlpha, effects: made.effectsAlpha)
            let count = RemovalComposite.levelCount(width: width, height: height)
            var sizes: [Int] = []
            for index in 1..<count {
                level = level.halved
                expected = halved(expected)
                #expect(level.width == max(1, width >> index) && level.height == max(1, height >> index))
                #expect(level.width == expected.width && level.height == expected.height)
                #expect(level.rgb == expected.rgb && level.object == expected.object && level.effects == expected.effects, "\(width)x\(height) level \(index)")
                sizes.append(level.width * level.height)
            }
            #expect(sizes.last == 1, "the chain ends at one texel")
            // The last texel is the patch's mean, to the rounding of each level between.
            let mean = stride(from: 0, to: made.rgb.count, by: 3).reduce(0.0) { $0 + Double(made.rgb[$1]) } / Double(width * height)
            #expect(abs(Double(level.rgb[0]) - mean) < 0.01 * mean)
        }
    }

    // MARK: the model's input

    @Test func theModelsInputIsTheDecodeOverItsBoxWithTheRemovalsLaid() throws {
        let gpu = try GPU()
        let first = try patch(), second = try patch(x: 120, y: 60, boxWidth: 120, boxHeight: 90, width: 48, height: 32, seed: 5)
        let stage = try LensStage(gpu: gpu, patches: FixedPatchSource([first, second]))
        let input = try decode(gpu), original = pixels(input)
        /// `values` (RGBA, bottom row first) over `box`, red, green and blue, top row first.
        func cut(_ values: [Float16], _ box: RemovalPatch.Box) -> [Float16] {
            var out: [Float16] = []
            for y in box.y..<(box.y + box.height) {
                for x in box.x..<(box.x + box.width) { out += values[((input.height - 1 - y) * input.width + x) * 4..<((input.height - 1 - y) * input.width + x) * 4 + 3] }
            }
            return out
        }
        let removals = [Removal(patch: first.ref), Removal(patch: second.ref, includesEffects: false)]
        let whole = pixels(try stage.correct(input, with: removing(removals)))
        let boxes = [try RemovalPatch.Box(x: 0, y: 0, width: 300, height: 200), try RemovalPatch.Box(x: 100, y: 50, width: 130, height: 110),
                     try RemovalPatch.Box(x: 37, y: 19, width: 21, height: 9), try RemovalPatch.Box(x: 260, y: 170, width: 40, height: 30),
                     try RemovalPatch.Box(x: 150, y: 90, width: 1, height: 1)]
        for box in boxes {
            // With nothing removed, the decode's own bits.
            #expect(try stage.removalInput(input, removals: [], box: box) == cut(original, box))
            #expect(try stage.removalInput(input, removals: removals.map { $0.setting(isOn: false) }, box: box) == cut(original, box))
            // With removals, the bits the stage lays into the whole decode, which the reference holds; and a removal sees the
            // earlier ones alone when it is given them alone.
            #expect(try stage.removalInput(input, removals: removals, box: box) == cut(whole, box), "\(box)")
            let earlier = pixels(try stage.correct(input, with: removing([removals[0]])))
            #expect(try stage.removalInput(input, removals: [removals[0]], box: box) == cut(earlier, box), "\(box)")
        }
        #expect(pixels(input) == original, "the decode is left as it was")
        let allocations = gpu.texturePool.allocationCount
        _ = try stage.removalInput(input, removals: removals, box: boxes[1])
        #expect(gpu.texturePool.allocationCount == allocations, "the cut is not the pool's to keep")

        // Only the full-size decode before the warp is cut, and only inside it.
        #expect(throws: RemovalError.invalid("a removal's input is cut from the full-size decode")) {
            try stage.removalInput(try decode(gpu, width: 150, height: 100), removals: [], box: boxes[2])
        }
        #expect(throws: RemovalError.invalid("a removal's input lies inside the frame")) {
            try stage.removalInput(input, removals: [], box: try RemovalPatch.Box(x: 280, y: 0, width: 21, height: 10))
        }
        #expect(throws: LensCorrectionError.decoderCorrected) {
            try stage.removalInput(try stage.correct(input, with: .identity), removals: [], box: boxes[2])
        }
    }
}
