import Foundation

/// Clarity's and Texture's tone weights m for one render's stock and settings: m at the print's CIE L* of each sample of scene level,
/// through the render's neutral transfer (`ManualToneTables.Transfer`), so the weight follows the stock, the rating, the print offset
/// and the reference as the Light tables do. Four tables, both sides of both controls, so a value crossing zero or moving builds
/// nothing: no slider value is in them, and neither is Exposure, which moves where they are read (`PresenceSceneParameters.weightOffset`).
///
/// `FilmRenderer` keeps the latest per renderer, keyed by what the transfer reads and the constants' version (`presenceWeights`).
/// 8 KB on the GPU.
struct PresenceToneWeights: Sendable, Equatable {
    /// The four tables, in this order in `samples` and in the GPU buffer.
    enum Table: Int, CaseIterable {
        case clarityPositive, clarityNegative, texturePositive, textureNegative

        func side(of constants: PresenceConstants) -> PresenceConstants.DetailSide {
            switch self {
            case .clarityPositive: constants.clarity.positive
            case .clarityNegative: constants.clarity.negative
            case .texturePositive: constants.texture.positive
            case .textureNegative: constants.texture.negative
            }
        }
    }

    static let samplesPerTable = ManualToneTables.sampleCount

    /// Stops from the manual reference at each table's first sample, and between neighbours: the transfer's.
    let start: Float
    let step: Float
    /// `samplesPerTable` samples each, the tables in `Table` order.
    let samples: [Float]

    /// Tables a test makes by hand: a scene stage's test without the stock's transfer.
    init(start: Float, step: Float, tables: [Table: [Float]]) {
        precondition(Table.allCases.allSatisfy { tables[$0]?.count == Self.samplesPerTable }, "four tables of samplesPerTable samples")
        self.start = start
        self.step = step
        samples = Table.allCases.flatMap { tables[$0] ?? [] }
    }

    /// The render's tables: each side's `ToneWeight` at the transfer's CIE L* of each sample, on the Light tables' grid.
    init(constants: PresenceConstants, referenceStops: Float, stock: Stock, settings: DevelopSettings) throws {
        let transfer = ManualToneTables.Transfer(referenceStops: referenceStops, stock: stock, settings: settings)
        let tables = Table.allCases.map { table in
            let weight = table.side(of: constants).weight
            return (table, transfer.lightness.map { weight.at(lightness: $0) })
        }
        self.init(start: transfer.start, step: transfer.step, tables: Dictionary(uniqueKeysWithValues: tables))
    }

    /// The first sample of `table` in `samples` and in the buffer: what `PresenceSceneParameters` names for each side in use.
    func offset(of table: Table) -> Int { table.rawValue * Self.samplesPerTable }

    /// `table` at `x` stops: linear between samples, constant past the ends, `ManualToneTables.value`'s arithmetic, which the kernel
    /// repeats.
    func value(_ table: Table, at x: Float) -> Float {
        let slice = samples[offset(of: table)..<offset(of: table) + Self.samplesPerTable]
        let last = Float(Self.samplesPerTable - 1)
        let scaled = (x - start) * (1 / step)
        let position = scaled.isNaN ? 0 : min(max(scaled, 0), last)
        let low = min(Int(position), Self.samplesPerTable - 2)
        let a = slice[slice.startIndex + low], b = slice[slice.startIndex + low + 1]
        return a + (b - a) * (position - Float(low))
    }
}
