import Foundation
import Metal
import simd
import Testing
@testable import ArgentCore

/// A mask's print balance (`MaskBalance`): that it is written only when set, and that it is the frame's Lab balance on the mask's own pixels.
@Suite struct MaskBalanceTests {
    /// A ramp of neutrals and colours, wide enough that the LUTs' whole range is read.
    private static let width = 32
    private static var pixels: [SIMD3<Float>] {
        (0..<(width * 16)).map { i in
            let level = 0.005 * pow(2, Float(i % width) * 0.27)
            switch (i / width) % 4 {
            case 0: return SIMD3(repeating: level)
            case 1: return SIMD3(level, level * 0.7, level * 0.45)
            case 2: return SIMD3(level * 0.45, level * 0.75, level)
            default: return SIMD3(level * 0.6, level, level * 0.5)
            }
        }
    }

    private static func masked(_ balance: MaskBalance, amount: Float = 1, adjustments: ManualAdjustments = .identity,
                               isEnabled: Bool = true) -> Mask {
        Mask(isEnabled: isEnabled, components: [MaskRender.everywhere], amount: amount, adjustments: adjustments, balance: balance)
    }

    private static func print(_ gpu: GPU, _ renderer: FilmRenderer, _ settings: DevelopSettings) throws -> [SIMD3<Float>] {
        let frame = try MaskRender.frame(gpu, pixels, width: width)
        return MaskRender.read(try renderer.render(frame, settings: settings).image.texture)
    }

    /// The paper stops a balance is, per channel, as Lab balance takes them.
    private static func labBalance(_ balance: MaskBalance, amount: Float = 1) -> SIMD3<Float> {
        (MaskBalance.warmthAxis * balance.warmth + MaskBalance.magentaAxis * balance.magenta) * amount
    }

    private static func lab(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let xyz = SIMD3<Float>(0.636958 * rgb.x + 0.144617 * rgb.y + 0.168881 * rgb.z,
                               0.262700 * rgb.x + 0.677998 * rgb.y + 0.059302 * rgb.z,
                               0.028073 * rgb.y + 1.060985 * rgb.z) / SIMD3(0.95047, 1, 1.08883)
        func f(_ t: Float) -> Float { t > 0.008856 ? pow(t, 1 / 3) : 7.787 * t + 16 / 116 }
        return SIMD3(116 * f(xyz.y) - 16, 500 * (f(xyz.x) - f(xyz.y)), 200 * (f(xyz.y) - f(xyz.z)))
    }

    // MARK: The record

    @Test func aMaskWithNoBalanceIsWrittenAsBefore() throws {
        let mask = Self.masked(.neutral)
        let set = try MaskSet(masks: [mask])
        #expect(MaskSet.schema(of: set.masks) == 1)
        let text = String(decoding: try JSONEncoder().encode(set), as: UTF8.self)
        #expect(!text.contains("balance") && text.contains(#""schema":1"#))
    }

    @Test func aBalanceRoundTripsAndMovesTheDigest() throws {
        let id = UUID()
        let plain = try MaskSet(masks: [Mask(id: id, components: [MaskRender.everywhere])])
        let set = try MaskSet(masks: [Mask(id: id, components: [MaskRender.everywhere], balance: MaskBalance(warmth: -40, magenta: 12))])
        #expect(set.digest != plain.digest)
        #expect(MaskSet.schema(of: set.masks) == 5)
        let read = try JSONDecoder().decode(MaskSet.self, from: try JSONEncoder().encode(set))
        #expect(read == set && read.masks[0].balance == MaskBalance(warmth: -40, magenta: 12))
    }

    @Test func aBalanceInARecordBelowSchemaFiveIsRefused() throws {
        let set = try MaskSet(masks: [Self.masked(MaskBalance(warmth: 10))])
        let text = String(decoding: try JSONEncoder().encode(set), as: UTF8.self).replacingOccurrences(of: #""schema":5"#, with: #""schema":4"#)
        #expect(throws: MaskError.self) { try JSONDecoder().decode(MaskSet.self, from: Data(text.utf8)) }
    }

    @Test func aBalanceOutsideItsRangeIsRefused() {
        #expect(throws: MaskError.self) { try MaskSet(masks: [Self.masked(MaskBalance(warmth: 101))]) }
    }

    @Test func anotherPictureKeepsTheBalance() throws {
        let set = try MaskSet(masks: [Self.masked(MaskBalance(warmth: 33))])
        #expect(try set.forAnotherPicture(freshIDs: true).masks[0].balance.warmth == 33)
    }

    @Test func aBalanceAloneIsAnEffectiveMask() throws {
        let on = try MaskRender.manual(masks: [Self.masked(MaskBalance(magenta: 5))])
        let off = try MaskRender.manual(masks: [Self.masked(MaskBalance(magenta: 5), isEnabled: false)])
        let none = try MaskRender.manual(masks: [Self.masked(MaskBalance(magenta: 5), amount: 0)])
        #expect(on.hasEffectiveMasks && !off.hasEffectiveMasks && !none.hasEffectiveMasks)
    }

    @Test func aBalanceTakesAPerPixelSelectionAsExposureDoes() throws {
        let raster = try MaskRaster(width: 64, height: 48, plane: [UInt8](repeating: 128, count: 64 * 48))
        let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let sky = MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: raster.ref, frame: frame)))
        #expect(MaskRefiner.perPixelSelection(Mask(components: [sky], balance: MaskBalance(warmth: 20))) != nil)
        #expect(MaskRefiner.perPixelSelection(Mask(components: [sky])) == nil)
    }

    // MARK: The print

    @Test func theParameterBlockHasTheKernelsLayout() {
        #expect(MemoryLayout<LocalMaskParameters>.offset(of: \.balanceAny) == 428)
        #expect(MemoryLayout<LocalMaskParameters>.offset(of: \.warmth) == 432)
        #expect(MemoryLayout<LocalMaskParameters>.offset(of: \.magenta) == 496)
        #expect(MemoryLayout<LocalMaskParameters>.offset(of: \.warmthAxis) == 560)
        #expect(MemoryLayout<LocalMaskParameters>.offset(of: \.magentaAxis) == 576)
    }

    /// Where a mask covers every pixel, its balance is the frame's Lab balance by that much: the same move in the same units.
    @Test func aFullMaskIsTheFramesLabBalance() throws {
        let gpu = try GPU()
        for stock in try MaskRender.stocks() {
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            for (balance, amount) in [(MaskBalance(warmth: 100), Float(1)), (MaskBalance(warmth: -60, magenta: 80), 1), (MaskBalance(magenta: -100), 0.5)] {
                let masked = DevelopSettings(manual: try MaskRender.manual(masks: [Self.masked(balance, amount: amount)]))
                let global = DevelopSettings(labBalance: Self.labBalance(balance, amount: amount), manual: try MaskRender.manual())
                let a = try Self.print(gpu, renderer, masked), b = try Self.print(gpu, renderer, global)
                let worst = zip(a, b).map { MaskRender.apart($0, $1) }.max() ?? .infinity
                MaskRender.report("\(stock.id) balance \(balance) amount \(amount): worst channel apart \(worst)")
                #expect(worst < 2e-3, "\(stock.id) \(balance)")
            }
        }
    }

    /// Over a frame's own Lab balance and print exposure, a full mask's balance is still that much more Lab balance: the frame's offset and the
    /// mask's amounts add before the print's saturate, in either order the same sum. Its tolerance is `aFullMaskIsTheFramesLabBalance`'s.
    @Test func aFullMaskOverAFramesOwnBalanceIsTheSummedBalance() throws {
        let gpu = try GPU()
        let own = SIMD3<Float>(0.08, -0.05, 0.12), printExposure: Float = -0.35
        for stock in try MaskRender.stocks() {
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            for (balance, amount) in [(MaskBalance(warmth: 100), Float(1)), (MaskBalance(warmth: -60, magenta: 80), 1), (MaskBalance(magenta: -100), 0.5),
                                      (MaskBalance(warmth: 100, magenta: -100), 2)] {
                let masked = DevelopSettings(labBalance: own, printExposure: printExposure, manual: try MaskRender.manual(masks: [Self.masked(balance, amount: amount)]))
                let summed = DevelopSettings(labBalance: own + Self.labBalance(balance, amount: amount), printExposure: printExposure, manual: try MaskRender.manual())
                let a = try Self.print(gpu, renderer, masked), b = try Self.print(gpu, renderer, summed)
                let worst = zip(a, b).map { MaskRender.apart($0, $1) }.max() ?? .infinity
                MaskRender.report("\(stock.id) over own balance, \(balance) amount \(amount): worst channel apart \(worst)")
                #expect(worst < 2e-3, "\(stock.id) \(balance) \(amount)")
            }
        }
    }

    /// Capture sharpening reads the dye amounts the Negative LUT pass wrote, so a mask balance's step is detail to it, where a frame's Lab balance,
    /// added after sharpening, never is. Measured 2026-11-09 on a flat field (`MaskBalanceSharpenMeasureTests`, the six original stocks, three field
    /// levels, both sliders each way, Amount 1 and 2): the most sharpening moved a pixel in the band about the edge, |ΔL*| and ΔE*ab, was at the
    /// full-size develop 0.193 and 0.205 (Gold 200, mid gray, Magenta -100 at Amount 2, a 2.9 px transition), in a RAW 9 drag at 2190 px 0.023 and
    /// 0.058, from RAW 8's draft decode with its second mask 0.627 and 0.653, and in this render — the worst, 2048 px at full size's mask, where the
    /// 0.8 px transition is the hardest the field can make — 1.337 and 1.381, held under 1.6 and 1.7 (about a fifth to spare).
    ///
    /// Re-measured 2026-11-23 across all 14 current baked stocks: every `densityRange = 2.5` stock still stays under 1.6 and 1.7 (worst `cinestill-800t`
    /// 1.481 |ΔL*| and `fujifilm-superia-400` 1.535 ΔE*ab; `kodak-gold-200` 1.340 and 1.384). The two `densityRange = 2.0` stocks measure more because
    /// `CaptureSharpening.threshold` is in normalized dye amounts, and on them a dye unit is 2.0 density, not 2.5: the same density step is 25 % more
    /// units against the same soft threshold, so less of it is cored. With the threshold at 0 they are ordinary (`kodak-vision3-500t` 3.416 against
    /// 2.448 to 3.512 on the others); at 0.009 the 2.5 stocks keep 38 to 43 % of that and the two 2.0 stocks 53 and 55 %. `kodak-vision3-500t`: 0.299
    /// and 0.313 at the full-size develop, at the 0.3 L* estimated before measuring for a develop, 0.039 and 0.060 in a RAW 9 drag, 0.899 and 0.922
    /// from the draft decode, and 1.820 and 1.877 on this bound (`kodak-vision3-500t-cinema` 1.685 and 1.800). Those two stocks are held under 2.2 and
    /// 2.3, the same fifth to spare; every other stock keeps 1.6 and 1.7.
    @Test func captureSharpeningSeesABalancesEdgeOnlySlightly() throws {
        let gpu = try GPU()
        let geometry = BalanceEdge.bound
        let stocks = try MaskRender.stocks()
        let probe = try BalanceEdge.frame(gpu, geometry, level: BalanceEdge.levels[1].value)
        let renderer = try FilmRenderer(gpu: gpu, stock: stocks[0])
        let coverage = try Refine.probe(gpu, probe, try Refine.scene(renderer, probe, try BalanceEdge.settings(geometry, MaskBalance(warmth: 100), amount: 1, sharpen: true)), slot: 0)
        let edge = BalanceEdge.edge(coverage, geometry)
        #expect(edge.span < 1.0, "the bound is only one if the edge is about a pixel: \(edge.span)")
        var worstL: Float = 0, worstE: Float = 0
        let cinemaDensityStocks: Set<String> = ["kodak-vision3-500t", "kodak-vision3-500t-cinema"]
        for stock in stocks {
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            var stockL: Float = 0, stockE: Float = 0
            for level in BalanceEdge.levels {
                let frame = try BalanceEdge.frame(gpu, geometry, level: level.value)
                for slider in BalanceEdge.sliders {
                    let on = try renderer.render(frame, settings: try BalanceEdge.settings(geometry, slider.balance, amount: 2, sharpen: true))
                    let off = try renderer.render(frame, settings: try BalanceEdge.settings(geometry, slider.balance, amount: 2, sharpen: false))
                    let result = BalanceEdge.compare(sharpened: on.image.texture, plain: off.image.texture, geometry, crossings: edge.crossings, rowStep: 4)
                    MaskRender.report("\(stock.id) \(level.name) \(slider.name) amount 2: band max |dL*| \(result.maximumL), max dE*ab \(result.maximumE), far from the edge \(result.farL)")
                    stockL = max(stockL, result.maximumL)
                    stockE = max(stockE, result.maximumE)
                    #expect(result.farL < 1e-3, "sharpening moved a flat part of the frame: \(stock.id) \(level.name) \(slider.name)")
                }
            }
            worstL = max(worstL, stockL)
            worstE = max(worstE, stockE)
            let (limitL, limitE): (Float, Float) = cinemaDensityStocks.contains(stock.id) ? (2.2, 2.3) : (1.6, 1.7)
            #expect(stockL < limitL && stockE < limitE, "\(stock.id): |dL*| \(stockL) (limit \(limitL)), dE*ab \(stockE) (limit \(limitE))")
        }
        MaskRender.report("sharpening at a balance's edge, worst of every stock: |dL*| \(worstL), dE*ab \(worstE)")
    }

    /// The same through the halation kernels.
    @Test func aFullMaskIsTheFramesLabBalanceThroughHalation() throws {
        let gpu = try GPU()
        let balance = MaskBalance(warmth: -70, magenta: 90)
        for stock in try MaskRender.stocks() {
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            let masked = DevelopSettings(halation: true, manual: try MaskRender.manual(masks: [Self.masked(balance)]))
            let global = DevelopSettings(labBalance: Self.labBalance(balance), halation: true, manual: try MaskRender.manual())
            let a = try Self.print(gpu, renderer, masked), b = try Self.print(gpu, renderer, global)
            let worst = zip(a, b).map { MaskRender.apart($0, $1) }.max() ?? .infinity
            MaskRender.report("\(stock.id) with halation: worst channel apart \(worst)")
            #expect(worst < 2e-3, "\(stock.id)")
        }
    }

    /// Under Auto's tone step a mask's balance is not the frame's Lab balance, and is not meant to be. The tone step's table is solved through
    /// the stock around the frame's own balance, to hold the colour a gray prints without the step (`PrintTone.table`): a frame's Lab balance
    /// solves it again, so a burned sky keeps the near-white it had on the paper's shoulder and barely takes the balance. A mask's balance is
    /// the same shift in the dye amounts on top of the table the frame already has, so the burned sky takes it as a mid-tone does. This holds how
    /// far apart the two are on burned neutrals at Auto's limits and a full slider, and that the mask is the one that still moves them.
    @Test func underTheToneStepAMaskIsTheShiftWithoutSolvingTheStepAgain() throws {
        let gpu = try GPU()
        let limits = PrintTone(burn: 1.25, dodge: 0.5, referenceStops: 0)   // `RollControls`' burnLimit and dodgeLimit
        var worstBurned: Float = 0, least: Float = .infinity, worstDodged: Float = 0
        for stock in try MaskRender.stocks().dropFirst() {
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            for balance in [MaskBalance(warmth: 100), MaskBalance(magenta: 100)] {
                func run(_ settings: DevelopSettings) throws -> [SIMD3<Float>] { try Self.print(gpu, renderer, settings).map { Self.lab(simd_max($0, SIMD3<Float>.zero)) } }
                let plain = try run(DevelopSettings(manual: try MaskRender.manual(), tone: limits))
                let masked = try run(DevelopSettings(manual: try MaskRender.manual(masks: [Self.masked(balance)]), tone: limits))
                let global = try run(DevelopSettings(labBalance: Self.labBalance(balance), manual: try MaskRender.manual(), tone: limits))
                // The neutral ramp's burned end, two stops and more over the print's mid-gray: where the paper's shoulder was.
                for step in (0..<Self.width) where log2(Self.pixels[step].x / 0.18) > 2 {
                    let mask = simd_length(SIMD2(masked[step].y - plain[step].y, masked[step].z - plain[step].z))
                    let frame = simd_length(SIMD2(global[step].y - plain[step].y, global[step].z - plain[step].z))
                    MaskRender.report("\(stock.id) \(balance) at \(log2(Self.pixels[step].x / 0.18)) EV, L* \(plain[step].x): a*b* moved by the mask \(mask), by Lab balance \(frame), apart \(simd_length(masked[step] - global[step]))")
                    worstBurned = max(worstBurned, simd_length(masked[step] - global[step]))
                    least = min(least, mask - frame)
                }
                // The dodged end, from three stops under the print's mid-gray to a quarter under: the table is solved there too, and the two differ either way.
                for step in (0..<Self.width) where (-3 ... -0.25).contains(log2(Self.pixels[step].x / 0.18)) {
                    worstDodged = max(worstDodged, simd_length(masked[step] - global[step]))
                }
            }
        }
        MaskRender.report("burned neutrals under Auto's limits, full slider: mask and Lab balance at most \(worstBurned) ΔE apart; the mask moves a*b* at least \(least) more")
        // Measured 2026-11-09 on the six bundled stocks: Warmth by the mask moves a*b* 10.0 to 14.3 there and by Lab balance 0.8 to 5.5, Magenta 6.5
        // to 8.8 against 0.6 to 3.5; the two are up to 12.2 ΔE apart, and the mask is the stronger by 5.0 and more. On dodged neutrals, up to 7.7 apart.
        MaskRender.report("dodged neutrals under Auto's limits, full slider: mask and Lab balance at most \(worstDodged) ΔE apart")
        #expect(worstBurned < 15)
        #expect(least > 3)
        #expect(worstDodged < 10)
    }

    /// The render law on a balance: at each pixel the summed slider is Σ coverage × Amount × value, so the pixel prints as the whole frame would
    /// under that much Lab balance. Two gradients that cross, so most of the frame is partly in both, with the coverage the kernels' own
    /// (`local_mask_coverage_probe`). A kernel that left the coverage out passes every full-coverage test above and fails this one.
    @Test func aBalanceIsItsCoverageOfTheFramesLabBalance() throws {
        let gpu = try GPU()
        let masks = [Mask(components: [MaskRender.linear(0.3, 0.25, 0.7, 0.25)], balance: MaskBalance(warmth: 100)),
                     Mask(components: [MaskRender.linear(0.9, 0.25, 0.2, 0.25)], amount: 1.5, balance: MaskBalance(warmth: 30, magenta: -80))]
        let settings = DevelopSettings(manual: try MaskRender.manual(masks: masks))
        let rows = Self.pixels.count / Self.width
        for stock in try MaskRender.stocks() {
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            let frame = try MaskRender.frame(gpu, Self.pixels, width: Self.width)
            let scene = try Refine.scene(renderer, frame, settings)
            let coverage = try masks.indices.map { try Refine.probe(gpu, frame, scene, slot: $0) }
            let printed = MaskRender.read(try renderer.render(frame, settings: settings).image.texture)
            var worst: Float = 0, partial = 0, covered = 0, open = 0
            // Both gradients run along x, so a column has one coverage of each, and one render of the whole frame stands for the column.
            for column in 0..<Self.width {
                let c = coverage.map { $0[column] }
                for row in 1..<rows {
                    #expect(abs(coverage[0][row * Self.width + column] - c[0]) < 1e-4 && abs(coverage[1][row * Self.width + column] - c[1]) < 1e-4)
                }
                if c[0] > 0.05 && c[0] < 0.95 { partial += 1 } else if c[0] >= 0.999 { covered += 1 } else if c[0] <= 0.001 { open += 1 }
                let shift = zip(masks, c).reduce(SIMD3<Float>.zero) { $0 + Self.labBalance($1.0.balance, amount: $1.0.amount) * $1.1 }
                let whole = try Self.print(gpu, renderer, DevelopSettings(labBalance: shift, manual: try MaskRender.manual()))
                for row in 0..<rows { worst = max(worst, MaskRender.apart(printed[row * Self.width + column], whole[row * Self.width + column])) }
            }
            MaskRender.report("\(stock.id) balance by coverage: worst channel apart \(worst); columns partly covered \(partial), wholly \(covered), not at all \(open)")
            #expect(partial >= 6 && covered >= 2 && open >= 2, "the first gradient has to leave columns in, out and between: \(partial) \(covered) \(open)")
            #expect(worst < 2e-3, "\(stock.id)")
        }
    }

    /// The same law where the coverage is a smart selection's own at the pixel (tier 2), which a balance takes without Exposure: a selection alone,
    /// one inverted (Background) and one composed with a gradient. Pixels along the selection's edge, where the tiers differ, and some inside and
    /// outside it, each against the whole frame under that pixel's summed balance.
    @Test func aBalanceReadsASmartMasksCoverageAtThePixel() throws {
        let gpu = try GPU()
        let (width, height) = (1200, 800)
        let (pixels, matte) = Refine.scene(width: width, height: height)
        let raster = try Refine.seed(matte: matte, width: width, height: height, seedWidth: 378, seedHeight: 252, binary: true)
        gpu.maskRefiner.seeds = Refine.Seeds([raster])
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let frame = try MaskRender.frame(gpu, pixels, width: width, picture: try MaskSpace(width: 7008, height: 4672))
        let masks = [Mask(components: [try Refine.component(.sky, raster)], balance: MaskBalance(warmth: 100)),
                     Mask(components: [try Refine.component(.background, raster)], amount: 1.5, balance: MaskBalance(magenta: 60)),
                     Mask(components: [try Refine.component(.sky, raster), MaskRender.linear(0, 0, 0, 0.6)], balance: MaskBalance(warmth: 60, magenta: 40))]
        #expect(MaskRefiner.perPixelSlots(masks) == [0, 1, 2])
        let settings = DevelopSettings(manual: try MaskRender.manual(masks: masks))
        let scene = try Refine.scene(renderer, frame, settings)
        #expect(try #require(scene.masks).refinement.refined == 0b111)
        let coverage = try masks.indices.map { try Refine.probe(gpu, frame, scene, slot: $0) }
        // Held as renders, not as their textures: a texture let go returns to the pool, and the next render would print over it.
        let printed = try renderer.render(frame, settings: settings)
        let edge = coverage[0].indices.filter { coverage[0][$0] > 0.1 && coverage[0][$0] < 0.9 }
        let inside = coverage[0].indices.filter { coverage[0][$0] > 0.98 }, outside = coverage[0].indices.filter { coverage[0][$0] < 0.02 }
        #expect(edge.count >= 16 && !inside.isEmpty && !outside.isEmpty)
        func spread(_ indices: [Int], _ count: Int) -> [Int] { (0..<count).map { indices[$0 * (indices.count - 1) / max(count - 1, 1)] } }
        let plain = try renderer.render(frame, settings: DevelopSettings(manual: try MaskRender.manual()))
        var worst: Float = 0, moved: Float = 0
        for index in spread(edge, 16) + spread(inside, 3) + spread(outside, 3) {
            let shift = masks.indices.reduce(SIMD3<Float>.zero) { $0 + Self.labBalance(masks[$1].balance, amount: masks[$1].amount) * coverage[$1][index] }
            let whole = try renderer.render(frame, settings: DevelopSettings(labBalance: shift, manual: try MaskRender.manual()))
            let (x, y) = (index % width, index / width)
            let here = MaskRender.pixel(printed.image.texture, x: x, y: y)
            worst = max(worst, MaskRender.apart(here, MaskRender.pixel(whole.image.texture, x: x, y: y)))
            // The pixel has to have moved, or agreeing with the whole frame says nothing: an edge pixel carries a tenth of a slider and more.
            if coverage[0][index] > 0.1 { moved = max(moved, MaskRender.apart(here, MaskRender.pixel(plain.image.texture, x: x, y: y))) }
        }
        MaskRender.report("balance on tier 2, 22 pixels: worst channel apart \(worst); the most the balance moved one \(moved)")
        #expect(moved > 0.01)
        #expect(worst < 2e-3)
    }

    @Test func warmthWarmsAndMagentaTakesGreen() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: try #require(try MaskRender.stocks().last))
        let plain = try Self.print(gpu, renderer, DevelopSettings(manual: try MaskRender.manual()))
        func shift(_ balance: MaskBalance) throws -> SIMD3<Float> {
            let moved = try Self.print(gpu, renderer, DevelopSettings(manual: try MaskRender.manual(masks: [Self.masked(balance)])))
            return Self.lab(moved[Self.width / 2]) - Self.lab(plain[Self.width / 2])
        }
        let warm = try shift(MaskBalance(warmth: 100)), magenta = try shift(MaskBalance(magenta: 100))
        MaskRender.report("mid gray, full sliders: Warmth Δab \(warm.y) \(warm.z); Magenta Δab \(magenta.y) \(magenta.z)")
        #expect(warm.z > 1 && warm.y > -1)
        #expect(magenta.y > 1)
    }

    /// Overlapping masks at Amount 2 cannot pass `sumLimit`: sixteen of them print as two full sliders.
    @Test func aStackIsHeldToItsLimit() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let stack = (0..<16).map { _ in Self.masked(MaskBalance(warmth: 100), amount: 2) }
        let two = [Self.masked(MaskBalance(warmth: 100), amount: 2)]
        let a = try Self.print(gpu, renderer, DevelopSettings(manual: try MaskRender.manual(masks: stack)))
        let b = try Self.print(gpu, renderer, DevelopSettings(manual: try MaskRender.manual(masks: two)))
        #expect(zip(a, b).allSatisfy { MaskRender.apart($0, $1) < 1e-3 })
    }

    /// What a mask's Light reads under a balance, against what it would read were the balance the frame's: its tables are built for the frame's.
    @Test func howFarALightControlIsFromItsTablesUnderABalance() throws {
        let gpu = try GPU()
        var worst: Float = 0
        for stock in try MaskRender.stocks().dropFirst() {
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            let balance = MaskBalance(warmth: 100)
            for light in [try ManualAdjustments(contrast: 60), try ManualAdjustments(highlights: -80, shadows: 60), try ManualAdjustments(whites: 60, blacks: -60)] {
                let masked = DevelopSettings(manual: try MaskRender.manual(masks: [Self.masked(balance, adjustments: light)]))
                let global = DevelopSettings(labBalance: Self.labBalance(balance), manual: try MaskRender.manual(masks: [Self.masked(.neutral, adjustments: light)]))
                let a = try Self.print(gpu, renderer, masked), b = try Self.print(gpu, renderer, global)
                let apart = zip(a, b).map { simd_length(Self.lab(simd_max($0, SIMD3<Float>.zero)) - Self.lab(simd_max($1, SIMD3<Float>.zero))) }.sorted()
                let p99 = apart[apart.count * 99 / 100]
                // How far the Light itself moved those pixels, for scale, and where along the ramp the gap sits.
                let plain = try Self.print(gpu, renderer, DevelopSettings(manual: try MaskRender.manual()))
                let moved = try Self.print(gpu, renderer, DevelopSettings(manual: try MaskRender.manual(masks: [Self.masked(.neutral, adjustments: light)])))
                let effect = zip(plain, moved).map { simd_length(Self.lab(simd_max($0, SIMD3<Float>.zero)) - Self.lab(simd_max($1, SIMD3<Float>.zero))) }.sorted()
                let gaps = zip(a, b).map { simd_length(Self.lab(simd_max($0, SIMD3<Float>.zero)) - Self.lab(simd_max($1, SIMD3<Float>.zero))) }
                let neutral = (0..<Self.width).map { gaps[$0] }.map { String(format: "%.1f", $0) }.joined(separator: " ")
                let name = ManualAdjustments.Control.allCases.filter { light.value(for: $0) != 0 }.map { "\($0.title) \(Int(light.value(for: $0)))" }.joined(separator: ", ")
                MaskRender.report("\(stock.id) \(name): gap p50 \(apart[apart.count / 2]) p90 \(apart[apart.count * 9 / 10]) p99 \(p99); Light's own effect p50 \(effect[effect.count / 2]) p99 \(effect[effect.count * 99 / 100]); neutral ramp gaps: \(neutral)")
                worst = max(worst, apart[apart.count * 9 / 10])
            }
        }
        // The tail is Whites and Blacks' stretch at its clip points, up to 12 at p99 where the Light itself moves the pixel by 45 and more; the rest stay under 2.
        MaskRender.report("Light under a full Warmth, worst stock's p90 ΔE: \(worst)")
        #expect(worst < 3.5)
    }

    /// Grain's strength is read from the amounts the Negative LUT pass writes, which hold the balance, where Lab balance's shift is added after.
    @Test func howFarGrainMovesUnderABalance() throws {
        let gpu = try GPU()
        for stock in try MaskRender.stocks().dropFirst() where stock.grain != nil {
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            let side = 512
            let flat = [SIMD3<Float>](repeating: SIMD3(0.18, 0.18, 0.18), count: side * side)
            func spread(_ settings: DevelopSettings) throws -> SIMD3<Float> {
                let frame = try MaskRender.frame(gpu, flat, width: side)
                let values = MaskRender.read(try renderer.render(frame, settings: settings).image.texture)
                let mean = values.reduce(SIMD3<Float>.zero, +) / Float(values.count)
                let sum = values.reduce(SIMD3<Float>.zero) { $0 + ($1 - mean) * ($1 - mean) }
                return (sum / Float(values.count)).squareRoot()
            }
            let balance = MaskBalance(warmth: 100, magenta: 100)
            let masked = try spread(DevelopSettings(grain: 1, manual: try MaskRender.manual(masks: [Self.masked(balance)])))
            let global = try spread(DevelopSettings(labBalance: Self.labBalance(balance), grain: 1, manual: try MaskRender.manual()))
            let ratio = masked / global
            MaskRender.report("\(stock.id) grain under a full balance, masked / Lab balance: \(ratio)")
            #expect(abs(ratio.x - 1) < 0.1 && abs(ratio.y - 1) < 0.1 && abs(ratio.z - 1) < 0.1, "\(stock.id)")
        }
    }
}
