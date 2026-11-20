import CryptoKit
import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Smart masks before Feather, byte for byte (decision 19's first rule: every existing mask renders exactly as before).
@Suite struct MaskFeatherZeroTests {
    private static let picture = try! MaskSpace(width: 7008, height: 4672)

    static func sha(_ bytes: some DataProtocol) -> String { SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined() }
    static func sha(_ bits: [UInt16]) -> String { bits.withUnsafeBytes { sha(Data($0)) } }
    static func sha(_ values: [Float]) -> String { values.withUnsafeBytes { sha(Data($0)) } }

    /// The smart masks each test renders: a selection alone with Exposure (tier 2), alone and tone-only (tier 1), less a soft Subtract
    /// brush (tier 2 composed), and with a second selection (tier 1 with Exposure).
    static func sets(_ raster: MaskRaster, empty: MaskRaster) throws -> [[Mask]] {
        let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let stroke = BrushStroke(radius: 0.04, feather: 1, flow: 0.8,
                                 points: try PackedPoints.pack([MaskPoint(x: 0.6, y: 0.15), MaskPoint(x: 0.75, y: 0.2), MaskPoint(x: 0.9, y: 0.12)]))
        let brush = MaskComponent(operation: .subtract, shape: .brush(BrushPaint(frame: frame, strokes: [stroke])))
        let sky = try Refine.component(.sky, raster), nothing = try Refine.component(.subject, empty)
        let exposure = try ManualAdjustments(exposureEV: -1.5)
        func id(_ n: UInt8) -> UUID { UUID(uuid: (n, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, n)) }
        return [[Mask(id: id(1), components: [sky], adjustments: exposure)],
                [Mask(id: id(2), components: [sky], adjustments: try ManualAdjustments(highlights: -40, shadows: 30))],
                [Mask(id: id(3), components: [sky, brush], adjustments: exposure)],
                [Mask(id: id(4), components: [sky, nothing], adjustments: exposure),
                 Mask(id: id(5), components: [try Refine.component(.background, raster)], adjustments: try ManualAdjustments(exposureEV: 0.7))]]
    }

    /// Each set's render, its first slice, the slots' identity and the record, as digests taken at `fcd98f3`, before Feather, by this
    /// same test: a selection with Feather 0, written or defaulted, is what it was in every byte.
    @Test func smartMasksRenderAsBeforeFeather() throws {
        let gpu = try GPU()
        let (pixels, matte) = Refine.scene(width: 1200, height: 800)
        let raster = try Refine.seed(matte: matte, width: 1200, height: 800, seedWidth: 378, seedHeight: 252, binary: true)
        let empty = try Refine.constant(0)
        gpu.maskRefiner.seeds = Refine.Seeds([raster, empty])
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        var renders: [String] = [], slices: [String] = [], identities: [String] = [], records: [String] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for masks in try Self.sets(raster, empty: empty) {
            let frame = try MaskRender.frame(gpu, pixels, width: 1200, picture: Self.picture)
            let settings = DevelopSettings(halation: true, sharpen: true, manual: try MaskRender.manual(try ManualAdjustments(shadows: 20), masks: masks, reference: 0.3))
            renders.append(Self.sha(MaskRender.bits(try renderer.render(frame, settings: settings).image.texture)))
            let scene = try Refine.scene(renderer, frame, settings)
            let inputs = try #require(scene.masks)
            slices.append(Self.sha(inputs.coverage.values(slot: 0)))
            identities.append(inputs.coverage.identity)
            records.append(Self.sha(try encoder.encode(try MaskSet(masks: masks))))
        }
        MaskRender.report("feather 0: renders \(renders) slices \(slices) identities \(identities) records \(records)")
        #expect(renders == ["1ec029ac9bb6cbc46501dd48096a0ff5e43ce2ee96a3954334da8028b0f7fcb1", "50e29f39dac110f7e2c6167ff96917ef1eec693f6873bb9a711a19485e8fb6d1",
                            "b9fdd7e4a6765aec0bd12a45a01fa27b82e2fa1a685ba5d24ac181718d12bb76", "73a17103fee9aa2b39f5bfa298e900a0ca17e20d3e54fc30520a78336fc005ee"])
        #expect(slices == ["d0c45dee8df1102819793e17bbcebffbf334ad3c4ac83467e9ce0fedbb305918", "d0c45dee8df1102819793e17bbcebffbf334ad3c4ac83467e9ce0fedbb305918",
                           "4946851a35747097e1f8dd78cf947a2e3faa9ed6faee36314cf4293031d6a96b", "d0c45dee8df1102819793e17bbcebffbf334ad3c4ac83467e9ce0fedbb305918"])
        #expect(identities == ["5673da58b2d483aa2b00f6340f963bd2086a6f844b9ca2c54a93d66108b2134c", "5673da58b2d483aa2b00f6340f963bd2086a6f844b9ca2c54a93d66108b2134c",
                               "85cc69943243fa16ccee360a0b7747c44220df3d00aa7cd23975348e4c461334", "56a651e06e5e7517e590a140ccdd5b68d7a32d22ddb0ac1c6f824e5bd404b0af"])
        #expect(records == ["3508b08ed586ff54a6727e54bb872874dc5c601f7ea50ab9fb57b2e6ce3e0a51", "e2e9a4148e7070a624a6ae45f31fab710f8710f23a82d5939848e2c59f7ab6ae",
                            "d8f629d6bae683964af3d03cb64b151df9bac362cab3200ec9a0b7744ae026a0", "5e66771ffb3e95720118be33eed9ec8199963e259b49c0fc3e1cd04e03bb1ffc"])
        #expect(gpu.maskRefiner.statistics.feathers == 0)
    }
}

/// Feather in the data model: a smart selection's, part of its mask's coverage and digest, written only when set, and a record that has
/// one says schema 2 so a build from before Feather refuses it rather than prints without it.
@Suite struct MaskFeatherModelTests {
    private static func id(_ n: UInt8) -> UUID { UUID(uuid: (n, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, n)) }
    private static func selection(feather: Float = 0, kind: SmartKind = .sky) throws -> SmartSelection {
        SmartSelection(kind: kind, raster: try RasterRef(id: #require(RasterID(hex: String(repeating: "ab", count: 32))), width: 64, height: 48),
                       frame: try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true), feather: feather)
    }
    private static func set(_ selection: SmartSelection, adjustments: ManualAdjustments = .identity) throws -> MaskSet {
        try MaskSet(masks: [Mask(id: id(1), components: [MaskComponent(shape: .smart(selection))], adjustments: adjustments)])
    }
    private static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private static func decode(_ text: String) throws -> MaskSet { try JSONDecoder().decode(MaskSet.self, from: Data(text.utf8)) }

    @Test func aSelectionStartsAtZeroAndZeroIsTheSelectionAsItWas() throws {
        #expect(SmartSelection(kind: .person).feather == 0)
        #expect(SmartSelection.featherRange == 0...100)
        let plain = try Self.selection(), zero = try Self.selection(feather: 0), negativeZero = try Self.selection(feather: -0.0)
        #expect(plain == zero && plain == negativeZero && plain.hashValue == negativeZero.hashValue)
        #expect(try Self.set(plain).digest == Self.set(negativeZero).digest)
        // The record a selection without a feather writes is the synthesized one's, key for key: no "feather", schema 1.
        let text = try Self.json(try Self.set(plain))
        #expect(!text.contains("feather") && text.contains(#""schema":1"#))
        #expect(try Self.json(plain) == #"{"frame":{"decoder":"raw9","height":4672,"lensCorrection":true,"orientation":1,"width":7008},"kind":"sky","raster":{"height":48,"id":"\#(String(repeating: "ab", count: 32))","width":64}}"#)
        #expect(try Self.json(SmartSelection(kind: .subject)) == #"{"kind":"subject"}"#)
    }

    @Test func aFeatheredRecordIsSchemaTwoAndComesBackExactly() throws {
        for feather: Float in [0.5, 1, 25, 37.25, 100] {
            let set = try Self.set(try Self.selection(feather: feather), adjustments: try ManualAdjustments(exposureEV: -1.5))
            let text = try Self.json(set)
            #expect(text.contains(#""schema":2"#) && text.contains(#""feather":"#), "\(feather)")
            let read = try Self.decode(text)
            #expect(read == set && read.digest == set.digest && read.masks == set.masks, "\(feather)")
            guard case .smart(let back) = read.masks[0].components[0].shape else { Issue.record("not smart"); return }
            #expect(back.feather == feather)
            #expect(MaskSet.schema(of: read.masks) == 2)
            // A receipt holds no field an older build would drop.
            #expect(try Self.json(set.digestOnly).contains(#""schema":1"#))
        }
        let unfeathered = try Self.set(try Self.selection())
        #expect(MaskSet.schema >= 2 && MaskSet.schema(of: unfeathered.masks) == 1)
    }

    /// Schema 2 is read; a feather in a record that says schema 1 is what an older build would have dropped, so it is refused, as a
    /// schema this build does not know is.
    @Test func aFeatherNeedsSchemaTwoAndANewerSchemaIsRefused() throws {
        let text = try Self.json(try Self.set(try Self.selection(feather: 40)))
        #expect(throws: MaskError.self) { try Self.decode(text.replacingOccurrences(of: #""schema":2"#, with: #""schema":1"#)) }
        #expect(throws: MaskError.unsupportedSchema(7)) { try Self.decode(text.replacingOccurrences(of: #""schema":2"#, with: #""schema":7"#)) }
        // A set with no feather may say schema 2 (a later build may write it so); it reads the same.
        let plain = try Self.json(try Self.set(try Self.selection()))
        #expect(try Self.decode(plain.replacingOccurrences(of: #""schema":1"#, with: #""schema":2"#)) == Self.set(try Self.selection()))
    }

    @Test func aFeatherIsZeroToOneHundredAndFinite() throws {
        for good: Float in [0, 0.001, 50, 100] { _ = try Self.set(try Self.selection(feather: good)) }
        for bad: Float in [-1, -0.001, 100.5, .infinity, .nan] {
            #expect(throws: MaskError.self, "\(bad)") { try Self.set(try Self.selection(feather: bad)) }
        }
        // And on the way in: a stored value past the range fails the read, so the record is kept.
        let text = try Self.json(try Self.set(try Self.selection(feather: 40)))
        #expect(throws: MaskError.self) { try Self.decode(text.replacingOccurrences(of: #""feather":40"#, with: #""feather":140"#)) }
    }

    /// A feather is shape, not a slider: it moves the coverage key, the digest and the render key; a slider moves only the digest.
    @Test func featherMovesTheCoverageKeyTheDigestAndTheRenderKey() throws {
        let picture = try MaskSpace(width: 7008, height: 4672)
        let plain = try Self.set(try Self.selection()), feathered = try Self.set(try Self.selection(feather: 25))
        let other = try Self.set(try Self.selection(feather: 26))
        #expect(plain.masks[0].coverage != feathered.masks[0].coverage && feathered.masks[0].coverage != other.masks[0].coverage)
        #expect(plain.digest != feathered.digest && feathered.digest != other.digest)
        let slots = { (set: MaskSet) in try MaskSlots(masks: set, picture: picture).identity }
        #expect(try slots(plain) != slots(feathered) && slots(feathered) != slots(other))
        let slid = try Self.set(try Self.selection(feather: 25), adjustments: try ManualAdjustments(exposureEV: 1))
        #expect(try slid.masks[0].coverage == feathered.masks[0].coverage && slots(slid) == slots(feathered) && slid.digest != feathered.digest)
    }

    /// Copy to another frame and Reapply clear the seed, a measurement of the old picture, and keep the Feather, which is the user's.
    @Test func anotherPictureKeepsTheFeather() throws {
        let moved = try Self.set(try Self.selection(feather: 60)).forAnotherPicture(freshIDs: true)
        guard case .smart(let selection) = moved.masks[0].components[0].shape else { Issue.record("not smart"); return }
        #expect(selection.raster == nil && selection.frame == nil && selection.feather == 60)
        #expect(MaskSet.schema(of: moved.masks) == 2)
    }
}

/// What a Feather means: σ in long sides, a normalized Gaussian with its edges held, the same on the CPU as in the kernel.
@Suite struct MaskFeatherCurveTests {
    @Test func sigmaGrowsFromZeroToItsValueAt100() {
        #expect(MaskFeather.sigma(0) == 0 && MaskFeather.sigma(100) == MaskFeather.sigmaAt100)
        #expect(MaskFeather.sigma(-5) == 0 && MaskFeather.sigma(150) == MaskFeather.sigmaAt100)
        var last: Float = 0
        for f in stride(from: Float(1), through: 100, by: 1) {
            #expect(MaskFeather.sigma(f) > last, "\(f)")
            last = MaskFeather.sigma(f)
        }
        // On the 2048 slice, Feather 100's kernel stays far inside what the kernel is handed.
        let size = MaskFieldSize(picture: try! MaskSpace(width: 7008, height: 4672))
        let sigma = MaskFeather.texelSigma(100, size: size)
        #expect(MaskFeather.weights(sigma: max(sigma.x, sigma.y)).count < MaskFeather.maximumRadius / 4)
    }

    @Test func theWeightsAreANormalizedGaussian() {
        #expect(MaskFeather.weights(sigma: 0) == [1] && MaskFeather.weights(sigma: 0.005) == [1])
        for sigma: Float in [0.3, 1, 2.5, 7, 13.1, 40] {
            let w = MaskFeather.weights(sigma: sigma)
            let total = w[0] + 2 * w.dropFirst().reduce(0, +)
            #expect(abs(total - 1) < 1e-5, "\(sigma)")
            #expect(w.count - 1 == max(1, Int((4 * sigma).rounded(.up))), "\(sigma)")
            #expect(zip(w, w.dropFirst()).allSatisfy { $0 > $1 }, "\(sigma)")
        }
    }

    /// A flat field stays flat to the edge (the edges are held, so a sky that meets the frame's top stays whole), a step becomes the
    /// Gaussian's integral, and the complement's blur is the blur's complement, so Invert and Background need no order.
    @Test func aBlurKeepsFlatsMakesAStepAnErfAndCommutesWithTheComplement() {
        let (w, h): (Int, Int) = (96, 64)
        let flat = MaskFeather.blurred([Float](repeating: 0.75, count: w * h), width: w, height: h, sigmaX: 6, sigmaY: 6)
        #expect(flat.allSatisfy { abs($0 - 0.75) < 1e-5 })
        let step = (0..<(w * h)).map { Float($0 % w < 48 ? 1 : 0) }
        let sigma: Float = 5
        let blurred = MaskFeather.blurred(step, width: w, height: h, sigmaX: sigma, sigmaY: sigma)
        for x in 30..<66 {
            // The edge is between texels 47 and 48, at 48 on a texel-centre axis.
            let expected = 0.5 * erfc((Float(x) + 0.5 - 48) / (sigma * Float(2).squareRoot()))
            #expect(abs(blurred[20 * w + x] - expected) < 0.002, "\(x): \(blurred[20 * w + x]) against \(expected)")
        }
        let inverse = MaskFeather.blurred(step.map { 1 - $0 }, width: w, height: h, sigmaX: sigma, sigmaY: 3)
        let direct = MaskFeather.blurred(step, width: w, height: h, sigmaX: sigma, sigmaY: 3)
        #expect(zip(inverse, direct).allSatisfy { abs($0 + $1 - 1) < 1e-5 })
        // Feather 0 is no blur at all.
        #expect(MaskFeather.blurred(step, width: w, height: h, feather: 0) == step)
    }
}

/// Feather through the refiner, the bake and the kernels' tier rule.
@Suite struct MaskFeatherRenderTests {
    private static let picture = try! MaskSpace(width: 7008, height: 4672)

    /// An `r16Float` field's texels, row 0 the texture's (the picture's bottom).
    static func field(_ texture: MTLTexture) -> [Float] {
        var halves = [Float16](repeating: 0, count: texture.width * texture.height)
        halves.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 2, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return halves.map(Float.init)
    }

    static func feathered(_ component: MaskComponent, _ feather: Float) -> MaskComponent {
        guard case .smart(var selection) = component.shape else { return component }
        selection.feather = feather
        return MaskComponent(operation: component.operation, shape: .smart(selection), invert: component.invert)
    }

    struct Phantom {
        let gpu: GPU
        let raster: MaskRaster
        let pixels: [SIMD3<Float>]
        let frame: LinearFrame
        let width: Int
        let height: Int
        init(width: Int = 2400, height: Int = 1600) throws {
            gpu = try GPU()
            let scene = Refine.scene(width: width, height: height)
            pixels = scene.pixels
            raster = try Refine.seed(matte: scene.matte, width: width, height: height, seedWidth: 378, seedHeight: 252, binary: true)
            gpu.maskRefiner.seeds = Refine.Seeds([raster])
            frame = try MaskRender.frame(gpu, pixels, width: width, picture: MaskFeatherRenderTests.picture)
            self.width = width; self.height = height
        }
        func sky(_ feather: Float = 0, invert: Bool = false, operation: MaskOperation = .add) throws -> MaskComponent {
            MaskFeatherRenderTests.feathered(try Refine.component(.sky, raster, invert: invert, operation: operation), feather)
        }
    }

    /// The kernel's blur against the CPU's, on the refined field it blurs: the difference is the half float's.
    @Test func theKernelBlursAsTheCPUDoes() throws {
        let p = try Phantom()
        let session = p.gpu.maskRefiner.session(for: p.frame, picture: Self.picture)
        guard case .smart(let plain) = try p.sky().shape else { return }
        let refined = Self.field(try session.field(for: plain))
        let size = session.fieldSize
        for feather: Float in [10, 50, 100] {
            var selection = plain
            selection.feather = feather
            let texture = try session.field(for: selection)
            #expect(texture.pixelFormat == .r16Float && texture.width == size.width && texture.height == size.height)
            let sigma = MaskFeather.texelSigma(feather, size: size)
            let cpu = MaskFeather.blurred(refined, width: size.width, height: size.height, sigmaX: sigma.x, sigmaY: sigma.y)
            let gpu = Self.field(texture)
            var worst: Float = 0
            for i in gpu.indices { worst = max(worst, abs(gpu[i] - cpu[i])) }
            MaskRender.report("feather \(feather): σ \(sigma) texels, kernel against the CPU \(worst), GPU \(p.gpu.maskRefiner.statistics.lastFeatherSeconds * 1000) ms")
            #expect(worst < 0.002, "\(feather): \(worst)")
            // It is a blur: the sky's mean is kept, and nothing leaves 0...1.
            #expect(abs(gpu.reduce(0, +) / Float(gpu.count) - refined.reduce(0, +) / Float(refined.count)) < 0.002)
            #expect(gpu.allSatisfy { $0 >= 0 && $0 <= 1 })
        }
        #expect(p.gpu.maskRefiner.statistics.feathers == 3 && p.gpu.maskRefiner.statistics.builds == 1)
    }

    /// Tier 1 whenever a selection has a Feather, alone, inverted or composed with a brush, on every surface; tier 2 for the same mask at
    /// Feather 0. The composed one's slice is the bake's composition of the blurred field with the brush, texel for texel.
    @Test func aFeatheredSelectionTakesTierOneAloneAndComposed() throws {
        let p = try Phantom()
        let renderer = try FilmRenderer(gpu: p.gpu, stock: LightCompilerBaselineTests.toyStock())
        let paintFrame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let stroke = BrushStroke(radius: 0.04, feather: 1, flow: 0.8,
                                 points: try PackedPoints.pack([MaskPoint(x: 0.6, y: 0.15), MaskPoint(x: 0.75, y: 0.2), MaskPoint(x: 0.9, y: 0.12)]))
        let brush = MaskComponent(operation: .subtract, shape: .brush(BrushPaint(frame: paintFrame, strokes: [stroke])))
        let exposure = try ManualAdjustments(exposureEV: -1.5)
        let masks = [Mask(components: [try p.sky(30)], adjustments: exposure),
                     Mask(components: [try p.sky(30), brush], adjustments: exposure),
                     Mask(components: [try p.sky(30, invert: true)], adjustments: exposure),
                     Mask(components: [try p.sky()], adjustments: exposure),
                     Mask(components: [try p.sky(), brush], adjustments: exposure)]
        for (index, mask) in masks.enumerated() {
            #expect((MaskRefiner.perPixelSelection(mask) == nil) == (index < 3), "mask \(index)")
        }
        #expect(MaskRefiner.perPixelSlots(masks) == [3, 4])
        let scene = try Refine.scene(renderer, p.frame, DevelopSettings(manual: try MaskRender.manual(masks: masks)))
        let inputs = try #require(scene.masks)
        #expect(inputs.refinement.refined == 0b11 && inputs.refinement.slot.x == 3 && inputs.refinement.slot.y == 4)
        #expect(inputs.coverage.slots.composed == [MaskSlots.Composed(mask: 4, low: 5)])

        // The composed mask's slice: Sky at Feather 30, blurred on the CPU from the unfeathered field, less the brush.
        let size = inputs.coverage.slots.size
        let session = p.gpu.maskRefiner.session(for: p.frame, picture: Self.picture)
        guard case .smart(let plain) = try p.sky().shape else { return }
        let sigma = MaskFeather.texelSigma(30, size: size)
        let blurred = MaskFeather.blurred(Self.field(try session.field(for: plain)), width: size.width, height: size.height,
                                          sigmaX: sigma.x, sigmaY: sigma.y)
        let program = try MaskProgram(masks[1].coverage), field = BrushField([stroke])
        let values = inputs.coverage.values(slot: 1), alone = inputs.coverage.values(slot: 0), inverted = inputs.coverage.values(slot: 2)
        var composed: Float = 0, single: Float = 0, complement: Float = 0
        for yTop in stride(from: 0, to: size.height, by: 3) {
            for x in stride(from: 0, to: size.width, by: 3) {
                let v = blurred[(size.height - 1 - yTop) * size.width + x], point = size.point(column: x, yTop: yTop)
                let expected = program.coverage(at: SIMD2(point.x, point.y)) { index, at in
                    if case .brush = program.rasters[index] { return field.value(at: at) }
                    return v
                }
                composed = max(composed, abs(values[yTop * size.width + x] - expected))
                single = max(single, abs(alone[yTop * size.width + x] - v))
                complement = max(complement, abs(inverted[yTop * size.width + x] - (1 - v)))
            }
        }
        MaskRender.report("feathered slices against the CPU: alone \(single), inverted \(complement), less a brush \(composed)")
        #expect(single < 0.003 && complement < 0.003 && composed < 0.003)
        // Per pixel the kernels read the slice, not the pixel's own light: the probe is the slice's bilinear read, which is smooth.
        let probe = try Refine.probe(p.gpu, p.frame, scene, slot: 0)
        var jump: Float = 0
        for row in stride(from: 1, to: p.height - 1, by: 2) {
            for column in 1..<(p.width - 1) { jump = max(jump, abs(probe[row * p.width + column] - probe[row * p.width + column - 1])) }
        }
        // No step between neighbours is steeper than the blur allows: a Gaussian of σ px rises at most 1 / (σ √2π) a pixel.
        let pixels = MaskFeather.sigma(30) * Float(p.width), steepest = 1 / (pixels * (2 * Float.pi).squareRoot())
        MaskRender.report("feathered probe: largest step between neighbours \(jump), a blur of σ \(pixels) px allows \(steepest)")
        #expect(jump <= steepest * 1.05)
    }

    /// Moving a Feather rebakes that mask's field and nothing else: no other mask's field, no refinement and no table. A slider on the
    /// feathered mask rebakes nothing. The refiner keeps no feathered field, so a drag does not push its coefficients out.
    @Test func featherRebakesOnlyItsMask() throws {
        let p = try Phantom(width: 1200, height: 800)
        let renderer = try FilmRenderer(gpu: p.gpu, stock: LightCompilerBaselineTests.toyStock())
        let radial = MaskRender.mask(MaskRender.radial(0.5, 0.33, 0.3, 0.2, feather: 40), try ManualAdjustments(shadows: 30))
        func settings(_ feather: Float, exposure: Float = -1.5) throws -> DevelopSettings {
            DevelopSettings(manual: try MaskRender.manual(masks: [
                radial, Mask(id: MaskFeatherModelTestsID.sky, components: [try p.sky(feather)], adjustments: try ManualAdjustments(exposureEV: exposure))]))
        }
        _ = try renderer.render(p.frame, settings: try settings(20))
        let refiner = p.gpu.maskRefiner.statistics, fields = p.gpu.maskFields.statistics, tables = renderer.localTablesBuilt
        let resident = p.gpu.maskRefiner.residentBytes
        #expect(refiner.feathers == 1 && fields.bakes == 2)
        for (step, feather) in [Float(21), 35, 60].enumerated() {
            _ = try renderer.render(p.frame, settings: try settings(feather))
            let now = p.gpu.maskFields.statistics
            #expect(now.bakes == fields.bakes + step + 1, "one bake a step")
            #expect(p.gpu.maskRefiner.statistics.builds == refiner.builds && p.gpu.maskRefiner.statistics.feathers == refiner.feathers + step + 1)
            #expect(renderer.localTablesBuilt == tables)
            #expect(p.gpu.maskRefiner.residentBytes == resident, "nothing feathered is kept")
        }
        // A slider and Amount on the feathered mask: nothing baked, blurred or built.
        let before = (p.gpu.maskFields.statistics.bakes, p.gpu.maskRefiner.statistics)
        _ = try renderer.render(p.frame, settings: try settings(60, exposure: 0.8))
        #expect(p.gpu.maskFields.statistics.bakes == before.0 && p.gpu.maskRefiner.statistics.feathers == before.1.feathers
                && p.gpu.maskRefiner.statistics.builds == before.1.builds && renderer.localTablesBuilt == tables)
        // Back to Feather 0: the refined field is still kept, so nothing is refined again, and the mask is tier 2 again.
        _ = try renderer.render(p.frame, settings: try settings(0))
        #expect(p.gpu.maskRefiner.statistics.builds == refiner.builds)
        // A develop's peak counts a feathered field and its pass, 16.8 MB on a 3:2 frame.
        let set = { (f: Float) in try MaskSet(masks: [Mask(components: [try p.sky(f)], adjustments: try ManualAdjustments(exposureEV: -1))]) }
        #expect(try MaskRefiner.developBytes(masks: set(40), picture: Self.picture) - MaskRefiner.developBytes(masks: set(0), picture: Self.picture)
                == 2048 * 1365 * 6)
    }
}

/// Preview against develop (deliverable 4): a feathered selection reads the same blurred slice on every surface, so on a smooth picture
/// the print agrees as a gradient's does, within the plan's 0.1 L*.
@Suite struct MaskFeatherPreviewTests {
    private static let picture = try! MaskSpace(width: 7008, height: 4672)

    /// Phase 1's smooth scene for gradients, with an edge for a selection to find: a sky brightening toward a wavy horizon over a darker
    /// ground, the horizon anti-aliased from 4 × 4 samples a pixel; its true matte, row 0 the bottom.
    static func horizon(width: Int, height: Int) -> (pixels: [SIMD3<Float>], matte: [Float]) {
        var pixels = [SIMD3<Float>](repeating: .zero, count: width * height), matte = [Float](repeating: 0, count: width * height)
        for yTop in 0..<height {
            let row = (height - 1 - yTop) * width, t = Float(yTop) / Float(height)
            for x in 0..<width {
                var open = 0
                for sy in 0..<4 {
                    for sx in 0..<4 {
                        let u = (Float(x) + (Float(sx) + 0.5) / 4) / Float(width), v = (Float(yTop) + (Float(sy) + 0.5) / 4) / Float(height)
                        if v < 0.5 + 0.06 * sin(2 * .pi * 2.5 * u) { open += 1 }
                    }
                }
                let m = Float(open) / 16, u = Float(x) / Float(width)
                let skyLight = Refine.sky * (0.7 + 0.8 * t) * (0.95 + 0.1 * u), groundLight = SIMD3<Float>(0.09, 0.075, 0.05) * (1.4 - 0.6 * t)
                pixels[row + x] = m * skyLight + (1 - m) * groundLight
                matte[row + x] = m
            }
        }
        return (pixels, matte)
    }

    /// The scene at a develop's size and at the frame view's and the sheet's, each smaller one area-averaged from the develop as the frame
    /// view's refined decode is, through the film with halation, Sky at −1.5 EV, against a linear gradient of the same darkening across
    /// the horizon. A pixel's |ΔL*| is the preview's against the develop area-averaged to it: p99 over every pixel, and its excess over
    /// the same with no mask. Feathered, at every size, within the plan's 0.1 L* excess for gradients; Feather 0 (tier 2) is reported.
    @Test func aFeatheredPreviewAgreesWithTheDevelop() throws {
        let gpu = try GPU()
        let (width, height) = (2400, 1600)
        let scene = Self.horizon(width: width, height: height)
        let raster = try Refine.seed(matte: scene.matte, width: width, height: height, seedWidth: 378, seedHeight: 252, binary: true)
        gpu.maskRefiner.seeds = Refine.Seeds([raster])
        let frame = try MaskRender.frame(gpu, scene.pixels, width: width, picture: Self.picture)
        let resize = try AreaResize(gpu: gpu)
        func resized(_ texture: MTLTexture, _ width: Int, _ height: Int) throws -> MTLTexture {
            let out = try gpu.makeTexture(width: width, height: height)
            let commandBuffer = try #require(gpu.queue.makeCommandBuffer())
            try resize.encode(texture, to: out, into: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return out
        }
        func p99(_ values: [Float]) -> Float {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, sorted.count * 99 / 100)]
        }
        let previews = try [(2190, 1460), (960, 640)].map { size in
            LinearFrame(image: PooledTexture(unpooled: try resized(frame.texture, size.0, size.1)), decoderVersion: "mask-test",
                        scale: Float(size.0) / Float(width), picture: Self.picture)
        }
        let all = try MaskRender.stocks(), stocks = [all[0]] + all.filter { $0.id == "kodak-portra-400" }
        let exposure = try ManualAdjustments(exposureEV: -1.5)
        let gradient = Mask(components: [MaskRender.linear(0.5, 0.15, 0.5, 0.45)], adjustments: exposure)
        let cases: [(String, Mask)] = try [("gradient", gradient)] + [Float(0), 25, 50, 100].map { feather in
            ("feather \(Int(feather))", Mask(components: [MaskFeatherRenderTests.feathered(try Refine.component(.sky, raster), feather)], adjustments: exposure))
        }
        for stock in stocks {
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            let plain = DevelopSettings(halation: stock.halation != nil, manual: try MaskRender.manual(reference: 0.2))
            let developPlain = try renderer.render(frame, settings: plain)
            for (name, mask) in cases {
                let settings = DevelopSettings(halation: stock.halation != nil, manual: try MaskRender.manual(masks: [mask], reference: 0.2))
                let develop = try renderer.render(frame, settings: settings)
                for preview in previews {
                    let (w, h) = (preview.width, preview.height)
                    let a = MaskRender.read(try resized(develop.image.texture, w, h)), b = MaskRender.read(try renderer.render(preview, settings: settings).image.texture)
                    let a0 = MaskRender.read(try resized(developPlain.image.texture, w, h)), b0 = MaskRender.read(try renderer.render(preview, settings: plain).image.texture)
                    var masked: [Float] = [], film: [Float] = []
                    for i in a.indices {
                        masked.append(abs(MaskRender.lightness(a[i]) - MaskRender.lightness(b[i])))
                        film.append(abs(MaskRender.lightness(a0[i]) - MaskRender.lightness(b0[i])))
                    }
                    let excess = p99(masked) - p99(film)
                    MaskRender.report("preview against develop, \(name), \(stock.id) at \(w): p99 \(p99(masked)) (no mask \(p99(film))), excess \(excess)")
                    if name.hasPrefix("feather"), name != "feather 0" {
                        #expect(excess <= 0.1, "\(name), \(stock.id) at \(w): excess \(excess)")
                    }
                }
            }
        }
    }
}

/// A fixed id for the feathered mask, so its slot's owner is the same mask from render to render.
enum MaskFeatherModelTestsID {
    static let sky = UUID(uuid: (9, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 9))
}
