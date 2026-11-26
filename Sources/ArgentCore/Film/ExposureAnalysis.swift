import CoreGraphics
import Foundation
import Metal

/// What auto development measures in a frame, once, from the contact sheet's scene-linear
/// decode, so the sheet, the frame view and the develop print it the same way.
///
/// `meanStops` is where the frame's light sits against a metered mid-gray, in scene-referred
/// stops at the Negative LUT's input (the spec defines every auto bound in those stops): the
/// weighted, trimmed mean of log2 luminance minus log2(0.18). A lab prints the frame so that
/// level lands where a metered gray card would, within bounds; see `AutoPrint`.
public struct ExposureAnalysis: Sendable, Equatable, Codable {
    /// Changes when the measurement changes, so a recipe or a cache knows its value is stale.
    /// 2026-10-06-6: Vision sees the frame upright, and face boxes are from the top left.
    /// 2026-10-06-7: the gray gamut's floor at -1.3 stops, and every mid-tone estimating the light
    /// when none is inside it (docs/M3-auto.md, section 12).
    /// 2026-10-07-1: each sample is its cell's mean light, not one pixel, and the decoder's lift
    /// of dark noise is taken out for a body whose noise is known (docs/M3-auto.md, section 16).
    /// 2026-10-07-2: each face carries its skin's colour (`FaceMeasure.skin`).
    /// 2026-10-07-3: lossless M and S decode 0.06 and 0.02 stops darker (decode pins 2026-10-07-1),
    /// so a frame of theirs measured before reads that much bright; the other modes measure as before.
    /// 2026-10-07-4: the a7 IV's shot noise is the published conversion gain, 0.243 at ISO 100
    /// against 0.355, so less of a high-ISO dark frame's light is taken for the decoder's lift
    /// (`BodyNoise`; docs/research/noise-and-hardware.md).
    /// 2026-10-09-1: a face's level uses the mean log luminance of the same retained, unclipped
    /// skin cells as its colour, with the whole-inset level retained when skin is unavailable.
    /// 2026-10-18-1: the measurement is unchanged, and Auto aims each frame by `FittedPlacement`,
    /// fitted on FiveK's experts (docs/M3-auto.md section 42), so a roll measured before is printed
    /// again with the new aim.
    /// 2026-10-19-1: the measurement is unchanged, and `FittedPlacement` is refitted on 1,092 FiveK
    /// photos with the face's error weighted twice, full face weight from 0.25 % of the frame and that
    /// weight on the frame's level too (docs/M3-auto.md section 43), so a roll is printed again.
    /// 2026-10-19-2: the a7 IV's lossless L, uncompressed and compressed frames are measured from
    /// Apple's RAW 9 decode, which RAW 8 or the in-house decoder made before (docs/decoder.md
    /// section 18), so each is measured again. RAW 9 denoises before any clip and lifts a dark frame
    /// little and not as RAW 8 does, so nothing is taken out of its decodes (`DecodedNoise.appleDecode`).
    /// 2026-10-29-1: the measurement is unchanged, but until 2026-10-29 a RAW 9 sheet decode made beside
    /// another could lose a tile, and a frame was measured from it (docs/decoder.md section 18, "Damaged
    /// tiles from two decodes at once"), so by the owner's decision each frame is measured again from a
    /// whole decode.
    /// 2026-11-05-1: the measurement is unchanged, and Auto's aim is fitted to Lightroom's Auto with a
    /// tone step beside it (docs/research/auto/balance-research.md, section 7c), so a roll is printed again.
    public static let currentVersion = "2026-11-05-1"
    /// The histogram's bins: half a stop each from five stops under mid-gray, where the level
    /// floors its light (`ExposureAnalyzer.floorStops`), to five over, so light the negative no
    /// longer records cannot tell two frames of one scene apart (docs/provenance.md).
    public static let histogramLowStops: Float = -5
    public static let histogramBinStops: Float = 0.5
    public static let histogramBins = 20

    public var version: String
    public var meanStops: Float
    /// The share of the frame's centre weight that took part, after clipped pixels were set
    /// aside and before the trim.
    public var validWeight: Float
    /// The centre-weighted distribution of log2 luminance against mid-gray over
    /// `histogramBins` half-stop bins, summing to 1, clipped light included; for telling
    /// one scene from the next when the roll is smoothed.
    public var histogram: [Float]
    /// The camera's own white balance for the frame, in kelvin, from the decoder's read-back:
    /// a change of light between frames shows here even though the decode ignores it.
    public var asShotTemperature: Float?
    /// The scene's light per channel by shades of gray, the L6 mean of each channel over the
    /// frame's mid-tones with clipped pixels left out, in log2 stops against mid-gray, red,
    /// green, blue; empty when no mid-tones were found. Its colour is the cast auto lab
    /// balance corrects (`AutoBalance`).
    public var grayEstimate: [Float]
    /// The faces Vision found, metered (`FaceMeter`).
    public var faces: [FaceMeasure]

    public init(version: String = ExposureAnalysis.currentVersion, meanStops: Float, validWeight: Float,
                histogram: [Float] = [], asShotTemperature: Float? = nil, grayEstimate: [Float] = [],
                faces: [FaceMeasure] = []) {
        self.grayEstimate = grayEstimate
        self.faces = faces
        self.version = version
        self.meanStops = meanStops
        self.validWeight = validWeight
        self.histogram = histogram
        self.asShotTemperature = asShotTemperature
    }

    /// The earth mover's distance between two frames' histograms, in stops: how far the
    /// light of one would have to move to look like the other's. `nil` if either is missing.
    public func histogramDistance(to other: ExposureAnalysis) -> Float? {
        guard histogram.count == Self.histogramBins, other.histogram.count == Self.histogramBins else { return nil }
        var cumulative: Float = 0, distance: Float = 0
        for (a, b) in zip(histogram, other.histogram) {
            cumulative += a - b
            distance += abs(cumulative)
        }
        return distance * Self.histogramBinStops
    }

    public var isCurrent: Bool { version == Self.currentVersion }

    private enum CodingKeys: String, CodingKey {
        case version, meanStops, validWeight, histogram, asShotTemperature, grayEstimate, faces
    }

    /// Reads what an older build wrote, too: its fields are missing, its version says it is
    /// stale, and the recipe around it still opens.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        meanStops = try c.decode(Float.self, forKey: .meanStops)
        validWeight = try c.decodeIfPresent(Float.self, forKey: .validWeight) ?? 0
        histogram = try c.decodeIfPresent([Float].self, forKey: .histogram) ?? []
        asShotTemperature = try c.decodeIfPresent(Float.self, forKey: .asShotTemperature)
        grayEstimate = try c.decodeIfPresent([Float].self, forKey: .grayEstimate) ?? []
        faces = try c.decodeIfPresent([FaceMeasure].self, forKey: .faces) ?? []
    }

    /// The faces' share of the frame.
    public var faceArea: Float { faces.reduce(0) { $0 + $1.area } }

    /// The faces' level, weighted by their size; `nil` without faces.
    public var faceLevelStops: Float? {
        let area = faceArea
        guard area > 0 else { return nil }
        return faces.reduce(0) { $0 + $1.levelStops * $1.area } / area
    }
}

/// The chromaticities a gray surface can show under some plausible light, through the decode's
/// fixed D55 neutral: red against blue from `redBlue.lowerBound` (a clear sky's shade) to
/// `redBlue.upperBound` (tungsten and candlelight) stops, and green against magenta within
/// `greenMagenta` stops either way. Shades of gray over these pixels alone leaves out the
/// strongly coloured surfaces that fool it (measured, docs/M3-auto.md sections 3 and 12).
public struct GrayGamut: Sendable, Equatable {
    public var redBlue: ClosedRange<Float>
    public var greenMagenta: Float

    public init(redBlue: ClosedRange<Float>, greenMagenta: Float) {
        self.redBlue = redBlue
        self.greenMagenta = greenMagenta
    }

    /// -1.3 stops of red against blue, which holds all but the coolest percent of the lights
    /// measured on Cube++'s gray cubes (docs/M3-auto.md section 12), to +2.1, about 2,700 K
    /// (CIE 1931, computed through the pin); and a fluorescent's green.
    public static let plausibleLight = GrayGamut(redBlue: -1.3...2.1, greenMagenta: 0.35)

    public func contains(_ rgb: SIMD3<Float>) -> Bool {
        let r = log2(rgb.x), g = log2(rgb.y), b = log2(rgb.z)
        return redBlue.contains(r - b) && abs(g - (r + b) / 2) <= greenMagenta
    }
}

/// Measures `ExposureAnalysis` from a scene-linear frame on the CPU.
///
/// Constants from the M3 research (docs/M3-research.md, section 2), each an inference from
/// photofinishing patents and Apple's, then measured on the corpus (docs/M3-auto.md, section 1):
/// - centre-weighted rings of 1.0, 0.5 and 0.25 out to the corners;
/// - the darkest 2 percent and the brightest 7 percent of the weight dropped;
/// - clipped pixels left out: those within 3 percent of the frame's brightest channel value,
///   when that value is past `clipFloorStops`, where the decoder can have clipped;
/// - light under five stops below mid-gray counted as five stops under, where the negative's toe
///   stops responding: on the six stocks' datasheet curves each layer's gradient falls under a
///   tenth of its mid-gray value between 4.5 and 6.2 stops under the metered gray, median 4.9
///   (computed; docs/provenance.md), so sensor noise in a dark scene does not move the level.
///
/// Each sample of the grid is the mean light of its cell, the `step` by `step` block of pixels
/// around it, not the one pixel at its centre (since 2026-10-07): a log taken of one noisy or
/// textured pixel reads low, so the level and the gray estimate moved with the decode's noise and
/// its size. With cells, the sheet's 960-pixel decode measures what cells of a full-size decode do
/// (docs/M3-auto.md, section 16). Given the decoder's noise (`DecodedNoise`), each cell's light is
/// then taken back from what the decoder's clip of dark noise made of it.
///
/// The research also proposed leaving out saturated pixels. On Cube++'s 1,597 scenes (CC BY 4.0)
/// it sets aside up to all of a frame's weight, a sixth of the frames cross a fallback at half, and
/// it moves levels by up to 1.6 stops (measured; docs/provenance.md), so it was dropped.
public enum ExposureAnalyzer {
    public static let darkTrim: Float = 0.02
    public static let brightTrim: Float = 0.07
    /// The fewest analysis samples on the long side; the 960-pixel preview is sampled every
    /// few pixels.
    public static let samplesOnLongSide = 240

    /// The decoder clips neutral light at +4.9 stops over mid-gray in lossless L and +3.56 and
    /// +3.55 in lossless M and S after their corrections (docs/research/camera.md); nothing under
    /// this can be a clip.
    public static let clipFloorStops: Float = 3.5
    /// Light below this, in stops against mid-gray, counts as this.
    public static let floorStops: Float = -5

    /// How the analysis reads the frame at each sample of its grid.
    public enum Sampling: Sendable {
        /// The one pixel at the sample's place, as the analysis read until 2026-10-07; kept for
        /// measuring the change.
        case points
        /// The mean light of the sample's cell.
        case cells
    }

    /// The analysis grid of a frame: one sample per `step` by `step` cell, rows from the
    /// picture's bottom as the frame's texture runs.
    public struct Grid: Sendable {
        public var width: Int
        public var height: Int
        public var step: Int
        public var frameWidth: Int
        public var frameHeight: Int
        /// Each cell's mean light over its pixels that are not clipped, RGB; zero when all are.
        public var light: [SIMD3<Float>]
        /// Each cell's mean light over all its pixels.
        public var all: [SIMD3<Float>]
        /// The share of each cell's pixels that are not clipped.
        public var unclipped: [Float]
        /// Each cell's centre weight: rings of 1, 0.5 and 0.25 by the elliptical radius of its
        /// sample, 1 at the middle of each edge.
        public var weight: [Float]

        /// The pixel at the middle of cell `index`, column and row.
        public func centre(_ index: Int) -> (x: Int, y: Int) {
            (index % width * step + step / 2, index / width * step + step / 2)
        }
    }

    /// Analyses `frame`, a scene-linear decode in the working space; with `workingSpace` it
    /// also looks for faces. With `info`, the raw's header, the decoder's lift of dark noise is
    /// taken out for a body whose noise is known (`DecodedNoise.appleDecode`).
    public static func analyze(_ frame: LinearFrame, workingSpace: CGColorSpace? = nil, info: ARWFrameInfo? = nil) -> ExposureAnalysis {
        measure(frame, workingSpace: workingSpace, info: info).analysis
    }

    /// Analyses `frame` as `analyze` does, and describes it for matching frames of a sequence from
    /// the same grid (`SequenceDescriptor`).
    public static func measure(_ frame: LinearFrame, workingSpace: CGColorSpace? = nil,
                               info: ARWFrameInfo? = nil) -> (analysis: ExposureAnalysis, descriptor: SequenceDescriptor) {
        let values = pixels(of: frame.texture)
        let noise = info.flatMap { DecodedNoise.appleDecode(model: $0.model, iso: $0.iso, pins: frame.pins) }
        let grid = grid(pixels: values, width: frame.width, height: frame.height, noise: noise)
        var analysis = analyze(grid: grid)
        analysis.asShotTemperature = frame.readback?.asShotTemperature
        if let workingSpace {
            let faces = FaceMeter.detections(frame.texture, workingSpace: workingSpace)
            analysis.faces = FaceMeter.meter(faces, grid: grid)
        }
        return (analysis, SequenceDescriptor(grid: grid, noise: noise))
    }

    /// Analyses `texture`, an `rgba16Float` frame in the working space.
    public static func analyze(_ texture: MTLTexture) -> ExposureAnalysis {
        analyze(pixels: pixels(of: texture), width: texture.width, height: texture.height)
    }

    /// The texture's RGBA half floats, row by row.
    public static func pixels(of texture: MTLTexture) -> [Float16] {
        let width = texture.width, height = texture.height
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: width * 8,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return pixels
    }

    /// Analyses `pixels`, RGBA half floats in the working space, row by row.
    public static func analyze(pixels: [Float16], width: Int, height: Int,
                               floorStops: Float = ExposureAnalyzer.floorStops,
                               grayGamut: GrayGamut? = .plausibleLight,
                               grayGamutFallback: Bool = true,
                               sampling: Sampling = .cells, noise: DecodedNoise? = nil) -> ExposureAnalysis {
        analyze(grid: grid(pixels: pixels, width: width, height: height, sampling: sampling, noise: noise),
                floorStops: floorStops, grayGamut: grayGamut, grayGamutFallback: grayGamutFallback)
    }

    /// The analysis grid of `pixels`, RGBA half floats in the working space, row by row: each
    /// cell's light read as `sampling` says, and with `noise` taken back from the decoder's lift.
    public static func grid(pixels: [Float16], width: Int, height: Int, sampling: Sampling = .cells,
                            noise: DecodedNoise? = nil) -> Grid {
        let step = max(1, max(width, height) / samplesOnLongSide)
        // A pixel that is not a number, or infinite, is left out of everything (review 5).
        func finite(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }
        var brightest: Float = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let v = SIMD3(Float(pixels[index]), Float(pixels[index + 1]), Float(pixels[index + 2]))
            if finite(v) { brightest = max(brightest, v.max()) }
        }
        // A frame whose brightest light could not have clipped keeps all of it.
        let clip = brightest >= 0.18 * exp2(clipFloorStops) ? brightest * 0.97 : .infinity
        // The samples sit at step / 2 and every step after, as many as fit, and one at least on a
        // side narrower than half a step.
        let columns = width < 1 ? 0 : max(1, width > step / 2 ? (width - step / 2 + step - 1) / step : 0)
        let rows = height < 1 ? 0 : max(1, height > step / 2 ? (height - step / 2 + step - 1) / step : 0)
        var grid = Grid(width: columns, height: rows, step: step, frameWidth: width, frameHeight: height,
                        light: [], all: [], unclipped: [], weight: [])
        let count = columns * rows
        grid.light.reserveCapacity(count); grid.all.reserveCapacity(count)
        grid.unclipped.reserveCapacity(count); grid.weight.reserveCapacity(count)
        let cx = Float(width - 1) / 2, cy = Float(height - 1) / 2
        func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * width + x) * 4
            return SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
        }
        for row in 0..<rows {
            for column in 0..<columns {
                let x = min(column * step + step / 2, width - 1), y = min(row * step + step / 2, height - 1)
                let dx = (Float(x) - cx) / max(cx, 1), dy = (Float(y) - cy) / max(cy, 1)
                let radius = (dx * dx + dy * dy).squareRoot()
                grid.weight.append(radius < 1.0 / 3 ? 1 : radius < 2.0 / 3 ? 0.5 : 0.25)
                var all = SIMD3<Float>(repeating: 0), kept = SIMD3<Float>(repeating: 0), n: Float = 0, k: Float = 0
                switch sampling {
                case .points:
                    let v = rgb(x, y)
                    if finite(v) {
                        all = v; n = 1
                        if v.max() < clip { kept = v; k = 1 }
                    }
                case .cells:
                    for yy in (row * step)..<min(row * step + step, height) {
                        for xx in (column * step)..<min(column * step + step, width) {
                            let v = rgb(xx, yy)
                            guard finite(v) else { continue }
                            all += v; n += 1
                            if v.max() < clip { kept += v; k += 1 }
                        }
                    }
                }
                var light = k > 0 ? kept / k : SIMD3<Float>(repeating: 0)
                n = max(n, 1)
                all /= n
                if let noise {
                    if k > 0 { light = noise.unlifted(light) }
                    all = noise.unlifted(all)
                }
                grid.light.append(light)
                grid.all.append(all)
                grid.unclipped.append(k / n)
            }
        }
        return grid
    }

    /// Analyses a frame's grid.
    public static func analyze(grid: Grid, floorStops: Float = ExposureAnalyzer.floorStops,
                               grayGamut: GrayGamut? = .plausibleLight,
                               grayGamutFallback: Bool = true) -> ExposureAnalysis {
        let floor = 0.18 * exp2(floorStops)
        struct Sample { var value: Float; var weight: Float }
        var histogram = [Float](repeating: 0, count: ExposureAnalysis.histogramBins)
        // Shades of gray: the weighted mean of each channel to the sixth power over mid-tones,
        // four stops under to three over mid-gray, in units of mid-gray so nothing underflows.
        var power = SIMD3<Float>(repeating: 0), powerWeight: Float = 0
        var allPower = SIMD3<Float>(repeating: 0), allWeight: Float = 0
        let midLow: Float = 0.18 * exp2(-4), midHigh: Float = 0.18 * exp2(3)
        var samples: [Sample] = []
        samples.reserveCapacity(grid.light.count)
        var totalWeight: Float = 0
        for index in grid.light.indices {
            let weight = grid.weight[index]
            totalWeight += weight
            let lowest = 0.18 * exp2(ExposureAnalysis.histogramLowStops)
            let stops = log2(max((grid.all[index] * Rec2020.luma).sum(), lowest)) - log2(0.18)
            let bin = stops.isFinite ? Int((stops - ExposureAnalysis.histogramLowStops) / ExposureAnalysis.histogramBinStops)
                : ExposureAnalysis.histogramBins - 1
            histogram[min(max(bin, 0), ExposureAnalysis.histogramBins - 1)] += weight
            let share = grid.unclipped[index]
            guard share > 0 else { continue }
            let rgb = grid.light[index]
            let luminance = (rgb * Rec2020.luma).sum()
            if luminance > midLow, luminance < midHigh, rgb.min() > 0 {
                let unit = rgb / 0.18
                let squared = unit * unit
                let sixth = squared * squared * squared * weight * share
                allPower += sixth
                allWeight += weight * share
                if grayGamut?.contains(rgb) ?? true {
                    power += sixth
                    powerWeight += weight * share
                }
            }
            samples.append(Sample(value: log2(max(luminance, floor)), weight: weight * share))
        }
        // A frame clipped everywhere is measured as it is.
        var used = samples
        if used.isEmpty {
            used = grid.all.map { Sample(value: log2(max(($0 * Rec2020.luma).sum(), floor)), weight: 1) }
        }
        let usedWeight = used.reduce(0) { $0 + $1.weight }
        guard usedWeight > 0 else { return ExposureAnalysis(meanStops: 0, validWeight: 0, histogram: histogram) }

        used.sort { $0.value < $1.value }
        let lower = usedWeight * darkTrim, upper = usedWeight * (1 - brightTrim)
        var cumulative: Float = 0, sum: Float = 0, kept: Float = 0
        for sample in used {
            // The part of this sample's weight that lies between the two trims.
            let start = max(cumulative, lower), end = min(cumulative + sample.weight, upper)
            if end > start {
                sum += sample.value * (end - start)
                kept += end - start
            }
            cumulative += sample.weight
        }
        let mean = kept > 0 ? sum / kept : used[used.count / 2].value
        let histogramTotal = histogram.reduce(0, +)
        // Under a light the gamut leaves out, a gray falls outside it too; when no mid-tone is
        // left, every mid-tone counts, rather than no estimate and so no filtration.
        if grayGamutFallback, powerWeight == 0 {
            power = allPower
            powerWeight = allWeight
        }
        var gray: [Float] = []
        if powerWeight > 0 {
            let mean = power / powerWeight
            gray = [log2(mean.x) / 6, log2(mean.y) / 6, log2(mean.z) / 6]
        }
        return ExposureAnalysis(meanStops: mean - log2(0.18), validWeight: samples.isEmpty ? 0 : usedWeight / totalWeight,
                                histogram: histogramTotal > 0 ? histogram.map { $0 / histogramTotal } : histogram,
                                grayEstimate: gray)
    }
}
