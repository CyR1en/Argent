import ArgentCore
import Foundation
import Testing

@Suite struct GateEvaluationProtocolTests {
    private func fixture() -> GateEvaluationProtocol {
        var face = GateEvaluationProtocol.Face(
            FaceMeasure(box: [0, 0, 1, 1], levelStops: 0, area: 0.25), width: 4, height: 4)
        face.region = .init(x0: 0, x1: 2, y0: 0, y1: 2)
        return GateEvaluationProtocol(inputs: ["portrait", "excluded"], frames: [
            .init(name: "portrait", width: 4, height: 4, orientations: [0, 1, 0, 1, 0], face: face)
        ], exclusions: ["excluded": "fixed alignment exclusion"])
    }

    @Test func detectorMissOrAnotherFaceCannotChangeScoringRegion() throws {
        let locked = fixture().frames[0]
        let otherFace = FaceMeasure(box: [0.5, 0, 0.5, 1], levelStops: 2, area: 0.4)
        var pixels = [Float16](repeating: 0.9, count: 4 * 4 * 4)
        for y in 0..<2 { for x in 0..<2 {
            for channel in 0..<3 { pixels[(y * 4 + x) * 4 + channel] = 0.01 }
        } }
        for detected in [nil, otherFace] {
            let face = try #require(GateEvaluationProtocol.evaluationFace(
                locked: locked, detected: detected, width: 4, height: 4))
            let result = GateMeasureTests.measure(pixels, width: 4, height: 4, region: face.region)
            #expect(abs(result.lightness - GateMeasureTests.lightness(Double(Float16(0.01)))) < 1e-8)
        }
        var faceless = locked
        faceless.face = nil
        #expect(GateEvaluationProtocol.evaluationFace(locked: faceless, detected: otherFace, width: 4, height: 4) == nil)
    }

    @Test func failsOnMissingAddedOrDuplicateInputsAndChangedGeometry() throws {
        let record = fixture()
        try record.validate()
        for names in [["portrait"], ["portrait", "excluded", "added"], ["portrait", "portrait"]] {
            #expect(throws: GateEvaluationProtocol.Invalid.self) {
                try record.validateInventory(names, label: "synthetic")
            }
        }
        #expect(throws: GateEvaluationProtocol.Invalid.self) {
            try record.frames[0].validateDimensions(width: 4, height: 5)
        }
        var changed = record
        changed.exclusions = [:]
        #expect(throws: GateEvaluationProtocol.Invalid.self) { try changed.validate() }
        changed = record
        changed.jnd = 3
        #expect(throws: GateEvaluationProtocol.Invalid.self) { try changed.validate() }
        changed = record
        changed.frames[0].orientations[0] = 2
        #expect(throws: GateEvaluationProtocol.Invalid.self) { try changed.validate() }
        changed = record
        changed.frames[0].face?.region.x1 = 5
        #expect(throws: GateEvaluationProtocol.Invalid.self) { try changed.validate() }
    }

    @Test func captureRoundTripPreservesProtocolAndCannotOverwriteIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("argent-gate-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let record = fixture()
        try record.write(url)
        let loaded = try GateEvaluationProtocol.read(url)
        #expect(loaded.inputs == record.inputs)
        #expect(loaded.frames[0].orientations == record.frames[0].orientations)
        #expect(loaded.frames[0].face == record.frames[0].face)
        #expect(throws: (any Error).self) { try record.write(url) }
    }

    @Test func correctionDirectionAndResidualGrayAreDifferentMetrics() {
        let errors = LabBalanceMeasureTests.correctionAndResidualErrors(
            estimate: SIMD3<Float>(0.3, -0.1, -0.2), truth: SIMD3<Float>(0.8, -0.15, -0.65))
        #expect(abs(errors.correctionDirection - errors.residualGray) > 0.01)
        let perfect = LabBalanceMeasureTests.correctionAndResidualErrors(
            estimate: SIMD3<Float>(0.8, -0.15, -0.65), truth: SIMD3<Float>(0.8, -0.15, -0.65))
        #expect(perfect.correctionDirection < 1e-5)
        #expect(perfect.residualGray < 1e-5)
    }
}
