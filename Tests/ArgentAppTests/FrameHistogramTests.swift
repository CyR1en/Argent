import ArgentCore
import ArgentRoll
import CoreGraphics
import SwiftUI
import Testing
@testable import ArgentApp

struct FrameHistogramTests {
    private func pixels(_ colors: [(UInt8, UInt8, UInt8)]) -> [UInt8] {
        colors.flatMap { [$0.0, $0.1, $0.2, 0] }
    }

    @Test func eachChannelFallsInItsOwnBinOnOneScale() throws {
        // Mid gray and a red, which differ only where the channels part.
        let histogram = try #require(FrameHistogram.measure(rgbx: pixels(
            Array(repeating: (128, 128, 128), count: 30) + Array(repeating: (200, 64, 64), count: 10))))
        let bins = FrameHistogram.binCount
        #expect(histogram.red.count == bins && histogram.green.count == bins && histogram.blue.count == bins)
        let gray = 128 * bins / 256, red = 200 * bins / 256, dark = 64 * bins / 256
        #expect(histogram.green[gray] == 1 && histogram.blue[gray] == 1)
        #expect(histogram.red[gray] == histogram.green[gray])
        #expect(histogram.red[red] > 0 && histogram.green[red] == 0)
        #expect(histogram.green[dark] > 0 && histogram.red[dark] == 0)
        #expect(!histogram.clipsShadows && !histogram.clipsHighlights)
        #expect(histogram.summary == "No clipping")
    }

    @Test func clippingCountsAPixelWithAnyChannelAtAnEnd() throws {
        let histogram = try #require(FrameHistogram.measure(rgbx: pixels(
            Array(repeating: (120, 120, 120), count: 96) + [(0, 40, 40), (0, 0, 0), (255, 200, 200), (128, 128, 128)])))
        #expect(histogram.shadowsClipped == 2.0 / 100)
        #expect(histogram.highlightsClipped == 1.0 / 100)
        #expect(histogram.clipsShadows && histogram.clipsHighlights)
    }

    @Test func aSpikeAtAnEndDoesNotFlattenTheRest() throws {
        // Mostly black, with a little mid-tone: the mid-tone still reaches the top, the spike is cut.
        let histogram = try #require(FrameHistogram.measure(rgbx: pixels(
            Array(repeating: (0, 0, 0), count: 900) + Array(repeating: (128, 128, 128), count: 100))))
        #expect(histogram.green[FrameHistogram.binCount / 2] == 1)
        #expect(histogram.green[0] == 1)
        #expect(histogram.green.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func aPictureAllAtOneEndStillHasAShape() throws {
        let histogram = try #require(FrameHistogram.measure(rgbx: pixels(Array(repeating: (0, 0, 0), count: 50))))
        #expect(histogram.red[0] == 1 && histogram.shadowsClipped == 1)
        #expect(FrameHistogram.measure(rgbx: []) == nil)
    }

    @Test func measuresACGImage() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        let image = try #require(context.makeImage())
        let histogram = try #require(FrameHistogram.measure(image))
        let peak = try #require(histogram.green.indices.max { histogram.green[$0] < histogram.green[$1] })
        #expect(abs(peak - FrameHistogram.binCount / 2) <= 1)
    }

    /// A print that ends inside the codes, as every stock's black does (8 to 18) and the Studio stocks'
    /// white (251, 252): clipping is at its own ends, and its crushed black does not flatten the rest.
    @Test func aPrintsOwnEndsSetClippingAndTheScale() throws {
        let limits = PrintLimits(white: SIMD3(repeating: 251), black: SIMD3(repeating: 17))
        let colors = Array(repeating: (UInt8(17), UInt8(17), UInt8(17)), count: 350)
            + Array(repeating: (UInt8(128), UInt8(128), UInt8(128)), count: 640)
            + Array(repeating: (UInt8(252), UInt8(240), UInt8(230)), count: 10)
        let histogram = try #require(FrameHistogram.measure(rgbx: pixels(colors), limits: limits))
        #expect(histogram.shadowsClipped == 0.35)
        #expect(histogram.highlightsClipped == 0.01)
        #expect(histogram.green[FrameHistogram.bin(128)] == 1)
        // The same frame measured against the display's ends misses both.
        let display = try #require(FrameHistogram.measure(rgbx: pixels(colors)))
        #expect(!display.clipsShadows && !display.clipsHighlights)
        // Ends a curve has turned round fall back to the display's.
        let inverted = PrintLimits(white: SIMD3(repeating: 10), black: SIMD3(repeating: 240))
        #expect(FrameHistogram.measure(rgbx: pixels(colors), limits: inverted) == display)
    }

    /// Small specular specks on a grainy mid-gray survive the downscale as clipping, and no tones
    /// between the grain and the white are invented.
    @Test func specksOfWhiteSurviveTheDownscale() throws {
        let width = 2560, height = 1707
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var generator = SystemRandomNumberGenerator()
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let speck = (x / 5) % 7 == 0 && (y / 5) % 7 == 0
                let code = speck ? UInt8(255) : UInt8.random(in: 98...122, using: &generator)
                bytes[i] = code; bytes[i + 1] = code; bytes[i + 2] = code
            }
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                         space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let histogram = try #require(FrameHistogram.measure(image))
        #expect(abs(histogram.highlightsClipped - 1.0 / 49) < 0.01)
        #expect(histogram.clipsHighlights)
        // Nothing between the grain and the white but what the smoothing spreads.
        let between = FrameHistogram.bin(130)...FrameHistogram.bin(245)
        #expect(histogram.green[between].allSatisfy { $0 == 0 })
    }

    /// A Display P3 or Adobe RGB film keeps its codes through the measurement.
    @Test func aWideGamutFilmKeepsItsCodes() throws {
        for name in [CGColorSpace.displayP3, CGColorSpace.adobeRGB1998] {
            let space = try #require(CGColorSpace(name: name))
            let context = try #require(CGContext(data: nil, width: 300, height: 450, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(try #require(CGColor(colorSpace: space, components: [200.0 / 255, 60.0 / 255, 20.0 / 255, 1])))
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 450))
            let image = try #require(context.makeImage())
            let histogram = try #require(FrameHistogram.measure(image))
            #expect(histogram.red[FrameHistogram.bin(200)] == 1, "\(name)")
            #expect(histogram.green[FrameHistogram.bin(60)] == 1, "\(name)")
            #expect(histogram.blue[FrameHistogram.bin(20)] == 1, "\(name)")
        }
    }

    @Test func theSummarySaysWhichEndClips() {
        func histogram(_ shadows: Double, _ highlights: Double) -> FrameHistogram {
            FrameHistogram(red: [], green: [], blue: [], shadowsClipped: shadows, highlightsClipped: highlights)
        }
        #expect(histogram(0, 0).summary == "No clipping")
        #expect(histogram(0.004, 0).summary == "Shadows clipped 0.4%")
        #expect(histogram(0, 0.012).summary == "Highlights clipped 1.2%")
        #expect(histogram(0.004, 0.012).summary == "Shadows clipped 0.4%, highlights clipped 1.2%")
        #expect(histogram(0.0004, 0.0004).summary == "No clipping")
    }

    @Test func theFillPathStaysWithinItsPlot() {
        let plot = CGRect(x: 0, y: 8, width: 240, height: 55.5)
        let values: [Float] = (0..<FrameHistogram.binCount).map { Float($0 % 7) / 6 }
        let bounds = FrameHistogramView.path(values, in: plot, baseline: 63.5, closed: true).boundingRect
        #expect(bounds.minX >= -0.01 && bounds.maxX <= 240.01)
        #expect(bounds.minY >= 8 - 0.01 && bounds.maxY <= 63.5 + 0.01)
    }

    // MARK: The histogram as a control

    /// Five ranges, shadows first, that leave no gap and cover the width: Blacks, Shadows, Exposure, Highlights, Whites.
    @Test func theFiveRangesCoverTheHistogramInOrder() {
        #expect(FrameHistogram.ranges.map(\.control) == [.blacks, .shadows, .exposure, .highlights, .whites])
        #expect(FrameHistogram.ranges.first?.range.lowerBound == 0 && FrameHistogram.ranges.last?.range.upperBound == 1)
        for (range, next) in zip(FrameHistogram.ranges, FrameHistogram.ranges.dropFirst()) {
            #expect(range.range.upperBound == next.range.lowerBound, "\(range.control) to \(next.control)")
            #expect(range.range.lowerBound < range.range.upperBound)
        }
    }

    /// The control under a point of the width is the one whose range holds it; a control's row lights that same range, and
    /// Contrast, which has none of the five, the whole.
    @Test func aPointOfTheWidthIsOneControlsAndThatControlLightsItsRange() {
        let table: [(Double, ManualAdjustments.Control)] = [
            (0, .blacks), (0.05, .blacks), (0.1, .shadows), (0.3, .shadows), (0.35, .exposure), (0.5, .exposure),
            (0.65, .highlights), (0.89, .highlights), (0.9, .whites), (1, .whites),
            // Past either end, as a drag that leaves the histogram is: the range at that end.
            (-0.2, .blacks), (1.4, .whites),
        ]
        for (fraction, control) in table {
            #expect(FrameHistogram.control(at: fraction) == control, "\(fraction)")
        }
        for (control, range) in FrameHistogram.ranges {
            #expect(FrameHistogram.range(of: control) == range)
            #expect(FrameHistogram.control(at: (range.lowerBound + range.upperBound) / 2) == control)
        }
        #expect(FrameHistogram.range(of: .contrast) == 0...1)
    }

    /// A drag across the whole width moves a control half its range, on the control's own steps and inside its range.
    @Test func aDragMovesItsControlHalfItsRangeAcrossTheWidth() {
        #expect(FrameHistogram.dragged(.shadows, from: 0, by: 1) == 100)
        #expect(FrameHistogram.dragged(.shadows, from: 0, by: -0.5) == -50)
        #expect(FrameHistogram.dragged(.shadows, from: 24, by: 0.1) == 34)
        #expect(FrameHistogram.dragged(.shadows, from: 80, by: 1) == 100, "it stops at the range's end")
        // Exposure's ten stops: a quarter of the width is one and a quarter, on its hundredths.
        #expect(FrameHistogram.dragged(.exposure, from: 0, by: 0.25) == 1.25)
        #expect(FrameHistogram.dragged(.exposure, from: 0.35, by: -0.07) == 0)
        #expect(FrameHistogram.dragged(.exposure, from: 4.5, by: 1) == 5)
        #expect(FrameHistogram.dragged(.blacks, from: -6, by: 0) == -6)
    }

    /// The wedge under the histogram and along the curve's axes: eleven steps, as a step tablet has.
    @MainActor @Test func theStepWedgeHasElevenSteps() {
        #expect(StepWedge.steps == 11 && StepWedge.thickness == 5)
        #expect(FrameHistogramView.height == FrameHistogramView.plotHeight + StepWedge.thickness)
    }
}
