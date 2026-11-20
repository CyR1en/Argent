import ArgentCore
import Foundation
import Testing
@testable import ArgentRoll

@Suite struct RollSmoothingTests {
    private func frame(_ index: Int, seconds: Double?, ev: Double = 10, flash: Bool? = nil) -> Frame {
        // EV100 10 at f/4 and ISO 100: t = 16 / 2^10.
        let t = 16 / exp2(ev)
        return Frame(id: index, url: URL(fileURLWithPath: "/roll/DSC\(index).ARW"),
                     info: ARWFrameInfo(captureDate: seconds.map { Date(timeIntervalSince1970: 1_700_000_000 + $0) },
                                        exposureTime: t, fNumber: 4, iso: 100, flashFired: flash))
    }

    /// A measurement whose histogram sits all in the bin of `stops`.
    private func analysis(_ mean: Float, histogramAt stops: Float = 0, kelvin: Float? = 5200, gray: [Float] = []) -> ExposureAnalysis {
        var histogram = [Float](repeating: 0, count: ExposureAnalysis.histogramBins)
        histogram[Int((stops - ExposureAnalysis.histogramLowStops) / ExposureAnalysis.histogramBinStops)] = 1
        return ExposureAnalysis(meanStops: mean, validWeight: 1, histogram: histogram, asShotTemperature: kelvin, grayEstimate: gray)
    }

    private func sizes(_ frames: [Frame], _ analyses: [URL: ExposureAnalysis] = [:]) -> [Int] {
        RollSmoothing.clusters(frames, analyses: analyses).map(\.count)
    }

    @Test func splitsOnTimeLightFlashAndUnknownTimes() {
        // Two minutes apart is together; a gap over two minutes is not.
        #expect(sizes([frame(0, seconds: 0), frame(1, seconds: 100), frame(2, seconds: 220), frame(3, seconds: 400)]) == [3, 1])
        // A jump of more than one EV in the light the camera exposed for.
        #expect(sizes([frame(0, seconds: 0, ev: 10), frame(1, seconds: 1, ev: 10.8), frame(2, seconds: 2, ev: 12)]) == [2, 1])
        #expect(sizes([frame(0, seconds: 0, flash: false), frame(1, seconds: 1, flash: true), frame(2, seconds: 2)]) == [1, 2])
        #expect(sizes([frame(0, seconds: 0), frame(1, seconds: nil), frame(2, seconds: 1)]) == [1, 1, 1])
    }

    @Test func splitsOnWhiteBalanceAndHistogramOnceMeasured() {
        let frames = (0..<4).map { frame($0, seconds: Double($0)) }
        // Measured: 5200 K to 4500 K is 30 mired; a histogram two stops away; the same light.
        let measured = [frames[0].url: analysis(0), frames[1].url: analysis(0, kelvin: 4500),
                        frames[2].url: analysis(0, histogramAt: 2, kelvin: 4500), frames[3].url: analysis(0, histogramAt: 2, kelvin: 4500)]
        #expect(sizes(frames, measured) == [1, 1, 2])
        // Not measured yet, only the header's splits apply.
        #expect(sizes(frames) == [4])
    }

    @Test func pullsEachFrameHalfwayToItsClusterAndNoFurtherThanAThird() throws {
        let frames = (0..<4).map { frame($0, seconds: Double($0)) }
        let means: [Float] = [-3, 0, 0.3, 2.5]
        let analyses = Dictionary(uniqueKeysWithValues: zip(frames.map(\.url), means.map { analysis($0) }))
        let levels = RollSmoothing.levels(frames, analyses: analyses)
        // Each frame's own level, Auto's aim for it alone, pulled halfway to the cluster's median of
        // them; one further than two thirds of a stop from it is held a third of a stop away.
        let own = means.map { AutoPrint.levelStops(analysis($0)) }
        let median = RollSmoothing.median(own)
        var halfway = 0, held = 0
        for (frame, level) in zip(frames, own) {
            let smoothed = try #require(levels[frame.url])
            if abs(level - median) <= 2 * RollSmoothing.maximumDeviation {
                #expect(abs(smoothed - (median + RollSmoothing.pull * (level - median))) < 1e-5, "\(frame.name)")
                halfway += 1
            } else {
                #expect(abs(abs(smoothed - median) - RollSmoothing.maximumDeviation) < 1e-5, "\(frame.name)")
                #expect((smoothed - median).sign == (level - median).sign, "\(frame.name)")
                held += 1
            }
        }
        #expect(halfway == 2 && held == 2)
        // A frame on its own keeps its own bounded level.
        let alone = frame(9, seconds: 9999)
        #expect(RollSmoothing.levels([alone], analyses: [alone.url: analysis(-3)])[alone.url] == AutoPrint.levelStops(analysis(-3)))
        // A frame not measured has no level and does not move the median.
        #expect(RollSmoothing.levels(frames, analyses: [frames[0].url: analysis(-1.2)])
                == [frames[0].url: AutoPrint.levelStops(analysis(-1.2))])
    }

    /// A cluster is filtered as one: every frame takes the cluster's median cast.
    @Test func everyFrameOfAClusterTakesItsMedianCast() {
        let frames = (0..<3).map { frame($0, seconds: Double($0)) }
        let grays: [[Float]] = [[0.6, 0, -0.6], [0.4, 0, -0.4], [1.6, 0, -1.6]]
        let analyses = Dictionary(uniqueKeysWithValues: zip(frames.map(\.url), grays.map { analysis(0, gray: $0) }))
        let aims = RollSmoothing.aims(frames, analyses: analyses)
        for frame in frames {
            #expect(abs(AutoBalance.axes(aims[frame.url]!.cast).redBlue - 1.2) < 1e-5)
        }
    }

    /// Smoothing keeps its median cap when one frame's face moves its own aim far from the others':
    /// nothing about the face is applied again after smoothing, which would put the frame past the cap.
    @Test func mixedFaceClusterKeepsTheMedianCapAndOneCast() throws {
        let frames = (0..<3).map { frame($0, seconds: Double($0)) }
        var lit = analysis(-3, gray: [0.6, 0, -0.6])
        lit.faces = [FaceMeasure(box: [0.4, 0.3, 0.2, 0.3], levelStops: 2.5, area: 0.04)]
        let measured = [frames[0].url: lit,
                        frames[1].url: analysis(-3, gray: [0.4, 0, -0.4]),
                        frames[2].url: analysis(-3, gray: [1.6, 0, -1.6])]
        #expect(RollSmoothing.clusters(frames, analyses: measured).map(\.count) == [3])
        let faceless = AutoPrint.levelStops(measured[frames[1].url])
        // The lit face raises its frame's own aim more than two thirds of a stop over the others'.
        #expect(AutoPrint.levelStops(lit) - faceless > 2 * RollSmoothing.maximumDeviation)
        let aims = RollSmoothing.aims(frames, analyses: measured)
        let expected: [Float] = [faceless + RollSmoothing.maximumDeviation, faceless, faceless]
        for (frame, level) in zip(frames, expected) {
            let aim = try #require(aims[frame.url])
            #expect(abs(aim.level - level) < 1e-5)
            #expect(abs(aim.level - faceless) <= RollSmoothing.maximumDeviation + 1e-5)
            #expect(abs(AutoBalance.axes(aim.cast).redBlue - 1.2) < 1e-5)
            #expect(abs(AutoBalance.axes(aim.cast).greenMagenta) < 1e-5)
        }
    }
}
