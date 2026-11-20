import Foundation
import Testing
@testable import ArgentCore

/// The pipeline from a selection to a patch (docs/remove-plan.md, section 4.4) on pictures made here: where a selection lands
/// with and without a lens, the crop's box, a whole removal on the fake engine, another try, the fill under another exposure,
/// the notes and the refusals. The suite that held each step against the research prototype's own output was removed before
/// open-sourcing, because its fixtures are crops of a person's photographs; it is kept outside Git, in the research folder.
@Suite struct RemovalPipelineTests {
    typealias Pipeline = RemovalPipeline

    // MARK: pictures

    /// A selection of discs, each a centre and a radius in its own texels, soft over one texel at the edge.
    private static func selection(width: Int, height: Int, discs: [(x: Float, y: Float, radius: Float)]) throws -> Pipeline.Selection {
        var coverage = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            let inside = discs.map { $0.radius - hypot(Float(x) + 0.5 - $0.x, Float(y) + 0.5 - $0.y) }.max()!
            coverage[y * width + x] = UInt8(min(max(inside + 0.5, 0), 1) * 255)
        } }
        return try Pipeline.Selection(width: width, height: height, coverage: coverage)
    }

    /// A frame's light at a pixel: a slow gradient with a weave over it, and a flat red wherever `object` says.
    private static func light(_ x: Int, _ y: Int, object: Bool) -> (Float, Float, Float) {
        if object { return (0.9, 0.08, 0.06) }
        let weave = 0.04 * sin(Float(x) / 7) * cos(Float(y) / 11)
        let level = 0.12 + 0.25 * Float(x % 4096) / 4096 + 0.2 * Float(y % 4096) / 4096 + weave
        return (level * 0.9, level, level * 1.15)
    }

    /// The decode's pixels over a plan's box, with the plan's object painted in.
    private static func crop(_ plan: Pipeline.Plan, scaled: Float = 1) throws -> Pipeline.Crop {
        let box = plan.box
        var rgb = [Float16](repeating: 0, count: box.width * box.height * 3)
        for y in 0..<box.height { for x in 0..<box.width {
            let p = y * box.width + x, value = light(box.x + x, box.y + y, object: plan.object[p] != 0)
            rgb[p * 3] = Float16(value.0 * scaled); rgb[p * 3 + 1] = Float16(value.1 * scaled); rgb[p * 3 + 2] = Float16(value.2 * scaled)
        } }
        return try Pipeline.Crop(box: box, rgb: rgb, decoder: "test-decoder-1")
    }

    /// The coverage read at a point of the corrected picture, in the frame's pixels, as a texture reads between its texels.
    private static func coverage(_ selection: Pipeline.Selection, at p: MaskPoint, frameWidth: Int, frameHeight: Int) -> Float {
        guard p.x >= 0, p.x <= Float(frameWidth), p.y >= 0, p.y <= Float(frameHeight) else { return 0 }
        let w = selection.width, h = selection.height
        let u = min(max(p.x * Float(w) / Float(frameWidth) - 0.5, 0), Float(w - 1)), v = min(max(p.y * Float(h) / Float(frameHeight) - 0.5, 0), Float(h - 1))
        let i = Int(u), j = Int(v), i1 = min(i + 1, w - 1), j1 = min(j + 1, h - 1), s = u - Float(i), t = v - Float(j)
        func at(_ x: Int, _ y: Int) -> Float { Float(selection.coverage[y * w + x]) }
        return (at(i, j) * (1 - s) + at(i1, j) * s) * (1 - t) + (at(i, j1) * (1 - s) + at(i1, j1) * s) * t
    }

    /// The whole frame's mask, each decode pixel carried by `carry` to the corrected picture, and the plan's cut of it.
    private static func expected(_ selection: Pipeline.Selection, frameWidth: Int, frameHeight: Int,
                                 carry: (MaskPoint) -> MaskPoint) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: frameWidth * frameHeight)
        for y in 0..<frameHeight { for x in 0..<frameWidth {
            let p = carry(MaskPoint(x: Float(x) + 0.5, y: Float(y) + 0.5))
            if coverage(selection, at: p, frameWidth: frameWidth, frameHeight: frameHeight) >= 127.5 { mask[y * frameWidth + x] = 255 }
        } }
        return mask
    }

    private static func cut(_ mask: [UInt8], frameWidth: Int, to box: RemovalPatch.Box) -> [UInt8] {
        (0..<box.height).flatMap { y in mask[((box.y + y) * frameWidth + box.x)..<((box.y + y) * frameWidth + box.x + box.width)] }
    }

    private static func count(_ mask: [UInt8]) -> Int { mask.count { $0 != 0 } }

    // MARK: the selection's place

    @Test func withNoLensASelectionIsAPlainStretch() throws {
        let width = 1500, height = 1000
        let selection = try Self.selection(width: 300, height: 200, discs: [(90, 70, 22.3), (131, 96, 9.6)])
        let plan = try Pipeline.plan(selection, geometry: nil, frameWidth: width, frameHeight: height)
        let whole = Self.expected(selection, frameWidth: width, frameHeight: height) { $0 }
        #expect(plan.object == Self.cut(whole, frameWidth: width, to: plan.box))
        #expect(Self.count(plan.object) == Self.count(whole), "nothing is selected outside the box")
        // Five times the selection's 22.3 texels: the disc is some 111 pixels in radius.
        #expect(abs(Float(Self.count(plan.object)) - .pi * (111.5 * 111.5 + 48 * 48)) < 500)
        // The decode's own geometry warps nothing either.
        #expect(try Pipeline.plan(selection, geometry: Pipeline.decodeGeometry, frameWidth: width, frameHeight: height) == plan)

        // At the frame's own size the mask is the coverage at 128 and above.
        let same = try Self.selection(width: 240, height: 160, discs: [(100.5, 80.25, 30.4)])
        let exact = try Pipeline.plan(same, geometry: nil, frameWidth: 240, frameHeight: 160)
        #expect(exact.box == (try RemovalPatch.Box(x: 0, y: 0, width: 240, height: 160)))
        #expect(exact.object == same.coverage.map { $0 >= 128 ? 255 : 0 })
    }

    /// A lens that pulls the corner in by 3 %, as a wide zoom's correction does: a selection near the corner lands where
    /// `LensRemap` carries each decode pixel, over ten pixels from where a plain stretch would put it.
    @Test func underALensASelectionLandsWhereTheRemapSaysItDoes() throws {
        let width = 1800, height = 1200
        let table = try RadialTable(knots: (0...15).map { 1 - 0.05 * pow(Double($0) / 15, 2) })
        let geometry = try LensGeometry(table: table, scale: 0.98)
        let extent = MaskPoint(x: Float(width), y: Float(height))
        let toPicture = try #require(LensRemap(from: ResolvedLensCorrection.identity.geometry, to: geometry, extent: extent))
        let toDecode = try #require(LensRemap(from: geometry, to: ResolvedLensCorrection.identity.geometry, extent: extent))

        // One disc by the top left corner, where the lens moves most, and one by the middle.
        let selection = try Self.selection(width: 900, height: 600, discs: [(70, 60, 30), (430, 310, 12)])
        let plan = try Pipeline.plan(selection, geometry: geometry, frameWidth: width, frameHeight: height)
        let whole = Self.expected(selection, frameWidth: width, frameHeight: height) { toPicture.point($0) }
        #expect(plan.object == Self.cut(whole, frameWidth: width, to: plan.box))
        #expect(Self.count(plan.object) == Self.count(whole), "nothing is selected outside the box")

        // The corner disc alone: its middle in the decode is the remap's, not the stretch's.
        let corner = try Self.selection(width: 900, height: 600, discs: [(70, 60, 30)])
        let warped = try Pipeline.plan(corner, geometry: geometry, frameWidth: width, frameHeight: height)
        let flat = try Pipeline.plan(corner, geometry: nil, frameWidth: width, frameHeight: height)
        func middle(_ plan: Pipeline.Plan) -> MaskPoint {
            var x: Float = 0, y: Float = 0, n: Float = 0
            for row in 0..<plan.box.height { for column in 0..<plan.box.width where plan.object[row * plan.box.width + column] != 0 {
                x += Float(plan.box.x + column) + 0.5; y += Float(plan.box.y + row) + 0.5; n += 1
            } }
            return MaskPoint(x: x / n, y: y / n)
        }
        let said = toDecode.point(MaskPoint(x: 140, y: 120)), found = middle(warped), stretched = middle(flat)
        #expect(hypot(found.x - said.x, found.y - said.y) < 1, "\(found) against \(said)")
        #expect(hypot(stretched.x - 140, stretched.y - 120) < 0.5)
        #expect(hypot(found.x - stretched.x, found.y - stretched.y) > 10, "the lens moves the corner disc \(hypot(found.x - stretched.x, found.y - stretched.y)) pixels")
    }

    // MARK: the crop

    /// The crop is the object with context about it, at a size the model takes as it is wherever one fits: the fill is then
    /// drawn at the picture's own scale and is as sharp as what is round it.
    @Test func theCropIsTheObjectWithItsContextAtASizeTheModelTakes() throws {
        let frame = (width: 7008, height: 4672)
        let cases: [(Pipeline.Bounds, [Int], [Int])] = [
            // Small: the least context, and the model's least size, at the picture's scale.
            (.init(x0: 3000, y0: 2000, x1: 3099, y1: 2199), [2793, 1843, 512, 512], [512, 512]),
            // A person: half the height as context, each side stepped up to the grid.
            (.init(x0: 3000, y0: 2000, x1: 3199, y1: 2599), [2651, 1659, 896, 1280], [896, 1280]),
            // Twice the object is past the limit: the crop is reduced, and no more than it must be.
            (.init(x0: 2000, y0: 1500, x1: 2999, y1: 2499), [1499, 999, 2000, 2000], [1344, 1344]),
            // The most context, then the frame's edge.
            (.init(x0: 1000, y0: 500, x1: 3499, y1: 2999), [487, 0, 3524, 3524], [1344, 1344]),
            // Most of the frame: widened to the grid, then cut by the frame's height.
            (.init(x0: 100, y0: 100, x1: 3899, y1: 4399), [0, 0, 5070, 4672], [1344, 1232]),
            // The corner.
            (.init(x0: 6900, y0: 4600, x1: 7007, y1: 4671), [6496, 4160, 512, 512], [512, 512]),
            // Long and thin, and past the limit: widened until its short side is on the grid at that scale.
            (.init(x0: 3000, y0: 1000, x1: 3059, y1: 2499), [2428, 487, 1202, 2524], [640, 1344]),
            // The largest object worked at the picture's own scale, 672 pixels, and the first that is not.
            (.init(x0: 3000, y0: 2000, x1: 3671, y1: 2671), [2663, 1663, 1344, 1344], [1344, 1344]),
            (.init(x0: 3000, y0: 2000, x1: 3672, y1: 2672), [2664, 1664, 1345, 1345], [1344, 1344]),
            // A square object past the limit keeps a square crop, where rounding once made it taller.
            (.init(x0: 3000, y0: 2000, x1: 4054, y1: 3054), [2488, 1488, 2079, 2079], [1344, 1344]),
        ]
        for (object, expected, working) in cases {
            let box = try Pipeline.cropBox(around: object, frameWidth: frame.width, frameHeight: frame.height)
            let sides: [Int] = [box.x, box.y, box.width, box.height]
            #expect(sides == expected, "\(object)")
            let size = Pipeline.workingSize(width: box.width, height: box.height)
            #expect([size.width, size.height] == working, "\(object)")
            #expect(box.x <= object.x0 && box.y <= object.y0 && box.x + box.width > object.x1 && box.y + box.height > object.y1)
            if max(box.width, box.height) <= RemovalPatch.longSideLimit { #expect(size == (box.width, box.height), "the picture's own scale") }
        }
        // Whatever the object, a crop no frame cuts has working sides on the grid or at the limit, the model's training size at
        // least, and a square object's is square: few sizes for the model to compile for.
        let grid = Set(stride(from: RemovalPatch.shortSide, through: RemovalPatch.longSideLimit, by: Pipeline.sizeStep)).union([RemovalPatch.longSideLimit])
        var sizes = Set<[Int]>()
        for wide in stride(from: 40, to: 3000, by: 37) {
            for tall in stride(from: 40, to: 3000, by: 41) {
                let box = try Pipeline.cropBox(around: .init(x0: 10_000, y0: 10_000, x1: 10_000 + wide - 1, y1: 10_000 + tall - 1),
                                               frameWidth: 60_000, frameHeight: 60_000)
                let size = Pipeline.workingSize(width: box.width, height: box.height)
                if !grid.contains(size.width) || !grid.contains(size.height) { Issue.record("\(wide) x \(tall): \(size)") }
                sizes.insert([size.width, size.height])
            }
        }
        #expect(sizes.count <= grid.count * grid.count)
        for side in 1...4000 {
            let box = try Pipeline.cropBox(around: .init(x0: 10_000, y0: 10_000, x1: 10_000 + side - 1, y1: 10_000 + side - 1),
                                           frameWidth: 60_000, frameHeight: 60_000)
            if box.width != box.height { Issue.record("a square of \(side) has a crop of \(box.width) x \(box.height)") }
        }

        // A frame smaller than the crop is the crop, enlarged to the model's size.
        let small = try Pipeline.cropBox(around: .init(x0: 40, y0: 30, x1: 60, y1: 50), frameWidth: 300, frameHeight: 200)
        let whole: [Int] = [small.x, small.y, small.width, small.height]
        #expect(whole == [0, 0, 300, 200] && Pipeline.workingSize(width: 300, height: 200) == (768, 512))
    }

    /// A crop reduced by a hair is not blurred: each working pixel is the mean of the area under it, not of every pixel it
    /// touches, which for 1345 pixels to 1344 would be two each way.
    @Test func aReducedCropIsTheMeanOfTheAreaUnderEachPixel() {
        // Columns of 0 and 1 in turn, 1345 to 1344: under working pixel x lie crop pixel x and a sliver of the next.
        let width = 1345, height = 4
        var stripes = [Float16](repeating: 0, count: width * height * 3)
        for y in 0..<height { for x in 0..<width where x % 2 == 1 { for k in 0..<3 { stripes[(y * width + x) * 3 + k] = 1 } } }
        let exact = Pipeline.resized(stripes, width: width, height: height, to: (1344, height))
        let whole = Pipeline.resized(stripes, width: width, height: height, to: (1344, height), wholePixels: true)
        for x in [0, 1, 10, 11, 100, 101] {
            let value = exact[x * 3], expected = Float(x % 2)
            #expect(abs(value - expected) < 0.1, "column \(x) is \(value)")
            #expect(x == 0 || whole[x * 3] == 0.5, "the prototype's whole pixels halve the stripes")
        }
        // No light is made or lost: the mean of the whole is the crop's.
        let mean = exact.reduce(0, +) / Float(exact.count), before = stripes.reduce(Float(0)) { $0 + Float($1) } / Float(stripes.count)
        #expect(abs(mean - before) < 1e-4)

        // Two to one, the two are the same: the mean of each two by two.
        var ramp = [Float16](repeating: 0, count: 8 * 4 * 3)
        for p in 0..<32 { for k in 0..<3 { ramp[p * 3 + k] = Float16(p) } }
        let halved = Pipeline.resized(ramp, width: 8, height: 4, to: (4, 2))
        #expect(halved == Pipeline.resized(ramp, width: 8, height: 4, to: (4, 2), wholePixels: true))
        #expect(halved[0] == (0 + 1 + 8 + 9) / 4 && halved[(1 * 4 + 3) * 3] == (22 + 23 + 30 + 31) / 4)
        // Three to two: the middle pixel is shared half and half.
        let thirds = Pipeline.resized([0, 0, 0, 3, 3, 3, 9, 9, 9], width: 3, height: 1, to: (2, 1))
        #expect(thirds[0] == 1 && thirds[3] == 7)
    }

    /// An object too long for the picture's own scale: the crop is reduced no more than it must be, its job is the area mean of
    /// the crop, and it is made again from its patch as any other.
    @Test func anObjectPastTheLimitIsRemovedOnAReducedCrop() async throws {
        // Five discs in a row, 820 pixels by 180 in the frame: with 410 a side the crop is 1640 long.
        let run = try await Self.run(discs: (0..<5).map { (228 + 40 * Float($0), 260, 22) })
        let box = run.plan.box, w = run.width, h = run.height
        #expect(box.width > RemovalPatch.longSideLimit && box.width < 1700 && w == 1344 && h == 896, "\(box) on \(w) x \(h)")
        #expect(abs(Double(box.height) * Double(w) / Double(box.width) - Double(h)) < 1, "the short side is on the grid at the crop's scale")
        #expect(!run.patch.isSoftAtFullSize && run.patch.notes.growth == Pipeline.maskGrowth)
        // The job's picture is the crop's light, none made or lost, and it has kept the weave a plain mean of two pixels halves.
        func mean(_ values: [Float]) -> Double { values.reduce(0.0) { $0 + Double($1) } / Double(values.count) }
        let original = run.prepared.original, kept = mean(original), given = mean(run.crop.rgb.map { Float($0) })
        #expect(abs(kept - given) < 1e-5, "\(kept) against \(given)")
        // Made again, the model gets the mask and the picture it had.
        let again = try Pipeline.plan(retrying: run.patch, frameWidth: 3000, frameHeight: 2000)
        let second = try Pipeline.prepare(run.crop, plan: again, seed: 9)
        #expect(again.box == box && second.job.width == w && second.job.height == h)
        #expect(second.job.mask == run.prepared.job.mask && second.job.image == run.prepared.job.image)
        // A patch that does not note its growth was grown 2: shrunk by that, its object is larger than one shrunk by 4.
        var unnoted = run.patch
        unnoted.notes.growth = nil
        let older = try Pipeline.plan(retrying: unnoted, frameWidth: 3000, frameHeight: 2000)
        #expect(Self.count(older.object) > Self.count(again.object))
        #expect(older.object.indices.allSatisfy { again.object[$0] == 0 || older.object[$0] != 0 })
    }

    // MARK: a whole removal

    /// What a removal on the fake engine gives, with what made it.
    private struct Run {
        let selection: Pipeline.Selection
        let plan: Pipeline.Plan
        let crop: Pipeline.Crop
        let prepared: Pipeline.Prepared
        let output: RemovalOutput
        let patch: RemovalPatch
        var width: Int { patch.width }
        var height: Int { patch.height }
        /// The changed area, as `finish` takes it.
        var changed: [UInt8] {
            Pipeline.changedArea(object: prepared.job.mask, attention: output.attention, width: width, height: height,
                                 growth: Pipeline.changedGrowth(shortSide: min(width, height)))
        }
    }

    private static let made = Date(timeIntervalSince1970: 1_800_000_000)

    /// A red disc, 320 pixels across, removed from a 3000 x 2000 frame.
    private static func run(faces: [FaceMeasure] = [], discs: [(x: Float, y: Float, radius: Float)] = [(300, 260, 40)]) async throws -> Run {
        let selection = try selection(width: 750, height: 500, discs: discs)
        let plan = try Pipeline.plan(selection, geometry: nil, frameWidth: 3000, frameHeight: 2000)
        let crop = try crop(plan)
        let prepared = try Pipeline.prepare(crop, plan: plan, seed: 7)
        let output = try await FakeRemovalEngine().run(prepared.job) { _, _ in }
        let patch = try Pipeline.finish(output, prepared: prepared, faces: faces, made: made)
        return Run(selection: selection, plan: plan, crop: crop, prepared: prepared, output: output, patch: patch)
    }

    @Test func aSelectionBecomesAPatchOnTheFakeEngine() async throws {
        let run = try await Self.run()
        let plan = run.plan, patch = run.patch, w = run.width, h = run.height
        // The disc is columns 1040 to 1359 and rows 880 to 1199, so the crop is its 320 pixels with half of that a side about
        // its middle pixel, and the model's size is the crop's.
        #expect(plan.box == (try RemovalPatch.Box(x: 879, y: 719, width: 640, height: 640)))
        #expect(patch.box == plan.box && w == 640 && h == 640 && !patch.isSoftAtFullSize)
        #expect(run.prepared.job.steps == RemovalJob.defaultSteps && run.prepared.job.guidance == RemovalJob.defaultGuidance)

        // The object alpha is full over the selection, and at 128 and above it is the mask the model was given.
        let selected = Pipeline.resampled(plan.object, width: plan.box.width, height: plan.box.height, to: (w, h))
        #expect(Self.count(selected) > 16_000)
        #expect(selected.indices.allSatisfy { selected[$0] == 0 || patch.objectAlpha[$0] == 255 })
        #expect(patch.objectAlpha.map { $0 >= 128 ? 255 : 0 } == run.prepared.job.mask)
        #expect(run.prepared.job.mask == Pipeline.grown(selected, width: w, height: h, by: Pipeline.maskGrowth))
        // The effects alpha is never below it, is full over the changed area but for its edge, and is nothing far from it.
        let changed = run.changed
        #expect(patch.effectsAlpha.indices.allSatisfy { patch.effectsAlpha[$0] >= patch.objectAlpha[$0] })
        #expect(patch.effectsAlpha.map { $0 >= 128 ? 255 : 0 } == changed)
        #expect(Set(patch.effectsAlpha) == [0, 85, 170, 255] && Set(patch.objectAlpha) == [0, 85, 170, 255])
        #expect(Self.count(changed) > Self.count(run.prepared.job.mask) && Self.count(changed) < w * h / 2)

        // Outside the changed area the patch is the crop at the working size, to a half float's rounding.
        let original = run.prepared.original
        for p in 0..<(w * h) where changed[p] == 0 {
            for k in 0..<3 { #expect(patch.rgb[p * 3 + k] == Float16(original[p * 3 + k])) }
        }
        // And that is the crop itself, pixel for pixel: the model works at the picture's scale.
        #expect(original == run.crop.rgb.map { Float($0) })

        // Inside the object the red disc is gone: the fill is the surround's grey-blue, and meets it at the edge's level.
        let middle = (h / 2) * w + w / 2
        #expect(selected[middle] != 0 && Float(original[middle * 3]) > 0.8)
        let fill = (0..<3).map { Float(patch.rgb[middle * 3 + $0]) }
        #expect(fill[0] < fill[1] && fill[1] < fill[2] && fill[1] > 0.15 && fill[1] < 0.5, "\(fill)")

        // The notes say what made it.
        let notes = patch.notes
        #expect(notes.engine == FakeRemovalEngine.engineID && notes.weights == FakeRemovalEngine.weightsID)
        #expect(notes.steps == RemovalJob.defaultSteps && notes.guidance == 1 && notes.seed == 7 && notes.decoder == "test-decoder-1")
        #expect(notes.frameWidth == 3000 && notes.frameHeight == 2000 && notes.made == Self.made && notes.face == nil)
        // And it is a patch its file holds.
        #expect(try RemovalPatch(decoding: patch.encoded()) == patch)
    }

    /// Try Again and Better: the box is the patch's, and the model gets the mask it had, the first time and every time after.
    @Test func tryingAgainGivesTheModelTheMaskItHad() async throws {
        // Two discs that nearly touch and a small one apart: a shape with a waist and a gap.
        let first = try await Self.run(discs: [(300, 260, 40), (352, 300, 28), (240, 330, 6)])
        let again = try Pipeline.plan(retrying: first.patch, frameWidth: 3000, frameHeight: 2000)
        #expect(again.box == first.patch.box && again.frameWidth == 3000 && again.frameHeight == 2000)
        let better = try Pipeline.prepare(first.crop, plan: again, steps: RemovalJob.betterSteps, guidance: RemovalJob.betterGuidance, seed: 8)
        #expect(better.job.mask == first.prepared.job.mask && better.job.image == first.prepared.job.image)
        #expect(better.job.steps == 20 && better.job.guidance == 2.5 && better.job.seed == 8)

        let output = try await FakeRemovalEngine().run(better.job) { _, _ in }
        let second = try Pipeline.finish(output, prepared: better, faces: [], made: Self.made)
        #expect(second.objectAlpha == first.patch.objectAlpha && second.effectsAlpha == first.patch.effectsAlpha)
        #expect(second.notes.steps == 20 && second.notes.seed == 8)
        #expect(try Pipeline.plan(retrying: second, frameWidth: 3000, frameHeight: 2000) == again)
        // The plan a patch gives holds the object's own pixels or a little more, never less.
        #expect(again.object.indices.allSatisfy { first.plan.object[$0] == 0 || again.object[$0] != 0 })
        #expect(Self.count(again.object) < Self.count(first.plan.object) * 11 / 10)
    }

    /// A frame smaller than the model's size is enlarged to it, and comes out as any other.
    @Test func aFrameSmallerThanTheModelsSizeIsRemovedFromToo() async throws {
        let selection = try Self.selection(width: 200, height: 150, discs: [(90, 70, 20)])
        let plan = try Pipeline.plan(selection, geometry: nil, frameWidth: 200, frameHeight: 150)
        #expect(plan.box == (try RemovalPatch.Box(x: 0, y: 0, width: 200, height: 150)))
        let prepared = try Pipeline.prepare(try Self.crop(plan), plan: plan, seed: 1)
        #expect(prepared.job.width == 688 && prepared.job.height == 512)
        let patch = try Pipeline.finish(try await FakeRemovalEngine().run(prepared.job) { _, _ in }, prepared: prepared, faces: [])
        let selected = Pipeline.resampled(plan.object, width: 200, height: 150, to: (688, 512))
        #expect(selected.indices.allSatisfy { selected[$0] == 0 || patch.objectAlpha[$0] == 255 })
        #expect(abs(Float(Self.count(selected)) / Float(688 * 512) - Float(Self.count(plan.object)) / Float(200 * 150)) < 0.002)
        #expect(!patch.isSoftAtFullSize)
        let again = try Pipeline.plan(retrying: patch, frameWidth: 200, frameHeight: 150)
        #expect(try Pipeline.prepare(prepared.crop, plan: again, seed: 2).job.mask == prepared.job.mask)
    }

    // MARK: exposure

    /// The match is a ratio, so it follows the crop's exposure. The same picture two stops down and two stops up gives the
    /// model the same job, and for the same output a fill that is the first one's times 0.25 and times 4, to within 0.2 % of
    /// the value (of the value and a tenth of the scale, so that black is not divided by). Measured, the worst is 0.07 %: one
    /// step of a half float. They are not equal to the bit because the ratio is taken between values lifted by 0.0001, which
    /// is a larger share of a darker picture.
    @Test func theFillFollowsTheCropsExposureTwoStopsEitherWay() async throws {
        let run = try await Self.run()
        let w = run.width, h = run.height
        // A model answers in its own colour and contrast: here flatter, lifted and warmer.
        var image = run.output.image
        for p in stride(from: 0, to: image.count, by: 3) {
            image[p] = UInt8(min(255, Float(image[p]) * 0.85 + 40)); image[p + 1] = UInt8(min(255, Float(image[p + 1]) * 0.8 + 40))
            image[p + 2] = UInt8(min(255, Float(image[p + 2]) * 0.8 + 30))
        }
        let output = try RemovalOutput(width: w, height: h, image: image, attention: run.output.attention, engine: "test", weights: "")
        let level = try Pipeline.finish(output, prepared: run.prepared, faces: [], made: Self.made)

        // The match has work to do: around the object the model's picture is off by 0.46 of a stop before it and 0.03 after.
        let changed = run.changed, raw = Pipeline.decoded(image, gain: run.prepared.gain)
        var off: Float = 0, corrected: Float = 0, n: Float = 0
        for p in 0..<(w * h) where changed[p] != 0 && run.prepared.job.mask[p] == 0 {
            off += abs(log2(raw[p * 3 + 1] / run.prepared.original[p * 3 + 1]))
            corrected += abs(log2(Float(level.rgb[p * 3 + 1]) / run.prepared.original[p * 3 + 1])); n += 1
        }
        #expect(off / n > 0.1 && corrected / n < off / n / 3, "off by \(off / n) stops before the match and \(corrected / n) after")

        for scale in [Float(0.25), 4] {
            let prepared = try Pipeline.prepare(try Self.crop(run.plan, scaled: scale), plan: run.plan, seed: 7)
            #expect(prepared.job == run.prepared.job, "the job at \(scale)")
            #expect(prepared.gain == run.prepared.gain / scale)
            let patch = try Pipeline.finish(output, prepared: prepared, faces: [], made: Self.made)
            #expect(patch.objectAlpha == level.objectAlpha && patch.effectsAlpha == level.effectsAlpha)
            var worst: Float = 0
            for i in patch.rgb.indices {
                let expected = Float(level.rgb[i]) * scale
                worst = max(worst, abs(Float(patch.rgb[i]) - expected) / (abs(expected) + 0.1 * scale))
            }
            #expect(worst <= 0.002, "at \(scale) the fill is off by \(worst) of its value")
        }
    }

    // MARK: the notes

    /// Faces by their boxes in the frame's pixels.
    private static func face(_ x: Float, _ y: Float, _ width: Float, _ height: Float, frame: (Float, Float) = (3000, 2000)) -> FaceMeasure {
        FaceMeasure(box: [x / frame.0, y / frame.1, width / frame.0, height / frame.1], levelStops: 0, area: 0.01)
    }

    /// The disc is 160 pixels in radius about (1200, 1040). The fake engine's attention reaches 8 working pixels past the
    /// mask and the changed area 4 more, some 26 pixels of the frame past the disc.
    @Test func aFaceIsNotedWhenTheChangedAreaReachesIntoItAndItWasNotTheObject() async throws {
        let own = Self.face(1150, 990, 100, 100)          // inside the disc: the object's own face
        let beside = Self.face(1340, 990, 100, 100)       // its left fifth under the disc's edge, more under the changed area
        let brushed = Self.face(1381, 990, 100, 100)      // five pixels of it under the changed area
        let far = Self.face(2400, 300, 200, 200)
        let run = try await Self.run()
        func noted(_ faces: [FaceMeasure]) throws -> [Float]? {
            try Pipeline.finish(run.output, prepared: run.prepared, faces: faces, made: Self.made).notes.face
        }
        #expect(try noted([beside]) == beside.box)
        #expect(try noted([far, own, beside, brushed]) == beside.box)
        #expect(try noted([own]) == nil, "the object is the face")
        #expect(try noted([brushed, far]) == nil)
        #expect(try noted([]) == nil)
        // A note changes nothing else of the patch, its name least of all.
        let with = try Pipeline.finish(run.output, prepared: run.prepared, faces: [beside], made: Self.made)
        #expect(with.identity == run.patch.identity && with.rgb == run.patch.rgb)
    }

    /// The rule itself, on a raster of 100 by 100 that is its own frame: the object is columns 0 to 49 and the changed area
    /// columns 0 to 59. A face counts when the changed area covers a tenth of its box and the object less than half.
    @Test func aFaceCountsAtATenthOfItsBoxAndIsTheObjectsOwnAtHalf() throws {
        var object = [UInt8](repeating: 0, count: 10_000), changed = object
        for y in 0..<100 { for x in 0..<60 { changed[y * 100 + x] = 255; if x < 50 { object[y * 100 + x] = 255 } } }
        let plan = try Pipeline.Plan(box: RemovalPatch.Box(x: 0, y: 0, width: 100, height: 100), object: object, frameWidth: 100, frameHeight: 100)
        func noted(_ boxes: [[Float]]) -> [Float]? {
            Pipeline.redrawnFace(boxes.map { FaceMeasure(box: $0, levelStops: 0, area: 0) }, changed: changed, object: object,
                                 width: 100, height: 100, plan: plan)
        }
        #expect(noted([[0.50, 0.4, 0.2, 0.2]]) == [0.50, 0.4, 0.2, 0.2], "half redrawn, none of it the object")
        #expect(noted([[0.57, 0.4, 0.2, 0.2]]) == [0.57, 0.4, 0.2, 0.2], "three twentieths redrawn")
        #expect(noted([[0.59, 0.4, 0.2, 0.2]]) == nil, "one twentieth redrawn")
        #expect(noted([[0.42, 0.4, 0.2, 0.2]]) == [0.42, 0.4, 0.2, 0.2], "two fifths of it the object")
        #expect(noted([[0.38, 0.4, 0.2, 0.2]]) == nil, "three fifths of it the object: its own")
        #expect(noted([[0.20, 0.4, 0.2, 0.2]]) == nil)
        #expect(noted([[0.57, 0.1, 0.2, 0.2], [0.52, 0.6, 0.2, 0.2], [0.55, 0.3, 0.2, 0.2]]) == [0.52, 0.6, 0.2, 0.2], "the most covered")
        // A box that runs off the frame is counted by what the frame holds of it.
        #expect(noted([[-0.2, 0.4, 0.3, 0.2]]) == nil, "its tenth in the frame is the object's")
        #expect(noted([[0.9, 0.9, 0.3, 0.3], [0.5, 0.5, 0, 0.2], [.nan, 0, 0.1, 0.1], [0.5, 0.5]]) == nil)

        // A crop that holds a part of a face counts the rest as untouched.
        let part = try Pipeline.Plan(box: RemovalPatch.Box(x: 100, y: 0, width: 100, height: 100), object: object, frameWidth: 400, frameHeight: 100)
        func inPart(_ box: [Float]) -> [Float]? {
            Pipeline.redrawnFace([FaceMeasure(box: box, levelStops: 0, area: 0)], changed: changed, object: object, width: 100, height: 100, plan: part)
        }
        #expect(inPart([0.25, 0.4, 0.1, 0.2]) == nil, "the crop's first forty columns, all the object's")
        #expect(inPart([0.37, 0.4, 0.2, 0.2]) == [0.37, 0.4, 0.2, 0.2], "columns 48 to 127 of the crop: twelve of eighty redrawn")
        #expect(inPart([0.39, 0.4, 0.4, 0.2]) == nil, "columns 56 to 215: four of a hundred and sixty")
    }

    @Test func softAtFullSizeFollowsTheBox() async throws {
        // A disc 192 pixels across takes the least crop, 512, and one of 320 takes 640: the patch is the crop's size.
        let small = try await Self.run(discs: [(300, 260, 24)])
        #expect(small.plan.box.width == 512 && small.plan.box.height == 512 && small.width == 512 && small.height == 512)
        #expect(!small.patch.isSoftAtFullSize)
        #expect(!(try await Self.run().patch.isSoftAtFullSize))
        // One 800 across takes 1600, reduced to the limit: less than the crop, and not by half. One 1696 across takes the frame's
        // height and 2720 of its width, on 1344 by 992: soft. A patch is soft by its box and its size alone, so these are not run.
        func patch(radius: Float) throws -> RemovalPatch {
            let plan = try Pipeline.plan(try Self.selection(width: 750, height: 500, discs: [(300, 260, radius)]), geometry: nil,
                                         frameWidth: 3000, frameHeight: 2000)
            let size = Pipeline.workingSize(width: plan.box.width, height: plan.box.height), count = size.width * size.height
            return try RemovalPatch(box: plan.box, width: size.width, height: size.height, rgb: [Float16](repeating: 0, count: count * 3),
                                    objectAlpha: [UInt8](repeating: 0, count: count), effectsAlpha: [UInt8](repeating: 0, count: count))
        }
        let large = try patch(radius: 100)
        #expect(large.box.width == 1600 && large.box.height == 1600 && large.width == 1344 && large.height == 1344)
        #expect(!large.isSoftAtFullSize)
        let huge = try patch(radius: 212)
        #expect(huge.box.width == 2720 && huge.box.height == 2000 && huge.width == 1344 && huge.height == 992)
        #expect(huge.isSoftAtFullSize)
    }

    // MARK: refusals

    @Test func whatCannotBeRemovedIsRefused() async throws {
        // Nothing selected.
        #expect(throws: RemovalError.invalid("nothing is selected")) {
            try Pipeline.Selection(width: 8, height: 8, coverage: [UInt8](repeating: 127, count: 64))
        }
        // A speck of a selection far finer than the frame, between the frame's pixels.
        var speck = [UInt8](repeating: 0, count: 4000 * 400)
        speck[205 * 4000 + 2005] = 255
        #expect(throws: RemovalError.invalid("nothing is selected at the frame's size")) {
            try Pipeline.plan(Pipeline.Selection(width: 4000, height: 400, coverage: speck), geometry: nil, frameWidth: 100, frameHeight: 10)
        }
        let selection = try Self.selection(width: 300, height: 200, discs: [(90, 70, 20)])
        #expect(throws: RemovalError.self) { try Pipeline.plan(selection, geometry: nil, frameWidth: 0, frameHeight: 2000) }
        #expect(throws: RemovalError.self) { try Pipeline.plan(selection, geometry: nil, frameWidth: 3000, frameHeight: 70_000) }

        // A crop that is not the plan's box.
        let run = try await Self.run()
        let other = try RemovalPatch.Box(x: run.plan.box.x + 1, y: run.plan.box.y, width: run.plan.box.width, height: run.plan.box.height)
        #expect(throws: RemovalError.invalid("a crop is cut to its plan's box")) {
            try Pipeline.prepare(Pipeline.Crop(box: other, rgb: run.crop.rgb, decoder: "test"), plan: run.plan, seed: 1)
        }
        // A plan with nothing in it.
        let empty = try Pipeline.Plan(box: run.plan.box, object: [UInt8](repeating: 0, count: run.plan.object.count), frameWidth: 3000, frameHeight: 2000)
        #expect(throws: RemovalError.invalid("nothing is selected")) { try Pipeline.prepare(run.crop, plan: empty, seed: 1) }

        // An output that is not the job's size.
        let short = try RemovalOutput(width: 512, height: 496, image: [UInt8](repeating: 0, count: 512 * 496 * 3),
                                      attention: [UInt8](repeating: 0, count: 512 * 496), engine: "test", weights: "")
        #expect(throws: RemovalError.invalid("an output is its job's size")) { try Pipeline.finish(short, prepared: run.prepared, faces: []) }

        // A patch that selects nothing, and one that lies outside the frame it is tried again on.
        let blank = try RemovalPatch(box: run.patch.box, width: 16, height: 16, rgb: [Float16](repeating: 0, count: 768),
                                     objectAlpha: [UInt8](repeating: 100, count: 256), effectsAlpha: [UInt8](repeating: 255, count: 256))
        #expect(throws: RemovalError.self) { try Pipeline.plan(retrying: blank, frameWidth: 3000, frameHeight: 2000) }
        #expect(throws: RemovalError.self) { try Pipeline.plan(retrying: run.patch, frameWidth: 1500, frameHeight: 2000) }
    }

    // MARK: the steps

    @Test func theGainPutsTheCropsMedianAtAQuarter() throws {
        // Three levels in equal shares down the columns: the middle one is the median.
        let box = try RemovalPatch.Box(x: 0, y: 0, width: 99, height: 40)
        var rgb = [Float16](repeating: 0, count: 99 * 40 * 3)
        for p in 0..<(99 * 40) { for k in 0..<3 { rgb[p * 3 + k] = [0.02, 0.5, 3][(p % 99) / 33] } }
        let gain = Pipeline.gain(for: try Pipeline.Crop(box: box, rgb: rgb, decoder: "test"))
        #expect(abs(gain - 0.5) < 1e-4)
        let grey = Pipeline.encoded([0.5, 0.5, 0.5], gain: gain)
        // A quarter through the shoulder and sRGB's curve is byte 124.
        #expect(grey == [124, 124, 124])
        // A black crop is not multiplied without end, and a crop of no numbers is black.
        let black = try Pipeline.Crop(box: box, rgb: [Float16](repeating: 0, count: rgb.count), decoder: "test")
        #expect(abs(Pipeline.gain(for: black) - 2500) < 0.01)
        let broken = try Pipeline.Crop(box: box, rgb: [Float16](repeating: .nan, count: rgb.count), decoder: "test")
        #expect(abs(Pipeline.gain(for: broken) - 2500) < 0.01)
        #expect(Pipeline.resized(broken.rgb, width: 99, height: 40, to: (32, 16)).allSatisfy { $0 == 0 })
        #expect(Pipeline.encoded([.infinity, 0, 0, .nan, .nan, .nan], gain: 1) == [255, 0, 0, 0, 0, 0])
    }

    @Test func theCurveIsUndoneToAByte() {
        // Rec. 2020 greys from deep shadow to three stops over the median: encoded and decoded, each is itself to within the
        // half byte the curve was rounded by.
        for stops in stride(from: Float(-7), through: 3, by: 0.25) {
            let value = 0.25 * exp2(stops), gain: Float = 1.7
            let bytes = Pipeline.encoded([value / gain, value / gain, value / gain], gain: gain)
            let back = Pipeline.decoded(bytes, gain: gain)[1] * gain
            let step = Pipeline.decoded([bytes[0] &+ 1, bytes[1] &+ 1, bytes[2] &+ 1], gain: gain)[1] * gain - back
            #expect(abs(back - value) <= abs(step) * 0.6, "\(stops) stops: \(value) came back \(back)")
        }
        #expect(Pipeline.decoded([255, 255, 255], gain: 1).allSatisfy { $0 > 5.9 && $0 < 6 }, "white is held just under the shoulder's end")
    }

    @Test func theMedianIsTheSortedOne() {
        var seed: UInt64 = 42
        func next() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) }
        for count in [1, 2, 3, 10, 257, 5000] {
            var values = (0..<count).map { _ in count == 10 ? Float(Int(next() * 3)) : next() }
            let sorted = values.sorted()
            for index in [0, count / 2, count - 1] {
                var copy = values
                #expect(Pipeline.ordered(&copy, at: index) == sorted[index])
            }
            #expect(Pipeline.ordered(&values, at: count / 2) == sorted[count / 2])
        }
    }

    @Test func masksGrowShrinkAndChangeSizeAsTheyShould() {
        let w = 37, h = 29
        var seed: UInt64 = 7
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        let mask = (0..<(w * h)).map { _ in next() % 23 == 0 ? UInt8(255) : 0 }
        // Grown is the square around each selected pixel.
        for reach in [1, 2, 5] {
            var square = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w where mask[y * w + x] != 0 {
                for j in max(0, y - reach)...min(h - 1, y + reach) { for i in max(0, x - reach)...min(w - 1, x + reach) { square[j * w + i] = 255 } }
            } }
            let grown = Pipeline.grown(mask, width: w, height: h, by: reach)
            #expect(grown == square)
            // Shrinking what was grown leaves at least the mask, and growing that again is the grown mask.
            let shrunk = Pipeline.shrunk(grown, width: w, height: h, by: reach)
            #expect(mask.indices.allSatisfy { mask[$0] == 0 || shrunk[$0] != 0 })
            #expect(Pipeline.grown(shrunk, width: w, height: h, by: reach) == grown)
        }
        // Stretched and reduced again a mask is itself, whatever the two sizes' ratio.
        for size in [(74, 58), (100, 31), (37, 200), (111, 87)] {
            let large = Pipeline.resampled(mask, width: w, height: h, to: size)
            #expect(Pipeline.resampled(large, width: size.0, height: size.1, to: (w, h)) == mask, "\(size)")
        }
        // Reduced, a pixel is selected when any pixel under it is.
        let wide = (0..<(64 * 4)).map { $0 % 64 == 21 || $0 == 63 ? UInt8(255) : 0 }
        #expect(Pipeline.resampled(wide, width: 64, height: 4, to: (16, 1)) == (0..<16).map { $0 == 5 || $0 == 15 ? 255 : 0 })
    }

    /// A feather of 3 is a ramp three pixels wide across the edge: 170 on the mask's outermost ring and 85 on the ring around
    /// it, so the mask is where the alpha is 128 and above.
    @Test func aFeatheredMaskIsItselfAt128AndAbove() {
        let w = 40, h = 30
        var mask = [UInt8](repeating: 0, count: w * h)
        for y in 8..<20 { for x in 0..<14 { mask[y * w + x] = 255 } }      // a block on the left edge
        mask[25 * w + 30] = 255                                           // and one pixel alone
        let alpha = Pipeline.feathered(mask, width: w, height: h, by: Pipeline.feather)
        #expect(alpha.map { $0 >= 128 ? 255 : 0 } == mask)
        let row = (0..<18).map { alpha[12 * w + $0] }
        #expect(row == [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 170, 85, 0, 0, 0], "the raster's own edge is no edge")
        #expect((5..<10).map { alpha[$0 * w + 5] } == [0, 0, 85, 170, 255])
        #expect(alpha[25 * w + 30] == 170 && alpha[24 * w + 29] == 85 && alpha[23 * w + 30] == 0)
        #expect(Pipeline.feathered(mask, width: w, height: h, by: 0) == mask)
    }
}
