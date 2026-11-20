import CoreGraphics
import Foundation
import simd
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// Synthetic scene-linear cells; no detector, RAW, or photographic evaluation fixtures.
@Suite struct FaceExposureRegressionTests {
    /// Published ColorChecker references through the D55 pin (docs/M3-auto.md section 16).
    private func skin(luminance: Float, redBlue: Float, greenMagenta: Float) -> SIMD3<Float> {
        let axes = AutoBalance.cast(redBlue: redBlue, greenMagenta: greenMagenta)
        let rgb = SIMD3<Float>(exp2(axes.x), exp2(axes.y), exp2(axes.z))
        return rgb * (luminance / (rgb * Rec2020.luma).sum())
    }

    private var references: [SIMD3<Float>] {
        [skin(luminance: 0.346, redBlue: 1.00, greenMagenta: -0.07),
         skin(luminance: 0.100, redBlue: 1.18, greenMagenta: -0.06)]
    }

    private func grid(_ all: [SIMD3<Float>], light: [SIMD3<Float>]? = nil,
                      unclipped: [Float]? = nil, width: Int? = nil, step: Int = 1) -> ExposureAnalyzer.Grid {
        let width = width ?? all.count, height = all.count / width
        return ExposureAnalyzer.Grid(width: width, height: height, step: step,
            frameWidth: width * step, frameHeight: height * step, light: light ?? all, all: all,
            unclipped: unclipped ?? Array(repeating: 1, count: all.count),
            weight: Array(repeating: 1, count: all.count))
    }

    /// Make the metered inset cover exactly this small fixture's cells.
    private var fullInset: CGRect {
        let width = CGFloat(1 / FaceMeter.insetWidth), height = CGFloat(1 / FaceMeter.insetHeight)
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    private func meter(_ grid: ExposureAnalyzer.Grid) throws -> FaceMeasure {
        try #require(FaceMeter.meter([fullInset], grid: grid).first)
    }

    private func level(_ rgb: SIMD3<Float>) -> Float {
        log2((rgb * Rec2020.luma).sum() / 0.18)
    }

    @Test func darkInsetContaminationDoesNotLowerLightOrDarkSkinLevel() throws {
        for rgb in references {
            let clean = try meter(grid(Array(repeating: rgb, count: 10)))
            let mixed = try meter(grid(Array(repeating: rgb, count: 7) + Array(repeating: rgb / 8, count: 3)))
            #expect(abs(clean.levelStops - level(rgb)) < 1e-5)
            #expect(abs(mixed.levelStops - clean.levelStops) < 1e-5)
            #expect(simd_distance(SIMD3(try #require(mixed.skin)), rgb) < 1e-6)
            #expect(abs(try #require(mixed.skinArea) - 0.7 * mixed.area) < 1e-6)
            #expect(mixed.area == clean.area && mixed.box == clean.box)
        }
    }

    @Test func levelUsesUnclippedSkinLightAndRejectsSpecularCells() throws {
        for rgb in references {
            // Six skin cells, two bright specular cells, two cells with too little unclipped light.
            // Accepted cells' all-pixel means are brighter than their unclipped light.
            let light = Array(repeating: rgb, count: 6) + Array(repeating: rgb * 4, count: 3) + [.zero]
            let all = Array(repeating: rgb * 2, count: 6) + Array(repeating: rgb * 4, count: 4)
            let face = try meter(grid(all, light: light, unclipped: [0.75, 0.75, 0.75, 0.75, 0.75, 0.5, 1, 1, 0.49, 0]))
            #expect(abs(face.levelStops - level(rgb)) < 1e-5)
            #expect(simd_distance(SIMD3(try #require(face.skin)), rgb) < 1e-6)
            #expect(abs(try #require(face.skinArea) - 0.6 * face.area) < 1e-6)
        }
    }

    @Test func gradualShadingKeepsMeanLogLevelAndArithmeticSkinColour() throws {
        let shading: [Float] = [-0.7, -0.5, -0.3, -0.1, 0, 0.1, 0.2, 0.3, 0.4, 0.5]
        for rgb in references {
            let cells = shading.map { rgb * exp2($0) }
            let face = try meter(grid(cells))
            let meanStops = shading.reduce(0, +) / Float(shading.count)
            let meanRGB = cells.reduce(SIMD3<Float>.zero, +) / Float(cells.count)
            #expect(abs(face.levelStops - (level(rgb) + meanStops)) < 1e-5)
            #expect(abs(face.levelStops - level(meanRGB)) > 0.04)
            #expect(simd_distance(SIMD3(try #require(face.skin)), meanRGB) < 1e-6)
            #expect(face.skinArea == face.area)
        }
    }

    @Test func insufficientSkinFallsBackToAllInsetMeanLog() throws {
        let rgb = references[0]
        // Fewer than four usable cells, then four usable cells covering less than half the inset.
        for (count, kept) in [(3, 3), (5, 3), (10, 4)] {
            let all = Array(repeating: rgb, count: kept) + Array(repeating: rgb * 4, count: count - kept)
            let light = Array(repeating: rgb, count: kept) + Array(repeating: SIMD3<Float>.zero, count: count - kept)
            let fraction = Array(repeating: Float(1), count: kept) + Array(repeating: Float(0), count: count - kept)
            let face = try meter(grid(all, light: light, unclipped: fraction))
            #expect(face.skin == nil && face.skinArea == nil)
            let expected = all.map(level).reduce(0, +) / Float(count)
            #expect(abs(face.levelStops - expected) < 1e-5)
        }
    }

    @Test func exactlyHalfSkinWithFourCellsIsAccepted() throws {
        let rgb = references[1]
        let all = Array(repeating: rgb, count: 4) + Array(repeating: rgb * 4, count: 4)
        let light = Array(repeating: rgb, count: 4) + Array(repeating: SIMD3<Float>.zero, count: 4)
        let face = try meter(grid(all, light: light, unclipped: [1, 1, 1, 1, 0, 0, 0, 0]))
        #expect(abs(face.levelStops - level(rgb)) < 1e-5)
        #expect(face.skinArea == 0.5 * face.area)
        #expect(simd_distance(SIMD3(try #require(face.skin)), rgb) < 1e-6)
    }

    @Test func boxesKeepTopLeftCoordinatesAndClipTheirInsetArea() throws {
        let width = 40
        let all = (0..<(width * width)).map { index in
            SIMD3<Float>(repeating: index / width >= 30 ? 0.72 : 0.09)
        }
        let boxes = [CGRect(x: 0.25, y: 0.05, width: 0.5, height: 0.2),
                     CGRect(x: 0.25, y: 0.75, width: 0.5, height: 0.2),
                     CGRect(x: -0.15, y: 0.3, width: 0.3, height: 0.4)]
        let faces = FaceMeter.meter(boxes, grid: grid(all, width: width))
        #expect(faces.count == 3)
        #expect(abs(faces[0].levelStops - 2) < 1e-5)
        #expect(abs(faces[1].levelStops + 1) < 1e-5)
        #expect(faces[0].box == [0.25, 0.05, 0.5, 0.2])
        #expect(faces[0].area == Float(14 * 7) / Float(width * width))
        #expect(faces[1].area == faces[0].area)
        #expect(faces[2].area == Float(4 * 14) / Float(width * width))
    }

    @Test func anInsetSmallerThanACellKeepsTheMiddleCellFallback() throws {
        var all = Array(repeating: SIMD3<Float>(repeating: 0.18), count: 16)
        all[10] = SIMD3(repeating: 0.72)
        let face = try #require(FaceMeter.meter([CGRect(x: 0.44, y: 0.44, width: 0.12, height: 0.12)],
                                               grid: grid(all, width: 4, step: 4)).first)
        #expect(abs(face.levelStops - 2) < 1e-5)
        #expect(face.skin == nil && face.skinArea == nil)
        #expect(face.area == Float(4) / 256)
    }

    @Test func malformedAndOffFrameBoxesMeterNothing() {
        let boxes = [CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
                     CGRect(x: 0, y: CGFloat.infinity, width: 1, height: 1),
                     CGRect(x: 0, y: 0, width: 0, height: 1),
                     CGRect(x: 0, y: 0, width: 1, height: -1),
                     CGRect(x: 3, y: 0, width: 0.2, height: 0.2)]
        #expect(FaceMeter.meter(boxes, grid: grid(Array(repeating: references[0], count: 10))).isEmpty)
    }
}
