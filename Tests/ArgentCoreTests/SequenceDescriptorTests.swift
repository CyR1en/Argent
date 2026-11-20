import CoreGraphics
import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Synthetic frames and grids; no RAW or detector.
@Suite struct SequenceDescriptorTests {
    /// A frame of `width` by `height` whose light is `rgb(x, y)`, rows from the picture's bottom.
    private func frame(_ width: Int, _ height: Int, _ rgb: (Int, Int) -> SIMD3<Float>) -> [Float16] {
        var pixels = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = rgb(x, y), i = (y * width + x) * 4
                pixels[i] = Float16(v.x); pixels[i + 1] = Float16(v.y); pixels[i + 2] = Float16(v.z)
            }
        }
        return pixels
    }

    private func grid(_ width: Int, _ height: Int, _ rgb: (Int, Int) -> SIMD3<Float>) -> ExposureAnalyzer.Grid {
        ExposureAnalyzer.grid(pixels: frame(width, height, rgb), width: width, height: height)
    }

    /// A grid of `width` by `height` cells whose light is `rgb(column, row)`, none clipped.
    private func cells(_ width: Int, _ height: Int, _ rgb: (Int, Int) -> SIMD3<Float>) -> ExposureAnalyzer.Grid {
        let all = (0..<width * height).map { rgb($0 % width, $0 / width) }
        return ExposureAnalyzer.Grid(width: width, height: height, step: 1, frameWidth: width, frameHeight: height,
                                     light: all, all: all, unclipped: Array(repeating: 1, count: all.count),
                                     weight: Array(repeating: 1, count: all.count))
    }

    /// Textured light from two and a half stops under to nearly two over mid-gray, a little warm;
    /// a stop more of it stays under the decoder's clip.
    private let scene: (Int, Int) -> SIMD3<Float> = { x, y in
        SIMD3<Float>(1.1, 1, 0.9) * 0.18 * exp2(Float(x % 17) / 4 - 2.5 + Float(y % 5) / 10)
    }

    /// A flat frame's descriptor is its light everywhere, nothing clipped and no detail: 3/16 sums
    /// and divides exactly.
    @Test func aFlatFrameIsFlat() {
        let light = SIMD3<Float>(0.25, 0.1875, 0.125)
        let descriptor = SequenceDescriptor(grid: grid(960, 640) { _, _ in light })
        #expect(descriptor.width == 64 && descriptor.height == 43)
        #expect(descriptor.rgb.count == 64 * 43 * 3 && descriptor.unclipped.count == 64 * 43 && descriptor.detail.count == 64 * 43)
        for cell in 0..<64 * 43 {
            #expect(SIMD3(descriptor.rgb[cell * 3], descriptor.rgb[cell * 3 + 1], descriptor.rgb[cell * 3 + 2]) == light)
        }
        #expect(descriptor.unclipped.allSatisfy { $0 == 1 })
        #expect(descriptor.detail.allSatisfy { $0 == 0 })
    }

    /// A stop more light on the same scene doubles each cell's light and leaves its texture as it
    /// was, while it stays under the decoder's clip.
    @Test func aStopOfLightIsAStop() {
        let base = SequenceDescriptor(grid: grid(960, 640, scene))
        let brighter = SequenceDescriptor(grid: grid(960, 640) { self.scene($0, $1) * 2 })
        #expect(brighter.rgb == base.rgb.map { $0 * 2 })
        #expect(brighter.unclipped == base.unclipped)
        #expect(zip(brighter.detail, base.detail).allSatisfy { abs($0 - $1) < 1e-5 })
        #expect(base.detail.allSatisfy { $0 > 0.1 })
    }

    /// The spans of a descriptor's columns or rows tile the grid's from first to last, none empty,
    /// for every grid up to 300 cells a side and every descriptor no larger.
    @Test func everyGridCellIsHeldOnce() {
        var tiled = true
        for gridCount in 1...300 {
            for count in 1...min(SequenceDescriptor.longSide, gridCount) {
                var next = 0
                for index in 0..<count {
                    let span = SequenceDescriptor.gridSpan(index, of: count, over: gridCount)
                    tiled = tiled && span.lowerBound == next && !span.isEmpty
                    next = span.upperBound
                }
                tiled = tiled && next == gridCount
            }
        }
        #expect(tiled)
    }

    /// Each descriptor cell holds the block its documented integer bounds give: on a grid whose
    /// light is its column and row, a cell's mean is the middle of its block.
    @Test func cellsHoldTheirDocumentedBlocks() {
        for (width, height) in [(240, 160), (316, 211), (157, 101), (160, 240), (65, 3)] {
            let descriptor = SequenceDescriptor(grid: cells(width, height) { SIMD3(Float($0), Float($1), 1) })
            for v in 0..<descriptor.height {
                let rows = v * height / descriptor.height, rowEnd = (v + 1) * height / descriptor.height
                for u in 0..<descriptor.width {
                    let columns = u * width / descriptor.width, columnEnd = (u + 1) * width / descriptor.width
                    let cell = (v * descriptor.width + u) * 3
                    #expect(abs(descriptor.rgb[cell] - Float(columns + columnEnd - 1) / 2) < 1e-3)
                    #expect(abs(descriptor.rgb[cell + 1] - Float(rows + rowEnd - 1) / 2) < 1e-3)
                }
            }
        }
    }

    /// An upright portrait decode gives a portrait descriptor, its rows from the picture's bottom;
    /// a lossless S decode, a few pixels short and sampled every three, keeps the sheet's shape.
    @Test func keepsTheDecodesShape() {
        // Light in the bottom quarter of the picture, the first rows of its texture.
        let portrait = SequenceDescriptor(grid: grid(640, 960) { _, y in SIMD3(repeating: y < 240 ? 0.75 : 0.1875) })
        #expect(portrait.width == 43 && portrait.height == 64)
        #expect(portrait.rgb[0] == 0.75 && portrait.rgb[(63 * 43) * 3] == 0.1875)
        let short = SequenceDescriptor(grid: grid(948, 632, scene))
        #expect(short.width == 64 && short.height == 43)
        let landscape = SequenceDescriptor(grid: grid(960, 640, scene))
        #expect(landscape.width == 64 && landscape.height == 43)
    }

    /// Clipped light counts in a cell's light, as the renderer sees it, and its share shows in the
    /// cell's unclipped share: a sky clipped over the picture's bottom quarter, and a frame whose
    /// every cell has one clipped pixel in sixteen.
    @Test func clippedHighlightsShowInTheUnclippedShare() {
        // Eight is past every raw mode's clip; the frame's brightest light sits there.
        let sky = grid(960, 640) { _, y in SIMD3(repeating: y < 160 ? 8 : 0.1875) }
        let descriptor = SequenceDescriptor(grid: sky)
        for v in 0..<descriptor.height {
            let rows = SequenceDescriptor.gridSpan(v, of: descriptor.height, over: sky.height)
            let share = Float(rows.filter { $0 >= 40 }.count) / Float(rows.count)
            #expect(abs(descriptor.unclipped[v * descriptor.width + 5] - share) < 1e-6)
        }
        #expect(descriptor.rgb[0] == 8 && descriptor.unclipped[0] == 0)
        #expect(descriptor.unclipped.last == 1 && descriptor.rgb.last == 0.1875)

        let specks = SequenceDescriptor(grid: grid(960, 640) { x, y in SIMD3(repeating: x % 4 == 0 && y % 4 == 0 ? 8 : 0.1875) })
        #expect(specks.unclipped.allSatisfy { $0 == 15.0 / 16 })
        #expect(specks.detail.allSatisfy { $0 == 0 })
    }

    /// A grid no larger than the descriptor is kept cell for cell; a line of a frame is one row;
    /// a frame of no pixels has no cells.
    @Test func smallGridsAreKept() {
        let small = grid(40, 27, scene)
        let kept = SequenceDescriptor(grid: small)
        #expect(kept.width == 40 && kept.height == 27)
        #expect(kept.rgb == small.all.flatMap { [$0.x, $0.y, $0.z] })
        #expect(kept.unclipped == small.unclipped)
        #expect(kept.detail.allSatisfy { $0 == 0 })

        let edge = SequenceDescriptor(grid: cells(64, 64) { SIMD3(Float($0), Float($1), 1) })
        #expect(edge.width == 64 && edge.height == 64)
        let past = SequenceDescriptor(grid: cells(65, 65) { SIMD3(Float($0), Float($1), 1) })
        #expect(past.width == 64 && past.height == 64)

        let line = SequenceDescriptor(grid: grid(960, 2) { _, _ in SIMD3(repeating: 0.375) })
        #expect(line.width == 64 && line.height == 1 && line.rgb.count == 64 * 3)

        let none = SequenceDescriptor(grid: ExposureAnalyzer.grid(pixels: [], width: 0, height: 0))
        #expect(none.width == 0 && none.height == 0 && none.rgb.isEmpty && none.unclipped.isEmpty && none.detail.isEmpty)
    }

    /// The same pixels give the same descriptor, bit for bit.
    @Test func isDeterministic() {
        let pixels = frame(960, 640, scene)
        let first = SequenceDescriptor(grid: ExposureAnalyzer.grid(pixels: pixels, width: 960, height: 640))
        let second = SequenceDescriptor(grid: ExposureAnalyzer.grid(pixels: pixels, width: 960, height: 640))
        #expect(first == second)
        #expect(first.rgb.map(\.bitPattern) == second.rgb.map(\.bitPattern))
        #expect(first.detail.map(\.bitPattern) == second.detail.map(\.bitPattern))
    }

    /// `measure` gives what `analyze` gives, bit for bit, and what the analysis was before it:
    /// the grid's analysis, faces looked for, and the descriptor of that grid.
    @Test func measureIsAnalyzeAndTheGridsDescriptor() throws {
        let gpu = try GPU()
        let width = 960, height = 640
        // The scene with a clipped patch, so the clip and the trims both take part.
        var pixels = frame(width, height) { x, y in x > 700 && y > 500 ? SIMD3(repeating: 8) : self.scene(x, y) }
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 1 }
        let texture = try gpu.texturePool.acquire(width: width, height: height)
        pixels.withUnsafeBytes { texture.texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                                         withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        let linear = LinearFrame(image: texture, decoderVersion: "test", scale: 1)
        for workingSpace in [nil, gpu.workingColorSpace] as [CGColorSpace?] {
            let measured = ExposureAnalyzer.measure(linear, workingSpace: workingSpace)
            let analysed = ExposureAnalyzer.analyze(linear, workingSpace: workingSpace)
            #expect(measured.analysis == analysed)
            #expect(measured.analysis.meanStops.bitPattern == analysed.meanStops.bitPattern)
            #expect(measured.analysis.histogram.map(\.bitPattern) == analysed.histogram.map(\.bitPattern))
            #expect(measured.analysis.grayEstimate.map(\.bitPattern) == analysed.grayEstimate.map(\.bitPattern))
        }
        let grid = ExposureAnalyzer.grid(pixels: ExposureAnalyzer.pixels(of: linear.texture), width: width, height: height)
        let measured = ExposureAnalyzer.measure(linear)
        #expect(measured.analysis == ExposureAnalyzer.analyze(grid: grid))
        #expect(measured.descriptor == SequenceDescriptor(grid: grid))
        #expect(measured.descriptor.width == 64 && measured.descriptor.height == 43)
    }
}
