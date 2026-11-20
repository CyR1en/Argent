import Foundation

// Sky in still water is not sky (the owner, 2026-11-06: "Sky in still water should not be selected"). DA3's seed selects a
// bright reflection as readily as the sky above it, so a Sky seed passes through the water veto before it is stored:
// Vision's scene classifier decides whether the frame may hold water at all (`WaterGate`), and only then does EoMT's water
// map clear the seed where it lies on water (`WaterVeto`). S5 measured the rule on the converted models: no real still-water
// frame keeps 1 % of the frame selected in its reflection (55 of 55), and 33 of 33 synthetic mirrors are clear, fused ones
// included (masking plan section 3). This file is that rule, ported from S5's `Veto.swift` and `WaterGate.swift`, which equal
// S5's Python (OpenCV) reference pixel for pixel on its golden masks. It takes the seed and the water map as arrays, so it
// runs no model; the caller passes the water map as a closure, which is called only when the gate passes.

/// Whether a frame may hold water: the largest confidence Vision's scene classifier gives any of S4's water labels, on the
/// frame's neutral print (`AppleSegmentation.waterScore`). Below the threshold EoMT never loads. It passes about 12 % of
/// frames (S5: 11.9 % of S4's 1,272, 7.1 % of 2,331 new ones), so most Sky clicks skip EoMT, and it stops a real loss of sky
/// beside an aircraft's wing (`a2076`, 4.1 % of the frame) that EoMT alone would remove.
public enum WaterGate {
    /// S4's water labels, of `ClassifyImageRequest`'s 1,303.
    public static let identifiers = ["water_body", "lake", "river", "ocean", "harbour", "waterways", "creek", "wetland"]
    /// S4's gate: under the lowest real positive (0.056, `a0307`) by 1.9 times, over the BMX-wheel frame's 0.000; decisions on
    /// S4's set are the same for gates 0.01 to 0.05.
    public static let threshold: Float = 0.03

    /// The score of a classification: the largest confidence of `identifiers`, 0 when none is returned.
    public static func score(_ confidences: [String: Float]) -> Float {
        identifiers.compactMap { confidences[$0] }.filter(\.isFinite).max() ?? 0
    }

    public static func passes(_ score: Float) -> Bool { score >= threshold }
}

/// Vision's water score for one picture, kept with the Sky seed it gated, because it is Apple's classifier and may change with
/// macOS: the canary re-runs it after each update.
public struct WaterScore: Sendable, Equatable {
    public static let engine = "vision.classify-image"
    /// `VNClassifyImageRequestRevision2`, pinned: the newest and the only one the Swift API offers on macOS 27.
    public static let revision = 2

    public let score: Float
    /// The water labels' confidences as Vision returned them, 0 for one it did not return.
    public let labels: [String: Float]

    public init(labels: [String: Float]) {
        var kept: [String: Float] = [:]
        for identifier in WaterGate.identifiers { kept[identifier] = labels[identifier] ?? 0 }
        self.labels = kept
        score = WaterGate.score(kept)
    }

    public var passes: Bool { WaterGate.passes(score) }
}

/// What made a model's output, as the model's runner reports it: a converted model is named by its recipe and weights, and
/// a canary frame's output hash, since its file's bytes differ from one conversion to the next (S1b, S5). It goes into the
/// seed's provenance; nothing reads it to make a seed again.
public struct ModelProvenance: Sendable, Equatable, Codable {
    /// The pinned recipe's id, `eomt-dinov3-l-ade150-sq768-f16-maps3-1` for EoMT.
    public var recipeID: String
    public var weightsSHA256: String
    /// The canary frame's output hash: for EoMT the CC0 sample DSC06673's maps, `63bdb66c…`.
    public var canarySHA256: String
    /// The shipped file's `main.mlirb` SHA-256: it names a file, not a model.
    public var fileSHA256: String
    /// Core AI's `SpecializationOptions`, `default` for both models.
    public var options: String

    public init(recipeID: String, weightsSHA256: String, canarySHA256: String, fileSHA256: String, options: String = "default") {
        self.recipeID = recipeID; self.weightsSHA256 = weightsSHA256; self.canarySHA256 = canarySHA256
        self.fileSHA256 = fileSHA256; self.options = options
    }
}

/// DA3's sky seed on its own grid: the sky head cropped from the padded 756 × 756 square to the picture, 756 × 504 for a
/// landscape and 504 × 756 for a portrait, as `clip(sky, 0, 0.6) / 0.6` (R4, R9), row 0 at the picture's top. The crop is the
/// runner's; the clip is here so the seed's meaning is pinned in one place.
public struct SkySeed: Sendable, Equatable {
    /// R4's cap: the sky head reaches about 0.6 on sky, so the seed is 1 there.
    public static let clip: Float = 0.6

    public let width: Int
    public let height: Int
    /// 0 to 1.
    public let values: [Float]
    public let model: ModelProvenance
    /// The square the model saw (`ModelSquare.recipe`, `SkyOutputs.squareRecipe`), recorded as `model.square`; `nil` for a seed from
    /// elsewhere, which records none, as every seed cut from the edge-repeated square did.
    public let square: String?

    public init(width: Int, height: Int, values: [Float], model: ModelProvenance, square: String? = nil) throws {
        guard RasterRef.sideRange.contains(width), RasterRef.sideRange.contains(height), values.count == width * height else {
            throw MaskError.invalid("a sky seed is width times height values")
        }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { throw MaskError.invalid("a sky seed's values are 0 to 1") }
        self.width = width; self.height = height; self.values = values; self.model = model; self.square = square
    }

    /// The seed from the sky head's output, already cropped to the picture.
    public init(skyHead: [Float], width: Int, height: Int, model: ModelProvenance, square: String? = nil) throws {
        try self.init(width: width, height: height,
                      values: skyHead.map { $0.isNaN ? 0 : min(max($0, 0), Self.clip) / Self.clip }, model: model, square: square)
    }

    func with(values: [Float]) -> SkySeed { SkySeed(width: width, height: height, checked: values, model: model, square: square) }
    private init(width: Int, height: Int, checked values: [Float], model: ModelProvenance, square: String?) {
        self.width = width; self.height = height; self.values = values; self.model = model; self.square = square
    }
}

/// EoMT's water map as its runner returns it: the summed probability of ADE20K's water, sea, river, lake, waterfall, swimming
/// pool and fountain classes on the model's output grid, `side` × `side` (192), which covers the padded `square` × `square`
/// input (768) at a quarter of its resolution, row 0 at the top; and where the picture lies in that square, in input pixels.
public struct WaterMap: Sendable, Equatable {
    public let side: Int
    public let values: [Float]
    public let square: Int
    public let contentWidth: Int
    public let contentHeight: Int
    public let originX: Int
    public let originY: Int
    public let model: ModelProvenance
    /// SHA-256 of the fp16 `maps` output as returned, all three channels.
    public let mapsSHA256: String

    public init(side: Int, values: [Float], square: Int, contentWidth: Int, contentHeight: Int, originX: Int, originY: Int,
                model: ModelProvenance, mapsSHA256: String) throws {
        guard side > 1, values.count == side * side, square >= side, square % side == 0 else {
            throw MaskError.invalid("a water map is side times side values over a square a whole multiple of it")
        }
        guard contentWidth > 0, contentHeight > 0, originX >= 0, originY >= 0,
              originX + contentWidth <= square, originY + contentHeight <= square else {
            throw MaskError.invalid("a water map's picture lies inside its square")
        }
        self.side = side; self.values = values; self.square = square
        self.contentWidth = contentWidth; self.contentHeight = contentHeight; self.originX = originX; self.originY = originY
        self.model = model; self.mapsSHA256 = mapsSHA256
    }
}

/// The water veto (`water-veto-1`): behind the gate, the seed pixels that are selected and that EoMT calls water, opened 3 × 3,
/// are removed if together they cover 1 % of the seed, with the unselected seed pixels within 6 px of them and every seed value
/// where water is at least 0.5 (masking plan section 3, S5 section 4).
///
/// Every constant was set or checked on S4's set (S5 section 3.3): the gate, the minimum and the opening by S4; the selected
/// level and the fringe from R9's refinement; the water threshold swept from 0.3 to 0.9 on a plateau; the soft clear chosen by
/// S5 after two frames' faint blotch at −1.5 EV. A change to any of them is a new `version`, since a stored seed records the
/// version it was cut with.
public enum WaterVeto {
    public static let version = "water-veto-1"
    /// The gate: `WaterGate.threshold`.
    public static let gate = WaterGate.threshold
    /// A seed pixel is selected at or above this (SEL).
    public static let selected: Float = 0.5
    /// EoMT calls a pixel water at or above this (WATER_THR): "more likely water than not". The reflections' outcome is the
    /// same from 0.3 to 0.9; at 0.7 and up the hazy band under `a3755`'s sea horizon would stay with the sky (S5, question 1).
    public static let waterThreshold: Float = 0.5
    /// The opened candidates act only if they cover this share of the seed's pixels (AMIN): without it 17 stray fires on S4's
    /// audit instead of 2. It is the owner's own bar, under 1 % of the frame. A `Double`, as S5's reference compares it.
    public static let minimumShare: Double = 0.01
    /// The opening's square, erosion then dilation (OPENING).
    public static let opening = 3
    /// The fringe cleared around the vetoed pixels, in seed pixels: the refiner's radius at the seed grid, as a 13 × 13 ellipse,
    /// OpenCV's `MORPH_ELLIPSE` (FRINGE), so no half-lit rim can seed the refinement.
    public static let fringeRadius = 6
    /// The constants in one line, as the provenance records them.
    public static let constants = "gate 0.03; sel 0.5; water 0.5; amin 0.01; opening 3x3; fringe 6 (13x13 ellipse); clear-soft"

    /// What the veto did to one seed, for the seed's provenance (`parameters`): the gate's score, whether EoMT ran and the veto
    /// fired, what it removed, and the seed before it, so an Update can say what was removed.
    public struct Decision: Sendable, Equatable {
        public var gate: WaterScore
        /// EoMT ran: the gate passed and the water map was asked for.
        public var ran: Bool
        public var fired: Bool
        /// The opened candidates' share of the seed's pixels, before the 1 % minimum; 0 when EoMT did not run.
        public var candidateShare: Double
        /// The vetoed region's pixels: selected, on water, opened. 0 unless it fired.
        public var removedPixels: Int
        /// The share of the seed's pixels selected before the veto and not after.
        public var removedSelectedShare: Double
        /// The seed values removed, summed, over the seed's pixels: soft values included.
        public var removedSoftShare: Double
        /// The identity of the seed before the veto, quantized as it would have been stored (`MaskRaster.identity`).
        public var seedBefore: RasterID
        /// The water map's model and output hash, when EoMT ran.
        public var waterModel: ModelProvenance?
        public var mapsSHA256: String?

        public init(gate: WaterScore, ran: Bool, fired: Bool, candidateShare: Double, removedPixels: Int,
                    removedSelectedShare: Double, removedSoftShare: Double, seedBefore: RasterID,
                    waterModel: ModelProvenance? = nil, mapsSHA256: String? = nil) {
            self.gate = gate; self.ran = ran; self.fired = fired; self.candidateShare = candidateShare
            self.removedPixels = removedPixels; self.removedSelectedShare = removedSelectedShare
            self.removedSoftShare = removedSoftShare; self.seedBefore = seedBefore
            self.waterModel = waterModel; self.mapsSHA256 = mapsSHA256
        }
    }

    /// Gates and vetoes a Sky seed. `water` runs EoMT and is called only when Vision's score passes the gate, so a frame below
    /// it never loads the model. The seed comes back unchanged unless the veto fires.
    public static func apply(to seed: SkySeed, gate score: WaterScore,
                             water: () async throws -> WaterMap) async rethrows -> (seed: SkySeed, decision: Decision) {
        let before = quantize(seed.values, width: seed.width, height: seed.height).identity
        guard score.passes else {
            return (seed, Decision(gate: score, ran: false, fired: false, candidateShare: 0, removedPixels: 0,
                                   removedSelectedShare: 0, removedSoftShare: 0, seedBefore: before))
        }
        let map = try await water()
        let onSeed = resample(map, toWidth: seed.width, height: seed.height)
        let (veto, share) = candidates(seed: seed.values, water: onSeed, width: seed.width, height: seed.height)
        let fired = veto.contains(true)
        let out = fired ? clear(seed: seed.values, veto: veto, water: onSeed, width: seed.width, height: seed.height) : seed.values
        var removedSelected = 0, removedMass = 0.0
        for i in seed.values.indices {
            if seed.values[i] >= selected && out[i] < selected { removedSelected += 1 }
            removedMass += Double(seed.values[i] - out[i])
        }
        let n = Double(seed.values.count)
        let decision = Decision(gate: score, ran: true, fired: fired, candidateShare: share,
                                removedPixels: fired ? veto.reduce(0) { $0 + ($1 ? 1 : 0) } : 0,
                                removedSelectedShare: Double(removedSelected) / n, removedSoftShare: removedMass / n,
                                seedBefore: before, waterModel: map.model, mapsSHA256: map.mapsSHA256)
        return (fired ? seed.with(values: out) : seed, decision)
    }

    // MARK: the rule's parts, on the seed grid

    /// The water map on the seed grid: bilinear at each seed pixel's centre, through the picture's rectangle in the square,
    /// `y = (top + (i + 0.5) h / seedHeight) / 4 − 0.5` and likewise for x, edges replicated (S5's `EomtInput.resample`, which
    /// matches OpenCV's `remap` to under 1e-5).
    public static func resample(_ map: WaterMap, toWidth sw: Int, height sh: Int) -> [Float] {
        var out = [Float](repeating: 0, count: sw * sh)
        let side = map.side, k = Double(map.square) / Double(side)
        map.values.withUnsafeBufferPointer { m in
            for y in 0..<sh {
                var fy = (Double(map.originY) + (Double(y) + 0.5) * Double(map.contentHeight) / Double(sh)) / k - 0.5
                fy = min(max(fy, 0), Double(side - 1))
                let y0 = Int(fy.rounded(.down)), y1 = min(y0 + 1, side - 1), wy = Float(fy - Double(y0))
                for x in 0..<sw {
                    var fx = (Double(map.originX) + (Double(x) + 0.5) * Double(map.contentWidth) / Double(sw)) / k - 0.5
                    fx = min(max(fx, 0), Double(side - 1))
                    let x0 = Int(fx.rounded(.down)), x1 = min(x0 + 1, side - 1), wx = Float(fx - Double(x0))
                    let a = m[y0 * side + x0], b = m[y0 * side + x1], c = m[y1 * side + x0], d = m[y1 * side + x1]
                    out[y * sw + x] = (a * (1 - wx) + b * wx) * (1 - wy) + (c * (1 - wx) + d * wx) * wy
                }
            }
        }
        return out
    }

    /// The pixels to veto: selected seed pixels whose water is at least the threshold, opened 3 × 3, and none unless they
    /// cover `minimumShare` of the seed. Returns them and their share before the minimum.
    public static func candidates(seed: [Float], water: [Float], width w: Int, height h: Int) -> (mask: [Bool], share: Double) {
        var v = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) { v[i] = seed[i] >= selected && water[i] >= waterThreshold }
        let opened = dilate3x3(erode3x3(v, width: w, height: h), width: w, height: h)
        let count = opened.reduce(0) { $0 + ($1 ? 1 : 0) }
        let share = Double(count) / Double(w * h)
        return share >= minimumShare ? (opened, share) : ([Bool](repeating: false, count: w * h), share)
    }

    /// The seed once the veto fires: zero on the vetoed pixels, on the unselected pixels within the fringe of them, and on every
    /// pixel where water is at least the threshold (CLEAR_SOFT), since DA3's soft values on water become coverage through the
    /// refinement (a faint blotch at −1.5 EV on `a1017` and `DSC04073`, S5).
    public static func clear(seed: [Float], veto: [Bool], water: [Float], width w: Int, height h: Int) -> [Float] {
        guard veto.contains(true) else { return seed }
        let grow = dilateEllipse(veto, width: w, height: h, radius: fringeRadius)
        var out = seed
        for i in 0..<(w * h) where (grow[i] && seed[i] < selected) || veto[i] || water[i] >= waterThreshold { out[i] = 0 }
        return out
    }

    /// The seed as an 8-bit raster, as it is stored: `round(v × 255)`, half to even.
    public static func quantize(_ values: [Float], width: Int, height: Int) -> MaskRaster {
        try! MaskRaster(width: width, height: height,
                        plane: values.map { UInt8(min(max(($0 * 255).rounded(.toNearestOrEven), 0), 255)) })
    }

    // MARK: morphology, OpenCV's borders

    /// Half-widths of OpenCV's elliptical structuring element of diameter 2r + 1 (`getStructuringElement(MORPH_ELLIPSE)`), one a
    /// row offset from −r to r.
    static func ellipseHalfWidths(radius r: Int) -> [Int] {
        let inverse = r > 0 ? 1.0 / Double(r * r) : 0
        return (0...(2 * r)).map { i in
            let dy = i - r
            return Int((Double(r) * (Double(r * r - dy * dy) * inverse).squareRoot()).rounded(.toNearestOrEven))
        }
    }

    /// 3 × 3 erosion, the outside counting as set (OpenCV's default border for erosion).
    static func erode3x3(_ m: [Bool], width w: Int, height h: Int) -> [Bool] {
        var tmp = [Bool](repeating: true, count: w * h), out = [Bool](repeating: true, count: w * h)
        for y in 0..<h { for x in 0..<w {
            var v = true
            for dx in -1...1 { let xx = x + dx; if xx >= 0 && xx < w && !m[y * w + xx] { v = false; break } }
            tmp[y * w + x] = v
        } }
        for y in 0..<h { for x in 0..<w {
            var v = true
            for dy in -1...1 { let yy = y + dy; if yy >= 0 && yy < h && !tmp[yy * w + x] { v = false; break } }
            out[y * w + x] = v
        } }
        return out
    }

    /// 3 × 3 dilation, the outside counting as clear.
    static func dilate3x3(_ m: [Bool], width w: Int, height h: Int) -> [Bool] {
        var tmp = [Bool](repeating: false, count: w * h), out = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w {
            var v = false
            for dx in -1...1 { let xx = x + dx; if xx >= 0 && xx < w && m[y * w + xx] { v = true; break } }
            tmp[y * w + x] = v
        } }
        for y in 0..<h { for x in 0..<w {
            var v = false
            for dy in -1...1 { let yy = y + dy; if yy >= 0 && yy < h && tmp[yy * w + x] { v = true; break } }
            out[y * w + x] = v
        } }
        return out
    }

    /// Dilation by the elliptical element, the outside counting as clear.
    static func dilateEllipse(_ m: [Bool], width w: Int, height h: Int, radius r: Int) -> [Bool] {
        let half = ellipseHalfWidths(radius: r)
        var out = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w where m[y * w + x] {
                for i in 0...(2 * r) {
                    let yy = y + i - r
                    if yy < 0 || yy >= h { continue }
                    let x0 = max(x - half[i], 0), x1 = min(x + half[i], w - 1)
                    if x0 <= x1 { for xx in x0...x1 { out[yy * w + xx] = true } }
                }
            }
        }
        return out
    }
}

// MARK: provenance

extension WaterScore {
    /// The score as a seed's provenance records it, under `gate.`.
    public var parameters: [String: String] {
        var p = ["gate.engine": Self.engine, "gate.revision": String(Self.revision), "gate.threshold": "\(WaterGate.threshold)",
                 "gate.score": "\(score)"]
        p["gate.labels"] = WaterGate.identifiers.map { "\($0) \(labels[$0] ?? 0)" }.joined(separator: "; ")
        return p
    }

    /// The score a provenance recorded, or `nil` if it holds none.
    public init?(parameters p: [String: String]) {
        guard let text = p["gate.labels"] else { return nil }
        var labels: [String: Float] = [:]
        for entry in text.split(separator: ";") {
            let parts = entry.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, let value = Float(parts[1]) else { return nil }
            labels[String(parts[0])] = value
        }
        self.init(labels: labels)
        guard p["gate.score"].flatMap(Float.init) == score else { return nil }
    }
}

extension ModelProvenance {
    func parameters(prefix: String) -> [String: String] {
        ["\(prefix).recipe": recipeID, "\(prefix).weights": weightsSHA256, "\(prefix).canary": canarySHA256,
         "\(prefix).file": fileSHA256, "\(prefix).options": options]
    }

    init?(parameters p: [String: String], prefix: String) {
        guard let recipe = p["\(prefix).recipe"], let weights = p["\(prefix).weights"], let canary = p["\(prefix).canary"],
              let file = p["\(prefix).file"], let options = p["\(prefix).options"] else { return nil }
        self.init(recipeID: recipe, weightsSHA256: weights, canarySHA256: canary, fileSHA256: file, options: options)
    }
}

extension WaterVeto.Decision {
    /// The decision as a seed's provenance records it: the veto's version and constants under `veto`, the gate under `gate.`,
    /// and EoMT's identity and output under `eomt.` when it ran (S5 section 4).
    public var parameters: [String: String] {
        var p = gate.parameters
        p["veto"] = WaterVeto.version
        p["veto.constants"] = WaterVeto.constants
        p["veto.ran"] = String(ran)
        p["veto.fired"] = String(fired)
        p["veto.candidateShare"] = "\(candidateShare)"
        p["veto.removedPixels"] = String(removedPixels)
        p["veto.removedSelectedShare"] = "\(removedSelectedShare)"
        p["veto.removedSoftShare"] = "\(removedSoftShare)"
        p["veto.seedBefore"] = seedBefore.hex
        if let waterModel { p.merge(waterModel.parameters(prefix: "eomt")) { a, _ in a } }
        if let mapsSHA256 { p["eomt.maps"] = mapsSHA256 }
        return p
    }

    /// The decision a provenance recorded, or `nil` if it holds none or one of another version.
    public init?(parameters p: [String: String]) {
        guard p["veto"] == WaterVeto.version, let gate = WaterScore(parameters: p),
              let ran = p["veto.ran"].flatMap(Bool.init), let fired = p["veto.fired"].flatMap(Bool.init),
              let candidate = p["veto.candidateShare"].flatMap(Double.init), let pixels = p["veto.removedPixels"].flatMap(Int.init),
              let selected = p["veto.removedSelectedShare"].flatMap(Double.init),
              let soft = p["veto.removedSoftShare"].flatMap(Double.init),
              let before = p["veto.seedBefore"].flatMap(RasterID.init(hex:)) else { return nil }
        self.init(gate: gate, ran: ran, fired: fired, candidateShare: candidate, removedPixels: pixels,
                  removedSelectedShare: selected, removedSoftShare: soft, seedBefore: before,
                  waterModel: ModelProvenance(parameters: p, prefix: "eomt"), mapsSHA256: p["eomt.maps"])
    }
}
