import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import ArgentCore

/// The frozen Subject design (masking plan decisions 19 to 24) without the models: S3OD's square, the rule, the gate, the hole fill, the matte's trimap and tile arithmetic, and the
/// click's decisions through fake models. What the converted models compute is `SubjectCanaryTests`' and the proof against the research's.
@Suite struct SubjectDesignTests {
    // MARK: S3OD's square

    @Test func theSubjectSquareIsBlackAllRoundWithThePictureCentred() {
        let layout = ModelSquareLayout(side: 4, contentWidth: 2, contentHeight: 2, originX: 1, originY: 1)
        let content: [UInt8] = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120]
        let square = ModelSquare(contentRGB8: content, layout: layout, padding: .black)
        #expect(square.padding == .black && square.padding.description == "black")
        func expected(_ code: UInt8, _ c: Int) -> Float16 { Float16(((Float(code) / 255) - ModelSquare.mean[c]) / ModelSquare.std[c]) }
        func value(_ c: Int, _ x: Int, _ y: Int) -> Float16 { square.input[c * 16 + y * 4 + x] }
        for c in 0..<3 {
            for (x, y) in [(0, 0), (3, 0), (0, 3), (3, 3), (0, 1), (3, 2)] { #expect(value(c, x, y) == expected(0, c)) }
            #expect(value(c, 1, 1) == expected(content[c], c))
            #expect(value(c, 2, 1) == expected(content[3 + c], c))
            #expect(value(c, 1, 2) == expected(content[6 + c], c))
            #expect(value(c, 2, 2) == expected(content[9 + c], c))
        }
        #expect(ModelSquare.recipe(side: 1024, padding: .black) == "square 1024, area-resized, centred, padding black")
        #expect(S3odModelRunner.padding == .black && S3odModelRunner.side == 1024)
    }

    // MARK: X1's rule

    @Test func theRuleIsEvSceneOrIso() {
        func decide(_ iso: Double?, _ t: Double?, _ n: Double?, _ p50: Float?) -> LowLightRule.Decision {
            LowLightRule.decide(.init(iso: iso, exposureTime: t, fNumber: n), medianLuminance: p50)
        }
        // The median is a Float, so EV_scene carries its rounding (log2(Double(Float(0.18)) / 0.18)); the rule compares the exact value.
        func close(_ a: Double?, _ b: Double) -> Bool { abs((a ?? .nan) - b) < 1e-6 }
        // EV100 = log2(16 / (1/4)) - log2(100 / 100) = 6, EV_scene 6 at the 18 % median: dim.
        var d = decide(100, 0.25, 4, 0.18)
        #expect(close(d.evScene, 6) && d.inRule && d.isDim && !d.isHighISO)
        // EV100 = 10: a well-lit frame, outside the rule.
        d = decide(100, 1.0 / 64.0, 4, 0.18)
        #expect(close(d.evScene, 10) && !d.inRule)
        // Just inside and just outside the limit, 7.0.
        d = decide(100, 1.0 / 8.0, 4, Float(0.18 * pow(2, -0.01)))
        #expect(d.evScene! < 7 && d.inRule && d.isDim)
        d = decide(100, 1.0 / 16.0, 4, Float(0.18 * pow(2, -0.9)))
        #expect(d.evScene! > 7 && !d.inRule)
        // The median moves the scene: a half-as-bright median is one stop dimmer, and a tiny one is held at 1e-4.
        d = decide(100, 1.0 / 8.0, 4, 0.09)
        #expect(close(d.evScene, 6) && d.inRule)
        #expect(decide(100, 1.0 / 16.0, 4, 1e-6).evScene! == decide(100, 1.0 / 16.0, 4, 1e-4).evScene!)
        // High ISO is in even in good light: clause 2.
        d = decide(6400, 1.0 / 1000, 8, 0.18)
        #expect(!d.isDim && d.isHighISO && d.inRule)
        #expect(!decide(6399, 1.0 / 1000, 8, 0.18).isHighISO && !decide(6399, 1.0 / 1000, 8, 0.18).inRule)
    }

    @Test func aFrameMissingMetadataPassesOnlyByItsIso() {
        for meta in [LowLightRule.Metadata(iso: nil, exposureTime: 1.0 / 8.0, fNumber: 4), LowLightRule.Metadata(iso: 400, exposureTime: nil, fNumber: 4),
                     LowLightRule.Metadata(iso: 400, exposureTime: 1.0 / 8.0, fNumber: nil), LowLightRule.Metadata()] {
            let d = LowLightRule.decide(meta, medianLuminance: 0.18)
            #expect(d.evScene == nil && !d.inRule && !d.isDim)
        }
        // A non-positive reading is no reading, as X1's `ev100` has it (iso, t and N all > 0).
        #expect(LowLightRule.decide(.init(iso: 0, exposureTime: 0.1, fNumber: 2), medianLuminance: 0.18).evScene == nil)
        // A known high ISO still passes with the rest missing, and a frame whose decode gave no median passes by nothing but its ISO.
        #expect(LowLightRule.decide(.init(iso: 12800), medianLuminance: 0.18).inRule)
        let noMedian = LowLightRule.decide(.init(iso: 100, exposureTime: 1.0 / 8.0, fNumber: 4), medianLuminance: nil)
        #expect(noMedian.evScene == nil && !noMedian.inRule)
        #expect(LowLightRule.decide(.init(iso: 100, exposureTime: 1.0 / 8.0, fNumber: 4), medianLuminance: nil).parameters["rule.in"] == "false")
    }

    @Test func theMedianIsNumpysEvenOddMedian() {
        var a: [Float] = [3, 1, 2]
        #expect(LowLightRule.median(&a) == 2)
        var b: [Float] = [4, 1, 3, 2]
        #expect(LowLightRule.median(&b) == 2.5)
        var c: [Float] = (0..<100_001).map { Float($0) }
        c.shuffle()
        #expect(LowLightRule.median(&c) == 50_000)
        var d: [Float] = (0..<100_000).map { Float($0) }
        d.shuffle()
        #expect(LowLightRule.median(&d) == 49_999.5)
        var empty: [Float] = []
        #expect(LowLightRule.median(&empty) == nil)
        var nan: [Float] = [.nan, 1, 2]
        _ = LowLightRule.median(&nan) // terminates; a NaN median is reported as none (a decode has none)
    }

    /// The median counted in two passes (`median(counting:)`), which a full-size decode's luminance is read with, is `median(_:)`'s
    /// number to the bit, whatever the values and however they are handed over: negatives, both zeros, runs of one value, values a
    /// few bits apart, odd and even counts, one chunk or many.
    @Test func theCountedMedianIsTheSameNumber() {
        var generator = SystemRandomNumberGenerator()
        func counted(_ values: [Float], chunk: Int) -> Float? {
            LowLightRule.median { take in
                var start = 0
                while start < values.count {
                    let end = min(values.count, start + chunk)
                    values[start..<end].withUnsafeBufferPointer { take($0) }
                    start = end
                }
            }
        }
        for trial in 0..<200 {
            let count = 1 + Int.random(in: 0..<60, using: &generator)
            let scale: Float = [1e-6, 1e-3, 1, 100, 3e7][trial % 5]
            let values = (0..<count).map { _ -> Float in
                switch Int.random(in: 0..<10, using: &generator) {
                case 0: return 0
                case 1: return -0.0
                case 2, 3: return Float(Int.random(in: -3...3, using: &generator)) * scale
                case 4: return (0.18 as Float).nextUp * scale
                case 5: return 0.18 * scale
                default: return Float.random(in: -1...1, using: &generator) * scale
                }
            }
            var held = values
            let expected = LowLightRule.median(&held)
            for chunk in [1, 7, count] {
                #expect(counted(values, chunk: chunk) == expected, "\(values) in chunks of \(chunk)")
            }
        }
        var many: [Float] = (0..<200_000).map { _ in Float.random(in: 0...0.9, using: &generator) }
        let big = counted(many, chunk: 4096)
        #expect(big == LowLightRule.median(&many) && big != nil)
        #expect(counted([], chunk: 1) == nil)
        #expect(counted([1, .nan, 2], chunk: 2) == nil, "a NaN among them is no median")
        #expect(counted([1, .infinity, .infinity], chunk: 3) == nil, "nor is one that is not finite")
        // The key orders as the values do, and comes back as the value it was.
        let ordered: [Float] = [-.infinity, -3e7, -1, -1e-30, -0.0, 0, 1e-30, 0.18, (0.18 as Float).nextUp, 1, 3e7, .infinity]
        #expect(ordered.map(LowLightRule.key) == ordered.map(LowLightRule.key).sorted())
        #expect(zip(ordered, ordered.map { LowLightRule.value(LowLightRule.key($0)) }).allSatisfy { $0.bitPattern == $1.bitPattern })
    }

    // MARK: The gate

    @Test func theGateCountsStuffUnderTheSelectionOnTheNearestCell() {
        // A 768 square whose content is 8 x 4 maps cells 1:1 at 192; a map of class 2 (sky, stuff) left, 12 (person, not) right.
        let cell = EomtModelRunner.side / EomtModelRunner.mapSide
        let layout = ModelSquareLayout(side: EomtModelRunner.side, contentWidth: 8 * cell, contentHeight: 4 * cell, originX: 0, originY: 94 * cell)
        var classes = [Float](repeating: 12, count: EomtModelRunner.mapSide * EomtModelRunner.mapSide)
        for y in 0..<EomtModelRunner.mapSide { for x in 0..<4 { classes[y * EomtModelRunner.mapSide + x] = 2 } }
        let maps = EomtMaps(layout: layout, water: classes, sky: classes, classIndex: classes)
        let seedLayout = ModelSquareLayout(side: 1024, contentWidth: 8, contentHeight: 4, originX: 508, originY: 510)
        // Selected: the left half (all stuff), then the right half too: half stuff.
        var selected = [Float](repeating: 0, count: 8 * 4)
        for y in 0..<4 { for x in 0..<4 { selected[y * 8 + x] = 1 } }
        #expect(SubjectDesign.stuffShare(selected: selected, layout: seedLayout, maps: maps) == 1)
        for y in 0..<4 { for x in 4..<8 { selected[y * 8 + x] = 1 } }
        #expect(SubjectDesign.stuffShare(selected: selected, layout: seedLayout, maps: maps) == 0.5)
        #expect(SubjectDesign.stuffShare(selected: [Float](repeating: 0, count: 32), layout: seedLayout, maps: maps) == 0)
        #expect(SubjectDesign.stuff.contains(2) && !SubjectDesign.stuff.contains(12))
    }

    // MARK: The hole fill

    @Test func aHoleInVisionsForegroundFillsAndAHoleBeyondItStays() throws {
        let w = 20, h = 20
        var seed = [UInt8](repeating: 255, count: w * h)
        func stamp(_ x0: Int, _ y0: Int, _ s: Int) { for y in y0..<(y0 + s) { for x in x0..<(x0 + s) { seed[y * w + x] = 0 } } }
        stamp(2, 2, 4)          // a hole Vision covers
        stamp(10, 10, 4)        // a hole Vision does not
        stamp(0, 15, 3)         // a hole at the frame's edge: never filled
        var visionPlane = [UInt8](repeating: 0, count: 16 * 16)
        // Vision: the upper-left quadrant, 0.8 of the frame's width and height on its 16 x 16.
        for y in 0..<8 { for x in 0..<8 { visionPlane[y * 16 + x] = 255 } }
        let vision = try MaskRaster(width: 16, height: 16, plane: visionPlane)
        let filled = SubjectDesign.fillHoles(seed: seed, width: w, height: h, vision: vision)
        #expect(filled[2 * w + 2] == 255 && filled[5 * w + 5] == 255, "inside Vision's foreground")
        #expect(filled[10 * w + 10] == 0 && filled[13 * w + 13] == 0, "beyond Vision's foreground")
        #expect(filled[15 * w] == 0 && filled[16 * w + 1] == 0, "at the frame's edge")
        #expect(SubjectDesign.fillHoles(seed: seed, width: w, height: h, vision: nil) == seed, "no Vision: the seed stands")
    }

    @Test func theFillIsFourConnectedAndCountsTheCoverOfTheWholeHole() throws {
        let w = 20, h = 20
        // Two diagonal one-pixel holes touching at a corner are two components: 8-connectivity would join them.
        var seed = [UInt8](repeating: 255, count: w * h)
        seed[3 * w + 3] = 0; seed[4 * w + 4] = 0
        // Vision covers exactly one of them.
        var visionPlane = [UInt8](repeating: 0, count: w * h)
        visionPlane[3 * w + 3] = 255
        let filled = SubjectDesign.fillHoles(seed: seed, width: w, height: h, vision: try MaskRaster(width: w, height: h, plane: visionPlane))
        #expect(filled[3 * w + 3] == 255 && filled[4 * w + 4] == 0)
        // 9 of 10 pixels of one hole is exactly the 0.9 of the rule: filled; 8 of 10 is not.
        var line = [UInt8](repeating: 255, count: w * h)
        for x in 1..<11 { line[6 * w + x] = 0 }
        var cover = [UInt8](repeating: 0, count: w * h)
        for x in 1..<10 { cover[6 * w + x] = 255 }
        #expect(SubjectDesign.fillHoles(seed: line, width: w, height: h, vision: try MaskRaster(width: w, height: h, plane: cover))[6 * w + 10] == 255)
        cover[6 * w + 9] = 0
        #expect(SubjectDesign.fillHoles(seed: line, width: w, height: h, vision: try MaskRaster(width: w, height: h, plane: cover))[6 * w + 5] == 0)
    }

    @Test func nearestNeighbourSamplesAtFloorOfTheScaledIndex() {
        let plane: [UInt8] = [10, 20, 30, 40]
        // Doubling: 0, 0, 1, 1 on each axis.
        #expect(SubjectDesign.nearestNeighbour(plane, width: 2, height: 2, toWidth: 4, height: 4)
                == [10, 10, 20, 20, 10, 10, 20, 20, 30, 30, 40, 40, 30, 30, 40, 40])
        // Rounded down, never past the end: 2 to 3 on an axis picks 0, 0, 1.
        #expect(SubjectDesign.nearestNeighbour(plane, width: 2, height: 2, toWidth: 3, height: 3) == [10, 10, 20, 10, 10, 20, 30, 30, 40])
    }

    // MARK: The matte

    @Test func tilesFollowTheFrozenAxisAndRamp() {
        #expect(SubjectMatte.axis(1024) == [0] && SubjectMatte.axis(900) == [0])
        #expect(SubjectMatte.axis(2560) == [0, 768, 1536] && SubjectMatte.axis(2560 + 1) == [0, 768, 1536, 1537])
        #expect(SubjectMatte.axis(1707) == [0, 683] && SubjectMatte.axis(1792) == [0, 768])
        // The ramp's values are numpy's linspace in float32: i × 1/129 for 1...128, mirrored, 1 between.
        let ramp = SubjectMatte.rampWindow(count: 1024, ramp: 128)
        #expect(ramp[0] == Float(Double(1) * (1.0 / 129.0)) && ramp[127] == Float(128 * (1.0 / 129.0)) && ramp[128] == 1 && ramp[895] == 1)
        #expect(ramp[1023] == ramp[0] && ramp[896] == ramp[127])
    }

    @Test func distanceTransformsAreExact() {
        func brute(_ mask: [Bool], target: Bool, w: Int, h: Int) -> [Int32] {
            var out = [Int32](repeating: Int32.max, count: w * h)
            for y in 0..<h { for x in 0..<w where true {
                var best = Int32.max
                for y2 in 0..<h { for x2 in 0..<w where mask[y2 * w + x2] == target {
                    best = min(best, Int32((x - x2) * (x - x2) + (y - y2) * (y - y2)))
                } }
                out[y * w + x] = best
            } }
            return out
        }
        var generator = SystemRandomNumberGenerator()
        for trial in 0..<8 {
            let w = Int.random(in: 3...40, using: &generator), h = Int.random(in: 3...40, using: &generator)
            var mask = [Bool](repeating: false, count: w * h)
            for i in mask.indices { mask[i] = Bool.random(using: &generator) || trial % 3 == 0 }
            if !mask.contains(true) { mask[0] = true }
            if !mask.contains(false) { mask[1] = false }
            #expect(SubjectMatte.squaredDistances(mask: mask, target: true, width: w, height: h) == brute(mask, target: true, w: w, h: h))
            #expect(SubjectMatte.squaredDistances(mask: mask, target: false, width: w, height: h) == brute(mask, target: false, w: w, h: h))
        }
        // A mask with no target: every distance beyond the band.
        let noTarget = SubjectMatte.squaredDistances(mask: [Bool](repeating: false, count: 400), target: true, width: 20, height: 20)
        #expect(noTarget.allSatisfy { $0 > 256 })
    }

    @Test func theTrimapIsTheBandAboutTheSeedsContour() {
        // A seed 64 wide: the left half in, the right half out. Unknown within 16 px either side of the contour between columns 31 and 32.
        let w = 64, h = 8
        var inside = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<32 { inside[y * w + x] = true } }
        let t = SubjectMatte.makeTrimap(inside: inside, width: w, height: h)
        #expect(t.values[0] == 255, "16 px inside: x=15 is 16.. away")
        #expect(t.values[15] == 255 && t.values[16] == 128, "a pixel 16 px in: d = 32 - 16 = 16 is in the band")
        #expect(t.values[31] == 128 && t.values[32] == 128 && t.values[47] == 128, "both sides of the contour")
        #expect(t.values[48] == 0, "17 px out")
    }

    @Test func aPictureBelowOneTileIsReflectedOnItsFarSide() async throws {
        // A print 8 × 8 is below the 1024 tile: `np.pad` reflects it, and the model's alpha is read back over its top-left 8 × 8.
        let w = 16, h = 16
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: w * h * 4, alignment: 1)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        for y in 0..<h { for x in 0..<w { buffer[y * w * 4 + x * 4] = UInt8(y * 16 + x) } }
        var tri = [UInt8](repeating: 0, count: w * h)
        tri[5 * w + 6] = 128
        var seen = [Float16]()
        let captured = LockedBox(seen)
        let result = try await SubjectMatte.tileLoop(trimap: tri, picturePixels: UnsafeRawBufferPointer(buffer), width: w, height: h, rowBytes: w * 4, bytesPerPixel: 4) { tile in
            captured.value = tile
            return [Float](repeating: 0.5, count: 1024 * 1024)
        }
        seen = captured.value
        #expect(result.tiles == 1)
        #expect(result.alpha[0] == 0.5 && result.alpha.count == w * h)
        let plane = 1024 * 1024, base = 0
        // The red plane at x=0: row 0, then the columns reflect about x=15: 0, 1, ..., 15, 14, 13, ...
        func red(_ x: Int, _ y: Int) -> Float16 { seen[base + y * 1024 + x] }
        func code(_ v: Int) -> Float16 { Float16((Float(v) / 255 - 0.5) / 0.5) }
        #expect(red(0, 0) == code(0) && red(15, 0) == code(15) && red(16, 0) == code(14) && red(17, 0) == code(13) && red(30, 0) == code(0) && red(31, 0) == code(1))
        // The trimap plane: 128 at (6, 5) in the model's fourth plane, 0 elsewhere around it.
        #expect(seen[3 * plane + 5 * 1024 + 6] == Float16(Float(128) / 255) && seen[3 * plane + 0] == 0)
    }

    @Test func theCompositeBlendsAtTheBandsEdgeAndAppliesTheContrast() {
        // An alpha of 0.5 across a band: the band's edge weight falls off over 4 px, contrast 1.5 keeps 0.5 at 0.5 and pushes the seed's 0/1 to 0/1.
        let w = 5, h = 1
        // Pixels: inside at distance 16 (unknown, ws = 1e-6 from the 16 - d = 0), inside at 12 (ws 1), out 12, out 17 (known 0)
        let t = SubjectMatte.Trimap(values: [128, 128, 128, 0, 255], inside: [true, true, false, false, true],
                                    distancesIn: [16 * 16, 12 * 12, 0, 0, 200 * 200], distancesOut: [0, 0, 12 * 12, 17 * 17, 0])
        let alpha = [Float](repeating: 0.5, count: w * h)
        let out = SubjectMatte.composite(alpha: alpha, trimap: t, width: w, height: h)
        // Inside at d = 16: ws = 1e-6, value = ws·0.5 + (1-ws)·1 ≈ 1 → contrast keeps at 1 → 255.
        #expect(out[0] == 255)
        // ws = 1 at 12 px: value 0.5 → contrast 0.5 → 127.5 + 0.5 truncates to 128.
        #expect(out[1] == 128 && out[2] == 128)
        #expect(out[3] == 0 && out[4] == 255)
    }

    @Test func pillowsBilinearOnKnownSeeds() {
        // A worked value by hand: 2 → 3 horizontally, 1 row. Centres at 1/3, 1, 5/3 of source pixels [0, 255].
        let up = SubjectMatte.pilBilinear([0, 255], width: 2, height: 1, toWidth: 3, toHeight: 1)
        #expect(up[0] == 0 || up[0] == 1)   // pulled by the 0 side and the fixed-point rounding
        #expect(up[2] == 255 || up[2] == 254)
        #expect(up[1] > 110 && up[1] < 145, "the middle sample is near a half: \(up[1])")
        // The same size returns the plane.
        #expect(SubjectMatte.pilBilinear([1, 2, 3, 4], width: 2, height: 2, toWidth: 2, toHeight: 2) == [1, 2, 3, 4])
    }

    // MARK: The click, through fake models

    static let provenance = ModelProvenance(recipeID: "recipe-a", weightsSHA256: String(repeating: "a", count: 64), canarySHA256: "c", fileSHA256: "f")

    /// S3OD's outputs for a content of `cw` × `ch` centred in the 1024 square, with mask `k` taking `pixels` in its content and the others empty.
    static func outputs(cw: Int, ch: Int, argmax k: Int = 1, pixels: [Int], maskValue: Float = 1) -> S3odOutputs {
        let layout = ModelSquareLayout(side: 1024, contentWidth: cw, contentHeight: ch, originX: (1024 - cw) / 2, originY: (1024 - ch) / 2)
        let plane = 1024 * 1024
        var masks = [Float](repeating: 0, count: 3 * plane)
        for p in pixels {
            let y = p / cw, x = p % cw
            masks[k * plane + (y + layout.originY) * 1024 + x + layout.originX] = maskValue
        }
        var iou: [Float] = [0.1, 0.1, 0.1]
        iou[k] = 0.9
        return S3odOutputs(layout: layout, masks: masks, iou: iou)
    }

    static func maps(of classCode: Float, layout: ModelSquareLayout = ModelSquareLayout(side: EomtModelRunner.side, width: 3, height: 2)) -> EomtMaps {
        let n = EomtModelRunner.mapSide * EomtModelRunner.mapSide
        return EomtMaps(layout: layout, water: [Float](repeating: 0, count: n), sky: [Float](repeating: 0, count: n), classIndex: [Float](repeating: classCode, count: n))
    }

    /// A picture, Vision's result and the models, with a recording of what ran.
    struct Rig {
        let picture: AppleSegmentation.Picture
        let source: SeedSource
        var calls: Ran
        var models: SmartSeed.SubjectModels

        final class Ran: @unchecked Sendable {
            let lock = NSLock()
            var region = 0, gate = 0, matte = 0
            var seenSeed: MaskRaster?
        }

        init(outputs: S3odOutputs, maps: EomtMaps = SubjectDesignTests.maps(of: 12), matteAlpha: UInt8 = 200) throws {
            let image = try Self.gray()
            picture = try AppleSegmentation.Picture(image)
            source = SeedSource(sourceSHA256: String(repeating: "0", count: 64), app: "tests", created: Date(timeIntervalSince1970: 0), operatingSystem: "tests")
            let ran = Ran()
            calls = ran
            let width = picture.width, height = picture.height
            models = SmartSeed.SubjectModels(region: SubjectDesignTests.provenance, gate: SubjectDesignTests.provenance, matte: SubjectDesignTests.provenance,
                                             runRegion: { ran.lock.withLock { ran.region += 1 }; return outputs },
                                             runGate: { ran.lock.withLock { ran.gate += 1 }; return maps },
                                             runMatte: { seed in
                                                 ran.lock.withLock { ran.matte += 1; ran.seenSeed = seed }
                                                 return SubjectMatte.Result(alpha: try MaskRaster(width: width, height: height, plane: [UInt8](repeating: matteAlpha, count: width * height)), tiles: 5, unknownShare: 0.03)
                                             })
        }

        static func gray() throws -> CGImage {
            try #require(CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 64 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
        }

        func visionSeed() throws -> SmartResult {
            var labels = [UInt8](repeating: 0, count: 512 * 512)
            for i in 0..<(512 * 512 / 4) { labels[i] = 255 }
            let raster = try MaskRaster(width: 512, height: 512, plane: labels)
            return .seed(SmartSeed(kind: .subject, raster: raster, provenance: RasterProvenance(engine: AppleSegmentation.subjectEngine, engineRevision: "1", parameters: [:], operatingSystem: "tests", app: "tests",
                                                                                                input: .init(kind: "neutral-print", width: 64, height: 40, colorSpace: "sRGB", sourceSHA256: String(repeating: "0", count: 64)),
                                                                                                created: Date(timeIntervalSince1970: 0))))
        }

        func visionNothing() -> SmartResult {
            .nothingFound(.subject, RasterProvenance(engine: AppleSegmentation.subjectEngine, engineRevision: "1", parameters: [:], operatingSystem: "tests", app: "tests",
                                                     input: .init(kind: "neutral-print", width: 64, height: 40, colorSpace: "sRGB", sourceSHA256: String(repeating: "0", count: 64)),
                                                     created: Date(timeIntervalSince1970: 0)))
        }
    }

    static let outOfRule = LowLightRule.decide(.init(iso: 100, exposureTime: 1.0 / 1000, fNumber: 8), medianLuminance: 0.18)
    static let inRule = LowLightRule.decide(.init(iso: 6400, exposureTime: 1.0 / 4000, fNumber: 16), medianLuminance: 0.18)   // a bright scene: in by its ISO alone

    @Test func theSeedPathOutsideTheRuleIsS3odsSeedWithTheCrispEdge() async throws {
        // 1024 × 768 content; a quarter of it selected. Vision found something, so the gate does not run.
        let pixels = Array(0..<(1024 * 768 / 4))
        let rig = try Rig(outputs: Self.outputs(cw: 1024, ch: 768, pixels: pixels, maskValue: 0.7))
        let result = try await SmartSeed.subject(vision: try rig.visionSeed(), picture: rig.picture, source: rig.source, rule: Self.outOfRule, models: rig.models)
        let seed = try #require(result.seed)
        #expect(seed.edge == .crisp && seed.kind == .subject)
        #expect(seed.raster.width == 1024 && seed.raster.height == 768)
        #expect(seed.raster.plane[0] == UInt8((Float(0.7) * 255).rounded()) && seed.raster.plane[1024 * 768 - 1] == 0)
        #expect(rig.calls.region == 1 && rig.calls.gate == 0 && rig.calls.matte == 0, "out of the rule, no matte; Vision found something, no gate")
        let p = seed.provenance.parameters
        #expect(seed.provenance.engine == "coreai:recipe-a" && seed.provenance.engineRevision == "recipe-a@sha256:\(String(repeating: "a", count: 64))")
        #expect(p["model.recipe"] == "recipe-a" && p["iou.argmax"] == "1" && p["vision.found"] == "true" && p["gate.ran"] == "false")
        #expect(p["edge"] == "crisp" && p["rule.in"] == "false" && p["outcome"] == "rule off" && p["seed.identity"] == seed.raster.identity.hex)
        #expect(p["design"] == SubjectDesign.version && p["selected.share"] != nil && p["iou"] != nil)
    }

    @Test func theGateRunsOnlyWhenVisionFoundNothing() async throws {
        let pixels = Array(0..<(1024 * 768 / 4))
        // Vision found nothing, EoMT calls the selection all stuff: rejected, nothing found, no seed; the provenance says the gate did it.
        let stuff = try Rig(outputs: Self.outputs(cw: 1024, ch: 768, pixels: pixels), maps: Self.maps(of: 2))
        let rejected = try await SmartSeed.subject(vision: stuff.visionNothing(), picture: stuff.picture, source: stuff.source, rule: Self.outOfRule, models: stuff.models)
        #expect(rejected.seed == nil && rejected.kind == .subject)
        #expect(stuff.calls.gate == 1 && stuff.calls.matte == 0)
        let p = rejected.provenance.parameters
        #expect(p["selection"] == "gate" && p["outcome"] == "none (gate)" && p["gate.ran"] == "true" && p["gate.stuffShare"] == "1.0" && p["eomt.recipe"] == "recipe-a")
        // Vision found nothing, EoMT calls it a person: the seed stands.
        let person = try Rig(outputs: Self.outputs(cw: 1024, ch: 768, pixels: pixels), maps: Self.maps(of: 12))
        let kept = try await SmartSeed.subject(vision: person.visionNothing(), picture: person.picture, source: person.source, rule: Self.outOfRule, models: person.models)
        #expect(kept.seed != nil && person.calls.gate == 1)
        #expect(kept.provenance.parameters["gate.stuffShare"] == "0.0" && kept.provenance.parameters["selection"] == "kept")
    }

    @Test func aSelectionUnderTheBarIsNothingFound() async throws {
        // 0.1 % of 1024 × 768 is 786.4 pixels. 786 is under, 787 is over.
        let under = try Rig(outputs: Self.outputs(cw: 1024, ch: 768, pixels: Array(0..<786)))
        let nothing = try await SmartSeed.subject(vision: try under.visionSeed(), picture: under.picture, source: under.source, rule: Self.outOfRule, models: under.models)
        #expect(nothing.seed == nil && nothing.provenance.parameters["selection"] == "empty" && nothing.provenance.parameters["outcome"] == "none (empty)")
        let over = try Rig(outputs: Self.outputs(cw: 1024, ch: 768, pixels: Array(0..<787)))
        let found = try await SmartSeed.subject(vision: try over.visionSeed(), picture: over.picture, source: over.source, rule: Self.outOfRule, models: over.models)
        #expect(found.seed != nil)
    }

    @Test func inTheRuleAFilledSeedIsMattedAndStoredAsAnAlpha() async throws {
        // An S3OD seed with a hole Vision covers (the hole in the upper-left quadrant, where visionSeed's labels are 255).
        let (w, h) = (1024, 768)
        var pixels = Array(0..<(w * h))
        for y in 100..<110 { for x in 100..<110 { pixels.removeAll { $0 == y * w + x } } }
        let rig = try Rig(outputs: Self.outputs(cw: w, ch: h, pixels: pixels))
        let result = try await SmartSeed.subject(vision: try rig.visionSeed(), picture: rig.picture, source: rig.source, rule: Self.inRule, models: rig.models)
        let seed = try #require(result.seed)
        #expect(seed.edge == .matte && seed.raster.width == 64 && seed.raster.height == 40, "the alpha at the print's size")
        #expect(seed.raster.plane.allSatisfy { $0 == 200 } && rig.calls.matte == 1)
        let given = try #require(rig.calls.seenSeed)
        #expect(given.plane[105 * w + 105] == 255, "the matte was given the filled seed")
        let p = seed.provenance.parameters
        #expect(p["edge"] == "matte" && p["rule.in"] == "true" && p["rule.clause"] == "iso" && p["outcome"] == "fill" && p["matte.recipe"] == "recipe-a")
        #expect(p["matte.tiles"] == "5" && p["seed.identity"] == given.identity.hex && p["matte.design"] == SubjectMatte.version)
        #expect(p["seed.frozen"] != nil && p["seed.frozen"] != p["seed.identity"], "the hole was filled, so the frozen seed differs from the seed given to the matte")
    }

    @Test func theRuleDoesNotChangeAFrameOutsideIt() async throws {
        // The same outputs out of the rule make no matte and no fill: a hole stays a hole.
        let (w, h) = (1024, 768)
        var pixels = Array(0..<(w * h))
        for y in 100..<110 { for x in 100..<110 { pixels.removeAll { $0 == y * w + x } } }
        let rig = try Rig(outputs: Self.outputs(cw: w, ch: h, pixels: pixels))
        let seed = try #require(try await SmartSeed.subject(vision: try rig.visionSeed(), picture: rig.picture, source: rig.source, rule: Self.outOfRule, models: rig.models).seed)
        #expect(seed.raster.plane[105 * w + 105] == 0, "the hole stays out of the rule")
        #expect(rig.calls.matte == 0)
    }

    @Test func inTheRuleAnEmptySelectionFallsBackToVisionsMask() async throws {
        let rig = try Rig(outputs: Self.outputs(cw: 1024, ch: 768, pixels: []))
        let result = try await SmartSeed.subject(vision: try rig.visionSeed(), picture: rig.picture, source: rig.source, rule: Self.inRule, models: rig.models)
        let seed = try #require(result.seed)
        let given = try #require(rig.calls.seenSeed)
        #expect(given.width == 512 && given.height == 512 && given.plane.filter { $0 == 255 }.count == 512 * 512 / 4, "Vision's own labels, at 512 x 512")
        #expect(seed.edge == .matte && seed.provenance.parameters["outcome"] == "vision fallback")
        #expect(seed.provenance.parameters["selection"] == "empty" && seed.provenance.parameters["seed.identity"] == given.identity.hex)
    }

    @Test func inTheRuleTheGateStillRejectsAndAnEmptyVisionFindsNothing() async throws {
        // Vision found nothing, the selection is all stuff: the fallback is for an empty selection only, and there is no Vision to fall back on.
        let rig = try Rig(outputs: Self.outputs(cw: 1024, ch: 768, pixels: Array(0..<(1024 * 768 / 4))), maps: Self.maps(of: 2))
        let result = try await SmartSeed.subject(vision: rig.visionNothing(), picture: rig.picture, source: rig.source, rule: Self.inRule, models: rig.models)
        #expect(result.seed == nil && result.provenance.parameters["selection"] == "gate" && rig.calls.matte == 0)
        // Empty selection and Vision found nothing: nothing found.
        let empty = try Rig(outputs: Self.outputs(cw: 1024, ch: 768, pixels: []))
        let none = try await SmartSeed.subject(vision: empty.visionNothing(), picture: empty.picture, source: empty.source, rule: Self.inRule, models: empty.models)
        #expect(none.seed == nil && empty.calls.matte == 0 && none.provenance.parameters["outcome"] == "none (empty)")
    }

    @Test func backgroundIsSubjectsRasterAndEdgeInverted() async throws {
        let rig = try Rig(outputs: Self.outputs(cw: 1024, ch: 768, pixels: Array(0..<(1024 * 768 / 4))))
        let subject = try await SmartSeed.subject(vision: try rig.visionSeed(), picture: rig.picture, source: rig.source, rule: Self.outOfRule, models: rig.models)
        let background = try #require(AppleSegmentation.background(from: subject).seed)
        #expect(background.kind == .background && background.raster == subject.seed?.raster && background.edge == .crisp && background.provenance == subject.provenance)
    }

    @Test func aFallbackKeepsTodaysSeedAndEdgeAndSaysWhy() throws {
        let rig = try Rig(outputs: Self.outputs(cw: 1024, ch: 768, pixels: []))
        let vision = try rig.visionSeed()
        let fallback = AppleSegmentation.fallback(vision, why: "s3od-sod-sq1024-f16 is unavailable")
        #expect(fallback.seed?.raster == vision.seed?.raster && fallback.seed?.edge == .guided)
        #expect(fallback.provenance.engine == AppleSegmentation.subjectEngine && fallback.provenance.parameters["fallback"] == "s3od-sod-sq1024-f16 is unavailable")
        let nothing = AppleSegmentation.fallback(rig.visionNothing(), why: "why")
        #expect(nothing.seed == nil && nothing.provenance.parameters["fallback"] == "why")
    }
}

/// A box a test's closure writes to from a task that does not cross into another.
private final class LockedBox: @unchecked Sendable {
    var value: [Float16]
    init(_ value: [Float16]) { self.value = value }
}
