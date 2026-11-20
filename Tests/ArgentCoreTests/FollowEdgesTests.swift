import Foundation
import Metal
import Testing
@testable import ArgentCore

/// A picture for Follow edges: pale sky above a wavy edge, dark textured hair below it with strands reaching up into the sky, and skin
/// at the bottom right. Its frame is the slice's own size, 2048 × 1365, so the guide frame is the frame itself, texel for texel.
enum Edges {
    static let picture = try! MaskSpace(width: 7008, height: 4672)
    static let size = MaskFieldSize(picture: picture)
    static let mframe = try! MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
    static let sky = SIMD3<Float>(0.55, 0.66, 0.88)
    static let hair = SIMD3<Float>(0.030, 0.022, 0.016)
    static let skin = SIMD3<Float>(0.36, 0.22, 0.15)

    /// Where the hair's edge is, `yTop` texels from the top, at column `x`.
    static func edge(_ x: Int) -> Float { 600 + 60 * sin(Float(x) / 90) }

    static func isHair(_ x: Int, _ yTop: Int) -> Bool {
        if Float(yTop) > edge(x) { return true }
        // Strands: 1 or 2 texels wide, 40 texels tall, every 37 columns.
        let strand = x % 37
        return strand < 1 + (x / 37) % 2 && Float(yTop) > edge(x) - 40
    }

    /// The light, row 0 the picture's bottom.
    static let light: [SIMD3<Float>] = {
        let w = size.width, h = size.height
        var out = [SIMD3<Float>](repeating: .zero, count: w * h)
        for yTop in 0..<h {
            let row = (h - 1 - yTop) * w
            for x in 0..<w {
                let grain = 1 + 0.12 * sin(Float(x &* 7 &+ yTop &* 13) * 0.71)
                var value = isHair(x, yTop) ? hair * grain : sky * (0.9 + 0.2 * Float(yTop) / Float(h))
                if x > 1400, yTop > 900 { value = skin * grain }
                out[row + x] = MaskRender.half(value)
            }
        }
        return out
    }()

    static func frame(_ gpu: GPU) throws -> LinearFrame { try MaskRender.frame(gpu, light, width: size.width, picture: picture) }

    /// A point `x`, `yTop` slice texels from the top left.
    static func at(_ x: Float, _ yTop: Float) -> MaskPoint { MaskPoint(x: x * size.texelToPoint.x, y: yTop * size.texelToPoint.y) }

    /// A stroke along the edge, inside the hair, its brush reaching well into the sky.
    static let along: [MaskPoint] = stride(from: Float(300), through: 1100, by: 25).map { at($0, edge(Int($0)) + 30) }

    static func session(_ gpu: GPU, cache: MaskFieldCache, frame: LinearFrame, mask: Mask, follow: Bool = true, erase: Bool = false,
                        flow: Float = 1, radius: Float = 0.03, seeds: (any MaskSeedProvider)? = nil) throws -> BrushStrokeSession {
        try BrushStrokeSession(cache: cache, picture: picture, mask: mask, component: 0,
                               settings: BrushSettings(radius: radius, feather: 0.5, flow: flow, erase: erase, followEdges: follow),
                               refinement: gpu.maskRefiner.session(for: frame, picture: picture, seeds: seeds))
    }

    static func paint(_ session: BrushStrokeSession, _ points: [MaskPoint]) throws -> BrushStroke {
        for point in points { try session.add(point) }
        return try #require(try session.end())
    }

    /// An `r16Float` texture's values, row 0 the texture's.
    static func values(_ texture: MTLTexture) -> [Float] { Brush.bits(texture).map { Float(Float16(bitPattern: $0)) } }
}

@Suite(.serialized) struct FollowEdgesTests {
    /// The colour test the stroke paints with is the CPU's (`FollowEdges.shape`) on the same light, and it keeps the stroke off the sky
    /// while a plain stroke covers it.
    @Test func theColourTestIsTheCPUsAndKeepsOffTheSky() throws {
        let gpu = try GPU()
        let frame = try Edges.frame(gpu)
        let session = try Edges.session(gpu, cache: Brush.cache(gpu), frame: frame, mask: Brush.brushMask([]))
        let stroke = try Edges.paint(session, Edges.along)
        let gpuShape = Edges.values(session.shape)
        let cpuShape = FollowEdges.shape(dabs: BrushDabPath.dabs(of: stroke), profile: BrushDabProfile(radius: 0.03, feather: 0.5),
                                         light: Edges.light, size: Edges.size)
        var worst: Float = 0, sky: (follow: Float, plain: Float, n: Float) = (0, 0, 0)
        let plain = BrushField([BrushStroke(radius: 0.03, feather: 0.5, points: stroke.points)], rounding: true)
        for yTop in 0..<Edges.size.height {
            let row = (Edges.size.height - 1 - yTop) * Edges.size.width
            for x in 0..<Edges.size.width {
                worst = max(worst, abs(gpuShape[row + x] - cpuShape[row + x]))
                // Sky clear of the edge and its strands, inside the brush's reach.
                if Float(yTop) < Edges.edge(x) - 5, Float(yTop) > Edges.edge(x) - 25, x % 37 >= 3, x > 350, x < 1050 {
                    let q = Edges.size.point(column: x, yTop: yTop)
                    sky.follow += gpuShape[row + x]; sky.plain += plain.value(at: SIMD2(q.x, q.y)); sky.n += 1
                }
            }
        }
        MaskRender.report("colour test: GPU against CPU worst \(worst); sky texels \(Int(sky.n)) mean shape \(sky.follow / sky.n), plain \(sky.plain / sky.n);"
                          + " tick GPU \(session.lastTickGPUSeconds * 1000) ms")
        #expect(worst <= 0.002, "\(worst)")
        #expect(sky.n > 1000 && sky.follow / sky.n < 0.01 && sky.plain / sky.n > 0.5)
        #expect(stroke.followEdges && stroke.measured != nil)
    }

    /// What the stroke keeps is its colour-tested shape refined by the guided filter, as `MaskRefiner.reference` makes it on the CPU,
    /// cropped where it is not 0; and it reaches the strands the colour test alone cut square.
    @Test func theMeasuredShapeIsTheCPUsRefinement() throws {
        let gpu = try GPU()
        let frame = try Edges.frame(gpu)
        let session = try Edges.session(gpu, cache: Brush.cache(gpu), frame: frame, mask: Brush.brushMask([]))
        let stroke = try Edges.paint(session, Edges.along)
        let measurement = try #require(session.measurement)
        let measured = try #require(stroke.measured)
        #expect(measured == measurement.measured && measured.raster == measurement.raster.ref)
        #expect(measured.pictureWidth == 7008 && measured.pictureHeight == 4672)
        // The seed: the colour-tested shape in 8 bits, top row first.
        let size = Edges.size, shape = Edges.values(session.shape)
        var plane = [UInt8](repeating: 0, count: size.width * size.height)
        for yTop in 0..<size.height { for x in 0..<size.width { plane[yTop * size.width + x] = FollowEdgesMeasurement.quantized(shape[(size.height - 1 - yTop) * size.width + x]) } }
        let seed = try MaskRaster(width: size.width, height: size.height, plane: plane)
        let parameters = FollowEdgesModel.refinement
        #expect(parameters.radius(seedWidth: size.width, seedHeight: size.height) == 2)
        let coefficients = MaskRefiner.reference(seed: seed, guide: Edges.light, guideWidth: size.width, guideHeight: size.height,
                                                 parameters: parameters).map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), Float($0.w)) }
        var worst = 0, outside = 0
        let raster = measurement.raster
        for yTop in 0..<size.height {
            for x in 0..<size.width {
                let row = size.height - 1 - yTop
                let uv = (SIMD2<Float>(Float(x), Float(row)) + 0.5) / SIMD2(Float(size.width), Float(size.height))
                let expected = Int(FollowEdgesMeasurement.quantized(MaskRefiner.refined(coefficients, width: size.width, height: size.height,
                                                                                        uv: uv, rgb: Edges.light[row * size.width + x])))
                let cx = x - measured.x, cy = yTop - measured.y
                let kept = cx >= 0 && cy >= 0 && cx < raster.width && cy < raster.height ? Int(raster.plane[cy * raster.width + cx]) : 0
                if kept == 0, expected != 0, !(cx >= 0 && cy >= 0 && cx < raster.width && cy < raster.height) { outside += 1 }
                worst = max(worst, abs(kept - expected))
            }
        }
        MaskRender.report("refinement: GPU against CPU worst \(worst) of 255, outside the crop \(outside); crop \(raster.width) x \(raster.height)"
                          + " at \(measured.x), \(measured.y); build \(measurement.build); measure \(session.measureSeconds * 1000) ms")
        #expect(worst <= 2, "\(worst)")
        #expect(outside == 0)
        // Strands the colour test kept square at the slice's texels are no less covered once refined, and the sky beside them stays out.
        let strand = (x: 37 * 12, yTop: Int(Edges.edge(37 * 12) - 8)), clear = (x: 37 * 12 + 18, yTop: Int(Edges.edge(37 * 12 + 18) - 25))
        func kept(_ p: (x: Int, yTop: Int)) -> Int { Int(raster.plane[(p.yTop - measured.y) * raster.width + p.x - measured.x]) }
        #expect(kept(strand) > 128 && kept(clear) < 8, "strand \(kept(strand)), sky \(kept(clear))")
    }

    /// A Follow edges stroke's canvas as the session leaves it is a replay of the recipe's strokes from nothing, bit for bit, with plain
    /// strokes before and after it and an erasing Follow edges stroke at Flow 60 over it.
    @Test func replayEqualsIncremental() throws {
        let gpu = try GPU()
        let frame = try Edges.frame(gpu)
        let cache = Brush.cache(gpu)
        let first = try Brush.stroke(Brush.path(30, seed: 5, start: Edges.at(500, 900)), radius: 0.02, flow: 0.7)
        var held = Refine.Seeds([])
        func remember(_ session: BrushStrokeSession) { if let m = session.measurement { held.rasters[m.raster.identity] = m.raster } }
        let follower = try Edges.session(gpu, cache: cache, frame: frame, mask: Brush.brushMask([first]))
        let followed = try Edges.paint(follower, Edges.along)
        remember(follower)
        // Laid from nothing, the plain stroke by the brush library's kernel and the measured one from its raster: the session's canvas.
        let two = try Brush.cache(gpu).canvas(for: BrushCanvasKey(size: Edges.size, version: MaskSet.currentVersion, strokes: [first, followed]),
                                              shapes: held)
        #expect(Brush.bits(two.texture) == Brush.bits(follower.live))
        // Again, from the cache holding the first two, so the base is a kept canvas: the measured stroke is not laid again.
        let eraser = try Edges.session(gpu, cache: cache, frame: frame, mask: Brush.brushMask([first, followed]), erase: true, flow: 0.6)
        let erased = try Edges.paint(eraser, stride(from: Float(600), through: 900, by: 30).map { Edges.at($0, Edges.edge(Int($0)) + 10) })
        remember(eraser)
        let shapes = [try #require(followed.measured).raster, try #require(erased.measured).raster]
        let after = try BrushStrokeSession(cache: cache, picture: Edges.picture, mask: Brush.brushMask([first, followed, erased]), component: 0,
                                           settings: BrushSettings(radius: 0.015, feather: 0.3, flow: 0.8),
                                           refinement: gpu.maskRefiner.session(for: frame, picture: Edges.picture))
        let last = try Edges.paint(after, Brush.path(25, seed: 8, start: Edges.at(800, 700)))
        // The first stroke painted again on another cache measures the same pixels: the measurement is deterministic.
        let again = try Edges.session(gpu, cache: Brush.cache(gpu), frame: frame, mask: Brush.brushMask([first]))
        #expect(try Edges.paint(again, Edges.along) == followed)
        #expect(held.rasters.count == 2 && shapes.allSatisfy { held.rasters[$0.id] != nil })
        for (strokes, live) in [([first, followed, erased], eraser.live), ([first, followed, erased, last], after.live)] {
            let fresh = try Brush.cache(gpu).canvas(for: BrushCanvasKey(size: Edges.size, version: MaskSet.currentVersion, strokes: strokes),
                                                    shapes: held)
            #expect(Brush.bits(fresh.texture) == Brush.bits(live), "\(strokes.count) strokes")
        }
        // And the CPU's reference (`BrushField`) agrees with the canvas at its texels, to the half float's rounding.
        let field = try BrushField([first, followed, erased, last], shapes: held)
        let canvas = Edges.values(after.live)
        var worst: Float = 0
        for yTop in stride(from: 400, to: 1000, by: 3) {
            for x in stride(from: 250, to: 1200, by: 3) {
                let q = Edges.size.point(column: x, yTop: yTop)
                worst = max(worst, abs(field.value(at: SIMD2(q.x, q.y)) - canvas[(Edges.size.height - 1 - yTop) * Edges.size.width + x]))
            }
        }
        #expect(worst <= 0.002, "\(worst)")
    }

    /// Through the masks' bake and the film: a mask of a Follow edges brush reads its shape from the seed store, the same slice whatever the
    /// stock or the sliders (it reads no decode), and refuses when the store has lost the shape, rather than print it as covering nothing.
    @Test func aRenderReadsTheStoredShapeAndALostOneRefuses() throws {
        let gpu = try GPU()
        let frame = try Edges.frame(gpu)
        let session = try Edges.session(gpu, cache: Brush.cache(gpu), frame: frame, mask: Brush.brushMask([]))
        let stroke = try Edges.paint(session, Edges.along)
        let raster = try #require(session.measurement).raster
        let mask = Mask(components: [MaskComponent(shape: .brush(BrushPaint(frame: Edges.mframe, strokes: [stroke])))],
                        adjustments: try ManualAdjustments(exposureEV: 1))
        #expect(mask.readsMeasuredStroke && !mask.readsSmartSelection)
        let set = try MaskSet(masks: [mask])
        #expect(set.rasters == [raster.ref])
        let manual = try MaskRender.manual(masks: [mask])
        #expect(MaskSeeds.needs(manual).rasters == [raster.ref])
        var slices: [[Float]] = []
        let baked = try LightCompilerBaselineTests.bakedStocks.prefix(1).map { try Stock.load(from: $0) }
        let stocks = [LightCompilerBaselineTests.toyStock()] + baked
        for (stock, panel) in [(stocks[0], ManualAdjustments.identity), (stocks[stocks.count - 1], try ManualAdjustments(contrast: 40, whites: -20))] {
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            let settings = DevelopSettings(manual: try MaskRender.manual(panel, masks: [Mask(id: mask.id, components: mask.components, amount: panel == .identity ? 1 : 0.4, adjustments: mask.adjustments)]))
            _ = try renderer.render(try Edges.frame(gpu), settings: settings, seeds: MaskSeeds([raster]))
            let scene = try Refine.scene(renderer, try Edges.frame(gpu), settings)
            slices.append(try #require(scene.masks).coverage.values(slot: 0))
        }
        #expect(slices[0] == slices[1])
        // A fresh GPU, whose cache holds no canvas, with a store that lacks the shape.
        let other = try GPU()
        other.maskRefiner.seeds = Refine.Seeds([])
        let renderer = try FilmRenderer(gpu: other, stock: LightCompilerBaselineTests.toyStock())
        #expect(throws: MaskRefinerError.seedUnavailable(raster.ref.id)) {
            try renderer.render(try Edges.frame(other), settings: DevelopSettings(manual: manual))
        }
        // With it, the same slice as the stroke's own canvas made.
        other.maskRefiner.seeds = Refine.Seeds([raster])
        let scene = try Refine.scene(renderer, try Edges.frame(other), DevelopSettings(manual: manual))
        #expect(try #require(scene.masks).coverage.values(slot: 0) == slices[0])
    }

    /// A Follow edges stroke reads the frame's decode, so with none it refuses at the press; a plain one does not need it.
    @Test func followEdgesNeedsTheDecode() throws {
        let gpu = try GPU()
        #expect(throws: MaskError.self) {
            try BrushStrokeSession(cache: Brush.cache(gpu), picture: Edges.picture, mask: Brush.brushMask([]), component: 0,
                                   settings: BrushSettings(radius: 0.02, followEdges: true))
        }
        _ = try BrushStrokeSession(cache: Brush.cache(gpu), picture: Edges.picture, mask: Brush.brushMask([]), component: 0,
                                   settings: BrushSettings(radius: 0.02))
    }

    /// A mask turned off is painted like any other. A plain stroke into a brush that holds a Follow edges stroke lays that brush's
    /// canvas from the stroke's stored shape when nothing keeps it (a relaunch, a trim), so the press needs the refinement's seeds
    /// though no render reads the mask; without them it refuses.
    @Test func aMaskTurnedOffStillPaintsBesideItsFollowEdgesStrokes() throws {
        let gpu = try GPU()
        let frame = try Edges.frame(gpu)
        let session = try Edges.session(gpu, cache: Brush.cache(gpu), frame: frame, mask: Brush.brushMask([]))
        let stroke = try Edges.paint(session, Edges.along)
        let held = Refine.Seeds([try #require(session.measurement).raster])
        var off = Brush.brushMask([stroke])
        off.isEnabled = false
        let plain = BrushSettings(radius: 0.02)
        #expect(!off.readsMeasuredStroke, "no render reads a mask turned off")
        #expect(BrushStrokeSession.needsRefinement(mask: off, settings: plain))
        #expect(!BrushStrokeSession.needsRefinement(mask: Brush.brushMask([]), settings: plain))
        #expect(BrushStrokeSession.needsRefinement(mask: Brush.brushMask([]), settings: BrushSettings(radius: 0.02, followEdges: true)))
        let smart = Mask(isEnabled: false, components: [MaskComponent(shape: .smart(SmartSelection(kind: .sky))),
                                                        MaskComponent(operation: .subtract, shape: .brush(BrushPaint(frame: Edges.mframe)))])
        #expect(BrushStrokeSession.needsRefinement(mask: smart, settings: plain))
        // On a cache that keeps no canvas of it: with the seeds the canvas is laid, and is the one the stroke left.
        let next = try BrushStrokeSession(cache: Brush.cache(gpu), picture: Edges.picture, mask: off, component: 0, settings: plain,
                                          refinement: gpu.maskRefiner.session(for: frame, picture: Edges.picture, seeds: held))
        #expect(Brush.bits(next.live) == Brush.bits(session.live))
        // With no refinement, as the press had none while it asked whether the mask was on, the stroke is refused.
        #expect(throws: MaskRefinerError.noSeedStore) {
            try BrushStrokeSession(cache: Brush.cache(gpu), picture: Edges.picture, mask: off, component: 0, settings: plain)
        }
    }

    /// A kept shape on a slice of another size, as a stroke copied or reapplied onto a frame of another shape has (`same == 0` in
    /// `brush_lay_measured`): each texel reads the raster's texel of the slice it was measured over that its point lies in, as `BrushField` reads
    /// it on the CPU, in the same place of the picture, and nothing outside what `FollowEdgesReplay.region` says it reaches.
    @Test(arguments: [(6000, 3376), (4672, 7008), (7008, 4000)])
    func aKeptShapeReadsOnASliceOfAnotherSize(width: Int, height: Int) throws {
        let gpu = try GPU()
        let frame = try Edges.frame(gpu)
        let session = try Edges.session(gpu, cache: Brush.cache(gpu), frame: frame, mask: Brush.brushMask([]))
        let stroke = try Edges.paint(session, Edges.along)
        let measurement = try #require(session.measurement), measured = try #require(stroke.measured), raster = measurement.raster
        let held = Refine.Seeds([raster])
        let size = MaskFieldSize(picture: try MaskSpace(width: width, height: height))
        #expect(size != Edges.size && measured.field == Edges.size)
        let recorded = Edges.size.texelToPoint, here = size.texelToPoint
        let canvas = try Brush.cache(gpu).canvas(for: BrushCanvasKey(size: size, version: MaskSet.currentVersion, strokes: [stroke]), shapes: held)
        let values = Edges.values(canvas.texture)
        let field = try BrushField([stroke], shapes: held)
        let region = try #require(FollowEdgesReplay.region(of: measured, size: size))
        var worst: Float = 0, worstField: Float = 0, covered = 0, outsideRegion = 0
        var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        for yTop in 0..<size.height {
            let row = (size.height - 1 - yTop) * size.width
            for x in 0..<size.width {
                let q = (SIMD2<Float>(Float(x), Float(yTop)) + 0.5) * here
                let cx = Int((q.x / recorded.x).rounded(.down)) - measured.x, cy = Int((q.y / recorded.y).rounded(.down)) - measured.y
                let inside = cx >= 0 && cy >= 0 && cx < raster.width && cy < raster.height
                let expected = inside ? BrushCompositing.half(Float(raster.plane[cy * raster.width + cx]) / 255) : 0
                let value = values[row + x]
                worst = max(worst, abs(value - expected))
                worstField = max(worstField, abs(value - field.value(at: q)))
                guard value > 0 else { continue }
                covered += 1
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, yTop); y1 = max(y1, yTop)
                if x < region.x || yTop < region.y || x >= region.x + region.width || yTop >= region.y + region.height { outsideRegion += 1 }
            }
        }
        MaskRender.report("kept shape on \(size.width) x \(size.height): worst \(worst) (BrushField \(worstField)), \(covered) texels; region \(region) against \(x0)...\(x1), \(y0)...\(y1)")
        #expect(worst <= 0.001, "\(worst)")
        #expect(worstField <= 0.002, "\(worstField)")
        #expect(covered > 1000 && outsideRegion == 0, "\(covered), \(outsideRegion) outside")
        // The region is the raster's rectangle at this slice's texels: at most its one-texel margin past what the raster covers, rounding aside.
        let scale = recorded / here
        #expect(region.width <= Int((Float(raster.width) * scale.x).rounded(.up)) + 3 && region.height <= Int((Float(raster.height) * scale.y).rounded(.up)) + 3,
                "\(region)")
    }

    /// The slice it was measured over reads it texel for texel, the path a Copy to a frame of the same shape keeps (`same == 1`), and the region
    /// is then the raster's rectangle exactly.
    @Test func aKeptShapeOnItsOwnSliceSizeIsLaidTexelForTexel() throws {
        let gpu = try GPU()
        let frame = try Edges.frame(gpu)
        let session = try Edges.session(gpu, cache: Brush.cache(gpu), frame: frame, mask: Brush.brushMask([]))
        let stroke = try Edges.paint(session, Edges.along)
        let measured = try #require(stroke.measured), held = Refine.Seeds([try #require(session.measurement).raster])
        let copy = try Brush.cache(gpu).canvas(for: BrushCanvasKey(size: Edges.size, version: MaskSet.currentVersion, strokes: [stroke]), shapes: held)
        #expect(Brush.bits(copy.texture) == Brush.bits(session.live))
        #expect(FollowEdgesReplay.region(of: measured, size: Edges.size)
                == BrushRegion(x: measured.x, y: measured.y, width: measured.raster.width, height: measured.raster.height))
    }
}

/// The record: what a measured stroke writes, reads back and needs.
@Suite struct MeasuredStrokeRecordTests {
    static func measured() throws -> (MaskRaster, MeasuredStroke) {
        let raster = try MaskRaster(width: 40, height: 24, plane: (0..<960).map { UInt8($0 % 251) })
        return (raster, try MeasuredStroke(raster: raster.ref, x: 300, y: 200, pictureWidth: 7008, pictureHeight: 4672))
    }

    static func set(_ strokes: [BrushStroke]) throws -> MaskSet {
        try MaskSet(masks: [Mask(id: BrushBeforeFollowEdgesTests.id(7), components: [MaskComponent(shape: .brush(BrushPaint(frame: Edges.mframe, strokes: strokes)))])])
    }

    static func json(_ set: MaskSet) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(set), as: UTF8.self)
    }

    @Test func aMeasuredStrokeRoundTripsAtSchemaThree() throws {
        let (raster, measured) = try Self.measured()
        let points = try PackedPoints.pack([MaskPoint(x: 0.2, y: 0.2), MaskPoint(x: 0.25, y: 0.21)])
        let stroke = BrushStroke(followEdges: true, radius: 0.02, points: points, measured: measured)
        let plain = BrushStroke(radius: 0.02, points: points)
        let set = try Self.set([plain, stroke])
        let text = try Self.json(set)
        #expect(text.contains(#""schema":3"#) && text.contains(#""measured":"#))
        let read = try JSONDecoder().decode(MaskSet.self, from: Data(text.utf8))
        #expect(read == set && read.digest == set.digest && read.masks == set.masks)
        #expect(MaskSet.schema >= 3 && MaskSet.schema(of: set.masks) == 3 && set.rasters == [raster.ref])
        // Plain strokes write what they always did: schema 1, no "measured".
        let plainText = try Self.json(try Self.set([plain]))
        #expect(plainText.contains(#""schema":1"#) && !plainText.contains("measured"))
        // A measured stroke in a record that says schema 2 is what an older build would have dropped.
        #expect(throws: MaskError.self) { try JSONDecoder().decode(MaskSet.self, from: Data(text.replacingOccurrences(of: #""schema":3"#, with: #""schema":2"#).utf8)) }
        // The digest and the coverage identity move with every field of it.
        var moved = stroke
        moved.measured = try MeasuredStroke(raster: raster.ref, x: 301, y: 200, pictureWidth: 7008, pictureHeight: 4672)
        let picture = Edges.picture
        #expect(try Self.set([plain, moved]).digest != set.digest)
        #expect(try MaskSlots(masks: Self.set([plain, moved]), picture: picture).identity != MaskSlots(masks: set, picture: picture).identity)
        // An unmeasured Follow edges stroke is a different stroke again.
        var unmeasured = stroke
        unmeasured.measured = nil
        #expect(try Self.set([plain, unmeasured]).digest != set.digest)
        #expect(MaskSet.schema(of: try Self.set([plain, unmeasured]).masks) == 1)
    }

    /// Copy and Reapply (`forAnotherPicture`) keep a Follow edges stroke as painted, its measured shape and raster named, whichever ids the copy
    /// takes, while a smart selection's seed stays behind, since that measured the old picture.
    @Test func copyAndReapplyKeepAMeasuredStrokeAndLeaveASmartSeedBehind() throws {
        let (raster, measured) = try Self.measured()
        let points = try PackedPoints.pack([MaskPoint(x: 0.2, y: 0.2), MaskPoint(x: 0.25, y: 0.21)])
        let stroke = BrushStroke(followEdges: true, radius: 0.02, feather: 0.4, flow: 0.7, points: points, measured: measured)
        let seed = try MaskRaster(width: 40, height: 24, plane: (0..<960).map { UInt8($0 % 7) })
        let selection = SmartSelection(kind: .sky, raster: seed.ref, frame: Edges.mframe)
        let mask = Mask(components: [MaskComponent(shape: .smart(selection)),
                                     MaskComponent(operation: .subtract, shape: .brush(BrushPaint(frame: Edges.mframe, strokes: [stroke])))])
        let set = try MaskSet(masks: [mask])
        #expect(set.rasters == [seed.ref, raster.ref])
        for fresh in [false, true] {
            let copy = try set.forAnotherPicture(freshIDs: fresh)
            #expect(copy.rasters == [raster.ref], "only the stroke's shape comes across")
            #expect((copy.masks[0].id == mask.id) == !fresh)
            guard case .brush(let paint) = copy.masks[0].components[1].shape else { Issue.record("not a brush"); return }
            #expect(paint.strokes == [stroke] && paint.frame == Edges.mframe && copy.masks[0].components[1].operation == .subtract)
            #expect(copy.masks[0].pendingSmart == [.sky])
            // Saved and read back at schema 3, with the shape it names.
            let read = try JSONDecoder().decode(MaskSet.self, from: Data(try Self.json(copy).utf8))
            #expect(read == copy && read.rasters == [raster.ref] && MaskSet.schema(of: copy.masks) == 3)
        }
    }

    @Test func aMeasuredShapeIsAFollowEdgesStrokesAndLiesInItsSlice() throws {
        let (raster, measured) = try Self.measured()
        let points = try PackedPoints.pack([MaskPoint(x: 0.2, y: 0.2)])
        #expect(throws: MaskError.self) { try Self.set([BrushStroke(radius: 0.02, points: points, measured: measured)]) }
        #expect(throws: MaskError.self) { try MeasuredStroke(raster: raster.ref, x: 2040, y: 0, pictureWidth: 7008, pictureHeight: 4672) }
        #expect(throws: MaskError.self) { try MeasuredStroke(raster: raster.ref, x: 0, y: 1350, pictureWidth: 7008, pictureHeight: 4672) }
        #expect(throws: MaskError.self) { try MeasuredStroke(raster: raster.ref, x: -1, y: 0, pictureWidth: 7008, pictureHeight: 4672) }
        _ = try MeasuredStroke(raster: raster.ref, x: 2008, y: 1341, pictureWidth: 7008, pictureHeight: 4672)
        // Read with the same checks: a crop outside its slice fails the record.
        let text = try Self.json(try Self.set([BrushStroke(followEdges: true, radius: 0.02, points: points, measured: measured)]))
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MaskSet.self, from: Data(text.replacingOccurrences(of: #""x":300"#, with: #""x":2030"#).utf8))
        }
        // The largest numbers a record can hold are refused like any other, not added to the raster's sides until they overflow.
        #expect(throws: MaskError.self) { try MeasuredStroke(raster: raster.ref, x: .max, y: 0, pictureWidth: 7008, pictureHeight: 4672) }
        #expect(throws: MaskError.self) { try MeasuredStroke(raster: raster.ref, x: 0, y: .max, pictureWidth: 7008, pictureHeight: 4672) }
        #expect(throws: MaskError.self) { try MeasuredStroke(raster: raster.ref, x: 0, y: 0, pictureWidth: 16, pictureHeight: .max) }
        for field in ["x", "y"] {
            let huge = text.replacingOccurrences(of: "\"\(field)\":\(field == "x" ? 300 : 200)", with: "\"\(field)\":\(Int.max)")
            #expect(huge != text)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(MaskSet.self, from: Data(huge.utf8)) }
        }
    }
}
