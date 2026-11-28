import Foundation

/// A small CPU prediction of a stock print before grain, sharpening, halation and output conversion.
/// The caller supplies the patch's approximate local tone base; the renderer uses a guided field.
package struct PrintPatchResponse {
    private let stock: Stock
    private let gain: Float
    private let offset: SIMD3<Float>
    private let tone: [SIMD4<Float>]
    private let filter: MonochromeFilter
    private let grade: PaperGrade

    package init(stock: Stock, settings: DevelopSettings) throws {
        self.stock = stock
        filter = settings.monochromeFilter
        grade = settings.paperGrade
        gain = exp2(settings.exposureStops(boxSpeed: stock.boxSpeed))
        offset = settings.printOffset(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
        tone = settings.tone.isActive ? try settings.tone.table(stock: stock, settings: settings) : []
    }

    package func sample(_ rgb: SIMD3<Float>, baseStops: Float) -> (rgb: SIMD3<Float>, clamped: Bool) {
        var scene = rgb
        var adjustment = SIMD4<Float>.zero
        if !tone.isEmpty {
            let t = min(max((baseStops - PrintToneTableInfo.firstStops) / PrintToneTableInfo.stepStops, 0), Float(tone.count - 1))
            let low = min(Int(t), tone.count - 2)
            adjustment = tone[low] + (t - Float(low)) * (tone[low + 1] - tone[low])
            let y = (scene * Rec2020.luma).sum()
            let spread = (scene.max() - scene.min()) / max(y, 1e-4)
            let x = min(max((spread - 0.5) * 2, 0), 1)
            scene += adjustment.w * (1 - x * x * (3 - 2 * x)) * (SIMD3(repeating: y) - scene)
        }
        let exposed = GamutCompression.compress(scene * gain)
        let dye = stock.negativeAmounts(exposed: exposed, filter: filter)
        let amounts = stock.paperAmounts(dye + offset + SIMD3(adjustment.x, adjustment.y, adjustment.z), grade: grade)
        return (stock.print.sample(encoded: amounts.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))),
                amounts.min() < 0 || amounts.max() > 1)
    }
}
