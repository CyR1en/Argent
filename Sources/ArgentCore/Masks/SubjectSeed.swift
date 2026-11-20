import Foundation

/// The new Subject's frozen design (research tasks V3 to V7, X1 to X3, Y2, Z1; docs/masking-plan.md decisions 19 to 24): S3OD-sod's region on every click, the EoMT "no subject" gate
/// only when Vision's foreground instances found nothing, the 1024 seed and, inside X1's low-light rule, Vision's fallback, the hole fill and ViTMatte's alpha. Every constant is the
/// research's and may not change; what chose each is in docs/provenance.md.
public enum SubjectDesign {
    /// What a seed's provenance names as its design; a change of meaning is a new version.
    public static let version = "v7-x3-z1-1"
    /// A pixel of S3OD's mask is selected at or above half.
    public static let select: Float = 0.5
    /// "Found nothing": the selection under 0.1 % of the frame.
    public static let found = 0.001
    /// EoMT's most probable classes that mean there is no subject (V3's `STUFF_NAMES` as ADE20K-150 indices).
    public static let stuff: Set<Int> = [0, 2, 3, 4, 5, 6, 9, 11, 13, 16, 17, 21, 26, 29, 34, 46, 52, 53, 54, 59, 60, 68, 72, 91, 94, 128]
    /// The gate rejects a selection when more than this share of it is stuff.
    public static let stuffMaximum = 0.80
    /// A hole is filled when at least this share of its pixels lie in Vision's foreground.
    public static let cover = 0.9

    /// The stuff share of the `selected` mask (content-sized, `layout`'s) by EoMT's most probable class at 192 cells on its padded 768 square, resampled nearest to the selection's
    /// grid (V4's measure).
    public static func stuffShare(selected: [Float], layout: ModelSquareLayout, maps: EomtMaps) -> Double {
        let cell = maps.layout.side / EomtModelRunner.mapSide
        let x0 = Int((Double(maps.layout.originX) / Double(cell)).rounded()), y0 = Int((Double(maps.layout.originY) / Double(cell)).rounded())
        let mw = max(1, Int((Double(maps.layout.contentWidth) / Double(cell)).rounded())), mh = max(1, Int((Double(maps.layout.contentHeight) / Double(cell)).rounded()))
        let cw = layout.contentWidth, ch = layout.contentHeight
        var stuff = 0, on = 0
        for y in 0..<ch {
            let my = min(mh - 1, Int((Double(y) + 0.5) * Double(mh) / Double(ch))) + y0
            for x in 0..<cw where selected[y * cw + x] >= select {
                on += 1
                let mx = min(mw - 1, Int((Double(x) + 0.5) * Double(mw) / Double(cw))) + x0
                if Self.stuff.contains(Int(maps.classIndex[my * EomtModelRunner.mapSide + mx])) { stuff += 1 }
            }
        }
        return on > 0 ? Double(stuff) / Double(on) : 0
    }

    /// Hole fill inside the low-light rule, X2's design: on the 8-bit S3OD seed, each 4-connected component of pixels under 128 that touches no edge of the frame is set to 255 when at
    /// least `cover` of its pixels lie in Vision's foreground (labels > 0, nearest neighbour to the seed's grid). Without a Vision foreground the seed stands. `vision` is Vision's seed
    /// plane, 0 or 255.
    public static func fillHoles(seed: [UInt8], width w: Int, height h: Int, vision: MaskRaster?) -> [UInt8] {
        guard let vision else { return seed }
        let visionOnSeed = nearestNeighbour(vision.plane, width: vision.width, height: vision.height, toWidth: w, height: h)
        var out = seed
        var visited = [Bool](repeating: false, count: w * h)
        var stack = [Int]()
        for start in 0..<(w * h) where seed[start] < 128 && !visited[start] {
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = true
            var component: [Int] = [], touchesEdge = false, inVision = 0
            while let i = stack.popLast() {
                component.append(i)
                let x = i % w, y = i / w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touchesEdge = true }
                if visionOnSeed[i] > 0 { inVision += 1 }
                if x > 0, seed[i - 1] < 128, !visited[i - 1] { visited[i - 1] = true; stack.append(i - 1) }
                if x < w - 1, seed[i + 1] < 128, !visited[i + 1] { visited[i + 1] = true; stack.append(i + 1) }
                if y > 0, seed[i - w] < 128, !visited[i - w] { visited[i - w] = true; stack.append(i - w) }
                if y < h - 1, seed[i + w] < 128, !visited[i + w] { visited[i + w] = true; stack.append(i + w) }
            }
            guard !touchesEdge, Double(inVision) / Double(component.count) >= cover else { continue }
            for i in component { out[i] = 255 }
        }
        return out
    }

    /// OpenCV's `INTER_NEAREST` from `width` by `height` to `toWidth` by `toHeight`: sampled at `floor(i × 1 / (toW / w))`, clamped.
    static func nearestNeighbour(_ plane: [UInt8], width w: Int, height h: Int, toWidth W: Int, height H: Int) -> [UInt8] {
        let fx = Double(W) / Double(w), fy = Double(H) / Double(h)
        let ifx = 1.0 / fx, ify = 1.0 / fy
        let xs = (0..<W).map { min(Int((Double($0) * ifx).rounded(.down)), w - 1) }
        let ys = (0..<H).map { min(Int((Double($0) * ify).rounded(.down)), h - 1) }
        var out = [UInt8](repeating: 0, count: W * H)
        for y in 0..<H {
            let row = ys[y] * w
            for x in 0..<W { out[y * W + x] = plane[row + xs[x]] }
        }
        return out
    }
}

extension SmartSeed {
    /// The steps the click needs from the models, as a seam: the engine's are the bundled ones, a test's are fakes.
    public struct SubjectModels: Sendable {
        public var region: ModelProvenance
        public var gate: ModelProvenance
        public var matte: ModelProvenance
        /// S3OD's masks for the click's picture: loaded, run and let go.
        public var runRegion: @Sendable () async throws -> S3odOutputs
        /// EoMT's maps for the click's picture: loaded, run and let go. Only when Vision found nothing.
        public var runGate: @Sendable () async throws -> EomtMaps
        /// ViTMatte's alpha for a seed: loaded, run and let go. Only inside the rule.
        public var runMatte: @Sendable (MaskRaster) async throws -> SubjectMatte.Result

        public init(region: ModelProvenance, gate: ModelProvenance, matte: ModelProvenance, runRegion: @escaping @Sendable () async throws -> S3odOutputs,
                    runGate: @escaping @Sendable () async throws -> EomtMaps, runMatte: @escaping @Sendable (MaskRaster) async throws -> SubjectMatte.Result) {
            self.region = region; self.gate = gate; self.matte = matte
            self.runRegion = runRegion; self.runGate = runGate; self.runMatte = runMatte
        }
    }

    /// The whole Subject click after Vision has run: S3OD's region, the gate where Vision found nothing, the selection, and inside the rule the fallback, hole fill and matte. Provenance on
    /// the seed names every recipe, weight and decision. Vision's result is `vision`, as `AppleSegmentation.subject` returned it for this picture.
    public static func subject(vision: SmartResult, picture: AppleSegmentation.Picture, source: SeedSource, rule: LowLightRule.Decision, models: SubjectModels) async throws -> SmartResult {
        let visionRaster = vision.seed?.raster
        let visionFound = visionRaster != nil
        let visionPlane = visionRaster?.plane ?? []
        let visionShare = visionFound ? Double(visionPlane.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }) / Double(visionPlane.count) : 0

        let outputs = try await models.runRegion()
        let k = outputs.selectedIndex
        let selected = outputs.selectedContent, layout = outputs.layout
        let (cw, ch) = (layout.contentWidth, layout.contentHeight)
        let on = selected.reduce(0) { $0 + ($1 >= SubjectDesign.select ? 1 : 0) }
        let share = Double(on) / Double(cw * ch)

        var keep = share >= SubjectDesign.found
        var why = keep ? "kept" : "empty"
        var parameters = rule.parameters
        parameters.merge(models.region.parameters(prefix: "model")) { a, _ in a }
        parameters["design"] = SubjectDesign.version
        parameters["model.square"] = S3odModelRunner.squareRecipe
        parameters["seed"] = "s3od-sod masks[argmax iou], content of the 1024 square, black padded, 8 bits"
        parameters["iou"] = outputs.iou.map { String(Double($0)) }.joined(separator: ",")
        parameters["iou.argmax"] = String(k)
        parameters["selected.share"] = String(share)
        parameters["select"] = String(SubjectDesign.select)
        parameters["found"] = String(SubjectDesign.found)
        parameters["vision.found"] = String(visionFound)
        parameters["gate.ran"] = String(!visionFound)
        parameters["gate.stuffMax"] = String(SubjectDesign.stuffMaximum)

        if !visionFound {
            let maps = try await models.runGate()
            parameters.merge(models.gate.parameters(prefix: "eomt")) { a, _ in a }
            let stuff = SubjectDesign.stuffShare(selected: selected, layout: layout, maps: maps)
            parameters["gate.stuffShare"] = String(stuff)
            if stuff > SubjectDesign.stuffMaximum {
                keep = false
                why = "gate"
            }
        }
        parameters["selection"] = why

        let provenance: (String) -> RasterProvenance = { outcome in
            var parameters = parameters
            parameters["outcome"] = outcome
            return source.provenance(engine: "coreai:\(models.region.recipeID)", revision: "\(models.region.recipeID)@sha256:\(models.region.weightsSHA256)",
                                     parameters: parameters, picture: picture)
        }

        let frozenSeed = keep ? selected.map { UInt8((min(max($0, 0), 1) * 255).rounded()) } : nil
        if let frozenSeed { parameters["seed.frozen"] = try MaskRaster(width: cw, height: ch, plane: frozenSeed).identity.hex }
        if !rule.inRule {
            guard let frozenSeed else { return .nothingFound(.subject, provenance("none (\(why))")) }
            let raster = try MaskRaster(width: cw, height: ch, plane: frozenSeed)
            parameters["edge"] = SmartEdge.crisp.rawValue
            parameters["seed.identity"] = raster.identity.hex
            return .seed(SmartSeed(kind: .subject, raster: raster, provenance: provenance("rule off"), edge: .crisp))
        }

        // Inside the rule: Vision's fallback when the selection was empty, the hole fill on S3OD's seed, then the matte on either.
        var seed: MaskRaster
        var outcome: String
        if let frozenSeed {
            let filled = SubjectDesign.fillHoles(seed: frozenSeed, width: cw, height: ch, vision: visionRaster)
            seed = try MaskRaster(width: cw, height: ch, plane: filled)
            outcome = "fill"
        } else if why == "empty", visionFound, let visionRaster, visionShare >= SubjectDesign.found {
            seed = visionRaster
            outcome = "vision fallback"
        } else {
            return .nothingFound(.subject, provenance("none (\(why))"))
        }

        parameters["seed.identity"] = seed.identity.hex
        let matte = try await models.runMatte(seed)
        parameters["edge"] = SmartEdge.matte.rawValue
        parameters.merge(models.matte.parameters(prefix: "matte")) { a, _ in a }
        parameters["matte.design"] = SubjectMatte.version
        parameters["matte.tiles"] = String(matte.tiles)
        parameters["matte.unknown"] = String(matte.unknownShare)
        return .seed(SmartSeed(kind: .subject, raster: matte.alpha, provenance: provenance(outcome), edge: .matte))
    }
}
