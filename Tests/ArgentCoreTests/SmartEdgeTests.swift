import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Fixtures shared by the edge suites: a picture's selection on a given edge, and a soft alpha at a print's size.
enum Edge {
    static let picture = try! MaskSpace(width: 7008, height: 4672)
    static let frame = try! MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
    static func id(_ n: UInt8) -> UUID { UUID(uuid: (n, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, n)) }

    static func selection(_ kind: SmartKind = .subject, _ raster: RasterRef, edge: SmartEdge, feather: Float = 0) -> SmartSelection {
        SmartSelection(kind: kind, raster: raster, frame: frame, feather: feather, edge: edge)
    }
    static func component(_ kind: SmartKind = .subject, _ raster: MaskRaster, edge: SmartEdge, feather: Float = 0, invert: Bool = false,
                          operation: MaskOperation = .add) -> MaskComponent {
        MaskComponent(operation: operation, shape: .smart(selection(kind, raster.ref, edge: edge, feather: feather)), invert: invert)
    }
    static func ref(_ byte: UInt8 = 0xab, width: Int = 2560, height: Int = 1709) throws -> RasterRef {
        try RasterRef(id: #require(RasterID(hex: String(repeating: String(format: "%02x", byte), count: 32))), width: width, height: height)
    }
    static func set(_ selection: SmartSelection) throws -> MaskSet {
        try MaskSet(masks: [Mask(id: id(1), components: [MaskComponent(shape: .smart(selection))])])
    }
    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func decode(_ text: String) throws -> MaskSet { try JSONDecoder().decode(MaskSet.self, from: Data(text.utf8)) }

    /// A soft raster with structure at every scale: what a matte's band is, not the flat ramp a sampler flatters.
    static func alpha(width: Int, height: Int) throws -> MaskRaster {
        var plane = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let v = 0.5 + 0.28 * sin(Float(x) / 37) * cos(Float(y) / 23) + 0.22 * sin(Float(x + y) / 5.5)
                plane[y * width + x] = UInt8(min(max(v * 255, 0), 255).rounded())
            }
        }
        return try MaskRaster(width: width, height: height, plane: plane)
    }

    /// `raster`'s value by the sampler's arithmetic at `uv`, row 0 the picture's bottom as `uv` counts it: bilinear, edges clamped.
    static func bilinear(_ raster: MaskRaster, uv: SIMD2<Float>) -> Float {
        let sx = uv.x * Float(raster.width) - 0.5, sy = uv.y * Float(raster.height) - 0.5
        let x0 = min(max(Int(sx.rounded(.down)), 0), raster.width - 1), x1 = min(x0 + 1, raster.width - 1)
        let y0 = min(max(Int(sy.rounded(.down)), 0), raster.height - 1), y1 = min(y0 + 1, raster.height - 1)
        let tx = min(max(sx - sx.rounded(.down), 0), 1), ty = min(max(sy - sy.rounded(.down), 0), 1)
        func at(_ x: Int, _ y: Int) -> Float { Float(raster.plane[(raster.height - 1 - y) * raster.width + x]) / 255 }
        let low = at(x0, y0) + (at(x1, y0) - at(x0, y0)) * tx, high = at(x0, y1) + (at(x1, y1) - at(x0, y1)) * tx
        return low + (high - low) * ty
    }

    /// Two very different pictures of the same shape, for what must not read the decode.
    static func pictures(width: Int, height: Int) -> [[SIMD3<Float>]] {
        let scene = Refine.scene(width: width, height: height).pixels
        var noise = [SIMD3<Float>](repeating: .zero, count: width * height), generator = SystemRandomNumberGenerator()
        for i in noise.indices { noise[i] = SIMD3(Float.random(in: -0.02...3000, using: &generator), Float.random(in: 0...0.0002, using: &generator), Float.random(in: 0...1.5, using: &generator)) }
        return [scene, noise]
    }
}

/// The record: `edge` written only when not `guided`, with masks schema 4; a build that cannot read 4 refuses and keeps the record.
@Suite struct SmartEdgeRecordTests {
    @Test func aSelectionOnTodaysPathWritesNoEdge() throws {
        let selection = Edge.selection(.subject, try Edge.ref(width: 512, height: 512), edge: .guided)
        let text = try Edge.json(try Edge.set(selection))
        #expect(!text.contains("edge") && text.contains(#""schema":1"#))
        // Written and defaulted are one record, one digest.
        #expect(try Edge.set(selection).digest == Edge.set(SmartSelection(kind: .subject, raster: selection.raster, frame: selection.frame)).digest)
    }

    @Test func aCrispOrMatteSelectionIsSchemaFourAndReadsBack() throws {
        for edge in [SmartEdge.crisp, .matte] {
            let set = try Edge.set(Edge.selection(.subject, try Edge.ref(), edge: edge))
            let text = try Edge.json(set)
            #expect(text.contains(#""schema":4"#) && text.contains("\"edge\":\"\(edge.rawValue)\""), "\(edge)")
            let read = try Edge.decode(text)
            #expect(read == set && read.digest == set.digest, "\(edge)")
            #expect(MaskSet.schema(of: read.masks) == 4)
            // A receipt's digest holds no field an older build would drop.
            #expect(try Edge.json(set.digestOnly).contains(#""schema":1"#))
        }
        #expect(MaskSet.schema == 6)
    }

    /// Schema 4 outranks the fields under it; a selection on today's path stays at the schema its other fields need.
    @Test func theSchemaIsWhatTheRecordNeeds() throws {
        let ref = try Edge.ref()
        func schema(_ selection: SmartSelection) throws -> Int { MaskSet.schema(of: try Edge.set(selection).masks) }
        #expect(try schema(Edge.selection(.subject, ref, edge: .guided)) == 1)
        #expect(try schema(Edge.selection(.subject, ref, edge: .guided, feather: 30)) == 2)
        #expect(try schema(Edge.selection(.subject, ref, edge: .crisp, feather: 30)) == 4)
        #expect(try schema(Edge.selection(.background, ref, edge: .matte)) == 4)
    }

    /// An edge under a schema that cannot name it is what an older build would have dropped: refused and kept, as a Feather under 2 is.
    @Test func anEdgeBelowSchemaFourOrPastItIsRefused() throws {
        let text = try Edge.json(try Edge.set(Edge.selection(.subject, try Edge.ref(), edge: .matte)))
        for lower in 1...3 {
            let at = text.replacingOccurrences(of: #""schema":4"#, with: "\"schema\":\(lower)")
            #expect(throws: MaskError.self) { try Edge.decode(at) }
        }
        #expect(throws: MaskError.unsupportedSchema(7)) { try Edge.decode(text.replacingOccurrences(of: #""schema":4"#, with: #""schema":7"#)) }
        // A kind of edge this build does not know fails the read, so the record is preserved and never read as another.
        #expect(throws: (any Error).self) { try Edge.decode(text.replacingOccurrences(of: #""edge":"matte""#, with: #""edge":"painted""#)) }
    }

    /// Person, Sky and a selection not made yet have today's edge and no other.
    @Test func onlyAMadeSubjectOrBackgroundTakesAnEdge() throws {
        let ref = try Edge.ref()
        for kind in [SmartKind.sky, .person] {
            #expect(throws: MaskError.self) { try Edge.set(Edge.selection(kind, ref, edge: .crisp)) }
            #expect(throws: MaskError.self) { try Edge.set(Edge.selection(kind, ref, edge: .matte)) }
        }
        #expect(throws: MaskError.self) { try Edge.set(SmartSelection(kind: .subject, edge: .matte)) }
        #expect(throws: Never.self) { _ = try Edge.set(Edge.selection(.background, ref, edge: .crisp)) }
        let unmadeText = #"{"schema":4,"version":"\#(MaskSet.currentVersion)","list":[{"id":"00000000-0000-0000-0000-000000000000","isEnabled":true,"amount":1,"adjustments":{},"components":[{"operation":"add","invert":false,"shape":{"type":"smart","smart":{"kind":"subject","edge":"crisp"}}}]}]}"#
        #expect(throws: (any Error).self) { try Edge.decode(unmadeText) }
    }

    /// Part of the digest, and of the render key, only when set; the digest of a selection on today's path is the one it had (golden).
    @Test func anEdgeMovesTheDigestAndTheFieldKey() throws {
        let ref = try Edge.ref()
        let digests = try [SmartEdge.guided, .crisp, .matte].map { try Edge.set(Edge.selection(.subject, ref, edge: $0)).digest }
        #expect(Set(digests).count == 3)
        func identity(_ edge: SmartEdge) throws -> String {
            try MaskSlots(masks: try Edge.set(Edge.selection(.subject, ref, edge: edge)), picture: Edge.picture, guide: MaskGuideID(serial: 1, width: 2, height: 3)).identity
        }
        #expect(try Set([identity(.guided), identity(.crisp), identity(.matte)]).count == 3)
    }

    /// A selection is a measurement of the picture it was made on: Copy and Reapply clear its seed, and with it the edge the click decided.
    /// The Feather is the user's and stays.
    @Test func anotherPictureClearsTheEdgeWithTheSeed() throws {
        let set = try Edge.set(Edge.selection(.subject, try Edge.ref(), edge: .matte, feather: 30))
        for fresh in [true, false] {
            let cleared = try set.forAnotherPicture(freshIDs: fresh)
            guard case .smart(let selection) = cleared.masks[0].components[0].shape else { Issue.record("not a selection"); continue }
            #expect(selection.raster == nil && selection.frame == nil && selection.edge == .guided && selection.feather == 30)
            #expect(MaskSet.schema(of: cleared.masks) == 2)
        }
    }

    /// The raster names the same pixels whatever the edge, and every raster a set names is collected: a matte's alpha among them.
    @Test func aMatteRasterIsCollectedAndAPrintSizedOneFits() throws {
        let ref = try Edge.ref()
        #expect(RasterRef.sideRange.contains(2560) && RasterRef.sideRange.contains(1709))
        let set = try Edge.set(Edge.selection(.subject, ref, edge: .matte))
        #expect(set.rasters == [ref])
        let manual = try ManualRenderSettings(adjustments: ManualAdjustments.identity.settingMasks(
            try MaskSet(masks: [Mask(components: set.masks[0].components, adjustments: try ManualAdjustments(exposureEV: -1))])), referenceStops: 0)
        #expect(MaskSeeds.needs(manual).rasters == [ref])
    }
}

/// `.crisp`: V7's frozen edge, the filter on a 1024 S3OD seed with radius 0.008, ε 0.02, then a contrast of 2 on the finished coefficients.
@Suite struct CrispEdgeTests {
    @Test func theConstantsAreFrozen() {
        let crisp = MaskRefineParameters.crisp
        #expect(crisp.radiusShare == 0.008 && crisp.epsilon == 0.02 && crisp.grid == 1 && crisp.contrast == 2)
        #expect(crisp.radius(seedWidth: 1024, seedHeight: 683) == 8 && crisp.radius(seedWidth: 512, seedHeight: 512) == 4)
        // Today's Subject takes the same filter and no contrast.
        #expect(MaskRefineParameters.of(.subject).contrast == 1)
        let guided = SmartSelection(kind: .subject), crispSelection = SmartSelection(kind: .subject, edge: .crisp)
        #expect(MaskRefineParameters.of(guided) == MaskRefineParameters.subject && MaskRefineParameters.of(crispSelection) == .crisp)
    }

    /// Exactly a ← 2a and b ← 2b − 0.5 on the finished coefficients: the slopes are doubled texel for texel, and the bias within the half
    /// float's rounding of 2b − 0.5, which the kernel writes back as a half float (V5's own pass).
    @Test func theContrastIsThereOnTheFinishedCoefficients() throws {
        let gpu = try GPU()
        let (pixels, matte) = Refine.scene(width: 1536, height: 1024)
        let frame = try MaskRender.frame(gpu, pixels, width: 1536)
        let raster = try Refine.seed(matte: matte, width: 1536, height: 1024, seedWidth: 1024, seedHeight: 683, binary: true)
        let plain = Refine.coefficients(try gpu.maskRefiner.build(seed: try gpu.maskRefiner.upload(raster), guideFrame: frame.texture, parameters: .subject).texture)
        let built = try gpu.maskRefiner.build(seed: try gpu.maskRefiner.upload(raster), guideFrame: frame.texture, parameters: .crisp)
        #expect(built.build.radius == 8 && built.build.seedWidth == 1024)
        let contrast = Refine.coefficients(built.texture)
        var slopes: Float = 0, bias: Float = 0
        for (p, c) in zip(plain, contrast) {
            slopes = max(slopes, abs(c.x - 2 * p.x), abs(c.y - 2 * p.y), abs(c.z - 2 * p.z))
            bias = max(bias, abs(c.w - (2 * p.w - 0.5)))
        }
        MaskRender.report("crisp contrast: slopes off by \(slopes), bias \(bias)")
        #expect(slopes == 0)
        #expect(bias < 0.001)
    }

    /// The contrast about 0.5 on each surface: a pixel's coverage is the crisp field's value at the crisp coefficients, tier 2 and tier 1 alike.
    @Test func crispRendersThroughBothTiers() throws {
        let gpu = try GPU()
        let (pixels, matte) = Refine.scene(width: 2400, height: 1600)
        let raster = try Refine.seed(matte: matte, width: 2400, height: 1600, seedWidth: 1024, seedHeight: 683, binary: true)
        gpu.maskRefiner.seeds = Refine.Seeds([raster])
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let frame = try MaskRender.frame(gpu, pixels, width: 2400, picture: Edge.picture)
        let exposure = try ManualAdjustments(exposureEV: -1.5)
        let settings = DevelopSettings(manual: try MaskRender.manual(masks: [Mask(components: [Edge.component(.subject, raster, edge: .crisp)], adjustments: exposure)]))
        let scene = try Refine.scene(renderer, frame, settings)
        let k = Refine.coefficients(try #require(scene.masks?.refinedCoefficients[0]))
        let probe = try Refine.probe(gpu, frame, scene, slot: 0)
        var worst: Float = 0
        for i in stride(from: 0, to: 2400 * 1600, by: 5) {
            let uv = SIMD2<Float>((Float(i % 2400) + 0.5) / 2400, (Float(i / 2400) + 0.5) / 1600)
            worst = max(worst, abs(probe[i] - MaskRefiner.refined(k, width: 1024, height: 683, uv: uv, rgb: MaskRender.half(pixels[i]))))
        }
        MaskRender.report("crisp tier 2 against the CPU: \(worst)")
        #expect(worst < 0.003)
        #expect(gpu.maskRefiner.statistics.builds == 1)
    }

    @Test func aLostSeedRefuses() throws {
        let gpu = try GPU()
        gpu.maskRefiner.seeds = Refine.Seeds([])
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let frame = try MaskRender.frame(gpu, Refine.scene(width: 1200, height: 800).pixels, width: 1200, picture: Edge.picture)
        let raster = try Refine.constant(200, width: 1024, height: 683)
        let settings = DevelopSettings(manual: try MaskRender.manual(masks: [Mask(components: [Edge.component(.subject, raster, edge: .crisp)], adjustments: try ManualAdjustments(exposureEV: -1))]))
        #expect(throws: MaskRefinerError.seedUnavailable(raster.identity)) { try renderer.render(frame, settings: settings) }
    }
}

/// `.matte`: the stored alpha, no filter, every surface sampling one `r8Unorm` texture bilinearly; no guide frame and no working set are made.
@Suite struct MatteEdgeTests {
    private func setup(width: Int = 1200, height: Int = 800, alpha: (Int, Int) = (2560, 1707)) throws -> (GPU, FilmRenderer, MaskRaster, [SIMD3<Float>]) {
        let gpu = try GPU()
        let raster = try Edge.alpha(width: alpha.0, height: alpha.1)
        gpu.maskRefiner.seeds = Refine.Seeds([raster])
        return (gpu, try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock()), raster, Refine.scene(width: width, height: height).pixels)
    }

    private func masked(_ component: MaskComponent, exposure: Float = -1.5) throws -> DevelopSettings {
        DevelopSettings(manual: try MaskRender.manual(masks: [Mask(components: [component], adjustments: try ManualAdjustments(exposureEV: exposure))]))
    }

    /// Tier 2: a pixel's coverage is the alpha sampled bilinearly at its uv. Nothing was built, and the texture is 8 bits.
    @Test func tierTwoIsTheAlphaSampledAtThePixel() throws {
        let (gpu, renderer, raster, pixels) = try setup(width: 2400, height: 1600)
        let frame = try MaskRender.frame(gpu, pixels, width: 2400, picture: Edge.picture)
        let scene = try Refine.scene(renderer, frame, try masked(Edge.component(.subject, raster, edge: .matte)))
        let masks = try #require(scene.masks)
        #expect(masks.refinement.refined == 1)
        #expect(masks.refinedCoefficients[0]?.pixelFormat == .r8Unorm)
        let probe = try Refine.probe(gpu, frame, scene, slot: 0)
        var worst: Float = 0
        for i in stride(from: 0, to: 2400 * 1600, by: 5) {
            let uv = SIMD2<Float>((Float(i % 2400) + 0.5) / 2400, (Float(i / 2400) + 0.5) / 1600)
            worst = max(worst, abs(probe[i] - Edge.bilinear(raster, uv: uv)))
        }
        MaskRender.report("matte tier 2 against the CPU's bilinear: \(worst)")
        #expect(worst < 0.004)
        #expect(gpu.maskRefiner.statistics.builds == 0 && gpu.maskRefiner.statistics.guideFrames == 0)
        #expect(gpu.maskRefiner.statistics.lastBuild == nil)
    }

    /// Tier 1 for a sheet: the slice is the alpha sampled at each texel's uv, kept in nothing past the render, and no guide frame made.
    @Test func tierOneIsTheAlphaSampledAtTheTexel() throws {
        let (gpu, renderer, raster, _) = try setup(width: 960, height: 640)
        let frame = try MaskRender.frame(gpu, Refine.scene(width: 960, height: 640).pixels, width: 960, picture: Edge.picture)
        let scene = try Refine.scene(renderer, frame, try masked(Edge.component(.subject, raster, edge: .matte)))
        let masks = try #require(scene.masks)
        #expect(masks.refinement.refined == 0)
        let size = masks.coverage.slots.size, field = masks.coverage.values(slot: 0)
        var worst: Float = 0
        for yTop in stride(from: 0, to: size.height, by: 3) {
            for x in stride(from: 0, to: size.width, by: 3) {
                let row = size.height - 1 - yTop
                let uv = SIMD2<Float>((Float(x) + 0.5) / Float(size.width), (Float(row) + 0.5) / Float(size.height))
                worst = max(worst, abs(field[yTop * size.width + x] - Edge.bilinear(raster, uv: uv)))
            }
        }
        MaskRender.report("matte tier 1 against the CPU's bilinear: \(worst)")
        #expect(worst < 0.004)
        #expect(gpu.maskRefiner.statistics.builds == 0 && gpu.maskRefiner.statistics.guideFrames == 0)
        #expect(gpu.maskRefiner.residentBytes == 0)
    }

    /// Guide independence, bit for bit: on two very different pictures, the matte's coverage is the same, per pixel and in the slice.
    @Test func noMatteReadsThePicture() throws {
        let (gpu, renderer, raster, _) = try setup()
        var perPixel: [[Float]] = [], fields: [[Float]] = []
        for pixels in Edge.pictures(width: 1200, height: 800) {
            let frame = try MaskRender.frame(gpu, pixels, width: 1200, picture: Edge.picture)
            let scene = try Refine.scene(renderer, frame, try masked(Edge.component(.subject, raster, edge: .matte)))
            perPixel.append(try Refine.probe(gpu, frame, scene, slot: 0))
            fields.append(try #require(scene.masks).coverage.values(slot: 0))
        }
        #expect(perPixel[0].withUnsafeBytes { Data($0) } == perPixel[1].withUnsafeBytes { Data($0) })
        #expect(fields[0].withUnsafeBytes { Data($0) } == fields[1].withUnsafeBytes { Data($0) })
        #expect(gpu.maskRefiner.statistics.builds == 0 && gpu.maskRefiner.statistics.guideFrames == 0)
    }

    /// The same bits across sliders and stocks, on either edge: a matte's coverage is the stored alpha and a crisp edge's the filter on the untouched
    /// decode, whatever a slider, stock, grain or sharpening says, and nothing is built again.
    @Test(arguments: [SmartEdge.matte, .crisp])
    func theCoverageIsTheSameAcrossSlidersAndStocks(edge: SmartEdge) throws {
        let (gpu, _, alpha, pixels) = try setup()
        let raster = edge == .matte ? alpha : try Edge.alpha(width: 1024, height: 683)
        gpu.maskRefiner.seeds = Refine.Seeds([raster])
        let frame = try MaskRender.frame(gpu, pixels, width: 1200, picture: Edge.picture)
        var first: (probe: [Float], field: [Float])?
        for stock in try MaskRender.stocks() {
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            for (values, base) in [(try ManualAdjustments(exposureEV: -5), DevelopSettings()),
                                   (try ManualAdjustments(exposureEV: 1.5, highlights: -60, shadows: 40), DevelopSettings(grain: 1, grainSeed: 7, halation: true, sharpen: true))] {
                var settings = base
                settings.manual = try MaskRender.manual(masks: [Mask(components: [Edge.component(.subject, raster, edge: edge)], amount: 1.7, adjustments: values)])
                let scene = try Refine.scene(renderer, frame, settings)
                let now = (probe: try Refine.probe(gpu, frame, scene, slot: 0), field: try #require(scene.masks).coverage.values(slot: 0))
                if let first {
                    #expect(first.probe.withUnsafeBytes { Data($0) } == now.probe.withUnsafeBytes { Data($0) })
                    #expect(first.field.withUnsafeBytes { Data($0) } == now.field.withUnsafeBytes { Data($0) })
                } else { first = now }
            }
        }
        #expect(gpu.maskRefiner.statistics.builds == (edge == .matte ? 0 : 1))
    }

    /// Background is the alpha inverted; so is Invert; both tiers.
    @Test func backgroundAndInvertAreOneMinusTheAlpha() throws {
        let (gpu, renderer, raster, pixels) = try setup(width: 2400, height: 1600)
        let frame = try MaskRender.frame(gpu, pixels, width: 2400, picture: Edge.picture)
        let plain = try Refine.probe(gpu, frame, try Refine.scene(renderer, frame, try masked(Edge.component(.subject, raster, edge: .matte))), slot: 0)
        for component in [Edge.component(.background, raster, edge: .matte), Edge.component(.subject, raster, edge: .matte, invert: true)] {
            let scene = try Refine.scene(renderer, frame, try masked(component))
            #expect(try #require(scene.masks).refinement.invert == 1)
            let probe = try Refine.probe(gpu, frame, scene, slot: 0)
            var worst: Float = 0
            for i in probe.indices { worst = max(worst, abs(probe[i] - (1 - plain[i]))) }
            #expect(worst < 2e-5, "\(worst)")
            let toned = try Refine.scene(renderer, frame, DevelopSettings(manual: try MaskRender.manual(masks: [Mask(components: [component], adjustments: try ManualAdjustments(highlights: -40))])))
            #expect(try #require(toned.masks).refinement.refined == 0)
        }
    }

    /// Feather blurs the same field a selection on today's path blurs, and takes tier 1; composing with a brush is affine in the alpha, tier 2.
    @Test func featherAndComposition() throws {
        let (gpu, renderer, raster, pixels) = try setup(width: 2400, height: 1600)
        let frame = try MaskRender.frame(gpu, pixels, width: 2400, picture: Edge.picture)
        let feathered = try Refine.scene(renderer, frame, try masked(Edge.component(.subject, raster, edge: .matte, feather: 30)))
        #expect(try #require(feathered.masks).refinement.refined == 0)
        #expect(gpu.maskRefiner.statistics.feathers == 1)
        let plain = try #require(try Refine.scene(renderer, frame, DevelopSettings(manual: try MaskRender.manual(masks: [Mask(components: [Edge.component(.subject, raster, edge: .matte)], adjustments: try ManualAdjustments(highlights: -40))]))).masks)
        let size = plain.coverage.slots.size
        let cpu = MaskFeather.blurred(plain.coverage.values(slot: 0), width: size.width, height: size.height, feather: 30)
        let got = try #require(feathered.masks).coverage.values(slot: 0)
        var worst: Float = 0
        for i in stride(from: 0, to: got.count, by: 3) { worst = max(worst, abs(got[i] - cpu[i])) }
        MaskRender.report("matte feather against the CPU: \(worst)")
        #expect(worst < 0.002)
        let stroke = BrushStroke(radius: 0.04, feather: 1, flow: 0.8, points: try PackedPoints.pack([MaskPoint(x: 0.4, y: 0.3), MaskPoint(x: 0.6, y: 0.4)]))
        let composed = try Refine.scene(renderer, frame, DevelopSettings(manual: try MaskRender.manual(masks: [
            Mask(components: [Edge.component(.subject, raster, edge: .matte), MaskComponent(operation: .subtract, shape: .brush(BrushPaint(frame: Edge.frame, strokes: [stroke])))],
                 adjustments: try ManualAdjustments(exposureEV: -1.5))])))
        let inputs = try #require(composed.masks)
        #expect(inputs.refinement.refined == 1 && inputs.refinement.composed == 1)
        let probe = try Refine.probe(gpu, frame, composed, slot: 0), brushed = BrushField([stroke])
        worst = 0
        for i in stride(from: 0, to: probe.count, by: 7) {
            let column = i % 2400, row = i / 2400
            let uv = SIMD2<Float>((Float(column) + 0.5) / 2400, (Float(row) + 0.5) / 1600)
            let point = try MaskSpace(width: 2400, height: 1600).point(column: column, yTop: 1599 - row)
            worst = max(worst, abs(probe[i] - Edge.bilinear(raster, uv: uv) * (1 - brushed.value(at: SIMD2(point.x, point.y)))))
        }
        MaskRender.report("matte composed with a brush against the CPU: \(worst)")
        #expect(worst < 0.006)
    }

    /// A lost alpha refuses, on either tier.
    @Test func aLostAlphaRefuses() throws {
        let gpu = try GPU()
        gpu.maskRefiner.seeds = Refine.Seeds([])
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let raster = try Refine.constant(200, width: 2560, height: 1707)
        for (width, height) in [(1200, 800), (960, 640)] {
            let frame = try MaskRender.frame(gpu, Refine.scene(width: width, height: height).pixels, width: width, picture: Edge.picture)
            #expect(throws: MaskRefinerError.seedUnavailable(raster.identity)) {
                try renderer.render(frame, settings: try masked(Edge.component(.subject, raster, edge: .matte)))
            }
        }
    }

    /// One alpha for every decode: a second decode of the same picture builds nothing new and reads the same field.
    @Test func everyDecodeOfThePictureSharesOneAlpha() throws {
        let (gpu, renderer, raster, pixels) = try setup()
        let settings = try masked(Edge.component(.subject, raster, edge: .matte))
        _ = try renderer.render(try MaskRender.frame(gpu, pixels, width: 1200, picture: Edge.picture), settings: settings)
        let resident = gpu.maskRefiner.residentBytes, bakes = gpu.maskFields.statistics.bakes
        _ = try renderer.render(try MaskRender.frame(gpu, pixels, width: 1200, picture: Edge.picture), settings: settings)
        #expect(gpu.maskRefiner.residentBytes == resident && gpu.maskFields.statistics.bakes == bakes)
        // Its bytes are its own: an r8 alpha and an r16 field.
        let kept = 2560 * 1707 + 2048 * 1365 * 2
        // As Metal allocates them: 0.8 MB of alignment on the two.
        #expect(resident >= kept && resident < kept + (1 << 20), "\(resident)")
    }

    /// Q's sharp overlay reads the print's own coverage.
    @Test func theSharpOverlayIsThePrintsCoverage() throws {
        let (gpu, renderer, raster, pixels) = try setup(width: 2400, height: 1600)
        let frame = try MaskRender.frame(gpu, pixels, width: 2400, picture: Edge.picture)
        let mask = Mask(components: [Edge.component(.subject, raster, edge: .matte)], adjustments: try ManualAdjustments(exposureEV: 1))
        let region = try #require(MaskRegion(frameWidth: 2400, frameHeight: 1600, left: 0.1, top: 0.2, right: 0.6, bottom: 0.7))
        let values = try gpu.regionCoverage(of: mask, on: frame, region: region)
        let scene = try Refine.scene(renderer, frame, DevelopSettings(manual: try MaskRender.manual(masks: [mask])))
        let probe = try Refine.probe(gpu, frame, scene, slot: 0)
        var worst = 0
        for row in 0..<region.height {
            let yTop = region.y + row
            for column in 0..<region.width {
                let expected = probe[(1600 - 1 - yTop) * 2400 + region.x + column]
                worst = max(worst, abs(Int(values[row * region.width + column]) - Int((expected * 255).rounded())))
            }
        }
        #expect(worst <= 1, "\(worst)")
    }

    /// What the develop's gate counts: the alpha and its field, and no guide frame or working set for a set of nothing but mattes.
    @Test func aDevelopCountsTheAlphaAndNoFilter() throws {
        let raster = try Edge.ref(width: 2560, height: 1707)
        let picture = Edge.picture, field = MaskFieldSize(picture: picture)
        let exposure = try ManualAdjustments(exposureEV: -1)
        let matte = try MaskSet(masks: [Mask(components: [MaskComponent(shape: .smart(Edge.selection(.subject, raster, edge: .matte)))], adjustments: exposure)])
        #expect(MaskRefiner.developBytes(masks: matte, picture: picture) == raster.width * raster.height + field.width * field.height * 2)
        // Background shares Subject's alpha.
        let both = try MaskSet(masks: [matte.masks[0], Mask(components: [MaskComponent(shape: .smart(Edge.selection(.background, raster, edge: .matte)))], adjustments: exposure)])
        #expect(MaskRefiner.developBytes(masks: both, picture: picture) == MaskRefiner.developBytes(masks: matte, picture: picture))
        // A crisp seed's coefficients are the guided filter's, at 1024: under a guide frame and one working set, with no extra pass held.
        let crisp = try MaskSet(masks: [Mask(components: [MaskComponent(shape: .smart(Edge.selection(.subject, try Edge.ref(width: 1024, height: 683), edge: .crisp)))], adjustments: exposure)])
        let guided = try MaskSet(masks: [Mask(components: [MaskComponent(shape: .smart(Edge.selection(.subject, try Edge.ref(width: 1024, height: 683), edge: .guided)))], adjustments: exposure)])
        #expect(MaskRefiner.developBytes(masks: crisp, picture: picture) == MaskRefiner.developBytes(masks: guided, picture: picture))
    }
}

/// A brush on a mask that holds a Subject, and Follow edges over one, on either edge: the stroke's overlay reads the same field the bake reads.
@Suite(.serialized) struct SmartEdgeBrushTests {
    @Test(arguments: [SmartEdge.crisp, .matte])
    func aStrokeOverASubjectPaintsAndRenders(edge: SmartEdge) throws {
        let gpu = try GPU()
        let raster = edge == .matte ? try Edge.alpha(width: 2560, height: 1707) : try Refine.constant(200, width: 1024, height: 683)
        gpu.maskRefiner.seeds = Refine.Seeds([raster])
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let frame = try Edges.frame(gpu)
        let paint = MaskComponent(shape: .brush(BrushPaint(frame: Edges.mframe)))
        let selected = Edge.component(.subject, raster, edge: edge, operation: .subtract)
        var mask = Mask(components: [paint, selected], adjustments: try ManualAdjustments(exposureEV: -1))
        for follow in [false, true] {
            let session = try Edges.session(gpu, cache: gpu.maskFields, frame: frame, mask: mask, follow: follow, seeds: Refine.Seeds([raster]))
            for point in Edges.along { try session.add(point) }
            var bytes = [UInt8](repeating: 0, count: 2048 * 1365)
            let region = try bytes.withUnsafeMutableBytes { try session.overlay(into: $0.baseAddress!, bytesPerRow: 2048) }
            #expect(region != nil)
            let stroke = try #require(try session.end())
            guard case .brush(var held) = mask.components[0].shape else { Issue.record("not a brush"); return }
            held.strokes.append(stroke)
            mask.components[0].shape = .brush(held)
        }
        let settings = DevelopSettings(manual: try MaskRender.manual(masks: [mask]))
        let scene = try Refine.scene(renderer, frame, settings)
        #expect(try #require(scene.masks).refinement.composed == 1)
        _ = try renderer.render(frame, settings: settings)
    }
}
