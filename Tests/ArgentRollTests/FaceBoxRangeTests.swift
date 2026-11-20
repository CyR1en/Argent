import CoreGraphics
import Testing
@testable import ArgentCore

/// Kept separate so the before-fix range-conversion trap can be witnessed in isolation.
@Suite struct FaceBoxRangeTests {
    private var grid: ExposureAnalyzer.Grid {
        ExposureAnalyzer.Grid(width: 4, height: 4, step: 1, frameWidth: 4, frameHeight: 4,
            light: Array(repeating: SIMD3(repeating: Float(0.18)), count: 16),
            all: Array(repeating: SIMD3(repeating: Float(0.18)), count: 16),
            unclipped: Array(repeating: 1, count: 16), weight: Array(repeating: 1, count: 16))
    }

    @Test func hugeFiniteOffFrameBoxesMeterNothing() {
        let boxes = [CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: 1, height: 1),
                     CGRect(x: 0, y: -CGFloat.greatestFiniteMagnitude, width: 1, height: 1),
                     CGRect(x: CGFloat(Int.max), y: 0, width: 1, height: 1)]
        #expect(FaceMeter.meter(boxes, grid: grid).isEmpty)
    }

    @Test func hugeSpanningBoxCannotReturnUnrepresentableFloatComponents() {
        let box = CGRect(x: -CGFloat.greatestFiniteMagnitude / 2, y: 0,
                         width: CGFloat.greatestFiniteMagnitude, height: 1)
        #expect(FaceMeter.meter([box], grid: grid).isEmpty)
    }

    @Test func wideRepresentableSpanningBoxClipsToTheFrame() throws {
        let box = CGRect(x: -1e20, y: 0, width: 2e20, height: 1)
        let face = try #require(FaceMeter.meter([box], grid: grid).first)
        #expect(face.box.allSatisfy { $0.isFinite })
        #expect(face.area == 1)
        #expect(abs(face.levelStops) < 1e-5)
    }
}
