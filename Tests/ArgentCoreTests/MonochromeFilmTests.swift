import Foundation
import Metal
import Testing
@testable import ArgentCore

@Suite struct MonochromeFilmTests {
    @Test(arguments: MonochromeFilm.allCases)
    func spectralMixKeepsNeutralsAndFiltersSuppressBlue(_ film: MonochromeFilm) {
        for filter in MonochromeFilter.allCases {
            let weights = film.weights(for: filter)
            #expect(abs(weights.sum() - 1) < 1e-6)
            #expect(weights.min() >= 0)
        }
        #expect(film.weights(for: .yellow).z < film.weights(for: .none).z)
        #expect(film.weights(for: .orange).y < film.weights(for: .yellow).y)
        #expect(film.weights(for: .red).y < film.weights(for: .orange).y)
        #expect(MonochromeFilm.triX.weights(for: .none) != MonochromeFilm.hp5.weights(for: .none))
    }

    @Test func toneRampsAreMonotonicAndTriXHasMoreMidtoneContrast() throws {
        func ramp(_ film: MonochromeFilm, _ grade: PaperGrade) throws -> [Float] {
            let stock = try #require(MonochromeFilm.stocks.first { $0.monochrome == film })
            let response = try PrintPatchResponse(stock: stock, settings: DevelopSettings(paperGrade: grade))
            return (-20...20).map { step in
                response.sample(SIMD3(repeating: 0.18 * exp2(Float(step) / 4)), baseStops: Float(step) / 4).rgb.x
            }
        }
        let triX = try ramp(.triX, .normal), hp5 = try ramp(.hp5, .normal)
        let soft = try ramp(.triX, .soft), hard = try ramp(.triX, .hard)
        for samples in [triX, hp5, soft, hard] {
            #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
        }
        #expect(triX[24] - triX[16] > hp5[24] - hp5[16])
        #expect(hard[24] - hard[16] > soft[24] - soft[16])
        #expect(abs(hard[20] - soft[20]) < 0.003)
    }

    @Test func metalRendersNeutralPixelsAndColorIgnoresSilverControls() throws {
        let gpu = try GPU()
        let texture = try gpu.makeTexture(width: 3, height: 1)
        let pixels: [Float16] = [0.04, 0.12, 0.8, 1, 0.18, 0.18, 0.18, 1, 0.6, 0.1, 0.04, 1]
        pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, 3, 1), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: 24)
        }
        let frame = LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "test", scale: 1)
        let stock = try #require(MonochromeFilm.stocks.first)
        let mono = try FilmRenderer(gpu: gpu, stock: stock)
        let color = try FilmRenderer(gpu: gpu, stock: Stock(id: "color", displayName: "Color", status: "synthetic",
                                     boxSpeed: 400, densityRange: 1, negative: .identity(), print: .identity()))
        func render(_ renderer: FilmRenderer, settings: DevelopSettings) throws -> [UInt16] {
            let output = try renderer.render(frame, settings: settings)
            return ExposureAnalyzer.pixels(of: output.image.texture).map(\.bitPattern)
        }
        let normal = try render(mono, settings: DevelopSettings())
        let filtered = try render(mono, settings: DevelopSettings(monochromeFilter: .red))
        for samples in [normal, filtered] {
            #expect(stride(from: 0, to: samples.count, by: 4).allSatisfy {
                samples[$0] == samples[$0 + 1] && samples[$0 + 1] == samples[$0 + 2]
            })
        }
        #expect(filtered[0] < normal[0])
        #expect(filtered[4] == normal[4])
        let colorOriginal = try render(color, settings: DevelopSettings())
        let colorFiltered = try render(color, settings: DevelopSettings(monochromeFilter: .red, paperGrade: .hard))
        #expect(colorOriginal == colorFiltered)
        #expect(colorOriginal[0] != colorOriginal[2])
    }
}
