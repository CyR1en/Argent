import ArgentCore
import Foundation

public struct PresetParts: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let light = Self(rawValue: 1 << 0)
    public static let presence = Self(rawValue: 1 << 1)
    public static let curves = Self(rawValue: 1 << 2)
    public static let filmControls = Self(rawValue: 1 << 3)
    public static let stock = Self(rawValue: 1 << 4)
    public static let all: Self = [.light, .presence, .curves, .filmControls, .stock]
}

public struct UserPreset: Identifiable, Sendable, Equatable, Codable {
    public static let currentVersion = 1
    public var version: Int
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var canisterColor: [Float]?
    public var includedParts: PresetParts

    public var baseStockID: String?
    public var ratedAt: RollControls.RatedAt?
    public var labBalance: RollControls.LabBalance?
    public var grain: OutputSettings.Grain?
    public var halation: Int?
    public var monochromeFilter: MonochromeFilter?
    public var paperGrade: PaperGrade?

    public var origin: AutomaticBaseline.Origin?
    public private(set) var adjustments: ManualAdjustments

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), updatedAt: Date? = nil,
                canisterColor: [Float]? = nil, includedParts: PresetParts = .all, baseStockID: String? = nil,
                ratedAt: RollControls.RatedAt? = nil, labBalance: RollControls.LabBalance? = nil,
                grain: OutputSettings.Grain? = nil, halation: Int? = nil, monochromeFilter: MonochromeFilter? = nil,
                paperGrade: PaperGrade? = nil, origin: AutomaticBaseline.Origin? = nil, adjustments: ManualAdjustments = .identity) {
        version = Self.currentVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.canisterColor = canisterColor
        self.includedParts = includedParts
        self.baseStockID = includedParts.contains(.stock) ? baseStockID : nil
        let includesFilm = includedParts.contains(.filmControls)
        self.ratedAt = includesFilm ? ratedAt : nil
        self.labBalance = includesFilm ? labBalance : nil
        self.grain = includesFilm ? grain : nil
        self.halation = includesFilm ? halation : nil
        self.monochromeFilter = includesFilm ? monochromeFilter : nil
        self.paperGrade = includesFilm ? paperGrade : nil
        self.origin = includedParts.contains(.light) ? origin : nil
        var values: ManualAdjustments.Parts = []
        if includedParts.contains(.light) { values.insert(.light) }
        if includedParts.contains(.presence) { values.insert(.presence) }
        if includedParts.contains(.curves) { values.insert(.curves) }
        self.adjustments = ManualAdjustments.identity.setting(values, from: adjustments)
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, name, createdAt, updatedAt, canisterColor, includedParts, baseStockID, ratedAt,
             labBalance, grain, halation, monochromeFilter, paperGrade, origin, adjustments
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Unsupported preset version \(version).")
        }
        try self.init(id: c.decode(UUID.self, forKey: .id), name: c.decode(String.self, forKey: .name),
                      createdAt: c.decode(Date.self, forKey: .createdAt), updatedAt: c.decode(Date.self, forKey: .updatedAt),
                      canisterColor: c.decodeIfPresent([Float].self, forKey: .canisterColor),
                      includedParts: c.decode(PresetParts.self, forKey: .includedParts),
                      baseStockID: c.decodeIfPresent(String.self, forKey: .baseStockID),
                      ratedAt: c.decodeIfPresent(RollControls.RatedAt.self, forKey: .ratedAt),
                      labBalance: c.decodeIfPresent(RollControls.LabBalance.self, forKey: .labBalance),
                      grain: c.decodeIfPresent(OutputSettings.Grain.self, forKey: .grain),
                      halation: c.decodeIfPresent(Int.self, forKey: .halation),
                      monochromeFilter: c.decodeIfPresent(MonochromeFilter.self, forKey: .monochromeFilter),
                      paperGrade: c.decodeIfPresent(PaperGrade.self, forKey: .paperGrade),
                      origin: c.decodeIfPresent(AutomaticBaseline.Origin.self, forKey: .origin),
                      adjustments: c.decode(ManualAdjustments.self, forKey: .adjustments))
    }
}
