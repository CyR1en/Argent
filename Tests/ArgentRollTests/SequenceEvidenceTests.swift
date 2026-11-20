import ArgentCore
import Foundation
import Testing
@testable import ArgentRoll

/// Synthetic descriptors of textured scenes; no RAW, detector or corpus.
@Suite struct SequenceEvidenceTests {
    typealias Scenes = SequenceScenes

    private static func texture(_ seed: UInt64) -> @Sendable (SIMD2<Float>) -> Float { Scenes.texture(seed) }
    private static let sky = Scenes.sky

    private func descriptor(width: Int = 64, height: Int = 43, view: (SIMD2<Float>) -> SIMD2<Float> = { $0 },
                            stops: (SIMD2<Float>) -> Float, brighter: Float = 0,
                            tint: (SIMD2<Float>) -> SIMD3<Float> = { _ in SIMD3(repeating: 1) },
                            masked: (Int, Int) -> Bool = { _, _ in false }) -> SequenceDescriptor {
        Scenes.descriptor(width: width, height: height, view: view, stops: stops, brighter: brighter, tint: tint, masked: masked)
    }

    /// Frame `index`, `seconds` into the roll, exposed for `ev` (EV100, at f/4 and ISO 100).
    private func frame(_ index: Int, seconds: Double? = nil, ev: Double? = 10, flash: Bool? = false) -> Frame {
        Frame(id: index, url: URL(fileURLWithPath: "/roll/DSC\(index).ARW"),
              info: ARWFrameInfo(captureDate: Date(timeIntervalSince1970: 1_700_000_000 + (seconds ?? Double(index))),
                                 exposureTime: ev.map { 16 / exp2($0) }, fNumber: 4, iso: 100, flashFired: flash))
    }

    private func undated(_ index: Int) -> Frame {
        Frame(id: index, url: URL(fileURLWithPath: "/roll/DSC\(index).ARW"),
              info: ARWFrameInfo(exposureTime: 16 / exp2(10), fNumber: 4, iso: 100, flashFired: false))
    }

    /// A roll of `frames` described by `descriptors`, each measured with `faces`.
    private func input(_ frames: [Frame], _ descriptors: [SequenceDescriptor?], faces: [[FaceMeasure]] = []) -> SequenceAims.Input {
        var analyses: [URL: ExposureAnalysis] = [:], described: [URL: SequenceDescriptor] = [:]
        for (index, frame) in frames.enumerated() {
            analyses[frame.url] = ExposureAnalysis(meanStops: 0, validWeight: 1, faces: index < faces.count ? faces[index] : [])
            described[frame.url] = descriptors[index]
        }
        let stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                          exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
        return SequenceAims.Input(frames: frames, analyses: analyses, descriptors: described, stock: stock, controls: RollControls())
    }

    private func links(_ frames: [Frame], _ descriptors: [SequenceDescriptor?], faces: [[FaceMeasure]] = [],
                       parameters: SequenceAims.Parameters = SequenceAims.Parameters()) -> [SequenceAims.Link] {
        SequenceEvidence.links(input(frames, descriptors, faces: faces), parameters: parameters)
    }

    private func luma(_ rgb: SIMD3<Float>) -> Float { (rgb * Rec2020.luma).sum() }

    @Test func identicalFramesLinkWithNoShiftOverAll() throws {
        let scene = descriptor(stops: Self.texture(1))
        let found = links([frame(0), frame(1)], [scene, scene])
        let link = try #require(found.first)
        #expect(found.count == 1 && link.earlier == 0 && link.later == 1)
        #expect(abs(link.shift) < 1e-4)
        #expect(link.overlap > 0.99)
        #expect(link.correlation > 0.99)
        #expect(try #require(link.lightChange) == link.shift)
        // A second apart, everything known: only the overlap and correlation margins hold it under 1.
        #expect(link.confidence > 0.9 && link.confidence <= 1)
        #expect(!link.earlierSamples.isEmpty && link.earlierSamples == link.laterSamples)
        #expect(link.weights.allSatisfy { $0 == 1 })
    }

    /// More exposure gives a brighter decode: a frame a stop brighter is a stop of shift, and no change
    /// of light when the camera gave it the stop; with the same exposure, the scene became a stop
    /// brighter, past the tolerance.
    @Test func aStopBrighterCopyIsTheCamerasStop() throws {
        let scene = Self.texture(2)
        let earlier = descriptor(stops: scene), brighter = descriptor(stops: scene, brighter: 1)
        let link = try #require(links([frame(0, ev: 10), frame(1, ev: 9)], [earlier, brighter]).first)
        #expect(abs(link.shift - 1) < 1e-3)
        #expect(abs(try #require(link.lightChange)) < 1e-3)
        #expect(zip(link.earlierSamples, link.laterSamples).allSatisfy { abs(luma($1) / luma($0) - 2) < 1e-3 })

        #expect(links([frame(0, ev: 10), frame(1, ev: 10)], [earlier, brighter]).isEmpty)
        // A third of a stop more light in the scene than the camera followed: linked, less trusted.
        let third = try #require(links([frame(0, ev: 10), frame(1, ev: 9.33)], [earlier, brighter]).first)
        #expect(abs(try #require(third.lightChange) - 0.33) < 0.01)
        #expect(third.confidence < link.confidence)
    }

    /// A translated view and a 1.5× zoom into the scene, each with half a stop more light the camera
    /// gave it, link with that shift.
    @Test func translatedAndZoomedCropsLink() throws {
        let scene = Self.texture(3)
        let earlier = descriptor(stops: scene)
        let moved = descriptor(view: { $0 + SIMD2(9.3, -5.6) }, stops: scene, brighter: 0.5)
        let translated = try #require(links([frame(0), frame(1, ev: 9.5)], [earlier, moved]).first)
        #expect(abs(translated.shift - 0.5) < 0.03)
        #expect(abs(translated.overlap - (64 - 9.3) * (43 - 5.6) / (64 * 43)) < 0.05)

        let zoomed = descriptor(view: { $0 / 1.5 + SIMD2(14, 6) }, stops: scene, brighter: 0.5)
        let zoom = try #require(links([frame(0), frame(1, ev: 9.5)], [earlier, zoomed]).first)
        #expect(abs(zoom.shift - 0.5) < 0.03)
        // The zoomed frame lies wholly inside the other.
        #expect(zoom.overlap > 0.95)
        // And the other way round, the wider view later.
        let wider = try #require(links([frame(0), frame(1, ev: 10.5)], [zoomed, earlier]).first)
        #expect(abs(wider.shift + 0.5) < 0.03)
    }

    /// A portrait frame of the same scene turned a quarter, as a frame whose orientation was not
    /// recorded shows it, links.
    @Test func aQuarterTurnedCopyLinks() throws {
        let scene = Self.texture(4)
        let earlier = descriptor(stops: scene)
        // The portrait frame's point (x, y) shows the landscape frame's (y, 43 − x): turned a quarter clockwise.
        let turned = descriptor(width: 43, height: 64, view: { SIMD2($0.y, 43 - $0.x) }, stops: scene)
        let link = try #require(links([frame(0), frame(1)], [earlier, turned]).first)
        #expect(abs(link.shift) < 0.03)
        #expect(link.overlap > 0.95)
    }

    @Test func unrelatedScenesDoNotLink() {
        for (index, (a, b)) in Scenes.unrelated(16).enumerated() {
            #expect(links([frame(0), frame(1)], [a, b]).isEmpty, "pair \(index)")
        }
    }

    /// Cells whose light agrees while the texture inside them does not are not one subject: the frames'
    /// detail must line up too.
    @Test func theTextureInsideTheCellsMustAgree() {
        let scene = descriptor(stops: Self.texture(12))
        var other = scene
        other.detail = descriptor(stops: Self.texture(13)).detail
        #expect(links([frame(0), frame(1)], [scene, other]).isEmpty)
        #expect(links([frame(0), frame(1)], [scene, scene]).count == 1)
    }

    /// Two frames of one sky agree everywhere and carry no detail: nothing shows they share a subject.
    @Test func aFlatPairDoesNotLink() {
        let sky = descriptor(stops: Self.sky)
        #expect(links([frame(0), frame(1)], [sky, sky]).isEmpty)
        // A sky over a little texture in one corner is still mostly flat.
        let scene = Self.texture(5)
        let corner = descriptor(stops: { $0.x < 12 && $0.y < 10 ? scene($0) : Self.sky($0) })
        #expect(links([frame(0), frame(1)], [corner, corner]).isEmpty)
    }

    @Test func aFlashChangeOrAGapIsABoundary() throws {
        let scene = descriptor(stops: Self.texture(6))
        #expect(links([frame(0, flash: false), frame(1, flash: true)], [scene, scene]).isEmpty)
        #expect(links([frame(0, seconds: 0), frame(1, seconds: 601)], [scene, scene]).isEmpty)
        #expect(links([undated(0), frame(1)], [scene, scene]).isEmpty)
        // Neighbours further than the reach are not compared.
        var parameters = SequenceAims.Parameters()
        parameters.neighbours = 1
        let reach = links([frame(0), frame(1), frame(2)], [scene, nil, scene], parameters: parameters)
        #expect(reach.isEmpty)
        // A flash known in one frame only halves the confidence.
        let known = try #require(links([frame(0), frame(1)], [scene, scene]).first)
        let unknown = try #require(links([frame(0), frame(1, flash: nil)], [scene, scene]).first)
        #expect(abs(unknown.confidence - known.confidence / 2) < 1e-6)
        // Further apart, less trusted.
        let later = try #require(links([frame(0, seconds: 0), frame(1, seconds: 400)], [scene, scene]).first)
        #expect(later.confidence < known.confidence)
    }

    @Test func anUnknownExposureHalvesConfidence() throws {
        let scene = descriptor(stops: Self.texture(7))
        let known = try #require(links([frame(0), frame(1)], [scene, scene]).first)
        let unknown = try #require(links([frame(0), frame(1, ev: nil)], [scene, scene]).first)
        #expect(unknown.lightChange == nil && known.lightChange != nil)
        #expect(abs(unknown.confidence - known.confidence / 2) < 1e-6)
        // Unknown, a scene a stop brighter is not a boundary.
        let brighter = descriptor(stops: Self.texture(7), brighter: 1)
        #expect(!links([frame(0, ev: nil), frame(1)], [scene, brighter]).isEmpty)
    }

    /// Masked cells, all zero, are no light: two different scenes masked in the same place do not
    /// link, and a mask in one frame alone moves neither the shift nor any matched point.
    @Test func maskedCellsAreIgnored() throws {
        let cube = { (u: Int, v: Int) in u >= 44 && v < 18 }
        let a = descriptor(stops: Self.texture(30), masked: cube), b = descriptor(stops: Self.texture(31), masked: cube)
        #expect(links([frame(0), frame(1)], [a, b]).isEmpty)

        let scene = Self.texture(32)
        let whole = descriptor(stops: scene), masked = descriptor(stops: scene, brighter: 0.25, masked: cube)
        let link = try #require(links([frame(0), frame(1, ev: 9.75)], [whole, masked]).first)
        #expect(abs(link.shift - 0.25) < 1e-3)
        #expect(link.laterSamples.allSatisfy { $0.min() > 0 })
        #expect(zip(link.earlierSamples, link.laterSamples).allSatisfy { abs(luma($1) / luma($0) - exp2(0.25)) < 1e-3 })
    }

    @Test func samplesAreBoundedAndDeterministic() throws {
        let scene = Self.texture(8)
        let earlier = descriptor(stops: scene), later = descriptor(view: { $0 + SIMD2(3.4, 2.2) }, stops: scene)
        var parameters = SequenceAims.Parameters()
        parameters.maximumSamples = 50
        let first = try #require(links([frame(0), frame(1)], [earlier, later], parameters: parameters).first)
        #expect(first.earlierSamples.count == 50 && first.laterSamples.count == 50 && first.weights.count == 50)
        #expect(links([frame(0), frame(1)], [earlier, later], parameters: parameters) == [first])
        // Spread over the shared region: from its darkest light to its brightest.
        let lumas = first.earlierSamples.map(luma).sorted()
        #expect(log2(lumas.last! / lumas.first!) > 2)
        parameters.maximumSamples = 0
        let none = try #require(links([frame(0), frame(1)], [earlier, later], parameters: parameters).first)
        #expect(none.earlierSamples.isEmpty && none.weights.isEmpty)
    }

    @Test func framesWithoutADescriptorOrAnalysisHaveNoLinks() {
        let scene = descriptor(stops: Self.texture(9))
        let frames = [frame(0), frame(1), frame(2)]
        let found = links(frames, [scene, nil, scene])
        #expect(found.count == 1 && found[0].earlier == 0 && found[0].later == 2)
        var unmeasured = input(frames, [scene, scene, scene])
        unmeasured.analyses[frames[1].url] = nil
        #expect(SequenceEvidence.links(unmeasured, parameters: SequenceAims.Parameters()).map { [$0.earlier, $0.later] } == [[0, 2]])
        var empty = scene
        empty.rgb = []
        #expect(links(frames, [scene, empty, scene]).map { [$0.earlier, $0.later] } == [[0, 2]])
    }

    /// A face that lands on the other frame's face adds its inset's cells at twice its confidence; one
    /// that lands on no face, a different person, adds nothing, and its cells give no point at all.
    @Test func onlyFacesThatMapOntoEachOtherPair() throws {
        let scene = Self.texture(11)
        // The face: warm light in the box over cells 26…32 across and 24…30 up, x 0.40625 and y 13/43 from
        // the top left.
        let warm = { (p: SIMD2<Float>) -> SIMD3<Float> in
            p.x >= 26 && p.x < 32 && p.y >= 24 && p.y < 30 ? SIMD3(1.6, 0.85, 0.6) : SIMD3(repeating: 1)
        }
        let earlier = descriptor(stops: scene, tint: warm)
        let later = descriptor(view: { $0 + SIMD2(4, 2) }, stops: scene, tint: warm)
        let box: [Float] = [26.0 / 64, 13.0 / 43, 6.0 / 64, 6.0 / 43]
        let face = FaceMeasure(box: box, levelStops: 0, area: 0.01, confidence: 0.8)
        // In the later frame the scene moved 4 cells left and 2 down: its face box moved with it.
        let moved = FaceMeasure(box: [box[0] - 4.0 / 64, box[1] + 2.0 / 43, box[2], box[3]], levelStops: 0, area: 0.01, confidence: 0.9)
        let paired = try #require(links([frame(0), frame(1)], [earlier, later], faces: [[face], [moved]]).first)
        let faceWeights = paired.weights.filter { $0 != 1 }
        #expect(!faceWeights.isEmpty && faceWeights.allSatisfy { abs($0 - 1.6) < 1e-6 })
        #expect(zip(paired.earlierSamples, paired.weights).filter { $1 != 1 }.allSatisfy { $0.0.x > $0.0.z * 2 })

        // The later face elsewhere: two people, no face points and none of the earlier face's light.
        let elsewhere = FaceMeasure(box: [0.1, 0.6, 0.1, 0.15], levelStops: 0, area: 0.01, confidence: 0.9)
        let strangers = try #require(links([frame(0), frame(1)], [earlier, later], faces: [[face], [elsewhere]]).first)
        #expect(strangers.weights.allSatisfy { $0 == 1 })
        #expect(strangers.earlierSamples.allSatisfy { $0.x < $0.z * 1.5 })
        // The faces' levels moved two stops against the region's: not the same face in the same light.
        let darker = FaceMeasure(box: moved.box, levelStops: -2, area: 0.01, confidence: 0.9)
        let unlike = try #require(links([frame(0), frame(1)], [earlier, later], faces: [[face], [darker]]).first)
        #expect(unlike.weights.allSatisfy { $0 == 1 })
    }

    /// A face whose box, as a recipe may hold it, lies further off the frame than an Int reaches still
    /// pairs with itself and leaves the link as it is, its point the cell nearest its inset's middle.
    @Test func aFaceFarOffTheFrameStillLinks() throws {
        let scene = descriptor(stops: Self.texture(14))
        let far = FaceMeasure(box: [2e17, 0.3, 2e17, 0.3], levelStops: 0, area: 0.01, confidence: 0.9)
        let plain = try #require(links([frame(0), frame(1)], [scene, scene]).first)
        let link = try #require(links([frame(0), frame(1)], [scene, scene], faces: [[far], [far]]).first)
        #expect(link.shift == plain.shift && link.confidence == plain.confidence)
        #expect(link.weights.filter { $0 != 1 }.count == 1)
    }
}
