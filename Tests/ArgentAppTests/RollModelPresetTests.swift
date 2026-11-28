import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp
@testable import ArgentCore

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

    @Test(arguments: [true, false])
    func stockChangingPastePinsTheNewStocksAutoAim(usePreset: Bool) async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            var printLUT = LUT3D.identity(size: 17)
            printLUT.values = printLUT.values.map { 0.04 + 0.92 * min(max(($0 - 0.375) / 0.5, 0), 1) }
            for (id, lut) in [("toy", LUT3D.identity(size: 2)), ("compressed", printLUT)] {
                let stock = Stock(id: id, displayName: id, status: "synthetic", boxSpeed: 400,
                                  densityRange: 1.5, exposurePerUnit: SIMD3(repeating: 0.35),
                                  negative: LUT3D.identity(size: 2), print: lut)
                try stock.write(to: fixture.stocks.appendingPathComponent(id))
            }
            let side = 128
            let light = (0..<(side * side)).map { pixel in
                let x = pixel % side
                let stops: Float = (x / 2) % 2 == 0 ? 3.5 : 4
                return SIMD3(repeating: 0.18 * exp2(stops + (x % 2 == 0 ? -0.08 : 0.08)))
            }
            let descriptor = SequenceDescriptor(grid: ExposureAnalyzer.Grid(width: side, height: side, step: 1,
                frameWidth: side, frameHeight: side, light: light, all: light,
                unclipped: Array(repeating: 1, count: light.count), weight: Array(repeating: 1, count: light.count)))
            var analysis = ExposureAnalysis(meanStops: 0, validWeight: 1, grayEstimate: [0, 0, 0])
            analysis.histogram = Array(repeating: 0, count: ExposureAnalysis.histogramBins)
            analysis.histogram[10] = 1
            let model = fixture.model(), gate = MeasurementGate()
            for name in AutoDecisionStateTests.names { gate.analyses[name] = analysis }
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let frames = try #require(model.roll?.frames)
            let source = frames[0], target = frames[1], unchanged = frames[2]
            model.stockIndex = try #require(model.films?.stocks.firstIndex { $0.id == "toy" })
            let compressed = try #require(model.films?.stocks.firstIndex { $0.id == "compressed" })
            model.descriptors[target.url] = descriptor
            model.descriptors[unchanged.url] = descriptor
            gate.openAll(frames)
            _ = try #require(await model.settledDecision())
            model.setStock(compressed, for: source)
            model.setStock(compressed, for: unchanged)
            await model.prepareManualAdjustments(for: source)
            model.recordVisibleAutomatic(for: source, stock: compressed, aim: model.printAim(for: source),
                                         settings: model.settings(for: source, stock: compressed))
            model.setManualAdjustments(try ManualAdjustments(exposureEV: 0.5), for: source)
            let before = try #require(await model.settledDecision())
            let oldAim = try #require(before.aims[target.url])
            let savedAim = try #require(before.aims[unchanged.url])
            try #require(savedAim.burn > oldAim.burn)
            #expect(model.manualEdits[target.url] == nil && model.manualEdits[unchanged.url] == nil)
            model.descriptors[unchanged.url] = nil

            let report: PasteReport
            if usePreset {
                let preset = model.makePreset(from: source, name: "Compressed", includedParts: [.stock, .light])
                report = try #require(await model.applyPreset(preset, to: [target, unchanged], batch: true)?.value)
            } else {
                model.copyAdjustments(from: source)
                let clipboard = try #require(model.adjustmentsClipboard)
                report = try #require(await model.paste(clipboard, parts: .all, to: [target, unchanged], batch: true)?.value)
            }

            #expect(report.pasted == [target.url, unchanged.url])
            let edit = try #require(model.manualEdits[target.url])
            let newAim = try #require(await model.settledDecision()?.aims[target.url])
            try #require(newAim.burn > oldAim.burn)
            #expect(edit.baseline.stockID == "compressed" && edit.baseline.origin == .auto)
            #expect(edit.baseline.aim == newAim)
            #expect(model.manualEdits[unchanged.url]?.baseline.aim == savedAim)
            try await model.flushManualSaves()
        }
    }

    @Test func stockChangingPresetKeepsTheSavedAimWhileReopenedRollMeasurementsAreIncomplete() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            try AutoDecisionStateTests.writeToyStock("other", in: fixture.stocks)
            let first = fixture.model(), gate = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: first, through: gate)
            let firstFrames = try #require(first.roll?.frames)
            let stockID = try #require(first.currentStock?.id)
            let newStockID = try #require(first.films?.stocks.first { $0.id != stockID }?.id)
            gate.openAll(firstFrames)
            let kept = try #require(await first.settledDecision())
            await first.decisionSave?.value
            AutoDecisionStateTests.close(first, gate)

            let model = fixture.model(), waiting = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: model, through: waiting)
            defer { AutoDecisionStateTests.close(model, waiting) }
            let frames = try #require(model.roll?.frames), target = frames[1]
            let savedAim = try #require(kept.aims[target.url])
            try #require(model.isBalanced && model.autoDecision?.revision == kept.revision)
            try await waiting.waitUntilWaiting(for: frames.count)
            let preset = UserPreset(name: "Other Stock", includedParts: [.stock, .light], baseStockID: newStockID,
                                    adjustments: try ManualAdjustments(exposureEV: 0.5))
            waiting.release(target.url)
            let report = try #require(await model.applyPreset(preset, to: target)?.value)
            #expect(report.pasted == [target.url])
            try #require(model.analyses.count == 1)
            let partialAim = try #require(RollSmoothing.aims(frames, analyses: model.analyses)[target.url])
            try #require(partialAim.level != savedAim.level)
            let edit = try #require(model.manualEdits[target.url])
            #expect(edit.baseline.stockID == newStockID && edit.baseline.aim == savedAim)
            waiting.openAll(frames)
            let settled = try #require(await model.settledDecision())
            #expect(settled.aims[target.url] == savedAim && model.manualEdits[target.url]?.baseline.aim == savedAim)
            try await model.flushManualSaves()
        }
    }
}
