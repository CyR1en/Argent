import Foundation
import Testing
@testable import ArgentCore
@testable import ArgentRoll

@Suite struct AutoDetailTests {
    static func compressedStock() throws -> Stock {
        let size = 17
        var identity = LUT3D.identity(size: size)
        identity.values = identity.values.map { 0.04 + 0.92 * min(max(($0 - 0.375) / 0.5, 0), 1) }
        return Stock(id: "compressed", displayName: "Compressed", status: "synthetic", boxSpeed: 400,
                     densityRange: 1.5, exposurePerUnit: SIMD3(repeating: 0.35),
                     negative: LUT3D.identity(size: 2), print: identity)
    }

    static func descriptor(low: Float, high: Float, flat: Bool = false, clipped: Bool = false,
                           midRows: Int = 0, noise: DecodedNoise? = nil) -> SequenceDescriptor {
        let side = 128
        var rgb: [SIMD3<Float>] = []
        for y in 0..<side {
            for x in 0..<side {
                let stops: Float
                if y < midRows {
                    stops = Float(x % 5 - 2) * 0.25
                } else {
                    stops = (x / 2) % 2 == 0 ? low : high
                }
                let ripple: Float = flat || y < midRows ? 0 : (x % 2 == 0 ? -0.08 : 0.08)
                rgb.append(SIMD3(repeating: 0.18 * exp2(stops + ripple)))
            }
        }
        return SequenceDescriptor(grid: ExposureAnalyzer.Grid(width: side, height: side, step: 1,
            frameWidth: side, frameHeight: side, light: rgb, all: rgb,
            unclipped: Array(repeating: clipped ? 0 : 1, count: rgb.count),
            weight: Array(repeating: 1, count: rgb.count)), noise: noise)
    }

    static let analysis = ExposureAnalysis(meanStops: 0, validWeight: 1, grayEstimate: [0, 0, 0])

    @Test func protectsTextureButLeavesMidtonesSmoothAndClippedInputAlone() throws {
        let stock = try Self.compressedStock()
        let prior = PrintAim()
        func protect(_ descriptor: SequenceDescriptor) -> PrintAim {
            AutoDetail.protect(prior, descriptor: descriptor, analysis: Self.analysis, stock: stock, controls: RollControls(), iso: 100)
        }
        let highlights = protect(Self.descriptor(low: 3.5, high: 4, midRows: 32))
        let shadows = protect(Self.descriptor(low: -3.7, high: -3.3))
        #expect(highlights.burn > prior.burn && highlights.level == prior.level && highlights.dodge == prior.dodge)
        #expect(shadows.dodge > prior.dodge && shadows.level == prior.level && shadows.burn == prior.burn)
        #expect(protect(Self.descriptor(low: -0.3, high: 0.3)) == prior)
        #expect(protect(Self.descriptor(low: 3.5, high: 4, flat: true)) == prior)
        #expect(protect(Self.descriptor(low: 3.5, high: 4, clipped: true)) == prior)
        #expect(protect(Self.descriptor(low: -3.7, high: -3.3,
            noise: DecodedNoise(read: SIMD3(repeating: 0.01), shot: .zero))) == prior)
    }

    @Test func protectsShadowsWithRealMidtonesOnBakedStocksAndGuardsFaces() throws {
        let stocksRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/stocks")
        let superiaURL = stocksRoot.appendingPathComponent("fujifilm-superia-400")
        let portraURL = stocksRoot.appendingPathComponent("kodak-portra-400")
        guard FileManager.default.fileExists(atPath: superiaURL.appendingPathComponent("stock.json").path),
              FileManager.default.fileExists(atPath: portraURL.appendingPathComponent("stock.json").path) else { return }
        let superia = try Stock.load(from: superiaURL)
        let portra = try Stock.load(from: portraURL)
        let prior = PrintAim(level: 0, cast: .zero, burn: 0.6, dodge: 0.15)
        let spatial = Self.descriptor(low: -3.3, high: -2.8, midRows: 48)
        let guarded = AutoDetail.protect(prior, descriptor: spatial, analysis: Self.analysis,
                                         stock: superia, controls: RollControls(), iso: 100)
        #expect(guarded.dodge > prior.dodge && guarded.level == prior.level && guarded.burn == prior.burn)
        let open = AutoDetail.protect(prior, descriptor: spatial, analysis: Self.analysis,
                                      stock: portra, controls: RollControls(), iso: 100)
        #expect(open.dodge <= guarded.dodge)

        var withDarkFace = Self.analysis
        let faceLight: Float = 0.18 * exp2(-0.8)
        withDarkFace.faces = [FaceMeasure(
            box: [0.2, 0.2, 0.2, 0.2], levelStops: -0.8, area: 0.04,
            skin: [faceLight, faceLight, faceLight], skinArea: 0.05, confidence: 0.95, clipped: 0)]
        let faceGuarded = AutoDetail.protect(prior, descriptor: spatial, analysis: withDarkFace,
                                             stock: superia, controls: RollControls(), iso: 100)
        #expect(faceGuarded == prior)
    }

    @Test func theSameHighlightNeedsDifferentAimsOnDifferentStocks() throws {
        let compressed = try Self.compressedStock()
        let open = Stock(id: "open", displayName: "Open", status: "synthetic", boxSpeed: 400,
                         densityRange: compressed.densityRange, exposurePerUnit: compressed.exposurePerUnit,
                         negative: compressed.negative, print: LUT3D.identity(size: 2))
        let url = URL(fileURLWithPath: "/detail/frame.ARW")
        let frame = Frame(id: 0, url: url, info: ARWFrameInfo(iso: 100))
        let spatial = Self.descriptor(low: 3.5, high: 4)
        var analysis = Self.analysis
        analysis.histogram = Array(repeating: 0, count: ExposureAnalysis.histogramBins)
        analysis.histogram[10] = 1
        var input = SequenceAims.Input(frames: [frame], analyses: [url: analysis], descriptors: [url: spatial],
                                       stock: open, controls: RollControls())
        let prior = try #require(SequenceAims.resolve(input, method: .control).aims[url])
        #expect(SequenceAims.resolve(input, method: .detail).aims[url] == prior)
        input.frameStocks[url] = compressed
        let guarded = try #require(SequenceAims.resolve(input, method: .detail).aims[url])
        #expect(guarded.burn > prior.burn && guarded.burn <= FittedTone.burnLimit)
    }
}
