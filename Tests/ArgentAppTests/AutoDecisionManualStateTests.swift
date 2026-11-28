import ArgentCore
import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// The first manual edit pins the settled Auto decision even when settling needs no new render.
@MainActor @Suite(.serialized) struct AutoDecisionManualStateTests {
    @Test(arguments: [RollControls.LabBalance.neutral, .warm, .cool])
    func settlingAnIgnoredCastAllowsEditingAndPinsTheSettledAim(labBalance: RollControls.LabBalance) async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let model = fixture.model(), gate = MeasurementGate()
            for name in AutoDecisionStateTests.names {
                gate.analyses[name] = ExposureAnalysis(meanStops: 0.2, validWeight: 1, grayEstimate: [0, 0, 0])
            }
            gate.analyses[AutoDecisionStateTests.names[0]] = ExposureAnalysis(meanStops: 0.2, validWeight: 1,
                                                                            grayEstimate: [1, 0, -1])
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            model.controls.labBalance = labBalance
            let frames = try #require(model.roll?.frames), frame = frames[0], stock = model.stockIndex
            try await gate.waitUntilWaiting(for: frames.count)
            gate.release(frame.url)
            while !model.isMeasured(frame) { await Task.yield() }
            model.manualReadySources[frame.url] = try SourceDigests.shared.digest(of: frame.url)
            let shownAim = model.printAim(for: frame), shownSettings = model.settings(for: frame, stock: stock)
            model.recordVisibleAutomatic(for: frame, stock: stock, aim: shownAim, settings: shownSettings)
            let before = FilmRequest(frame: frame.url, stock: stock, settings: shownSettings, space: model.output.space,
                                     pixelSize: 960, analyzed: model.isMeasured(frame), source: model.sourceStamp(for: frame))
            #expect(!model.canAdjust(frame))

            gate.openAll(frames)
            let decision = try #require(await model.settledDecision())
            let settledAim = try #require(decision.aims[frame.url])
            #expect(settledAim.level == shownAim.level)
            #expect(settledAim.cast != shownAim.cast)
            let after = FilmRequest(frame: frame.url, stock: stock, settings: model.settings(for: frame, stock: stock),
                                    space: model.output.space, pixelSize: 960, analyzed: model.isMeasured(frame), source: model.sourceStamp(for: frame))
            // FramePicture's .task(id:) does not run again: the pixels already show the settled render.
            #expect(before == after)
            #expect(model.canAdjust(frame))
            // Keep the gesture open: this test exercises pinning, without saving an adjustment.
            model.beginManualGesture(for: frame)
            model.setManualAdjustments(try ManualAdjustments(exposureEV: 0.5), for: frame)
            let edit = try #require(model.manualEdits[frame.url])
            #expect(edit.baseline.aim == settledAim)
            #expect(edit.baseline.baseRender == Recipe.Render(settings: shownSettings, grain: model.output.grain))
            #expect(!model.hasUpdatedAuto(frame))

            // Switching this pin to Auto lab balance must use the settled cast, not the provisional one
            // that happened to produce the same picture under the original balance.
            let selectedStock = try #require(model.currentStock)
            let automatic = RollControls(labBalance: .auto)
            let resolved = try DevelopmentResolver.resolve(stock: selectedStock, stockDigest: model.stockDigests[stock],
                controls: automatic, aim: shownAim, manual: edit, grain: model.output.grain.amount, grainSeed: frame.grainSeed)
            #expect(resolved.labBalance == automatic.settings(for: selectedStock, aim: settledAim).labBalance)
            #expect(resolved.labBalance != automatic.settings(for: selectedStock, aim: shownAim).labBalance)
        }
    }

    /// A mask is a first edit: while the roll balances the tiles wait and no key gets past them, and once it has
    /// settled the first mask pins the settled Auto. Start from Original skips the wait, since it reads no decision.
    @Test(arguments: [false, true])
    func aFirstMaskWaitsForTheRollOrStartsFromOriginal(fromOriginal: Bool) async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let model = fixture.model(), gate = MeasurementGate()
            for name in AutoDecisionStateTests.names {
                gate.analyses[name] = ExposureAnalysis(meanStops: 0.2, validWeight: 1, grayEstimate: [0, 0, 0])
            }
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let frames = try #require(model.roll?.frames), frame = frames[0], stock = model.stockIndex
            model.selection = frame.id
            model.openFrame()
            defer { model.maskEditor.reset() }
            try await gate.waitUntilWaiting(for: frames.count)
            gate.release(frame.url)
            while !model.isMeasured(frame) { await Task.yield() }
            model.manualReadySources[frame.url] = try SourceDigests.shared.digest(of: frame.url)
            model.recordVisibleAutomatic(for: frame, stock: stock, aim: model.printAim(for: frame), settings: model.settings(for: frame, stock: stock))
            #expect(!model.canAdjust(frame) && !model.canAddMask(frame))
            #expect(model.adjustPreparation(for: frame) == "Balancing roll…")
            #expect(model.masksStandDown(frame))
            model.perform(.newMask(.linear))
            #expect(model.adjustTab == .masks && model.maskEditor.tool == nil, "the tab comes up and says why")
            #expect(!model.placeArmedGradient())

            if fromOriginal {
                // No waiting for the decision.
                model.startFrom(.original, for: frame)
                #expect(model.canAddMask(frame) && model.adjustPreparation(for: frame) == nil)
                model.perform(.newMask(.linear))
                #expect(model.placeArmedGradient())
                #expect(model.masks(for: frame).count == 1 && model.manualEdits[frame.url]?.baseline.origin == .original)
            } else {
                gate.openAll(frames)
                let decision = try #require(await model.settledDecision())
                let aim = try #require(decision.aims[frame.url])
                model.recordVisibleAutomatic(for: frame, stock: stock, aim: aim, settings: model.settings(for: frame, stock: stock))
                #expect(model.canAddMask(frame))
                model.perform(.newMask(.linear))
                #expect(model.placeArmedGradient())
                let edit = try #require(model.manualEdits[frame.url])
                #expect(edit.baseline.aim == aim && edit.adjustments.masks.count == 1 && edit.curveVersion == ManualRenderSettings.currentVersion)
                #expect(model.maskName(edit.adjustments.masks.masks[0].id, for: frame) == "Linear 1")
            }
        }
    }

    /// Update Automatic Baseline keeps the masks and their notes on the same picture. Reapply brings placed shapes and names onto
    /// new bytes, and a smart seed stays behind, since it measured the old picture.
    @Test func baselineUpdatesKeepMasksAndReapplyLeavesSmartSeedsBehind() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let model = fixture.model(), gate = MeasurementGate()
            for name in AutoDecisionStateTests.names {
                gate.analyses[name] = ExposureAnalysis(meanStops: 0.2, validWeight: 1, grayEstimate: [0, 0, 0])
            }
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let frames = try #require(model.roll?.frames), frame = frames[0], stock = model.stockIndex
            try await gate.waitUntilWaiting(for: frames.count)
            gate.openAll(frames)
            _ = try #require(await model.settledDecision())
            while !model.isMeasured(frame) { await Task.yield() }
            model.manualReadySources[frame.url] = try SourceDigests.shared.digest(of: frame.url)
            model.recordVisibleAutomatic(for: frame, stock: stock, aim: model.printAim(for: frame),
                                         settings: model.settings(for: frame, stock: stock))
            @MainActor func waitForEdit(_ done: () -> Bool) async throws {
                let start = Date()
                while !done() {
                    #expect(Date().timeIntervalSince(start) < 20, "the baseline update did not finish")
                    if Date().timeIntervalSince(start) >= 20 { return }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            let picture = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
            // A seed the library holds, as the selection's queue leaves it before a mask names it: the writer refuses one it lacks.
            let raster = try await model.storeMaskSeed(MaskRaster(width: 756, height: 504, plane: (0..<(756 * 504)).map { UInt8($0 % 756 / 3) }))
            let gradient = Mask(components: [MaskComponent(shape: .linear(.init(full: MaskPoint(x: 0.5, y: 0), zero: MaskPoint(x: 0.5, y: 0.5))))],
                                adjustments: try ManualAdjustments(exposureEV: -0.5))
            let sky = Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: raster, frame: picture)))],
                           adjustments: try ManualAdjustments(exposureEV: -0.7))
            // A Follow edges stroke with the shape it measured: a stored seed too, but it comes across with its stroke (L; plan section 7).
            let shapeRaster = try MaskRaster(width: 40, height: 24, plane: (0..<960).map { UInt8($0 % 251) })
            let shape = try await model.storeMaskSeed(shapeRaster)
            let followed = BrushStroke(followEdges: true, radius: 0.02, flow: 0.8, points: try PackedPoints.pack([MaskPoint(x: 0.2, y: 0.2), MaskPoint(x: 0.25, y: 0.21)]),
                                       measured: try MeasuredStroke(raster: shape, x: 300, y: 200, pictureWidth: 7008, pictureHeight: 4672))
            let painted = Mask(components: [MaskComponent(shape: .brush(BrushPaint(frame: picture, strokes: [followed])))],
                               adjustments: try ManualAdjustments(exposureEV: 0.4))
            let set = try MaskSet(masks: [gradient, sky, painted])
            let notes = MaskNotes(names: [gradient.id.uuidString: "Gradient", sky.id.uuidString: "Sky"],
                                  rasters: [raster.id.hex: RasterProvenance(engine: "coreml:da3", engineRevision: "1", operatingSystem: "test", app: "test",
                                      input: .init(kind: "neutral-print", width: 2048, height: 1365, colorSpace: "sRGB", sourceSHA256: "a"), created: Date(timeIntervalSince1970: 1000))])
            model.setManualAdjustments(try ManualAdjustments(highlights: -20, masks: set), for: frame)
            model.manualEdits[frame.url]?.maskNotes = notes
            model.manualEdits[frame.url]?.curveVersion = ManualRenderSettings.regionsVersion
            #expect(model.manualIssue(for: frame)?.contains("Update Automatic Baseline") == true)

            model.updateAutomaticBaseline(for: frame)
            try await waitForEdit { model.manualEdits[frame.url]?.curveVersion == ManualRenderSettings.currentVersion }
            #expect(model.manualAdjustments(for: frame).masks == set && model.manualEdits[frame.url]?.maskNotes == notes)
            #expect(model.manualIssue(for: frame) == nil)

            let held = try #require(model.manualEdits[frame.url])
            model.manualEdits[frame.url] = nil
            model.heldManualEdits[frame.url] = held
            model.reapplyManualAdjustments(for: frame)
            try await waitForEdit { model.manualEdits[frame.url] != nil }
            let reapplied = model.manualAdjustments(for: frame).masks
            #expect(reapplied.masks.map(\.id) == [gradient.id, sky.id, painted.id] && reapplied.rasters == [shape])
            let expected = try set.forAnotherPicture(freshIDs: false,
                geometry: model.maskLens(for: frame, settings: model.lensSettings(for: frame))?.picture)
            #expect(reapplied.masks[0].coverage == expected.masks[0].coverage && reapplied.masks[1].pendingSmart == [.sky])
            #expect(reapplied.masks[2].components == expected.masks[2].components && model.maskSeedStore.contains(shape.id))
            #expect(model.manualEdits[frame.url]?.maskNotes == MaskNotes(names: notes.names))
            try await model.flushManualSaves()
        }
    }

    /// A new edit takes the current Light compiler. An edit recorded with an older one keeps it while
    /// it is edited, crossing zero within a gesture included, and renders with it; Update Automatic
    /// Baseline, Reapply Adjustments and Reset to Current Auto adopt the current one.
    @Test(arguments: [ManualRenderSettings.regionsVersion, ManualRenderSettings.exposedBaseVersion])
    func editsKeepTheirLightCompilerUntilTheyAdoptTheCurrentOne(recorded: String) async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let model = fixture.model(), gate = MeasurementGate()
            for name in AutoDecisionStateTests.names {
                gate.analyses[name] = ExposureAnalysis(meanStops: 0.2, validWeight: 1, grayEstimate: [0, 0, 0])
            }
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let frames = try #require(model.roll?.frames), frame = frames[0], stock = model.stockIndex
            try await gate.waitUntilWaiting(for: frames.count)
            gate.openAll(frames)
            _ = try #require(await model.settledDecision())
            while !model.isMeasured(frame) { await Task.yield() }
            model.manualReadySources[frame.url] = try SourceDigests.shared.digest(of: frame.url)
            @MainActor func showAutomatic() {
                model.recordVisibleAutomatic(for: frame, stock: stock, aim: model.printAim(for: frame),
                                             settings: model.settings(for: frame, stock: stock))
            }
            @MainActor func waitForEdit(_ done: () -> Bool) async throws {
                let start = Date()
                while !done() {
                    #expect(Date().timeIntervalSince(start) < 20, "the baseline update did not finish")
                    if Date().timeIntervalSince(start) >= 20 { return }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            let current = ManualRenderSettings.currentVersion
            showAutomatic()
            #expect(model.canAdjust(frame))
            model.setManualAdjustments(try ManualAdjustments(highlights: -40), for: frame)
            #expect(model.manualEdits[frame.url]?.curveVersion == current)

            model.manualEdits[frame.url]?.curveVersion = recorded
            model.setManualAdjustments(try ManualAdjustments(highlights: -60, shadows: 20), for: frame)
            #expect(model.manualEdits[frame.url]?.curveVersion == recorded)
            model.beginManualGesture(for: frame)
            model.setManualAdjustments(.identity, for: frame)
            model.setManualAdjustments(try ManualAdjustments(shadows: 25), for: frame)
            model.endManualGesture(for: frame)
            #expect(model.manualEdits[frame.url]?.curveVersion == recorded)
            #expect(model.settings(for: frame, stock: stock).manual.version == recorded)

            model.updateAutomaticBaseline(for: frame)
            try await waitForEdit { model.manualEdits[frame.url]?.curveVersion == current }
            #expect(model.manualAdjustments(for: frame) == (try ManualAdjustments(shadows: 25)))
            #expect(model.settings(for: frame, stock: stock).manual.version == current)

            var held = try #require(model.manualEdits[frame.url])
            held.curveVersion = recorded
            model.manualEdits[frame.url] = nil
            model.heldManualEdits[frame.url] = held
            model.reapplyManualAdjustments(for: frame)
            try await waitForEdit { model.manualEdits[frame.url] != nil }
            #expect(model.manualEdits[frame.url]?.curveVersion == current && model.heldManualEdits[frame.url] == nil)

            model.manualEdits[frame.url]?.curveVersion = recorded
            model.resetManualAdjustments(for: frame)
            #expect(model.manualEdits[frame.url] == nil)
            showAutomatic()
            model.setManualAdjustments(try ManualAdjustments(whites: 30), for: frame)
            #expect(model.manualEdits[frame.url]?.curveVersion == current)
            try await model.flushManualSaves()
        }
    }

    /// Regression: Neutral's Auto polish must not keep `recordVisibleAutomatic` from recording the Auto render,
    /// which previously left untouched Neutral frames stuck at "Preparing Auto…" with Masks and Adjust disabled.
    /// Adding a mask pins Neutral's Auto polish in the baseline without jumping, Compare to Auto retains the polish,
    /// user Presence stacks on top, and Start from Original clears the Auto polish.
    @Test func neutralAutoBecomesAdjustableAndKeepsPolishUnderMasksAndOriginalClearsIt() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            try AutoDecisionStateTests.writeToyStock(NeutralAuto.stockID, in: fixture.stocks)
            let model = fixture.model(), gate = MeasurementGate()
            for name in AutoDecisionStateTests.names {
                gate.analyses[name] = ExposureAnalysis(meanStops: 0.2, validWeight: 1, grayEstimate: [0, 0, 0])
            }
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let neutralIndex = try #require(model.films?.stocks.firstIndex(where: { $0.id == NeutralAuto.stockID }))
            model.stockIndex = neutralIndex

            let frames = try #require(model.roll?.frames), frame = frames[0]
            model.selection = frame.id
            model.openFrame()
            defer { model.maskEditor.reset() }
            try await gate.waitUntilWaiting(for: frames.count)
            gate.openAll(frames)
            let decision = try #require(await model.settledDecision())
            let aim = try #require(decision.aims[frame.url])
            while !model.isMeasured(frame) { await Task.yield() }
            model.manualReadySources[frame.url] = try SourceDigests.shared.digest(of: frame.url)

            let autoRendered = model.settings(for: frame, stock: neutralIndex)
            #expect(autoRendered.manual == .identity)
            #expect(autoRendered.autoPresence.isActive && autoRendered.effectivePresence == NeutralAuto.polishPresence)
            #expect(model.automaticSettings(for: frame, stock: neutralIndex) == autoRendered)

            model.recordVisibleAutomatic(for: frame, stock: neutralIndex, aim: aim, settings: autoRendered)
            #expect(model.canAdjust(frame) && model.canAddMask(frame))
            #expect(model.adjustPreparation(for: frame) == nil)

            // Adding a mask pins Auto and keeps Neutral's polish intact without touching user Presence.
            model.perform(.newMask(.linear))
            #expect(model.placeArmedGradient())
            let edit = try #require(model.manualEdits[frame.url])
            #expect(edit.adjustments.masks.count == 1 && edit.adjustments.presence.isIdentity)
            let maskedSettings = model.settings(for: frame, stock: neutralIndex)
            #expect(maskedSettings.autoPresence == autoRendered.autoPresence)
            #expect(maskedSettings.effectivePresence == NeutralAuto.polishPresence)
            #expect(model.automaticSettings(for: frame, stock: neutralIndex) == autoRendered)

            // User Presence stacks additively on Neutral Auto's polish and cancels cleanly at -12 / -8.
            let cancelled = try edit.adjustments.settingPresence(Presence([
                .vibrance: -NeutralAuto.polishVibrance,
                .clarity: -NeutralAuto.polishClarity,
            ]))
            model.setManualAdjustments(cancelled, for: frame)
            #expect(model.settings(for: frame, stock: neutralIndex).effectivePresence.isIdentity)

            // Start from Original removes Neutral's Auto polish.
            model.startFrom(.original, for: frame)
            let originalEdit = try #require(model.manualEdits[frame.url])
            #expect(originalEdit.baseline.origin == .original && originalEdit.baseline.baseRender.autoPresence == nil)
            let originalSettings = model.settings(for: frame, stock: neutralIndex)
            #expect(!originalSettings.autoPresence.isActive && originalSettings.effectivePresence.isIdentity)
            #expect(!model.automaticSettings(for: frame, stock: neutralIndex).autoPresence.isActive)
            try await model.flushManualSaves()
        }
    }
}
