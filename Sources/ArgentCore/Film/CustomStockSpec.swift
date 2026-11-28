import Foundation

public struct CustomStockSpec: Codable, Equatable, Sendable {
    public enum Base: Codable, Equatable, Hashable, Sendable {
        case neutral
        case monochrome
        case derived(stockID: String)
    }

    public struct Tint: Codable, Equatable, Sendable {
        public var hue: Float = 0
        public var strength: Float = 0
    }

    public struct SplitTone: Codable, Equatable, Sendable {
        public var shadows = Tint()
        public var midtones = Tint()
        public var highlights = Tint()
    }

    public enum Hue: String, Codable, CaseIterable, Sendable {
        case red, orange, yellow, green, cyan, blue

        var center: Float {
            switch self {
            case .red: 28
            case .orange: 55
            case .yellow: 95
            case .green: 145
            case .cyan: 198
            case .blue: 260
            }
        }
    }

    public struct HueShift: Codable, Equatable, Sendable {
        public var hue: Float = 0
        public var saturation: Float = 0
        public init(hue: Float = 0, saturation: Float = 0) {
            self.hue = hue
            self.saturation = saturation
        }
    }

    public struct Grain: Codable, Equatable, Sendable {
        public enum Preset: String, Codable, CaseIterable, Sendable {
            case none, fine, medium, coarse, monochrome
            case inherited
        }

        public var preset: Preset = .none
        public var strength: Float = 1
        public var shadowBias: Float = 0

        public init(preset: Preset = .none, strength: Float = 1, shadowBias: Float = 0) {
            self.preset = preset
            self.strength = strength
            self.shadowBias = shadowBias
        }
    }

    public struct Halation: Codable, Equatable, Sendable {
        public var enabled = false
        public var strength: Float = 0.035
        public var greenShare: Float = 0.25
        public var radiusMicrometres: Float = 150

        public static func strengthRange(inheriting stock: Stock?) -> ClosedRange<Float> {
            0...max(0.08, (stock?.halation?.strength ?? 0) * 2)
        }
    }

    public struct FrameLook: Codable, Equatable, Sendable {
        public let manual: ManualRenderSettings
        public let ratedAt: Float?
        public let printExposure: Float
        public let labBalance: SIMD3<Float>
        public let monochromeFilter: MonochromeFilter
        public let paperGrade: PaperGrade
        public let effectivePresence: Presence?
        public let presenceReferenceStops: Float?
    }

    public var base: Base
    public var boxSpeed: Float = 400
    public var canisterColor: [Float] = [0.29, 0.49, 0.55]
    public var characterLine = ""
    public var contrast: Float = 1
    public var shadowToe: Float = 0
    public var highlightShoulder: Float = 0
    public var toneCurve: ToneCurves?
    public var warmth: Float = 0
    public var tint: Float = 0
    public var saturation: Float = 1
    public var vibrance: Float = 0
    public var splitTone = SplitTone()
    public var colorShift: [Hue: HueShift] = [:]
    public var monochromeMixer: SIMD3<Float>?
    public var paperTone: SIMD3<Float>?
    public var grain = Grain()
    public var halation = Halation()
    public private(set) var frameLook: FrameLook?

    public init(base: Base = .neutral) { self.base = base }

    public init(derivedFrom stock: Stock) {
        self.init(base: .derived(stockID: stock.id))
        boxSpeed = min(max(stock.boxSpeed, 50), 3200)
        canisterColor = stock.canisterColor?.components ?? canisterColor
        grain.preset = stock.grain == nil ? .none : .inherited
        if let h = stock.halation {
            halation.enabled = true
            halation.strength = h.strength
            halation.greenShare = h.greenShare
            halation.radiusMicrometres = min(max(h.radiusMicrometres, 60), 350)
        }
    }

    public init(baking stock: Stock, settings: DevelopSettings) throws {
        self.init(derivedFrom: stock)
        let original = settings.manual.adjustments
        toneCurve = original.curves.hasEffect ? original.curves : nil
        let adjustments = original.settingMasks(.empty).settingCurves(.identity).settingLens(.default)
        let global = try adjustments.settingRemovals([])
        let manual = try ManualRenderSettings(adjustments: global, referenceStops: settings.manual.referenceStops,
                                              version: settings.manual.version)
        frameLook = FrameLook(manual: manual, ratedAt: settings.ratedAt, printExposure: settings.printExposure,
                              labBalance: settings.labBalance, monochromeFilter: settings.monochromeFilter,
                              paperGrade: settings.paperGrade,
                              effectivePresence: settings.autoPresence.isActive ? settings.effectivePresence : nil,
                              presenceReferenceStops: settings.autoPresence.isActive ? settings.presenceReferenceStops : nil)
        grain.strength = min(max(settings.grain, 0), 2)
        halation.enabled = halation.enabled && settings.halation && settings.halationAmount > 0
        if let h = stock.halation { halation.strength = h.strength * settings.halationAmount }
    }
}
