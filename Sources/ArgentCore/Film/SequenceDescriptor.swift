import Foundation

/// A coarse picture of the decode Auto measured, built from the same analysis grid as its
/// `ExposureAnalysis` (`ExposureAnalyzer.measure`): for telling whether nearby frames of a roll
/// show the same subject in the same light, and for rendering the regions they share through the
/// print (docs/auto-exposure-consistency-plan.md, steps 1 to 3).
///
/// It has `longSide` cells on its long side and the grid's aspect on its short side, rounded to
/// the nearest cell and one at least; a grid with no more than `longSide` cells on its long side is
/// kept cell for cell. Rows run from the picture's bottom, as the grid's do, and an upright portrait
/// decode gives a portrait descriptor. Each cell holds the block of grid cells `gridSpan` gives on
/// each axis, so every grid cell is in exactly one descriptor cell and each descriptor cell holds
/// one at least; each grid cell counts once, whatever its pixels.
public struct SequenceDescriptor: Sendable, Equatable {
    /// Changes when what a descriptor holds changes, so a cache knows its value is stale.
    /// 2026-10-22-1: the first.
    public static let version = "2026-11-25-1"
    /// The cells on the descriptor's long side.
    public static let longSide = 64

    /// The descriptor's size in cells.
    public var width: Int
    public var height: Int
    /// Each cell's mean light over all its pixels, clipped ones too, as the renderer sees them:
    /// linear red, green and blue in the working space, interleaved, row by row. It is the mean of
    /// the grid's `all`, so with the decoder's lift of dark noise taken out where the analysis takes
    /// it out (`DecodedNoise`).
    public var rgb: [Float]
    /// The share of each cell's pixels that are not clipped: the mean of the grid's `unclipped`.
    public var unclipped: [Float]
    /// Each cell's texture: the standard deviation of the log2 luminance of the grid cells it holds,
    /// each floored at `ExposureAnalyzer.floorStops` as the level is. Zero on a flat cell, and the
    /// same a stop brighter or darker while the light stays over the floor.
    public var detail: [Float]
    /// Calibrated only for supported decoders and RAW modes.
    public var noise: DecodedNoise?

    /// The descriptor of an analysis grid.
    public init(grid: ExposureAnalyzer.Grid, noise: DecodedNoise? = nil) {
        self.noise = noise
        let gridWidth = grid.width, gridHeight = grid.height
        if gridWidth < 1 || gridHeight < 1 {
            (width, height) = (0, 0)
        } else if max(gridWidth, gridHeight) <= Self.longSide {
            (width, height) = (gridWidth, gridHeight)
        } else {
            // The short side, rounded half up in integers.
            let long = max(gridWidth, gridHeight), short = min(gridWidth, gridHeight)
            let side = max(1, (2 * Self.longSide * short + long) / (2 * long))
            (width, height) = gridWidth >= gridHeight ? (Self.longSide, side) : (side, Self.longSide)
        }
        let count = width * height
        rgb = []; unclipped = []; detail = []
        rgb.reserveCapacity(count * 3); unclipped.reserveCapacity(count); detail.reserveCapacity(count)
        let floor = 0.18 * exp2(ExposureAnalyzer.floorStops)
        let stops = grid.all.map { log2(max(($0 * Rec2020.luma).sum(), floor)) }
        for v in 0..<height {
            let rows = Self.gridSpan(v, of: height, over: gridHeight)
            for u in 0..<width {
                let columns = Self.gridSpan(u, of: width, over: gridWidth)
                let n = Float(rows.count * columns.count)
                var light = SIMD3<Float>(repeating: 0), share: Float = 0, offset: Float = 0
                // The spread is taken about the block's first cell, so a flat block's is exactly zero.
                let first = stops[rows.lowerBound * gridWidth + columns.lowerBound]
                for row in rows {
                    for column in columns {
                        let index = row * gridWidth + column
                        light += grid.all[index]
                        share += grid.unclipped[index]
                        offset += stops[index] - first
                    }
                }
                let mean = offset / n
                var spread: Float = 0
                for row in rows {
                    for column in columns {
                        let d = stops[row * gridWidth + column] - first - mean
                        spread += d * d
                    }
                }
                light /= n
                rgb.append(light.x); rgb.append(light.y); rgb.append(light.z)
                unclipped.append(share / n)
                detail.append((spread / n).squareRoot())
            }
        }
    }

    /// The grid columns or rows that descriptor column or row `index` of `count` holds over a grid
    /// of `gridCount`: from `index * gridCount / count` up to `(index + 1) * gridCount / count`, in
    /// integer division. Over `index` from 0 to `count - 1` these cover the grid's cells once each,
    /// and none is empty while `count` is no more than `gridCount`.
    public static func gridSpan(_ index: Int, of count: Int, over gridCount: Int) -> Range<Int> {
        index * gridCount / count..<(index + 1) * gridCount / count
    }
}
