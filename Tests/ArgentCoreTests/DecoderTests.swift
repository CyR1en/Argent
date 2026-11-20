import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Metal
import Testing
@testable import ArgentCore

@Suite struct ExposureAnchorTests {
    @Test func movesTheBaselineZeroMidToneToTheFilmMidGray() {
        let stops = ExposureAnchor.gainStops()
        let decoded = ExposureAnchor.decodedMidTone * exp2(stops)
        #expect(abs(decoded - ExposureAnchor.filmMidGray) < 1e-6)
        #expect(abs(stops - log2(Float(2.25))) < 1e-5)
    }

    @Test func subtractsApplesDefaultBaselineWhenItIsLeftOn() {
        let stops = ExposureAnchor.gainStops(baselineExposure: 0.3)
        let lifted = ExposureAnchor.decodedMidTone * exp2(Float(0.3))
        #expect(abs(lifted * exp2(stops) - ExposureAnchor.filmMidGray) < 1e-5)
        #expect(abs(stops - 0.87) < 0.01)
    }

    @Test func leavesISO100AndAboveAlone() {
        let reference = ExposureAnchor.gainStops()
        for iso: Float in [100, 250, 640, 3200, 51200] {
            #expect(ExposureAnchor.gainStops(iso: iso) == reference, "ISO \(iso)")
        }
    }

    @Test func keepsISO100GainBelowISO100() {
        let reference = ExposureAnchor.gainStops()
        #expect(abs(ExposureAnchor.gainStops(iso: 50) - (reference - 1)) < 1e-5)
        let sixtyFour = reference - log2(Float(100) / 64)
        #expect(abs(ExposureAnchor.gainStops(iso: 64) - sixtyFour) < 1e-5)
    }

    @Test func ignoresAnISOItCannotUse() {
        let reference = ExposureAnchor.gainStops()
        #expect(ExposureAnchor.gainStops(iso: 0) == reference)
        #expect(ExposureAnchor.gainStops(iso: -50) == reference)
        #expect(ExposureAnchor.gainStops(iso: nil) == reference)
    }
}

@Suite struct NoiseReductionTests {
    @Test func luminanceTiersFollowTheISO() {
        for iso: Float in [50, 100, 400, 1599] {
            #expect(NoiseReduction.luminanceAmount(iso: iso) == 0.4, "ISO \(iso)")
        }
        for iso: Float in [1600, 3200, 6400] {
            #expect(NoiseReduction.luminanceAmount(iso: iso) == 0.6, "ISO \(iso)")
        }
        for iso: Float in [6401, 12800, 102400, 204800] {
            #expect(NoiseReduction.luminanceAmount(iso: iso) == 0.9, "ISO \(iso)")
        }
    }

    @Test func anUnknownISOGetsTheLowTier() {
        #expect(NoiseReduction.luminanceAmount(iso: nil) == 0.4)
        #expect(NoiseReduction.luminanceAmount(iso: 0) == 0.4)
        #expect(NoiseReduction.luminanceAmount(iso: -1) == 0.4)
    }

    /// RAW 9's amounts are its table's at the knots, run linearly in stops between them, flat beyond
    /// the ends, never fall as the ISO rises, and give a frame with no usable ISO the least.
    @Test func raw9AmountsFollowItsTable() {
        let table = NoiseReduction.learnedLuminanceTable
        for knot in table { #expect(NoiseReduction.learnedLuminanceAmount(iso: knot.iso) == knot.amount, "ISO \(knot.iso)") }
        for iso: Float in [50, 100, 250, 400, 640] { #expect(NoiseReduction.learnedLuminanceAmount(iso: iso) == table.first!.amount) }
        for iso: Float in [32000, 51200, 102400, 204800] { #expect(NoiseReduction.learnedLuminanceAmount(iso: iso) == table.last!.amount) }
        // Halfway in stops between ISO 1600 and 2000.
        let between = NoiseReduction.learnedLuminanceAmount(iso: 1600 * Float(1.25).squareRoot())
        let low = table.first { $0.iso == 1600 }!.amount, high = table.first { $0.iso == 2000 }!.amount
        #expect(abs(between - (low + high) / 2) < 1e-5)
        // Apple's defaults at a few third stops, which the table pins (docs/decoder.md section 18).
        for (iso, amount): (Float, Float) in [(800, 0.012408), (3200, 0.175559), (6400, 0.297300), (12800, 0.400002)] {
            #expect(abs(NoiseReduction.learnedLuminanceAmount(iso: iso) - amount) < 1e-6, "ISO \(iso)")
        }
        var previous: Float = 0
        var iso: Float = 50
        while iso <= 204800 {
            let amount = NoiseReduction.learnedLuminanceAmount(iso: iso)
            #expect(amount >= previous && amount >= 0 && amount <= 1, "ISO \(iso)")
            previous = amount
            iso *= 1.05
        }
        for iso: Float? in [nil, 0, -1] { #expect(NoiseReduction.learnedLuminanceAmount(iso: iso) == table.first!.amount) }
        #expect(zip(table, table.dropFirst()).allSatisfy { $0.iso < $1.iso && $0.amount <= $1.amount })
    }
}

@Suite struct ExifISOTests {
    private let ratings = kCGImagePropertyExifISOSpeedRatings as String
    private let recommended = kCGImagePropertyExifRecommendedExposureIndex as String

    @Test func readsTheRatingWhenItIsUsable() {
        #expect(AppleRawDecoder.isoSpeed(exif: [ratings: [400], recommended: 400]) == 400)
        #expect(AppleRawDecoder.isoSpeed(exif: [ratings: [250]]) == 250)
        // The first rating wins when a file lists several.
        #expect(AppleRawDecoder.isoSpeed(exif: [ratings: [800, 1600]]) == 800)
    }

    @Test func fallsBackToTheRecommendedIndexWhenTheRatingIsAbsentOrSaturated() {
        #expect(AppleRawDecoder.isoSpeed(exif: [recommended: 800]) == 800)
        // ISOSpeedRatings is an Exif SHORT: 102400 and 204800 files carry 65535.
        #expect(AppleRawDecoder.isoSpeed(exif: [ratings: [65535], recommended: 102400]) == 102400)
        #expect(AppleRawDecoder.isoSpeed(exif: [ratings: [65535], recommended: 204800]) == 204800)
    }

    @Test func keepsASaturatedRatingWhenNothingBetterExists() {
        #expect(AppleRawDecoder.isoSpeed(exif: [ratings: [65535]]) == 65535)
    }

    @Test func returnsNilWithoutEitherKey() {
        #expect(AppleRawDecoder.isoSpeed(exif: [:]) == nil)
        #expect(AppleRawDecoder.isoSpeed(exif: [ratings: [] as [Int]]) == nil)
    }
}

@Suite struct DecodePinsTests {
    @Test func roundTripsThroughJSON() throws {
        let pins = DecodePins(
            version: DecodePins.currentVersion, decoderVersion: "8", baselineExposure: 0, shadowBias: 0, sharpness: 0,
            boost: 0, boostShadow: 0, gamutMapping: false, highlightRecovery: true, extendedDynamicRange: 1,
            neutralChromaticity: AppleRawDecoder.daylightNeutral, moireReduction: nil, contrast: 0, detail: 0,
            anchorDecodedMidTone: ExposureAnchor.decodedMidTone, anchorVersion: AppleRawDecoder.anchorVersion,
            exposureGainStops: ExposureAnchor.gainStops(), luminanceNoiseReduction: 0.4, colorNoiseReduction: 0.5,
            lensCorrection: true, scale: 1, draftMode: false)
        let data = try JSONEncoder().encode(pins)
        #expect(try JSONDecoder().decode(DecodePins.self, from: data) == pins)

        let readback = DecodeReadback(asShotTemperature: 5052, asShotTint: 12, neutralTemperature: 5501, neutralTint: 10)
        let readbackData = try JSONEncoder().encode(readback)
        #expect(try JSONDecoder().decode(DecodeReadback.self, from: readbackData) == readback)
    }

    /// RAW 9's pins leave out the colour amount and detail it does not take; a record written before,
    /// with both, reads as it was written.
    @Test func controlsADecoderDoesNotTakeReadAsAbsent() throws {
        var pins = DecodePins(
            version: DecodePins.currentVersion, decoderVersion: "9", baselineExposure: 0, shadowBias: 0, sharpness: 0,
            boost: 0, boostShadow: 0, gamutMapping: false, highlightRecovery: true, extendedDynamicRange: 1,
            neutralChromaticity: AppleRawDecoder.daylightNeutral, moireReduction: nil, contrast: 0, detail: nil,
            anchorDecodedMidTone: ExposureAnchor.decodedMidTone, anchorVersion: AppleRawDecoder.anchorVersion,
            exposureGainStops: ExposureAnchor.gainStops(), luminanceNoiseReduction: 0.176, colorNoiseReduction: nil,
            lensCorrection: true, scale: 1, draftMode: false)
        let data = try JSONEncoder().encode(pins)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("colorNoiseReduction") && !text.contains("\"detail\"") && !text.contains("moireReduction"))
        #expect(try JSONDecoder().decode(DecodePins.self, from: data) == pins)
        pins.decoderVersion = "8"
        pins.colorNoiseReduction = 0.5
        pins.detail = 0
        let older = try JSONEncoder().encode(pins)
        #expect(try JSONDecoder().decode(DecodePins.self, from: older).colorNoiseReduction == 0.5)
        #expect(try JSONDecoder().decode(DecodePins.self, from: older).detail == 0)
    }

    @Test func theDaylightNeutralIsD55() {
        #expect(abs(AppleRawDecoder.daylightNeutral.x - 0.33243) < 1e-6)
        #expect(abs(AppleRawDecoder.daylightNeutral.y - 0.34744) < 1e-6)
    }
}

/// Runs where the CC0 sample raws from `scripts/fetch-samples.sh` are present, including in
/// `scripts/regression.sh`, the required real-RAW regression suite.
@Suite struct AppleRawDecoderTests {
    private static let sample = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")

    private static var hasSample: Bool { FileManager.default.fileExists(atPath: sample.path) }

    private func geometricMeanLuminance(_ texture: MTLTexture) -> Double {
        let width = texture.width
        let height = texture.height
        var halves = [Float16](repeating: 0, count: width * height * 4)
        halves.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: width * 8,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        var logSum = 0.0
        var count = 0.0
        for i in 0..<(width * height) {
            let base = i * 4
            let red = Double(halves[base])
            let green = Double(halves[base + 1])
            let blue = Double(halves[base + 2])
            let luminance = 0.2627 * red + 0.6780 * green + 0.0593 * blue
            if luminance > 1e-5 {
                logSum += log2(luminance)
                count += 1
            }
        }
        return exp2(logSum / count)
    }

    /// The street scene in this sample measured a geometric-mean luminance of 0.0764 with
    /// the decode pinned at baseline 0, no shadow bias and the camera's white balance. The
    /// gain takes that to 0.172. Apple's defaults (baseline +0.3, shadow bias 3) would read
    /// 0.09; no gain would read 0.076. The D55 pin moves daylight files by a few hundredths
    /// of a stop, inside the tolerance; the test prints what it measured.
    @Test(.enabled(if: AppleRawDecoderTests.hasSample))
    func putsAMeteredFrameNearMidGray() throws {
        let gpu = try GPU()
        var options = DecodeOptions()
        options.scale = 0.125
        options.lensCorrection = false
        options.colorNoiseReduction = 0
        options.luminanceNoiseReduction = 0
        let frame = try AppleRawDecoder(gpu: gpu).decode(Self.sample, options: options)

        #expect(frame.decoderVersion == "8")
        #expect(frame.pins?.version == DecodePins.currentVersion)
        #expect(frame.pins?.luminanceNoiseReduction == 0)
        let measured = geometricMeanLuminance(frame.texture)
        let offByStops = log2(measured / 0.172)
        print(String(format: "MEASURE metered frame: geometric-mean luminance %.5f, %+.4f stops from 0.172", measured, offByStops))
        #expect(abs(offByStops) < 0.15, "geometric-mean luminance \(measured), \(offByStops) stops from 0.172")
    }

    /// A decode whose extent is empty, infinite or not a number has no pixels, and says so rather than
    /// trapping on the conversion to whole pixels.
    @Test func onlyAFiniteExtentWithAreaHasPixels() {
        #expect(AppleRawDecoder.hasPixels(CGRect(x: 0, y: 12, width: 7008, height: 4660)))
        #expect(AppleRawDecoder.hasPixels(CGRect(x: 0, y: 0, width: 1, height: 1)))
        #expect(!AppleRawDecoder.hasPixels(.zero) && !AppleRawDecoder.hasPixels(CGRect(x: 0, y: 0, width: 7008, height: 0)))
        #expect(!AppleRawDecoder.hasPixels(.infinite) && !AppleRawDecoder.hasPixels(.null))
        #expect(!AppleRawDecoder.hasPixels(CGRect(x: 0, y: 0, width: CGFloat.nan, height: 4672)))
        #expect(!AppleRawDecoder.hasPixels(CGRect(x: 0, y: 0, width: 7008, height: CGFloat.infinity)))
    }

    /// The row shift a filled lossless S decode gets (`AppleRawDecoder.cut`) makes each row the
    /// image `phase` pixels above it, Core Image's y being up: a single bright row moves down by
    /// about the phase, its light all kept. Its centroid moves by the Lanczos-3 kernel's own
    /// first moment, 0.389 for 0.4 and 0.230 for 0.25. Textures hold Core Image's rows bottom up.
    @Test func rowShiftMovesRowsUp() throws {
        let gpu = try GPU()
        let extent = CGRect(x: 0, y: 0, width: 4, height: 32)
        let line = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 16, width: 4, height: 1))
        let image = line.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent))
        func rows(_ image: CIImage) throws -> [Double] {
            let texture = try gpu.texturePool.acquire(width: Int(extent.width), height: Int(extent.height))
            let commandBuffer = try #require(gpu.queue.makeCommandBuffer())
            gpu.ciContext.render(image, to: texture.texture, commandBuffer: commandBuffer, bounds: extent, colorSpace: gpu.workingColorSpace)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            let pixels = ExposureAnalyzer.pixels(of: texture.texture)
            var green: [Double] = []
            for row in 0..<Int(extent.height) { green.append(Double(pixels[row * Int(extent.width) * 4 + 1])) }
            return green
        }
        func centroid(_ values: [Double]) -> Double {
            var moment = 0.0, total = 0.0
            for (row, value) in values.enumerated() {
                moment += (Double(row) + 0.5) * value
                total += value
            }
            return moment / total
        }
        let plain = try rows(image)
        #expect(abs(centroid(plain) - 16.5) < 1e-3)
        for (phase, moment) in [(-0.4, -0.3893), (0.25, 0.2302)] {
            let shift = CIFilter.convolution9Vertical()
            shift.inputImage = image.clampedToExtent()
            shift.weights = AppleRawDecoder.rowShiftWeights(phase)
            shift.bias = 0
            let moved = try rows(try #require(shift.outputImage).cropped(to: extent))
            #expect(abs(centroid(moved) - (16.5 - moment)) < 0.01, "phase \(phase): centroid \(centroid(moved))")
            #expect(abs(moved.reduce(0, +) - plain.reduce(0, +)) < 0.01, "phase \(phase)")
        }
    }

    /// Every pin reads back from the filter, and the white balance readback says what
    /// Apple's camera profile makes of D55 today: 5501 K, tint +10.0.
    @Test(.enabled(if: AppleRawDecoderTests.hasSample))
    func configureAppliesEveryPinAndReadsThemBack() throws {
        let filter = try #require(CIRAWFilter(imageURL: Self.sample))
        var options = DecodeOptions()
        options.scale = 0.25
        options.lensCorrection = false
        options.colorNoiseReduction = 0.3
        let iso = AppleRawDecoder.isoSpeed(of: filter)
        #expect(iso != nil && iso! > 0)
        let (pins, readback) = AppleRawDecoder.configure(filter, options: options, iso: iso)

        #expect(filter.decoderVersion == .version8)
        #expect(filter.baselineExposure == 0)
        #expect(filter.shadowBias == 0)
        #expect(filter.sharpnessAmount == 0)
        #expect(filter.boostAmount == 0)
        #expect(filter.boostShadowAmount == 0)
        #expect(filter.isGamutMappingEnabled == false)
        #expect(filter.isHighlightRecoveryEnabled == true)
        #expect(filter.extendedDynamicRangeAmount == 1)
        #expect(abs(filter.neutralChromaticity.x - 0.33243) < 1e-4)
        #expect(abs(filter.neutralChromaticity.y - 0.34744) < 1e-4)
        #expect(filter.isMoireReductionSupported)
        #expect(filter.moireReductionAmount == 1)
        #expect(filter.contrastAmount == 0)
        #expect(filter.detailAmount == 0)
        #expect(filter.exposure == ExposureAnchor.gainStops(iso: iso))
        #expect(filter.scaleFactor == 0.25)
        #expect(filter.isDraftModeEnabled)
        #expect(filter.isLensCorrectionEnabled == false)
        #expect(filter.luminanceNoiseReductionAmount == NoiseReduction.luminanceAmount(iso: iso))
        #expect(filter.colorNoiseReductionAmount == 0.3)

        #expect(pins.version == DecodePins.currentVersion)
        #expect(pins.decoderVersion == "8")
        #expect(pins.neutralChromaticity == AppleRawDecoder.daylightNeutral)
        #expect(pins.moireReduction == 1)
        #expect(pins.anchorDecodedMidTone == ExposureAnchor.decodedMidTone)
        #expect(pins.anchorVersion == "1")
        #expect(pins.exposureGainStops == ExposureAnchor.gainStops(iso: iso))
        #expect(pins.luminanceNoiseReduction == NoiseReduction.luminanceAmount(iso: iso))
        #expect(pins.colorNoiseReduction == 0.3)
        #expect(pins.lensCorrection == false)
        #expect(pins.scale == 0.25)
        #expect(pins.draftMode)

        print(String(format: "MEASURE ISO %.0f, as shot %.0f K tint %.1f, D55 reads back %.0f K tint %.1f", iso ?? 0,
                     readback.asShotTemperature, readback.asShotTint, readback.neutralTemperature, readback.neutralTint))
        #expect(abs(readback.neutralTemperature - 5501) < 10)
        #expect(abs(readback.neutralTint - 10) < 1)
        #expect(readback.asShotTemperature >= 2000 && readback.asShotTemperature <= 50000)

        // An explicit amount wins over the ISO keying.
        options.luminanceNoiseReduction = 0.15
        let explicit = AppleRawDecoder.configure(filter, options: options, iso: iso)
        #expect(filter.luminanceNoiseReductionAmount == 0.15)
        #expect(explicit.pins.luminanceNoiseReduction == 0.15)
    }

    private static let medium = sample.deletingLastPathComponent()
        .appendingPathComponent("ILCE-7M4_DSC06675_FullFrame-LossLess-Compressed-Medium.ARW")

    /// RAW 9 takes RAW 8's pins where it has the control, its own luminance amount from Argent's table
    /// (Apple's RAW 9 default, pinned), and leaves the colour amount, detail and moire reduction it
    /// does not take unset and recorded absent. An amount on RAW 9's scale wins over the table, and one
    /// on RAW 8's does not reach it. A file without RAW 9, as lossless M, is refused when it is asked for.
    @Test(.enabled(if: AppleRawDecoderTests.hasSample))
    func raw9AppliesItsPinsAndLeavesWhatItDoesNotTake() throws {
        let filter = try #require(CIRAWFilter(imageURL: Self.sample))
        var options = DecodeOptions()
        options.scale = 0.25
        options.appleDecoder = .learned
        options.luminanceNoiseReduction = 0.9
        let iso = AppleRawDecoder.isoSpeed(of: filter)
        let (pins, readback) = AppleRawDecoder.configure(filter, options: options, iso: iso, layout: try ARWLayout.read(from: Self.sample))

        #expect(filter.decoderVersion.rawValue == "9" && pins.decoderVersion == AppleRawDecoder.learnedDecoderVersion)
        #expect(!filter.isColorNoiseReductionSupported && !filter.isDetailSupported && !filter.isMoireReductionSupported)
        #expect(pins.colorNoiseReduction == nil && pins.detail == nil && pins.moireReduction == nil)
        let amount = NoiseReduction.learnedLuminanceAmount(iso: iso)
        #expect(filter.luminanceNoiseReductionAmount == amount && pins.luminanceNoiseReduction == amount)
        #expect(filter.sharpnessAmount == 0 && filter.contrastAmount == 0 && filter.boostAmount == 0 && filter.boostShadowAmount == 0)
        #expect(filter.baselineExposure == 0 && filter.shadowBias == 0 && !filter.isGamutMappingEnabled)
        #expect(filter.isHighlightRecoveryEnabled && filter.extendedDynamicRangeAmount == 1)
        #expect(abs(filter.neutralChromaticity.x - 0.33243) < 1e-4 && abs(filter.neutralChromaticity.y - 0.34744) < 1e-4)
        #expect(filter.exposure == ExposureAnchor.gainStops(iso: iso) && pins.exposureGainStops == ExposureAnchor.gainStops(iso: iso))
        #expect(filter.scaleFactor == 0.25 && filter.isLensCorrectionEnabled == options.lensCorrection)
        #expect(pins.neutralChromaticity == AppleRawDecoder.daylightNeutral && pins.highlightRecovery && pins.sharpness == 0)
        #expect(pins.version == DecodePins.currentVersion && pins.rawMode == "lossless L")

        // Apple's own default for the file today, which the table pins.
        let fresh = try #require(CIRAWFilter(imageURL: Self.sample))
        fresh.decoderVersion = CIRAWDecoderVersion(rawValue: "9")
        print(String(format: "MEASURE RAW 9 at ISO %.0f: Apple's default luminance amount %.4f, the table's %.4f; D55 reads back %.0f K tint %.1f, as shot %.0f K tint %.1f",
                     iso ?? 0, fresh.luminanceNoiseReductionAmount, amount, readback.neutralTemperature, readback.neutralTint,
                     readback.asShotTemperature, readback.asShotTint))

        options.learnedLuminanceNoiseReduction = 0.2
        let explicit = AppleRawDecoder.configure(filter, options: options, iso: iso)
        #expect(filter.luminanceNoiseReductionAmount == 0.2 && explicit.pins.luminanceNoiseReduction == 0.2)

        let gpu = try GPU()
        #expect(throws: DecodeError.self) { try AppleRawDecoder(gpu: gpu).decode(Self.medium, options: options) }
        let classic = AppleRawDecoder.configure(try #require(CIRAWFilter(imageURL: Self.medium)), options: options, iso: iso)
        #expect(classic.pins.decoderVersion == AppleRawDecoder.pinnedDecoderVersion)
    }

    /// A frame's summed light per channel and its 16-pixel blocks' mean light.
    private static func colour(_ texture: MTLTexture) -> (mean: SIMD3<Double>, blocks: [SIMD3<Double>]) {
        let pixels = ExposureAnalyzer.pixels(of: texture), width = texture.width, height = texture.height
        var sum = SIMD3<Double>(repeating: 0)
        var blocks: [SIMD3<Double>] = []
        for by in stride(from: 0, to: height - 15, by: 16) {
            for bx in stride(from: 0, to: width - 15, by: 16) {
                var block = SIMD3<Double>(repeating: 0)
                for y in by..<(by + 16) {
                    for x in bx..<(bx + 16) {
                        let i = (y * width + x) * 4
                        block += SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
                    }
                }
                sum += block
                blocks.append(block / 256)
            }
        }
        return (sum, blocks)
    }

    /// RAW 9 renders the colour RAW 8 does. In a wide working space RAW 9 collapses red and turns a
    /// frame cyan (red against green 2.5 to 3.6 stops low), so its decodes work in extended linear sRGB
    /// (`GPU.learnedWorkingColorSpace`); this fails if that colour drifts. The lossless sample at the
    /// sheet's 960 pixels: the whole frame's red and blue against green within 0.06 stops of RAW 8's and
    /// its luminance within 0.05 (measured 2026-10-19: -0.030, -0.018 and +0.025),
    /// and of the 16-pixel blocks lit above 4 stops under mid-gray, no more than one in a hundred with
    /// its red against green half a stop below RAW 8's.
    @Test(.enabled(if: AppleRawDecoderTests.hasSample))
    func raw9ColourStaysWithRAW8s() throws {
        let gpu = try GPU()
        let decoder = AppleRawDecoder(gpu: gpu)
        var options = DecodeOptions()
        options.maxLongSide = 960
        let classic = try decoder.decode(Self.sample, options: options)
        options.appleDecoder = .learned
        let learned = try decoder.decode(Self.sample, options: options)
        #expect(classic.decoderVersion == "8" && learned.decoderVersion == "9")
        #expect(learned.width == classic.width && learned.height == classic.height)
        let a = Self.colour(classic.texture), b = Self.colour(learned.texture)
        let luma = SIMD3<Double>(0.2627, 0.6780, 0.0593)
        let redGreen = log2((b.mean.x / b.mean.y) / (a.mean.x / a.mean.y))
        let blueGreen = log2((b.mean.z / b.mean.y) / (a.mean.z / a.mean.y))
        let level = log2((b.mean * luma).sum() / (a.mean * luma).sum())
        let lit = zip(a.blocks, b.blocks).filter { $0.min() > 0.18 / 16 && $1.min() > 0.18 / 16 }
        let cyan = lit.filter { log2($1.x / $1.y) < log2($0.x / $0.y) - 0.5 }.count
        print(String(format: "MEASURE RAW 9 colour against RAW 8: red/green %+.4f, blue/green %+.4f, luminance %+.4f stops; %d of %d lit blocks half a stop or more less red",
                     redGreen, blueGreen, level, cyan, lit.count))
        #expect(abs(redGreen) < 0.06 && abs(blueGreen) < 0.06 && abs(level) < 0.05)
        #expect(lit.count > a.blocks.count / 4 && cyan * 100 < lit.count)
    }

    /// RAW 9's working space, extended linear sRGB in half floats, keeps colours outside sRGB, whose
    /// components are negative there: Rec. 2020's primaries and a saturated cyan go into the working
    /// space and come out in Rec. 2020 within a half float's step.
    @Test func raw9sWorkingSpaceKeepsColoursOutsideSRGB() throws {
        let gpu = try GPU()
        let extent = CGRect(x: 0, y: 0, width: 4, height: 4)
        for colour in [SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(0, 0.6, 0.6), SIMD3(0.9, 0.05, 0.4), SIMD3(0.18, 0.18, 0.18)] {
            let ci = try #require(CIColor(red: CGFloat(colour.x), green: CGFloat(colour.y), blue: CGFloat(colour.z), alpha: 1,
                                          colorSpace: gpu.workingColorSpace))
            let image = CIImage(color: ci).cropped(to: extent)
            let texture = try gpu.texturePool.acquire(width: 4, height: 4)
            let commandBuffer = try #require(gpu.queue.makeCommandBuffer())
            gpu.learnedContext.render(image, to: texture.texture, commandBuffer: commandBuffer, bounds: extent, colorSpace: gpu.workingColorSpace)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            let pixel = ExposureAnalyzer.pixels(of: texture.texture)
            let out = SIMD3(Float(pixel[0]), Float(pixel[1]), Float(pixel[2]))
            let d = out - colour
            #expect(max(abs(d.x), abs(d.y), abs(d.z)) < 2e-3, "\(colour) came out \(out)")
        }
    }

    /// RAW 9 repeats bit for bit: the lossless sample twice through one decoder, and through another
    /// GPU's decoder with a Core Image context of its own.
    @Test(.enabled(if: AppleRawDecoderTests.hasSample))
    func raw9RepeatsBitForBit() throws {
        let gpu = try GPU(), other = try GPU()
        var options = DecodeOptions()
        options.maxLongSide = 960
        options.appleDecoder = .learned
        let decoder = AppleRawDecoder(gpu: gpu)
        func bits(_ frame: LinearFrame) -> [UInt16] { ExposureAnalyzer.pixels(of: frame.texture).map(\.bitPattern) }
        let first = bits(try decoder.decode(Self.sample, options: options))
        let again = bits(try decoder.decode(Self.sample, options: options))
        let elsewhere = bits(try AppleRawDecoder(gpu: other, contextPerDecode: true).decode(Self.sample, options: options))
        #expect(first.count == 960 * 640 * 4)
        #expect(first == again && first == elsewhere)
    }

    private static let uncompressed = sample.deletingLastPathComponent()
        .appendingPathComponent("ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW")

    /// RAW 9 decodes made two at once through one GPU, each in a Core Image context of its own as the
    /// previews make them, are each a lone decode's bits. Rendered into command buffers of the GPU's one
    /// queue, such decodes came back with a tile of RAW 9's network black or garbled: on the uncompressed
    /// sample at 960 pixels, 37 of 40 in five processes, and none alone or through Core Image's own tasks
    /// (measured 2026-10-29, docs/decoder.md section 18).
    @Test(.enabled(if: AppleRawDecoderTests.hasSample))
    func raw9DecodesAtOnceAreEachALoneDecode() throws {
        final class Lanes: @unchecked Sendable {
            let decoder: AppleRawDecoder
            let options: DecodeOptions
            let files: [URL]
            let lone: [[UInt16]]
            private let lock = NSLock()
            private var mismatches: [String] = []
            var differing: [String] { lock.withLock { mismatches } }
            init(decoder: AppleRawDecoder, options: DecodeOptions, files: [URL]) throws {
                self.decoder = decoder
                self.options = options
                self.files = files
                lone = try files.map { try Self.bits(decoder, $0, options) }
            }
            static func bits(_ decoder: AppleRawDecoder, _ url: URL, _ options: DecodeOptions) throws -> [UInt16] {
                try autoreleasepool { ExposureAnalyzer.pixels(of: try decoder.decode(url, options: options).texture).map(\.bitPattern) }
            }
            func run(lane: Int, rounds: Int) {
                for round in 0..<rounds {
                    for (index, url) in files.enumerated() {
                        let bits = (try? Self.bits(decoder, url, options)) ?? []
                        if bits != lone[index] { lock.withLock { mismatches.append("lane \(lane) round \(round) \(url.lastPathComponent)") } }
                    }
                }
            }
        }
        var options = DecodeOptions()
        options.maxLongSide = 960
        options.appleDecoder = .learned
        let lanes = try Lanes(decoder: AppleRawDecoder(gpu: try GPU(), contextPerDecode: true), options: options,
                              files: [Self.uncompressed, Self.sample])
        #expect(lanes.lone.allSatisfy { $0.count == 960 * 640 * 4 })
        DispatchQueue.concurrentPerform(iterations: 2) { lanes.run(lane: $0, rounds: 3) }
        #expect(lanes.differing.isEmpty, "\(lanes.differing)")
    }
}
