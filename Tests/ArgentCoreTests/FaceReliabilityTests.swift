import CoreGraphics
import Foundation
import Testing
@testable import ArgentCore

/// What a face keeps for telling a reliable one from a doubtful one: Vision's confidence and the
/// inset's clipped share. Synthetic cells; no detector or RAW.
@Suite struct FaceReliabilityTests {
    /// A frame of `width` by `height` whose light is `value(x, y)` in every channel, rows from the
    /// picture's bottom.
    private func frame(_ width: Int, _ height: Int, _ value: (Int, Int) -> Float) -> [Float16] {
        var pixels = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = Float16(value(x, y)), i = (y * width + x) * 4
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v
            }
        }
        return pixels
    }

    /// A box whose inset is the whole frame.
    private var fullInset: CGRect {
        let width = CGFloat(1 / FaceMeter.insetWidth), height = CGFloat(1 / FaceMeter.insetHeight)
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    /// Vision's confidence reaches the face through the meter; a bare box, as the tests and the
    /// Cube++ cache pass, has none, and one that is not a number is not written.
    @Test func confidenceIsCarriedThroughTheMeter() throws {
        let grid = ExposureAnalyzer.grid(pixels: frame(240, 160) { _, _ in 0.18 }, width: 240, height: 160)
        let box = CGRect(x: 0.4, y: 0.25, width: 0.2, height: 0.5)
        let found = try #require(FaceMeter.meter([FaceMeter.Detection(box: box, confidence: 0.72)], grid: grid).first)
        #expect(found.confidence == 0.72)
        let bare = try #require(FaceMeter.meter([box], grid: grid).first)
        #expect(bare.confidence == nil)
        // Otherwise the two meter alike.
        var same = found
        same.confidence = nil
        #expect(same == bare)
        let unknown = try #require(FaceMeter.meter([FaceMeter.Detection(box: box, confidence: .nan)], grid: grid).first)
        #expect(unknown.confidence == nil)
        // Boxes that meter nothing still drop out, confidence or not.
        let off = FaceMeter.Detection(box: CGRect(x: 1.4, y: 0.2, width: 0.2, height: 0.2), confidence: 0.9)
        #expect(FaceMeter.meter([off], grid: grid).isEmpty)
    }

    /// An unclipped face has none clipped, a face under a clipped sky all of it, and a face whose
    /// every cell has one clipped pixel in sixteen a sixteenth.
    @Test func clippedShareOfTheInset() throws {
        // Eight is past every raw mode's clip; the top of the picture, the texture's last rows, is
        // clipped.
        let sky = frame(960, 640) { _, y in y >= 400 ? 8 : 0.18 }
        let high = try #require(FaceMeter.meter([CGRect(x: 0.4, y: 0.05, width: 0.2, height: 0.2)],
                                                pixels: sky, width: 960, height: 640).first)
        #expect(high.clipped == 1)
        let low = try #require(FaceMeter.meter([CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.2)],
                                               pixels: sky, width: 960, height: 640).first)
        #expect(low.clipped == 0)

        let specks = frame(960, 640) { x, y in x % 4 == 0 && y % 4 == 0 ? 8 : 0.18 }
        let face = try #require(FaceMeter.meter([CGRect(x: 0.4, y: 0.25, width: 0.2, height: 0.5)],
                                                pixels: specks, width: 960, height: 640).first)
        #expect(abs(try #require(face.clipped) - 1.0 / 16) < 1e-6)
    }

    /// Cells count by their pixels: on a frame seven pixels wide in cells of four, the last
    /// column's cell holds twelve pixels to the first's sixteen.
    @Test func clippedShareCountsPixels() throws {
        let light = Array(repeating: SIMD3<Float>(repeating: 0.18), count: 2)
        let grid = ExposureAnalyzer.Grid(width: 2, height: 1, step: 4, frameWidth: 7, frameHeight: 4,
                                         light: light, all: light, unclipped: [1, 0], weight: [1, 1])
        let face = try #require(FaceMeter.meter([fullInset], grid: grid).first)
        #expect(abs(try #require(face.clipped) - 12.0 / 28) < 1e-6)
    }

    /// A face written before 2026-10-22 has neither key and still reads, inside a current analysis
    /// too; one written now keeps both, and leaves out what it does not know.
    @Test func olderFacesReadAndNewOnesRoundTrip() throws {
        let older = #"{"box":[0.4,0.3,0.2,0.3],"levelStops":-0.5,"area":0.04,"skin":[0.25,0.125,0.0625],"skinArea":0.03}"#
        let face = try JSONDecoder().decode(FaceMeasure.self, from: Data(older.utf8))
        #expect(face.confidence == nil && face.clipped == nil)
        #expect(face == FaceMeasure(box: [0.4, 0.3, 0.2, 0.3], levelStops: -0.5, area: 0.04,
                                    skin: [0.25, 0.125, 0.0625], skinArea: 0.03))
        let analysis = #"{"version":"\#(ExposureAnalysis.currentVersion)","meanStops":0.25,"faces":[\#(older)]}"#
        let read = try JSONDecoder().decode(ExposureAnalysis.self, from: Data(analysis.utf8))
        #expect(read.isCurrent && read.faces == [face])
        let rewritten = String(decoding: try JSONEncoder().encode(face), as: UTF8.self)
        #expect(!rewritten.contains("confidence") && !rewritten.contains("clipped"))

        var measured = face
        measured.confidence = 0.75
        measured.clipped = 0.125
        let data = try JSONEncoder().encode(measured)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""confidence":0.75"#) && text.contains(#""clipped":0.125"#))
        #expect(try JSONDecoder().decode(FaceMeasure.self, from: data) == measured)
        let whole = ExposureAnalysis(meanStops: 0.25, validWeight: 1, faces: [measured])
        #expect(try JSONDecoder().decode(ExposureAnalysis.self, from: JSONEncoder().encode(whole)) == whole)
    }
}
