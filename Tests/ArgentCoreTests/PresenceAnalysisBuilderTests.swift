import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Presence's analysis builds (`PresenceAnalysisBuilder`) on synthetic frames: each part against `ToneBaseField` or its CPU reference,
/// the band's working set against its budget, and Dehaze's reference against `fit_dehaze.py` on a recorded fixture.
@Suite struct PresenceAnalysisBuilderTests {
    static let constants = PresenceConstants.named(Presence.currentVersion)!

    static func builder(_ gpu: GPU) -> PresenceAnalysisBuilder { PresenceAnalysisBuilder(device: gpu.device, queue: gpu.queue) }

    /// `frame` as a decode of a `picture` the full-size picture's size, as a preview of a larger picture is.
    static func decode(of frame: LinearFrame, picture: (width: Int, height: Int)) throws -> LinearFrame {
        LinearFrame(image: frame.image, decoderVersion: "test", scale: Float(frame.width) / Float(picture.width),
                    picture: try MaskSpace(width: picture.width, height: picture.height))
    }

    /// An `rg32Float` texture's texels, row by row.
    static func texels(_ texture: MTLTexture) -> [SIMD2<Float>] {
        var values = [SIMD2<Float>](repeating: .zero, count: texture.width * texture.height)
        values.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: texture.width * 8,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return values
    }

    /// How many texels of two fields differ in any bit.
    static func differing(_ a: [SIMD2<Float>], _ b: [SIMD2<Float>]) -> Int {
        zip(a, b).filter { $0.x.bitPattern != $1.x.bitPattern || $0.y.bitPattern != $1.y.bitPattern }.count
    }

    // MARK: Texture

    /// The band built in bands of rows is the base's own unbanded field (`ToneBaseField.field`) to the bit: for a landscape and a
    /// portrait decode, a preview whose band is the decode's own size, and a decode smaller than the band's window, each at bands of one
    /// segment, of several, and of the whole field.
    @Test(arguments: [(1500, 1000, 1500, 1000), (900, 1400, 900, 1400), (1752, 1168, 7008, 4672), (40, 30, 40, 30)])
    func theBandedBandIsTheUnbandedFieldToTheBit(shape: (width: Int, height: Int, pictureWidth: Int, pictureHeight: Int)) throws {
        let gpu = try GPU()
        let builder = Self.builder(gpu)
        let (made, _) = try ToneBaseFieldTests.frame(gpu, width: shape.width, height: shape.height) {
            ToneBaseFieldTests.scene($0, $1, width: shape.width, height: shape.height)
        }
        let frame = try Self.decode(of: made, picture: (shape.pictureWidth, shape.pictureHeight))
        let field = Self.constants.texture.field(decodeLongSide: max(shape.width, shape.height),
                                                 fullLongSide: max(shape.pictureWidth, shape.pictureHeight))
        let unbanded = Self.texels(try ToneBaseField(gpu: gpu).field(for: frame, parameters: field).texture)
        for rows in [1, 200, Int.max / 2] {
            let band = try builder.texture(of: frame, constants: Self.constants, bandRows: rows)
            let build = try #require(builder.lastBuild)
            #expect(band.field == field && band.coefficients.pixelFormat == .rg32Float)
            #expect(Self.differing(Self.texels(band.coefficients), unbanded) == 0,
                    "\(shape) in \(build.bands) bands of \(build.bandRows) rows")
        }
    }

    /// At a 33 MP picture's band, 3504 by 2336, the two working textures stay under `textureWorkingSetBudget` as Metal allocated them,
    /// in more than one band, and the band itself is the kept texture's only bytes. A 3504 by 2336 decode of the 7008 by 4672 picture
    /// makes the full-size decode's band, with a quarter of its frame.
    @Test func aDevelopsBandKeepsItsWorkingTexturesUnderTheBudget() throws {
        let gpu = try GPU()
        let builder = Self.builder(gpu)
        let frame = try Self.decode(of: LinearFrame(image: PooledTexture(unpooled: try gpu.makeTexture(width: 3504, height: 2336)),
                                                    decoderVersion: "test", scale: 0.5), picture: (7008, 4672))
        let band = try builder.texture(of: frame, constants: Self.constants)
        let build = try #require(builder.lastBuild)
        #expect(band.coefficients.width == 3504 && band.coefficients.height == 2336)
        #expect(build.bands > 1 && build.workingBytes <= PresenceAnalyses.textureWorkingSetBudget, "\(build)")
        #expect(build.keptBytes == band.coefficients.allocatedSize)
        print("MEASURE Presence Texture band 3504x2336: \(build.bands) bands of \(build.bandRows) rows, working \(build.workingBytes) bytes "
              + "of \(PresenceAnalyses.textureWorkingSetBudget), kept \(build.keptBytes)")
    }

    // MARK: Clarity

    /// Clarity's two fields, made from one guide pass, are each side's field as the base makes it alone (`ToneBaseField.field`) to
    /// the bit, and match `ToneBaseField`'s CPU reference with each side's constants: on a frame the 1024 field shrinks by an uneven
    /// ratio, and on one under 1024 pixels, which is its own field.
    @Test(arguments: [(1100, 300), (700, 467)])
    func clarityFieldsAreEachSidesOwnField(size: (width: Int, height: Int)) throws {
        let gpu = try GPU()
        let builder = Self.builder(gpu)
        let (frame, pixels) = try ToneBaseFieldTests.frame(gpu, width: size.width, height: size.height) {
            ToneBaseFieldTests.scene($0, $1, width: size.width, height: size.height)
        }
        let fields = try builder.clarity(of: frame, constants: Self.constants)
        let build = try #require(builder.lastBuild)
        #expect(build.keptBytes == fields.positive.allocatedSize + fields.negative.allocatedSize && build.workingBytes == build.keptBytes,
                "the guide and one scratch beside the two fields")
        let base = try ToneBaseField(gpu: gpu)
        let luminance = pixels.map(ToneBaseField.luminance)
        for (parameters, made) in [(Self.constants.clarity.positiveField, fields.positive), (Self.constants.clarity.negativeField, fields.negative)] {
            let texels = Self.texels(made)
            #expect(Self.differing(texels, Self.texels(try base.field(for: frame, parameters: parameters).texture)) == 0, "\(parameters)")
            let reference = ToneBaseField.referenceField(luminance: luminance, width: size.width, height: size.height, parameters: parameters)
            #expect(made.width == reference.width && made.height == reference.height)
            let a = zip(texels, reference.coefficients).map { abs($0.x - $1.x) }.max() ?? 0
            let b = zip(texels, reference.coefficients).map { abs($0.y - $1.y) }.max() ?? 0
            print(String(format: "MEASURE Presence Clarity field radius %.2f, %dx%d, GPU against CPU: box(a) %.1e, box(b) %.1e stops",
                         parameters.radiusFraction, size.width, size.height, a, b))
            #expect(a < 5e-5 && b < 5e-5)
        }
    }

    // MARK: Dehaze

    /// A hazy scene: a bright sky above, dark textured ground veiled more toward the horizon, a red patch, and a light brighter than
    /// the haze, with a little noise.
    static func hazy(_ x: Int, _ y: Int, width: Int, height: Int) -> SIMD3<Float> {
        let u = Float(x) / Float(width), v = Float(y) / Float(height)
        let airlight = SIMD3<Float>(1.15, 1.2, 1.32), noise = 1 + 0.04 * (ToneBaseFieldTests.hash(x, y) - 0.5)
        if abs(u - 0.8) < 0.03 && abs(v - 0.15) < 0.04 { return SIMD3(3, 2.8, 2.5) }
        if v < 0.25 { return airlight * (0.97 + 0.06 * u) * noise }
        var ground = SIMD3<Float>(0.03 + 0.04 * u, 0.05 + 0.03 * sin(9 * u), 0.02 + 0.02 * v) * ((x / 3 + y / 2) % 2 == 0 ? 1 : 1.6)
        if u > 0.55 && u < 0.7 && v > 0.6 { ground = SIMD3(0.35, 0.04, 0.03) }
        let t = exp(-2.2 * (1 - v))
        return (ground * t + airlight * (1 - t)) * noise
    }

    /// The version's constants with Dehaze's field made at `longSide` and its radii and quantiles as given.
    static func constants(dehaze c: HazeFixture.Case.Constants) -> PresenceConstants {
        let real = Self.constants
        let dehaze = PresenceConstants.Dehaze(
            fieldLongSide: c.longSide, omega: c.omega, airlightRadius: c.airlightRadius, airlightQuantile: c.airlightQuantile,
            airlightBrightShare: c.airlightBrightShare, darkRadius: c.darkRadius,
            guide: ToneBaseParameters(radiusFraction: c.guideRadius, epsilon: c.epsilon, fieldLongSide: c.longSide, coefficientRadiusShare: 0.5),
            minimumTransmission: real.dehaze.minimumTransmission, fade: real.dehaze.fade, kappa: real.dehaze.kappa,
            hazeShare: real.dehaze.hazeShare, hazePower: real.dehaze.hazePower)
        return PresenceConstants(version: "test-haze", source: "", texture: real.texture, clarity: real.clarity, dehaze: dehaze,
                                 saturation: real.saturation, vibrance: real.vibrance, detailLimitStops: real.detailLimitStops)
    }

    /// The largest relative difference of two colours, channel by channel.
    static func apart(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let share = (a - b) / b
        return max(abs(share.x), abs(share.y), abs(share.z))
    }

    /// Dehaze's field on the GPU against `hazeReference`, step by step: the airlight, the eroded normalised dark channel and (a, b).
    /// With the version's constants on a frame the 1024 field shrinks, and with a small field the frame shrinks by an uneven ratio and
    /// radii of a few field pixels, the airlight from its brightest half.
    @Test(arguments: [(1100, 300, false), (300, 200, true)])
    func hazeFieldMatchesTheReference(shape: (width: Int, height: Int, small: Bool)) throws {
        let gpu = try GPU()
        let builder = Self.builder(gpu)
        let constants = shape.small
            ? Self.constants(dehaze: .init(longSide: 64, omega: 0.95, airlightRadius: 0.05, airlightQuantile: 0.99, airlightBrightShare: 0.5,
                                           darkRadius: 0.03, guideRadius: 0.1, epsilon: 0.5))
            : Self.constants
        let (frame, pixels) = try ToneBaseFieldTests.frame(gpu, width: shape.width, height: shape.height) {
            Self.hazy($0, $1, width: shape.width, height: shape.height)
        }
        let (estimate, dark) = try builder.hazeField(of: frame, constants: constants)
        let build = try #require(builder.lastBuild)
        let reference = PresenceAnalysisBuilder.hazeSteps(pixels: pixels, width: shape.width, height: shape.height, constants: constants.dehaze)
        let count = reference.width * reference.height
        #expect(estimate.transmission.width == reference.width && estimate.transmission.height == reference.height)
        #expect(estimate.transmission.pixelFormat == .rg32Float && build.keptBytes == estimate.transmission.allocatedSize)
        let airlight = Self.apart(SIMD3<Double>(estimate.airlight), reference.airlight)
        let gpuDark = Array(UnsafeBufferPointer(start: dark.contents().bindMemory(to: Float.self, capacity: count), count: count))
        let darkError = zip(gpuDark, reference.dark).map { abs(Double($0) - $1) }.max() ?? 0
        let texels = Self.texels(estimate.transmission)
        let a = zip(texels, reference.coefficients).map { abs(Double($0.x) - $1.x) }.max() ?? 0
        let b = zip(texels, reference.coefficients).map { abs(Double($0.y) - $1.y) }.max() ?? 0
        print(String(format: "MEASURE Presence Dehaze field %dx%d of %dx%d, GPU against CPU: airlight %.1e apart, dark %.1e, a %.1e, b %.1e",
                     reference.width, reference.height, shape.width, shape.height, airlight, darkError, a, b))
        #expect(airlight < 1e-6 && darkError < 2e-6 && a < 5e-6 && b < 5e-6)
    }

    /// `fit_dehaze.py`'s `Field`, recorded by `scripts/presence/analysis/haze_fixture.py` on three small hazy scenes.
    struct HazeFixture: Decodable {
        struct Case: Decodable {
            struct Constants: Decodable {
                let longSide: Int
                let omega: Float, airlightRadius: Float, airlightQuantile: Float, airlightBrightShare: Float
                let darkRadius: Float, guideRadius: Float, epsilon: Float
            }

            let name: String
            let width: Int
            let height: Int
            /// Half floats' bit patterns, row by row and red, green, blue.
            let pixels: [UInt16]
            let constants: Constants
            let fieldWidth: Int
            let fieldHeight: Int
            let airlight: [Double]
            let dark: [Double]
            let a: [Double]
            let b: [Double]

            var light: [SIMD3<Float>] {
                stride(from: 0, to: pixels.count, by: 3).map { i in
                    SIMD3((0..<3).map { Float(Float16(bitPattern: pixels[i + $0])) })
                }
            }
        }

        let cases: [Case]

        static let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/presence/analysis/haze-fixture.json")
    }

    /// `hazeReference`'s steps are `fit_dehaze.py`'s `Field`'s on the recorded scenes: the field's size, the airlight, the eroded
    /// normalised dark channel and the boxed coefficients. The GPU's are too, within its float sums.
    @Test func hazeReferenceIsFitDehazesField() throws {
        let fixture = try JSONDecoder().decode(HazeFixture.self, from: Data(contentsOf: HazeFixture.url))
        #expect(fixture.cases.count == 3)
        let gpu = try GPU()
        let builder = Self.builder(gpu)
        for recorded in fixture.cases {
            let constants = Self.constants(dehaze: recorded.constants), light = recorded.light
            let steps = PresenceAnalysisBuilder.hazeSteps(pixels: light, width: recorded.width, height: recorded.height,
                                                          constants: constants.dehaze)
            #expect(steps.width == recorded.fieldWidth && steps.height == recorded.fieldHeight, "\(recorded.name)")
            let airlight = Self.apart(steps.airlight, SIMD3(recorded.airlight[0], recorded.airlight[1], recorded.airlight[2]))
            let dark = zip(steps.dark, recorded.dark).map { abs($0 - $1) }.max() ?? 0
            let a = zip(steps.coefficients, recorded.a).map { abs($0.x - $1) }.max() ?? 0
            let b = zip(steps.coefficients, recorded.b).map { abs($0.y - $1) }.max() ?? 0
            print(String(format: "MEASURE Presence Dehaze reference against fit_dehaze.py, %@: airlight %.1e apart, dark %.1e, a %.1e, b %.1e",
                         recorded.name, airlight, dark, a, b))
            #expect(airlight < 5e-7 && dark < 1e-6 && a < 5e-7 && b < 5e-7, "\(recorded.name)")

            let (frame, _) = try ToneBaseFieldTests.frame(gpu, width: recorded.width, height: recorded.height) { x, y in
                light[y * recorded.width + x]
            }
            let estimate = try builder.haze(of: frame, constants: constants)
            let texels = Self.texels(estimate.transmission)
            let gpuA = zip(texels, recorded.a).map { abs(Double($0.x) - $1) }.max() ?? 0
            let gpuB = zip(texels, recorded.b).map { abs(Double($0.y) - $1) }.max() ?? 0
            let gpuAirlight = Self.apart(SIMD3<Double>(estimate.airlight), SIMD3(recorded.airlight[0], recorded.airlight[1], recorded.airlight[2]))
            #expect(gpuAirlight < 1e-6 && gpuA < 5e-6 && gpuB < 5e-6, "\(recorded.name): GPU a \(gpuA), b \(gpuB)")
        }
    }

    /// A pixel that is not finite keeps the airlight and the transmission finite, as the tone base's guide keeps its field.
    @Test(arguments: [Float.infinity, -Float.infinity, Float.nan])
    func aNonFinitePixelLeavesTheEstimateFinite(_ bad: Float) throws {
        let gpu = try GPU()
        let (frame, _) = try ToneBaseFieldTests.frame(gpu, width: 300, height: 200) { x, y in
            x == 150 && y == 30 ? SIMD3(repeating: bad) : Self.hazy(x, y, width: 300, height: 200)
        }
        let estimate = try Self.builder(gpu).haze(of: frame, constants: Self.constants)
        #expect(estimate.airlight.min() > 0 && estimate.airlight.max().isFinite)
        #expect(Self.texels(estimate.transmission).allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    /// What the builder assumes of every version's numbers: Clarity's two fields share one guide, and Dehaze's field is its guided
    /// filter's.
    @Test func everyVersionsFieldsFitTheBuilds() {
        for constants in PresenceConstants.all {
            #expect(constants.clarity.positiveField.fieldLongSide == constants.clarity.negativeField.fieldLongSide, "\(constants.version)")
            #expect(constants.dehaze.fieldLongSide == constants.dehaze.guide.fieldLongSide, "\(constants.version)")
        }
    }

    // MARK: The cache

    /// The GPU's own cache builds every part through this builder: each a real texture of its constants' size, Dehaze's airlight
    /// positive, and the bytes Metal allocated for them.
    @Test func theGPUsCacheBuildsEveryPart() throws {
        let gpu = try GPU()
        let (frame, _) = try ToneBaseFieldTests.frame(gpu, width: 1500, height: 1000) { Self.hazy($0, $1, width: 1500, height: 1000) }
        let analysis = try gpu.presenceAnalyses.analysis(of: frame, parts: [.texture, .clarity, .haze], constants: Self.constants)
        #expect(analysis.parts == [.texture, .clarity, .haze] && gpu.presenceAnalyses.statistics.builds == 3)
        let clarity = try #require(analysis.clarity), texture = try #require(analysis.texture), haze = try #require(analysis.haze)
        #expect(clarity.positive.width == 1024 && clarity.positive.height == 683 && clarity.negative.width == 1024)
        #expect(texture.coefficients.width == 750 && texture.coefficients.height == 500)
        #expect(haze.transmission.width == 1024 && haze.transmission.height == 683 && haze.airlight.min() > 0)
        #expect(gpu.presenceAnalyses.residentBytes == analysis.bytes)
    }
}
