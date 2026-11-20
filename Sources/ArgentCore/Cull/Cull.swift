import Accelerate
import Foundation

/// What Vision reads in one frame's IFD0 preview.
public struct PreviewScores: Sendable, Equatable {
    /// The best face's capture quality, 0 to 1 (`VNDetectFaceCaptureQualityRequest`); `nil` when
    /// Vision found no face.
    public var faceQuality: Double?
    /// The frame's overall aesthetics score, -1 to 1 (`VNCalculateImageAestheticsScoresRequest`).
    public var aesthetics: Double
    /// The frame's image feature print (`VNGenerateImageFeaturePrintRequest` revision 2, 768 floats).
    public var featurePrint: [Float]

    public init(faceQuality: Double?, aesthetics: Double, featurePrint: [Float]) {
        self.faceQuality = faceQuality
        self.aesthetics = aesthetics
        self.featurePrint = featurePrint
    }
}

/// One raw on the card, as the cull reads it.
public struct CullInput: Sendable, Equatable {
    /// The raw's path within the folder the cull reads, such as DCIM/100MSDCF/DSC04142.ARW. It
    /// names the frame; a file name alone does not, since a camera can number each DCF folder from
    /// DSC00001.
    public var path: String
    /// DateTimeOriginal with its milliseconds (`ARWFrameInfo.captureDate`); `nil` when the header
    /// could not be read.
    public var captureDate: Date?
    /// `nil` when the preview could not be read.
    public var scores: PreviewScores?

    public init(path: String, captureDate: Date?, scores: PreviewScores?) {
        self.path = path
        self.captureDate = captureDate
        self.scores = scores
    }
}

/// The photographer's thresholds for the cull.
public struct CullSettings: Sendable, Equatable, Codable {
    /// The longest gap between two frames of one burst, in seconds, to the millisecond.
    public var burstGap: TimeInterval
    /// A face quality below this is soft focus.
    public var softFocusBelow: Double
    /// A face quality from `softFocusBelow` up to this is eyes closed.
    public var eyesClosedBelow: Double
    /// An aesthetics score below this is a failed frame.
    public var failedBelow: Double
    /// The largest feature-print distance from its burst's keeper at which a frame is the same moment.
    public var sameMomentWithin: Double
    /// Whether a frame with closed eyes stays on the card.
    public var leavesEyesClosed: Bool

    public init(burstGap: TimeInterval = 0.35, softFocusBelow: Double = 0.26, eyesClosedBelow: Double = 0.30,
                failedBelow: Double = 0, sameMomentWithin: Double = 0.25, leavesEyesClosed: Bool = true) {
        self.burstGap = burstGap
        self.softFocusBelow = softFocusBelow
        self.eyesClosedBelow = eyesClosedBelow
        self.failedBelow = failedBelow
        self.sameMomentWithin = sameMomentWithin
        self.leavesEyesClosed = leavesEyesClosed
    }
}

/// Why a frame stays on the card.
public enum CullReason: Sendable, Hashable {
    case failed
    case softFocus
    case eyesClosed
    /// The frame shows the same moment as its burst's keeper, at this path, which is copied.
    case sameMoment(keeper: String)
}

/// One frame's fate.
public struct CullVerdict: Sendable, Hashable {
    public var path: String
    /// Why the frame stays on the card; `nil` for a frame Argent copies.
    public var reason: CullReason?
    /// The frame's burst, counted from 0 in capture order.
    public var burst: Int

    public var keep: Bool { reason == nil }

    public init(path: String, reason: CullReason?, burst: Int) {
        self.path = path
        self.reason = reason
        self.burst = burst
    }
}

public enum Cull {
    /// Each frame's fate, in capture order.
    ///
    /// Frames no more than `burstGap` apart form a burst. A scored frame is failed, soft focus or
    /// eyes closed by its own scores, in that order. Among the burst's other scored frames the
    /// keeper has the best face quality, a face ranking above none, then the best aesthetics, then
    /// the earliest; each of the rest within `sameMomentWithin` of the keeper is the same moment,
    /// and one farther away is kept. A frame without scores is kept. Paths must be unique.
    public static func verdicts(_ frames: [CullInput], settings: CullSettings = CullSettings()) -> [CullVerdict] {
        let ordered = frames.map { frame in
            (frame: frame, milliseconds: frame.captureDate.map { wholeMilliseconds($0.timeIntervalSince1970) })
        }.sorted { a, b in
            switch (a.milliseconds, b.milliseconds) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.frame.path.localizedStandardCompare(b.frame.path) == .orderedAscending
            }
        }
        let gap = wholeMilliseconds(settings.burstGap)
        var bursts: [[CullInput]] = []
        for (index, item) in ordered.enumerated() {
            if index > 0, let a = ordered[index - 1].milliseconds, let b = item.milliseconds, b - a <= gap {
                bursts[bursts.count - 1].append(item.frame)
            } else {
                bursts.append([item.frame])
            }
        }
        return bursts.enumerated().flatMap { decide($0.element, burst: $0.offset, settings: settings) }
    }

    private static func decide(_ frames: [CullInput], burst: Int, settings: CullSettings) -> [CullVerdict] {
        var reasons = frames.map { $0.scores.flatMap { ownReason($0, settings) } }
        let candidates = frames.indices.compactMap { index in
            reasons[index] == nil ? frames[index].scores.map { (index: index, scores: $0) } : nil
        }
        if let keeper = candidates.max(by: { rank($0.scores) < rank($1.scores) }) {
            for candidate in candidates where candidate.index != keeper.index
                && Double(distance(candidate.scores.featurePrint, keeper.scores.featurePrint)) <= settings.sameMomentWithin {
                reasons[candidate.index] = .sameMoment(keeper: frames[keeper.index].path)
            }
        }
        return frames.indices.map { CullVerdict(path: frames[$0].path, reason: reasons[$0], burst: burst) }
    }

    private static func ownReason(_ scores: PreviewScores, _ settings: CullSettings) -> CullReason? {
        if scores.aesthetics < settings.failedBelow { return .failed }
        guard let face = scores.faceQuality else { return nil }
        if face < settings.softFocusBelow { return .softFocus }
        if face < settings.eyesClosedBelow, settings.leavesEyesClosed { return .eyesClosed }
        return nil
    }

    private static func rank(_ scores: PreviewScores) -> (Double, Double) {
        (scores.faceQuality ?? -.infinity, scores.aesthetics)
    }

    private static func wholeMilliseconds(_ seconds: TimeInterval) -> Double {
        (seconds * 1000).rounded()
    }

    /// The Euclidean distance between two feature prints, which is Vision's `computeDistance` for
    /// revision 2.
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return .infinity }
        return vDSP.distanceSquared(a, b).squareRoot()
    }
}
