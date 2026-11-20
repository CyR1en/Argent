import Foundation
import Metal
import simd
import Testing
@testable import ArgentCore

/// What capture sharpening makes of a mask's balance at the mask's own edge, on a flat field, where the balance's step is the only detail in the
/// frame: every render made twice, with `DevelopSettings.sharpen` on and off, grain and halation off. `MaskBalanceTests` holds the bound; this
/// is the whole table, run when asked:
///
///     ARGENT_MEASURE=1 ARGENT_BALANCE_OUT=<folder> swift test -c release -Xswiftc -enable-testing --filter MaskBalanceSharpenMeasureTests
///
/// `sharpen.csv` goes into the folder.
enum BalanceEdge {
    /// How a frame is rendered: its pixels against the 2048 field (which set the coverage edge's width) and its scale and pins (which set the sharpener).
    struct Geometry: Sendable {
        let name: String
        let width: Int, height: Int
        let scale: Float
        /// A scaled decode in RAW 8's draft mode, which adds the sharpener's second mask.
        let draft: Bool
        let picture: MaskSpace
    }

    static let longest = try! MaskSpace(width: 7008, height: 4672)
    /// A full-size develop: 3.42 render pixels a field texel.
    static let full = Geometry(name: "full 7008", width: 7008, height: 4672, scale: 1, draft: false, picture: longest)
    /// A drag at the frame view's 2190 px (`FrameLayout.pixels`), as RAW 9 decodes it, the route for an a7 IV's Bayer modes.
    static let drag = Geometry(name: "drag 2190", width: 2190, height: 1460, scale: 2190.0 / 7008, draft: false, picture: longest)
    /// The same from RAW 8's draft mode, where the sharpener takes the scaling's blur out too: the other route a preview can take.
    static let dragDraft = Geometry(name: "drag 2190 draft", width: 2190, height: 1460, scale: 2190.0 / 7008, draft: true, picture: longest)
    /// Not a render the app makes: the field's own 2048 at full size's sensor mask. One field texel is one pixel, so the edge is the
    /// sharpest the field can be, under the widest mask: what a coverage step as hard as a pixel would meet at full size (tier 2 at a real edge can make one).
    static let bound = Geometry(name: "bound 2048 at scale 1", width: 2048, height: 1365, scale: 1, draft: false, picture: try! MaskSpace(width: 2048, height: 1365))
    static let geometries = [full, drag, dragDraft, bound]

    static let levels: [(name: String, value: Float)] = [("dark", 0.015), ("mid", 0.18), ("light", 0.75)]
    static let sliders: [(name: String, balance: MaskBalance)] = [("Warmth +100", MaskBalance(warmth: 100)), ("Warmth -100", MaskBalance(warmth: -100)),
                                                                  ("Magenta +100", MaskBalance(magenta: 100)), ("Magenta -100", MaskBalance(magenta: -100))]
    static let amounts: [Float] = [1, 2]
    /// Pixels either side of the edge the numbers read; farther than the widest sharpening kernel (6 taps) and the ramp reach.
    static let halfBand = 24

    /// The hardest edge coverage can have that is not a smart selection: a Linear gradient whose Full and Zero points are as close as `MaskSpace` lets them
    /// be, far inside one field texel, so the 2048 bake is a step and the render's bilinear read of it is all the ramp there is. Tilted a few degrees, so the rows read
    /// every phase of the step against the field and the render's pixels; covered to the left of it.
    static func component(_ g: Geometry) -> MaskComponent {
        let tilt: Float = 3 * .pi / 180, direction = SIMD2(cos(tilt), sin(tilt)), span = 2 * MaskSpace.minimumExtent
        let centre = SIMD2(g.picture.extent.x / 2, g.picture.extent.y / 2)
        let a = centre - direction * span / 2, b = centre + direction * span / 2
        return MaskComponent(shape: .linear(.init(full: MaskPoint(x: a.x, y: a.y), zero: MaskPoint(x: b.x, y: b.y))))
    }

    static func pins(scale: Float) -> DecodePins {
        DecodePins(version: "measure", decoderVersion: "measure", baselineExposure: 0, shadowBias: 0, sharpness: 0, boost: 0, boostShadow: 0,
                   gamutMapping: false, highlightRecovery: false, extendedDynamicRange: 0, neutralChromaticity: .init(x: 0.3127, y: 0.329),
                   moireReduction: nil, contrast: 0, detail: nil, anchorDecodedMidTone: 0.18, anchorVersion: "measure", exposureGainStops: 0,
                   luminanceNoiseReduction: 0, colorNoiseReduction: nil, lensCorrection: true, scale: scale, draftMode: true)
    }

    /// A flat frame of `level` in every channel, with the geometry's scale and picture.
    static func frame(_ gpu: GPU, _ g: Geometry, level: Float) throws -> LinearFrame {
        let texture = try gpu.makeTexture(width: g.width, height: g.height)
        var row = [Float16](repeating: 1, count: g.width * 4)
        for x in 0..<g.width { row[x * 4] = Float16(level); row[x * 4 + 1] = Float16(level); row[x * 4 + 2] = Float16(level) }
        row.withUnsafeBytes { bytes in
            for y in 0..<g.height {
                texture.replace(region: MTLRegionMake2D(0, y, g.width, 1), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: g.width * 8)
            }
        }
        return LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "balance-edge", scale: g.scale, pins: g.draft ? pins(scale: g.scale) : nil, picture: g.picture)
    }

    static func settings(_ g: Geometry, _ balance: MaskBalance, amount: Float, sharpen: Bool) throws -> DevelopSettings {
        DevelopSettings(sharpen: sharpen, manual: try MaskRender.manual(masks: [Mask(components: [component(g)], amount: amount, balance: balance)]))
    }

    /// Where each row's coverage crosses 0.5, and the median and largest number of pixels a row's coverage takes to fall from 0.9 to 0.1.
    static func edge(_ coverage: [Float], _ g: Geometry) -> (crossings: [Float], span: Float, widest: Float) {
        var crossings = [Float](repeating: 0, count: g.height), spans: [Float] = []
        for y in 0..<g.height {
            let row = y * g.width
            func at(_ level: Float) -> Float {
                for x in 1..<g.width where coverage[row + x - 1] >= level && coverage[row + x] < level {
                    return Float(x - 1) + (coverage[row + x - 1] - level) / (coverage[row + x - 1] - coverage[row + x])
                }
                return .nan
            }
            crossings[y] = at(0.5)
            spans.append(at(0.1) - at(0.9))
        }
        let sorted = spans.filter(\.isFinite).sorted()
        return (crossings, sorted.isEmpty ? .nan : sorted[sorted.count / 2], sorted.last ?? .nan)
    }

    /// CIELAB of display-linear Rec. 2020 at D65, as `MaskBalanceTests` reads it.
    static func lab(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let c = simd_max(rgb, .zero)
        let xyz = SIMD3<Float>(0.636958 * c.x + 0.144617 * c.y + 0.168881 * c.z,
                               0.262700 * c.x + 0.677998 * c.y + 0.059302 * c.z,
                               0.028073 * c.y + 1.060985 * c.z) / SIMD3(0.95047, 1, 1.08883)
        func f(_ t: Float) -> Float { t > 0.008856 ? pow(t, 1 / 3) : 7.787 * t + 16 / 116 }
        return SIMD3(116 * f(xyz.y) - 16, 500 * (f(xyz.x) - f(xyz.y)), 200 * (f(xyz.y) - f(xyz.z)))
    }

    /// Columns `x` to `x + width` of every row of a rendered texture, as RGB.
    static func columns(_ texture: MTLTexture, x: Int, width: Int) -> [SIMD3<Float>] {
        var values = [Float16](repeating: 0, count: width * texture.height * 4)
        values.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(x, 0, width, texture.height), mipmapLevel: 0) }
        return (0..<(width * texture.height)).map { SIMD3(Float(values[$0 * 4]), Float(values[$0 * 4 + 1]), Float(values[$0 * 4 + 2])) }
    }

    struct Result {
        var maximumL: Float = 0, p99L: Float = 0, maximumE: Float = 0, p99E: Float = 0
        /// Far from the edge, where the two renders should not differ at all: the kernels' own difference.
        var farL: Float = 0
        /// The balance's own step, off render, for scale: covered side against uncovered.
        var stepL: Float = 0, stepE: Float = 0
        var fieldL: Float = 0
    }

    /// `|ΔL*|` and ΔE*ab between `sharpened` and `plain` in the band about the edge, `plain` being the same render with sharpening off.
    static func compare(sharpened: MTLTexture, plain: MTLTexture, _ g: Geometry, crossings: [Float], rowStep: Int = 1) -> Result {
        let finite = crossings.filter(\.isFinite)
        let low = max(0, Int((finite.min() ?? 0).rounded(.down)) - halfBand - 1)
        let high = min(g.width, Int((finite.max() ?? 0).rounded(.up)) + halfBand + 2)
        let a = columns(sharpened, x: low, width: high - low), b = columns(plain, x: low, width: high - low)
        var dL: [Float] = [], dE: [Float] = []
        dL.reserveCapacity(g.height * (2 * halfBand + 1)); dE.reserveCapacity(g.height * (2 * halfBand + 1))
        var result = Result()
        let width = high - low
        for y in stride(from: 0, to: g.height, by: rowStep) where crossings[y].isFinite {
            let centre = crossings[y] - Float(low)
            for x in 0..<width where abs(Float(x) - centre) <= Float(halfBand) {
                let p = lab(a[y * width + x]), q = lab(b[y * width + x])
                dL.append(abs(p.x - q.x))
                dE.append(simd_length(p - q))
            }
        }
        dL.sort(); dE.sort()
        result.maximumL = dL.last ?? 0; result.maximumE = dE.last ?? 0
        if !dL.isEmpty {
            result.p99L = dL[min(dL.count - 1, dL.count * 99 / 100)]
            result.p99E = dE[min(dE.count - 1, dE.count * 99 / 100)]
        }
        // Far from the edge: the same comparison where the coverage is flat, and the two sides of the step.
        let farColumns = max(0, min(32, low)), probe = min(4, farColumns)
        if probe > 0 {
            let farA = columns(sharpened, x: 8, width: probe), farB = columns(plain, x: 8, width: probe)
            for i in farA.indices { result.farL = max(result.farL, abs(lab(farA[i]).x - lab(farB[i]).x)) }
        }
        let row = g.height / 2, centre = Int(crossings[row].isFinite ? crossings[row] : Float(g.width / 2))
        let covered = plainPixel(plain, x: max(0, centre - 40), y: row), open = plainPixel(plain, x: min(g.width - 1, centre + 40), y: row)
        result.stepL = abs(lab(covered).x - lab(open).x)
        result.stepE = simd_length(lab(covered) - lab(open))
        result.fieldL = lab(open).x
        return result
    }

    private static func plainPixel(_ texture: MTLTexture, x: Int, y: Int) -> SIMD3<Float> {
        var values = [Float16](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0) }
        return SIMD3(Float(values[0]), Float(values[1]), Float(values[2]))
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] != nil))
struct MaskBalanceSharpenMeasureTests {
    @Test func theTable() throws {
        let gpu = try GPU()
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARGENT_BALANCE_OUT"] ?? NSTemporaryDirectory() + "argent-balance")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var csv = "geometry,sigma px,stock,field,field L*,slider,amount,10-90 span px (median),10-90 span px (widest row),band pixels per side,max |dL*|,p99 |dL*|,max dE*ab,p99 dE*ab,far from edge max |dL*|,balance step dL*,balance step dE*ab\n"
        struct Row { let geometry, stock, field, slider: String; let amount: Float; let result: BalanceEdge.Result }
        var rows: [Row] = []
        for geometry in BalanceEdge.geometries {
            let stocks = try MaskRender.stocks()
            // The edge's width first, from the coverage the kernels read, on one stock: coverage holds no stock.
            let probeFrame = try BalanceEdge.frame(gpu, geometry, level: BalanceEdge.levels[1].value)
            let renderer = try FilmRenderer(gpu: gpu, stock: stocks[0])
            let settings = try BalanceEdge.settings(geometry, MaskBalance(warmth: 100), amount: 1, sharpen: true)
            let coverage = try Refine.probe(gpu, probeFrame, try Refine.scene(renderer, probeFrame, settings), slot: 0)
            let edge = BalanceEdge.edge(coverage, geometry)
            let sharpening = CaptureSharpening.masks(for: probeFrame)
            print(String(format: "MEASURE %@: 10-90 %% coverage transition %.3f px at the median row, %.3f at the widest; sensor sigma %.3f, scaling sigma %.3f",
                         geometry.name as NSString, edge.span, edge.widest, sharpening.sensor.sigma, sharpening.scaling?.sigma ?? 0))
            for stock in stocks {
                let renderer = try FilmRenderer(gpu: gpu, stock: stock)
                for level in BalanceEdge.levels {
                    let frame = try BalanceEdge.frame(gpu, geometry, level: level.value)
                    for slider in BalanceEdge.sliders {
                        for amount in BalanceEdge.amounts {
                            let result: BalanceEdge.Result = try autoreleasepool {
                                let on = try renderer.render(frame, settings: try BalanceEdge.settings(geometry, slider.balance, amount: amount, sharpen: true))
                                let off = try renderer.render(frame, settings: try BalanceEdge.settings(geometry, slider.balance, amount: amount, sharpen: false))
                                return BalanceEdge.compare(sharpened: on.image.texture, plain: off.image.texture, geometry, crossings: edge.crossings)
                            }
                            rows.append(Row(geometry: geometry.name, stock: stock.id, field: level.name, slider: slider.name, amount: amount, result: result))
                            csv += String(format: "%@,%.3f,%@,%@,%.2f,%@,%.0f,%.3f,%.3f,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%.3f\n",
                                          geometry.name as NSString, sharpening.sensor.sigma, stock.id as NSString, level.name as NSString, result.fieldL,
                                          slider.name as NSString, amount, edge.span, edge.widest, BalanceEdge.halfBand, result.maximumL, result.p99L, result.maximumE,
                                          result.p99E, result.farL, result.stepL, result.stepE)
                        }
                    }
                }
            }
        }
        let url = out.appendingPathComponent("sharpen.csv")
        try Data(csv.utf8).write(to: url)
        print("MEASURE wrote \(url.path) (\(rows.count) rows)")

        func report(_ header: String, _ selected: [Row]) {
            guard let worstL = selected.max(by: { $0.result.maximumL < $1.result.maximumL }),
                  let worstE = selected.max(by: { $0.result.maximumE < $1.result.maximumE }) else { return }
            let p99L = selected.map(\.result.p99L).max() ?? 0, p99E = selected.map(\.result.p99E).max() ?? 0
            print(String(format: "MEASURE %-40@ max |dL*| %.4f (%@ %@ amount %.0f, %@), worst p99 |dL*| %.4f; max dE*ab %.4f (%@ %@ amount %.0f, %@), worst p99 dE*ab %.4f",
                         header as NSString, worstL.result.maximumL, worstL.field as NSString, worstL.slider as NSString, worstL.amount, worstL.geometry as NSString, p99L,
                         worstE.result.maximumE, worstE.field as NSString, worstE.slider as NSString, worstE.amount, worstE.geometry as NSString, p99E))
        }
        for stock in Set(rows.map(\.stock)).sorted() {
            report(stock, rows.filter { $0.stock == stock })
            for geometry in BalanceEdge.geometries {
                report("\(stock) / \(geometry.name)", rows.filter { $0.stock == stock && $0.geometry == geometry.name })
            }
        }
        for geometry in BalanceEdge.geometries { report("all stocks / \(geometry.name)", rows.filter { $0.geometry == geometry.name }) }
        report("every geometry the app can reach", rows.filter { $0.geometry != BalanceEdge.bound.name })
        report("all, with the bound", rows)
        print(String(format: "MEASURE largest difference far from the edge, every row: %.5f L*", rows.map(\.result.farL).max() ?? 0))
    }
}
