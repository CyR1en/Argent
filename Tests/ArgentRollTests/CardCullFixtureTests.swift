import ArgentCore
import ArgentRoll
import Testing

@Suite struct CardCullFixtureTests {
    @Test func aCullCanBeBuiltOutsideTheModule() {
        let frame = CullInput(path: "DCIM/100MSDCF/DSC00001.ARW", captureDate: nil, scores: nil)
        let verdict = CullVerdict(path: frame.path, reason: .failed, burst: 0)
        let cull = CardCull(frames: [frame], verdicts: [verdict])
        #expect(cull.frames.map(\.path) == [frame.path] && cull.verdicts == [verdict])
    }
}
