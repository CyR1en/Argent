import ArgentCore
import Foundation

extension PrintAim: Codable {
    private enum CodingKeys: String, CodingKey { case level, cast, burn, dodge }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let level = try values.decode(Float.self, forKey: .level)
        let cast = try values.decode([Float].self, forKey: .cast)
        // Absent from every aim before the tone step: those prints stay as they were.
        let burn = try values.decodeIfPresent(Float.self, forKey: .burn) ?? 0
        let dodge = try values.decodeIfPresent(Float.self, forKey: .dodge) ?? 0
        guard level.isFinite, cast.count == 3, cast.allSatisfy(\.isFinite) else {
            throw DecodingError.dataCorruptedError(forKey: .cast, in: values, debugDescription: "Automatic aim must contain finite RGB values.")
        }
        guard burn.isFinite, dodge.isFinite, burn >= 0, dodge >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .burn, in: values, debugDescription: "Automatic aim's tone step must be finite, zero or more.")
        }
        self.init(level: level, cast: SIMD3(cast[0], cast[1], cast[2]), burn: burn, dodge: dodge)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(level, forKey: .level)
        try values.encode([cast.x, cast.y, cast.z], forKey: .cast)
        if burn != 0 { try values.encode(burn, forKey: .burn) }
        if dodge != 0 { try values.encode(dodge, forKey: .dodge) }
    }
}

/// Where a frame's refinements start: the automatic decisions that were visible when its first
/// refinement began, or, chosen in the inspector, its Original (docs/manual-development.md,
/// "Starting from Original").
public struct AutomaticBaseline: Sendable, Equatable, Codable {
    /// What the pin is of. Recorded, never inferred from its aim: an Auto pin can sit at the neutral
    /// aim too, after a failed measurement.
    public enum Origin: String, Sendable, Codable, CaseIterable {
        /// The automatic result: Auto's print aim and, with Lab balance on Auto, its filtration.
        case auto
        /// The frame as shot at its Rated at, through the film: the neutral aim `PrintAim()`, so no
        /// automatic exposure placement or filtration. Recorded from recipe version 4.
        case original
    }

    public var sourceSHA256: String
    public var stockID: String
    public var stockDigest: String
    public var controls: RollControls
    public var aim: PrintAim
    public var analysisVersion: String
    public var resolverVersion: String
    public var baseRender: Recipe.Render
    public var origin: Origin

    public init(sourceSHA256: String, stockID: String, stockDigest: String, controls: RollControls,
                aim: PrintAim, analysisVersion: String, resolverVersion: String = DevelopmentResolver.currentVersion,
                baseRender: Recipe.Render, origin: Origin = .auto) {
        self.sourceSHA256 = sourceSHA256
        self.stockID = stockID
        self.stockDigest = stockDigest
        self.controls = controls
        self.aim = aim
        self.analysisVersion = analysisVersion
        self.resolverVersion = resolverVersion
        // Halation stays live under a pin, as grain does (`DevelopmentResolver.resolve`), so the pin keeps none of the
        // control: a frame pinned at another amount needs no newer recipe once the control is back at the stock's own.
        var render = baseRender
        render.halationAmount = nil
        self.baseRender = render
        self.origin = origin
    }

    /// The Original starting point of the raw `sourceSHA256` through `stock` with `controls`, at the
    /// current resolver: `baseRender` is what they give at `PrintAim()`.
    public static func original(sourceSHA256: String, stockID: String, stockDigest: String, controls: RollControls,
                                baseRender: Recipe.Render) -> AutomaticBaseline {
        AutomaticBaseline(sourceSHA256: sourceSHA256, stockID: stockID, stockDigest: stockDigest, controls: controls,
                          aim: PrintAim(), analysisVersion: ExposureAnalysis.currentVersion, baseRender: baseRender,
                          origin: .original)
    }

    /// Whether the pin is what its origin says: an Original's aim is the neutral one.
    public var isConsistent: Bool { origin == .auto || aim == PrintAim() }

    private enum CodingKeys: String, CodingKey {
        case sourceSHA256, stockID, stockDigest, controls, aim, analysisVersion, resolverVersion, baseRender, origin
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceSHA256 = try values.decode(String.self, forKey: .sourceSHA256)
        stockID = try values.decode(String.self, forKey: .stockID)
        stockDigest = try values.decode(String.self, forKey: .stockDigest)
        controls = try values.decode(RollControls.self, forKey: .controls)
        aim = try values.decode(PrintAim.self, forKey: .aim)
        analysisVersion = try values.decode(String.self, forKey: .analysisVersion)
        resolverVersion = try values.decode(String.self, forKey: .resolverVersion)
        baseRender = try values.decode(Recipe.Render.self, forKey: .baseRender)
        // Absent from every pin before 2026-10-30, all of them Auto's; an origin this build does not
        // know fails the read, so the recipe is preserved rather than taken for an Auto pin.
        origin = try values.decodeIfPresent(Origin.self, forKey: .origin) ?? .auto
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sourceSHA256, forKey: .sourceSHA256)
        try values.encode(stockID, forKey: .stockID)
        try values.encode(stockDigest, forKey: .stockDigest)
        try values.encode(controls, forKey: .controls)
        try values.encode(aim, forKey: .aim)
        try values.encode(analysisVersion, forKey: .analysisVersion)
        try values.encode(resolverVersion, forKey: .resolverVersion)
        try values.encode(baseRender, forKey: .baseRender)
        // An Auto pin is written as before Original existed.
        if origin != .auto { try values.encode(origin, forKey: .origin) }
    }
}

/// Editable intent and its source-bound starting point. The app releases an edit from Auto once its
/// values are identity (`isEmpty`); one from Original is kept with identity values, since starting
/// there is itself the frame's choice. The resolver can retain a pin with identity values for
/// Compare to Auto.
public struct ManualEdit: Sendable, Equatable, Codable {
    public var adjustments: ManualAdjustments {
        didSet { maskNotes = maskNotes.keeping(adjustments.masks) }
    }
    public var baseline: AutomaticBaseline
    public var curveVersion: String
    /// Mask names and each seed's provenance: not pixels, so never in a fingerprint or a develop's
    /// comparison. They go with their masks, here and when `adjustments` changes.
    public var maskNotes: MaskNotes

    public init(adjustments: ManualAdjustments, baseline: AutomaticBaseline,
                curveVersion: String = ManualRenderSettings.currentVersion, maskNotes: MaskNotes = .none) {
        self.adjustments = adjustments
        self.baseline = baseline
        self.curveVersion = curveVersion
        self.maskNotes = maskNotes.keeping(adjustments.masks)
    }

    private enum CodingKeys: String, CodingKey { case adjustments, baseline, curveVersion, maskNotes }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        adjustments = try values.decode(ManualAdjustments.self, forKey: .adjustments)
        baseline = try values.decode(AutomaticBaseline.self, forKey: .baseline)
        curveVersion = try values.decode(String.self, forKey: .curveVersion)
        maskNotes = (try values.decodeIfPresent(MaskNotes.self, forKey: .maskNotes) ?? .none).keeping(adjustments.masks)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(adjustments, forKey: .adjustments)
        try values.encode(baseline, forKey: .baseline)
        try values.encode(curveVersion, forKey: .curveVersion)
        // A frame with no masks is written as before they existed.
        if !maskNotes.isEmpty { try values.encode(maskNotes, forKey: .maskNotes) }
    }

    /// An edit from Auto with every value at identity: the automatic result itself, so its pin goes.
    public var isEmpty: Bool { adjustments.isIdentity && baseline.origin == .auto }
}

public enum DevelopmentResolver {
    public static let currentVersion = "2026-10-09-1"

    public enum Failure: Error, LocalizedError, Equatable {
        case unsupportedResolver(String)
        case stockChanged(String)
        case invalidBaseline

        public var errorDescription: String? {
            switch self {
            case .unsupportedResolver(let version):
                return "This edit needs automatic resolver \(version). Update Automatic Baseline to use the current resolver."
            case .stockChanged(let stock):
                return "The \(stock) stock has changed since editing began. Update Automatic Baseline before changing this edit."
            case .invalidBaseline:
                return "This edit's automatic baseline is invalid. Update Automatic Baseline to continue."
            }
        }
    }

    /// Preview, comparison, and export use this same conversion. Grain, halation and stock choices stay live;
    /// unchanged automatic choices retain their recorded resolved render across analysis updates. `halation` is
    /// the multiple of the stock's own (`OutputSettings.halationAmount`).
    public static func resolve(stock: Stock, stockDigest: String, controls: RollControls, aim: PrintAim,
                               manual: ManualEdit?, grain: Float, halation: Float = 1, grainSeed: UInt32,
                               sharpen: Bool = true) throws -> DevelopSettings {
        var settings: DevelopSettings
        if let edit = manual {
            let baseline = edit.baseline
            guard baseline.aim.level.isFinite, baseline.aim.cast.x.isFinite, baseline.aim.cast.y.isFinite,
                  baseline.aim.cast.z.isFinite, baseline.isConsistent, baseline.baseRender.labBalance.count == 3,
                  baseline.baseRender.labBalance.allSatisfy(\.isFinite), baseline.baseRender.printExposure.isFinite else {
                throw Failure.invalidBaseline
            }
            if baseline.stockID == stock.id && baseline.stockDigest != stockDigest {
                throw Failure.stockChanged(stock.displayName)
            }
            if baseline.stockID == stock.id && baseline.stockDigest == stockDigest && baseline.controls == controls {
                settings = baseline.baseRender.settings
            } else {
                // Keep this registry explicit: future mappings must retain a case for the recorded
                // version instead of silently remapping an existing edit.
                switch baseline.resolverVersion {
                case currentVersion: settings = controls.settings(for: stock, aim: baseline.aim)
                default: throw Failure.unsupportedResolver(baseline.resolverVersion)
                }
                // The pin's tone step keeps the version it recorded, as the edit keeps its Light compiler: a new stock or
                // rating solves its table again, and by the rules the frame was saved on (`PrintTone.versions`).
                if let recorded = baseline.baseRender.tone, settings.tone.isActive { settings.tone.version = recorded.version }
            }
            settings.manual = try ManualRenderSettings(adjustments: edit.adjustments,
                                                       referenceStops: baseline.aim.level, version: edit.curveVersion)
        } else {
            settings = controls.settings(for: stock, aim: aim)
            settings.manual = NeutralAuto.autoManualSettings(for: stock, referenceStops: aim.level)
        }
        settings.grain = grain
        settings.grainSeed = grainSeed
        settings.halation = stock.halation != nil
        // A stock without halation takes none of the control, so its settings do not move with it.
        settings.halationAmount = settings.halation ? halation : 1
        settings.sharpen = sharpen
        return settings
    }
}
