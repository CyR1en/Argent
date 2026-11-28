import ArgentCore
import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

@MainActor @Suite(.serialized) struct RollModelPresetTests {
    private func withRoll(_ work: (RollModel, [Frame]) async throws -> Void) async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            try AutoDecisionStateTests.writeToyStock("other", in: fixture.stocks)
            let model = fixture.model(), gate = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let frames = try #require(model.roll?.frames)
            model.stockIndex = try #require(model.films?.stocks.firstIndex { $0.id == "toy" })
            gate.openAll(frames)
            _ = try #require(await model.settledDecision())
            try await work(model, frames)
            try await model.flushManualSaves()
        }
    }

    @Test func capturesEffectiveFilmSettingsAndAppliesStockSeparatelyFromFilmSettings() async throws {
        try await withRoll { model, frames in
            let source = frames[0], target = frames[1]
            let index = try #require(model.films?.stocks.firstIndex { $0.id == "other" })
            model.setStock(index, for: source)
            model.controls.ratedAt = .oneStopOver
            model.setLabBalance(.warm, for: source)
            model.setHalation(45, for: source)
            model.setLabBalance(.cool, for: target)
            let stock = model.makePreset(from: source, name: "Stock only", includedParts: [.stock])
            let film = model.makePreset(from: source, name: "Film only", includedParts: [.filmControls])
            #expect(stock.baseStockID == "other" && stock.halation == nil)
            #expect(film.baseStockID == nil && film.ratedAt == .oneStopOver && film.labBalance == .warm && film.halation == 45)
            let first = try #require(await model.applyPreset(film, to: target)?.value)
            #expect(first.pasted == [target.url] && model.frameControls(target).stock == nil)
            #expect(model.frameControls(target).labBalance == .warm && model.halation(for: target) == 45)
            let second = try #require(await model.applyPreset(stock, to: target)?.value)
            #expect(second.pasted == [target.url] && model.frameControls(target).stock == "other")
            #expect(model.frameControls(target).labBalance == .warm && model.halation(for: target) == 45)

            let missing = UserPreset(name: "Missing", includedParts: [.stock], baseStockID: "user-missing")
            #expect(model.applyPreset(missing, to: target) == nil)
            #expect(model.frameControls(target).stock == "other")
        }
    }

    @Test func appliesAWholeRollWithEachFramesOwnAutoPinAndOneUndoStep() async throws {
        try await withRoll { model, frames in
            let source = frames[0]
            let lens = try LensSettings.default.setting(.distortion, to: 80)
            await model.prepareManualAdjustments(for: source)
            model.recordVisibleAutomatic(for: source, stock: model.stockIndex(for: source), aim: model.printAim(for: source),
                                         settings: model.settings(for: source, stock: model.stockIndex(for: source)))
            model.setManualAdjustments(try ManualAdjustments(exposureEV: 0.5, presence: Presence([.clarity: 15]), lens: lens), for: source)
            let before = frames.map(model.pasteUndoState(for:))
            let undo = UndoManager()
            undo.groupsByEvent = false
            model.manualUndoManager = undo
            let preset = UserPreset(name: "Soft", includedParts: [.light], adjustments: try ManualAdjustments(contrast: -20))
            let report = try #require(await model.applyPresetToRoll(preset)?.value)
            #expect(report.pasted == frames.map(\.url) && report.isUndoable)
            for frame in frames {
                let edit = try #require(model.manualEdits[frame.url])
                #expect(edit.baseline.origin == .auto && edit.baseline.aim == model.printAim(for: frame))
                #expect(edit.baseline.sourceSHA256 == model.manualReadySources[frame.url]?.sha256)
                #expect(edit.adjustments.contrast == -20 && edit.adjustments.exposureEV == 0)
            }
            #expect(model.manualAdjustments(for: source).presence.clarity == 15)
            #expect(model.manualAdjustments(for: source).lens == lens && model.adjustmentsClipboard == nil)
            undo.undo()
            #expect(frames.map(model.pasteUndoState(for:)) == before && !undo.canUndo)
        }
    }
}
