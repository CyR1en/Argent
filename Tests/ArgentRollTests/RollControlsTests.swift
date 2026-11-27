import ArgentCore
import CoreGraphics
import Foundation
import simd
import Testing
@testable import ArgentRoll

/// A stock with identity LUTs: the Negative LUT returns its log-encoded input as dye amounts.
private func identityStock(boxSpeed: Float = 400) throws -> Stock {
    Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: boxSpeed, densityRange: 2.5,
          exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 9), print: LUT3D.identity(size: 9))
}

@Suite struct RollControlsTests {
    @Test func ratedAtPositionsAndSpeeds() {
        #expect(RollControls.RatedAt.allCases == [.boxSpeed, .oneStopOver, .oneStopUnder, .twoStopsUnder])
        #expect(RollControls.RatedAt.boxSpeed.iso(boxSpeed: 400) == 400)
        #expect(RollControls.RatedAt.oneStopOver.iso(boxSpeed: 400) == 200)
        #expect(RollControls.RatedAt.oneStopUnder.iso(boxSpeed: 400) == 800)
        #expect(RollControls.RatedAt.twoStopsUnder.iso(boxSpeed: 160) == 640)
        #expect(RollControls().ratedAt == .boxSpeed && RollControls().labBalance == .auto)
    }

    @Test func boxSpeedAndNeutralLeaveTheFilmAlone() throws {
        let stock = try identityStock()
        for balance in [RollControls.LabBalance.auto, .neutral] {
            let settings = RollControls(ratedAt: .boxSpeed, labBalance: balance).settings(for: stock)
            #expect(settings == DevelopSettings())
        }
    }

    @Test func warmAndCoolAreMirrorImages() throws {
        let stock = try identityStock()
        let warm = RollControls(labBalance: .warm).settings(for: stock).labBalance
        let cool = RollControls(labBalance: .cool).settings(for: stock).labBalance
        #expect(warm.x > 0 && warm.z < 0 && warm.y == 0)
        #expect(warm == -cool)
    }

    /// The compensation's print offset cancels the extra dye a rated-at shift puts on a
    /// metered mid-gray, exactly, for the identity stock.
    @Test func ratingOffBoxSpeedPrintsMidGrayBackToItsDensity() throws {
        let stock = try identityStock()
        let encoding = stock.negative.encoding
        for position in RollControls.RatedAt.allCases where position != .boxSpeed {
            let settings = RollControls(ratedAt: position).settings(for: stock)
            #expect(settings.exposureStops(boxSpeed: stock.boxSpeed) == Float(position.stops))
            let shift = encoding.encode(encoding.midGray * exp2(Float(position.stops))) - encoding.encode(encoding.midGray)
            let offset = settings.printOffset(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
            for channel in 0..<3 {
                #expect(abs(offset[channel] + shift) < 1e-5, "\(position) channel \(channel)")
            }
        }
    }

    @Test func aFrameOverridesEachControlOnItsOwn() {
        var roll = RollControls()
        var own = FrameControls()
        own.setLabBalance(.warm, roll: roll)
        #expect(own == FrameControls(labBalance: .warm))
        #expect(own.applied(to: roll) == RollControls(ratedAt: .boxSpeed, labBalance: .warm))
        // The roll's Rated at still reaches a frame that has only its own Lab balance.
        roll.ratedAt = .oneStopUnder
        #expect(own.applied(to: roll) == RollControls(ratedAt: .oneStopUnder, labBalance: .warm))
        own.setRatedAt(.twoStopsUnder, roll: roll)
        roll.ratedAt = .boxSpeed
        #expect(own.applied(to: roll) == RollControls(ratedAt: .twoStopsUnder, labBalance: .warm))
    }

    @Test func choosingTheRollsValueFollowsTheRollAgain() {
        let roll = RollControls(ratedAt: .oneStopOver, labBalance: .neutral)
        var own = FrameControls(ratedAt: .twoStopsUnder, labBalance: .cool)
        own.setRatedAt(.oneStopOver, roll: roll)
        #expect(own.ratedAt == nil && own.labBalance == .cool)
        own.setLabBalance(nil, roll: roll)
        #expect(own.isEmpty)
        #expect(own.applied(to: roll) == roll)
    }

    @Test func anOverrideStaysWhenTheRollComesToTheSameValue() {
        var roll = RollControls()
        var own = FrameControls()
        own.setRatedAt(.oneStopUnder, roll: roll)
        roll.ratedAt = .oneStopUnder
        #expect(own.ratedAt == .oneStopUnder)
        roll.ratedAt = .boxSpeed
        #expect(own.applied(to: roll).ratedAt == .oneStopUnder)
    }

    static let bakedStock: URL? = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("build/stocks/kodak-portra-400")
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("stock.json").path) ? folder : nil
    }()

    /// Runs where scripts/build-app.sh has baked the stocks: the library shows the films' names
    /// in the spec's order, and each film's full name in the stock's descriptive line.
    @Test(.enabled(if: RollControlsTests.bakedStock != nil))
    func theBakedLibraryShowsTheFilmsNamesAndEachFilmInFullInItsLine() throws {
        let stocks = StockLibrary.load(from: try #require(Self.bakedStock).deletingLastPathComponent()).stocks
        #expect(stocks.map(\.id) == StockLibrary.order)
        #expect(stocks.map(\.displayName) == [
            "Neutral",
            "Portra 160", "Portra Natural", "Portra 400", "Portra 800",
            "Ektar 100", "Gold 200", "ColorPlus 200", "UltraMax 400",
            "Pro 400H", "C200", "Superia 400", "Tungsten 500", "Cinema 500", "Tungsten 800",
        ])
        let neutral = try #require(stocks.first { $0.id == "argent-neutral" })
        #expect(neutral.status == "digital" && neutral.afterLine == nil)
        #expect(neutral.grain == nil && neutral.halation == nil)
        let films = [
            "Kodak Portra 160", "Kodak Portra 400", "Kodak Portra 800", "Kodak Ektar 100", "Kodak Gold 200",
            "Kodak UltraMax 400", "Fujifilm Fujicolor Pro 400H", "Fujifilm Fujicolor C200", "Fujifilm Fujicolor Superia X-TRA 400",
            "Kodak VISION3 500T",
        ]
        #expect(stocks.filter { $0.status == "datasheet" && $0.modelledPrint == nil }.map(\.afterLine) == films.map {
            "After \($0): Argent's model of the film, built from its published datasheet."
        })
        #expect(stocks.filter { $0.status == "approximation" }.compactMap(\.afterLine) == ["Kodak Portra 160", "Kodak ColorPlus 200", "CineStill 800T"].map {
            "After \($0): Argent's approximation, using proxy data and not fitted to scans."
        })
        let vision = try #require(stocks.first { $0.id == "kodak-vision3-500t" }?.halation)
        let cine = try #require(stocks.first { $0.id == "cinestill-800t" }?.halation)
        #expect(cine.strength > 5 * vision.strength)
        #expect(cine.radiusMicrometres > vision.radiusMicrometres)
        #expect(cine.greenShare < vision.greenShare)
        #expect(stocks.allSatisfy { $0.negative.encoding == LogEncoding(stopsAboveMidGray: 8) })
    }

    @Test(.enabled(if: RollControlsTests.bakedStock != nil))
    func cinema500PrintsTheSameNegativeThroughItsOwnLook() throws {
        let stocks = StockLibrary.load(from: try #require(Self.bakedStock).deletingLastPathComponent()).stocks
        let tungsten = try #require(stocks.first { $0.id == "kodak-vision3-500t" })
        let cinema = try #require(stocks.first { $0.id == "kodak-vision3-500t-cinema" })
        #expect(tungsten.modelledPrint == nil)
        #expect(cinema.afterLine == "After Kodak VISION3 500T on Kodak VISION Color Print Film 2383: Argent's projection model, based on published data.")
        #expect(cinema.boxSpeed == tungsten.boxSpeed)
        #expect(cinema.halation == tungsten.halation)
        let encoded = SIMD3<Float>(repeating: tungsten.negative.encoding.encode(0.18))
        let amounts = tungsten.negative.sample(encoded: encoded)
        #expect(cinema.negative.sample(encoded: encoded) == amounts)
        let paperGray = tungsten.print.sample(encoded: amounts)
        let projectedGray = cinema.print.sample(encoded: amounts)
        #expect(abs(paperGray.y - 0.18) < 0.002)
        #expect(abs(projectedGray.y - 0.115) < 0.005)
    }

    /// Runs where scripts/build-app.sh has baked the stocks. Through Portra 400 a metered gray
    /// prints the same at every rating once the lab prints it back. One stop over prints
    /// almost as box speed does, the latitude the spec asks of Portra; two stops under lifts
    /// the blacks by about a stop, the milky shadows of a thin negative printed to normal
    /// density (measured: 0.0046 at box speed, 0.0097 two under, four stops below gray).
    @Test(.enabled(if: RollControlsTests.bakedStock != nil))
    func onPortraTheRatingChangesTheCurveNotTheGray() throws {
        let stock = try Stock.load(from: try #require(Self.bakedStock))
        let encoding = stock.negative.encoding
        func printed(_ linear: Float, _ settings: DevelopSettings) -> SIMD3<Float> {
            let exposed = linear * exp2(settings.exposureStops(boxSpeed: stock.boxSpeed))
            let dyes = stock.negative.sample(encoded: SIMD3(repeating: encoding.encode(exposed)))
            let offset = settings.printOffset(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
            return stock.print.sample(encoded: (dyes + offset).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1)))
        }
        let box = RollControls().settings(for: stock)
        for position in RollControls.RatedAt.allCases {
            let settings = RollControls(ratedAt: position).settings(for: stock)
            let gray = printed(0.18, settings), reference = printed(0.18, box)
            #expect(abs(log2(gray.y / reference.y)) < 0.02, "\(position): \(gray) against \(reference)")
            #expect(abs(gray.x - gray.z) / gray.y < 0.02, "\(position) stays neutral: \(gray)")
        }
        let over = RollControls(ratedAt: .oneStopOver).settings(for: stock)
        let under = RollControls(ratedAt: .twoStopsUnder).settings(for: stock)
        // Four stops under gray the Portras' softer print since 2026-10-08 (a tone stage from US5300381 FIG. 2,
        // docs/research/film-sim/print.md) keeps more of the extra stop's shadow density: 0.14 stops there
        // (measured), within 0.1 everywhere else.
        for stops in [-4, -2, -1, 1, 2, 3] {
            let linear = 0.18 * exp2(Float(stops))
            #expect(abs(log2(printed(linear, over).y / printed(linear, box).y)) < (stops == -4 ? 0.2 : 0.1), "one stop over at \(stops)")
        }
        let warm = printed(0.18, RollControls(labBalance: .warm).settings(for: stock))
        let cool = printed(0.18, RollControls(labBalance: .cool).settings(for: stock))
        let warmth = log2(warm.x / warm.z) - log2(cool.x / cool.z)
        print(String(format: "MEASURE Portra 400 mid-gray, Warm against Cool: %.2f stops of red against blue on the print", warmth))
        #expect(warmth > 0.1)
        let blackLift = log2(printed(0.18 / 16, under).y / printed(0.18 / 16, box).y)
        print(String(format: "MEASURE Portra 400 two stops under lifts the black four stops below gray by %.2f stops", blackLift))
        #expect(blackLift > 0.7)
    }
}

@Suite struct AutoPrintTests {
    private func stock() throws -> Stock {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeToyStock(id: "kodak-portra-400", in: directory)
        return try #require(StockLibrary.load(from: directory).stocks.first)
    }

    /// Auto's aim prints as a metered gray would, on top of the rating.
    @Test func printsTheLevelAsAGrayOnTopOfTheRating() throws {
        let stock = try stock()
        let analysis = ExposureAnalysis(meanStops: 0.7, validWeight: 1)
        let settings = RollControls(ratedAt: .oneStopOver).settings(for: stock, analysis: analysis)
        let expected = RollControls.grayCompensation(stock, exposureStops: SIMD3(repeating: 1 + AutoPrint.levelStops(analysis)))
        #expect(simd_distance(settings.labBalance, expected) < 1e-5)
        // Before it is measured a frame prints as the rating alone puts it.
        #expect(RollControls().settings(for: stock, analysis: nil) == RollControls().settings(for: stock))
    }
}

@Suite struct AutoBalanceTests {
    @Test func castsSplitIntoTwoAxesAndBack() {
        let cast = AutoBalance.cast(redBlue: 0.8, greenMagenta: -0.2)
        #expect(abs(cast.sum()) < 1e-6)
        let (redBlue, greenMagenta) = AutoBalance.axes(cast)
        #expect(abs(redBlue - 0.8) < 1e-6 && abs(greenMagenta + 0.2) < 1e-6)
        // 130 mired is 1.24 stops of red against blue through the D55 pin.
        #expect(abs(AutoBalance.mired(AutoBalance.cast(redBlue: 1.24, greenMagenta: 0)) - 130) < 0.01)
        // The estimate's level does not count, only its colour.
        let analysis = ExposureAnalysis(meanStops: 0, validWeight: 1, grayEstimate: [1.4, 1, 0.6])
        #expect(abs(AutoBalance.axes(AutoBalance.cast(analysis)).redBlue - 0.8) < 1e-6)
        #expect(AutoBalance.cast(nil) == .zero)
    }

    /// The lab takes out 0.7 of a cast, at most 60 mired of red against blue and half that of
    /// green against magenta.
    @Test func correctsSevenTenthsWithinTheBounds() {
        let small = AutoBalance.axes(AutoBalance.correction(for: AutoBalance.cast(redBlue: 0.2, greenMagenta: 0.1)))
        #expect(abs(small.redBlue - 0.14) < 1e-5 && abs(small.greenMagenta - 0.07) < 1e-5)
        // A 3200 K scene on daylight film: 130 mired, of which the lab takes out 60.
        let tungsten = AutoBalance.correction(for: AutoBalance.cast(redBlue: 1.24, greenMagenta: -1))
        #expect(abs(AutoBalance.mired(tungsten) - 60) < 0.01)
        #expect(abs(AutoBalance.axes(tungsten).greenMagenta + AutoBalance.greenMagentaLimit) < 1e-5)
    }

    /// Through Portra 400 a gray under tungsten prints with less of its cast on Auto, the
    /// same on Neutral, and Warm and Cool still step from Neutral.
    @Test(.enabled(if: RollControlsTests.bakedStock != nil))
    func autoTrimsACastOnPortraAndTheOtherPositionsIgnoreIt() throws {
        let stock = try Stock.load(from: try #require(RollControlsTests.bakedStock))
        let encoding = stock.negative.encoding
        let cast = AutoBalance.cast(redBlue: 1.24, greenMagenta: 0)
        func printed(_ settings: DevelopSettings) -> SIMD3<Float> {
            let exposed = GamutCompression.compress(SIMD3<Float>(repeating: 0.18) * SIMD3(exp2(cast.x), exp2(cast.y), exp2(cast.z)))
            let dyes = stock.negative.sample(encoded: SIMD3(encoding.encode(exposed.x), encoding.encode(exposed.y), encoding.encode(exposed.z)))
            let offset = settings.printOffset(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
            return stock.print.sample(encoded: (dyes + offset).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1)))
        }
        func warmth(_ p: SIMD3<Float>) -> Float { log2(p.x / p.z) }
        let aim = PrintAim(cast: cast)
        let auto = printed(RollControls(labBalance: .auto).settings(for: stock, aim: aim))
        let neutral = printed(RollControls(labBalance: .neutral).settings(for: stock, aim: aim))
        let untouched = printed(RollControls(labBalance: .neutral).settings(for: stock))
        print(String(format: "MEASURE Portra 400, a 3200 K gray: %.2f stops red against blue on Neutral, %.2f on Auto", warmth(neutral), warmth(auto)))
        #expect(warmth(neutral) == warmth(untouched))
        #expect(warmth(auto) < warmth(neutral) * 0.75 && warmth(auto) > 0)
        let warm = printed(RollControls(labBalance: .warm).settings(for: stock, aim: aim))
        #expect(warmth(warm) > warmth(neutral))
    }
}

/// How the analysis weighs a frame's faces: the box meter, the faces' aggregate level, and the
/// fitted aim's bounds at extreme measurements.
@Suite struct FaceWeightingTests {
    private func analysis(mean: Float, face: Float?, area: Float) -> ExposureAnalysis {
        let faces = face.map { [FaceMeasure(box: [0.4, 0.3, 0.2, 0.3], levelStops: $0, area: area)] } ?? []
        return ExposureAnalysis(meanStops: mean, validWeight: 1, faces: faces)
    }

    @Test func facesAggregateByInsetArea() throws {
        let faces = [FaceMeasure(box: [0, 0, 0.1, 0.1], levelStops: 0, area: 0.01, skinArea: 0.001),
                     FaceMeasure(box: [0.5, 0.5, 0.2, 0.2], levelStops: -2, area: 0.03, skinArea: 0.02)]
        let multiple = ExposureAnalysis(meanStops: 3, validWeight: 1, faces: faces)
        #expect(abs(try #require(multiple.faceLevelStops) + 1.5) < 1e-5)
        #expect(abs(multiple.faceArea - 0.04) < 1e-6)
    }

    @Test func extremeFiniteMeasurementsStayWithinTheExistingBounds() {
        for mean: Float in [-1e20, -20, 0, 20, 1e20] {
            for face: Float in [-1e20, -20, 0, 20, 1e20] {
                for area: Float in [0.001, 0.015, 0.04, 1] {
                    let a = analysis(mean: mean, face: face, area: area)
                    let level = AutoPrint.levelStops(a)
                    #expect(level.isFinite)
                    #expect(level >= -AutoPrint.bound && level <= AutoPrint.darkenLimit)
                }
            }
        }
    }

    @Test func metersTheMiddleOfABox() {
        let width = 100, height = 80
        var pixels = [Float16](repeating: Float16(0.18), count: width * height * 4)
        // A face box over x 40..<60, y 20..<60 whose middle is a stop over mid-gray.
        for y in 23..<57 { for x in 43..<57 { for c in 0..<3 { pixels[(y * width + x) * 4 + c] = Float16(0.36) } } }
        let faces = FaceMeter.meter([CGRect(x: 0.4, y: 0.25, width: 0.2, height: 0.5)], pixels: pixels, width: width, height: height)
        #expect(faces.count == 1)
        #expect(abs(faces[0].levelStops - 1) < 0.05)
        #expect(abs(faces[0].area - Float(14 * 35) / Float(width * height)) < 0.01)

        // Rows run from the picture's bottom: a box near the top meters the last rows.
        var top = [Float16](repeating: Float16(0.18), count: width * height * 4)
        for y in 66..<78 { for x in 43..<57 { for c in 0..<3 { top[(y * width + x) * 4 + c] = Float16(0.72) } } }
        let high = FaceMeter.meter([CGRect(x: 0.4, y: 0.025, width: 0.2, height: 0.15)], pixels: top, width: width, height: height)
        #expect(abs(high[0].levelStops - 2) < 0.05)
        #expect(high[0].box == [0.4, 0.025, 0.2, 0.15])
    }

    /// An analysis an older build wrote still decodes, stale, so its recipe opens.
    @Test func readsAnOlderAnalysis() throws {
        let old = Data(#"{"version":"2026-10-06-1","meanStops":-0.3,"validWeight":1}"#.utf8)
        let decoded = try JSONDecoder().decode(ExposureAnalysis.self, from: old)
        #expect(decoded.meanStops == -0.3 && decoded.faces.isEmpty && !decoded.isCurrent)
    }
}
