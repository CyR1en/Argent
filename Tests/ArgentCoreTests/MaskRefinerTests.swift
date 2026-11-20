import CryptoKit
import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Synthetic frames and seeds for `MaskRefiner`, and readers. The phantoms are R8's (section 13, row 8): thin lines of one to six
/// pixels, a baluster comb and a lattice against a sky, whose true matte is known, under a seed too coarse to hold them.
enum Refine {
    /// Seeds by id, as the app's store hands them over.
    struct Seeds: MaskSeedProvider {
        var rasters: [RasterID: MaskRaster] = [:]
        init(_ rasters: [MaskRaster]) { for raster in rasters { self.rasters[raster.identity] = raster } }
        func seed(for ref: RasterRef) throws -> MaskRaster {
            guard let raster = rasters[ref.id] else { throw CocoaError(.fileNoSuchFile) }
            return raster
        }
    }

    static let sky = SIMD3<Float>(0.20, 0.34, 0.72)
    static let ground = SIMD3<Float>(0.06, 0.05, 0.035)
    static let branch = SIMD3<Float>(0.035, 0.028, 0.02)

    static let thicknesses: [Float] = [1, 1.5, 2, 3, 4, 6]
    static func trunk(width: Int) -> (left: Float, right: Float) {
        let left = (0.18 * Float(width)).rounded()
        return (left, left + (26 * Float(width) / 2048).rounded())
    }
    /// The top of twig or wire `index`, on a whole pixel.
    static func twigTop(_ index: Int, height: Int) -> Float { ((0.25 + 0.05 * Float(index)) * Float(height)).rounded() }
    static func wireTop(_ index: Int, height: Int) -> Float { ((0.06 + 0.025 * Float(index)) * Float(height)).rounded() }

    /// Whether a point of a `width` by `height` picture (pixels, from the top left) lies on structure: the ground; a trunk with six twigs
    /// of 1 to 6 px growing from it, 80 px long, whose roots the seed's window sees beside the labelled trunk; six wires of the same
    /// widths in open sky, far from anything labelled; a baluster comb (3 px bars at a 12 px pitch) and a diagonal lattice (2 px
    /// members). Sizes scale with the width / 2048.
    static func structure(_ x: Float, _ y: Float, width: Int, height: Int) -> Bool {
        let s = Float(width) / 2048, w = Float(width), h = Float(height)
        if y > 0.66 * h { return true }
        let (left, right) = trunk(width: width)
        if x > left, x < right, y > 0.2 * h { return true }
        for (index, thickness) in thicknesses.enumerated() {
            let twig = twigTop(index, height: height), wire = wireTop(index, height: height)
            if x >= right, x < right + 80 * s, y >= twig, y < twig + thickness * s { return true }
            if x > 0.3 * w, x < 0.5 * w, y >= wire, y < wire + thickness * s { return true }
        }
        if x > 0.55 * w, x < 0.75 * w, y > 0.42 * h, (x - 0.55 * w).truncatingRemainder(dividingBy: 12 * s) < 3 * s { return true }
        if x > 0.78 * w, x < 0.97 * w, y > 0.1 * h, y < 0.4 * h {
            let p = 40 * s
            let a = (x + y).truncatingRemainder(dividingBy: p), b = (x - y + 4 * h).truncatingRemainder(dividingBy: p)
            if a < 2 * s || b < 2 * s { return true }
        }
        return false
    }

    /// The phantom: its light and its true sky matte, row 0 the picture's bottom as a texture's, from 4 × 4 samples a pixel, with a
    /// gentle gradient in the sky and the ground so the guide is not flat, and a little texture.
    static func scene(width: Int, height: Int) -> (pixels: [SIMD3<Float>], matte: [Float]) {
        var pixels = [SIMD3<Float>](repeating: .zero, count: width * height), matte = [Float](repeating: 0, count: width * height)
        for yTop in 0..<height {
            let row = (height - 1 - yTop) * width
            for x in 0..<width {
                var open = 0
                for sy in 0..<4 { for sx in 0..<4 where !structure(Float(x) + (Float(sx) + 0.5) / 4, Float(yTop) + (Float(sy) + 0.5) / 4,
                                                                    width: width, height: height) { open += 1 } }
                let m = Float(open) / 16
                let t = Float(yTop) / Float(height), ripple = 1 + 0.03 * sin(Float(x) * 0.37) * sin(Float(yTop) * 0.23)
                let skyLight = sky * (0.75 + 0.5 * t), structureLight = (yTop > height * 2 / 3 ? ground : branch) * ripple
                pixels[row + x] = m * skyLight + (1 - m) * structureLight
                matte[row + x] = m
            }
        }
        return (pixels, matte)
    }

    /// A seed of `seedWidth` by `seedHeight` from a matte (row 0 the bottom): the matte area-averaged to it, then held to 0 or 255 at
    /// one half (`binary`, as a model's label) or kept soft; top row first, as a store holds it. `shift` moves the matte right by frame
    /// pixels first, a seed misregistered by that much.
    static func seed(matte: [Float], width: Int, height: Int, seedWidth: Int, seedHeight: Int, binary: Bool, shift: Int = 0) throws -> MaskRaster {
        var plane = [UInt8](repeating: 0, count: seedWidth * seedHeight)
        for sy in 0..<seedHeight {
            for sx in 0..<seedWidth {
                let x0 = sx * width / seedWidth, x1 = max(x0 + 1, (sx + 1) * width / seedWidth)
                let y0 = sy * height / seedHeight, y1 = max(y0 + 1, (sy + 1) * height / seedHeight)
                var sum: Float = 0
                for y in y0..<y1 { for x in x0..<x1 { sum += matte[(height - 1 - y) * width + min(max(x - shift, 0), width - 1)] } }
                let mean = sum / Float((x1 - x0) * (y1 - y0))
                plane[sy * seedWidth + sx] = binary ? (mean >= 0.5 ? 255 : 0) : UInt8((mean * 255).rounded())
            }
        }
        return try MaskRaster(width: seedWidth, height: seedHeight, plane: plane)
    }

    static func constant(_ value: UInt8, width: Int = 64, height: Int = 48) throws -> MaskRaster {
        try MaskRaster(width: width, height: height, plane: [UInt8](repeating: value, count: width * height))
    }

    static func component(_ kind: SmartKind, _ raster: MaskRaster, invert: Bool = false, operation: MaskOperation = .add) throws -> MaskComponent {
        let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        return MaskComponent(operation: operation, shape: .smart(SmartSelection(kind: kind, raster: raster.ref, frame: frame)), invert: invert)
    }

    /// An `rgba16Float` texture's texels as floats, row 0 the texture's.
    static func coefficients(_ texture: MTLTexture) -> [SIMD4<Float>] {
        var halves = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        halves.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return (0..<(texture.width * texture.height)).map { SIMD4(Float(halves[$0 * 4]), Float(halves[$0 * 4 + 1]), Float(halves[$0 * 4 + 2]), Float(halves[$0 * 4 + 3])) }
    }

    /// Each pixel's coverage of `slot` as the masked kernels read it, tier 2 included (`local_mask_coverage_probe`), row 0 the bottom.
    static func probe(_ gpu: GPU, _ frame: LinearFrame, _ scene: ManualSceneInputs, slot: Int) throws -> [Float] {
        let masks = try #require(scene.masks)
        let count = frame.width * frame.height
        let buffer = try #require(gpu.device.makeBuffer(length: count * 4, options: .storageModeShared))
        let commandBuffer = try #require(gpu.queue.makeCommandBuffer()), encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(masks.pipelines.coverageProbe)
        masks.bind(to: encoder)
        encoder.setTexture(frame.texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        var index = UInt32(slot)
        encoder.setBytes(&index, length: 4, index: 1)
        encoder.dispatchPixels(masks.pipelines.coverageProbe, width: frame.width, height: frame.height)
        encoder.endEncoding()
        commandBuffer.commit()
        withExtendedLifetime((frame, scene)) { commandBuffer.waitUntilCompleted() }
        let values = buffer.contents().bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: values, count: count))
    }

    /// The scene inputs a render of `frame` would bind, from `renderer`.
    static func scene(_ renderer: FilmRenderer, _ frame: LinearFrame, _ settings: DevelopSettings) throws -> ManualSceneInputs {
        let stock = renderer.stock
        let rated = settings.exposureStops(boxSpeed: stock.boxSpeed)
        let offset = settings.printOffset(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
        return try renderer.sceneInputs(frame, settings: settings, exposureStops: rated, printOffset: offset).scene
    }

    static func p99(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Float(sorted.count) * 0.99))]
    }
}

/// The banded build (plan section 4, "Memory"; S3 part 2): the same coefficients as the unbanded build, value for value, in a working set
/// under 32 MiB, with the constants of the plan's table.
@Suite struct MaskRefinerBuildTests {
    @Test func theConstantsAreThePlansTable() {
        #expect(MaskRefineParameters.of(.sky).radius(seedWidth: 756, seedHeight: 504) == 6)
        #expect(MaskRefineParameters.of(.person).radius(seedWidth: 2016, seedHeight: 1512) == 8)
        #expect(MaskRefineParameters.of(.person).radius(seedWidth: 1512, seedHeight: 2016) == 8)
        #expect(MaskRefineParameters.of(.subject).radius(seedWidth: 512, seedHeight: 512) == 4)
        #expect(MaskRefineParameters.of(.background) == MaskRefineParameters.of(.subject))
        #expect(MaskRefineParameters.of(.sky).epsilon == 0.01 && MaskRefineParameters.of(.person).epsilon == 0.02
                && MaskRefineParameters.of(.subject).epsilon == 0.02)
        #expect(SmartKind.background.invertsSeed && !SmartKind.subject.invertsSeed && !SmartKind.sky.invertsSeed)
        // The plan's coefficient memory, rgba16Float: 2.9, 5.8 (the person matte on the coarser grid the plan allows; 23.3 on its own)
        // and 2.0 MiB.
        #expect(MaskRefineParameters.of(.person).grid == 2)
        for (kind, w, h, mib) in [(SmartKind.sky, 756, 504, 2.9), (.person, 2016, 1512, 5.8), (.subject, 512, 512, 2.0)] {
            let size = MaskRefineParameters.of(kind).coefficientSize(seedWidth: w, seedHeight: h)
            #expect(abs(Double(size.width * size.height * 8) / 1048576 - mib) < 0.05, "\(kind)")
        }
        let full = MaskRefineParameters(radiusShare: 0.004, epsilon: 0.02).coefficientSize(seedWidth: 2016, seedHeight: 1512)
        #expect(abs(Double(full.width * full.height * 8) / 1048576 - 23.3) < 0.05)
    }

    /// Every band count gives the unbanded half-float coefficients bit for bit, on each stored seed shape, both grids; the working set
    /// the budget chooses stays under 32 MiB, where the unbanded build of the person matte takes about 200.
    @Test func bandedEqualsUnbandedExactlyInUnder32MiB() throws {
        let gpu = try GPU()
        let refiner = gpu.maskRefiner
        let (pixels, matte) = Refine.scene(width: 2048, height: 1365)
        let frame = try MaskRender.frame(gpu, pixels, width: 2048)
        let cases: [(String, Int, Int, MaskRefineParameters, Bool)] = [
            ("person", 2016, 1512, .person, false), ("person portrait", 1512, 2016, .person, false),
            ("person full grid", 2016, 1512, MaskRefineParameters(radiusShare: 0.004, epsilon: 0.02), false),
            ("sky", 756, 504, .sky, true), ("labels", 512, 512, .subject, true),
        ]
        for (name, w, h, parameters, binary) in cases {
            let raster = try Refine.seed(matte: matte, width: 2048, height: 1365, seedWidth: w, seedHeight: h, binary: binary)
            let seed = try refiner.upload(raster)
            let whole = try refiner.build(seed: seed, guideFrame: frame.texture, parameters: parameters, bandRows: h)
            let wholeBits = MaskRender.bits(whole.texture)
            #expect(whole.build.bands == 1)
            let budget = try refiner.build(seed: seed, guideFrame: frame.texture, parameters: parameters)
            #expect(MaskRender.bits(budget.texture) == wholeBits, "\(name): \(budget.build.bands) bands")
            #expect(budget.build.workingBytes < 32 << 20, "\(name): \(budget.build.workingBytes >> 20) MiB")
            MaskRender.report("refiner \(name) \(w)x\(h) r \(budget.build.radius): unbanded \(whole.build.workingBytes) B, "
                              + "\(budget.build.bands) bands of \(budget.build.bandRows) rows \(budget.build.workingBytes) B, "
                              + "output \(budget.build.outputBytes) B, GPU \(budget.build.gpuSeconds * 1000) ms (unbanded \(whole.build.gpuSeconds * 1000))")
            for rows in [1, 2, 7, 64, 333] where rows < h {
                let banded = try refiner.build(seed: seed, guideFrame: frame.texture, parameters: parameters, bandRows: rows)
                #expect(MaskRender.bits(banded.texture) == wholeBits, "\(name): bands of \(rows)")
            }
        }
        // S3's figure for the person matte: 8 bands, 29 MiB. A margin of r instead of 2 r would not be exact (S3: 0.28 in a coefficient).
        // S3's figure for the person matte: 8 bands, 29.2 MiB; this budget takes 9 bands of 182 rows.
        let person = try refiner.build(seed: try refiner.upload(Refine.constant(128, width: 2016, height: 1512)), guideFrame: frame.texture,
                                       parameters: .person)
        #expect((8...9).contains(person.build.bands) && person.build.workingBytes > 26 << 20 && person.build.workingBytes < 32 << 20)
    }

    /// The coefficients and the coverage they give against a double-precision reference of the same filter, unbanded, with a solve by
    /// pivoting rather than the kernel's LDL: the difference is the half float's (R9: coverage max 0.002).
    @Test func theBuildMatchesTheCPUReference() throws {
        let gpu = try GPU()
        let (pixels, matte) = Refine.scene(width: 768, height: 512)
        let frame = try MaskRender.frame(gpu, pixels, width: 768)
        for (parameters, binary) in [(MaskRefineParameters.sky, true), (.person, false),
                                     (MaskRefineParameters(radiusShare: 0.004, epsilon: 0.02), false)] {
            let raster = try Refine.seed(matte: matte, width: 768, height: 512, seedWidth: 378, seedHeight: 252, binary: binary)
            let built = try gpu.maskRefiner.build(seed: try gpu.maskRefiner.upload(raster), guideFrame: frame.texture, parameters: parameters, bandRows: 40)
            let gpuCoefficients = Refine.coefficients(built.texture)
            let reference = MaskRefiner.reference(seed: raster, guide: pixels.map(MaskRender.half), guideWidth: 768, guideHeight: 512,
                                                  parameters: parameters)
            #expect(gpuCoefficients.count == reference.count)
            var worstCoverage: Float = 0
            let cw = built.texture.width, ch = built.texture.height
            let cpu = reference.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), Float($0.w)) }
            for i in stride(from: 0, to: pixels.count, by: 7) {
                let uv = SIMD2<Float>((Float(i % 768) + 0.5) / 768, (Float(i / 768) + 0.5) / 512)
                let rgb = MaskRender.half(pixels[i])
                let a = MaskRefiner.refined(gpuCoefficients, width: cw, height: ch, uv: uv, rgb: rgb)
                let b = MaskRefiner.refined(cpu, width: cw, height: ch, uv: uv, rgb: rgb)
                worstCoverage = max(worstCoverage, abs(a - b))
            }
            MaskRender.report("refiner CPU reference \(parameters): worst coverage \(worstCoverage)")
            #expect(worstCoverage < 0.004, "\(parameters)")
        }
    }
}

/// Guide independence (plan section 8's gate; R8 13, row 9): the refined mask is the same bits whatever slider, stock, grain or
/// sharpening the render has, in both tiers, and nothing is built again.
@Suite struct MaskRefinerGuideIndependenceTests {
    @Test func theRefinedMaskIsBitIdenticalAcrossEverySliderStockGrainAndSharpening() throws {
        let gpu = try GPU()
        let (pixels, matte) = Refine.scene(width: 1200, height: 800)
        let raster = try Refine.seed(matte: matte, width: 1200, height: 800, seedWidth: 378, seedHeight: 252, binary: true)
        gpu.maskRefiner.seeds = Refine.Seeds([raster])
        let frame = try MaskRender.frame(gpu, pixels, width: 1200, picture: try MaskSpace(width: 7008, height: 4672))
        let sky = try Refine.component(.sky, raster)
        let stocks = try MaskRender.stocks()
        var first: (field: [Float], coefficients: [UInt16], tier2: [Float])?
        var cases = 0
        for (index, stock) in stocks.enumerated() {
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            let variants: [(ManualAdjustments, ManualAdjustments, DevelopSettings)] = [
                (try ManualAdjustments(exposureEV: -5), .identity, DevelopSettings()),
                (try ManualAdjustments(exposureEV: 5, highlights: -60, shadows: 40), .identity, DevelopSettings(grain: 1, grainSeed: 7, halation: true)),
                (try ManualAdjustments(exposureEV: -1.5, contrast: 30, whites: 20, blacks: -40), try ManualAdjustments(exposureEV: 1.2, highlights: -50),
                 DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.02, -0.01, 0), printExposure: 0.2, grain: 0.6, grainSeed: 99, halation: true, sharpen: true)),
                (try ManualAdjustments(exposureEV: 0.75), try ManualAdjustments(shadows: 70), DevelopSettings(sharpen: true, tone: LightCompilerBaselineTests.toneStep)),
            ]
            // Every variant on the toy stock, and one on each baked stock in turn.
            for (maskValues, panel, base) in index == 0 ? variants : [variants[index % variants.count]] {
                var settings = base
                settings.manual = try MaskRender.manual(panel, masks: [Mask(components: [sky], amount: index == 0 ? 1 : 1.7, adjustments: maskValues)],
                                                        reference: 0.3)
                _ = try renderer.render(frame, settings: settings)
                let scene = try Refine.scene(renderer, frame, settings)
                let masks = try #require(scene.masks)
                let coefficients = try #require(masks.refinedCoefficients[0])
                let now = (masks.coverage.values(slot: 0), MaskRender.bits(coefficients), try Refine.probe(gpu, frame, scene, slot: 0))
                if let first {
                    #expect(now.0 == first.field, "\(stock.id) \(maskValues)")
                    #expect(now.1 == first.coefficients, "\(stock.id) \(maskValues)")
                    #expect(now.2 == first.tier2, "\(stock.id) \(maskValues)")
                } else {
                    first = now
                }
                cases += 1
            }
        }
        #expect(cases >= 6)
        // One refinement and one field for the whole run: every other render hit both.
        #expect(gpu.maskRefiner.statistics.builds == 1)
        #expect(gpu.maskFields.statistics.bakes == 1)
        // And the mask moves a pixel: Exposure through it is not nothing.
        #expect(try #require(first).tier2.contains { $0 > 0.9 } && first!.tier2.contains { $0 < 0.1 })
    }
}

/// R8 section 13, row 8: phantoms with a known matte under a coarse seed.
@Suite struct MaskRefinerPhantomTests {
    private struct Run {
        let refined: [Float], bilinear: [Float], matte: [Float], width: Int, height: Int
    }

    /// Tier 2's coverage of a phantom frame from `raster` (sky constants), and the seed sampled bilinearly as the unrefined slice would.
    private func run(_ gpu: GPU, width: Int, height: Int, raster: MaskRaster, pixels: [SIMD3<Float>], matte: [Float],
                     parameters: MaskRefineParameters = .sky) throws -> Run {
        let frame = try MaskRender.frame(gpu, pixels, width: width)
        let built = try gpu.maskRefiner.build(seed: try gpu.maskRefiner.upload(raster), guideFrame: frame.texture, parameters: parameters)
        let k = Refine.coefficients(built.texture), cw = built.texture.width, ch = built.texture.height
        var refined = [Float](repeating: 0, count: width * height), bilinear = refined
        let seed = (0..<raster.plane.count).map { i -> SIMD4<Float> in   // the seed as constant coefficients, rows flipped to a texture's
            let x = i % raster.width, y = i / raster.width
            return SIMD4(0, 0, 0, Float(raster.plane[(raster.height - 1 - y) * raster.width + x]) / 255)
        }
        for i in 0..<(width * height) {
            let uv = SIMD2<Float>((Float(i % width) + 0.5) / Float(width), (Float(i / width) + 0.5) / Float(height))
            refined[i] = MaskRefiner.refined(k, width: cw, height: ch, uv: uv, rgb: MaskRender.half(pixels[i]))
            bilinear[i] = MaskRefiner.refined(seed, width: raster.width, height: raster.height, uv: uv, rgb: .zero)
        }
        return Run(refined: refined, bilinear: bilinear, matte: matte, width: width, height: height)
    }

    /// Mean |coverage − matte| over pixels within `reach` px of an edge of the matte, left of `columns` of the width.
    private func bandError(_ coverage: [Float], _ run: Run, reach: Int = 12, columns: Float = 1) -> Float {
        var edge = [Bool](repeating: false, count: run.matte.count)
        for y in 0..<run.height {
            for x in 0..<Int(columns * Float(run.width)) where run.matte[y * run.width + x] > 0.02 && run.matte[y * run.width + x] < 0.98 {
                for dy in -reach...reach { for dx in -reach...reach {
                    let xx = x + dx, yy = y + dy
                    if xx >= 0, yy >= 0, xx < run.width, yy < run.height { edge[yy * run.width + xx] = true }
                } }
            }
        }
        var sum: Float = 0, count: Float = 0
        for i in edge.indices where edge[i] { sum += abs(coverage[i] - run.matte[i]); count += 1 }
        return sum / max(count, 1)
    }

    @Test func refinementBringsBackThinStructureABinarySeedLost() throws {
        let gpu = try GPU()
        let (width, height) = (2048, 1365)
        let (pixels, matte) = Refine.scene(width: width, height: height)
        // DA3's sky seed is 756 px on the long side: 2.7 frame pixels a seed pixel.
        let raster = try Refine.seed(matte: matte, width: width, height: height, seedWidth: 756, seedHeight: 504, binary: true)
        let result = try run(gpu, width: width, height: height, raster: raster, pixels: pixels, matte: matte)
        let refinedError = bandError(result.refined, result), seedError = bandError(result.bilinear, result)
        MaskRender.report("phantom band error: refined \(refinedError), seed bilinear \(seedError)")
        // R8 5.2 on a binary seed: 0.139 against bilinear's 0.172, a fifth lower.
        #expect(refinedError < 0.8 * seedError)

        // Twigs of 1 to 6 px growing from the labelled trunk: the seed lost the thin ones (coverage near 1 on them); within the window of
        // the trunk refinement brings them back partly, the thinner the paler, never to 0 (R8 5.8: twigs 0.1 to 0.3, the finest 0.7 to
        // 0.85). Wires as thin in open sky, with nothing labelled in the window, cannot come back: a wrong label stays (R8 5.8, 4).
        func mean(_ values: [Float], rows: ClosedRange<Int>, columns: Range<Int>) -> Float {
            var sum: Float = 0, count: Float = 0
            for yTop in rows { for x in columns where result.matte[(height - 1 - yTop) * width + x] <= 0.5 {
                sum += values[(height - 1 - yTop) * width + x]; count += 1
            } }
            return count > 0 ? sum / count : .nan
        }
        let right = Int(Refine.trunk(width: width).right)
        var twigs: [(Float, Float, Float, Float)] = [], wires: [(Float, Float, Float)] = []
        for (index, thickness) in Refine.thicknesses.enumerated() {
            let twig = Int(Refine.twigTop(index, height: height)), wire = Int(Refine.wireTop(index, height: height))
            let rows = twig...(twig + max(0, Int(thickness.rounded(.up)) - 1)), wireRows = wire...(wire + max(0, Int(thickness.rounded(.up)) - 1))
            let near = (right + 2)..<(right + 14), far = (right + 50)..<(right + 78), open = Int(0.32 * Float(width))..<Int(0.48 * Float(width))
            twigs.append((thickness, mean(result.refined, rows: rows, columns: near), mean(result.refined, rows: rows, columns: far),
                          mean(result.bilinear, rows: rows, columns: near)))
            wires.append((thickness, mean(result.refined, rows: wireRows, columns: open), mean(result.bilinear, rows: wireRows, columns: open)))
        }
        MaskRender.report("phantom twigs (px, refined near the trunk, refined far, seed): \(twigs)")
        MaskRender.report("phantom wires in open sky (px, refined, seed): \(wires)")
        for (thickness, near, _, seed) in twigs where thickness <= 2 {
            #expect(seed > 0.6, "the seed lost the \(thickness) px twig")
            #expect(near < seed - 0.15, "\(thickness) px twig, near the trunk")
        }
        for (thickness, near, far, _) in twigs where thickness >= 4 { #expect(near < 0.3 && far < 0.3, "\(thickness) px twig") }
        // The balusters (3 px at 12 px) return as bars: their middles darker than the gaps between them.
        let row = (height - 1 - Int(0.55 * Float(height))) * width
        var bars: Float = 0, gaps: Float = 0, nb: Float = 0, ng: Float = 0
        for x in Int(0.56 * Float(width))..<Int(0.74 * Float(width)) {
            if result.matte[row + x] < 0.05 { bars += result.refined[row + x]; nb += 1 }
            if result.matte[row + x] > 0.95 { gaps += result.refined[row + x]; ng += 1 }
        }
        MaskRender.report("phantom balusters: bars \(bars / nb), gaps \(gaps / ng)")
        #expect(gaps / ng - bars / nb > 0.2)
    }

    /// With nothing in the guide to follow, the filter keeps the seed: `a` is 0 and `b` is the seed boxed twice, which is the seed itself
    /// wherever the seed is flat across the boxes.
    @Test func aFlatGuideGivesTheSeedBack() throws {
        let gpu = try GPU()
        let (width, height) = (1024, 683)
        let (_, matte) = Refine.scene(width: width, height: height)
        let raster = try Refine.seed(matte: matte, width: width, height: height, seedWidth: 378, seedHeight: 252, binary: false)
        let flat = [SIMD3<Float>](repeating: SIMD3(0.18, 0.18, 0.18), count: width * height)
        let frame = try MaskRender.frame(gpu, flat, width: width)
        let built = try gpu.maskRefiner.build(seed: try gpu.maskRefiner.upload(raster), guideFrame: frame.texture, parameters: .sky)
        let k = Refine.coefficients(built.texture)
        #expect(k.allSatisfy { abs($0.x) < 1e-3 && abs($0.y) < 1e-3 && abs($0.z) < 1e-3 })
        let r = MaskRefineParameters.sky.radius(seedWidth: 378, seedHeight: 252)
        var checked = 0
        for y in (2 * r)..<(252 - 2 * r) {
            for x in (2 * r)..<(378 - 2 * r) {
                var low = UInt8.max, high = UInt8.min
                for yy in (y - 2 * r)...(y + 2 * r) { for xx in (x - 2 * r)...(x + 2 * r) {
                    let v = raster.plane[(251 - yy) * 378 + xx]; low = min(low, v); high = max(high, v)
                } }
                guard low == high else { continue }
                #expect(abs(k[y * 378 + x].w - Float(low) / 255) < 0.001)
                checked += 1
            }
        }
        #expect(checked > 10_000)
    }

    /// A seed misregistered by one frame pixel (a third of a seed pixel, about what S3 measured for Vision's stretch) or by a whole seed
    /// pixel is absorbed at solid edges, the trunk, its twigs, the wires and the horizon: the refined coverage moves less than the seed
    /// and keeps most of its gain over it (R8 5.8: up to about the window's radius). The comb and lattice, whose members are as wide as a
    /// seed pixel, alias in a binary seed that moves, so there a shift changes the labels themselves; that is measured and reported.
    @Test func aOnePixelShiftIsAbsorbed() throws {
        let gpu = try GPU()
        let (width, height) = (2048, 1365)
        let (pixels, matte) = Refine.scene(width: width, height: height)
        let raster = try Refine.seed(matte: matte, width: width, height: height, seedWidth: 756, seedHeight: 504, binary: true)
        let a = try run(gpu, width: width, height: height, raster: raster, pixels: pixels, matte: matte)
        for shift in [1, 3] {
            let shifted = try Refine.seed(matte: matte, width: width, height: height, seedWidth: 756, seedHeight: 504, binary: true, shift: shift)
            let b = try run(gpu, width: width, height: height, raster: shifted, pixels: pixels, matte: matte)
            for (region, columns) in [("solid edges", Float(0.52)), ("whole frame", Float(1))] {
                let seedMove = bandError(b.bilinear, Run(refined: [], bilinear: [], matte: a.bilinear, width: width, height: height), columns: columns)
                let refinedMove = bandError(b.refined, Run(refined: [], bilinear: [], matte: a.refined, width: width, height: height), columns: columns)
                let shiftedError = bandError(b.refined, b, columns: columns), registered = bandError(a.refined, a, columns: columns)
                let seedError = bandError(b.bilinear, b, columns: columns)
                MaskRender.report("phantom shift \(shift) px, \(region): seed moves \(seedMove), refined \(refinedMove); error \(shiftedError) "
                                  + "(registered \(registered)) against the seed's \(seedError)")
                guard columns < 1 else { continue }
                // Absorbed: the refined edge moves a quarter of the seed's or less, and its error stays within 15 % of the registered
                // seed's. That error includes the wires no window can recover, so it is not far under the seed's own.
                #expect(refinedMove < 0.25 * seedMove, "\(shift) px")
                #expect(shiftedError < 1.15 * registered && shiftedError < seedError, "\(shift) px")
            }
        }
    }
}

/// R8 section 13, row 10: statistics from the shared 2048 frame against the render's own, at 3800 px.
@Suite struct MaskRefinerStatisticsTests {
    @Test func canonicalAgainstOwnStatisticsAt3800() throws {
        let gpu = try GPU()
        let (width, height) = (3800, 2533)
        let (pixels, matte) = Refine.scene(width: width, height: height)
        let raster = try Refine.seed(matte: matte, width: width, height: height, seedWidth: 756, seedHeight: 504, binary: true)
        let frame = try MaskRender.frame(gpu, pixels, width: width, picture: try MaskSpace(width: width, height: height))
        let seed = try gpu.maskRefiner.upload(raster)
        let canonical = try gpu.maskRefiner.guideFrame(for: frame, size: MaskFieldSize(picture: try frame.maskPicture))
        #expect(canonical.width == 2048 && canonical !== frame.texture)
        let fromCanonical = Refine.coefficients(try gpu.maskRefiner.build(seed: seed, guideFrame: canonical, parameters: .sky).texture)
        let fromOwn = Refine.coefficients(try gpu.maskRefiner.build(seed: seed, guideFrame: frame.texture, parameters: .sky).texture)
        var differences: [Float] = []
        differences.reserveCapacity(width * height / 3)
        for i in stride(from: 0, to: width * height, by: 3) {
            let uv = SIMD2<Float>((Float(i % width) + 0.5) / Float(width), (Float(i / width) + 0.5) / Float(height))
            let rgb = MaskRender.half(pixels[i])
            differences.append(abs(MaskRefiner.refined(fromCanonical, width: 756, height: 504, uv: uv, rgb: rgb)
                                   - MaskRefiner.refined(fromOwn, width: 756, height: 504, uv: uv, rgb: rgb)))
        }
        let worst = differences.max() ?? 0, p99 = Refine.p99(differences)
        let past = Float(differences.filter { $0 > 0.02 }.count) / Float(differences.count)
        MaskRender.report("canonical against own statistics at 3800: max \(worst), p99 \(p99), share past 0.02 \(past)")
        // R8's list asks for 0.02 at the max; its own measurement on real twigs was p99 0.018, max 0.085. On this phantom's 2 px
        // lattice the max is about 0.3 (the report's correction); the bound is held at p99, and to a sliver of pixels past 0.02.
        #expect(p99 < 0.02)
        #expect(past < 0.005)
    }
}

/// Tier 1 and tier 2 in the render: which mask takes which, and each against the CPU.
@Suite struct MaskRefinerTierTests {
    private let picture = try! MaskSpace(width: 7008, height: 4672)

    @Test func theRuleChoosesTierTwoForExposureOnASmartMaskAlone() throws {
        let seed = try Refine.constant(200)
        let sky = try Refine.component(.sky, seed), subject = try Refine.component(.subject, seed)
        let exposure = try ManualAdjustments(exposureEV: -1), tone = try ManualAdjustments(highlights: -40)
        let masks = [
            Mask(components: [sky], adjustments: exposure),                                    // 0: tier 2
            Mask(components: [sky], adjustments: tone),                                        // 1: tone only, tier 1
            Mask(components: [sky, MaskRender.linear(0, 0, 0, 1)], adjustments: exposure),     // 2: composed, tier 2
            Mask(isEnabled: false, components: [subject], adjustments: exposure),              // 3: off
            Mask(components: [subject], amount: 0, adjustments: exposure),                     // 4: Amount 0
            Mask(components: [try Refine.component(.background, seed)], adjustments: exposure), // 5: tier 2, inverted
            Mask(components: [try Refine.component(.subject, seed, invert: true)], adjustments: exposure), // 6: tier 2, inverted
            Mask(components: [try Refine.component(.person, seed, invert: true)], adjustments: exposure), // 7: tier 2, inverted
            Mask(components: [try Refine.component(.person, seed)], adjustments: exposure),     // 8: a fifth: tier 1
        ]
        // Four at most, in list order: the fifth and sixth (7 and 8) read their slices. Mask 2 is composed: its fields at 9 and 10.
        #expect(MaskRefiner.perPixelSlots(masks) == [0, 2, 5, 6])
        #expect(MaskRefiner.perPixelPlan(masks).map(\.composedLow) == [nil, 9, nil, nil])
        #expect(MaskRefiner.perPixelSelection(masks[2])?.alone == false && MaskRefiner.perPixelSelection(masks[0])?.alone == true)
        // Two selections in one mask are not affine in either: tier 1. A selection subtracted alone is composed, not alone.
        #expect(MaskRefiner.perPixelSelection(Mask(components: [sky, subject], adjustments: exposure)) == nil)
        #expect(MaskRefiner.perPixelSelection(Mask(components: [try Refine.component(.sky, seed, operation: .subtract)], adjustments: exposure))?.alone == false)
        // Composed fields take slots after the masks': fourteen masks leave two for a composite; fifteen leave one, and it reads its slice.
        let tones = Array(repeating: Mask(components: [MaskRender.everywhere], adjustments: tone), count: 14)
        #expect(MaskRefiner.perPixelPlan(Array(tones.prefix(13)) + [masks[2]]).map(\.composedLow) == [14])
        #expect(MaskRefiner.perPixelPlan(tones + [masks[2]]).isEmpty)
        #expect(MaskRefiner.perPixelSelection(masks[5])?.inverted == true)
        #expect(MaskRefiner.perPixelSelection(masks[6])?.inverted == true)
        #expect(MaskRefiner.perPixelSelection(masks[0])?.inverted == false)
        let backgroundInverted = Mask(components: [try Refine.component(.background, seed, invert: true)], adjustments: exposure)
        #expect(MaskRefiner.perPixelSelection(backgroundInverted)?.inverted == false)
        // Another mask's slider does not change a mask's tier; its own Exposure and its place do.
        var moved = masks
        moved[1].adjustments = try ManualAdjustments(highlights: 80)
        #expect(MaskRefiner.perPixelSlots(moved) == [0, 2, 5, 6])
    }

    /// A seed of 255 everywhere refines to coverage exactly 1 (a of 0, b of 1), so a smart mask over it renders as the gradient that
    /// covers the frame, in either tier; a Background of a seed of 0, the same. Through the whole film, densities and halo.
    @Test func aSeedThatCoversEverythingRendersAsTheWholeFrameMask() throws {
        let gpu = try GPU()
        gpu.maskRefiner.seeds = Refine.Seeds([try Refine.constant(255), try Refine.constant(0)])
        let negative = try MaskRender.Negative(gpu, stock: LightCompilerBaselineTests.toyStock())
        let values = try ManualAdjustments(exposureEV: -1.5, highlights: -30, whites: 20, blacks: -30)
        for width in [1200, 640] {   // tier 2 and tier 1
            let (pixels, _) = Refine.scene(width: width, height: width * 2 / 3)
            let frame = try MaskRender.frame(gpu, pixels, width: width, picture: picture)
            func settings(_ component: MaskComponent) throws -> DevelopSettings {
                DevelopSettings(halation: true, manual: try MaskRender.manual(masks: [MaskRender.mask(component, values)], reference: 0.2))
            }
            let whole = try negative.run(frame, settings: try settings(MaskRender.everywhere))
            for component in [try Refine.component(.sky, Refine.constant(255)), try Refine.component(.background, Refine.constant(0)),
                              try Refine.component(.subject, Refine.constant(0), invert: true)] {
                let smart = try negative.run(frame, settings: try settings(component))
                #expect(smart.densities == whole.densities, "\(width) \(component.shape)")
                #expect(smart.field == whole.field)
            }
        }
    }

    /// Tier 2 per pixel, as the kernels evaluate it (`local_mask_coverage_probe`), against the CPU: the same coefficients read back to
    /// within the sampler's rounding, and against the double-precision reference within the half float's. Tier 1's slice against the
    /// CPU at its texels.
    @Test func tierTwoAndTierOneAgainstTheCPU() throws {
        let gpu = try GPU()
        let (width, height) = (2400, 1600)   // past the slice, so the guide frame is the decode area-averaged to 2048
        let (pixels, matte) = Refine.scene(width: width, height: height)
        let raster = try Refine.seed(matte: matte, width: width, height: height, seedWidth: 378, seedHeight: 252, binary: true)
        gpu.maskRefiner.seeds = Refine.Seeds([raster])
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let frame = try MaskRender.frame(gpu, pixels, width: width, picture: picture)
        let gradient = MaskRender.radial(0.5, 0.3, 0.4, 0.25, feather: 50)
        let settings = DevelopSettings(manual: try MaskRender.manual(masks: [
            MaskRender.mask(gradient, try ManualAdjustments(shadows: 20)),
            Mask(components: [try Refine.component(.sky, raster)], adjustments: try ManualAdjustments(exposureEV: -1.5)),
            Mask(components: [try Refine.component(.background, raster)], adjustments: try ManualAdjustments(exposureEV: 0.5)),
        ]))
        let scene = try Refine.scene(renderer, frame, settings)
        let masks = try #require(scene.masks)
        #expect(masks.refinement.refined == 0b11 && masks.refinement.slot.x == 1 && masks.refinement.slot.y == 2)
        #expect(masks.refinement.invert == 0b10)
        let k = Refine.coefficients(try #require(masks.refinedCoefficients[0])), cw = 378, ch = 252
        let kb = Refine.coefficients(try #require(masks.refinedCoefficients[1]))   // Background: Subject's constants
        let guide = try guidePixels(gpu, frame)
        let size = masks.coverage.slots.size
        #expect(guide.count == size.width * size.height)
        let reference = MaskRefiner.reference(seed: raster, guide: guide, guideWidth: size.width, guideHeight: size.height,
                                              parameters: .sky).map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), Float($0.w)) }
        let sky = try Refine.probe(gpu, frame, scene, slot: 1), background = try Refine.probe(gpu, frame, scene, slot: 2)
        let slice = try Refine.probe(gpu, frame, scene, slot: 0)
        var sampled: Float = 0, cpu: Float = 0, inverse: Float = 0
        for i in stride(from: 0, to: width * height, by: 5) {
            let uv = SIMD2<Float>((Float(i % width) + 0.5) / Float(width), (Float(i / width) + 0.5) / Float(height))
            let rgb = MaskRender.half(pixels[i])
            sampled = max(sampled, abs(sky[i] - MaskRefiner.refined(k, width: cw, height: ch, uv: uv, rgb: rgb)))
            cpu = max(cpu, abs(sky[i] - MaskRefiner.refined(reference, width: cw, height: ch, uv: uv, rgb: rgb)))
            inverse = max(inverse, abs(background[i] - (1 - MaskRefiner.refined(kb, width: cw, height: ch, uv: uv, rgb: rgb))))
        }
        // The sampler filters half-float texels at about the half float's own precision: R9 measured the same 0.002.
        MaskRender.report("tier 2 against the CPU: same coefficients \(sampled), reference \(cpu), background \(inverse)")
        #expect(sampled < 0.003)
        #expect(cpu < 0.005)
        #expect(inverse < 0.003)
        // The gradient is untouched by tier 2: the slice's own bilinear read.
        #expect(slice.contains { $0 > 0.5 })

        // Tier 1: the slice's texels against the refined value at the guide frame's texel, which is the decode area-averaged there.
        let field = masks.coverage.values(slot: 1)   // top row first
        var tierOne: Float = 0
        for yTop in stride(from: 0, to: size.height, by: 5) {
            for x in stride(from: 0, to: size.width, by: 5) {
                let row = size.height - 1 - yTop
                let uv = SIMD2<Float>((Float(x) + 0.5) / Float(size.width), (Float(row) + 0.5) / Float(size.height))
                let expected = MaskRefiner.refined(k, width: cw, height: ch, uv: uv, rgb: MaskRender.half(guide[row * size.width + x]))
                tierOne = max(tierOne, abs(field[yTop * size.width + x] - expected))
            }
        }
        // The sampler's 0.002 and the slice's half float, written toward zero (T5).
        MaskRender.report("tier 1 against the CPU: \(tierOne)")
        #expect(tierOne < 0.003)
    }

    /// A smart selection composes with gradients, brushes and another selection in one mask as any component does. In the slice (tier
    /// 1) each mask's field is the CPU's composition of the same refined values at its texels. A mask with one selection carrying
    /// Exposure takes tier 2 composed: its two composed fields are the composition with the selection at 0 and at 1, and per pixel its
    /// coverage is the composition with the gradient or brush at the pixel and the refined value from the pixel's own light. Sky less a
    /// radial, Sky less a soft Subtract brush (the plan's repair), and Sky with Background (two selections: tier 1).
    @Test func aComposedSmartMaskBakesItsCompositionAndTakesTierTwo() throws {
        let gpu = try GPU()
        let (width, height) = (2400, 1600)
        let (pixels, matte) = Refine.scene(width: width, height: height)
        let raster = try Refine.seed(matte: matte, width: width, height: height, seedWidth: 378, seedHeight: 252, binary: true)
        gpu.maskRefiner.seeds = Refine.Seeds([raster])
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let frame = try MaskRender.frame(gpu, pixels, width: width, picture: picture)
        let paintFrame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let radial = MaskComponent(operation: .subtract, shape: .radial(.init(center: MaskPoint(x: 0.4, y: 0.2), semiAxisA: 0.2,
                                                                                   semiAxisB: 0.12, feather: 50)))
        let stroke = BrushStroke(radius: 0.04, feather: 1, flow: 0.8,
                                 points: try PackedPoints.pack([MaskPoint(x: 0.6, y: 0.15), MaskPoint(x: 0.75, y: 0.2), MaskPoint(x: 0.9, y: 0.12)]))
        let brush = MaskComponent(operation: .subtract, shape: .brush(BrushPaint(frame: paintFrame, strokes: [stroke])))
        let exposure = try ManualAdjustments(exposureEV: -1.5)
        let masks = [Mask(components: [try Refine.component(.sky, raster), radial], adjustments: exposure),
                     Mask(components: [try Refine.component(.sky, raster), try Refine.component(.background, raster)], adjustments: exposure),
                     Mask(components: [try Refine.component(.sky, raster), brush], adjustments: exposure)]
        let scene = try Refine.scene(renderer, frame, DevelopSettings(manual: try MaskRender.manual(masks: masks)))
        let inputs = try #require(scene.masks)
        let slots = inputs.coverage.slots
        // Masks 0 and 2 take tier 2 composed, their fields in slots 3 and 4, 5 and 6; mask 1, with two selections, its slice.
        #expect(inputs.refinement.refined == 0b11 && inputs.refinement.composed == 0b11 && inputs.refinement.invert == 0)
        #expect(inputs.refinement.slot.x == 0 && inputs.refinement.slot.y == 2)
        #expect(slots.composed == [MaskSlots.Composed(mask: 0, low: 3), MaskSlots.Composed(mask: 2, low: 5)])
        #expect(inputs.refinement.composedSlots == 3 | (5 << 4) && slots.sliceCount == 2 && slots.maskCount == 3)

        let guide = MaskRender.read(try gpu.maskRefiner.guideFrame(for: frame, size: MaskFieldSize(picture: picture)))
        let size = slots.size
        let session = gpu.maskRefiner.session(for: frame, picture: picture)
        guard case .smart(let skySelection) = masks[1].components[0].shape, case .smart(let background) = masks[1].components[1].shape else { return }
        let skyK = Refine.coefficients(try session.coefficients(for: skySelection))
        let backgroundK = Refine.coefficients(try session.coefficients(for: background))
        func refined(_ selection: SmartSelection, _ uv: SIMD2<Float>, _ rgb: SIMD3<Float>) -> Float {
            MaskRefiner.refined(selection.kind == .background ? backgroundK : skyK, width: 378, height: 252, uv: uv, rgb: rgb)
        }
        let field = BrushField([stroke])
        /// The CPU's composition of `program` at `q`, each refined raster taking `value`, a brush its CPU field.
        func compose(_ program: MaskProgram, at q: SIMD2<Float>, _ value: (SmartSelection) -> Float) -> Float {
            program.coverage(at: q) { index, at in
                switch program.rasters[index] {
                case .refined(let selection): return value(selection)
                case .brush: return field.value(at: at)
                }
            }
        }
        var tierOne: Float = 0, composedFields: Float = 0
        for (slot, mask) in masks.enumerated() {
            let program = try MaskProgram(mask.coverage), values = inputs.coverage.values(slot: slot)
            let fields = slots.composed.first { $0.mask == slot }
            let low = fields.map { inputs.coverage.values(slot: $0.low) }, high = fields.map { inputs.coverage.values(slot: $0.low + 1) }
            for yTop in stride(from: 0, to: size.height, by: 7) {
                for x in stride(from: 0, to: size.width, by: 7) {
                    let row = size.height - 1 - yTop
                    let uv = SIMD2<Float>((Float(x) + 0.5) / Float(size.width), (Float(row) + 0.5) / Float(size.height))
                    let rgb = MaskRender.half(guide[row * size.width + x])
                    let point = size.point(column: x, yTop: yTop), q = SIMD2(point.x, point.y)
                    tierOne = max(tierOne, abs(values[yTop * size.width + x] - compose(program, at: q) { refined($0, uv, rgb) }))
                    if let low, let high {
                        composedFields = max(composedFields, abs(low[yTop * size.width + x] - compose(program, at: q) { _ in 0 }),
                                             abs(high[yTop * size.width + x] - compose(program, at: q) { _ in 1 }))
                    }
                }
            }
        }
        // Tier 2, per pixel: the probe against the composition at the pixel's own point and light.
        var tierTwo: [Float] = [0, 0]
        for (index, slot) in [0, 2].enumerated() {
            let program = try MaskProgram(masks[slot].coverage), probe = try Refine.probe(gpu, frame, scene, slot: slot)
            for i in stride(from: 0, to: width * height, by: 5) {
                let column = i % width, row = i / width
                let uv = SIMD2<Float>((Float(column) + 0.5) / Float(width), (Float(row) + 0.5) / Float(height))
                let point = try MaskSpace(width: width, height: height).point(column: column, yTop: height - 1 - row)
                let expected = compose(program, at: SIMD2(point.x, point.y)) { refined($0, uv, MaskRender.half(pixels[i])) }
                tierTwo[index] = max(tierTwo[index], abs(probe[i] - expected))
            }
        }
        MaskRender.report("composed smart masks against the CPU: slices \(tierOne), composed fields \(composedFields), tier 2 (radial, brush) \(tierTwo)")
        #expect(tierOne < 0.003)
        #expect(composedFields < 0.002)
        #expect(tierTwo[0] < 0.004 && tierTwo[1] < 0.004)
    }

    /// The guide frame a session makes for `frame`, read back, row 0 the bottom.
    private func guidePixels(_ gpu: GPU, _ frame: LinearFrame) throws -> [SIMD3<Float>] {
        let texture = try gpu.maskRefiner.guideFrame(for: frame, size: MaskFieldSize(picture: try frame.maskPicture))
        return MaskRender.read(texture)
    }

    /// Below `perPixelMinimumLongSide` (the sheet and strip) every mask reads its slice, and nothing is kept of the coefficients.
    @Test func theSheetTakesTierOneAndKeepsNoCoefficients() throws {
        let gpu = try GPU()
        let (pixels, matte) = Refine.scene(width: 960, height: 640)
        let raster = try Refine.seed(matte: matte, width: 960, height: 640, seedWidth: 378, seedHeight: 252, binary: true)
        gpu.maskRefiner.seeds = Refine.Seeds([raster])
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let frame = try MaskRender.frame(gpu, pixels, width: 960, picture: picture)
        let settings = DevelopSettings(manual: try MaskRender.manual(masks: [
            Mask(components: [try Refine.component(.sky, raster)], adjustments: try ManualAdjustments(exposureEV: -1.5))]))
        let scene = try Refine.scene(renderer, frame, settings)
        #expect(scene.masks?.refinement.refined == 0)
        #expect(gpu.maskRefiner.residentBytes == 0 && gpu.maskRefiner.statistics.builds == 1)
        // The sheet's decode is its own guide frame: no guide frame made.
        #expect(gpu.maskRefiner.statistics.guideFrames == 0)
        // A slider: the slice is kept, so nothing is built again.
        let slid = DevelopSettings(manual: try MaskRender.manual(masks: [
            Mask(components: [try Refine.component(.sky, raster)], adjustments: try ManualAdjustments(exposureEV: 0.7))]))
        _ = try renderer.render(frame, settings: slid)
        #expect(gpu.maskRefiner.statistics.builds == 1 && gpu.maskFields.statistics.bakes == 1)
    }
}

/// What the cache keeps, and what refuses.
@Suite struct MaskRefinerCacheTests {
    private let picture = try! MaskSpace(width: 7008, height: 4672)

    @Test func aSliderNeverRebuildsAndANewDecodeDoes() throws {
        let gpu = try GPU()
        let (pixels, matte) = Refine.scene(width: 1200, height: 800)
        let raster = try Refine.seed(matte: matte, width: 1200, height: 800, seedWidth: 378, seedHeight: 252, binary: true)
        gpu.maskRefiner.seeds = Refine.Seeds([raster])
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let frame = try MaskRender.frame(gpu, pixels, width: 1200, picture: picture)
        let component = try Refine.component(.sky, raster)
        for ev in stride(from: Float(-3), through: 3, by: 0.5) where ev != 0 {
            let settings = DevelopSettings(manual: try MaskRender.manual(masks: [Mask(components: [component], adjustments: try ManualAdjustments(exposureEV: ev))]))
            _ = try renderer.render(frame, settings: settings)
        }
        // A 1200 px frame is smaller than the slice, so it is its own guide frame: none is made.
        #expect(gpu.maskRefiner.statistics.builds == 1 && gpu.maskRefiner.statistics.guideFrames == 0)
        #expect(gpu.maskFields.statistics.bakes == 1)
        // Its coefficients and its refined field at the slice's size, which the bake read: 6.35 MB, 6.70 as Metal allocates them.
        let kept = 378 * 252 * 8 + 2048 * 1365 * 2
        #expect(gpu.maskRefiner.residentBytes >= kept && gpu.maskRefiner.residentBytes < kept + (512 << 10))
        // The same pixels in another decode: refined again, its own field.
        let again = try MaskRender.frame(gpu, pixels, width: 1200, picture: picture)
        let settings = DevelopSettings(manual: try MaskRender.manual(masks: [Mask(components: [component], adjustments: try ManualAdjustments(exposureEV: -1))]))
        _ = try renderer.render(again, settings: settings)
        #expect(gpu.maskRefiner.statistics.builds == 2 && gpu.maskFields.statistics.bakes == 2)
        // A develop's limit keeps nothing between frames.
        gpu.maskRefiner.maximumBytes = 0
        #expect(gpu.maskRefiner.residentBytes == 0)
    }

    @Test func aLostOrPendingSeedRefusesRatherThanRenderWithoutTheMask() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let frame = try MaskRender.frame(gpu, [SIMD3<Float>](repeating: SIMD3(0.2, 0.2, 0.2), count: 1200 * 800), width: 1200)
        let raster = try Refine.constant(77)
        func settings(_ component: MaskComponent) throws -> DevelopSettings {
            DevelopSettings(manual: try MaskRender.manual(masks: [Mask(components: [component], adjustments: try ManualAdjustments(exposureEV: -1))]))
        }
        let smart = try Refine.component(.sky, raster)
        #expect(throws: MaskRefinerError.noSeedStore) { try renderer.render(frame, settings: try settings(smart)) }
        gpu.maskRefiner.seeds = Refine.Seeds([])
        #expect(throws: MaskRefinerError.seedUnavailable(raster.identity)) { try renderer.render(frame, settings: try settings(smart)) }
        let pending = MaskComponent(shape: .smart(SmartSelection(kind: .person)))
        #expect(throws: MaskRefinerError.selectionPending(.person)) { try renderer.render(frame, settings: try settings(pending)) }
        // Off, or with no slider, a smart mask is not read.
        let idle = DevelopSettings(manual: try MaskRender.manual(masks: [Mask(components: [smart])]))
        _ = try renderer.render(frame, settings: idle)
        #expect(!gpu.maskRefiner.hasPipelines)
    }
}

/// What the develop's memory gate counts for a frame's smart masks.
@Suite struct MaskRefinerDevelopBytesTests {
    @Test func threeSmartMasksCountTheirPeak() throws {
        let picture = try MaskSpace(width: 7008, height: 4672)
        let sky = try Refine.component(.sky, Refine.constant(1, width: 756, height: 504))
        let person = try Refine.component(.person, Refine.constant(2, width: 2016, height: 1512))
        let subject = try Refine.component(.subject, Refine.constant(3, width: 512, height: 512))
        let exposure = try ManualAdjustments(exposureEV: -1)
        let three = try MaskSet(masks: [sky, person, subject].map { Mask(components: [$0], adjustments: exposure) })
        let bytes = MaskRefiner.developBytes(masks: three, picture: picture)
        MaskRender.report("develop bytes for Sky, Person and Subject: \(bytes) (\(bytes >> 20) MiB)")
        // The guide frame 22.4 MB, coefficients 3.0 + 6.1 + 2.1 MB, three refined fields 16.8 MB, the person matte's working set and
        // seed 32.5 MB.
        #expect(bytes > 80_000_000 && bytes < 86_000_000)
        // The same seed twice counts once; a smart mask that is off, or none, nothing.
        let twice = try MaskSet(masks: [Mask(components: [sky], adjustments: exposure), Mask(components: [sky], adjustments: exposure)])
        #expect(MaskRefiner.developBytes(masks: twice, picture: picture) == MaskRefiner.developBytes(masks: try MaskSet(masks: [twice.masks[0]]), picture: picture))
        #expect(MaskRefiner.developBytes(masks: try MaskSet(masks: [Mask(isEnabled: false, components: [sky], adjustments: exposure)]), picture: picture) == 0)
        #expect(MaskRefiner.developBytes(masks: try MaskSet(masks: [MaskRender.mask(MaskRender.everywhere, exposure)]), picture: picture) == 0)
    }
}

/// A frame whose masks are gradients renders as Phase 1 did, byte for byte: the bake, the kernels and the keys of gradients are
/// unchanged. The digests are Phase 1's own, taken at `bceb32a` with this same test.
@Suite struct MaskRefinerPhaseOneTests {
    @Test func aFrameWithoutSmartMasksRendersAsPhaseOne() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let pixels = LightToneFrame.pixels(), width = LightToneFrame.width
        let sets: [[Mask]] = [
            [MaskRender.mask(MaskRender.linear(0.1, 0.05, 0.2, 0.6), try ManualAdjustments(exposureEV: -1.5))],
            [MaskRender.mask(MaskRender.radial(0.5, 0.3, 0.3, 0.2, feather: 35), try ManualAdjustments(highlights: -60, shadows: 40), amount: 1.4),
             MaskRender.mask(MaskRender.linear(0.9, 0.6, 0.3, 0.1), try ManualAdjustments(exposureEV: 0.8, contrast: 30, whites: 20, blacks: -35))],
        ]
        var digests: [String] = []
        for masks in sets {
            let frame = try MaskRender.frame(gpu, pixels, width: width, picture: try MaskSpace(width: 7008, height: 4672))
            let settings = DevelopSettings(halation: true, sharpen: true, manual: try MaskRender.manual(try ManualAdjustments(shadows: 20), masks: masks, reference: 0.3))
            let bits = MaskRender.bits(try renderer.render(frame, settings: settings).image.texture)
            digests.append(bits.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() })
        }
        MaskRender.report("phase 1 digests: \(digests)")
        #expect(digests == Self.phaseOne)
        #expect(!gpu.maskRefiner.hasPipelines)
    }

    static let phaseOne = ["ec26063e1c55c8986014265959c85dfc7548b015daf2e6fbfb1f89666b060db7",
                           "ecd84f181a9df68d7f2435af2149e31f10bf2b0a15053ae7ad3587682f85053a"]
}

extension MaskRefinerCacheTests {
    @Test func anotherGeometryResamplesASeedOnceUnderItsOwnKey() throws {
        let gpu = try GPU()
        let a = try LensGeometry(table: RadialTable(knots: [1, 0.96]), scale: 1)
        let b = ResolvedLensCorrection.identity.geometry
        let raster = try MaskRaster(width: 64, height: 48, plane: (0..<(64 * 48)).map { $0 % 64 < 20 ? 255 : 0 })
        let remap = try #require(LensRemap(from: b, to: a, extent: picture.extent))
        // Independent bilinear read at each destination texel centre, with the seed's top-left origin.
        func sample(_ p: MaskPoint) -> Float {
            let x = p.x / picture.extent.x * Float(raster.width) - 0.5
            let y = p.y / picture.extent.y * Float(raster.height) - 0.5
            let ix = Int(floor(x)), iy = Int(floor(y)), fx = x - Float(ix), fy = y - Float(iy)
            func at(_ x: Int, _ y: Int) -> Float {
                Float(raster.plane[min(raster.height - 1, max(0, y)) * raster.width + min(raster.width - 1, max(0, x))])
            }
            let top = at(ix, iy) * (1 - fx) + at(ix + 1, iy) * fx
            let bottom = at(ix, iy + 1) * (1 - fx) + at(ix + 1, iy + 1) * fx
            return top * (1 - fy) + bottom * fy
        }
        let expected = try MaskRaster(width: raster.width, height: raster.height, plane: (0..<raster.plane.count).map { i in
            let point = MaskPoint(x: (Float(i % raster.width) + 0.5) / Float(raster.width) * picture.extent.x,
                                  y: (Float(i / raster.width) + 0.5) / Float(raster.height) * picture.extent.y)
            return UInt8(min(255, max(0, sample(remap.point(point)).rounded())))
        })
        try #require(expected.plane != raster.plane)
        let seeds = Refine.Seeds([raster, expected])
        let base = try MaskRender.frame(gpu, [SIMD3<Float>](repeating: .init(repeating: 0.2), count: 1200 * 800), width: 1200, picture: picture)
        let correction = try ResolvedLensCorrection(red: b.table, green: b.table, blue: b.table, gain: .one, status: .init(), scale: b.scale).remembering(legacy: a)
        let frame = LinearFrame(image: base.image, decoderVersion: base.decoderVersion, scale: base.scale, picture: picture, lens: correction)
        let plain = gpu.maskRefiner.session(for: base, picture: picture, seeds: seeds)
        let mapped = gpu.maskRefiner.session(for: frame, picture: picture, seeds: seeds)
        for edge in [SmartEdge.matte, .crisp] {
            let selection = SmartSelection(kind: .subject, raster: raster.ref,
                                           frame: try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: false, geometry: a), edge: edge)
            let original = try plain.coefficients(for: selection)
            let moved = try mapped.coefficients(for: selection)
            let hits = gpu.maskRefiner.statistics.hits
            let again = try mapped.coefficients(for: selection)
            #expect(original !== moved && moved === again)
            #expect(gpu.maskRefiner.statistics.hits == hits + 1)
            var reference = selection
            reference.raster = expected.ref
            reference.frame?.geometry = b
            let truth = try mapped.coefficients(for: reference)
            if edge == .matte {
                func bytes(_ texture: MTLTexture) -> [UInt8] {
                    var plane = [UInt8](repeating: 0, count: texture.width * texture.height)
                    plane.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width,
                                                                    from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }
                    return plane
                }
                let values = bytes(moved), expectedValues = bytes(truth)
                #expect(zip(values, expectedValues).map { abs(Int($0) - Int($1)) }.max()! <= 1)
                #expect(values != bytes(original))
            } else {
                let values = Refine.coefficients(moved), expectedValues = Refine.coefficients(truth)
                let error = zip(values, expectedValues).map { abs($0.w - $1.w) }.max()!
                #expect(error < 0.005, "crisp resampled pixels: \(error)")
                #expect(values != Refine.coefficients(original))
            }
            let before = try plain.field(for: selection), after = try mapped.field(for: selection)
            #expect(before !== after)
        }
    }
}
