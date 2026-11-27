import ArgentCore
import Foundation

/// Auto-development rules specific to the Neutral digital stock (`argent-neutral`):
///
/// - Mood-preserving white balance: removes unwanted green/magenta and cool casts cleanly while
///   tapering warm red-blue correction above a golden-hour knee so warm light (such as sunsets)
///   keeps its mood instead of being neutralized cold.
/// - Subtle social-ready polish: adds a small Vibrance (+12) and Clarity (+8) lift when Neutral
///   develops in Auto mode; `PresencePrint` protects skin tones via its Oklab skin-hue mask.
public enum NeutralAuto {
    public static let stockID = "argent-neutral"

    /// Share of green-against-magenta cast removed (fluorescent / LED tint is never mood).
    public static let greenMagentaShare: Float = 0.85
    /// Bound on green-against-magenta correction, in stops.
    public static let greenMagentaLimit: Float = 0.40
    /// Share of cool (blue) cast removed, bounded by `coolLimit` stops.
    public static let coolShare: Float = 0.80
    public static let coolLimit: Float = 0.65
    /// Mild warm casts below `warmMoodKnee` stops are trimmed at `mildWarmShare`; stronger warm
    /// casts (golden hour, sunset) taper smoothly toward `warmMoodLimit` so the scene stays warm.
    public static let mildWarmShare: Float = 0.75
    public static let warmMoodKnee: Float = 0.45
    public static let warmMoodLimit: Float = 0.42

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

    /// The share of `cast` Neutral's Auto white balance takes out: cleans green-magenta and cool
    /// casts firmly, trims mild indoor warmth, and preserves golden-hour / sunset warmth.
    public static func whiteBalanceCorrection(for cast: SIMD3<Float>) -> SIMD3<Float> {
        let (redBlue, greenMagenta) = AutoBalance.axes(cast)
        let gm = min(max(greenMagentaShare * greenMagenta, -greenMagentaLimit), greenMagentaLimit)
        let rb: Float
        if redBlue <= 0 {
            rb = max(coolShare * redBlue, -coolLimit)
        } else if redBlue <= warmMoodKnee {
            rb = mildWarmShare * redBlue
        } else {
            let base = mildWarmShare * warmMoodKnee
            let headroom = max(warmMoodLimit - base, 0)
            let excess = redBlue - warmMoodKnee
            let soft = headroom > 0 ? headroom * (excess / (excess + headroom / mildWarmShare)) : 0
            rb = min(base + soft, warmMoodLimit)
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
