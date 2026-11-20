import ArgentCore
@testable import ArgentRoll
import Foundation
import AppKit
import SwiftUI
import Testing
@testable import ArgentApp

@MainActor @Suite(.serialized) struct LensAdjustmentsTests {
    private func withRoll(_ body: (RollModel, [Frame]) async throws -> Void) async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let model = fixture.model(), gate = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let frames = try #require(model.roll?.frames)
            gate.openAll(frames)
            _ = try #require(await model.settledDecision())
            model.manualUndoManager = UndoManager()
            model.manualUndoManager?.groupsByEvent = false
            try await body(model, frames)
        }
    }

    private func edit(_ model: RollModel, _ frame: Frame, _ values: ManualAdjustments) async throws {
        await model.prepareManualAdjustments(for: frame)
        model.recordVisibleAutomatic(for: frame, stock: model.stockIndex, aim: model.printAim(for: frame),
                                     settings: model.settings(for: frame, stock: model.stockIndex))
        step(model) { model.setManualAdjustments(values, for: frame) }
        #expect(model.manualAdjustments(for: frame) == values)
    }

    private func step(_ model: RollModel, _ body: () -> Void) {
        model.manualUndoManager?.beginUndoGrouping()
        body()
        model.manualUndoManager?.endUndoGrouping()
    }

    @Test func automaticSettingsKeepLensAndClearOtherEdits() async throws {
        try await withRoll { model, frames in
            let frame = frames[0]
            let lens = try LensSettings(arguments: "distortion-amount=150,vignette=-50,vignette-midpoint=75")
            try await edit(model, frame, try ManualAdjustments(exposureEV: 0.5, contrast: 20, lens: lens))
            let automatic = model.automaticSettings(for: frame, stock: model.stockIndex)
            #expect(automatic.manual.adjustments.lens == lens)
            #expect(automatic.manual.adjustments.clearing(.lens).isIdentity)
            #expect(model.manualAdjustments(for: frame).exposureEV == 0.5)
        }
    }

    @Test func automaticSettingsFallBackForAnUnknownRecordedCompiler() async throws {
        try await withRoll { model, frames in
            let frame = frames[0], stock = try #require(model.currentStock)
            try await edit(model, frame, try ManualAdjustments(exposureEV: 0.5))
            var recipe = try Recipe.make(frame: frame, byteCount: 1, stock: stock, stockDigest: stock.digest,
                                         roll: RollControls(), own: FrameControls(), manual: model.manualEdits[frame.url])
            let bytes = try JSONEncoder().encode(recipe.render.manual)
            let json = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: ManualRenderSettings.currentVersion, with: "future-compiler")
            recipe.render.manual = try JSONDecoder().decode(ManualRenderSettings.self, from: Data(json.utf8))
            model.manualEdits[frame.url]?.curveVersion = "future-compiler"
            model.manualRecipes[frame.url] = recipe
            #expect(model.settings(for: frame, stock: model.stockIndex).manual.version == "future-compiler")
            #expect(model.automaticSettings(for: frame, stock: model.stockIndex).manual == .identity)
        }
    }

    @Test func aRefusedAmountShowsTheResolversReason() throws {
        let curve = SonyLensCorrection.Curve(knots: (0..<16).map { $0 * 160 })
        let file = LensFile(correction: SonyLensCorrection(distortionSetting: 17, distortion: curve),
                            picture: try MaskSpace(width: 7008, height: 4672), metadata: nil)
        try #require(LensResolver.availability(file).distortion == .file(cameraOff: false))
        #expect(LensAdjustmentsView.distortionLine(file, settings: .default) == "Distortion, from the file")
        let strong = try LensSettings(arguments: "distortion-amount=200")
        try #require(LensResolver.resolve(file, settings: strong).status.distortion == .none("the amount is too strong for this lens"))
        #expect(LensAdjustmentsView.distortionLine(file, settings: strong) == "Distortion, the amount is too strong for this lens")
        #expect(LensAdjustmentsView.distortionLine(file, settings: strong.settingDistortion(isOn: false)) == "Distortion, from the file")
        var cameraOff = try #require(file.correction)
        cameraOff.distortionSetting = 0
        #expect(LensAdjustmentsView.distortionLine(LensFile(correction: cameraOff, picture: file.picture, metadata: nil), settings: .default)
            == "Distortion, from the file, camera set to Off")
        #expect(LensAdjustmentsView.distortionLine(LensFile(correction: nil, picture: nil, metadata: nil), settings: strong)
            == "Distortion, none in the file")
    }

    @Test func aSwitchFlipSuspendsAndResumesAnAmountGesture() async throws {
        try await withRoll { model, frames in
            let frame = frames[0]
            try await edit(model, frame, try ManualAdjustments(exposureEV: 0.5))
            model.manualUndoManager?.removeAllActions()
            step(model) {
                model.beginLightAdjusting(for: frame)
                model.moveLight(.lens(.distortion), to: 150, for: frame)
                let generation = model.lightGestureGeneration
                model.setDistortion(false, for: frame)
                #expect(model.lightGestureGeneration > generation)
                #expect(model.manualAdjustments(for: frame).lens.distortion.amount == 150)
                #expect(!model.lensSettings(for: frame).distortion.isOn)
                model.moveLight(.lens(.distortion), to: 175, for: frame)
                #expect(!model.lensSettings(for: frame).distortion.isOn)
                model.endLightAdjusting(for: frame)
            }
            #expect(model.manualAdjustments(for: frame).lens == (try LensSettings(arguments: "distortion=off,distortion-amount=175")))
        }
    }

    @Test func theDefaultOmitsLensAndKeepsTheOriginalBytes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(ManualAdjustments(lens: .default))
        #expect(data == (try encoder.encode(ManualAdjustments.identity)))
        #expect(String(decoding: data, as: UTF8.self) == #"{"blacks":0,"contrast":0,"exposureEV":0,"highlights":0,"shadows":0,"whites":0}"#)
    }

    @Test func nonDefaultLensNeedsNineAndAnEightReaderRefusesIt() async throws {
        try await withRoll { model, frames in
            let frame = frames[0], stock = try #require(model.currentStock)
            try await edit(model, frame, .identity.settingLens(try LensSettings(arguments: "distortion-amount=150")))
            let record = try Recipe.make(frame: frame, byteCount: 1, stock: stock, stockDigest: stock.digest,
                                         roll: RollControls(), own: FrameControls(), manual: model.manualEdits[frame.url])
            #expect(record.requiredVersion == 9 && record.version == 9)
            #expect(try Recipe.decodeStrict(record.encoded()) == record)
            #expect(throws: Recipe.ReadFailure.unsupportedVersion(9)) { try Recipe.decodeStrict(record.encoded(), readerVersion: 8) }
        }
    }

    @Test func aDragAndASwitchFlipAreEachOneUndoStep() async throws {
        try await withRoll { model, frames in
            let frame = frames[0]
            try await edit(model, frame, try ManualAdjustments(exposureEV: 0.5))
            model.manualUndoManager?.removeAllActions()
            let before = model.manualEdits[frame.url]
            step(model) {
                model.beginLightAdjusting(for: frame)
                model.moveLight(.lens(.distortion), to: 125, for: frame)
                model.moveLight(.lens(.distortion), to: 150, for: frame)
                #expect(model.manualEdits[frame.url] == before)
                #expect(model.lensSettings(for: frame).distortion.amount == 150)
                model.endLightAdjusting(for: frame)
            }
            #expect(model.manualAdjustments(for: frame).lens.distortion.amount == 150)
            model.manualUndoManager?.undo()
            #expect(model.manualEdits[frame.url] == before && model.manualUndoManager?.canUndo == false)
            model.manualUndoManager?.redo()
            model.manualUndoManager?.removeAllActions()
            step(model) { model.setDistortion(false, for: frame) }
            #expect(!model.lensSettings(for: frame).distortion.isOn && model.lensSettings(for: frame).distortion.amount == 150)
            model.manualUndoManager?.undo()
            #expect(model.lensSettings(for: frame).distortion.isOn && model.manualUndoManager?.canUndo == false)
        }
    }

    @Test func resetLensClearsLensAloneAndLensChangesKeepTheMaskDigest() async throws {
        try await withRoll { model, frames in
            let frame = frames[0]
            let mask = Mask(components: [.init(shape: .linear(.init(full: .init(x: 0, y: 0), zero: .init(x: 1, y: 1))))])
            let values = try ManualAdjustments(exposureEV: 0.5, masks: MaskSet(masks: [mask]), presence: Presence([.clarity: 20]))
            try await edit(model, frame, values)
            step(model) { model.moveLight(.lens(.distortion), to: 150, for: frame) }
            #expect(model.manualAdjustments(for: frame).masks.digest == values.masks.digest)
            let changed = model.manualEdits[frame.url]
            step(model) { InspectorMenus.resetLens(frame, model: model).choose() }
            #expect(model.manualAdjustments(for: frame) == values)
            model.manualUndoManager?.undo()
            #expect(model.manualEdits[frame.url] == changed)
        }
    }

    @Test func pasteOnlyLensAndPasteToShownCarryIntentInOneUndo() async throws {
        try await withRoll { model, frames in
            let source = frames[0], destination = frames[1]
            let lens = try LensSettings(arguments: "distortion-amount=150")
            try await edit(model, source, try ManualAdjustments(exposureEV: 1, lens: lens))
            try await edit(model, destination, try ManualAdjustments(exposureEV: -0.5))
            model.copyAdjustments(from: source)
            #expect(model.adjustmentsClipboard?.parts == [.light, .lens])
            #expect(AdjustmentParts.each.map(\.name) == ["light", "presence", "curve", "masks", "lens", "frameControls", "film"])
            model.pasteAdjustments(to: destination, parts: .lens)
            _ = try #require(await model.pasteTask?.value)
            #expect(model.lensSettings(for: destination) == lens && model.manualAdjustments(for: destination).exposureEV == -0.5)
            let before = model.manualEdits
            model.manualUndoManager?.removeAllActions()
            model.pasteAdjustmentsToShownFrames(parts: .lens)
            _ = try #require(await model.pasteTask?.value)
            #expect(frames.allSatisfy { model.lensSettings(for: $0) == lens })
            model.manualUndoManager?.undo()
            #expect(model.manualEdits == before && model.manualUndoManager?.canUndo == false)
            model.adjustmentsClipboard?.adjustments = try ManualAdjustments(exposureEV: 1)
            #expect(model.adjustmentsClipboard?.parts == [.light])
            model.pasteAdjustments(to: destination)
            _ = try #require(await model.pasteTask?.value)
            #expect(model.lensSettings(for: destination).isDefault, "Paste Adjustments carries the default too")
        }
    }

    @Test func masksRefuseLensAndArgumentsRoundTripWithoutUnknownKeys() throws {
        let lens = try LensSettings(arguments: "distortion=off,distortion-amount=150")
        #expect(try LensSettings(arguments: lens.arguments) == lens)
        #expect(throws: (any Error).self) { try LensSettings(arguments: "vignetting=on") }
        #expect(throws: (any Error).self) {
            try MaskSet(masks: [Mask(components: [.init(shape: .linear(.init(full: .init(x: 0, y: 0), zero: .init(x: 1, y: 1))))],
                                      adjustments: .identity.settingLens(lens))])
        }
    }
}

#if DEBUG
extension LensAdjustmentsTests {
    @Test(.enabled(if: hasLensGeometrySample))
    func theLoadedLensTabAndFrameMenusUseTheFilesCurve() async throws {
        let shown = UserDefaults.standard.object(forKey: "manualInspectorShown")
        let tab = UserDefaults.standard.object(forKey: AdjustInspectorTab.storageKey)
        defer {
            UserDefaults.standard.set(shown, forKey: "manualInspectorShown")
            UserDefaults.standard.set(tab, forKey: AdjustInspectorTab.storageKey)
        }
        try await AutoDecisionStateTests.withRoll { fixture in
            try cloneLensGeometrySample(to: fixture.raw(0))
            let model = fixture.model(), gate = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let frames = try #require(model.roll?.frames), frame = frames[0]
            gate.openAll(frames)
            _ = try #require(await model.settledDecision())
            try await edit(model, frame, try ManualAdjustments(exposureEV: 0.5))
            model.selection = frame.id
            model.openFrame()
            model.adjustTab = .lens
            model.isAdjustmentsShown = true
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let loaded = try #require(await model.films?.lensFile(for: frame))
            model.isInspectorDefringeExpanded = true
            let host = NSHostingView(rootView: LensAdjustmentsView(frame: frame, file: loaded).environment(model))
            window.contentView = host
            let root = try #require(window.contentView)
            for _ in 0..<300 {
                root.layoutSubtreeIfNeeded()
                if AdjustmentSliderControl.sliders(in: .lens, under: root).first?.isEnabled == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(LensAdjustmentsView.lensLine(loaded) == "FE 50mm F2.5 G, 50 mm, f/5.6")
            #expect(LensAdjustmentsView.distortionLine(loaded, settings: model.lensSettings(for: frame)) == "Distortion, from the file")
            let amount = try #require(AdjustmentSliderControl.sliders(in: .lens, under: root).first)
            #expect(amount.isEnabled && amount.doubleValue == 100)
            let windowNumber = window.windowNumber
            func key(_ text: String) throws -> NSEvent {
                try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: windowNumber, context: nil, characters: text,
                                             charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0))
            }
            #expect(window.makeFirstResponder(amount))
            amount.keyDown(with: try key("."))
            let purple = try #require(AdjustmentSliderControl.sliders(in: .lens, under: root).first { $0.spec.title == "Purple Amount" })
            #expect(window.firstResponder === purple)
            purple.keyDown(with: try key(","))
            #expect(window.firstResponder === amount)
            amount.keyDown(with: try key("+"))
            #expect(model.lensSettings(for: frame).distortion.amount == 105)
            #expect(model.menuState.canSetDistortion && model.menuState.isDistortionOn && model.menuState.canResetLens)
            step(model) { InspectorMenus.lensDistortion(frame, model: model).choose() }
            #expect(!model.menuState.isDistortionOn && model.menuState.canSetDistortion)
            step(model) { InspectorMenus.resetLens(frame, model: model).choose() }
            #expect(model.lensSettings(for: frame).isDefault && !model.menuState.canResetLens)
            #expect(model.manualAdjustments(for: frame).exposureEV == 0.5)
            model.manualErrors[frame.url] = "unavailable edit"
            #expect(!model.menuState.canSetDistortion && !model.menuState.canResetLens)
            #expect(!InspectorMenus.lensDistortion(frame, model: model).isEnabled)
            #expect(!InspectorMenus.resetLens(frame, model: model).isEnabled)
            model.manualErrors[frame.url] = nil
            model.closeFrame()
            #expect(!model.menuState.canSetDistortion && !model.menuState.canResetLens)
        }
    }

    @Test(.enabled(if: hasLensGeometrySample))
    func pasteOnlyLensResolvesTheDestinationsOwnCurveWithoutAHeldDecode() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            try cloneLensGeometrySample(to: fixture.raw(0))
            try cloneLensGeometrySample(to: fixture.raw(1))
            let original = LensFile(reading: fixture.raw(1))
            let knots = try #require(original.correction?.distortion?.knots)
            func shorts(_ values: [Int]) -> Data {
                Data(values.flatMap { value -> [UInt8] in
                    let bits = UInt16(bitPattern: Int16(value))
                    return [UInt8(bits & 255), UInt8(bits >> 8)]
                })
            }
            var bytes = try Data(contentsOf: fixture.raw(1))
            let range = try #require(bytes.range(of: shorts([16] + knots)))
            bytes.replaceSubrange(range, with: shorts([16] + knots.map { $0 * 2 }))
            try bytes.write(to: fixture.raw(1), options: .atomic)
            let model = fixture.model(), gate = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let frames = try #require(model.roll?.frames)
            gate.openAll(frames)
            _ = try #require(await model.settledDecision())
            let source = try #require(frames.first { $0.url.lastPathComponent == fixture.raw(0).lastPathComponent })
            let destination = try #require(frames.first { $0.url.lastPathComponent == fixture.raw(1).lastPathComponent })
            let settings = try LensSettings(arguments: "distortion-amount=150")
            try await edit(model, source, .identity.settingLens(settings))
            model.copyAdjustments(from: source)
            #expect(model.films?.decodeCount == 0)
            model.pasteAdjustments(to: destination, parts: .lens)
            _ = try #require(await model.pasteTask?.value)
            _ = await model.films?.lensFile(for: destination)
            let resolved = try #require(model.films?.lensCorrection(for: destination, settings: model.lensSettings(for: destination)))
            let expected = LensResolver.correction(for: destination.url, settings: settings)
            let sourceCurve = LensResolver.correction(for: source.url, settings: settings)
            #expect(model.lensSettings(for: destination) == settings)
            #expect(resolved.status.distortion == .file && resolved.digest == expected.digest)
            #expect(resolved.geometry != sourceCurve.geometry)
            #expect(model.films?.decodeCount == 0, "pasting intent does not decode")
        }
    }
}
#endif

extension LensAdjustmentsTests {
    @Test func defringeRowsWorkWithoutAFileCurveAndKeepTheirOwnSpecs() async throws {
        try await withRoll { model, frames in
            let frame = frames[0]
            try await edit(model, frame, try ManualAdjustments(exposureEV: 0.5))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = NSHostingView(rootView: LensAdjustmentsView(frame: frame).environment(model))
            let root = try #require(window.contentView)
            for _ in 0..<300 {
                root.layoutSubtreeIfNeeded()
                if !AdjustmentSliderControl.sliders(in: .lens, under: root).isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let folded = AdjustmentSliderControl.sliders(in: .lens, under: root)
            #expect(folded.map(\.spec.order) == [.distortion, .vignette, .vignetteMidpoint].map { AdjustmentSliderSpec.lensAmount($0).order })
            model.isInspectorDefringeExpanded = true
            for _ in 0..<300 {
                root.layoutSubtreeIfNeeded()
                if AdjustmentSliderControl.sliders(in: .lens, under: root).count == LensSettings.Control.allCases.count { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let sliders = AdjustmentSliderControl.sliders(in: .lens, under: root)
            #expect(sliders.count == LensSettings.Control.allCases.count)
            for (index, control) in LensSettings.Control.allCases.enumerated() {
                let slider = try #require(sliders.first { $0.spec.order == index })
                // A hue range's two ends are read on the strip they share, 0 to 100, and each knows the other; every other
                // row keeps its control's own range.
                let isHue = [LensSettings.Control.purpleHueLow, .purpleHueHigh, .greenHueLow, .greenHueHigh].contains(control)
                #expect(slider.spec.range == (isHue ? 0...100 : control.range) && slider.spec.defaultValue == control.defaultValue)
                #expect((slider.spec.trackPartner != nil) == isHue, "\(control)")
                #expect(slider.doubleValue == Double(control.defaultValue))
                #expect(slider.isEnabled == (control != .distortion && control != .vignetteMidpoint))
            }
            let low = try #require(sliders.first { $0.spec.title == "Purple Hue Low" })
            let high = try #require(sliders.first { $0.spec.title == "Purple Hue High" })
            // One track for the two, High laid over Low, each stopped ten short of the other.
            #expect(low.spec.trackPartner == high.spec.order && high.spec.trackPartner == low.spec.order)
            #expect(low.convert(low.bounds, to: nil) == high.convert(high.bounds, to: nil))
            #expect(low.limits == 0...60 && high.limits == 40...100)
            let windowNumber = window.windowNumber
            func key(_ text: String) throws -> NSEvent {
                try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: windowNumber, context: nil, characters: text,
                                             charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0))
            }
            #expect(window.makeFirstResponder(low))
            low.keyDown(with: try key("."))
            #expect(window.firstResponder === high)
            high.keyDown(with: try key(","))
            #expect(window.firstResponder === low)
            let increment = try key("=")
            for _ in 0..<10 { step(model) { low.keyDown(with: increment) }; root.layoutSubtreeIfNeeded() }
            #expect(model.lensSettings(for: frame).defringe.purpleHue == 60...70)
            step(model) { low.onReset?() }
            #expect(model.lensSettings(for: frame).defringe.purpleHue == 30...70)
            // A press on the track is the nearer end's, whichever of the two lies on top: a double-click where Low's knob
            // stands, given to High, resets Low and leaves High, and one where High's stands resets High.
            step(model) {
                model.moveLight(.lens(.purpleHueHigh), to: 90, for: frame)
                model.moveLight(.lens(.purpleHueLow), to: 50, for: frame)
            }
            for _ in 0..<100 where low.doubleValue != 50 || high.doubleValue != 90 {
                root.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(low.doubleValue == 50 && high.doubleValue == 90 && low.limits == 0...80 && high.limits == 60...100)
            func doubleClick(atKnobOf slider: AdjustmentSliderControl) throws -> NSEvent {
                let knob = try #require(slider.cell as? NSSliderCell).knobRect(flipped: slider.isFlipped)
                return try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: slider.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil),
                                                       modifierFlags: [], timestamp: 0, windowNumber: windowNumber, context: nil,
                                                       eventNumber: 0, clickCount: 2, pressure: 1))
            }
            let atLow = try doubleClick(atKnobOf: low), atHigh = try doubleClick(atKnobOf: high)
            // A right-click is the nearer end's too: High lies on top and is the view a press at Low's knob reaches, and the
            // menu it gives there is Low's, not its own.
            #expect(root.hitTest(low.convert(NSPoint(x: try #require(low.cell as? NSSliderCell).knobRect(flipped: low.isFlipped).midX, y: 8), to: root.superview)) === high)
            #expect(high.menu(for: atLow)?.items.first?.title == "Reset Purple Hue Low")
            #expect(high.menu(for: atHigh)?.items.first?.title == "Reset Purple Hue High")
            #expect(low.menu(for: atHigh)?.items.first?.title == "Reset Purple Hue High")
            #expect(low.menu(for: atLow)?.items.first?.title == "Reset Purple Hue Low")
            step(model) { high.mouseDown(with: atLow) }
            #expect(model.lensSettings(for: frame).defringe.purpleHue == 30...90)
            step(model) { low.mouseDown(with: atHigh) }
            #expect(model.lensSettings(for: frame).defringe.purpleHue == 30...70)

            // A scrub over an end's value counts along the strip's whole 0 to 100, and is held to the end's limits by its row:
            // Low scrubbed to 95 with High at 70 stops at 60, in the value, in the print and where its knob stands, so the
            // knob never passes High's.
            @MainActor func scrubber(_ title: String) throws -> ValueScrubView {
                @MainActor func found(_ view: NSView) -> [ValueScrubView] { ((view as? ValueScrubView).map { [$0] } ?? []) + view.subviews.flatMap(found) }
                return try #require(found(root).first { $0.spec.title == title })
            }
            // Once the rows have been drawn with the range the resets left, as they are before any pointer reaches them.
            for _ in 0..<100 where low.limits != 0...60 || low.doubleValue != 30 {
                root.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(low.limits == 0...60 && high.limits == 40...100)
            let scrub = try scrubber("Purple Hue Low")
            model.manualUndoManager?.beginUndoGrouping()
            scrub.onEditingChanged?(true)
            scrub.onScrub?(95)
            for _ in 0..<100 where low.doubleValue != 60 {
                root.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(low.doubleValue == 60 && high.doubleValue == 70, "the low knob stands at \(low.doubleValue)")
            #expect(model.lensSettings(for: frame).defringe.purpleHue == 60...70)
            scrub.onEditingChanged?(false)
            model.manualUndoManager?.endUndoGrouping()
            #expect(model.manualAdjustments(for: frame).lens.defringe.purpleHue == 60...70)
            step(model) { model.resetLensHue(low: .purpleHueLow, high: .purpleHueHigh, for: frame) }
            #expect(model.lensSettings(for: frame).defringe.purpleHue == 30...70)
            step(model) { model.moveLight(.lens(.purpleAmount), to: 8, for: frame) }
            #expect(model.lensSettings(for: frame).defringe.purpleAmount == 8)
            step(model) { InspectorMenus.resetLens(frame, model: model).choose() }
            #expect(model.lensSettings(for: frame).isDefault)
            #expect(model.manualAdjustments(for: frame).exposureEV == 0.5)
        }
    }

    /// A hue range's reset, its name double-clicked or the arrow beside it: both ends at their defaults in one undo step,
    /// from wherever they stand. Each end is stopped ten short of the other as it is set, so the end that has room goes
    /// first; set in the other order, the first would be stopped short and left there.
    @Test func aHueRangesResetReturnsBothEndsFromEitherSide() async throws {
        try await withRoll { model, frames in
            let frame = frames[0]
            try await edit(model, frame, try ManualAdjustments(exposureEV: 0.5))
            let undo = try #require(model.manualUndoManager)
            for (low, high, defaults) in [(LensSettings.Control.purpleHueLow, LensSettings.Control.purpleHueHigh, Float(30)...Float(70)),
                                          (.greenHueLow, .greenHueHigh, 40...60)] {
                @MainActor func range() -> ClosedRange<Float> {
                    let lens = model.manualAdjustments(for: frame).lens
                    return lens.value(for: low)...lens.value(for: high)
                }
                // Above both defaults: Low's default has room under High, and goes first.
                // Below both: High stands under Low's default, and goes first.
                for moved in [Float(80)...Float(95), 5...15, defaults.lowerBound...95, 5...defaults.upperBound] {
                    step(model) {
                        // Whichever end has room first, as the reset itself must choose.
                        let first = moved.lowerBound <= model.manualAdjustments(for: frame).lens.value(for: high) - RollModel.lensHueGap ? low : high
                        for control in [first, first == low ? high : low] {
                            model.moveLight(.lens(control), to: control == low ? moved.lowerBound : moved.upperBound, for: frame)
                        }
                    }
                    #expect(range() == moved, "\(low) set to \(moved)")
                    step(model) { model.resetLensHue(low: low, high: high, for: frame) }
                    #expect(range() == defaults, "\(low) from \(moved)")
                    // One step: undoing it puts both ends back where they stood.
                    undo.undo()
                    #expect(range() == moved, "\(low) undone to \(moved)")
                    undo.redo()
                    #expect(range() == defaults)
                }
                // At its defaults a reset is nothing, and no undo step.
                let before = undo.undoActionName, canUndo = undo.canUndo
                model.resetLensHue(low: low, high: high, for: frame)
                #expect(undo.undoActionName == before && undo.canUndo == canUndo && range() == defaults)
            }
            #expect(model.manualAdjustments(for: frame).exposureEV == 0.5)
        }
    }

    @Test func defringeArgumentsAndMovedHueHandlesKeepTheOtherEnd() throws {
        let value = try LensSettings(arguments: "defringe-purple=8,defringe-purple-hue=20:80,defringe-green=4,defringe-green-hue=30:70")
        #expect(try LensSettings(arguments: value.arguments) == value)
        for argument in ["defringe-purple=21","defringe-green=-1","defringe-purple-hue=50:59",
                         "defringe-purple-hue=90:80","defringe-green-hue=0:101","defringe-purple=nan",
                         "defringe-purple=1,defringe-purple=2"] {
            #expect(throws: (any Error).self) { try LensSettings(arguments: argument) }
        }
        let pairs: [(LensSettings.Control, LensSettings.Control)] = [(.purpleHueLow,.purpleHueHigh),(.greenHueLow,.greenHueHigh)]
        for (low,high) in pairs {
            let original = LensSettings.default
            let movedLow = try original.setting(low,to: 100)
            #expect(movedLow.value(for: low) == original.value(for: high)-10)
            #expect(movedLow.value(for: high) == original.value(for: high))
            let movedHigh = try original.setting(high,to: -100)
            #expect(movedHigh.value(for: high) == original.value(for: low)+10)
            #expect(movedHigh.value(for: low) == original.value(for: low))
            #expect(try movedHigh.setting(low,to: low.defaultValue).value(for: high) == movedHigh.value(for: high))
        }
        for control in LensSettings.Control.allCases {
            #expect(control.defaultValue == LensSettings.default.value(for: control))
            #expect(ManualAdjustments.Slider.lens(control).range == control.range)
        }
        #expect(value.settingDistortion(isOn: false).defringe == value.defringe)
    }
}
