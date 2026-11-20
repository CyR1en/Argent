import ArgentCore
import Foundation

extension SequenceAims {
    /// How one frame prints at each level candidate B weighs: the rating's exposure of the
    /// negative, which no level changes, and the Print LUT's offset at every level of
    /// `Response.levels` with the frame's own controls and its final cast. Level and cast are
    /// coupled through the gray compensation, so each offset comes from the whole `PrintAim`.
    struct FramePrint: Sendable {
        var exposureStops: Float
        var offsets: [SIMD3<Float>]

        init(stock: Stock, controls: RollControls, cast: SIMD3<Float>) {
            exposureStops = controls.settings(for: stock, aim: PrintAim(level: 0, cast: cast)).exposureStops(boxSpeed: stock.boxSpeed)
            offsets = Response.levels.map { level in
                controls.settings(for: stock, aim: PrintAim(level: level, cast: cast))
                    .printOffset(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
            }
        }
    }

    /// A link's matched points in one of its frames, printed through the stock at each level from
    /// `-AutoPrint.bound` to `AutoPrint.darkenLimit` in sixteenths of a stop, and linear between
    /// them: their weighted mean L* and the weighted share of them the print clips.
    ///
    /// Each point is printed on the CPU as the render graph's LUT passes print a pixel: the
    /// rating's exposure and the negative's log encoding, the Negative LUT once, then per level
    /// the print offset, clamped to the Print LUT's domain, and the Print LUT; L* from Rec. 2020
    /// luminance with Y clamped to 0...1, as the gates measure it (`GateMeasureTests.lightness`).
    /// Halation, sharpening and grain are left out: the first two are spatial and the third is
    /// noise, and none depends on the level (docs/research/auto/sequence-consistency.md, section 3).
    /// The mean is of each point's L*, not the L* of a mean, which a curved print does not keep.
    ///
    /// A point is clipped at a level when its dye amounts plus the print offset leave 0...1 in any
    /// channel: the Print LUT clamps its input there, so the point's detail is lost at the print's
    /// black or white end (`synthetic_print.py`'s `printClipped`). Amendment 1 of the
    /// pre-registration (section 3) set this in place of L* thresholds: the stocks' paper black
    /// prints at L* 3.8 to 6.3 and the Portras' white at 99.1, so L* 1 and 99 could never see
    /// black and barely see white.
    struct Response: Sendable, Equatable {
        static let step: Float = 1.0 / 16
        static let levels: [Float] = {
            let count = Int(((AutoPrint.darkenLimit + AutoPrint.bound) / step).rounded()) + 1
            return (0..<count).map { -AutoPrint.bound + Float($0) * step }
        }()

        /// Per level of `levels`.
        var lightness: [Float]
        var clipped: [Float]

        /// `samples` weighted by `weights`, paired by index, each finite and its weight finite and
        /// above zero (`RenderedLink.points`).
        init(samples: [SIMD3<Float>], weights: [Float], print: FramePrint, stock: Stock) {
            let encoding = stock.negative.encoding
            let gain = exp2(print.exposureStops)
            let dyes = samples.map { rgb in
                let exposed = GamutCompression.compress(rgb * gain)
                return stock.negative.sample(encoded: SIMD3(encoding.encode(exposed.x), encoding.encode(exposed.y),
                                                            encoding.encode(exposed.z)))
            }
            let total = weights.reduce(0, +)
            lightness = []
            clipped = []
            lightness.reserveCapacity(print.offsets.count)
            clipped.reserveCapacity(print.offsets.count)
            for offset in print.offsets {
                var sum: Float = 0, lost: Float = 0
                for (dye, weight) in zip(dyes, weights) {
                    let input = dye + offset
                    let printed = stock.print.sample(encoded: input.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1)))
                    sum += weight * SequenceAims.lightness((printed * Rec2020.luma).sum())
                    if input.min() < 0 || input.max() > 1 { lost += weight }
                }
                lightness.append(sum / total)
                clipped.append(lost / total)
            }
        }

        func lightness(at level: Float) -> Float { Self.interpolate(lightness, row: 0, at: level) }
        func clipped(at level: Float) -> Float { Self.interpolate(clipped, row: 0, at: level) }

        /// Row `row` of `table`, rows of `levels.count` values one after another, at `level`.
        static func interpolate(_ table: [Float], row: Int, at level: Float) -> Float {
            let t = (min(max(level, -AutoPrint.bound), AutoPrint.darkenLimit) + AutoPrint.bound) / step
            let index = min(Int(t), levels.count - 2), f = t - Float(index), base = row * levels.count + index
            return table[base] + f * (table[base + 1] - table[base])
        }
    }

    /// A link that counts for candidate B, with its matched points' response in each frame.
    struct RenderedLink: Sendable {
        var link: Link
        var earlier: Response
        var later: Response

        /// The matched points that can be printed: finite in both frames and weighted above zero, in
        /// the link's order; `nil` when none is, or their weights do not add up to a finite amount.
        static func points(_ link: Link) -> (earlier: [SIMD3<Float>], later: [SIMD3<Float>], weights: [Float])? {
            func finite(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }
            var earlier: [SIMD3<Float>] = [], later: [SIMD3<Float>] = [], weights: [Float] = []
            for (k, weight) in link.weights.enumerated()
            where weight > 0 && weight.isFinite && k < link.earlierSamples.count && k < link.laterSamples.count
                && finite(link.earlierSamples[k]) && finite(link.laterSamples[k]) {
                earlier.append(link.earlierSamples[k])
                later.append(link.laterSamples[k])
                weights.append(weight)
            }
            let total = weights.reduce(0, +)
            return total > 0 && total.isFinite ? (earlier, later, weights) : nil
        }
    }

    /// L* of display-linear luminance `y`, clamped to 0...1, by the gates' convention
    /// (`GateMeasureTests.lightness`).
    static func lightness(_ y: Float) -> Float {
        let v = min(max(y, 0), 1)
        return v > 0.008856 ? 116 * cbrt(v) - 16 : 903.3 * v
    }

    /// `links`' responses on `input`'s stock, each frame printed with its own controls and the cast
    /// in `aims`; a link with no point to print is left out. Each frame's print is
    /// worked out once, however many links it has.
    static func renderedLinks(_ input: Input, links: [Link], aims: [URL: PrintAim]) -> [RenderedLink] {
        var prints: [Int: FramePrint] = [:]
        func print(_ index: Int) -> FramePrint? {
            if let known = prints[index] { return known }
            let url = input.frames[index].url
            guard let cast = aims[url]?.cast else { return nil }
            let made = FramePrint(stock: input.stock, controls: input.controls(for: url), cast: cast)
            prints[index] = made
            return made
        }
        return links.compactMap { link in
            guard let points = RenderedLink.points(link), let e = print(link.earlier), let l = print(link.later) else { return nil }
            return RenderedLink(link: link,
                                earlier: Response(samples: points.earlier, weights: points.weights, print: e, stock: input.stock),
                                later: Response(samples: points.later, weights: points.weights, print: l, stock: input.stock))
        }
    }
}
