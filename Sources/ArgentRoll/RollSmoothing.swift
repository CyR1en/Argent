import ArgentCore
import Foundation

/// Roll smoothing: the one mechanism that makes a sequence look like one roll (spec, Auto
/// development). Frames taken together in the same light form a cluster, and each frame's print
/// level is pulled halfway toward the cluster's median and held within a third of a scene stop
/// of it, as a lab printing a roll keeps a sequence even.
///
/// Constants from the M3 research (docs/M3-research.md, section 2): the pull of 0.5 and the
/// third of a stop are the spec's; no published lab constants exist for either. The splits are
/// inference: a gap of two minutes, a jump of more than one EV in the light the camera exposed
/// for, a flash firing or not, the camera's own white balance moving by `whiteBalanceMired`, or
/// the frames' log-luminance histograms differing by more than half a stop. Measured on Cube++'s
/// capture sequences (docs/research/rolls.md, 2026-10-07): the histogram split keeps a cluster's
/// levels within about half a stop, so the pull and cap rarely act, and it stays because looser
/// splits let a culled frame move its neighbours' prints by up to a stop.
public enum RollSmoothing {
    public static let pull: Float = 0.5
    public static let maximumDeviation: Float = 1.0 / 3
    /// The same for a burn or a dodge, in paper stops: a third of a scene stop is about 0.16 of a paper
    /// stop at the print's mid-gray, where one paper stop is about 2.1 scene stops (`local-tone`), and at a sky three
    /// stops over mid-gray a burn has reached about three quarters of its strength.
    public static let maximumToneDeviation: Float = 0.2
    public static let timeGap: TimeInterval = 120
    public static let evJump: Double = 1
    public static let histogramDistance: Float = 0.5
    /// About a Wratten 81A; the camera's auto white balance drifts less than this in one light
    /// (inference; on Cube++ it splits 13 percent of neighbours in one measured light,
    /// docs/research/rolls.md).
    public static let whiteBalanceMired: Float = 20

    /// The roll's clusters, in capture order. Frames are taken as ordered (the roll scan's
    /// capture order); a frame with no capture time is a cluster of its own. A split that
    /// needs a measurement not made yet is not made.
    public static func clusters(_ frames: [Frame], analyses: [URL: ExposureAnalysis]) -> [[Frame]] {
        var clusters: [[Frame]] = []
        var previous: Frame?
        for frame in frames {
            if let last = previous, !splits(last, frame, analyses: analyses), !clusters.isEmpty {
                clusters[clusters.count - 1].append(frame)
            } else {
                clusters.append([frame])
            }
            previous = frame
        }
        return clusters
    }

    /// Whether `next` starts a new cluster after `last`.
    public static func splits(_ last: Frame, _ next: Frame, analyses: [URL: ExposureAnalysis]) -> Bool {
        guard let a = last.info.captureDate, let b = next.info.captureDate, abs(b.timeIntervalSince(a)) <= timeGap
        else { return true }
        if let x = last.info.sceneEV100, let y = next.info.sceneEV100, abs(x - y) > evJump { return true }
        if let x = last.info.flashFired, let y = next.info.flashFired, x != y { return true }
        guard let p = analyses[last.url], let q = analyses[next.url] else { return false }
        if let x = p.asShotTemperature, let y = q.asShotTemperature, x > 0, y > 0,
           abs(1e6 / x - 1e6 / y) > whiteBalanceMired { return true }
        if let distance = p.histogramDistance(to: q), distance > histogramDistance { return true }
        return false
    }

    /// Each measured frame's print level, in scene stops: its own bounded level
    /// (`AutoPrint.levelStops`) pulled toward its cluster's median. Frames not yet measured
    /// have none and do not count toward a median.
    public static func levels(_ frames: [Frame], analyses: [URL: ExposureAnalysis]) -> [URL: Float] {
        aims(frames, analyses: analyses).mapValues(\.level)
    }

    /// Each measured frame's print aim: its level pulled toward its cluster's median as in
    /// `levels`, and its cluster's cast. Colour is smoothed more strongly than exposure, as
    /// labs do (spec): every frame of a cluster takes the cluster's median cast, channel by
    /// channel, so a sequence in one light is filtered as one.
    public static func aims(_ frames: [Frame], analyses: [URL: ExposureAnalysis]) -> [URL: PrintAim] {
        var aims: [URL: PrintAim] = [:]
        for cluster in clusters(frames, analyses: analyses) {
            let measured = cluster.compactMap { frame in analyses[frame.url].map { (frame.url, $0) } }
            guard !measured.isEmpty else { continue }
            let median = Self.median(measured.map { AutoPrint.levelStops($0.1) })
            let casts = measured.map { AutoBalance.cast($0.1) }
            let tones = measured.map { FittedTone.strengths($0.1) }
            let burnMedian = Self.median(tones.map(\.burn)), dodgeMedian = Self.median(tones.map(\.dodge))
            let cast = SIMD3(Self.median(casts.map(\.x)), Self.median(casts.map(\.y)), Self.median(casts.map(\.z)))
            for ((url, analysis), tone) in zip(measured, tones) {
                let level = AutoPrint.levelStops(analysis)
                let pulled = median + min(max(pull * (level - median), -maximumDeviation), maximumDeviation)
                // The tone step pulls as the level does, so reframing does not swing a sky's burn.
                func tonePulled(_ value: Float, _ median: Float) -> Float {
                    max(0, median + min(max(pull * (value - median), -maximumToneDeviation), maximumToneDeviation))
                }
                aims[url] = PrintAim(level: min(max(pulled, -AutoPrint.bound), AutoPrint.darkenLimit),
                                     cast: cast - SIMD3(repeating: cast.sum() / 3),
                                     burn: tonePulled(tone.burn, burnMedian), dodge: tonePulled(tone.dodge, dodgeMedian))
            }
        }
        return aims
    }

    static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
