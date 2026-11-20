import Foundation
import Metal
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// What a mask's balance costs one frame's render, on a real raw and a real Sky seed (DSC04100, the hardest of `MaskBalanceEdgeTests`' frames),
/// grain off and halation and sharpening on as the app renders. Each render waits for its command buffer (`FilmRenderer.render`). It runs only
/// when asked, in release:
///
///     ARGENT_MEASURE=1 ARGENT_BALANCE_OUT=<folder> swift test -c release -Xswiftc -enable-testing --filter MaskBalanceCostTests
///
/// `cost.csv` goes into the folder. Three states of the caches, each timed apart:
/// - steady: fields and coefficients warm, the state every step of a drag sees. The values move a little from render to render, as a drag's do,
///   and the counters before and after prove nothing was baked or built.
/// - rebake: the refinement kept and the coverage array gone, what a change of a mask's shape costs when its selection is the same (it also
///   pays the new array's allocation, which the app's cache mostly avoids by writing over its last).
/// - cold: both gone, the first render of a selection on a decode.
///
/// The drag's size is `ARGENT_BALANCE_DRAG_PIXELS`, 2190 by default: a drag has no size of its own, it renders at the frame view's own pixels
/// (`FrameLayout.pixels`, window-dependent, at most 4912), and 2190 is the frame view the validation record times.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] != nil))
struct MaskBalanceCostTests {
    enum Kind: Int, CaseIterable {
        case none = 1, exposure, balance, both, balanceTierOne, highlights

        var name: String {
            switch self {
            case .none: "1 no masks"
            case .exposure: "2 Exposure (tier 2)"
            case .balance: "3 Balance (tier 2)"
            case .both: "4 Exposure + Balance (tier 2)"
            case .balanceTierOne: "5 Balance (forced tier 1)"
            case .highlights: "6 Highlights (tier 1)"
            }
        }
    }

    static let stem = "DSC04100"
    static let dragPixels = ProcessInfo.processInfo.environment["ARGENT_BALANCE_DRAG_PIXELS"].flatMap(Int.init) ?? 2190
    /// Renders thrown away after each change of case, then those kept, in sweeps, so drift spreads over every case.
    static let warmup = 3, kept = 10, sweeps = 6
    /// Renders timed in each of the rebake and cold states.
    static let firstRenders = 20
    /// One mask id throughout, as a drag has.
    static let maskID = UUID()

    /// `base` with the one mask, its value `step` of a drag.
    static func settings(_ kind: Kind, step: Int, base: DevelopSettings, selection: MaskComponent) throws -> DevelopSettings {
        let nudge = Float(step % 9)
        let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let nothing = MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: MaskRefinerSurfaceTests.emptySeed.ref, frame: frame)))
        let adjustments: ManualAdjustments, balance: MaskBalance, components: [MaskComponent]
        switch kind {
        case .none: return base
        case .exposure: (adjustments, balance, components) = (try ManualAdjustments(exposureEV: 0.4 + nudge * 0.01), .neutral, [selection])
        case .balance: (adjustments, balance, components) = (.identity, MaskBalance(warmth: 30 + nudge), [selection])
        case .both: (adjustments, balance, components) = (try ManualAdjustments(exposureEV: 0.4 + nudge * 0.01), MaskBalance(warmth: 30 + nudge), [selection])
        case .balanceTierOne: (adjustments, balance, components) = (.identity, MaskBalance(warmth: 30 + nudge), [selection, nothing])
        case .highlights: (adjustments, balance, components) = (try ManualAdjustments(highlights: -30 - nudge), .neutral, [selection])
        }
        var s = base
        let mask = Mask(id: maskID, components: components, adjustments: adjustments, balance: balance)
        s.manual = try ManualRenderSettings(adjustments: ManualAdjustments.identity.settingMasks(try MaskSet(masks: [mask])), referenceStops: base.manual.referenceStops)
        return s
    }

    struct Times {
        var wall: [Double] = []
        var gpu: [Double] = []
        mutating func add(_ t: (wall: Double, gpu: Double)) { wall.append(t.wall); gpu.append(t.gpu) }
    }

    /// One render, to its command buffer's completion: the whole call, setup included, and the GPU's time for the Negative and Print passes.
    static func timed(_ renderer: FilmRenderer, _ frame: LinearFrame, _ settings: DevelopSettings) throws -> (wall: Double, gpu: Double) {
        try autoreleasepool {
            let start = ContinuousClock.now
            let rendered = try renderer.render(frame, settings: settings)
            let wall = FrameViewMeasureTests.ms(ContinuousClock.now - start)
            return (wall, rendered.gpuSeconds * 1000)
        }
    }

    static func quantile(_ values: [Double], _ q: Double) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return .nan }
        let at = q * Double(s.count - 1), low = Int(at.rounded(.down)), high = Int(at.rounded(.up))
        return s[low] + (s[high] - s[low]) * (at - Double(low))
    }

    static func median(_ values: [Double]) -> Double { quantile(values, 0.5) }

    /// The three states of one frame, returned by case.
    static func measure(_ c: MaskRefinerSurfaceTests.Context, frame: LinearFrame, base: DevelopSettings, selection: MaskComponent,
                        label: String) throws -> (steady: [Kind: Times], rebake: [Kind: Times], cold: [Kind: Times]) {
        func settings(_ kind: Kind, _ step: Int) throws -> DevelopSettings { try Self.settings(kind, step: step, base: base, selection: selection) }
        // Pipelines compiled, every array and refinement in the caches.
        for kind in Kind.allCases { for step in 0..<4 { _ = try timed(c.renderer, frame, try settings(kind, step)) } }

        var steady: [Kind: Times] = [:], rebake: [Kind: Times] = [:], cold: [Kind: Times] = [:]
        // A kept render must make nothing. A case's first renders may (case 5's field is written over the others'), and those are the warmup, not counted here.
        var fieldHits = 0, bakes = 0, moves = 0, allocations = 0, refinerHits = 0, builds = 0, guideFrames = 0
        var step = 0
        for _ in 0..<sweeps {
            for kind in Kind.allCases {
                for _ in 0..<warmup { _ = try timed(c.renderer, frame, try settings(kind, step)); step += 1 }
                let fields = c.gpu.maskFields.statistics, refiner = c.gpu.maskRefiner.statistics
                for _ in 0..<kept {
                    let s = try settings(kind, step)
                    steady[kind, default: Times()].add(try timed(c.renderer, frame, s))
                    step += 1
                }
                let f = c.gpu.maskFields.statistics, r = c.gpu.maskRefiner.statistics
                fieldHits += f.hits - fields.hits; bakes += f.bakes - fields.bakes; moves += f.moves - fields.moves; allocations += f.allocations - fields.allocations
                refinerHits += r.hits - refiner.hits; builds += r.builds - refiner.builds; guideFrames += r.guideFrames - refiner.guideFrames
            }
        }
        print("MEASURE \(label) steady, what the caches did during the kept renders: field hits +\(fieldHits), bakes +\(bakes), moves +\(moves), "
              + "allocations +\(allocations); refiner hits +\(refinerHits), builds +\(builds), guide frames +\(guideFrames)")
        #expect(bakes == 0 && allocations == 0 && builds == 0 && guideFrames == 0, "\(label): a steady render made something")

        for kind in Kind.allCases where kind != .none {
            for _ in 0..<firstRenders {
                c.gpu.maskFields.removeAll()
                let s = try settings(kind, step)
                rebake[kind, default: Times()].add(try timed(c.renderer, frame, s))
                step += 1
            }
            for _ in 0..<firstRenders {
                c.gpu.maskRefiner.removeAll()
                c.gpu.maskFields.removeAll()
                let s = try settings(kind, step)
                cold[kind, default: Times()].add(try timed(c.renderer, frame, s))
                step += 1
            }
        }
        return (steady, rebake, cold)
    }

    @Test func theTable() throws {
        let c = try MaskRefinerSurfaceTests.context()
        try FileManager.default.createDirectory(at: MaskBalanceEdgeTests.out, withIntermediateDirectories: true)
        let raw = MaskBalanceEdgeTests.probe.appendingPathComponent(Self.stem + ".ARW")

        var options = DecodeOptions()
        options.tileSize = RollDeveloper.decodeTile
        options.learnedTileSize = RollDeveloper.learnedDecodeTile
        let full = try c.decoder.decode(raw, options: options)
        let drag = try c.decoder.decode(raw, options: FilmPreviews.frameDecodeOptions(longSide: Self.dragPixels))
        print("MEASURE frames: full \(full.width)x\(full.height) scale \(full.scale), drag \(drag.width)x\(drag.height) scale \(drag.scale) picture \(String(describing: drag.picture))")

        let entry = MaskRefinerSurfaceTests.Entry(stem: Self.stem, raw: raw.path, kind: "sky",
                                                  seed: MaskBalanceEdgeTests.seeds.appendingPathComponent(Self.stem + ".out.f32").path,
                                                  format: "f32", seedWidth: nil, seedHeight: nil, surfaces: nil, proof: nil)
        let raster = try MaskRefinerSurfaceTests.seed(entry, frameWidth: full.width, frameHeight: full.height)
        c.seeds.add(raster)
        let base = try MaskRefinerSurfaceTests.settings(c, raw, grain: false)
        let selection = try MaskRefinerSurfaceTests.component("sky", raster, background: false, width: full.width, height: full.height)
        #expect(MaskRefiner.perPixelSlots(try Self.settings(.balance, step: 0, base: base, selection: selection).manual.adjustments.masks.masks) == [0])
        #expect(MaskRefiner.perPixelSlots(try Self.settings(.balanceTierOne, step: 0, base: base, selection: selection).manual.adjustments.masks.masks).isEmpty)

        var csv = "size,case,steady median ms,steady p25,steady p75,steady min,n,gpu median ms,rebake median ms,cold median ms,gpu cold median ms,vs case 2 ms,vs case 2 percent\n"
        for (label, frame) in [("drag \(Self.dragPixels) px", drag), ("full \(max(full.width, full.height)) px", full)] {
            let measured = try Self.measure(c, frame: frame, base: base, selection: selection, label: label)
            let reference = Self.median(measured.steady[.exposure]?.wall ?? [])
            print("MEASURE \(label), median ms of \(Self.kept * Self.sweeps) renders, caches warm:")
            for kind in Kind.allCases {
                let steady = measured.steady[kind] ?? Times()
                let wall = Self.median(steady.wall), gpu = Self.median(steady.gpu)
                let rebake = measured.rebake[kind].map { Self.median($0.wall) } ?? .nan
                let cold = measured.cold[kind].map { Self.median($0.wall) } ?? .nan
                let coldGPU = measured.cold[kind].map { Self.median($0.gpu) } ?? .nan
                let ms = wall - reference, percent = 100 * ms / reference
                print(String(format: "MEASURE   %-30@ steady %8.3f (p25 %7.3f p75 %7.3f min %7.3f) gpu %8.3f  vs case 2 %+8.3f ms %+7.1f%%   rebake %8.3f  cold %8.3f (gpu %7.3f)",
                             kind.name as NSString, wall, Self.quantile(steady.wall, 0.25), Self.quantile(steady.wall, 0.75), steady.wall.min() ?? .nan, gpu, ms, percent, rebake, cold, coldGPU))
                csv += String(format: "%@,%@,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.2f\n", label as NSString, kind.name as NSString, wall,
                              Self.quantile(steady.wall, 0.25), Self.quantile(steady.wall, 0.75), steady.wall.min() ?? .nan, steady.wall.count, gpu, rebake, cold, coldGPU, ms, percent)
            }
        }
        let url = MaskBalanceEdgeTests.out.appendingPathComponent("cost.csv")
        try Data(csv.utf8).write(to: url)
        print("MEASURE wrote \(url.path)")
    }
}
