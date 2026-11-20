import CoreGraphics
import Foundation
import simd
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// Skin as auto lab balance's second estimate (docs/M3-auto.md section 16).
@Suite struct SkinBalanceTests {
    /// Linear RGB with red against blue `redBlue` and green against magenta `greenMagenta` stops, at
    /// luminance near `level` stops against mid-gray.
    static func colour(redBlue: Float, greenMagenta: Float, level: Float = 0) -> SIMD3<Float> {
        let cast = AutoBalance.cast(redBlue: redBlue, greenMagenta: greenMagenta)
        return 0.18 * exp2(level) * SIMD3(exp2(cast.x), exp2(cast.y), exp2(cast.z))
    }

    static func frame(_ width: Int, _ height: Int, _ rgb: (Int, Int) -> SIMD3<Float>) -> [Float16] {
        var pixels = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = rgb(x, y), i = (y * width + x) * 4
                pixels[i] = Float16(v.x); pixels[i + 1] = Float16(v.y); pixels[i + 2] = Float16(v.z)
            }
        }
        return pixels
    }

    /// The skin of a face inset is metered without its dark eyes and red lips.
    @Test func metersSkinWithoutEyesAndLips() throws {
        let skin = Self.colour(redBlue: 1.1, greenMagenta: -0.02)
        // A face box over the middle of a 960 by 640 frame; rows of the buffer run from the bottom.
        let box = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
        let pixels = Self.frame(960, 640) { x, y in
            let fx = Float(x) / 960, fy = 1 - Float(y) / 640
            guard fx > 0.4, fx < 0.6, fy > 0.3, fy < 0.7 else { return Self.colour(redBlue: 0, greenMagenta: 0.4) }
            if fy > 0.42, fy < 0.46, (fx > 0.44 && fx < 0.48) || (fx > 0.52 && fx < 0.56) { return SIMD3(repeating: 0.01) }
            if fy > 0.6, fy < 0.63, fx > 0.46, fx < 0.54 { return Self.colour(redBlue: 2.0, greenMagenta: -0.6, level: -0.5) }
            return skin
        }
        let faces = FaceMeter.meter([box], pixels: pixels, width: 960, height: 640)
        let measured = try #require(faces.first?.skin)
        // Cells across an eye's or the lips' edge mix in a little of them.
        let m = AutoBalance.axes(SIMD3(log2(measured[0]), log2(measured[1]), log2(measured[2])))
        let truth = AutoBalance.axes(SIMD3(log2(skin.x), log2(skin.y), log2(skin.z)))
        #expect(abs(m.redBlue - truth.redBlue) < 0.03 && abs(m.greenMagenta - truth.greenMagenta) < 0.03, "\(m) against \(truth)")
        #expect(abs(log2(measured[1] / skin.y)) < 0.1)
        #expect(try #require(faces.first?.skinArea) < faces[0].area)
    }

    /// An inset that is not mostly alike, a face in a striped mask, gives no skin.
    @Test func noSkinFromAnInsetThatIsNotAlike() {
        let box = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
        let pixels = Self.frame(960, 640) { x, _ in (x / 8) % 3 == 0 ? Self.colour(redBlue: 1, greenMagenta: 0)
            : (x / 8) % 3 == 1 ? Self.colour(redBlue: -1, greenMagenta: 0.5) : Self.colour(redBlue: 0, greenMagenta: -0.8, level: 1.5) }
        #expect(FaceMeter.meter([box], pixels: pixels, width: 960, height: 640).first?.skin == nil)
    }

    static func analysis(light: SIMD3<Float>, skin redBlue: Float, _ greenMagenta: Float = 0, area: Float = 0.03) -> ExposureAnalysis {
        let lit = Self.colour(redBlue: redBlue, greenMagenta: greenMagenta) * SIMD3(exp2(light.x), exp2(light.y), exp2(light.z))
        let face = FaceMeasure(box: [0.4, 0.3, 0.2, 0.4], levelStops: 0, area: area, skin: [lit.x, lit.y, lit.z], skinArea: area)
        return ExposureAnalysis(meanStops: 0, validWeight: 1, grayEstimate: [light.x, light.y, light.z], faces: [face])
    }

    /// While the estimate leaves every face a colour some skin has, the skin changes nothing, so a
    /// darker or lighter person is not read as warmer or cooler light, nor is a gray statue.
    @Test func skinOfAnyToneLeavesAnAgreeingEstimate() {
        let tungsten = AutoBalance.cast(redBlue: 1.2, greenMagenta: 0.05)
        for tone: Float in [0, 0.6, 1.0, 1.4, 1.9] {
            for light in [SIMD3<Float>.zero, tungsten] {
                let a = Self.analysis(light: light, skin: tone, 0.05)
                #expect(simd_distance(AutoBalance.cast(a), AutoBalance.cast(a, skinWeight: 0)) < 1e-5)
            }
        }
    }

    /// A green field fools the gray estimate into a green light, which would print the face
    /// magenta; the face's skin, under the true daylight, pulls the estimate's green against
    /// magenta back by half of how far it would have to move to leave the face inside skin's range,
    /// and its red against blue not at all.
    @Test func skinPullsAnEstimateThatLeavesAFaceNoSkinColour() throws {
        let fooled = AutoBalance.cast(redBlue: 0.3, greenMagenta: 0.5)
        var analysis = Self.analysis(light: .zero, skin: 1.0, 0)
        analysis.grayEstimate = [fooled.x, fooled.y, fooled.z]
        let moved = AutoBalance.axes(AutoBalance.cast(analysis))
        // Under the estimate the face's green against magenta is -0.5, past skin's range.
        #expect(abs(moved.greenMagenta - (0.5 + SkinBalance.weight * (-0.5 - SkinBalance.greenMagenta.lowerBound))) < 1e-4)
        #expect(abs(moved.redBlue - 0.3) < 1e-4)
        // A face too small to count changes nothing.
        var tiny = Self.analysis(light: .zero, skin: 1.0, 0, area: 0.01)
        tiny.grayEstimate = [fooled.x, fooled.y, fooled.z]
        #expect(simd_distance(AutoBalance.cast(tiny), fooled) < 1e-5)
    }
}
