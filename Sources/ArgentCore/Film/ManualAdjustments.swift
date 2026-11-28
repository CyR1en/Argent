import Foundation

/// Frame refinements relative to its automatic development. Values are validated once at
/// the UI/recipe boundary; renderers never repair invalid or partially decoded edits.
public struct ManualAdjustments: Sendable, Equatable, Hashable, Codable {
    public private(set) var exposureEV: Float
    public private(set) var contrast: Float
    public private(set) var highlights: Float
    public private(set) var shadows: Float
    public private(set) var whites: Float
    public private(set) var blacks: Float
    public private(set) var curves: ToneCurves
    /// Local adjustments, beside the curves so `isIdentity` and every check built on it cover them: a mask
    /// with every slider at zero is still an edit, and keeps the pin and its reference.
    public private(set) var masks: MaskSet
    /// Texture, Clarity, Dehaze, Vibrance and Saturation, with their constants' version: a value of its own, not more
    /// `Control` cases, because a mask's adjustments are a `ManualAdjustments` and masks take no Presence.
    public private(set) var presence: Presence
    public private(set) var lens: LensSettings

    public enum Control: String, CaseIterable, Sendable {
        case exposure, contrast, highlights, shadows, whites, blacks

        public var title: String {
            switch self {
            case .exposure: "Exposure"
            case .contrast: "Contrast"
            case .highlights: "Highlights"
            case .shadows: "Shadows"
            case .whites: "Whites"
            case .blacks: "Blacks"
            }
        }
        /// Lightroom Classic's Basic panel ranges. Exposure was −3…+3 until 2026-10-29; every
        /// value saved then is inside this range.
        public var range: ClosedRange<Float> { self == .exposure ? -5...5 : -100...100 }
        /// The resolution a drag or a typed value lands on (keyboard steps: AdjustmentSlider.swift).
        public var step: Float { self == .exposure ? 0.01 : 1 }
    }

    public static let identity = try! ManualAdjustments()
    public var isIdentity: Bool { self == Self.identity }

    public init(exposureEV: Float = 0, contrast: Float = 0, highlights: Float = 0,
                shadows: Float = 0, whites: Float = 0, blacks: Float = 0, curves: ToneCurves = .identity,
                masks: MaskSet = .empty, presence: Presence = .identity, lens: LensSettings = .default) throws {
        self.exposureEV = try Self.validated(exposureEV, for: .exposure)
        self.contrast = try Self.validated(contrast, for: .contrast)
        self.highlights = try Self.validated(highlights, for: .highlights)
        self.shadows = try Self.validated(shadows, for: .shadows)
        self.whites = try Self.validated(whites, for: .whites)
        self.blacks = try Self.validated(blacks, for: .blacks)
        self.curves = curves
        self.masks = masks
        self.presence = presence
        self.lens = lens
    }

    public func settingCurves(_ curves: ToneCurves) -> Self {
        var result = self
        result.curves = curves
        return result
    }

    public func settingMasks(_ masks: MaskSet) -> Self {
        var result = self
        result.masks = masks
        return result
    }

    public func settingPresence(_ presence: Presence) -> Self {
        var result = self
        result.presence = presence
        return result
    }

    /// The lens values change and the removals stay this frame's own, whatever `lens` holds: a paste, a reset and the drive hook
    /// all come through here or through `setting(_:from:)`, and none of them may move a removal to another frame or drop one
    /// (docs/remove-plan.md, section 4.1). Only `settingRemovals` changes them.
    public func settingLens(_ lens: LensSettings) -> Self {
        var result = self
        result.lens = lens.carryingRemovals(self.lens.removals)
        return result
    }

    /// The objects taken out of the frame (`LensSettings.removals`).
    public var removals: [Removal] { lens.removals }

    public func settingRemovals(_ removals: [Removal]) throws -> Self {
        var result = self
        result.lens = try lens.settingRemovals(removals)
        return result
    }

    /// These values with nothing removed: what Copy Adjustments holds, which never names a pixel, and what a probe that renders no
    /// frame keys on.
    public var withoutRemovals: Self {
        var result = self
        result.lens = lens.carryingRemovals([])
        return result
    }

    /// These values as another picture takes them (`MaskSet.forAnotherPicture`).
    public func forAnotherPicture(freshIDs: Bool, geometry: LensGeometry? = nil) throws -> Self {
        settingMasks(try masks.forAnotherPicture(freshIDs: freshIDs, geometry: geometry))
    }

    public func value(for control: Control) -> Float {
        switch control {
        case .exposure: exposureEV
        case .contrast: contrast
        case .highlights: highlights
        case .shadows: shadows
        case .whites: whites
        case .blacks: blacks
        }
    }

    public func setting(_ control: Control, to value: Float) throws -> Self {
        let value = try Self.validated(value, for: control)
        var result = self
        switch control {
        case .exposure: result.exposureEV = value
        case .contrast: result.contrast = value
        case .highlights: result.highlights = value
        case .shadows: result.shadows = value
        case .whites: result.whites = value
        case .blacks: result.blacks = value
        }
        return result
    }

    private static func validated(_ value: Float, for control: Control) throws -> Float {
        guard value.isFinite, control.range.contains(value) else {
            throw ManualDevelopmentError.invalidControl(control, value)
        }
        return value == 0 ? 0 : value  // one identity/fingerprint for positive and negative zero
    }

    private enum CodingKeys: String, CodingKey {
        case exposureEV, contrast, highlights, shadows, whites, blacks, curves, masks, presence, lens
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(exposureEV: values.decode(Float.self, forKey: .exposureEV),
                      contrast: values.decode(Float.self, forKey: .contrast),
                      highlights: values.decode(Float.self, forKey: .highlights),
                      shadows: values.decode(Float.self, forKey: .shadows),
                      whites: values.decode(Float.self, forKey: .whites),
                      blacks: values.decode(Float.self, forKey: .blacks),
                      curves: values.decodeIfPresent(ToneCurves.self, forKey: .curves) ?? .identity,
                      masks: values.decodeIfPresent(MaskSet.self, forKey: .masks) ?? .empty,
                      presence: values.decodeIfPresent(Presence.self, forKey: .presence) ?? .identity,
                      lens: values.decodeIfPresent(LensSettings.self, forKey: .lens) ?? .default)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(exposureEV, forKey: .exposureEV); try c.encode(contrast, forKey: .contrast)
        try c.encode(highlights, forKey: .highlights); try c.encode(shadows, forKey: .shadows)
        try c.encode(whites, forKey: .whites); try c.encode(blacks, forKey: .blacks)
        if !curves.isIdentity { try c.encode(curves, forKey: .curves) }
        // A frame with no masks is written as before they existed.
        if !masks.isEmpty { try c.encode(masks, forKey: .masks) }
        // A frame without Presence is written as before it existed (recipe version 6 and below).
        if !presence.isIdentity { try c.encode(presence, forKey: .presence) }
        if !lens.isDefault { try c.encode(lens, forKey: .lens) }
    }
}

// MARK: The Light tab's sliders and the parts that are copied, pasted and reset whole

extension ManualAdjustments {
    /// A slider of the Light tab: one of Light's six or one of Presence's five. The one thing a Light-tab gesture moves
    /// (`RollModel.moveLight`), so Presence rides the print-only lane, the commit at release, undo and the drive hook with no
    /// second copy of them.
    public enum Slider: Hashable, Sendable {
        case light(Control)
        case presence(Presence.Control)
        case lens(LensSettings.Control)

        /// The tab's rows in order, and the order `.` and `,` walk: Light's six, then Presence's five. Derived from the two
        /// controls' own lists, never written out.
        public static let allCases: [Slider] = Control.allCases.map(Slider.light) + Presence.Control.allCases.map(Slider.presence) + LensSettings.Control.allCases.map(Slider.lens)

        public var title: String {
            switch self {
            case .light(let control): control.title
            case .presence(let control): control.title
            case .lens(let control): control.title
            }
        }
        public var range: ClosedRange<Float> {
            switch self {
            case .light(let control): control.range
            case .presence(let control): control.range
            case .lens(let control): control.range
            }
        }
        /// The name the drive hook and the spike take: a control's `rawValue` (`exposure`, `clarity`).
        public var name: String {
            switch self {
            case .light(let control): control.rawValue
            case .presence(let control): control.rawValue
            case .lens(let control): control.rawValue
            }
        }
        public init?(name: String) {
            guard let found = Self.allCases.first(where: { $0.name == name }) else { return nil }
            self = found
        }
    }

    public func value(for slider: Slider) -> Float {
        switch slider {
        case .light(let control): value(for: control)
        case .presence(let control): presence.value(for: control)
        case .lens(let control): lens.value(for: control)
        }
    }

    public func setting(_ slider: Slider, to value: Float) throws -> Self {
        switch slider {
        case .light(let control): try setting(control, to: value)
        case .presence(let control): settingPresence(try presence.setting(control, to: value))
        case .lens(let control): settingLens(try lens.setting(control, to: value))
        }
    }

    /// The parts of these values that are taken whole from another value, cleared whole, and tell a copy what it holds:
    /// one decision for the print-only lane, the commit at release, Paste and Paste Only, and the resets, which each
    /// named Light's six by hand before (grounding gotcha 3). Masks are not among them: a paste takes them as another
    /// picture does (`forAnotherPicture`), never as they are.
    public struct Parts: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// The six Light values.
        public static let light = Parts(rawValue: 1 << 0)
        /// The Presence value, its version with it.
        public static let presence = Parts(rawValue: 1 << 1)
        /// The four curves, their version with them.
        public static let curves = Parts(rawValue: 1 << 2)
        /// What a Light-tab gesture moves (`Slider`): what the print-only lane lays over the edit and the release writes.
        public static let lens = Parts(rawValue: 1 << 3)
        public static let sliders: Parts = [.light, .presence, .lens]
    }

    /// These values with `other`'s `parts`, each taken whole, its version with it. The print-only lane and the release
    /// take `.sliders` over the edit as it is now; a paste takes the parts it carries.
    public func setting(_ parts: Parts, from other: ManualAdjustments) -> Self {
        var result = self
        if parts.contains(.light) {
            result.exposureEV = other.exposureEV; result.contrast = other.contrast; result.highlights = other.highlights
            result.shadows = other.shadows; result.whites = other.whites; result.blacks = other.blacks
        }
        if parts.contains(.presence) { result.presence = other.presence }
        if parts.contains(.lens) { result.lens = other.lens.carryingRemovals(lens.removals) }
        if parts.contains(.curves) { result.curves = other.curves }
        return result
    }

    /// These values with `parts` back to identity: Reset Light is `clearing(.light)`, and Presence is never cleared by it.
    public func clearing(_ parts: Parts) -> Self { setting(parts, from: .identity) }

    /// The parts holding something: what a copy of these values can paste (`AdjustmentsClipboard.parts`).
    public var heldParts: Parts {
        var parts: Parts = []
        if Control.allCases.contains(where: { value(for: $0) != 0 }) { parts.insert(.light) }
        if !presence.isIdentity { parts.insert(.presence) }
        if !lens.hasDefaultValues { parts.insert(.lens) }
        if !curves.isIdentity { parts.insert(.curves) }
        return parts
    }

    /// `parts` at `other`'s versions, the values kept: Paste Only, which keeps the frame's pin and its compilers.
    public func keepingVersions(_ parts: Parts, of other: ManualAdjustments) throws -> Self {
        var result = self
        if parts.contains(.curves) {
            result.curves = try ToneCurves(tone: curves.tone, red: curves.red, green: curves.green, blue: curves.blue,
                                           version: other.curves.version)
        }
        if parts.contains(.presence) {
            result.presence = try Presence(Dictionary(uniqueKeysWithValues: Presence.Control.allCases.map { ($0, presence.value(for: $0)) }),
                                           version: other.presence.version)
        }
        return result
    }

    /// Every versioned part at the current version: a new pin (Update Automatic Baseline, Reapply, a paste that pins
    /// anew). One call, so a part added later cannot be left at an old version by one of its callers.
    public func updatingVersions() throws -> Self {
        settingCurves(try curves.updatingVersion()).settingMasks(try masks.updatingVersion())
            .settingPresence(try presence.updatingVersion())
    }
}

public enum ManualDevelopmentError: Error, Sendable, LocalizedError {
    case invalidControl(ManualAdjustments.Control, Float)
    case invalidPresence(Presence.Control, Float)
    case invalidLens(String)
    case invalidReference(Float)
    case unsupportedVersion(String)

    public var errorDescription: String? {
        switch self {
        case .invalidControl(let control, let value):
            return "\(control.title) value \(value) is outside its supported range."
        case .invalidPresence(let control, let value):
            return "\(control.title) value \(value) is outside its supported range."
        case .invalidLens(let reason): return reason
        case .invalidReference:
            return "The automatic tonal reference is invalid. Update Automatic Baseline to continue."
        case .unsupportedVersion(let version):
            return "Manual-development version \(version) is unavailable. Update Automatic Baseline to continue."
        }
    }
}

extension ManualRenderSettings {
    /// Preserve recipe intent while omitting dormant hue handles from render identities.
    public func ignoringInactiveLensHue() -> Self {
        try! Self(recordedAdjustments: adjustments.settingLens(adjustments.lens.ignoringInactiveHue),
                  referenceStops: referenceStops, version: version)
    }

    /// The same settings as a develop receipt keeps them: the masks as their digest alone, which compares
    /// equal to the settings they came from and cannot be rendered.
    public func digestingMasks() -> ManualRenderSettings {
        guard !adjustments.masks.isEmpty, !adjustments.masks.isDigestOnly,
              let digested = try? ManualRenderSettings(recordedAdjustments: adjustments.settingMasks(adjustments.masks.digestOnly),
                                                       referenceStops: referenceStops, version: version) else { return self }
        return digested
    }
}

/// The version and reference fully select the curve compiler. The reference is a fixed
/// scene midtone of 0.18 * 2^(-referenceStops), derived from the frame's pinned automatic
/// aim; neither image resolution nor a manually adjusted measurement changes it.
///
/// Three Light compilers are supported. `2026-11-06-1`, current, acts on scene light alone and
/// follows Lightroom's Basic panel: Exposure as a scene gain, Highlights and Shadows at each pixel's
/// local base before that Exposure, then Whites, Blacks and Contrast at its light after it, as scene
/// gains that land on Lightroom's lightness changes through the stock's print (`ManualToneTables`).
/// `2026-10-29-1` is the same but for one read: Highlights and Shadows take the base after Exposure, so
/// Exposure moves which tones they act on, as Lightroom's do not. With Exposure at 0 the two render
/// the same bytes. `2026-10-09-1` mapped Highlights and Shadows through logistic regions on scene
/// light and Contrast, Whites and Blacks on the print. The older two are kept so edits recorded with
/// them render as they did.
public struct ManualRenderSettings: Sendable, Equatable, Hashable, Codable {
    public static let currentVersion = "2026-11-06-1"
    /// The gain tables with Highlights and Shadows reading the base after Exposure, kept for saved edits.
    public static let exposedBaseVersion = "2026-10-29-1"
    /// The logistic regions and the print mapping, kept for saved edits.
    public static let regionsVersion = "2026-10-09-1"
    public static let identity = try! ManualRenderSettings(adjustments: .identity, referenceStops: 0)

    public let adjustments: ManualAdjustments
    public let referenceStops: Float
    public let version: String
    public var isIdentity: Bool { adjustments.settingLens(adjustments.lens.ignoringInactiveHue).isIdentity }

    public init(adjustments: ManualAdjustments, referenceStops: Float,
                version: String = Self.currentVersion) throws {
        guard Self.supports(version: version) else { throw ManualDevelopmentError.unsupportedVersion(version) }
        try adjustments.masks.requireRenderable(lightCompiler: version)
        try self.init(recordedAdjustments: adjustments, referenceStops: referenceStops, version: version)
    }

    private init(recordedAdjustments adjustments: ManualAdjustments, referenceStops: Float, version: String) throws {
        guard referenceStops.isFinite, (-32...32).contains(referenceStops) else {
            throw ManualDevelopmentError.invalidReference(referenceStops)
        }
        self.adjustments = adjustments
        self.referenceStops = adjustments.isIdentity ? 0 : (referenceStops == 0 ? 0 : referenceStops)
        self.version = adjustments.isIdentity ? Self.currentVersion : version
    }

    /// Keep recorded compilers here when adding a new mapping. An unavailable version is
    /// an explicit error, rather than silently reinterpreting a saved slider value.
    public static func supports(version: String) -> Bool {
        version == currentVersion || version == exposedBaseVersion || version == regionsVersion
    }

    /// Whether this edit's compiler uses the gain tables: every one since `regionsVersion`.
    var usesGainTables: Bool { version == Self.currentVersion || version == Self.exposedBaseVersion }

    /// Whether the render needs `toneTables(stock:settings:)`: a gain-table compiler with any of
    /// Contrast, Highlights, Shadows, Whites or Blacks set.
    public var needsToneTables: Bool {
        let a = adjustments
        return usesGainTables && (a.contrast != 0 || a.highlights != 0 || a.shadows != 0
            || a.whites != 0 || a.blacks != 0)
    }

    /// Whether the render needs the local base field: a gain-table compiler with Highlights or Shadows set, on the panel or on a mask
    /// that is on, after its Amount.
    public var needsToneBase: Bool {
        usesGainTables && (adjustments.highlights != 0 || adjustments.shadows != 0
            || adjustments.masks.masks.contains { $0.scaledValue(for: .highlights) != 0 || $0.scaledValue(for: .shadows) != 0 })
    }

    /// Whether any mask changes a pixel: one that is on, with a slider other than 0 after its Amount. Without one a render takes today's
    /// kernels and reads no coverage, whatever the edit's mask list holds (plan section 4, rule 4).
    public var hasEffectiveMasks: Bool {
        adjustments.masks.masks.contains { mask in
            !mask.scaledBalance.isNeutral || ManualAdjustments.Control.allCases.contains { mask.scaledValue(for: $0) != 0 }
        }
    }

    /// A gain-table compiler's tables for a render of `stock` with `settings` (their rating, lab
    /// balance and print exposure; Exposure does not change them, and they are the same for either
    /// compiler, which differ in where the local one is read). `nil` when `needsToneTables` is false.
    public func toneTables(stock: Stock, settings: DevelopSettings) throws -> ManualToneTables? {
        try validateSupportedVersion()
        guard needsToneTables else { return nil }
        return ManualToneTables(adjustments: adjustments, referenceStops: referenceStops, stock: stock, settings: settings)
    }

    public func validateSupportedVersion() throws {
        guard isIdentity || Self.supports(version: version) else {
            throw ManualDevelopmentError.unsupportedVersion(version)
        }
        try adjustments.curves.validateSupportedVersion()
        try adjustments.masks.requireRenderable(lightCompiler: version)
        try adjustments.presence.validateSupportedVersion()
    }

    private enum CodingKeys: String, CodingKey { case adjustments, referenceStops, version }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A known recipe with an unavailable compiler can still restore its edit intent
        // and show Update Automatic Baseline. Rendering, not decoding, enforces support.
        try self.init(recordedAdjustments: values.decode(ManualAdjustments.self, forKey: .adjustments),
                      referenceStops: values.decode(Float.self, forKey: .referenceStops),
                      version: values.decode(String.self, forKey: .version))
    }

    /// CPU reference for the scene mapping a render without tone tables uses: `regionsVersion`'s,
    /// and a gain-table compiler's Exposure alone. Their tone controls need the stock:
    /// `applyingScene(to:baseLog2:tables:)`.
    public func applyingScene(to rgb: SIMD3<Float>) throws -> SIMD3<Float> {
        try applyingScene(to: rgb, baseLog2: Self.guideLog2(rgb), tables: nil)
    }

    /// CPU reference for the fused scene pass and the halation source, any compiler.
    ///
    /// `currentVersion`: Exposure's gain, then `gain = local(xb) + global(x + local(xb))` stops for
    /// all three channels together, `x` the pixel's guarded log2 luminance before Exposure moved to
    /// stops from the reference after it, `xb` its local base (`baseLog2`, in the base field's units:
    /// `ToneBaseField.reference`) moved to stops from the reference before it, so the local gain does
    /// not move with Exposure. `exposedBaseVersion` is the same with `xb` after Exposure. For a fixed
    /// base the map rises with `x`, since the global table's `x + global(x)` does. `tables` are
    /// `toneTables(stock:settings:)`'s.
    ///
    /// `regionsVersion` ignores the base and tables. Rec.2020 luminance is warped in log stops:
    /// each H/S region contributes at most 1.5 stops with a logistic width of two stops.
    /// The combined derivative is at least 1 - 2*(1.5/8) = 0.625, even with opposed
    /// extrema. Absent signal stays absent; signed channels share a positive RGB gain.
    public func applyingScene(to rgb: SIMD3<Float>, baseLog2: Float, tables: ManualToneTables?) throws -> SIMD3<Float> {
        precondition(tables != nil || !needsToneTables, "\(version)'s tone controls need their tables")
        return applyingScene(to: rgb, baseLog2: baseLog2, tables: tables, parameters: try parameters(tables: tables))
    }

    func applyingScene(to rgb: SIMD3<Float>, baseLog2: Float, tables: ManualToneTables?,
                       parameters p: ManualCurveParameters) -> SIMD3<Float> {
        guard p.sceneActive != 0 else { return rgb }
        let exposed = rgb * p.exposureGain
        if p.sceneTables != 0 {
            guard let tables, p.localActive != 0 || p.globalActive != 0 else { return exposed }
            let local = p.localActive != 0 ? tables.value(tables.local, at: baseLog2 + p.baseOffset) : 0
            let global = p.globalActive != 0 ? tables.value(tables.global, at: Self.guideLog2(rgb) + p.guideOffset + local) : 0
            return exposed * exp2(local + global)
        }
        guard p.highlights != 0 || p.shadows != 0 else { return exposed }
        let luminance = Self.luminance(exposed)
        let guarded = sqrt(luminance * luminance + Self.sceneEpsilon * Self.sceneEpsilon)
        let stops = log2(guarded / p.sceneReference)
        let shift = p.highlights * Self.logistic((stops - 1) * 0.5)
            + p.shadows * Self.logistic(-(stops + 1) * 0.5)
        return exposed * exp2(shift)
    }

    /// CPU reference for the fused print pass; the gain-table compilers have no print mapping, only curves.
    /// `regionsVersion`: Contrast is a rational bias on either side
    /// of 18% gray, joined with the same derivative. Its slope stays positive and finite,
    /// including linear continuations outside 0...1. Endpoints are black +/-0.04 and
    /// white 1 +/-0.20, so even opposed extremes leave a positive scale of at least 0.76.
    /// A neutral toe guard avoids amplifying chroma noise or flipping signed RGB at black.
    public func applyingPrint(to rgb: SIMD3<Float>) throws -> SIMD3<Float> {
        let curves = adjustments.curves.hasEffect ? try adjustments.curves.compiled() : nil
        return applyingPrint(to: rgb, parameters: try parameters, curves: curves)
    }

    func applyingPrint(to rgb: SIMD3<Float>, parameters p: ManualCurveParameters,
                       curves: CompiledToneCurves?) -> SIMD3<Float> {
        guard p.printActive != 0 else {
            return curves?.applying(to: rgb) ?? rgb
        }
        let luminance = Self.luminance(rgb)
        let curve = Self.contrastCurve(luminance, exponent: p.contrastSlope)
        let span = p.whiteEndpoint - p.blackEndpoint
        let mapped = p.blackEndpoint + span * curve
        let contrastGain = Self.contrastGain(luminance, exponent: p.contrastSlope)
        // Away from the toe, one gain preserves RGB chromaticity. Around zero or a
        // negative target, move the endpoint neutrally while retaining positive RGB gain.
        let blend: Float = luminance > 0
            ? Self.smoothstep(0, 0.02, p.blackEndpoint < 0 ? max(mapped, 0) : luminance) : 0
        let endpointGain: Float = luminance > 0 ? p.blackEndpoint * blend / luminance : 0
        let print = rgb * (span * contrastGain + endpointGain)
            + SIMD3<Float>(repeating: p.blackEndpoint * (1 - blend))
        return curves?.applying(to: print) ?? print
    }

    public static func luminance(_ rgb: SIMD3<Float>) -> Float {
        rgb.x * Rec2020.luma.x + rgb.y * Rec2020.luma.y + rgb.z * Rec2020.luma.z
    }

    /// The guide the local base field filters and the gain-table compilers measure each pixel by:
    /// log2 of the Rec. 2020 luminance before Exposure, guarded neutrally at zero and below
    /// (`ToneBaseField.guide`, one definition for both).
    public static func guideLog2(_ rgb: SIMD3<Float>) -> Float { ToneBaseField.guide(rgb) }

    static let sceneEpsilon: Float = 1e-6
    private static func logistic(_ x: Float) -> Float { 1 / (1 + exp(-x)) }
    private static func smoothstep(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let t = min(max((value - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }
    private static func contrastCurve(_ luminance: Float, exponent k: Float) -> Float {
        if k == 1 { return luminance }
        if luminance <= 0 { return luminance / k }
        if luminance >= 1 { return 1 + (luminance - 1) / k }
        let pivot: Float = 0.18
        if luminance <= pivot {
            let t = luminance / pivot
            return pivot * t / (k + (1 - k) * t)
        }
        let t = (1 - luminance) / (1 - pivot)
        return 1 - (1 - pivot) * t / (k + (1 - k) * t)
    }

    private static func contrastGain(_ luminance: Float, exponent k: Float) -> Float {
        if k == 1 { return 1 }
        if luminance <= 0 { return 1 / k }
        if luminance <= 0.18 { return 1 / (k + (1 - k) * luminance / 0.18) }
        return contrastCurve(luminance, exponent: k) / luminance
    }

    /// The parameter block without tone tables: `regionsVersion`'s, the print pass's, and a
    /// gain-table compiler's Exposure alone.
    var parameters: ManualCurveParameters { get throws { try parameters(tables: nil) } }

    /// `regionsVersion`'s constants are part of that version, not per-stock heuristics. The
    /// compact parameter block is shared by the negative, halation-source, and print kernels.
    /// For a gain-table compiler the tables' geometry joins it, which of them are set, and where each
    /// is read.
    func parameters(tables: ManualToneTables?) throws -> ManualCurveParameters {
        try validateSupportedVersion()
        let a = adjustments
        var p = ManualCurveParameters(exposureGain: exp2(a.exposureEV), sceneReference: 0.18 * exp2(-referenceStops))
        guard usesGainTables else {
            p.highlights = a.highlights * 0.015; p.shadows = a.shadows * 0.015
            p.contrastSlope = exp2(a.contrast * 0.01)
            p.whiteEndpoint = 1 + a.whites * 0.002
            p.blackEndpoint = a.blacks * 0.0004
            p.sceneActive = a.exposureEV != 0 || a.highlights != 0 || a.shadows != 0 ? 1 : 0
            p.printActive = a.contrast != 0 || a.whites != 0 || a.blacks != 0 ? 1 : 0
            return p
        }
        p.sceneTables = 1
        p.sceneActive = a.exposureEV != 0 || needsToneTables ? 1 : 0
        if let tables {
            p.globalActive = tables.globalActive ? 1 : 0
            p.localActive = tables.localActive ? 1 : 0
            p.tableCount = UInt32(tables.global.count)
            p.tableStart = tables.start
            p.tableScale = 1 / tables.step
        }
        // From the guide's units, log2 luminance before Exposure, to stops from the reference: after
        // Exposure for the pixel's own light, and for its local base as the compiler reads it.
        p.guideOffset = a.exposureEV + referenceStops - log2(Float(0.18))
        p.baseOffset = version == Self.exposedBaseVersion ? p.guideOffset : referenceStops - log2(Float(0.18))
        return p
    }
}

/// Mirrors ManualCurveParameters in Shaders.swift: seven floats and two uints for
/// `regionsVersion`, then four uints and four floats for the gain-table compilers, 68 bytes.
struct ManualCurveParameters: Sendable {
    var exposureGain: Float
    var sceneReference: Float
    var highlights: Float = 0
    var shadows: Float = 0
    var contrastSlope: Float = 1
    var whiteEndpoint: Float = 1
    var blackEndpoint: Float = 0
    var sceneActive: UInt32 = 0
    var printActive: UInt32 = 0
    /// 1 for a gain-table compiler: the tables in place of the logistic regions.
    var sceneTables: UInt32 = 0
    var localActive: UInt32 = 0
    var globalActive: UInt32 = 0
    var tableCount: UInt32 = 0
    var tableStart: Float = 0
    /// Samples per stop.
    var tableScale: Float = 0
    /// Added to the guide to read the global table: stops from the reference, after Exposure.
    var guideOffset: Float = 0
    /// Added to the local base to read the local table: stops from the reference, before Exposure on
    /// `currentVersion` and equal to `guideOffset`, after it, on `exposedBaseVersion`.
    var baseOffset: Float = 0
}
