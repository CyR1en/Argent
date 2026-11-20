import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Shared fixtures: strokes from a seeded generator, so every run paints the same.
enum Brush {
    static let picture = try! MaskSpace(width: 7008, height: 4672)
    static let frame = try! MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .apple, lensCorrection: true)

    /// xorshift64*, so a "random" path is the same on every run.
    struct Random {
        var state: UInt64
        mutating func next() -> Float {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return Float((state &* 2_685_821_657_736_338_717) >> 40) / Float(1 << 24)
        }
    }

    /// A hand-like path of `count` pointer points: a slowly turning heading, a speed that varies, an occasional sharp turn.
    static func path(_ count: Int, seed: UInt64, start: MaskPoint = MaskPoint(x: 0.3, y: 0.3), step: Float = 0.004) -> [MaskPoint] {
        var random = Random(state: seed | 1), heading = random.next() * 6.283, point = start
        var out: [MaskPoint] = []
        for i in 0..<count {
            out.append(point)
            heading += (random.next() - 0.5) * 0.5 + (i % 37 == 36 ? 2.6 : 0)
            let speed = step * (0.2 + 1.6 * random.next())
            point = MaskPoint(x: min(max(point.x + cos(heading) * speed, 0.02), 0.98), y: min(max(point.y + sin(heading) * speed, 0.02), 0.64))
        }
        return out
    }

    static func stroke(_ points: [MaskPoint], radius: Float, feather: Float = 0.5, flow: Float = 1, erase: Bool = false) throws -> BrushStroke {
        var sampler = try StrokeSampler(settings: BrushSettings(radius: radius, feather: feather, flow: flow, erase: erase))
        for point in points { _ = sampler.add(point) }
        return try Brush.end(&sampler).stroke
    }

    /// `sampler.end()`, which a stroke with a point always has.
    static func end(_ sampler: inout StrokeSampler) throws -> (dabs: [BrushDab], stroke: BrushStroke) {
        guard let ended = sampler.end() else { throw MaskError.invalid("a stroke with no point") }
        return ended
    }

    static func brushMask(_ strokes: [BrushStroke], operation: MaskOperation = .add, invert: Bool = false, id: UUID = UUID()) -> Mask {
        Mask(id: id, components: [MaskComponent(operation: operation, shape: .brush(BrushPaint(frame: frame, strokes: strokes)), invert: invert)])
    }

    static func cache(_ gpu: GPU) -> MaskFieldCache { MaskFieldCache(device: gpu.device, queue: gpu.queue) }

    /// A texture's half floats as bits, row 0 first: what "bit for bit" compares.
    static func bits(_ texture: MTLTexture) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: texture.width * texture.height)
        out.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 2, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return out
    }

    static func dabBits(_ dabs: [BrushDab]) -> [UInt64] { dabs.map { UInt64($0.x.bitPattern) << 32 | UInt64($0.y.bitPattern) } }
}

// MARK: - The sampler

@Suite struct StrokeSamplerTests {
    /// A straight stroke lays a dab at its start, one every tenth of the diameter, and one at its end.
    @Test func dabsFallEveryTenthOfTheDiameter() throws {
        for radius: Float in [0.003, 0.02, 0.15] {
            let a = StrokeSampler.quantized(MaskPoint(x: 0.1, y: 0.2)), b = StrokeSampler.quantized(MaskPoint(x: 0.7, y: 0.2))
            let dabs = BrushDabPath.dabs(of: try Brush.stroke([a, b], radius: radius))
            let spacing = 0.2 * Double(radius)
            #expect(dabs.first == BrushDab(x: a.x, y: a.y) && dabs.last == BrushDab(x: b.x, y: b.y))
            let gaps = zip(dabs.dropFirst(), dabs).map { Double($0.x - $1.x) }
            for gap in gaps.dropLast() { #expect(abs(gap - spacing) < 2e-6, "radius \(radius): \(gap) against \(spacing)") }
            #expect(gaps.last! > 0 && gaps.last! <= spacing + 2e-6)
            #expect(dabs.allSatisfy { $0.y == a.y })
        }
        // The smallest brush is held to half a canvas texel.
        let tiny = BrushDabPath(radius: MaskSpace.brushRadiusRange.lowerBound)
        #expect(tiny.spacing == 0.5 / 2048)
    }

    /// Each segment's dabs lie within a quarter of its chord's length of the chord, on hairpins and corners too, and the curve passes
    /// through every kept point.
    @Test func smoothingStaysWithinTheChordBound() throws {
        var worst: Double = 0
        for seed in UInt64(1)...40 {
            var random = Brush.Random(state: seed)
            var points: [MaskPoint] = []
            var p = MaskPoint(x: 0.5, y: 0.3)
            for _ in 0..<60 {
                points.append(StrokeSampler.quantized(p))
                // Steps of very different lengths, and turns up to a full reversal, which unbounded Catmull-Rom would loop on.
                let angle = random.next() * 6.283, length = 0.0005 + 0.03 * random.next() * random.next()
                p = MaskPoint(x: min(max(p.x + cos(angle) * length, 0.05), 0.95), y: min(max(p.y + sin(angle) * length, 0.05), 0.6))
            }
            var path = BrushDabPath(radius: 0.004)
            var segments: [[BrushDab]] = []
            for point in points {
                let before = path.points.count
                let dabs = path.add(point)
                // A point that is kept makes the segment before the one it ends certain; the end dab lies on the last point.
                if path.points.count > before, path.points.count >= 3 { segments.append(dabs) }
            }
            segments.append(path.end())
            let kept = path.points
            #expect(segments.count == kept.count - 1)
            for (i, dabs) in segments.enumerated() {
                let a = kept[i], b = kept[i + 1], d = b - a, length = (d * d).sum().squareRoot()
                for dab in dabs {
                    let q = SIMD2<Double>(Double(dab.x), Double(dab.y)) - a
                    let t = min(max((q * d).sum() / (length * length), 0), 1)
                    let off = q - d * t, distance = (off * off).sum().squareRoot()
                    worst = max(worst, distance / length)
                    #expect(distance <= 0.25 * length + 1e-6, "seed \(seed) segment \(i)")
                }
            }
        }
        MaskRender.report("brush chord bound: worst distance from the chord \(String(format: "%.4f", worst)) of its length (bound 0.25)")
        #expect(worst > 0.01, "the curve does bend")
    }

    /// The sampler smooths: a right-angled corner is rounded, so the dabs near the corner leave the polyline.
    @Test func aCornerIsRounded() throws {
        let points = (0...10).map { MaskPoint(x: 0.2 + 0.01 * Float($0), y: 0.3) } + (1...10).map { MaskPoint(x: 0.3, y: 0.3 + 0.01 * Float($0)) }
        let dabs = BrushDabPath.dabs(of: try Brush.stroke(points, radius: 0.01))
        let off = dabs.map { min(abs($0.y - 0.3), abs($0.x - 0.3)) }.max()!
        #expect(off > 0.0005 && off < 0.0025)
    }

    /// Shift-drag keeps nothing until the pointer is 0.005 long sides away, then holds to the axis it went further along.
    @Test func shiftDragHoldsToAnAxis() throws {
        var sampler = try StrokeSampler(settings: BrushSettings(radius: 0.01), constraint: .axis)
        _ = sampler.add(MaskPoint(x: 0.4, y: 0.4))
        _ = sampler.add(MaskPoint(x: 0.401, y: 0.4021))
        #expect(sampler.kept.count == 1 && sampler.pending.isEmpty, "inside the decision distance nothing is kept")
        for i in 1...30 { _ = sampler.add(MaskPoint(x: 0.4 + 0.003 * Float(i), y: 0.4 + (i % 2 == 0 ? 0.002 : -0.0015))) }
        let stroke = try Brush.end(&sampler).stroke
        #expect(stroke.points.points.allSatisfy { $0.y == StrokeSampler.quantized(MaskPoint(x: 0, y: 0.4)).y })
        #expect(BrushDabPath.dabs(of: stroke).allSatisfy { $0.y == stroke.points.points[0].y })

        var vertical = try StrokeSampler(settings: BrushSettings(radius: 0.01), constraint: .axis)
        _ = vertical.add(MaskPoint(x: 0.4, y: 0.4))
        for i in 1...10 { _ = vertical.add(MaskPoint(x: 0.4 + 0.001 * Float(i % 3), y: 0.4 + 0.004 * Float(i))) }
        #expect(try Brush.end(&vertical).stroke.points.points.allSatisfy { $0.x == StrokeSampler.quantized(MaskPoint(x: 0.4, y: 0)).x })
    }

    /// Shift-click is a straight stroke from a point to the pointer, its end following the pointer until release; a long line is
    /// reached through evenly spaced points on it, so its dabs keep their spacing.
    @Test func shiftClickDrawsAStraightLine() throws {
        let from = MaskPoint(x: 0.2, y: 0.5)
        var sampler = try StrokeSampler(settings: BrushSettings(radius: 0.003), constraint: .line(from: from))
        _ = sampler.add(MaskPoint(x: 0.6, y: 0.2))
        _ = sampler.add(MaskPoint(x: 0.61, y: 0.25))
        let (dabs, stroke) = try Brush.end(&sampler)
        let points = stroke.points.points, a = points[0], b = points[points.count - 1]
        #expect(a == StrokeSampler.quantized(from) && b == StrokeSampler.quantized(MaskPoint(x: 0.61, y: 0.25)))
        let reach = BrushModel.reachShare * Double(BrushModel.maximumDabsPerSegment) * 0.0006
        #expect(points.count == 1 + Int((Double(hypot(b.x - a.x, b.y - a.y)) / reach).rounded(.up)), "in steps of at most 32 spacings")
        let all = BrushDabPath.dabs(of: stroke)
        #expect(dabs.count == all.count - 1, "the line's start dab was laid at the press")
        let length = hypot(b.x - a.x, b.y - a.y)
        for dab in all + points.map({ BrushDab(x: $0.x, y: $0.y) }) {
            let cross = (b.x - a.x) * (dab.y - a.y) - (b.y - a.y) * (dab.x - a.x)
            #expect(abs(cross) / length <= 1 / 32_768, "on the line to the stored grid")
        }
        let gaps = zip(all.dropFirst(), all).map { Double(hypot($0.x - $1.x, $0.y - $1.y)) }
        #expect(gaps.dropLast().allSatisfy { abs($0 - 0.0006) < 2e-6 }, "a tenth of the diameter all along")
        #expect(throws: MaskError.self) { try StrokeSampler(settings: BrushSettings(radius: 0.01), constraint: .line(from: from), pointBudget: 1) }
    }

    /// Erasing changes what a stroke does, never where its dabs fall.
    @Test func eraseIsAFlagOnTheSameDabs() throws {
        let points = Brush.path(80, seed: 7)
        let paint = try Brush.stroke(points, radius: 0.01), erase = try Brush.stroke(points, radius: 0.01, erase: true)
        #expect(erase.erase && !paint.erase && erase.points == paint.points)
        #expect(BrushDabPath.dabs(of: erase) == BrushDabPath.dabs(of: paint))
    }

    /// What a stroke laid live is what its stored points replay: every tick's certain dabs plus the tail it showed equal the replay of
    /// the stroke as it stood, and the whole equals the replay of the stroke kept, bit for bit, through the recipe's JSON.
    @Test func liveDabsAreTheReplayedDabs() throws {
        for (seed, radius) in [(UInt64(3), Float(0.002)), (11, 0.02), (23, 0.12)] {
            var sampler = try StrokeSampler(settings: BrushSettings(radius: radius, feather: 0.3, flow: 0.6))
            var laid: [BrushDab] = []
            for (i, point) in Brush.path(150, seed: seed).enumerated() {
                laid += sampler.add(point)
                if i % 17 == 5 {
                    let now = try #require(sampler.stroke)
                    #expect(Brush.dabBits(laid + sampler.tail) == Brush.dabBits(BrushDabPath.dabs(of: now)), "seed \(seed) at \(i)")
                }
            }
            let (last, stroke) = try Brush.end(&sampler)
            laid += last
            let set = try MaskSet(masks: [Brush.brushMask([stroke])])
            let decoded = try JSONDecoder().decode(MaskSet.self, from: try JSONEncoder().encode(set))
            guard case .brush(let paint) = decoded.masks[0].components[0].shape else { Issue.record("not a brush"); return }
            #expect(paint.strokes[0] == stroke)
            #expect(Brush.dabBits(laid) == Brush.dabBits(BrushDabPath.dabs(of: paint.strokes[0])))
            #expect(Brush.dabBits(BrushDabPath.dabs(of: stroke)) == Brush.dabBits(BrushDabPath.dabs(of: stroke)), "runs agree")
        }
    }

    /// Dab placement is a function of the stored points alone: these values were recorded when the rule was written, so a change of
    /// the rule fails here and needs a new masks compiler.
    @Test func dabPlacementIsBitExactAcrossRuns() throws {
        let stroke = try Brush.stroke(Brush.path(40, seed: 99), radius: 0.01, feather: 0.5, flow: 0.5)
        let dabs = BrushDabPath.dabs(of: stroke)
        var hash: UInt64 = 0xcbf29ce484222325
        for bits in Brush.dabBits(dabs) { hash = (hash ^ bits) &* 0x100000001b3 }
        MaskRender.report("brush dab golden: \(dabs.count) dabs, FNV \(String(hash, radix: 16))")
        #expect(dabs.count == 92)
        #expect(String(hash, radix: 16) == "2dd24683217abf42")
    }

    /// The pointer's path as fractions of the picture, met at two picture sizes and two zooms, gives the same points and so the same
    /// dabs: dabs are in long sides, and nothing in the sampler knows a pixel.
    @Test func theSameStrokeAtAnyPictureSizeGivesTheSameDabs() throws {
        let fractions = Brush.path(60, seed: 5).map { CGPoint(x: Double($0.x), y: Double($0.y) / (2.0 / 3.0)) }
        func dabs(width: Double, height: Double, zoom: Double) throws -> [BrushDab] {
            // As `FrameGeometry.maskPoint` converts: area points over the drawn picture's long side.
            let drawn = CGSize(width: width * zoom, height: height * zoom), long = max(drawn.width, drawn.height)
            let points = fractions.map { MaskPoint(x: Float($0.x * drawn.width / long), y: Float($0.y * drawn.height / long)) }
            return BrushDabPath.dabs(of: try Brush.stroke(points, radius: 0.01))
        }
        let reference = try dabs(width: 7008, height: 4672, zoom: 1)
        #expect(try dabs(width: 3504, height: 2336, zoom: 0.25) == reference)
        #expect(try dabs(width: 960, height: 640, zoom: 3.7) == reference)
    }

    /// The stored points bound the dabs: at most 65 a segment, met only by a stroke from elsewhere, since a fling across the frame
    /// is reached through kept points and keeps its tenth-of-a-diameter spacing.
    @Test func theDabCountIsBounded() throws {
        let fling = try Brush.stroke([MaskPoint(x: 0, y: 0.1), MaskPoint(x: 1, y: 0.6), MaskPoint(x: 0.1, y: 0.6)], radius: 0.001)
        let dabs = BrushDabPath.dabs(of: fling)
        #expect(dabs.count <= 2 + fling.points.count * (BrushModel.maximumDabsPerSegment + 1))
        let gaps = zip(dabs.dropFirst(), dabs).map { hypot($0.x - $1.x, $0.y - $1.y) }
        #expect(gaps.dropLast().allSatisfy { $0 <= Float(BrushModel.minimumSpacing) * 1.01 })
        // Stored elsewhere, two points a frame apart: the cap spaces the dabs, and bounds them.
        let crafted = BrushStroke(radius: 0.001, points: try PackedPoints.pack([MaskPoint(x: -1, y: -1), MaskPoint(x: 2, y: 2)]))
        #expect(BrushDabPath.dabs(of: crafted).count <= 2 + BrushModel.maximumDabsPerSegment)
        for seed in UInt64(1)...10 {
            let stroke = try Brush.stroke(Brush.path(200, seed: seed, step: 0.05), radius: 0.001)
            #expect(BrushDabPath.dabs(of: stroke).count <= 2 + stroke.points.count * (BrushModel.maximumDabsPerSegment + 1))
        }
        // An ordinary stroke keeps its spacing.
        let ordinary = BrushDabPath.dabs(of: try Brush.stroke(Brush.path(100, seed: 4), radius: 0.01))
        #expect(zip(ordinary.dropFirst(), ordinary).dropLast().allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) <= 0.002 + 1e-6 })
    }

    /// Points nearer the last kept one than half a spacing are not kept, except the last.
    @Test func aSlowHandIsThinned() throws {
        var sampler = try StrokeSampler(settings: BrushSettings(radius: 0.02))
        for i in 0..<100 { _ = sampler.add(MaskPoint(x: 0.3 + 0.0002 * Float(i), y: 0.3)) }
        let stroke = try Brush.end(&sampler).stroke
        let points = stroke.points.points
        #expect(points.count < 15)
        #expect(points.last == StrokeSampler.quantized(MaskPoint(x: 0.3 + 0.0002 * 99, y: 0.3)))
        // A click is one point and one dab.
        var click = try StrokeSampler(settings: BrushSettings(radius: 0.02))
        _ = click.add(MaskPoint(x: 0.5, y: 0.5))
        let ended = try Brush.end(&click)
        #expect(ended.stroke.points.count == 1 && BrushDabPath.dabs(of: ended.stroke).count == 1)
    }

    /// The point cap: the stroke stops keeping points at the mask's remaining budget, says so, and a mask at the cap takes no stroke.
    @Test func thePointCapStopsTheStroke() throws {
        var sampler = try StrokeSampler(settings: BrushSettings(radius: 0.002), pointBudget: 100)
        let path = Brush.path(400, seed: 8, step: 0.01)
        for point in path { _ = sampler.add(point) }
        #expect(sampler.isFull && sampler.kept.count == 100)
        let stroke = try Brush.end(&sampler).stroke
        #expect(stroke.points.count == 100)
        #expect(throws: MaskError.self) { try StrokeSampler(settings: BrushSettings(radius: 0.002), pointBudget: 0) }
        // The set's own rule agrees: 16,384 points a mask, then a Flatten step.
        let full = try PackedPoints.pack((0..<MaskSet.maximumBrushPoints).map { MaskPoint(x: Float($0 % 1000) / 1000, y: Float($0 / 1000) / 100) })
        let atCap = BrushStroke(radius: 0.01, points: full)
        _ = try MaskSet(masks: [Brush.brushMask([atCap])])
        #expect(throws: MaskError.self) { try MaskSet(masks: [Brush.brushMask([atCap, try Brush.stroke([MaskPoint(x: 0.5, y: 0.5)], radius: 0.01)])]) }
    }

    /// Settings out of range refuse before anything is painted.
    @Test func settingsOutOfRangeRefuse() {
        for settings in [BrushSettings(radius: 0.0005), BrushSettings(radius: 0.3), BrushSettings(radius: 0.01, feather: 1.5),
                         BrushSettings(radius: 0.01, flow: -0.1), BrushSettings(radius: .nan)] {
            #expect(throws: MaskError.self) { try StrokeSampler(settings: settings) }
        }
    }

    /// Points off the picture are clamped to where a brush point may lie, so the stroke can always be stored.
    @Test func pointsFarOffThePictureAreClamped() throws {
        let stroke = try Brush.stroke([MaskPoint(x: -5, y: 0.2), MaskPoint(x: 9, y: .infinity)], radius: 0.01)
        let points = stroke.points.points
        #expect(points.first == StrokeSampler.quantized(MaskPoint(x: -1, y: 0.2)) && points.last == MaskPoint(x: 2, y: 0))
        #expect(points.allSatisfy { MaskSpace.brushCoordinateRange.contains($0.x) && MaskSpace.brushCoordinateRange.contains($0.y) })
    }
}

// MARK: - The canvas

@Suite struct BrushCanvasTests {
    /// Three committed strokes, an erase among them, as a brush that is being repaired holds.
    static func committed() throws -> [BrushStroke] {
        [try Brush.stroke(Brush.path(120, seed: 31, start: MaskPoint(x: 0.4, y: 0.3)), radius: 0.03, feather: 0.6, flow: 0.7),
         try Brush.stroke(Brush.path(80, seed: 32, start: MaskPoint(x: 0.45, y: 0.32)), radius: 0.012, feather: 0, flow: 1),
         try Brush.stroke(Brush.path(60, seed: 33, start: MaskPoint(x: 0.42, y: 0.31)), radius: 0.02, feather: 1, flow: 0.5, erase: true)]
    }

    /// The gate: a stroke painted tick by tick equals the recipe's strokes replayed from nothing, bit for bit, at every tick checked
    /// (with the stroke as if it ended there) and at the end, for paint and erase, hard and soft, small and large.
    @Test func replayEqualsIncremental() throws {
        let gpu = try GPU()
        let committed = try Self.committed()
        for (index, settings) in [BrushSettings(radius: 0.015, feather: 0.5, flow: 0.5), BrushSettings(radius: 0.004, feather: 0, flow: 1),
                                  BrushSettings(radius: 0.08, feather: 1, flow: 0.3, erase: true)].enumerated() {
            let painting = Brush.cache(gpu), replaying = Brush.cache(gpu)
            let mask = Brush.brushMask(committed)
            let session = try BrushStrokeSession(cache: painting, picture: Brush.picture, mask: mask, component: 0, settings: settings)
            var checked = 0
            for (i, point) in Brush.path(140, seed: UInt64(50 + index), start: MaskPoint(x: 0.43, y: 0.31)).enumerated() {
                try session.add(point)
                guard i % 23 == 7, let stroke = session.stroke else { continue }
                let replay = try replaying.canvas(for: BrushCanvasKey(size: session.size, version: session.version, strokes: committed + [stroke]))
                #expect(Brush.bits(session.live) == Brush.bits(replay.texture), "settings \(index), tick \(i)")
                checked += 1
            }
            let stroke = try #require(try session.end())
            let replay = try Brush.cache(gpu).canvas(for: BrushCanvasKey(size: session.size, version: session.version, strokes: committed + [stroke]))
            let kept = try painting.canvas(for: BrushCanvasKey(size: session.size, version: session.version, strokes: committed + [stroke]))
            #expect(painting.statistics.replays == 1, "only the base was laid; the stroke's canvas was handed over")
            #expect(Brush.bits(kept.texture) == Brush.bits(replay.texture), "settings \(index), the end")
            #expect(checked >= 5)
        }
    }

    /// A canvas continued with new strokes equals the same strokes laid from nothing: what the cache does after an undo or a commit.
    @Test func aContinuedCanvasEqualsOneLaidFromNothing() throws {
        let gpu = try GPU()
        let strokes = try Self.committed()
        let size = MaskFieldSize(picture: Brush.picture)
        let cache = Brush.cache(gpu)
        _ = try cache.canvas(for: BrushCanvasKey(size: size, version: MaskSet.currentVersion, strokes: Array(strokes.prefix(1))))
        let continued = try cache.canvas(for: BrushCanvasKey(size: size, version: MaskSet.currentVersion, strokes: strokes))
        #expect(cache.statistics.replays == 2 && cache.statistics.strokesReplayed == 3)
        let fresh = try Brush.cache(gpu).canvas(for: BrushCanvasKey(size: size, version: MaskSet.currentVersion, strokes: strokes))
        #expect(Brush.bits(continued.texture) == Brush.bits(fresh.texture))
    }

    /// The canvas is the CPU's arithmetic at each texel's centre: within one half-float step, and equal on nearly every texel.
    @Test func theCanvasIsTheCPUReference() throws {
        let gpu = try GPU()
        let strokes = try Self.committed()
        let size = MaskFieldSize(picture: Brush.picture)
        let canvas = try Brush.cache(gpu).canvas(for: BrushCanvasKey(size: size, version: MaskSet.currentVersion, strokes: strokes))
        let values = canvas.values(), field = BrushField(strokes)
        var worst: Float = 0, differ = 0, touched = 0
        for y in stride(from: 400, to: 1000, by: 2) {
            for x in stride(from: 600, to: 1300, by: 2) {
                let point = size.point(column: x, yTop: y)
                let cpu = field.value(at: SIMD2(point.x, point.y)), gpuValue = values[y * size.width + x]
                if cpu > 0 || gpuValue > 0 { touched += 1 }
                if cpu != gpuValue { differ += 1 }
                worst = max(worst, abs(cpu - gpuValue))
            }
        }
        MaskRender.report("brush canvas against CPU: worst \(worst), \(differ) of \(touched) touched texels differ")
        #expect(touched > 10_000 && worst <= 0.0005 && Double(differ) < 0.01 * Double(touched))
    }

    /// R8 13 row 6: the half-float canvas against an `r32Float` one, within 0.005. On R8's own case, one soft stroke of Flow 0.05, the
    /// canvas takes one rounding; on a heavy build-up, 30 soft passes of Flow 0.1 with erasing among them, one a stroke. The extreme,
    /// 120 passes of Flow 0.05, is measured and bounded looser: each stroke's rounding shrinks by only (1 − 0.05) a stroke after it.
    @Test func halfFloatAgreesWithFullFloat() throws {
        let gpu = try GPU()
        let size = MaskFieldSize(picture: Brush.picture)
        func measure(_ strokes: [BrushStroke], _ name: String) throws -> Float {
            let canvas = try Brush.cache(gpu).canvas(for: BrushCanvasKey(size: size, version: MaskSet.currentVersion, strokes: strokes)).values()
            let full = BrushField(strokes, rounding: false)
            var worst: Float = 0, sum: Double = 0, count = 0, peak: Float = 0
            for y in stride(from: 500, to: 900, by: 3) {
                for x in stride(from: 850, to: 1250, by: 3) {
                    let point = size.point(column: x, yTop: y)
                    let reference = full.value(at: SIMD2(point.x, point.y))
                    guard reference > 0 else { continue }
                    let error = abs(canvas[y * size.width + x] - reference)
                    worst = max(worst, error); sum += Double(error); count += 1; peak = max(peak, reference)
                }
            }
            MaskRender.report("brush r16Float against r32Float, \(name): max \(worst), mean \(sum / Double(max(count, 1))) over \(count) texels, peak \(peak)")
            #expect(count > 1000 && peak > 0.04)
            return worst
        }
        func passes(_ count: Int, flow: Float, seed: UInt64) throws -> [BrushStroke] {
            try (0..<count).map { i in
                try Brush.stroke(Brush.path(30, seed: seed + UInt64(i), start: MaskPoint(x: 0.5, y: 0.33), step: 0.003),
                                 radius: 0.03, feather: 1, flow: flow, erase: i % 5 == 4)
            }
        }
        let one = [try Brush.stroke(Brush.path(200, seed: 300, start: MaskPoint(x: 0.5, y: 0.33), step: 0.002), radius: 0.03, feather: 1, flow: 0.05)]
        #expect(try measure(one, "one soft stroke of Flow 0.05 (R8's case)") < 0.005)
        #expect(try measure(passes(30, flow: 0.1, seed: 400), "30 passes of Flow 0.1, every fifth erasing") < 0.005)
        #expect(try measure(passes(120, flow: 0.05, seed: 200), "120 passes of Flow 0.05, every fifth erasing") < 0.01)
    }

    /// A hard brush's edge on the print: the canvas holds it one texel wide, so at 7008 px its 10 to 90 % rise takes about 3 px.
    @Test func aHardEdgeSoftensAboutThreePixelsAt7008() throws {
        let gpu = try GPU()
        let stroke = try Brush.stroke([MaskPoint(x: 0.5, y: 0.33)], radius: 0.1, feather: 0)
        let masks = try MaskSet(masks: [Brush.brushMask([stroke])])
        let coverage = try #require(try Brush.cache(gpu).coverage(for: masks, picture: Brush.picture))
        let field = coverage.values(slot: 0), size = coverage.slots.size
        // Along the row through the centre, bilinear at each 7008 px column's centre, as a kernel samples the slice.
        let row = Int((0.33 / size.texelToPoint.y - 0.5).rounded())
        var profile: [(x: Double, c: Float)] = []
        for column in 3_800...4_300 {
            let u = (Float(column) + 0.5) / 7008 * Float(size.width) - 0.5
            let i = Int(u.rounded(.down)), f = u - Float(i)
            profile.append((Double(column), field[row * size.width + i] * (1 - f) + field[row * size.width + i + 1] * f))
        }
        func crossing(_ level: Float) -> Double {
            for k in 1..<profile.count where profile[k - 1].c >= level && profile[k].c < level {
                let a = profile[k - 1], b = profile[k]
                return a.x + Double((a.c - level) / (a.c - b.c)) * (b.x - a.x)
            }
            return .nan
        }
        let width = crossing(0.1) - crossing(0.9)
        MaskRender.report("brush hard edge at 7008: 10 to 90 % over \(String(format: "%.2f", width)) px")
        #expect(width > 2 && width < 5)
    }
}

// MARK: - Coverage

@Suite struct BrushCoverageTests {
    /// A brush composes with gradients, through Add, Subtract and Intersect and Invert: the slice is the CPU reference's composite.
    @Test func aBrushComposesWithGradients() throws {
        let gpu = try GPU()
        let strokes = try BrushCanvasTests.committed()
        let paint = MaskShape.brush(BrushPaint(frame: Brush.frame, strokes: strokes))
        let linear = MaskShape.linear(.init(full: MaskPoint(x: 0.3, y: 0.1), zero: MaskPoint(x: 0.6, y: 0.5)))
        let radial = MaskShape.radial(.init(center: MaskPoint(x: 0.45, y: 0.32), semiAxisA: 0.08, semiAxisB: 0.05, feather: 40))
        let masks = [
            Mask(components: [MaskComponent(shape: linear), MaskComponent(operation: .subtract, shape: paint)]),
            Mask(components: [MaskComponent(shape: paint), MaskComponent(operation: .intersect, shape: radial)]),
            Mask(components: [MaskComponent(shape: radial), MaskComponent(operation: .add, shape: paint, invert: true)]),
            Mask(components: [MaskComponent(shape: paint, invert: true), MaskComponent(operation: .intersect, shape: paint)]),
        ]
        let coverage = try #require(try Brush.cache(gpu).coverage(for: MaskSet(masks: masks), picture: Brush.picture))
        let size = coverage.slots.size
        for (slot, mask) in masks.enumerated() {
            let values = coverage.values(slot: slot)
            var worst: Float = 0, inside = 0
            let texels = stride(from: 450, to: 900, by: 4).flatMap { y in stride(from: 650, to: 1250, by: 4).map { (x: $0, y: y) } }
            let expected = try MaskCoverage.reference(mask, at: texels.map { size.point(column: $0.x, yTop: $0.y) })
            for (texel, value) in zip(texels, expected) {
                if value > 0.01 && value < 0.99 { inside += 1 }
                worst = max(worst, abs(values[texel.y * size.width + texel.x] - value))
            }
            #expect(worst < 0.0015, "mask \(slot): \(worst)")
            #expect(inside > 100, "mask \(slot) has partial coverage to compare")
        }
    }

    /// A slider never lays a stroke or bakes; a new stroke continues the kept canvas with that stroke alone; the undo of it lays nothing.
    @Test func theCacheIsKeyedByStrokes() throws {
        let gpu = try GPU()
        let cache = Brush.cache(gpu)
        let strokes = try BrushCanvasTests.committed()
        let id = UUID()
        func set(_ strokes: [BrushStroke], exposure: Float) throws -> MaskSet {
            var mask = Brush.brushMask(strokes, id: id)
            mask.adjustments = try ManualAdjustments(exposureEV: exposure)
            return try MaskSet(masks: [mask])
        }
        _ = try cache.coverage(for: set(Array(strokes.prefix(2)), exposure: -1), picture: Brush.picture)
        #expect(cache.statistics.replays == 1 && cache.statistics.bakes == 1)
        for value in stride(from: Float(-2), through: 2, by: 0.5) { _ = try cache.coverage(for: set(Array(strokes.prefix(2)), exposure: value), picture: Brush.picture) }
        #expect(cache.statistics.replays == 1 && cache.statistics.bakes == 1, "a slider")
        _ = try cache.coverage(for: set(strokes, exposure: 1), picture: Brush.picture)
        #expect(cache.statistics.replays == 2 && cache.statistics.strokesReplayed == 3 && cache.statistics.bakes == 2, "one stroke laid")
        _ = try cache.coverage(for: set(Array(strokes.prefix(2)), exposure: 1), picture: Brush.picture)
        #expect(cache.statistics.replays == 2, "undo lays nothing")
        #expect(cache.canvasBytes == 2 * BrushCanvas.byteCount(MaskFieldSize(picture: Brush.picture)))
        cache.removeAll()
        #expect(cache.canvasBytes == 0 && cache.residentBytes == 0)
    }

    /// The stroke in progress stays out of the kept canvases: its print snapshot is found by a render and laid by nobody, and is never
    /// kept; when it ends its canvas is kept, and the bake after it lays nothing.
    @Test func aLiveStrokeIsKeptOutOfTheCacheUntilItEnds() throws {
        let gpu = try GPU()
        let cache = Brush.cache(gpu)
        let strokes = try BrushCanvasTests.committed()
        let mask = Brush.brushMask(strokes)
        _ = try cache.coverage(for: MaskSet(masks: [mask]), picture: Brush.picture)
        let canvas = BrushCanvas.byteCount(MaskFieldSize(picture: Brush.picture))
        #expect(cache.statistics.replays == 1 && cache.canvasBytes == canvas)
        let session = try BrushStrokeSession(cache: cache, picture: Brush.picture, mask: mask, component: 0,
                                             settings: BrushSettings(radius: 0.01, feather: 0.5, flow: 0.8, erase: true))
        var flushed: [Mask] = []
        for (i, point) in Brush.path(90, seed: 77, start: MaskPoint(x: 0.42, y: 0.3)).enumerated() {
            try session.add(point)
            if i % 9 == 4, let snapshot = try session.printSnapshot() {
                flushed.append(snapshot)
                let before = cache.statistics
                let coverage = try #require(try cache.coverage(for: MaskSet(masks: [snapshot]), picture: Brush.picture))
                #expect(cache.statistics.replays == before.replays && cache.statistics.canvasHits == before.canvasHits + 1)
                #expect(cache.canvasBytes == canvas, "the live stroke is not kept")
                let size = coverage.slots.size, x = 860, y = 614
                let reference = try MaskCoverage.reference(snapshot, at: size.point(column: x, yTop: y))
                #expect(abs(coverage.values(slot: 0)[y * size.width + x] - reference) < 0.001)
            }
        }
        #expect(cache.liveCount == 2 && flushed.count >= 8)
        let stroke = try #require(try session.end())
        #expect(cache.liveCount == 0)
        #expect(cache.canvasBytes == 2 * canvas, "the ended stroke's canvas is kept")
        let before = cache.statistics.replays
        _ = try cache.coverage(for: MaskSet(masks: [session.mask(with: stroke)]), picture: Brush.picture)
        #expect(cache.statistics.replays == before, "the bake after the stroke lays nothing")
    }

    /// A session's overlay is the mask's coverage at the slice's texels, live: after the first full read only what changed.
    @Test func theOverlayIsTheMasksCoverage() throws {
        let gpu = try GPU()
        let cache = Brush.cache(gpu)
        let linear = MaskComponent(shape: .linear(.init(full: MaskPoint(x: 0.3, y: 0.1), zero: MaskPoint(x: 0.6, y: 0.5))))
        let mask = Mask(components: [linear, MaskComponent(operation: .subtract, shape: .brush(BrushPaint(frame: Brush.frame)))])
        let session = try BrushStrokeSession(cache: cache, picture: Brush.picture, mask: mask, component: 1,
                                             settings: BrushSettings(radius: 0.02, feather: 0.5, flow: 1))
        let size = session.size
        var bitmap = [UInt8](repeating: 7, count: size.width * size.height)
        let first = try bitmap.withUnsafeMutableBytes { try session.overlay(into: $0.baseAddress!, bytesPerRow: size.width) }
        #expect(first == BrushRegion(x: 0, y: 0, width: size.width, height: size.height))
        #expect(try bitmap.withUnsafeMutableBytes { try session.overlay(into: $0.baseAddress!, bytesPerRow: size.width) } == nil)
        for point in Brush.path(40, seed: 12, start: MaskPoint(x: 0.4, y: 0.25)) { try session.add(point) }
        let changed = try #require(try bitmap.withUnsafeMutableBytes { try session.overlay(into: $0.baseAddress!, bytesPerRow: size.width) })
        #expect(changed.width < size.width / 2)
        let snapshot = try #require(try session.printSnapshot())
        var worst: Float = 0
        let texels = stride(from: 0, to: size.height, by: 7).flatMap { y in stride(from: 0, to: size.width, by: 7).map { (x: $0, y: y) } }
        let expected = try MaskCoverage.reference(snapshot, at: texels.map { size.point(column: $0.x, yTop: $0.y) })
        for (texel, value) in zip(texels, expected) { worst = max(worst, abs(Float(bitmap[texel.y * size.width + texel.x]) / 255 - value)) }
        #expect(worst < 0.006, "\(worst)")
        session.cancel()
        #expect(cache.liveCount == 0 && cache.canvasBytes == BrushCanvas.byteCount(size), "a cancelled stroke keeps nothing but its base")
    }

    /// A brush with no stroke yet covers nothing, and inverted everything; a Follow edges stroke with no measured shape, and a smart shape,
    /// refuse.
    @Test func emptyBrushesAndUnbakedShapes() throws {
        let gpu = try GPU()
        let cache = Brush.cache(gpu)
        let empty = Brush.brushMask([]), inverted = Brush.brushMask([], invert: true)
        let coverage = try #require(try cache.coverage(for: MaskSet(masks: [empty, inverted]), picture: Brush.picture))
        #expect(coverage.values(slot: 0).allSatisfy { $0 == 0 } && coverage.values(slot: 1).allSatisfy { $0 == 1 })
        #expect(cache.statistics.replays == 0)
        var follow = try Brush.stroke([MaskPoint(x: 0.5, y: 0.3)], radius: 0.01)
        follow.followEdges = true
        #expect(throws: MaskCoverageError.unmeasuredStroke) {
            try cache.coverage(for: MaskSet(masks: [Brush.brushMask([follow])]), picture: Brush.picture)
        }
        let pending = Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: .sky)))])
        #expect(throws: MaskRefinerError.selectionPending(.sky)) { try cache.coverage(for: MaskSet(masks: [pending]), picture: Brush.picture) }
        // A smart selection with a seed bakes only with its decode's refinement (`MaskRefinerTests`): without one it refuses, and a stroke
        // on such a mask refuses at the press, not at the first overlay.
        let seed = try MaskRaster(width: 16, height: 16, plane: [UInt8](repeating: 200, count: 256))
        let smart = Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: seed.ref, frame: Brush.frame)))])
        #expect(throws: MaskCoverageError.unbakedShape("smart")) { try cache.coverage(for: MaskSet(masks: [smart]), picture: Brush.picture) }
        var repaired = smart
        repaired.components.append(MaskComponent(operation: .subtract, shape: .brush(BrushPaint(frame: Brush.frame))))
        #expect(throws: MaskCoverageError.unbakedShape("smart")) {
            try BrushStrokeSession(cache: cache, picture: Brush.picture, mask: repaired, component: 1, settings: BrushSettings(radius: 0.01))
        }
        #expect(throws: MaskError.self) {
            try BrushStrokeSession(cache: cache, picture: Brush.picture, mask: repaired, component: 0, settings: BrushSettings(radius: 0.01))
        }
    }

    /// The develop's memory gate counts a canvas for each different list of strokes on a mask that is on, and a develop's cache, whose
    /// limit is 0, keeps none after the bake.
    @Test func aDevelopCountsItsBrushCanvases() throws {
        let gpu = try GPU()
        let strokes = try BrushCanvasTests.committed()
        let a = Brush.brushMask(strokes), b = Brush.brushMask(strokes), c = Brush.brushMask(Array(strokes.prefix(1)))
        let off = Mask(isEnabled: false, components: Brush.brushMask(Array(strokes.prefix(2))).components)
        let set = try MaskSet(masks: [a, b, c, off])
        let slots = try MaskSlots(masks: set, picture: Brush.picture)
        #expect(slots.brushCanvasBytes == 2 * BrushCanvas.byteCount(slots.size))
        let cache = Brush.cache(gpu)
        cache.maximumBytes = 0
        _ = try cache.coverage(for: set, picture: Brush.picture)
        #expect(cache.statistics.replays == 2 && cache.canvasBytes == 0)
    }

    /// The render key's identity holds a brush's strokes: another stroke is another identity, the same strokes the same one.
    @Test func theIdentityHoldsTheStrokes() throws {
        let strokes = try BrushCanvasTests.committed()
        func identity(_ strokes: [BrushStroke]) throws -> String {
            try MaskSlots(masks: MaskSet(masks: [Brush.brushMask(strokes)]), picture: Brush.picture).identity
        }
        #expect(try identity(strokes) == identity(strokes))
        #expect(try identity(strokes) != identity(Array(strokes.prefix(2))))
        var flipped = strokes
        flipped[0].erase.toggle()
        #expect(try identity(strokes) != identity(flipped))
    }

    /// A brush mask prints: Exposure through it darkens where it was painted and nowhere else.
    @Test func aBrushMaskRenders() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let width = 96, height = 64
        let picture = try MaskSpace(width: width, height: height)
        let frame = try MaskRender.frame(gpu, [SIMD3<Float>](repeating: SIMD3(0.18, 0.18, 0.18), count: width * height), width: width, picture: picture)
        let stroke = try Brush.stroke([MaskPoint(x: 0.2, y: 0.33), MaskPoint(x: 0.5, y: 0.33)], radius: 0.06, feather: 0.2)
        let manual = try MaskRender.manual(masks: [MaskRender.mask(MaskComponent(shape: .brush(BrushPaint(frame: Brush.frame, strokes: [stroke]))),
                                                                   ManualAdjustments(exposureEV: -2))])
        // Read while the render is held: its texture goes back to the pool with it.
        func greens(_ settings: DevelopSettings) throws -> (painted: Float, away: Float) {
            let rendered = try renderer.render(frame, settings: settings)
            func pixel(_ x: Int, _ yTop: Int) -> Float {
                var value = [Float16](repeating: 0, count: 4)
                rendered.image.texture.getBytes(&value, bytesPerRow: 8, from: MTLRegionMake2D(x, height - 1 - yTop, 1, 1), mipmapLevel: 0)
                return Float(value[1])
            }
            return (pixel(33, 32), pixel(90, 5))
        }
        let plain = try greens(DevelopSettings(manual: try MaskRender.manual())), masked = try greens(DevelopSettings(manual: manual))
        #expect(masked.painted < plain.painted * 0.8, "painted")
        #expect(abs(masked.away - plain.away) <= 0.002 * plain.away, "not painted")
    }
}

// MARK: - Measurements

/// Timings and memory, printed for the evidence: `ARGENT_BRUSH_MEASURE=1 swift test --filter BrushMeasureTests`. Not a gate; the numbers
/// depend on what else the machine is doing.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ARGENT_BRUSH_MEASURE"] != nil))
struct BrushMeasureTests {
    static func line(_ text: String) { print("[measure] " + text) }

    static func stats(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "none" }
        let sorted = values.sorted()
        func ms(_ v: Double) -> String { String(format: "%.3f", v * 1000) }
        return "min \(ms(sorted[0])) median \(ms(sorted[sorted.count / 2])) p95 \(ms(sorted[min(sorted.count - 1, sorted.count * 95 / 100)])) ms"
    }

    /// A tick: the dabs one pointer event makes certain, at R8's radii and dabs a tick, on the 2048 canvas.
    @Test func tick() throws {
        let gpu = try GPU()
        Self.line("load \(ProcessInfo.processInfo.environment["ARGENT_LOAD"] ?? "?")")
        for radius: Float in [0.005, 0.02, 0.08, 0.15] {
            for perTick in [4, 16, 64] {
                let cache = Brush.cache(gpu)
                let mask = Brush.brushMask([])
                let session = try BrushStrokeSession(cache: cache, picture: Brush.picture, mask: mask, component: 0,
                                                     settings: BrushSettings(radius: radius, feather: 0.5, flow: 0.5))
                // A walk that bounces inside the frame, each event as far as `perTick` dabs; a step past 0.6 long sides is not a pointer event.
                let step = Float(perTick) * 0.2 * radius * 0.999
                guard step <= 0.6 else {
                    Self.line(String(format: "tick r %.3f %2d dabs a tick: skipped, an event %.2f long sides long", radius, perTick, step))
                    continue
                }
                var gpuTimes: [Double] = [], wall: [Double] = []
                var x: Float = 0.1, direction: Float = 1
                for i in 0..<80 {
                    x += step * direction
                    if x > 0.9 { x = 1.8 - x; direction = -1 }
                    if x < 0.1 { x = 0.2 - x; direction = 1 }
                    guard try session.add(MaskPoint(x: x, y: 0.2 + 0.003 * Float(i))) != nil, i >= 4 else { continue }
                    gpuTimes.append(session.lastTickGPUSeconds); wall.append(session.lastTickSeconds)
                }
                Self.line(String(format: "tick r %.3f (%4.0f texels) %2d dabs a tick: GPU ", radius, radius * 2048, perTick) + Self.stats(gpuTimes)
                          + " | wall " + Self.stats(wall))
                session.cancel()
            }
        }
    }

    /// A replay from nothing of about 1,000, 5,000 and 20,000 dabs, at R8's radii: CPU (dabs and bins) and GPU.
    @Test func replay() throws {
        let gpu = try GPU()
        for radius: Float in [0.005, 0.02, 0.08] {
            for target in [1_000, 5_000, 20_000] {
                var strokes: [BrushStroke] = [], dabs = 0, seed: UInt64 = 1
                while dabs < target {
                    let stroke = try Brush.stroke(Brush.path(40, seed: seed, start: MaskPoint(x: 0.1 + 0.8 * Float(seed % 7) / 7, y: 0.1 + 0.45 * Float(seed % 5) / 5),
                                                             step: 0.2 * radius * 3), radius: radius, feather: 0.5, flow: 0.5)
                    strokes.append(stroke); dabs += BrushDabPath.dabs(of: stroke).count; seed += 1
                }
                let size = MaskFieldSize(picture: Brush.picture)
                var cpu: [Double] = [], gpuTimes: [Double] = [], wall: [Double] = []
                for _ in 0..<8 {
                    let started = Date()
                    _ = BrushReplay.inputs(strokes, size: size)
                    cpu.append(Date().timeIntervalSince(started))
                    let cache = Brush.cache(gpu)
                    let begun = Date()
                    _ = try cache.canvas(for: BrushCanvasKey(size: size, version: MaskSet.currentVersion, strokes: strokes))
                    wall.append(Date().timeIntervalSince(begun))
                    gpuTimes.append(cache.statistics.lastGPUSeconds)
                }
                Self.line(String(format: "replay r %.3f %6d dabs in %3d strokes: CPU ", radius, dabs, strokes.count) + Self.stats(cpu)
                          + " | GPU " + Self.stats(gpuTimes) + " | wall " + Self.stats(wall))
            }
        }
    }

    /// What a canvas and a stroke in progress hold, and what the session's other calls cost.
    @Test func memoryAndSession() throws {
        let gpu = try GPU()
        for (w, h) in [(7008, 4672), (6000, 6000), (4672, 7008)] {
            let size = MaskFieldSize(picture: try MaskSpace(width: w, height: h))
            Self.line("canvas \(w)x\(h): \(size.width)x\(size.height) r16Float, \(BrushCanvas.byteCount(size)) bytes "
                      + String(format: "(%.2f MiB); a stroke in progress adds shape + live + up to two print snapshots (4 canvases) and an 8-bit overlay: %.1f MiB",
                               Double(BrushCanvas.byteCount(size)) / 1_048_576,
                               Double(4 * BrushCanvas.byteCount(size) + size.width * size.height) / 1_048_576))
        }
        let committed = try BrushCanvasTests.committed()
        var begin: [Double] = [], snapshot: [Double] = [], overlayFull: [Double] = [], overlayTick: [Double] = [], end: [Double] = [], bake: [Double] = []
        for round in 0..<10 {
            let cache = Brush.cache(gpu)
            let mask = Brush.brushMask(committed)
            _ = try cache.coverage(for: MaskSet(masks: [mask]), picture: Brush.picture)
            var started = Date()
            let session = try BrushStrokeSession(cache: cache, picture: Brush.picture, mask: mask, component: 0,
                                                 settings: BrushSettings(radius: 0.02, feather: 0.5, flow: 0.5))
            begin.append(Date().timeIntervalSince(started))
            let size = session.size
            var bitmap = [UInt8](repeating: 0, count: size.width * size.height)
            started = Date()
            _ = try bitmap.withUnsafeMutableBytes { try session.overlay(into: $0.baseAddress!, bytesPerRow: size.width) }
            overlayFull.append(Date().timeIntervalSince(started))
            var last: Mask?
            for (i, point) in Brush.path(60, seed: UInt64(900 + round), start: MaskPoint(x: 0.45, y: 0.3)).enumerated() {
                try session.add(point)
                started = Date()
                _ = try bitmap.withUnsafeMutableBytes { try session.overlay(into: $0.baseAddress!, bytesPerRow: size.width) }
                overlayTick.append(Date().timeIntervalSince(started))
                if i % 4 == 3 {
                    started = Date()
                    last = try session.printSnapshot()
                    snapshot.append(Date().timeIntervalSince(started))
                    if let last {
                        started = Date()
                        _ = try cache.coverage(for: MaskSet(masks: [last]), picture: Brush.picture)
                        bake.append(Date().timeIntervalSince(started))
                    }
                }
            }
            started = Date()
            _ = try session.end()
            end.append(Date().timeIntervalSince(started))
        }
        Self.line("session begin (base found, two textures, a blit): " + Self.stats(begin))
        Self.line("overlay, first and whole: " + Self.stats(overlayFull) + "; a tick's region: " + Self.stats(overlayTick))
        Self.line("printSnapshot (a canvas copied and registered): " + Self.stats(snapshot))
        Self.line("a render's coverage of the snapshot (slice rebaked from the live canvas, nothing laid): " + Self.stats(bake))
        Self.line("end: " + Self.stats(end))
    }
}
