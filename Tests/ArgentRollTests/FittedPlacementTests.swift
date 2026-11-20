import ArgentCore
import Testing
@testable import ArgentRoll

/// Auto's fitted aim and tone step against the fit's own Python (docs/research/auto/balance-research.md,
/// section 7d, `freeze3.py`) on synthetic measurements, and their continuity and bounds.
@Suite struct FittedPlacementTests {
    static let spread: [Float] = [0, 0, 0.01, 0.02, 0.05, 0.08, 0.12, 0.15, 0.14, 0.12, 0.1, 0.08, 0.05, 0.03, 0.02,
                                  0.01, 0.01, 0.005, 0.003, 0.002]
    static let narrow: [Float] = [0, 0, 0, 0, 0, 0, 0.05, 0.1, 0.15, 0.2, 0.2, 0.15, 0.08, 0.04, 0.02, 0.005, 0.003, 0.002, 0, 0]

    static func analysis(_ level: Float, _ histogram: [Float], faces: [(area: Float, level: Float)] = []) -> ExposureAnalysis {
        ExposureAnalysis(meanStops: level, validWeight: 1, histogram: histogram,
                         faces: faces.map { FaceMeasure(box: [0.4, 0.3, 0.2, 0.3], levelStops: $0.level, area: $0.area) })
    }

    @Test func matchesTheFitsPython() {
        // The same features and the frozen coefficients, computed in double precision.
        let cases: [(ExposureAnalysis, aim: Float, burn: Float, dodge: Float)] = [
            (Self.analysis(-1.2, Self.spread, faces: [(0.02, -0.3)]), -0.132500, 0.814010, 0.136175),
            (Self.analysis(0.8, Self.narrow), 0.339300, 0.198270, 0.045787),
            (Self.analysis(0.3, []), 0.206550, 0.340400, 0),
            (Self.analysis(-2, Self.spread, faces: [(0.0008, -1.0), (0.0002, 0.5)]), -0.422362, 0.983610, 0.154575),
        ]
        for (analysis, aim, burn, dodge) in cases {
            #expect(abs(AutoPrint.levelStops(analysis) - aim) < 1e-4)
            let tone = FittedTone.strengths(analysis)
            #expect(abs(tone.burn - burn) < 1e-4)
            #expect(abs(tone.dodge - dodge) < 1e-4)
            let whole = AutoPrint.aim(analysis)
            #expect(whole.level == AutoPrint.levelStops(analysis) && whole.burn == tone.burn && whole.dodge == tone.dodge)
        }
        let features = FittedPlacement.Features(Self.analysis(-1.2, Self.spread, faces: [(0.02, -0.3)]))
        #expect(abs(features.shadowSpread - 1.625) < 1e-5 && abs(features.highlightSpread - 2.05) < 1e-5)
        #expect(abs(features.bright - 0.03) < 1e-5 && abs(features.dark - 0.03) < 1e-5)
        #expect(abs(features.reach - 3.5) < 1e-5)
        #expect(FittedPlacement.Features(Self.analysis(0.3, [])).reach == FittedPlacement.noReach)
        #expect(features.faceWeight == 1 && abs(features.faceOffset - 0.9) < 1e-5 && abs(features.faceFrameLevel + 1.2) < 1e-5)
        // Faces under `fullFaceArea` weigh the square root of their share of it.
        let small = FittedPlacement.Features(Self.analysis(-2, Self.spread, faces: [(0.0008, -1.0), (0.0002, 0.5)]))
        #expect(abs(small.faceWeight - 0.632456) < 1e-5 && abs(small.faceOffset - 0.822192) < 1e-5)
        #expect(abs(small.faceFrameLevel + 1.264911) < 1e-5)
    }

    @Test func staysWithinTheBoundEitherWay() {
        #expect(AutoPrint.levelStops(Self.analysis(9, Self.narrow)) == AutoPrint.bound)
        #expect(AutoPrint.levelStops(Self.analysis(-9, Self.spread)) == -AutoPrint.bound)
        #expect(AutoPrint.levelStops(Self.analysis(.nan, Self.spread)) == 0)
        #expect(AutoPrint.levelStops(nil) == 0)
    }

    @Test func theToneStaysWithinItsLimits() {
        let wide = Self.analysis(-3, [0.4, 0.1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.1, 0.1, 0.1, 0.2])
        #expect(FittedTone.strengths(wide).burn <= FittedTone.burnLimit)
        #expect(FittedTone.strengths(Self.analysis(9, Self.narrow)).burn == 0, "a bright, narrow frame has nothing to hold back")
        let broken = FittedTone.strengths(Self.analysis(.nan, Self.spread))
        #expect(broken.burn == 0 && broken.dodge == 0)
        #expect(AutoPrint.aim(nil) == PrintAim())
    }

    @Test func aFramesReachMovesItsAimALittleAndItsBurnMore() {
        // The same level with a long bright tail or without: the burn holds most of the range, and the aim prints it a little down.
        let tail = Self.analysis(-0.5, [0, 0, 0, 0, 0, 0, 0, 0.1, 0.2, 0.2, 0.1, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05])
        let plain = Self.analysis(-0.5, [0, 0, 0, 0, 0, 0, 0, 0.1, 0.3, 0.3, 0.2, 0.1, 0, 0, 0, 0, 0, 0, 0, 0])
        let further = FittedPlacement.Features(tail).reach - FittedPlacement.Features(plain).reach
        #expect(further > 2)
        #expect(abs(AutoPrint.levelStops(tail) - AutoPrint.levelStops(plain) - 0.181 * further) < 1e-4)
        #expect(FittedTone.strengths(tail).burn > FittedTone.strengths(plain).burn + 0.176 * further)
    }

    /// No switch: the aim moves by a small step for a small step in any input, through the old
    /// rule's 1.5 % face threshold, zero level and empty face list.
    @Test func movesContinuously() {
        var previous: Float?
        for i in 0...400 {
            let level = -2 + Float(i) * 0.01
            let aim = AutoPrint.levelStops(Self.analysis(level, Self.spread))
            if let previous { #expect(abs(aim - previous) < 0.01) }
            previous = aim
        }
        // The face weight grows as the square root of the faces' area up to `fullFaceArea`:
        // continuous, steepest for the smallest faces. A face of a millionth of the frame moves the
        // aim by under 0.01 stop, and so does each further millionth.
        previous = AutoPrint.levelStops(Self.analysis(-1, Self.spread))
        for i in 1...3000 {
            let aim = AutoPrint.levelStops(Self.analysis(-1, Self.spread, faces: [(Float(i) * 1e-6, 0.5)]))
            #expect(abs(aim - previous!) < 0.01)
            previous = aim
        }
        // From `fullFaceArea` on, a larger face at the same level changes nothing.
        let full = AutoPrint.levelStops(Self.analysis(-1, Self.spread, faces: [(FittedPlacement.fullFaceArea, 0.5)]))
        #expect(AutoPrint.levelStops(Self.analysis(-1, Self.spread, faces: [(0.04, 0.5)])) == full)
    }
}
