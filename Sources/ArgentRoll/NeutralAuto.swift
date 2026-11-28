import ArgentCore
import Foundation

/// Auto-development rules specific to the Neutral digital stock (`argent-neutral`):
///
/// - Mood-preserving white balance: removes unwanted green/magenta and cool casts, trims mild
///   warmth, and leaves the red-blue balance of strongly warm light (such as sunsets) alone.
/// - Subtle social-ready polish: adds a small Vibrance (+12) and Clarity (+8) lift when Neutral
///   develops in Auto mode; `PresencePrint` protects skin tones via its Oklab skin-hue mask.
public enum NeutralAuto {
    public static let stockID = "argent-neutral"

    /// Small green-against-magenta shifts within `greenMagentaDeadband` stops (~6 mired) are
    /// normal scene/foliage bounce and left untouched so neutral walls and skin never turn pink.
    public static let greenMagentaDeadband: Float = 0.06
    /// Share of green-against-magenta cast above the deadband removed (fluorescent / LED tint).
    public static let greenMagentaShare: Float = 0.60
    /// Bound on green-against-magenta correction, in stops (~26 mired).
    public static let greenMagentaLimit: Float = 0.25
    /// Small red-against-blue shifts within `redBlueDeadband` stops (~12 mired) are normal
    /// daylight/sky variance and left untouched so blue skies and neutral walls keep camera color.
    public static let redBlueDeadband: Float = 0.12
    /// Share of cool (blue) cast above the deadband removed, bounded by `coolLimit` stops so
    /// bright blue skies do not warm sunny landscapes into yellow.
    public static let coolShare: Float = 0.45
    public static let coolLimit: Float = 0.35
    /// Mild warm casts up to `warmMoodKnee` stops are trimmed at `mildWarmShare`. The correction
    /// fades to zero at `warmMoodThreshold` stops so strong golden-hour and sunset light keeps
    /// its red-blue balance.
    public static let mildWarmShare: Float = 0.55
    public static let warmMoodKnee: Float = 0.45
    public static let warmMoodThreshold: Float = 0.75

    /// Subtle auto polish applied to Neutral when no manual edit overrides Presence.
    public static let polishVibrance: Float = 12
    public static let polishClarity: Float = 8
    public static let polishPresence: Presence = try! Presence([
        .vibrance: polishVibrance,
        .clarity: polishClarity,
    ])

    public static func isNeutral(_ stock: Stock) -> Bool {
        stock.id == stockID
    }

    /// The share of `cast` Neutral's Auto white balance takes out: ignores minor foliage/daylight
    /// variance inside its deadbands, cleans genuine fluorescent and cold casts gently without
    /// warming blue skies, trims mild indoor warmth, and preserves golden-hour / sunset warmth.
    public static func whiteBalanceCorrection(for cast: SIMD3<Float>) -> SIMD3<Float> {
        let (redBlue, greenMagenta) = AutoBalance.axes(cast)
        let gmExcess = max(abs(greenMagenta) - greenMagentaDeadband, 0)
        let gmSign: Float = greenMagenta >= 0 ? 1 : -1
        let gm = gmSign * min(greenMagentaShare * gmExcess, greenMagentaLimit)
        let rb: Float
        if abs(redBlue) <= redBlueDeadband {
            rb = 0
        } else if redBlue < 0 {
            let coolExcess = -redBlue - redBlueDeadband
            rb = -min(coolShare * coolExcess, coolLimit)
        } else if redBlue <= warmMoodKnee {
            rb = mildWarmShare * (redBlue - redBlueDeadband)
        } else if redBlue < warmMoodThreshold {
            let base = mildWarmShare * (warmMoodKnee - redBlueDeadband)
            let t = (warmMoodThreshold - redBlue) / (warmMoodThreshold - warmMoodKnee)
            rb = base * t * t * (3 - 2 * t)
        } else {
            rb = 0
        }
        return AutoBalance.cast(redBlue: rb, greenMagenta: gm)
    }

    /// Automatic manual-layer settings for `stock` when no user edit is present: subtle
    /// skin-protected vibrance and clarity for Neutral, identity for all film stocks.
    public static func autoManualSettings(for stock: Stock, referenceStops: Float) -> ManualRenderSettings {
        guard isNeutral(stock) else { return .identity }
        let adjustments = (try? ManualAdjustments(presence: polishPresence)) ?? .identity
        return (try? ManualRenderSettings(adjustments: adjustments, referenceStops: referenceStops)) ?? .identity
    }
}
