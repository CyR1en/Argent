import Foundation
import Metal
import Testing

@testable import ArgentCore

@Suite(.serialized) struct DefringeTests {
    private func frame(
        _ gpu: GPU, width: Int = 256, height: Int = 128, scale: Float = 1,
        _ pixel: (Int, Int) -> SIMD3<Float>
    ) throws -> LinearFrame {
        let image = try gpu.texturePool.acquire(width: width, height: height)
        var values = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = pixel(x, y)
                let i = (y * width + x) * 4
                values[i] = Float16(v.x)
                values[i + 1] = Float16(v.y)
                values[i + 2] = Float16(v.z)
            }
        }
        values.withUnsafeBytes {
            image.texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        return LinearFrame(image: image, decoderVersion: "synthetic", scale: scale)
    }
    private func pixels(_ texture: MTLTexture) -> [Float16] {
        var v = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        v.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!, bytesPerRow: texture.width * 8,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return v
    }
    private func rgb(_ data: [Float16], _ x: Int, _ y: Int, width: Int = 256) -> SIMD3<Float> {
        let i = (y * width + x) * 4
        return SIMD3(Float(data[i]), Float(data[i + 1]), Float(data[i + 2]))
    }
    private func camera(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let m = InHouseColor.cameraToWorking
        return SIMD3((0..<3).map { row in
            (Float(m[row][0]) * v.x + Float(m[row][1]) * v.y + Float(m[row][2]) * v.z) / 0.998214
        })
    }
    private var purple: SIMD3<Float> { camera(SIMD3(0.77, 0.53, 0.77)) }
    private func luminance(_ v: SIMD3<Float>) -> Float { 0.2627 * v.x + 0.6780 * v.y + 0.0593 * v.z }
    private func length(_ v: SIMD2<Float>) -> Float { sqrt(v.x * v.x + v.y * v.y) }
    private func chroma(_ v: SIMD3<Float>) -> Float { length(SIMD2(v.x - v.y, v.z - v.y)) }
    private func correction(_ arguments: String) throws -> ResolvedLensCorrection {
        .identity.defringing(DefringeParameters(try LensSettings(arguments: arguments).defringe))
    }

    @Test func purpleStripHasAnAmountDeepHardFront() throws {
        let gpu = try GPU(), stage = try LensStage(gpu: gpu)
        let input = try frame(gpu) { x, _ in x < 80 ? .init(repeating: 0.65) : purple }
        let before = pixels(input.texture)
        for amount in [1, 2, 5, 10, 20] {
            let after = pixels(try stage.correct(input, with: correction("defringe-purple=\(amount)")).texture)
            for x in 80..<80 + amount {
                #expect(chroma(rgb(after, x, 64)) / chroma(rgb(before, x, 64)) < 0.08)
            }
            for x in 80 + amount..<256 { #expect(rgb(after, x, 64) == rgb(before, x, 64)) }
        }
    }

    @Test func purpleObjectLosesOnlyItsAmountWideRim() throws {
        let gpu = try GPU(), stage = try LensStage(gpu: gpu)
        let input = try frame(gpu) { x, y in
            (70..<150).contains(x) && (32..<96).contains(y) ? purple : .init(repeating: 0.65)
        }
        let before = pixels(input.texture)
        let after = pixels(try stage.correct(input, with: correction("defringe-purple=5")).texture)
        for y in 32..<96 {
            for x in 70..<150 {
                if min(x - 70, 149 - x, y - 32, 95 - y) < 5 {
                    #expect(chroma(rgb(after, x, y)) / chroma(rgb(before, x, y)) < 0.08)
                } else { #expect(rgb(after, x, y) == rgb(before, x, y)) }
            }
        }
    }

    @Test func noDonorCopiesAllFourChannels() throws {
        let gpu = try GPU(), stage = try LensStage(gpu: gpu)
        let input = try frame(gpu, width: 24, height: 16) { _, _ in purple }
        let after = try stage.correct(input, with: correction("defringe-purple=20"))
        #expect(pixels(after.texture).map(\.bitPattern) == pixels(input.texture).map(\.bitPattern))
    }

    @Test func luminanceStaysWithinHalfFloatRounding() throws {
        let gpu = try GPU(), stage = try LensStage(gpu: gpu)
        let input = try synthetic(gpu)
        let before = pixels(input.texture)
        let after = pixels(try stage.correct(input, with: correction("defringe-purple=3,defringe-green=5")).texture)
        var changed = 0
        for y in 0..<28 {
            for x in 0..<40 {
                let a = rgb(before, x, y, width: 40), b = rgb(after, x, y, width: 40)
                if a != b { changed += 1 }
                let steps = SIMD3<Float>((0..<3).map { c in
                    let h = Float16(b[c])
                    return max(abs(Float(h.nextUp) - b[c]), abs(b[c] - Float(h.nextDown)))
                })
                #expect(abs(luminance(a) - luminance(b)) <= 0.5 * luminance(steps) + 0.0000002)
            }
        }
        #expect(changed > 0)
    }

    @Test func nonPositiveLuminanceIsCopied() throws {
        let gpu = try GPU(), stage = try LensStage(gpu: gpu)
        let input = try frame(gpu, width: 32, height: 20) { x, _ in
            x < 8 ? .init(repeating: 0.6) : x < 16 ? .zero : .init(-0.4, 0.01, 0.8)
        }
        let before = pixels(input.texture)
        let after = pixels(try stage.correct(input, with: correction("defringe-purple=20,defringe-green=20")).texture)
        for i in stride(from: 0, to: before.count, by: 4) {
            let v = SIMD3(Float(before[i]), Float(before[i + 1]), Float(before[i + 2]))
            if luminance(v) <= 0 {
                #expect(before[i..<i + 4].map(\.bitPattern) == after[i..<i + 4].map(\.bitPattern))
            }
        }
    }

    @Test func zeroAmountsSkipThePassAndKeepRenderIdentity() throws {
        let gpu = try GPU(), stage = try LensStage(gpu: gpu)
        let input = try synthetic(gpu)
        let off = try correction("defringe-purple=0,defringe-green=0,defringe-purple-hue=0:100,defringe-green-hue=0:100")
        #expect(off == .identity && off.digest == ResolvedLensCorrection.identity.digest)
        #expect(try stage.correct(input, with: off).image === input.image)
        #expect(RenderGraph.version(for: DevelopSettings(), lens: off)
            == RenderGraph.version(for: DevelopSettings(), lens: .identity))
        #expect(!Defringe.runs(amount: 1, scale: 0.249))
        #expect(Defringe.runs(amount: 1, scale: 0.25))
    }

    private func synthetic(_ gpu: GPU) throws -> LinearFrame {
        try frame(gpu, width: 40, height: 28) { x, y in
            if y > 23 { return .init(-0.4, 0.01, 0.8) }
            let angle = Float((x * 17 + y * 13) % 360) * .pi / 180
            let a: Float = (x % 7 == 0) ? 0.005 : 0.12
            let c = cos(angle), s = sin(angle)
            return camera(SIMD3(repeating: 0.45) + a * SIMD3(c + s, -2 * c, c - s))
        }
    }

    @Test func shaderAgreesWithSectionZeroFDirectSquareReference() throws {
        let gpu = try GPU(), stage = try LensStage(gpu: gpu)
        let input = try synthetic(gpu), before = pixels(input.texture)
        for (p, g) in [(3, 0), (0, 5), (3, 5)] {
            let after = pixels(try stage.correct(input, with: correction("defringe-purple=\(p),defringe-green=\(g)")).texture)
            let expected = reference(before, width: 40, height: 28, purple: p, green: g)
            for i in after.indices {
                let step = max(abs(Float(expected[i].nextUp) - Float(expected[i])),
                               abs(Float(expected[i]) - Float(expected[i].nextDown)))
                #expect(abs(Float(after[i]) - Float(expected[i])) <= step)
            }
        }
    }

    @Test func bandsAndTheirHalosKeepEveryOutputBit() throws {
        let gpu = try GPU(), pass = try Defringe(gpu: gpu)
        let parameters = try #require(try correction("defringe-purple=3,defringe-green=5").defringe)
        let output = try gpu.texturePool.acquire(width: 40, height: 28)
        for scale: Float in [1, 0.6] {
            let input = try synthetic(gpu)
            pass.bandRows = input.height
            try pass.repair(input.texture, into: output.texture, with: parameters, scale: scale)
            let expected = pixels(output.texture).map(\.bitPattern)
            for rows in [1, 3, 9, 512] {
                pass.bandRows = rows
                try pass.repair(input.texture, into: output.texture, with: parameters, scale: scale)
                #expect(pixels(output.texture).map(\.bitPattern) == expected)
            }
        }
    }

    // Direct 2D sums keep this oracle independent of the shader's separable implementation.
    private func reference(_ source: [Float16], width: Int, height: Int, purple: Int, green: Int) -> [Float16] {
        let image = (0..<width * height).map { i -> SIMD3<Float> in
            let r = Float(source[i * 4]), g = Float(source[i * 4 + 1]), b = Float(source[i * 4 + 2])
            return SIMD3(0.2627 * r + 0.6780 * g + 0.0593 * b, r - g, b - g)
        }
        let bands = [(purple, Defringe.HueTrack.purple, Float(30), Float(70)),
                     (green, Defringe.HueTrack.green, Float(40), Float(60))]
        let weights = bands.map { _, track, low, high in image.map { p -> Float in
            var a = atan2(0.629564 * p.y - 0.533624 * p.z, 0.343440 * p.y + 0.183699 * p.z) * 180 / .pi
            if a < 0 { a += 360 }
            let t = min(max((length(SIMD2(p.y, p.z)) / (p.x + 0.004) - 0.06) / 0.04, 0), 1)
            return track.score(angle: a, low: low, high: high) * t * t * (3 - 2 * t)
        } }
        var out = source
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x, p = image[i]
                if p.x <= 0 { continue }
                let total = max(1, (purple > 0 ? weights[0][i] : 0) + (green > 0 ? weights[1][i] : 0))
                var change = SIMD2<Float>.zero
                var repaired = false
                for (band, (r, _, _, _)) in bands.enumerated() where r > 0 && weights[band][i] > 0 {
                    var mass: Float = 0, c = SIMD2<Float>.zero
                    for qy in max(0, y - r)...min(height - 1, y + r) {
                        for qx in max(0, x - r)...min(width - 1, x + r) {
                            let j = qy * width + qx, q = image[j]
                            let d = (1 - weights[band][j]) * Float((r + 1 - abs(qx - x)) * (r + 1 - abs(qy - y)))
                            mass += d
                            if q.x > 0 { c += d * SIMD2(q.y, q.z) / q.x }
                        }
                    }
                    if mass == 0 { continue }
                    let m = 1 - pow(Float(0.075), mass / Float((r + 1) * (r + 1)))
                    change += weights[band][i] / total * m * (0.8 * c / mass * p.x - SIMD2(p.y, p.z))
                    repaired = true
                }
                if !repaired { continue }
                let k = SIMD2(p.y, p.z) + change
                let g = p.x - 0.2627 * k.x - 0.0593 * k.y
                out[i * 4] = Float16(g + k.x); out[i * 4 + 1] = Float16(g); out[i * 4 + 2] = Float16(g + k.y)
            }
        }
        return out
    }
}
