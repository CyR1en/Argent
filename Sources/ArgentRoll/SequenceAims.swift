import ArgentCore
import Foundation

/// Print levels for a roll that keep a subject photographed again in the same light at one
/// brightness, while each frame's own placement stays the starting point
/// (docs/research/auto/sequence-consistency.md, the pre-registration; the plan is
/// docs/auto-exposure-consistency-plan.md). Frames that nearby captures show to share a subject
/// and light are linked by matched regions (`Link`), and their levels are moved, within bounds,
/// until those regions agree. A frame with no link keeps `AutoPrint.levelStops` exactly. Colour is
/// left to roll smoothing's clusters (`RollSmoothing.aims`), whose cast every method keeps.
///
/// A pure function of its input: the same frames, measurements, stock and controls give the same
/// aims, whatever order the measurements arrived in.
public enum SequenceAims {
    /// One roll as the methods see it.
    public struct Input: Sendable {
        /// The roll's frames in capture order.
        public var frames: [Frame]
        public var analyses: [URL: ExposureAnalysis]
        public var descriptors: [URL: SequenceDescriptor]
        public var stock: Stock
        /// The roll's controls, and each frame's own where it has any.
        public var controls: RollControls
        public var frameControls: [URL: FrameControls]
        public var frameStocks: [URL: Stock]

        public init(frames: [Frame], analyses: [URL: ExposureAnalysis], descriptors: [URL: SequenceDescriptor],
                    stock: Stock, controls: RollControls, frameControls: [URL: FrameControls] = [:],
                    frameStocks: [URL: Stock] = [:]) {
            self.frames = frames
            self.analyses = analyses
            self.descriptors = descriptors
            self.stock = stock
            self.controls = controls
            self.frameControls = frameControls
            self.frameStocks = frameStocks
        }

        /// What `url` develops with.
        public func controls(for url: URL) -> RollControls {
            frameControls[url].map { $0.applied(to: controls) } ?? controls
        }
    }

    /// Which rule sets the levels.
    public enum Method: String, Sendable, Codable, CaseIterable {
        /// Roll smoothing as shipped (`RollSmoothing.aims`): the comparison.
        case control
        /// Roll smoothing followed by the stock-aware textured detail check.
        case detail
        /// Candidate A: frames grouped by links, and roll smoothing's pull and cap applied to their
        /// levels once each is expressed at the group's exposure (the link shifts;
        /// `smoothedLevels`).
        case smoothing
        /// Candidate B: levels solved so that linked regions print at one lightness through the
        /// stock, against each frame's own placement, within bounds (`renderedLevels`). With
        /// `Parameters.faceReliability` it is the ablation R, which does not ship.
        case render
    }

    /// Two frames shown to share a subject in the same light, and the regions that show it.
    public struct Link: Sendable, Equatable {
        /// Indices into `Input.frames`, `earlier` before `later`.
        public var earlier: Int
        public var later: Int
        /// The later frame's matched region against the earlier's in the decodes, in stops: its
        /// light is 2^shift times the earlier's.
        public var shift: Float
        /// `shift` less the change in the camera's exposure, when both headers give one: how much
        /// brighter the scene itself became.
        public var lightChange: Float?
        /// How far the link is trusted, 0 to 1.
        public var confidence: Float
        /// The matched share of the smaller frame, and the matched regions' correlation.
        public var overlap: Float
        public var correlation: Float
        /// The matched points' light in each frame (linear working-space RGB, paired by index) and
        /// each point's weight; bounded in number.
        public var earlierSamples: [SIMD3<Float>]
        public var laterSamples: [SIMD3<Float>]
        public var weights: [Float]

        public init(earlier: Int, later: Int, shift: Float, lightChange: Float?, confidence: Float, overlap: Float,
                    correlation: Float, earlierSamples: [SIMD3<Float>], laterSamples: [SIMD3<Float>], weights: [Float]) {
            self.earlier = earlier
            self.later = later
            self.shift = shift
            self.lightChange = lightChange
            self.confidence = confidence
            self.overlap = overlap
            self.correlation = correlation
            self.earlierSamples = earlierSamples
            self.laterSamples = laterSamples
            self.weights = weights
        }
    }

    /// The methods' constants. Defaults are the starting points of the pre-registration, the
    /// evidence's (`neighbours` to `maximumSamples`) as the matcher rule chose them on the development
    /// split (`SequenceEvidence`; `SequenceEvidenceMeasureTests`); the frozen candidates are
    /// `frozenSmoothing` and `frozenRender`.
    public struct Parameters: Sendable, Equatable, Codable {
        /// Frames after each that it may be linked to, in capture order.
        public var neighbours = 3
        /// The longest gap between linked captures, in seconds.
        public var maximumGap: Double = 600
        /// The least share of the smaller frame two aligned frames must share.
        public var minimumOverlap: Float = 0.4
        /// The least correlation of a verification block's log luminance for it to agree.
        public var minimumCorrelation: Float = 0.5
        /// Cells flatter than this (`SequenceDescriptor.detail`, stops) do not count as structure.
        public var minimumDetail: Float = 0.03
        /// A scene that became this much brighter or darker, in stops, is not the same light.
        public var lightTolerance: Float = 0.5
        public var maximumSamples = 256
        /// Links trusted less than this are left out.
        public var minimumConfidence: Float = 0.5
        /// Candidate B: the matched regions' weight against each frame's own placement, the
        /// lightness difference in L* that the robust loss scales by, the farthest a level may move
        /// from its own placement in stops, and the weight against newly clipped detail
        /// (`renderedLevels` has the objective).
        public var matchWeight: Float = 4
        public var lightnessScale: Float = 20
        public var maximumMove: Float = 0.75
        public var clipWeight: Float = 1
        /// The ablation R: faces count by how reliable they are (confidence, skin, clipping) in the
        /// level each candidate starts a frame from (`reliablyWeighted`). It changes the FiveK-fitted
        /// placement, so it is reported and never ships.
        public var faceReliability = false

        public init() {}

        public init(from decoder: Decoder) throws {
            self.init()
            let c = try decoder.container(keyedBy: CodingKeys.self)
            neighbours = try c.decodeIfPresent(Int.self, forKey: .neighbours) ?? neighbours
            maximumGap = try c.decodeIfPresent(Double.self, forKey: .maximumGap) ?? maximumGap
            minimumOverlap = try c.decodeIfPresent(Float.self, forKey: .minimumOverlap) ?? minimumOverlap
            minimumCorrelation = try c.decodeIfPresent(Float.self, forKey: .minimumCorrelation) ?? minimumCorrelation
            minimumDetail = try c.decodeIfPresent(Float.self, forKey: .minimumDetail) ?? minimumDetail
            lightTolerance = try c.decodeIfPresent(Float.self, forKey: .lightTolerance) ?? lightTolerance
            maximumSamples = try c.decodeIfPresent(Int.self, forKey: .maximumSamples) ?? maximumSamples
            minimumConfidence = try c.decodeIfPresent(Float.self, forKey: .minimumConfidence) ?? minimumConfidence
            matchWeight = try c.decodeIfPresent(Float.self, forKey: .matchWeight) ?? matchWeight
            lightnessScale = try c.decodeIfPresent(Float.self, forKey: .lightnessScale) ?? lightnessScale
            maximumMove = try c.decodeIfPresent(Float.self, forKey: .maximumMove) ?? maximumMove
            clipWeight = try c.decodeIfPresent(Float.self, forKey: .clipWeight) ?? clipWeight
            faceReliability = try c.decodeIfPresent(Bool.self, forKey: .faceReliability) ?? faceReliability
        }

        /// Every constant given, as a freeze states them.
        init(neighbours: Int, maximumGap: Double, minimumOverlap: Float, minimumCorrelation: Float, minimumDetail: Float,
             lightTolerance: Float, maximumSamples: Int, minimumConfidence: Float, matchWeight: Float, lightnessScale: Float,
             maximumMove: Float, clipWeight: Float, faceReliability: Bool) {
            self.neighbours = neighbours
            self.maximumGap = maximumGap
            self.minimumOverlap = minimumOverlap
            self.minimumCorrelation = minimumCorrelation
            self.minimumDetail = minimumDetail
            self.lightTolerance = lightTolerance
            self.maximumSamples = maximumSamples
            self.minimumConfidence = minimumConfidence
            self.matchWeight = matchWeight
            self.lightnessScale = lightnessScale
            self.maximumMove = maximumMove
            self.clipWeight = clipWeight
            self.faceReliability = faceReliability
        }

        /// Candidate A as frozen on the development split (docs/research/auto/sequence-consistency.md,
        /// section 4; benchmark/runs/tune-A-01 and tune-A-02-g6): of the 24 settings, the smallest
        /// development G1 ratio that G3, G5 and G6 allow, 0.722 (G1 asks 0.70), with the fewest links.
        /// It is every default; B's four constants are unread.
        public static let frozenSmoothing = Parameters(
            neighbours: 3, maximumGap: 600, minimumOverlap: 0.4, minimumCorrelation: 0.5, minimumDetail: 0.03,
            lightTolerance: 0.5, maximumSamples: 256, minimumConfidence: 0.5, matchWeight: 4, lightnessScale: 20,
            maximumMove: 0.75, clipWeight: 1, faceReliability: false)
        /// Candidate B as frozen on the development split (docs/research/auto/sequence-consistency.md,
        /// section 4; benchmark/runs/tune-B-01, tune-B-02-g6 and tune-B-03-clip): of the 146 settings,
        /// the smallest development G1 ratio that G3, G5 and G6 allow, 0.388, at the clip weight 0.
        public static let frozenRender = Parameters(
            neighbours: 6, maximumGap: 600, minimumOverlap: 0.4, minimumCorrelation: 0.5, minimumDetail: 0.03,
            lightTolerance: 0.5, maximumSamples: 256, minimumConfidence: 0.3, matchWeight: 16, lightnessScale: 10,
            maximumMove: 0.75, clipWeight: 0, faceReliability: false)
    }

    /// The aims and what they rest on.
    public struct Result: Sendable {
        /// Every measured frame's aim; unmeasured frames have none, as with `RollSmoothing.aims`.
        public var aims: [URL: PrintAim]
        /// Each measured frame's own level, `AutoPrint.levelStops`; with
        /// `Parameters.faceReliability`, the reliably weighted level the candidate started from.
        public var initial: [URL: Float]
        /// The links that counted, in their canonical order (`usableLinks`); none for control.
        public var links: [Link]
        /// The lightness difference left between linked regions, per frame, in L*, where any: under
        /// B, the mean |ΔL*| over the frame's links at the solution. A renders nothing and gives none.
        public var residual: [URL: Float]

        public init(aims: [URL: PrintAim], initial: [URL: Float], links: [Link] = [], residual: [URL: Float] = [:]) {
            self.aims = aims
            self.initial = initial
            self.links = links
            self.residual = residual
        }
    }

    /// The roll's aims by `method`, the candidates on the links `SequenceEvidence` finds.
    public static func resolve(_ input: Input, method: Method, parameters: Parameters = Parameters()) -> Result {
        resolve(input, links: method == .control || method == .detail ? [] : SequenceEvidence.links(input, parameters: parameters),
                method: method, parameters: parameters)
    }

    /// The roll's aims by `method` on `links`, in any order (SequenceSolver.swift has the rules).
    /// Control is `RollSmoothing.aims` exactly and reads no link. A candidate starts each measured
    /// frame from its own level (`ownLevel`), moves only frames that a usable link joins
    /// (`usableLinks`; for B, also with a point to print) and gives every frame roll smoothing's cast.
    static func resolve(_ input: Input, links: [Link], method: Method, parameters: Parameters) -> Result {
        var smoothed = RollSmoothing.aims(input.frames, analyses: input.analyses)
        if method == .detail {
            for frame in input.frames {
                guard let baseline = smoothed[frame.url], let descriptor = input.descriptors[frame.url],
                      let analysis = input.analyses[frame.url] else { continue }
                smoothed[frame.url] = AutoDetail.protect(baseline, descriptor: descriptor, analysis: analysis,
                                                       stock: input.frameStocks[frame.url] ?? input.stock,
                                                       controls: input.controls(for: frame.url), iso: frame.info.iso)
            }
        }
        guard method != .control && method != .detail else {
            return Result(aims: smoothed, initial: input.analyses.mapValues { AutoPrint.levelStops($0) })
        }
        let own = input.frames.map { frame in input.analyses[frame.url].map { ownLevel($0, parameters: parameters) } }
        let usable = usableLinks(links, own: own, parameters: parameters)
        var levels = own, residual = [Float?](repeating: nil, count: own.count), counted = usable
        if method == .smoothing {
            levels = smoothedLevels(own, links: usable)
        } else {
            let rendered = renderedLinks(input, links: usable, aims: smoothed)
            (levels, residual) = renderedLevels(own, links: rendered, parameters: parameters)
            counted = rendered.map(\.link)
        }
        var result = Result(aims: [:], initial: input.analyses.mapValues { ownLevel($0, parameters: parameters) }, links: counted)
        for (index, frame) in input.frames.enumerated() {
            guard let level = levels[index], let cast = smoothed[frame.url]?.cast else { continue }
            let tone = input.analyses[frame.url].map(FittedTone.strengths) ?? (burn: 0, dodge: 0)
            result.aims[frame.url] = PrintAim(level: level, cast: cast, burn: tone.burn, dodge: tone.dodge)
            result.residual[frame.url] = residual[index]
        }
        return result
    }
}
