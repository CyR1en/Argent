import Foundation

/// A frame's sensor noise, read from its own mosaic: a sample `s` digital numbers above black
/// varies by `shot * s + read` squared digital numbers.
///
/// Shot noise grows with the signal and read noise does not. The three colours of one sensor share
/// the conversion gain at a given ISO, so one pair covers them all. The pair is estimated blind,
/// so no camera or ISO table is needed: the two greens of a Bayer quad are diagonal neighbours,
/// and their difference is noise plus whatever detail changes over a pixel. Over 16 by 16 blocks
/// (64 quads) the variance of that difference, halved for one sample, is binned by the block's
/// green level in quarter stops. The lowest tenth of each bin are the flat blocks; their value,
/// corrected for taking the lowest tenth of a chi-square spread, is the noise at that level, and a
/// line is fitted through the bins, dropping bins that sit well above it, which are texture
/// (docs/decoder.md, section 10).
public struct SensorNoise: Sendable, Equatable, Codable {
    /// Variance per digital number of signal: the conversion gain.
    public var shot: Double
    /// Variance at black.
    public var read: Double

    public init(shot: Double, read: Double) {
        self.shot = shot
        self.read = read
    }

    /// The variance of a sample `level` digital numbers above black.
    public func variance(at level: Double) -> Double { shot * max(level, 0) + read }

    /// Samples a block side.
    static let block = 16
    /// Quarter-stop bins of the block's level in digital numbers above black, from 1.
    static let binsPerStop = 4.0
    static let bins = 64
    /// The share of a bin's blocks taken as flat, and the chi-square quantile it reads: the
    /// variance of 64 differences, their mean removed, is a chi-square of 63 degrees of freedom
    /// over 63, whose 10th percentile is 0.7796 (Wilson-Hilferty).
    static let flatShare = 0.1
    static let flatQuantile = 0.7796
    /// A bin needs this many blocks to count.
    static let minimumBlocks = 24

    /// The read noise is at least this: a frame need not reach black, and then the line's
    /// intercept is a poor estimate (0 on the CC0 samples, whose flattest blocks sit above 100
    /// digital numbers, measured). At the a7 IV's base ISO the conversion gain is 0.243 digital
    /// numbers an electron and the read noise 4.6 electrons (PhotonsToPhotos, reported), about 1.25
    /// digital numbers squared. Until 2026-10-07 this said 0.355, read from the CC0 sample at ISO 250
    /// (`BodyNoise`); 3 electrons came to about 1 then too.
    static let minimumRead = 1.0

    /// The noise of `samples`, laid out as `layout`, from the blocks inside the crop.
    public static func estimate(_ samples: UnsafePointer<UInt16>, layout: BayerMosaicLayout) -> SensorNoise {
        var noise = fit(levels(samples, layout: layout))
        noise.read = max(noise.read, minimumRead)
        return noise
    }

    /// Each bin's level and flat-block variance, in digital numbers, and its block count.
    struct Bin: Equatable {
        var level: Double
        var variance: Double
        var blocks: Int
    }

    static func levels(_ samples: UnsafePointer<UInt16>, layout: BayerMosaicLayout) -> [Bin] {
        let greens = (0..<4).filter { layout.cfa[$0] == 1 }
        guard greens.count == 2 else { return [] }
        let (g1x, g1y) = (greens[0] & 1, greens[0] >> 1), (g2x, g2y) = (greens[1] & 1, greens[1] >> 1)
        let black1 = Double(layout.blackLevels[greens[0]]), black2 = Double(layout.blackLevels[greens[1]])
        let clip = UInt16(clamping: layout.whiteLevel - (layout.whiteLevel - layout.blackLevels[greens[0]]) / 20)
        // Blocks start on an even sample so every quad has the CFA's phase.
        let x0 = (layout.cropOrigin.x + 1) & ~1, y0 = (layout.cropOrigin.y + 1) & ~1
        let across = (layout.cropOrigin.x + layout.cropSize.width - x0) / block
        let down = (layout.cropOrigin.y + layout.cropSize.height - y0) / block
        guard across > 0, down > 0 else { return [] }
        let pitch = layout.pitch
        // Per block: its bin, or -1 when a green clipped, its level and its variance.
        var blockBins = [Int8](repeating: -1, count: across * down)
        var levels = [Float](repeating: 0, count: across * down), variances = levels
        blockBins.withUnsafeMutableBufferPointer { binOut in
            levels.withUnsafeMutableBufferPointer { levelOut in
                variances.withUnsafeMutableBufferPointer { varianceOut in
                    let out = BlockOutput(bins: binOut.baseAddress!, levels: levelOut.baseAddress!, variances: varianceOut.baseAddress!)
                    let source = UncheckedSamples(pointer: samples)
                    DispatchQueue.concurrentPerform(iterations: down) { by in
                        for bx in 0..<across {
                            // Exact in integers: 64 differences of 14-bit samples.
                            var sum = 0, squares = 0, level = 0, top: UInt16 = 0
                            for qy in 0..<(block / 2) {
                                let row = (y0 + by * block + 2 * qy) * pitch + x0 + bx * block
                                let first = source.pointer + row + g1y * pitch + g1x, second = source.pointer + row + g2y * pitch + g2x
                                for qx in 0..<(block / 2) {
                                    let a = first[2 * qx], b = second[2 * qx]
                                    top = max(top, a, b)
                                    let d = Int(a) - Int(b)
                                    sum &+= d
                                    squares &+= d &* d
                                    level &+= Int(a) &+ Int(b)
                                }
                            }
                            let clipped = top >= clip
                            let n = Double(block * block / 4)
                            let index = by * across + bx
                            let mean = Double(level) / (2 * n) - (black1 + black2) / 2
                            out.levels[index] = Float(mean)
                            out.variances[index] = Float((Double(squares) - Double(sum) * Double(sum) / n) / (n - 1) / 2)
                            out.bins[index] = clipped ? -1 : Int8(min(Self.bins - 1, max(0, Int((Self.binsPerStop * log2(max(mean, 1))).rounded(.down)))))
                        }
                    }
                }
            }
        }
        // The blocks' variances grouped by bin, in place, then each bin's lowest tenth selected.
        var counts = [Int](repeating: 0, count: bins), levelSums = [Double](repeating: 0, count: bins)
        for i in blockBins.indices where blockBins[i] >= 0 {
            counts[Int(blockBins[i])] += 1
            levelSums[Int(blockBins[i])] += Double(levels[i])
        }
        var starts = [Int](repeating: 0, count: bins + 1)
        for b in 0..<bins { starts[b + 1] = starts[b] + counts[b] }
        var grouped = [Float](repeating: 0, count: starts[bins]), fill = starts
        for i in blockBins.indices where blockBins[i] >= 0 {
            let b = Int(blockBins[i])
            grouped[fill[b]] = variances[i]
            fill[b] += 1
        }
        var out: [Bin] = []
        grouped.withUnsafeMutableBufferPointer { all in
            for b in 0..<bins where counts[b] >= minimumBlocks {
                let group = UnsafeMutableBufferPointer(rebasing: all[starts[b]..<starts[b + 1]])
                let quantile = Double(select(group, Int(flatShare * Double(counts[b] - 1))))
                out.append(Bin(level: levelSums[b] / Double(counts[b]), variance: quantile / flatQuantile, blocks: counts[b]))
            }
        }
        return out
    }

    /// The `k`th smallest of `values`, which it reorders: Hoare's selection, the median of three as
    /// the pivot.
    static func select(_ values: UnsafeMutableBufferPointer<Float>, _ k: Int) -> Float {
        var lo = 0, hi = values.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if values[mid] < values[lo] { values.swapAt(mid, lo) }
            if values[hi] < values[lo] { values.swapAt(hi, lo) }
            if values[hi] < values[mid] { values.swapAt(hi, mid) }
            let pivot = values[mid]
            var i = lo, j = hi
            while i <= j {
                while values[i] < pivot { i += 1 }
                while values[j] > pivot { j -= 1 }
                if i <= j {
                    values.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { break }
        }
        return values[k]
    }

    /// The line through the bins, weighted by their block counts and relative error; bins more
    /// than a quarter above the line are texture and are dropped, up to four times.
    static func fit(_ bins: [Bin]) -> SensorNoise {
        var kept = bins.filter { $0.variance > 0 }
        var noise = SensorNoise(shot: 0, read: 0)
        for _ in 0..<5 {
            guard !kept.isEmpty else { break }
            var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            for bin in kept {
                let w = Double(bin.blocks) / (bin.variance * bin.variance)
                sw += w; sx += w * bin.level; sy += w * bin.variance
                sxx += w * bin.level * bin.level; sxy += w * bin.level * bin.variance
            }
            let det = sw * sxx - sx * sx
            var shot = det > 0 ? (sw * sxy - sx * sy) / det : 0
            var read = det > 0 ? (sy - shot * sx) / sw : sy / sw
            if read < 0 {
                read = 0
                shot = sxx > 0 ? sxy / sxx : 0
            }
            if shot < 0 {
                shot = 0
                read = sy / sw
            }
            noise = SensorNoise(shot: shot, read: read)
            let next = kept.filter { $0.variance <= 1.25 * noise.variance(at: $0.level) }
            if next.count == kept.count || next.count < 2 { break }
            kept = next
        }
        return noise
    }
}

/// Where each block's statistics go; each block is written by one worker only.
private struct BlockOutput: @unchecked Sendable {
    let bins: UnsafeMutablePointer<Int8>
    let levels: UnsafeMutablePointer<Float>
    let variances: UnsafeMutablePointer<Float>
}

/// The mosaic, read by the workers.
private struct UncheckedSamples: @unchecked Sendable {
    let pointer: UnsafePointer<UInt16>
}
