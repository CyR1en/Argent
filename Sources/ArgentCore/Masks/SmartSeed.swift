import Foundation

// A smart mask's seed is a measurement stored with the edit (masking plan section 3, "Why store the result"): the 8-bit raster a
// model returned, at the model's own size, and what made it. Apple's segmentation requests have one revision each and a
// converted model is tied to the OS build, so nothing can be pinned but the pixels: a saved seed is never made again by itself.
//
// What each kind stores (plan section 4's refinement table):
//
//   Sky         DA3's sky head, clip(sky, 0, 0.6) / 0.6, cropped from the padded square: 756 × 504 (504 × 756 portrait),
//               after the water veto. Soft, 0 to 255.
//   Person      Vision's .accurate matte as returned: 2016 × 1512 for a landscape, stretched over the whole frame. Soft.
//   Subject     S3OD-sod's argmax-IoU mask at 1024 on the long side, soft, with a `crisp` edge; inside the low-light rule ViTMatte's alpha at the
//               click print's size (2560 on the long side), 8 bits, with a `matte` edge (`SmartEdge`). Where the models are absent, Vision's foreground
//               label map, every instance 255, 512 × 512 over the whole frame, with today's `guided` edge. (`SubjectDesign`.)
//   Background  Subject's raster, read as 1 − v. The same raster id, provenance and edge, not a second raster.
//
// Every plane's row 0 is the picture's top row, as Vision's buffers and the models' outputs are; the coverage field flips once
// at upload (`MaskSpace`).

/// A seed ready to store: its kind, its pixels and what made them. The raster's identity names it in the store and in
/// `MaskNotes.rasters`, under which the provenance goes.
public struct SmartSeed: Sendable, Equatable {
    /// A seed pixel is selected at or above half: 128 of 255. A seed with none is no seed (`SmartResult.nothingFound`).
    public static let selectedLevel: UInt8 = 128

    public let kind: SmartKind
    public let raster: MaskRaster
    public let provenance: RasterProvenance
    /// The edge the click decided for this seed (`SmartEdge`, decided once and stored); `.guided` for every Person and Sky seed.
    public let edge: SmartEdge

    public init(kind: SmartKind, raster: MaskRaster, provenance: RasterProvenance, edge: SmartEdge = .guided) {
        self.kind = kind; self.raster = raster; self.provenance = provenance; self.edge = edge
    }

    /// The component's selection once the seed is stored, with the frame it was made on (`MaskFrame`).
    public func selection(frame: MaskFrame) -> SmartSelection { SmartSelection(kind: kind, raster: raster.ref, frame: frame, edge: edge) }

    /// The Sky seed after the water veto, quantized as it is stored, with the veto's decision in its provenance;
    /// `.nothingFound` when no pixel is selected, the veto's removal included.
    public static func sky(_ seed: SkySeed, decision: WaterVeto.Decision, picture: AppleSegmentation.Picture,
                           source: SeedSource) -> SmartResult {
        var parameters = decision.parameters
        parameters["seed"] = "clip(sky, 0, \(SkySeed.clip)) / \(SkySeed.clip), cropped from the square"
        parameters.merge(seed.model.parameters(prefix: "model")) { a, _ in a }
        if let square = seed.square { parameters["model.square"] = square }
        let provenance = source.provenance(engine: "coreai:\(seed.model.recipeID)",
                                           revision: "\(seed.model.recipeID)@sha256:\(seed.model.weightsSHA256)",
                                           parameters: parameters, picture: picture)
        let raster = WaterVeto.quantize(seed.values, width: seed.width, height: seed.height)
        guard raster.plane.contains(where: { $0 >= selectedLevel }) else { return .nothingFound(.sky, provenance) }
        return .seed(SmartSeed(kind: .sky, raster: raster, provenance: provenance))
    }

    /// The whole Sky click after DA3: Vision's gate, the veto (which calls `water`, and so loads EoMT, only behind the gate),
    /// then the seed to store.
    public static func sky(_ seed: SkySeed, picture: AppleSegmentation.Picture, source: SeedSource, gate: WaterScore,
                           water: () async throws -> WaterMap) async rethrows -> SmartResult {
        let (vetoed, decision) = try await WaterVeto.apply(to: seed, gate: gate, water: water)
        return sky(vetoed, decision: decision, picture: picture, source: source)
    }
}

/// What a smart request returns. Finding nothing is a result, shown as a quiet state in the mask's row, never an error
/// (plan section 5).
public enum SmartResult: Sendable, Equatable {
    case seed(SmartSeed)
    /// Nothing of the kind in the frame, with the provenance of what was run.
    case nothingFound(SmartKind, RasterProvenance)

    public var seed: SmartSeed? { if case .seed(let seed) = self { return seed } else { return nil } }
    public var kind: SmartKind {
        switch self {
        case .seed(let seed): return seed.kind
        case .nothingFound(let kind, _): return kind
        }
    }
    public var provenance: RasterProvenance {
        switch self {
        case .seed(let seed): return seed.provenance
        case .nothingFound(_, let provenance): return provenance
        }
    }

    /// The row's words for an empty result, the plan's "No sky found in this frame" and its siblings.
    public static func nothingFoundMessage(_ kind: SmartKind) -> String {
        switch kind {
        case .sky: return "No sky found in this frame"
        case .subject: return "No subject found in this frame"
        case .person: return "No people found in this frame"
        case .background: return "No subject found in this frame, so no background"
        }
    }
}

/// What the caller knows of a seed's picture and no engine sees: the raw and the decode behind the neutral print, and where and
/// when the seed was made. With the picture's own size and digest it becomes the seed's `RasterProvenance`.
public struct SeedSource: Sendable, Equatable {
    /// `RasterProvenance.Input.kind` for every seed: the frame's own decode through `LUT3D.neutralPrint` (plan section 3).
    public static let inputKind = "neutral-print"

    /// The raw's SHA-256.
    public var sourceSHA256: String
    /// `DecodePins.decoderVersion` and `DecodePins.currentVersion` of the decode the print came from.
    public var decoderVersion: String?
    public var pinsVersion: String?
    public var app: String
    public var created: Date
    /// `ProcessInfo.operatingSystemVersionString` where the seed was made, as the disk cache keys Apple's decodes.
    public var operatingSystem: String

    public init(sourceSHA256: String, decoderVersion: String? = nil, pinsVersion: String? = nil, app: String,
                created: Date = Date(), operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString) {
        self.sourceSHA256 = sourceSHA256; self.decoderVersion = decoderVersion; self.pinsVersion = pinsVersion
        self.app = app; self.created = created; self.operatingSystem = operatingSystem
    }

    /// The seed's provenance: the engine and its revision, the request's parameters, and the input picture, whose digest is
    /// `input.sha256` (`AppleSegmentation.Picture.sha256`).
    func provenance(engine: String, revision: some CustomStringConvertible, parameters: [String: String],
                    picture: AppleSegmentation.Picture) -> RasterProvenance {
        var parameters = parameters
        parameters["input.sha256"] = picture.sha256
        return RasterProvenance(engine: engine, engineRevision: revision.description, parameters: parameters,
                                operatingSystem: operatingSystem, app: app,
                                input: .init(kind: Self.inputKind, decoderVersion: decoderVersion, pinsVersion: pinsVersion,
                                             width: picture.width, height: picture.height, colorSpace: "sRGB",
                                             sourceSHA256: sourceSHA256),
                                created: created)
    }
}
