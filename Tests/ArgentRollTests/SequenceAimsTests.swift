import ArgentCore
import Foundation
import Testing
@testable import ArgentRoll

/// The candidates of docs/research/auto/sequence-consistency.md, section 3, on links built here:
/// `SequenceEvidence` finds none until it is built, so each test hands the solver its own.
@Suite struct SequenceAimsTests {
    typealias Link = SequenceAims.Link
    typealias Generator = RollDiagnosticsMeasureTests.SeededGenerator

    private func frame(_ index: Int, seconds: Double) -> Frame {
        // EV100 10 at f/4 and ISO 100: t = 16 / 2^10.
        Frame(id: index, url: URL(fileURLWithPath: "/roll/DSC\(index).ARW"),
              info: ARWFrameInfo(captureDate: Date(timeIntervalSince1970: 1_700_000_000 + seconds), exposureTime: 16 / 1024,
                                 fNumber: 4, iso: 100))
    }

    /// A measurement whose histogram sits all in the bin of its level, so roll smoothing's histogram
    /// split acts only between levels half a stop or more apart.
    private func analysis(_ mean: Float, gray: [Float] = [0.3, 0, -0.3], faces: [FaceMeasure] = []) -> ExposureAnalysis {
        var histogram = [Float](repeating: 0, count: ExposureAnalysis.histogramBins)
        histogram[min(max(Int((mean - ExposureAnalysis.histogramLowStops) / ExposureAnalysis.histogramBinStops), 0), 19)] = 1
        return ExposureAnalysis(meanStops: mean, validWeight: 1, histogram: histogram, asShotTemperature: 5200, grayEstimate: gray,
                                faces: faces)
    }

    /// A link whose points are `points` in the earlier frame and `2^shift` times them in the later.
    private func link(_ earlier: Int, _ later: Int, shift: Float = 0, confidence: Float = 1,
                      points: [SIMD3<Float>] = SequenceAimsTests.midtones) -> Link {
        Link(earlier: earlier, later: later, shift: shift, lightChange: nil, confidence: confidence, overlap: 0.8, correlation: 0.9,
             earlierSamples: points, laterSamples: points.map { $0 * exp2(shift) },
             weights: [Float](repeating: 1, count: points.count))
    }

    /// Light from a stop and a half under a metered gray to a stop and a half over, some of it coloured.
    static let midtones: [SIMD3<Float>] = (0..<32).map { k in
        let stops = -1.5 + 3 * Float(k) / 31
        let tint = SIMD3<Float>(1 + 0.2 * sin(Float(k)), 1, 1 - 0.2 * sin(Float(k)))
        return 0.18 * exp2(stops) * tint
    }

    private func input(_ frames: [Frame], _ analyses: [URL: ExposureAnalysis], stock: Stock,
                       frameControls: [URL: FrameControls] = [:]) -> SequenceAims.Input {
        SequenceAims.Input(frames: frames, analyses: analyses, descriptors: [:], stock: stock, controls: RollControls(),
                           frameControls: frameControls)
    }

    /// A stock whose Negative LUT returns its log-encoded input as dye amounts, printed by `print`
    /// (the identity by default, `RollControlsTests`' toy).
    private static func toyStock(print: LUT3D = .identity(size: 9)) -> Stock {
        Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
              exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: .identity(size: 9), print: print)
    }

    /// Portra 400 as scripts/build-app.sh bakes it, where it is baked.
    private static func studio400() throws -> Stock {
        try Stock.load(from: try #require(RollControlsTests.bakedStock))
    }

    private func rendered(_ link: Link, stock: Stock, casts: (SIMD3<Float>, SIMD3<Float>) = (.zero, .zero),
                          controls: RollControls = RollControls()) throws -> SequenceAims.RenderedLink {
        let points = try #require(SequenceAims.RenderedLink.points(link))
        return SequenceAims.RenderedLink(
            link: link,
            earlier: SequenceAims.Response(samples: points.earlier, weights: points.weights,
                                           print: SequenceAims.FramePrint(stock: stock, controls: controls, cast: casts.0), stock: stock),
            later: SequenceAims.Response(samples: points.later, weights: points.weights,
                                         print: SequenceAims.FramePrint(stock: stock, controls: controls, cast: casts.1), stock: stock))
    }

    // MARK: Every method

    /// A frame no usable link joins keeps its own level bit for bit under both candidates, and roll
    /// smoothing's cast: no link, a link to a frame not measured, one trusted too little, one that
    /// names a frame the roll does not have. A frame not measured has no aim.
    @Test func framesWithoutAUsableLinkKeepTheirOwnLevel() throws {
        let frames = [frame(0, seconds: 0), frame(1, seconds: 1), frame(2, seconds: 600), frame(3, seconds: 601), frame(4, seconds: 602)]
        let analyses = [frames[0].url: analysis(-1.2, gray: [0.6, 0, -0.6]), frames[1].url: analysis(-0.9, gray: [0.2, 0, -0.2]),
                        frames[2].url: analysis(1.4), frames[4].url: analysis(2.6, gray: [-0.4, 0.1, 0.3])]
        let links = [link(0, 3), link(2, 4, confidence: 0.3), link(1, 9), link(1, 1)]
        let smoothed = RollSmoothing.aims(frames, analyses: analyses)
        let stock = Self.toyStock()
        for method in [SequenceAims.Method.smoothing, .render] {
            for result in [SequenceAims.resolve(input(frames, analyses, stock: stock), links: links, method: method, parameters: .init()),
                           SequenceAims.resolve(input(frames, analyses, stock: stock), method: method)] {
                #expect(result.aims.count == 4 && result.aims[frames[3].url] == nil, "\(method)")
                for (url, analysis) in analyses {
                    let aim = try #require(result.aims[url])
                    #expect(aim.level.bitPattern == AutoPrint.levelStops(analysis).bitPattern, "\(method) \(url.lastPathComponent)")
                    #expect(aim.cast == smoothed[url]?.cast, "\(method) \(url.lastPathComponent)")
                }
                #expect(result.initial == analyses.mapValues { AutoPrint.levelStops($0) })
                #expect(result.links.isEmpty && result.residual.isEmpty, "\(method)")
            }
        }
    }

    /// Control is roll smoothing as shipped, whatever links there are.
    @Test func controlIsRollSmoothing() {
        let frames = (0..<5).map { frame($0, seconds: Double($0)) }
        let means: [Float] = [-0.4, 0, 0.3, 0.2, -2]
        let analyses = Dictionary(uniqueKeysWithValues: zip(frames.map(\.url), means.map { analysis($0) }).dropLast())
        let roll = input(frames, analyses, stock: Self.toyStock())
        let expected = RollSmoothing.aims(frames, analyses: analyses)
        for result in [SequenceAims.resolve(roll, method: .control),
                       SequenceAims.resolve(roll, links: [link(0, 1), link(1, 2, shift: 1)], method: .control, parameters: .init())] {
            #expect(result.aims == expected)
            #expect(result.initial == analyses.mapValues { AutoPrint.levelStops($0) })
            #expect(result.links.isEmpty && result.residual.isEmpty)
        }
    }

    // MARK: Candidate A

    /// Two frames linked with no change of exposure are pulled and capped as roll smoothing pulls
    /// and caps a cluster of the two, bit for bit, whether roll smoothing itself keeps them together
    /// (a second apart) or splits them (ten minutes apart).
    @Test func smoothingPullsAPairLinkedAtOneExposureAsRollSmoothingDoes() throws {
        for means: [Float] in [[-0.6, -0.2], [-1.4, 0.4], [1.5, -2.5]] {
            let together = [frame(0, seconds: 0), frame(1, seconds: 1)]
            let analyses = Dictionary(uniqueKeysWithValues: zip(together.map(\.url), means.map { analysis($0, gray: []) }))
            // One histogram bin for both, so roll smoothing clusters them.
            let flat = analyses.mapValues { a -> ExposureAnalysis in
                var a = a
                a.histogram = analysis(0).histogram
                return a
            }
            #expect(RollSmoothing.clusters(together, analyses: flat).count == 1)
            let expected = RollSmoothing.levels(together, analyses: flat)
            for frames in [together, [frame(0, seconds: 0), frame(1, seconds: 600)]] {
                let moved = Dictionary(uniqueKeysWithValues: zip(frames.map(\.url), together.map { flat[$0.url]! }))
                let result = SequenceAims.resolve(input(frames, moved, stock: Self.toyStock()), links: [link(0, 1)], method: .smoothing,
                                                  parameters: .init())
                for (frame, original) in zip(frames, together) {
                    let level = try #require(result.aims[frame.url]?.level)
                    #expect(level.bitPattern == expected[original.url]?.bitPattern, "\(means) \(frame.name)")
                }
                #expect(result.links.count == 1)
            }
        }
        // The cap holds the pair a third of a stop either side of its median.
        let held = SequenceAims.smoothedLevels([-1.0, 1.0], links: [link(0, 1)])
        #expect(held == [-RollSmoothing.maximumDeviation, RollSmoothing.maximumDeviation])
    }

    /// A linked stop more light keeps the later frame's level a stop over the earlier's, where roll
    /// smoothing would pull the two together; levels a stop apart less what placement followed are
    /// brought halfway to the stop.
    @Test func smoothingKeepsALinkedStopOfExposure() throws {
        let kept = SequenceAims.smoothedLevels([0.2, 1.2], links: [link(0, 1, shift: 1)])
        #expect(abs(try #require(kept[1]) - (try #require(kept[0])) - 1) < 1e-6)
        #expect(abs(try #require(kept[0]) - 0.2) < 1e-6)
        // The later frame is the earlier's scene given a stop more light: placement follows part of it.
        let frames = [frame(0, seconds: 0), frame(1, seconds: 1)]
        let analyses = [frames[0].url: analysis(0.2), frames[1].url: analysis(1.2)]
        let own = frames.map { AutoPrint.levelStops(analyses[$0.url]) }
        #expect(own[1] - own[0] < 0.7)
        let result = SequenceAims.resolve(input(frames, analyses, stock: Self.toyStock()), links: [link(0, 1, shift: 1)],
                                          method: .smoothing, parameters: .init())
        let levels = try frames.map { try #require(result.aims[$0.url]?.level) }
        #expect(abs((levels[1] - levels[0]) - (1 + RollSmoothing.pull * ((own[1] - own[0]) - 1))) < 1e-5)
        #expect(abs(levels[1] - levels[0] - 1) < abs(own[1] - own[0] - 1))
    }

    /// The group's exposures follow a chain of links exactly and share out a loop that disagrees
    /// by confidence (least squares, by hand: 1.15 and 2.3).
    @Test func smoothingFitsTheGroupsExposures() throws {
        #expect(SequenceAims.groups([link(0, 1), link(1, 3), link(4, 5)], count: 7) == [[0, 1, 3], [4, 5]])
        let chain = SequenceAims.exposureOffsets([0, 1, 3], links: [link(0, 1, shift: 0.5), link(1, 3, shift: -0.25)])
        #expect(zip(chain, [0, 0.5, 0.25] as [Float]).allSatisfy { abs($0 - $1) < 1e-6 })
        let loop = SequenceAims.exposureOffsets([0, 1, 2], links: [link(0, 1, shift: 1), link(1, 2, shift: 1),
                                                                    link(0, 2, shift: 2.6, confidence: 0.5)])
        #expect(zip(loop, [0, 1.15, 2.3] as [Float]).allSatisfy { abs($0 - $1) < 1e-5 }, "\(loop)")
    }

    // MARK: Candidate B

    /// Through Portra 400 the same region in two frames whose own levels are 0.3 stop apart, about
    /// 6 L*, ends within 1 L*, each frame moving about as far as the other. How far apart their moves
    /// may end is the search's own resolution: coordinate descent on a grid of `searchStep` stops
    /// ends where no one level's step lowers the cost, which along the matched-lightness valley can be
    /// anywhere |(earlier − 0.1) + (later − 0.4)| ≤ (1 + matchWeight × (L′ / lightnessScale)²) ×
    /// `searchStep`, with L′ the response's slope: on Portra 400, −20.8 L* a stop, 5.3 steps. Measured
    /// 2026-11-23: on the current bake 6.19 L* apart, solved at 0.2357 and 0.2672 (0.65 L*), 3 steps
    /// off symmetry, where each level's own step raises the cost and both together lower it; on the
    /// 2026-11-11 bake 0.2338 and 0.2662, 0 steps, the same solve stopping elsewhere in that band (5.2
    /// steps there). Held within 6 steps: a solve that favoured one frame is many times further off.
    @Test(.enabled(if: RollControlsTests.bakedStock != nil))
    func renderPrintsALinkedRegionAlike() throws {
        let stock = try Self.studio400()
        let pair = try rendered(link(0, 1), stock: stock)
        let own: [Float?] = [0.1, 0.4]
        let before = abs(pair.later.lightness(at: 0.4) - pair.earlier.lightness(at: 0.1))
        let (levels, residual) = SequenceAims.renderedLevels(own, links: [pair], parameters: .init())
        let earlier = try #require(levels[0]), later = try #require(levels[1])
        let after = abs(pair.later.lightness(at: later) - pair.earlier.lightness(at: earlier))
        print(String(format: "MEASURE Portra 400, one region at levels 0.1 and 0.4: %.2f L* apart, solved at %.4f and %.4f, %.2f L* apart",
                     before, earlier, later, after))
        #expect(before > 5)
        #expect(after < 1)
        #expect(residual == [after, after])
        #expect(earlier > 0.1 && later < 0.4 && abs((earlier - 0.1) + (later - 0.4)) < 6 * SequenceAims.searchStep)
    }

    /// A level moves no further than `maximumMove` from its own, nor past ±1.5, however strongly
    /// its link pulls.
    @Test func renderStaysWithinItsBounds() throws {
        let stock = Self.toyStock()
        var parameters = SequenceAims.Parameters()
        parameters.matchWeight = 10_000
        let apart = try SequenceAims.renderedLevels([-1.2, 1.2], links: [rendered(link(0, 1), stock: stock)], parameters: parameters).levels
        // The search's steps reach a bound to within one of them.
        let step = SequenceAims.searchStep * 1.001
        #expect(abs(try #require(apart[0]) + 1.2 - parameters.maximumMove) <= step)
        #expect(abs(try #require(apart[1]) - 1.2 + parameters.maximumMove) <= step)
        #expect(zip(apart, [-1.2, 1.2] as [Float]).allSatisfy { abs($0! - $1) <= parameters.maximumMove })
        parameters.maximumMove = 1
        // The later frame has two stops more light at the same level as the earlier, so it darkens to
        // the darken limit and the earlier lifts its whole move; mirrored, it lifts to the bound.
        for (own, shift) in [(Float(1.2), Float(2)), (-1.2, -2)] {
            let levels = try SequenceAims.renderedLevels([own, own], links: [rendered(link(0, 1, shift: shift), stock: stock)],
                                                         parameters: parameters).levels
            let earlier = try #require(levels[0]), later = try #require(levels[1])
            let limit = shift > 0 ? AutoPrint.darkenLimit : -AutoPrint.bound
            #expect(abs(later) <= 1.5 && abs(later - limit) <= step, "\(later)")
            #expect(abs(earlier - (own - (shift > 0 ? 1 : -1) * parameters.maximumMove)) <= step, "\(earlier)")
        }
    }

    /// Points so deep in shadow that every level prints them on paper black give the solver nothing
    /// to gain, so both frames keep their own levels bit for bit. The toy prints them black inside
    /// its Print LUT's domain, so they count as clipped only at the levels whose offset takes dye
    /// away, past the domain's black end.
    @Test func renderLeavesAFlatResponseAtItsOwnLevels() throws {
        // The toy's print is black below half its dye range, and a point eight stops under gray has
        // none of the negative's dye, so no level's offset (under a ninth of the range) lifts it.
        var values = LUT3D.identity(size: 9).values
        for k in values.indices { values[k] = max(0, values[k] - 0.5) * 2 }
        let stock = Self.toyStock(print: try LUT3D(size: 9, values: values))
        let shadow = (0..<16).map { SIMD3<Float>(repeating: 0.18 * exp2(-10 - Float($0) / 8)) }
        let frames = [frame(0, seconds: 0), frame(1, seconds: 1)]
        let analyses = [frames[0].url: analysis(-0.8), frames[1].url: analysis(0.9)]
        let result = SequenceAims.resolve(input(frames, analyses, stock: stock), links: [link(0, 1, points: shadow)], method: .render,
                                          parameters: .init())
        #expect(result.links.count == 1)
        for (url, analysis) in analyses {
            #expect(result.aims[url]?.level.bitPattern == AutoPrint.levelStops(analysis).bitPattern)
            #expect(result.residual[url] == 0)
        }
        let response = try rendered(link(0, 1, points: shadow), stock: stock).earlier
        #expect(Set(response.lightness) == [0])
        #expect(zip(SequenceAims.Response.levels, response.clipped).allSatisfy { $1 == ($0 > 0 ? 1 : 0) })
    }

    /// At every level of its grid a response is the weighted mean of what stage 1's CPU print path
    /// (`RollDiagnosticsMeasureTests.printedLightness`) prints each point at, with the rating, the
    /// Lab balance and the cast.
    @Test(.enabled(if: RollControlsTests.bakedStock != nil))
    func renderPrintsAsStageOneDoes() throws {
        let stock = try Self.studio400()
        var generator = Generator(state: 7)
        func uniform(_ range: ClosedRange<Float>) -> Float { Float.random(in: range, using: &generator) }
        let points = (0..<48).map { _ in 0.18 * exp2(uniform(-6...5)) * SIMD3(uniform(0.6...1.4), 1, uniform(0.6...1.4)) }
        let weights = (0..<48).map { _ in uniform(0.1...1) }
        for (controls, cast) in [(RollControls(), SIMD3<Float>(0.2, 0, -0.2)),
                                 (RollControls(ratedAt: .twoStopsUnder, labBalance: .cool), SIMD3(-0.1, 0.05, 0.05)),
                                 (RollControls(ratedAt: .oneStopOver), SIMD3(0.3, -0.1, -0.2))] {
            let response = SequenceAims.Response(samples: points, weights: weights,
                                                 print: SequenceAims.FramePrint(stock: stock, controls: controls, cast: cast), stock: stock)
            for (level, lightness) in zip(SequenceAims.Response.levels, response.lightness) {
                let settings = controls.settings(for: stock, aim: PrintAim(level: level, cast: cast))
                let expected = zip(points, weights).map { Double($1) * RollDiagnosticsMeasureTests.printedLightness($0, settings, stock: stock) }
                    .reduce(0, +) / Double(weights.reduce(0, +))
                #expect(abs(Double(lightness) - expected) < 1e-3, "\(controls) \(level)")
            }
        }
    }

    /// A link that would lift a frame's matched points onto paper white holds that frame where they
    /// stay off it, and its partner moves instead; without `clipWeight` the frame lifts the whole way.
    @Test func renderKeepsMatchedPointsOffPaperWhite() throws {
        // Through the toy a gray 4.6 stops over has dye amounts of 12.6 / 13 and each level a stop
        // under 0 adds 1 / 13 of print offset, so its Print LUT input passes 1 at levels below about
        // -0.4: the later frame's point is clear of it at its own level, the earlier's is past it.
        let pair = try rendered(link(0, 1, points: [SIMD3(repeating: 0.18), SIMD3(repeating: 0.18 * exp2(4.6))]), stock: Self.toyStock())
        var parameters = SequenceAims.Parameters()
        parameters.matchWeight = 10_000
        parameters.clipWeight = 0
        let free = SequenceAims.renderedLevels([-1.5, 0], links: [pair], parameters: parameters).levels
        parameters.clipWeight = 1000
        let guarded = SequenceAims.renderedLevels([-1.5, 0], links: [pair], parameters: parameters).levels
        let freeLater = try #require(free[1]), guardedLater = try #require(guarded[1])
        #expect(pair.earlier.clipped(at: -1.5) == 0.5 && pair.later.clipped(at: 0) == 0)
        #expect(pair.later.clipped(at: freeLater) > 0.4, "\(freeLater)")
        #expect(pair.later.clipped(at: guardedLater) < 0.05, "\(guardedLater)")
        #expect(guardedLater > freeLater + 0.1)
        #expect(abs(try #require(guarded[0]) - (-1.5 + parameters.maximumMove)) <= SequenceAims.searchStep * 1.001)
    }

    /// Only newly clipped points cost: a frame whose matched points the print already clips at its
    /// own level gains nothing by moving them off, so with nothing to match both frames stay put.
    @Test func renderCountsOnlyNewlyClippedPoints() throws {
        // The toy's gray 4.6 stops over is clipped at -0.75 and not at 0, as in
        // `renderKeepsMatchedPointsOffPaperWhite`.
        let pair = try rendered(link(0, 1, points: [SIMD3(repeating: 0.18), SIMD3(repeating: 0.18 * exp2(4.6))]), stock: Self.toyStock())
        var parameters = SequenceAims.Parameters()
        parameters.matchWeight = 0
        parameters.clipWeight = 1000
        #expect(pair.earlier.clipped(at: -0.75) == 0.5 && pair.earlier.clipped(at: 0) == 0)
        #expect(SequenceAims.renderedLevels([-0.75, 0], links: [pair], parameters: parameters).levels == [-0.75, 0])
    }

    /// Through Portra 400 a shadow seven stops under gray prints at the stock's paper black, about
    /// L* 5, at every level, so no L* threshold of 1 sees it; but its least dye, green, is under
    /// 0.006, and a level about a tenth of a stop darker than 0 takes that away and leaves the
    /// Print LUT's input below 0 (amendment 1). A link that would darken a frame whose matched
    /// shadows are clear at its own level holds it short of that, and its partner moves instead;
    /// without `clipWeight` the two meet about halfway, where the shadows are clipped.
    @Test(.enabled(if: RollControlsTests.bakedStock != nil))
    func renderKeepsMatchedShadowsOffPaperBlack() throws {
        let stock = try Self.studio400()
        let shadows = [SIMD3<Float>](repeating: SIMD3(repeating: 0.18 * exp2(-7)), count: 8)
        let alone = SequenceAims.Response(samples: shadows, weights: [Float](repeating: 1, count: 8),
                                          print: SequenceAims.FramePrint(stock: stock, controls: RollControls(), cast: .zero), stock: stock)
        #expect(alone.lightness.allSatisfy { $0 > 3 } && alone.clipped(at: 0) == 0 && alone.clipped(at: 0.25) == 1)
        let pair = try rendered(link(0, 1, points: Self.midtones + shadows), stock: stock)
        var parameters = SequenceAims.Parameters()
        parameters.matchWeight = 100
        parameters.clipWeight = 0
        let free = SequenceAims.renderedLevels([0, 0.6], links: [pair], parameters: parameters).levels
        parameters.clipWeight = 1000
        let guarded = SequenceAims.renderedLevels([0, 0.6], links: [pair], parameters: parameters).levels
        let freeEarlier = try #require(free[0]), guardedEarlier = try #require(guarded[0])
        let freeLater = try #require(free[1]), guardedLater = try #require(guarded[1])
        print(String(format: "MEASURE Portra 400, shadows 7 stops under at levels 0 and 0.6: free %.4f and %.4f (%.2f clipped), guarded %.4f and %.4f (%.2f clipped)",
                     freeEarlier, freeLater, pair.earlier.clipped(at: freeEarlier), guardedEarlier, guardedLater, pair.earlier.clipped(at: guardedEarlier)))
        #expect(pair.earlier.clipped(at: 0) == 0 && pair.later.clipped(at: 0.6) == 0.2)
        #expect(pair.earlier.clipped(at: freeEarlier) > 0.15, "\(freeEarlier)")
        #expect(pair.earlier.clipped(at: guardedEarlier) < 0.01, "\(guardedEarlier)")
        #expect(guardedEarlier < freeEarlier - 0.1 && guardedLater < freeLater - 0.1)
    }

    /// The same roll gives the same aims bit for bit whatever order its links and measurements came
    /// in, under both candidates, with a frame of its own controls and casts of their own.
    @Test func candidatesIgnoreTheOrderOfLinksAndMeasurements() throws {
        var generator = Generator(state: 20261022)
        func uniform(_ range: ClosedRange<Float>) -> Float { Float.random(in: range, using: &generator) }
        let frames = (0..<9).map { frame($0, seconds: Double($0) * 2 + ($0 >= 5 ? 1000 : 0)) }
        var analyses: [URL: ExposureAnalysis] = [:]
        for frame in frames where frame.id != 6 {
            analyses[frame.url] = analysis(uniform(-1.5...1.5), gray: [uniform(-0.3...0.3), 0, uniform(-0.3...0.3)])
        }
        var links: [Link] = []
        for e in frames.indices {
            for l in (e + 1)..<min(e + 3, frames.count) {
                let points = (0..<24).map { _ in 0.18 * exp2(uniform(-3...3)) * SIMD3(uniform(0.8...1.2), 1, uniform(0.8...1.2)) }
                links.append(link(e, l, shift: uniform(-0.6...0.6), confidence: uniform(0.3...1), points: points))
            }
        }
        let controls = [frames[3].url: FrameControls(ratedAt: .oneStopOver)]
        let stock = RollControlsTests.bakedStock == nil ? Self.toyStock() : try Self.studio400()
        var reordered: [URL: ExposureAnalysis] = [:]
        for frame in frames.reversed() { reordered[frame.url] = analyses[frame.url] }
        var shuffled = links
        shuffled.shuffle(using: &generator)
        for method in [SequenceAims.Method.smoothing, .render] {
            let first = SequenceAims.resolve(input(frames, analyses, stock: stock, frameControls: controls), links: links, method: method,
                                             parameters: .init())
            let second = SequenceAims.resolve(input(frames, reordered, stock: stock, frameControls: controls), links: shuffled, method: method,
                                              parameters: .init())
            #expect(first.aims.count == 8 && first.links.count > 4, "\(method)")
            #expect(first.aims.mapValues(\.level.bitPattern) == second.aims.mapValues(\.level.bitPattern), "\(method)")
            #expect(first.aims == second.aims && first.links == second.links && first.residual == second.residual, "\(method)")
            #expect(first.aims.contains { $0.value.level != AutoPrint.levelStops(analyses[$0.key]) }, "\(method) moves a level")
        }
    }

    // MARK: The ablation

    /// Faces Vision was not asked about, with their skin found and nothing clipped, are fully
    /// reliable: the ablation gives candidate B's aims bit for bit.
    @Test func reliabilityWithNeutralFacesIsRender() throws {
        let face = FaceMeasure(box: [0.4, 0.3, 0.1, 0.1], levelStops: -1.2, area: 0.0015, skin: [0.1, 0.08, 0.07], skinArea: 0.0012)
        let sure = FaceMeasure(box: [0.2, 0.3, 0.1, 0.1], levelStops: 0.4, area: 0.001, skin: [0.1, 0.08, 0.07], skinArea: 0.0008,
                               confidence: 0.95, clipped: 0)
        let frames = (0..<3).map { frame($0, seconds: Double($0)) }
        let analyses = [frames[0].url: analysis(0.3, faces: [face]), frames[1].url: analysis(0.8, faces: [face, sure]),
                        frames[2].url: analysis(-0.2)]
        let links = [link(0, 1, shift: 0.2), link(1, 2, shift: -0.3)]
        var ablation = SequenceAims.Parameters()
        ablation.faceReliability = true
        let roll = input(frames, analyses, stock: Self.toyStock())
        let render = SequenceAims.resolve(roll, links: links, method: .render, parameters: .init())
        let reliable = SequenceAims.resolve(roll, links: links, method: .render, parameters: ablation)
        #expect(render.aims == reliable.aims && render.initial == reliable.initial && render.residual == reliable.residual)
    }

    /// A face Vision doubts counts for nothing, one without skin for half, one partly clipped for its
    /// unclipped share, through placement's own face weight.
    @Test func reliabilityCountsADoubtfulFaceLess() {
        var ablation = SequenceAims.Parameters()
        ablation.faceReliability = true
        let face = FaceMeasure(box: [0.4, 0.3, 0.1, 0.1], levelStops: -2, area: 0.002, skin: [0.1, 0.08, 0.07], skinArea: 0.0016)
        var doubtful = face, skinless = face, clipped = face
        doubtful.confidence = 0.5
        (skinless.skin, skinless.skinArea) = (nil, nil)
        clipped.clipped = 0.3
        #expect(SequenceAims.reliability(face) == 1)
        #expect(SequenceAims.reliability(doubtful) == 0 && SequenceAims.reliability(skinless) == 0.5)
        #expect(abs(SequenceAims.reliability(clipped) - 0.7) < 1e-6)
        func own(_ faces: [FaceMeasure], _ parameters: SequenceAims.Parameters) -> Float {
            SequenceAims.ownLevel(analysis(0.5, faces: faces), parameters: parameters)
        }
        #expect(own([doubtful], ablation) == own([], .init()))
        var halved = face
        halved.area /= 2
        #expect(own([skinless], ablation) == own([halved], .init()))
        #expect(own([face], ablation) == own([face], .init()))
        #expect(own([face], .init()) < own([], .init()) - 0.2)
    }
}

/// Candidate B's cost on a large roll, against the pre-registration's budget of 40 ms a frame
/// (G7). Portra 400, 340 frames each linked to the next three with 256 points a link. Runs only
/// with ARGENT_MEASURE=1, in a release build:
///
///     ARGENT_MEASURE=1 swift test -c release -Xswiftc -enable-testing --filter SequenceAimsMeasureTests
@Suite(.serialized) struct SequenceAimsMeasureTests {
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func renderCostOnALargeRoll() throws {
        let stock = try Stock.load(from: try #require(RollControlsTests.bakedStock))
        var generator = RollDiagnosticsMeasureTests.SeededGenerator(state: 340)
        func uniform(_ range: ClosedRange<Float>) -> Float { Float.random(in: range, using: &generator) }
        let count = 340, neighbours = 3, points = 256
        let frames = (0..<count).map { k in
            Frame(id: k, url: URL(fileURLWithPath: "/roll/DSC\(k).ARW"),
                  info: ARWFrameInfo(captureDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(k) * 5), exposureTime: 1.0 / 250,
                                     fNumber: 4, iso: 100))
        }
        var analyses: [URL: ExposureAnalysis] = [:]
        for frame in frames {
            analyses[frame.url] = ExposureAnalysis(meanStops: uniform(-2...2), validWeight: 1,
                                                   grayEstimate: [uniform(-0.3...0.3), 0, uniform(-0.3...0.3)])
        }
        var links: [SequenceAims.Link] = []
        for e in 0..<count {
            for l in (e + 1)..<min(e + 1 + neighbours, count) {
                let shift = uniform(-0.7...0.7)
                let earlier = (0..<points).map { _ in 0.18 * exp2(uniform(-4...3)) * SIMD3(uniform(0.7...1.3), 1, uniform(0.7...1.3)) }
                links.append(SequenceAims.Link(earlier: e, later: l, shift: shift, lightChange: nil, confidence: uniform(0.5...1),
                                               overlap: 0.7, correlation: 0.9, earlierSamples: earlier,
                                               laterSamples: earlier.map { $0 * exp2(shift) }, weights: (0..<points).map { _ in uniform(0.5...1) }))
            }
        }
        let input = SequenceAims.Input(frames: frames, analyses: analyses, descriptors: [:], stock: stock, controls: RollControls())
        let clock = ContinuousClock()
        var totals: [Double] = [], responses: [Double] = [], solves: [Double] = []
        var peak = 0
        for _ in 0..<3 {
            let base = physicalFootprint()
            resetFootprintPeak()
            var start = clock.now
            let result = SequenceAims.resolve(input, links: links, method: .render, parameters: .init())
            totals.append(FrameViewMeasureTests.ms(clock.now - start))
            peak = max(peak, footprintPeakSinceReset() - base)
            #expect(result.aims.count == count && result.links.count == links.count)
            let smoothed = RollSmoothing.aims(frames, analyses: analyses)
            let own = frames.map { AutoPrint.levelStops(analyses[$0.url]) as Float? }
            start = clock.now
            let rendered = SequenceAims.renderedLinks(input, links: SequenceAims.usableLinks(links, own: own, parameters: .init()), aims: smoothed)
            responses.append(FrameViewMeasureTests.ms(clock.now - start))
            start = clock.now
            _ = SequenceAims.renderedLevels(own, links: rendered, parameters: .init())
            solves.append(FrameViewMeasureTests.ms(clock.now - start))
        }
        let total = totals.sorted()[1]
        print(String(format: "MEASURE candidate B on %d frames, %d links of %d points: %.0f ms (%.2f ms a frame; responses %.0f ms, solve %.0f ms), peak %.1f MB over the footprint before",
                     count, links.count, points, total, total / Double(count), responses.sorted()[1], solves.sorted()[1],
                     Double(peak) / 1_048_576))
        #expect(total / Double(count) < 40)
    }
}
