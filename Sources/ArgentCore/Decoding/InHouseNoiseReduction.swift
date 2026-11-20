import Foundation

/// The in-house decoder's noise reduction (docs/decoder.md, section 10): a decimated Laplacian
/// pyramid in luminance and two colour ratios, in linear light, where each level's detail is kept
/// by how far its neighbourhood stands above the noise there.
///
/// The noise comes from the frame itself: `SensorNoise` reads the raw noise's shot and read parts
/// from the mosaic, and `shotNoise` and `readNoise` say what a unit of each leaves in each level and
/// channel after this decoder's demosaic, matrix and pyramid. So a threshold is a multiple of the
/// noise actually there, at that brightness, and the multiples are the only tuning: for luminance
/// and for colour, keyed to Apple's amounts and ISO tiers so that `DecodeOptions` and
/// `NoiseReduction` select them as they do Apple's, and chosen so the decode's noise comes out as
/// Apple's production decode's. Before the demosaic, in the extreme tier, lone samples far outside
/// their neighbours are pulled in, as they would otherwise survive as specks.
public enum InHouseNoiseReduction {
    /// The standard deviation of each of the seven detail levels' coefficients, the full-size level
    /// first, in a flat neutral field, per channel (luminance, and red and blue less luminance: the
    /// colour ratios before the division by their base, which the kernels apply), over the reference
    /// noise, the standard deviation in output luminance of a neutral green sample's noise. One table
    /// for shot noise and one for read noise, whose colours weigh differently through the white
    /// balance.
    /// Simulated on synthetic mosaics through this decoder's kernels with the committed matrix,
    /// `InHouseNoiseReductionTests/levelNoise`, which fails when they drift.
    public static let shotNoise: [SIMD3<Float>] = [
        SIMD3(0.7471, 0.6859, 1.0601), SIMD3(0.3388, 0.5192, 0.6986), SIMD3(0.1709, 0.2835, 0.4001),
        SIMD3(0.0859, 0.1466, 0.2066), SIMD3(0.0430, 0.0733, 0.1036), SIMD3(0.0216, 0.0367, 0.0516),
        SIMD3(0.0110, 0.0188, 0.0252),
    ]
    public static let readNoise: [SIMD3<Float>] = [
        SIMD3(0.8289, 1.0270, 1.3196), SIMD3(0.3994, 0.7711, 0.8732), SIMD3(0.2030, 0.4185, 0.4981),
        SIMD3(0.1025, 0.2164, 0.2567), SIMD3(0.0520, 0.1095, 0.1292), SIMD3(0.0269, 0.0544, 0.0646),
        SIMD3(0.0149, 0.0270, 0.0328),
    ]

    /// Luminance thresholds, in multiples of the noise, in each ISO tier of `NoiseReduction` at
    /// the tier's own amount, by ISO: Apple's decoder scales its effect by the ISO within a tier,
    /// so the strength that matches it changes with the ISO and jumps where the amount does. Between
    /// a tier's points the strength is interpolated in stops of ISO, and past them it holds.
    ///
    /// Each point is the strength at which the decode's L* noise in flat patches equals Apple's
    /// production decode's, measured on data whose licence allows choosing it (docs/provenance.md;
    /// `ProvenanceMeasureTests/noiseStrengths`), on three kinds of content: the CC0 scene (the
    /// full-frame sample at its own ISO 250, the APS-C sample at its own ISO 640, and the full-frame
    /// sample simulated at each higher ISO with the a7 IV's noise model, `SyntheticRaw`), synthetic
    /// flat patches in four tints, and synthetic neutral flat patches, each with that model's noise.
    /// At each ISO, the mean of the three kinds (the scene's own two at 640 averaged first), rounded
    /// to two decimals; the kinds lie 0.10 to 0.19 apart at each ISO, the neutral patches wanting
    /// the most. Refitted 2026-10-07 under the published conversion gain (`BodyNoise`), with the neutral
    /// patches added: the earlier fit's noisier model and scene-weighted content left Apple's L* 1.05
    /// to 1.32 times on Imaging Resource's a7 IV ladder from ISO 100 to 51200, this one 0.92 to 1.17
    /// (held out, measured; docs/research/noise-and-hardware.md). On RawNIND's real a7C ladder the
    /// strength that matches real frames and the strength that matches the same scene simulated with
    /// the a7C's published noise agree within 8 percent from ISO 640 to 51200 (measured), so the
    /// simulation stands in for real frames here. The extended settings, 102400 and 204800, are
    /// noise-reduced in the camera's raw (PhotonsToPhotos' marks, reported) and keep 1.4 to 1.6 times
    /// Apple's L* on the held-out ladder.
    public static let lowTier: [(iso: Float, strength: Float)] = [(100, 0.58), (250, 0.63), (640, 0.66), (1000, 0.66), (1250, 0.66)]
    public static let highTier: [(iso: Float, strength: Float)] = [(1600, 0.73), (3200, 0.73), (6400, 0.77)]
    public static let extremeTier: [(iso: Float, strength: Float)] = [(8000, 1.09), (12800, 1.12), (25600, 1.15), (51200, 1.14), (102400, 1.17)]
    /// Colour thresholds at Apple's colour amount of 0.5, which every decode uses, by ISO, matched
    /// the same way on chroma noise: 1.42 up to ISO 12800, the median of the thirty matches from ISO
    /// 100 to 12800 on the three kinds of content (1.12 to 3.13, scattering up to twice between
    /// kinds at one ISO and with no trend across tiers), then the mean of the three kinds, 2.60, 3.64
    /// and 3.47 at 25600, 51200 and 102400, interpolated in stops. Apple's chroma reduction follows
    /// the Exif ISO, not the noise (measured: one frame's noise tagged 800, 1600 and 3200 keeps 23, 8
    /// and 4 percent of its chroma), so the earlier fit's noisier model saw it weaker than it is. One
    /// value cannot follow Apple inside its low tier: on the permitted content this leaves 0.6 to 1.0
    /// times Apple's chroma noise up to ISO 640 and 1.2 to 1.9 times at 1000 and 1250. On Imaging
    /// Resource's ladder, held out, it leaves 0.44 to 0.67 times from ISO 100 to 800 and 1.5 to 2.6
    /// times from 1600 to 12800, against 0.86 to 1.64 and 2.9 to 4.7 before (measured), mostly
    /// neutral patches, where Apple removes nearly all colour noise.
    public static let colourByISO: [(iso: Float, strength: Float)] = [(12800, 1.42), (25600, 2.60), (51200, 3.64), (102400, 3.47)]
    /// The colour strength raised near neutral from Apple's high tier up (ISO 1600; `BayerDemosaic
    /// .ColourGain`): times `1 + neutralGain * exp(-|c|^2 / neutralWidth^2)`, `c` the coarser level's
    /// colour ratios. Apple's chroma reduction depends on content: from ISO 1600 it takes nearly all the
    /// colour noise out of neutral areas and keeps more on coloured ones (Apple's flat-patch a*b* at
    /// 3200 and 6400: 0.19 and 0.18 on neutral synthetic patches, 0.40 and 0.76 on tinted ones), and on
    /// real textured frames it keeps more than the colour strength of 1.42 leaves (matching strengths
    /// 0.78 to 1.95 on the photographyblog frames from 1250 to 4000). Neutral content wants 1.48 to 1.98
    /// (Imaging Resource's still life and neutral patches, 1600 to 6400), where 1.42 left 1.29 to 2.25
    /// times Apple's a*b* on the still life. With 0.5 and 0.2 the still life keeps 0.56, 0.60, 0.74
    /// and 0.67 of Apple's a*b* at 1600, 3200, 4000 and 5000 (0.07 to 0.11 in a*b*), the textured frames
    /// and every print move by at most 0.01 dE2000 (measured, `DecoderCoverageMeasureTests/colourDesign`;
    /// docs/decoder.md section 17). Below 1600 the frames the decoder took before keep their pixels.
    public static let neutralGain: Float = 0.5
    public static let neutralWidth: Float = 0.2

    /// The share of the coarser level's own luminance keep each level keeps at least, of luminance
    /// and of colour (`BayerDemosaic.NoiseLevel.inherit`): all of it for luminance, none for colour,
    /// whose noise it would carry along every edge. On the CC0 sample simulated at ISO 1600 to
    /// 51200, against the sample itself as the clean frame, luminance inheriting keeps 3 to 8 points
    /// more of the finest band at about the same noise, and colour inheriting raises chroma noise 1.3
    /// to 4 times (measured, `ProvenanceMeasureTests/noiseDesign`).
    public static let inherit: Float = 1
    public static let inheritColour: Float = 0
    /// Impulses are pulled in past this many deviations in the extreme tier, and left alone below
    /// it, where a lone bright pixel is more likely a point of light than noise. A round value: on
    /// Gaussian noise alone the test pulls about 2 samples in a million, against 1 in 10,000 at 3
    /// (computed). The specks it is for are not in synthetic noise, and 4 was preferred to 6 on
    /// RawNIND's a7C at ISO 51200, a permitted set since 2026-10-07 (CC BY-SA 4.0); docs/provenance.md
    /// records the choice.
    public static let extremeImpulse: Float = 4
    /// Per-level multipliers on the luminance and colour strengths, the full-size level first.
    public static let luminanceProfile: [Float] = [1, 1, 1, 1, 1, 1, 1]
    public static let colourProfile: [Float] = [1, 1, 1, 1, 1, 1, 1]
    /// Where Hamilton-Adams's correction starts and finishes fading in, in multiples of what noise
    /// alone gives a site's differences (`BayerDemosaic.Parameters.flatLow`): round multiples of the
    /// noise. Without the fade the simulated CC0 frames carry 1.3 to 2 times the L* noise at the same
    /// strengths (measured, `noiseDesign`).
    public static let flatLow: Float = 1.5
    public static let flatHigh: Float = 3
    /// The colour ratios' lift (`BayerDemosaic.NoiseLevel`), in standard deviations of the
    /// reference noise: a round value; at 1 the simulated CC0 frame at ISO 51200 carries 6.5 times
    /// Apple's chroma noise (measured, `noiseDesign`).
    public static let lift: Float = 2

    /// Everything the noise reduction is set by.
    public struct Tuning: Sendable, Equatable {
        /// The amounts on Apple's scale this stands for, as the pins record them.
        public var luminanceAmount: Float
        public var colourAmount: Float
        /// Thresholds in multiples of the noise.
        public var luminance: Float
        public var colour: Float
        /// A multiplier on each per detail level, the full-size one first; the shorter of the two
        /// sets how many levels the pyramid has.
        public var luminanceProfile: [Float]
        public var colourProfile: [Float]
        public var flatLow: Float
        public var flatHigh: Float
        /// The colour ratios' lift in deviations of the reference noise.
        public var lift: Float
        /// Impulses are pulled in past this many deviations of the noise
        /// (`BayerDemosaic.Parameters.impulse`); 0 is off.
        public var impulse: Float
        /// The share of the coarser level's luminance keep each level keeps at least, for its
        /// luminance and its colour (`BayerDemosaic.NoiseLevel.inherit`).
        public var inherit: Float
        public var inheritColour: Float
        /// The colour strength raised near neutral (`BayerDemosaic.ColourGain`); 0 leaves it, and the
        /// decode runs the kernels without the gain.
        public var colourNeutral: Float = 0
        public var colourWidth: Float = 1
        public var shotNoise: [SIMD3<Float>]
        public var readNoise: [SIMD3<Float>]

        public init(luminanceAmount: Float, colourAmount: Float, luminance: Float, colour: Float,
                    luminanceProfile: [Float] = InHouseNoiseReduction.luminanceProfile,
                    colourProfile: [Float] = InHouseNoiseReduction.colourProfile,
                    flatLow: Float = InHouseNoiseReduction.flatLow, flatHigh: Float = InHouseNoiseReduction.flatHigh,
                    lift: Float = InHouseNoiseReduction.lift, impulse: Float = 0,
                    inherit: Float = InHouseNoiseReduction.inherit, inheritColour: Float = InHouseNoiseReduction.inheritColour,
                    shotNoise: [SIMD3<Float>] = InHouseNoiseReduction.shotNoise,
                    readNoise: [SIMD3<Float>] = InHouseNoiseReduction.readNoise) {
            self.luminanceAmount = luminanceAmount
            self.colourAmount = colourAmount
            self.luminance = luminance
            self.colour = colour
            self.luminanceProfile = luminanceProfile
            self.colourProfile = colourProfile
            self.flatLow = flatLow
            self.flatHigh = flatHigh
            self.lift = lift
            self.impulse = impulse
            self.inherit = inherit
            self.inheritColour = inheritColour
            self.shotNoise = shotNoise
            self.readNoise = readNoise
        }
    }

    /// The tuning for Apple's amounts on a frame of `iso`. The luminance strength is the ISO tier's
    /// at that ISO, scaled by the amount over the tier's own, so the ISO-keyed default lands on the
    /// table and an amount set in `DecodeOptions` moves it as it would move Apple's; the colour
    /// strength scales with its amount the same way, and from the high tier rises near neutral. A frame with no usable ISO gets the low tier
    /// at ISO 100, the least, as `NoiseReduction` gives it the least.
    public static func tuning(luminance: Float, colour: Float, iso: Float?) -> Tuning {
        let tierAmount = NoiseReduction.luminanceAmount(iso: iso)
        let known = iso.flatMap { $0 > 0 ? $0 : nil }
        let table = tierAmount == NoiseReduction.extremeISOLuminance ? extremeTier
            : tierAmount == NoiseReduction.highISOLuminance ? highTier : lowTier
        let atISO = strength(at: known ?? lowTier[0].iso, table)
        let colourAtISO = strength(at: known ?? colourByISO[0].iso, colourByISO)
        var tuning = Tuning(luminanceAmount: luminance, colourAmount: colour,
                            luminance: max(0, atISO * luminance / tierAmount), colour: max(0, colourAtISO * colour / 0.5),
                            impulse: tierAmount == NoiseReduction.extremeISOLuminance && luminance > 0 ? extremeImpulse : 0)
        if tierAmount == NoiseReduction.highISOLuminance || tierAmount == NoiseReduction.extremeISOLuminance {
            tuning.colourNeutral = neutralGain
            tuning.colourWidth = neutralWidth
        }
        return tuning
    }

    /// `table` at `iso`, interpolated in stops and held past its ends.
    static func strength(at iso: Float, _ table: [(iso: Float, strength: Float)]) -> Float {
        guard iso > table[0].iso else { return table[0].strength }
        for (a, b) in zip(table, table.dropFirst()) where iso <= b.iso {
            return a.strength + (b.strength - a.strength) * log2(iso / a.iso) / log2(b.iso / a.iso)
        }
        return table[table.count - 1].strength
    }

    /// The colour gain `tuning` asks for, or nil for none.
    static func colourGain(_ tuning: Tuning) -> BayerDemosaic.ColourGain? {
        tuning.colourNeutral > 0 && tuning.colour > 0 ? BayerDemosaic.ColourGain(neutral: tuning.colourNeutral, width: tuning.colourWidth) : nil
    }

    /// Gives the demosaic the noise of each colour in white-balanced units, where its green fades
    /// to the flat mean, and the colour ratios' lift.
    static func apply(_ tuning: Tuning, noise: SensorNoise, to p: inout BayerDemosaic.Parameters) {
        let scales = [p.scale.0, p.scale.1, p.scale.2, p.scale.3]
        let colours = [p.colour.0, p.colour.1, p.colour.2, p.colour.3]
        func scale(_ colour: UInt32) -> Float { scales[colours.firstIndex(of: colour) ?? 0] }
        let s = (scale(0), scale(1), scale(2))
        p.noiseShot = (s.0 * Float(noise.shot), s.1 * Float(noise.shot), s.2 * Float(noise.shot))
        p.noiseRead = (s.0 * s.0 * Float(noise.read), s.1 * s.1 * Float(noise.read), s.2 * s.2 * Float(noise.read))
        p.flatLow = tuning.flatLow
        p.flatHigh = tuning.flatHigh
        p.impulse = tuning.impulse
        let (a, b) = reference(noise: noise, parameters: p)
        p.liftShot = tuning.lift * tuning.lift * a
        p.liftRead = tuning.lift * tuning.lift * b
    }

    /// The reference noise's variance at output luminance `y` is `a * y + b`: a neutral green
    /// sample's, carried to the output by the luminance of the matrix's neutral (the exposure gain
    /// included).
    static func reference(noise: SensorNoise, parameters p: BayerDemosaic.Parameters) -> (a: Float, b: Float) {
        let m = p.matrix
        let luma = Rec2020.luma
        let neutral = luma.x * (m.0 + m.1 + m.2) + luma.y * (m.3 + m.4 + m.5) + luma.z * (m.6 + m.7 + m.8)
        let scales = [p.scale.0, p.scale.1, p.scale.2, p.scale.3]
        let colours = [p.colour.0, p.colour.1, p.colour.2, p.colour.3]
        let green = scales[colours.firstIndex(of: 1) ?? 1]
        let k = neutral * green
        return (k * Float(noise.shot), k * k * Float(noise.read))
    }

    /// Each detail level's thresholds, or nil when both strengths are 0 and the decode is the
    /// plain demosaic.
    static func levels(_ tuning: Tuning, noise: SensorNoise, parameters: BayerDemosaic.Parameters) -> [BayerDemosaic.NoiseLevel]? {
        guard tuning.luminance > 0 || tuning.colour > 0 else { return nil }
        let (a, b) = reference(noise: noise, parameters: parameters)
        let count = min(tuning.luminanceProfile.count, tuning.colourProfile.count, tuning.shotNoise.count, tuning.readNoise.count)
        return (0..<count).map { l in
            let colour = tuning.colour * tuning.colourProfile[l]
            let strength = SIMD3(tuning.luminance * tuning.luminanceProfile[l], colour, colour)
            let squared = strength * strength
            let slope = squared * tuning.shotNoise[l] * tuning.shotNoise[l] * a
            let floor = squared * tuning.readNoise[l] * tuning.readNoise[l] * b
            var level = BayerDemosaic.NoiseLevel()
            level.slope = (slope.x, slope.y, slope.z)
            level.floor = (floor.x, floor.y, floor.z)
            level.liftShot = parameters.liftShot
            level.liftRead = parameters.liftRead
            if l < count - 1 {
                level.inherit = tuning.inherit
                level.inheritColour = tuning.inheritColour
            }
            return level
        }
    }
}
