import AppKit
import ArgentCore
import ArgentRoll
import Testing
@testable import ArgentApp

@MainActor @Suite(.serialized) struct AdjustmentSliderTests {
    private func fixture(_ control: ManualAdjustments.Control) -> (AdjustmentSliderControl, SliderActions) {
        _ = NSApplication.shared
        let slider = AdjustmentSliderControl()
        slider.spec = .light(control)
        slider.doubleValue = 0
        let actions = SliderActions()
        slider.target = actions
        slider.action = #selector(SliderActions.changed(_:))
        slider.onEditingChanged = { actions.phases.append($0) }
        slider.onClipping = { actions.clipping.append($0) }
        return (slider, actions)
    }

    /// The Light tab's eleven sliders, and a curve region's before them, in a window, Exposure focused.
    private func window() -> (NSWindow, [ManualAdjustments.Slider: AdjustmentSliderControl], AdjustmentSliderControl) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 520), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 520))
        window.contentView = content
        let region = AdjustmentSliderControl(frame: NSRect(x: 10, y: 490, width: 200, height: 24))
        region.spec = .light(.shadows, group: nil)
        content.addSubview(region)
        var sliders: [ManualAdjustments.Slider: AdjustmentSliderControl] = [:]
        for (index, tabSlider) in (ManualAdjustments.Control.allCases.map(ManualAdjustments.Slider.light) + Presence.Control.allCases.map(ManualAdjustments.Slider.presence)).enumerated() {
            let slider = AdjustmentSliderControl(frame: NSRect(x: 10, y: 450 - 40 * index, width: 200, height: 24))
            slider.spec = .light(tabSlider)
            content.addSubview(slider)
            sliders[tabSlider] = slider
        }
        #expect(window.makeFirstResponder(sliders[.light(.exposure)]))
        return (window, sliders, region)
    }

    private func typed(_ text: String, flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) throws -> NSEvent {
        // + and _ are Shift-= and Shift-−, unless + comes from the keypad.
        let shifted = (text == "+" || text == "_") && !flags.contains(.numericPad)
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: shifted ? flags.union(.shift) : flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: keyCode))
    }

    private func modifiers(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58))
    }

    private func key(_ key: NSEvent.SpecialKey, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let text = String(try #require(UnicodeScalar(key.rawValue)))
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: flags.union(.function), timestamp: 0, windowNumber: 0, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0))
    }

    @Test func nativeArrowKeysUseThePhotographicStepAndOneGesture() throws {
        let (slider, actions) = fixture(.exposure)
        slider.keyDown(with: try key(.rightArrow))
        #expect(abs(slider.doubleValue - 0.05) < 0.000001)
        #expect(actions.values.count == 1)
        #expect(actions.phases == [true, false])
        slider.keyDown(with: try key(.leftArrow))
        #expect(slider.doubleValue == 0)
        slider.keyDown(with: try key(.upArrow, flags: .shift))
        #expect(abs(slider.doubleValue - 0.5) < 0.000001)
        #expect(actions.values.count == 3 && actions.phases == [true, false, true, false, true, false])
    }

    @Test func toneKeysAndAccessibilityHaveTheSameStepAndClampAtTheEndpoints() throws {
        let (slider, actions) = fixture(.shadows)
        slider.keyDown(with: try key(.rightArrow))
        #expect(slider.doubleValue == 1)
        #expect(slider.accessibilityPerformDecrement())
        #expect(slider.doubleValue == 0)
        slider.keyDown(with: try key(.home))
        #expect(slider.doubleValue == -100)
        let before = actions.values.count
        slider.keyDown(with: try key(.leftArrow))
        #expect(actions.values.count == before && slider.doubleValue == -100)
        slider.keyDown(with: try key(.end))
        #expect(slider.doubleValue == 100)
        #expect(slider.accessibilityPerformIncrement())
        #expect(slider.doubleValue == 100)
        #expect(actions.phases.count == actions.values.count * 2)
    }

    @Test func accessibleValueEntrySnapsAndRejectsInvalidOrDisabledEdits() throws {
        let (slider, actions) = fixture(.exposure)
        slider.setAccessibilityValue(NSNumber(value: 0.833))
        #expect(Float(slider.doubleValue) == 0.83)
        #expect(actions.phases == [true, false])
        slider.setAccessibilityValue(NSNumber(value: Double.nan))
        #expect(actions.values.count == 1)
        slider.isEnabled = false
        slider.setAccessibilityValue(NSNumber(value: 2))
        slider.keyDown(with: try key(.rightArrow))
        #expect(!slider.accessibilityPerformIncrement())
        #expect(!slider.accessibilityPerformDecrement())
        #expect(actions.values.count == 1 && actions.phases == [true, false])
    }

    @Test func lightroomKeysStepExposureByATenthAndAThirdOfAStop() throws {
        let (slider, actions) = fixture(.exposure)
        let expected: [(String, Float)] = [("=", 0.1), ("+", 0.43), ("-", 0.33), ("+", 0.66), ("+", 0.99), ("_", 0.66), ("-", 0.56)]
        for (key, value) in expected {
            slider.keyDown(with: try typed(key))
            #expect(Float(slider.doubleValue) == value, "\(key)")
        }
        #expect(actions.values.count == expected.count && actions.phases.count == expected.count * 2)
        // Arrows keep Argent's fine step, from wherever = and − left the value.
        slider.keyDown(with: try key(.rightArrow))
        #expect(Float(slider.doubleValue) == 0.61)
        slider.keyDown(with: try key(.end))
        slider.keyDown(with: try typed("="))
        #expect(slider.doubleValue == 5 && actions.values.count == expected.count + 2)
        slider.keyDown(with: try key(.home))
        #expect(slider.doubleValue == -5)
    }

    @Test func lightroomKeysStepTheOtherFiveByFiveAndTwentyAndLeaveMenuKeysAlone() throws {
        let (slider, actions) = fixture(.whites)
        for (key, value) in [("=", 5), ("+", 25), ("-", 20), ("_", 0), ("_", -20)] as [(String, Double)] {
            slider.keyDown(with: try typed(key))
            #expect(slider.doubleValue == value, "\(key)")
        }
        // Keypad + without Shift is the small step.
        slider.keyDown(with: try typed("+", flags: .numericPad))
        #expect(slider.doubleValue == -15)
        let before = actions.values.count
        // Command and Control keep their menu shortcuts (Zoom In is ⌘+).
        slider.keyDown(with: try typed("=", flags: .command))
        slider.keyDown(with: try typed("-", flags: .control))
        #expect(slider.doubleValue == -15 && actions.values.count == before)
        // A curve region's slider borrows the range but not Lightroom's keys.
        let (region, regionActions) = fixture(.shadows)
        region.spec.group = nil
        region.keyDown(with: try typed("="))
        region.keyDown(with: try key(.rightArrow))
        #expect(region.doubleValue == 1 && regionActions.values.count == 1)
    }

    /// One walk round the Light tab's eleven: Light's six, on into Presence's five, and round the end, in the tab's order.
    @Test func periodAndCommaMoveFocusRoundTheLightTabsElevenSliders() throws {
        let (window, sliders, region) = window()
        defer { window.close() }
        @MainActor func focused() -> AdjustmentSliderControl? { window.firstResponder as? AdjustmentSliderControl }
        var walked: [AdjustmentSliderControl] = []
        for _ in (ManualAdjustments.Control.allCases.map(ManualAdjustments.Slider.light) + Presence.Control.allCases.map(ManualAdjustments.Slider.presence)) {
            walked += focused().map { [$0] } ?? []
            focused()?.keyDown(with: try typed(".", keyCode: 47))
        }
        #expect(walked.map(\.spec.title) == ["Exposure", "Contrast", "Highlights", "Shadows", "Whites", "Blacks",
                                              "Texture", "Clarity", "Dehaze", "Vibrance", "Saturation"])
        #expect(window.firstResponder === sliders[.light(.exposure)])
        sliders[.light(.exposure)]?.keyDown(with: try typed(",", keyCode: 43))
        #expect(window.firstResponder === sliders[.presence(.saturation)])
        // Back out of Presence into Light.
        #expect(window.makeFirstResponder(sliders[.presence(.texture)]))
        sliders[.presence(.texture)]?.keyDown(with: try typed(",", keyCode: 43))
        #expect(window.firstResponder === sliders[.light(.blacks)])
        #expect(window.makeFirstResponder(sliders[.light(.exposure)]))
        for _ in 0..<3 { focused()?.keyDown(with: try typed(".", keyCode: 47)) }
        // Shadows is the Light slider, never the curve region's that borrows its range.
        #expect(window.firstResponder === sliders[.light(.shadows)] && window.firstResponder !== region)
        #expect(sliders.values.allSatisfy { $0.doubleValue == 0 })
    }

    @Test func optionHeldOnAFocusedLightSliderShowsTheClippingViewUntilReleased() async throws {
        let (window, sliders, _) = window()
        defer { window.close() }
        let exposure = try #require(sliders[.light(.exposure)])
        // Its own wait and pointer, so no suite running beside it can change either.
        exposure.optionWait = .milliseconds(1)
        exposure.isPointerOverArmedCanvas = { false }
        var shown: [Bool] = []
        exposure.onClipping = { shown.append($0) }
        exposure.flagsChanged(with: try modifiers(.option))
        // The wait is the slider's own task; a loaded machine can hold it past any fixed sleep (B3: 100 ms lost it in a full `swift test`).
        for _ in 0..<500 where shown.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shown == [true] && exposure.isClipping)
        // Shift added keeps it; Option released ends it.
        exposure.flagsChanged(with: try modifiers([.option, .shift]))
        exposure.flagsChanged(with: try modifiers([]))
        #expect(shown == [true, false] && !exposure.isClipping)
        // A chord such as ⌥⌘1 never shows it, and Option released early cancels the wait.
        exposure.flagsChanged(with: try modifiers([.option, .command]))
        exposure.flagsChanged(with: try modifiers(.option))
        exposure.flagsChanged(with: try modifiers([]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(shown == [true, false])
        // A key step made with Option shows it at once; losing focus ends it.
        exposure.keyDown(with: try typed("=", flags: .option))
        #expect(shown == [true, false, true] && Float(exposure.doubleValue) == 0.1)
        exposure.keyDown(with: try typed(".", keyCode: 47))
        #expect(window.firstResponder === sliders[.light(.contrast)] && shown == [true, false, true, false])
        // Disabled, it never shows.
        let contrast = try #require(sliders[.light(.contrast)])
        contrast.isEnabled = false
        contrast.onClipping = { shown.append($0) }
        contrast.flagsChanged(with: try modifiers(.option))
        try await Task.sleep(for: .milliseconds(100))
        #expect(shown.count == 4 && !contrast.isClipping)
    }

    @Test func eachControlNamesLightroomsClippingView() {
        #expect(ManualAdjustments.Control.allCases.map(\.clipping)
                == [.highlights, nil, .highlights, .shadows, .highlights, .shadows])
    }
}

/// The spec the sliders share: the Light tab's six as they always were, and what a mask's Amount needs.
extension AdjustmentSliderTests {
    /// The row's words, restated as they stood before the row was made generic.
    private func formattedAsItWas(_ value: Float, _ control: ManualAdjustments.Control) -> String {
        value.formatted(.number.precision(.fractionLength(control == .exposure ? 2 : 0))
            .sign(strategy: .always(includingZero: false)))
    }

    @Test func aLightSpecIsItsControls() {
        for control in ManualAdjustments.Control.allCases {
            let spec = AdjustmentSliderSpec.light(control)
            #expect(spec.title == control.title && spec.range == control.range && spec.step == control.step)
            #expect(spec.defaultValue == 0 && spec.polarity == .bipolar && spec.group == .light)
            #expect(spec.arrowStep == control.arrowStep && spec.clipping == control.clipping)
            #expect(spec.keyStep(large: false) == control.keyStep(large: false) && spec.keyStep(large: true) == control.keyStep(large: true))
            #expect(spec.order == ManualAdjustments.Control.allCases.firstIndex(of: control))
            // The track as it was: filled from its centre, the mark on it.
            #expect(spec.fillOrigin == 0.5 && spec.markFraction == 0.5)
            #expect(spec.fraction(of: control.range.lowerBound) == 0 && spec.fraction(of: control.range.upperBound) == 1)
            for value in [control.range.lowerBound, -1.5, 0, 0.33, 37, control.range.upperBound] where control.range.contains(value) {
                #expect(spec.formatted(value) == formattedAsItWas(value, control))
                #expect(spec.spoken(value) == formattedAsItWas(value, control) + (control == .exposure ? " EV" : ""))
                #expect(spec.snapped(value) == control.snapped(value))
            }
        }
    }

    @Test func aCurveRegionBorrowsARangeWithoutTheKeys() {
        let region = AdjustmentSliderSpec.light(.shadows, group: nil)
        #expect(region.group == nil && region.range == -100...100)
        #expect(region.sliderHelp("Shape it.") == "Shape it. Double-click to reset. Arrows step it, Shift in larger steps. Hold Option as you drag to see clipped shadows.")
    }

    /// What the Light tab's help tags and VoiceOver hints say, word for word.
    @Test func theLightRowsSayWhatTheySaid() {
        let keys = " Double-click to reset. Arrows, = and − step it, Shift in larger steps; . and , move to the next or previous slider."
        for control in ManualAdjustments.Control.allCases {
            let spec = AdjustmentSliderSpec.light(control)
            let clipping = control.clipping == .highlights ? " Hold Option as you drag to see clipped highlights."
                : control.clipping == .shadows ? " Hold Option as you drag to see clipped shadows." : ""
            #expect(spec.sliderHelp(control.adjustmentHelp) == control.adjustmentHelp + keys + clipping)
            let limits = "Enter \(formattedAsItWas(control.range.lowerBound, control)) to \(formattedAsItWas(control.range.upperBound, control))\(control == .exposure ? " EV" : "")."
            #expect(spec.entryLimits == limits)
            #expect(spec.entryHelp(control.adjustmentHelp) == limits + " " + control.adjustmentHelp)
        }
        #expect(ManualAdjustments.Control.exposure.adjustmentHelp == "Change scene exposure entering the film, in EV. +1 EV doubles the light; Rated at remains independent.")
    }

    /// Presence's five: -100 to +100 in whole steps, after Light's six in the tab's walk, with no clipping view, so their help
    /// promises none and Option shows nothing on them.
    @Test func aPresenceSpecIsItsControlsAfterLightsSixWithNoClippingView() {
        let keys = " Double-click to reset. Arrows, = and − step it, Shift in larger steps; . and , move to the next or previous slider."
        for (index, control) in Presence.Control.allCases.enumerated() {
            let spec = AdjustmentSliderSpec.light(.presence(control))
            #expect(spec.title == control.title && spec.range == -100...100 && spec.step == 1, "\(control)")
            #expect(spec.defaultValue == 0 && spec.polarity == .bipolar && spec.group == .light && spec.clipping == nil, "\(control)")
            #expect(spec.order == ManualAdjustments.Control.allCases.count + index, "\(control)")
            #expect(spec.fillOrigin == 0.5 && spec.markFraction == 0.5)
            for value: Float in [-100, -37, 0, 37, 100] {
                #expect(spec.formatted(value) == formattedAsItWas(value, .contrast) && spec.spoken(value) == spec.formatted(value))
                #expect(spec.snapped(value + 0.4) == value)
            }
            #expect(spec.sliderHelp(control.adjustmentHelp) == control.adjustmentHelp + keys)
            #expect(spec.entryLimits == "Enter \(formattedAsItWas(-100, .contrast)) to \(formattedAsItWas(100, .contrast)).")
        }
    }

    /// A Presence slider steps as Light's ±100 controls do: arrows 1, = and − 5, Shift 20.
    @Test func aPresenceSliderStepsAsLightsTonesDo() throws {
        let (slider, actions) = fixture(.whites)
        slider.spec = .light(.presence(.vibrance))
        for (key, value) in [("=", 5), ("+", 25), ("-", 20), ("_", 0), ("_", -20)] as [(String, Double)] {
            slider.keyDown(with: try typed(key))
            #expect(slider.doubleValue == value, "\(key)")
        }
        slider.keyDown(with: try key(.rightArrow))
        #expect(slider.doubleValue == -19)
        slider.keyDown(with: try key(.leftArrow, flags: .shift))
        #expect(slider.doubleValue == -29)
        slider.keyDown(with: try key(.home))
        #expect(slider.doubleValue == -100)
        #expect(actions.values.count == 8 && actions.phases.count == actions.values.count * 2)
    }

    @Test func aMasksAmountHasADefaultAboveItsLowerEnd() throws {
        let amount = AdjustmentSliderSpec.maskAmount
        #expect(amount.range == 0...200 && amount.defaultValue == 100 && amount.polarity == .unipolar)
        #expect(amount.title == "Amount" && amount.group == .mask && amount.clipping == nil)
        #expect(amount.snapped(150.4) == 150 && amount.snapped(-3) == 0 && amount.snapped(260) == 200)
        // No sign and no unit: "100", as the wireframe has it, never a percentage.
        #expect(amount.spoken(100) == 100.formatted() && amount.formatted(0) == 0.formatted())
        // Filled from the lower end, the mark on the default.
        #expect(amount.fillOrigin == 0 && amount.markFraction == 0.5)
        #expect(amount.fraction(of: 100) == 0.5 && amount.fraction(of: 150) == 0.75)
        #expect(amount.scrubbed(from: 100, steps: 12.7) == 112 && amount.scrubbed(from: 195, steps: 40) == 200)
        // A unipolar slider from its own default has nothing to mark.
        var size = amount
        size.defaultValue = 0
        #expect(size.markFraction == nil && size.fillOrigin == 0)
        // Bipolar, on a range not centred on its default: the fill and mark stand at the default.
        var lopsided = AdjustmentSliderSpec.light(.contrast)
        lopsided.range = -50...150
        #expect(lopsided.fillOrigin == 0.25 && lopsided.markFraction == 0.25)
    }

    /// A balance slider's track is drawn in the two colours it pushes between; no other row's is tinted.
    @Test func onlyAMasksBalanceRowsAreTinted() {
        #expect(AdjustmentSliderSpec.maskBalance(.warmth).tint == .warmth && AdjustmentSliderSpec.maskBalance(.magenta).tint == .magenta)
        #expect(AdjustmentSliderSpec.maskAmount.tint == nil)
        for slider in ManualAdjustments.Slider.allCases {
            #expect(AdjustmentSliderSpec.light(slider).tint == nil && AdjustmentSliderSpec.light(slider).trackPartner == nil, "\(slider)")
        }
    }

    /// A hue range's two ends: each read on the whole strip, with the control's own default, steps and place in the Lens
    /// group, and each knowing the other's place.
    @Test func aHueRangesEndsShareAStripAndKnowEachOther() {
        let controls = LensSettings.Control.allCases
        for (low, high) in [(LensSettings.Control.purpleHueLow, LensSettings.Control.purpleHueHigh), (.greenHueLow, .greenHueHigh)] {
            let a = AdjustmentSliderSpec.lensHue(low, partner: high), b = AdjustmentSliderSpec.lensHue(high, partner: low)
            #expect(a.range == 0...100 && b.range == 0...100)
            #expect(a.defaultValue == low.defaultValue && b.defaultValue == high.defaultValue)
            #expect(a.order == controls.firstIndex(of: low) && b.order == controls.firstIndex(of: high))
            #expect(a.trackPartner == b.order && b.trackPartner == a.order)
            #expect(a.group == .lens && a.title == low.title && a.step == 1)
            // The knobs stand where their hues are on one strip, which the controls' own ranges, 0 to 90 and 10 to 100, would not give.
            #expect(abs(a.fraction(of: 30) - 0.3) < 1e-6 && abs(b.fraction(of: 30) - 0.3) < 1e-6)
            #expect(abs(AdjustmentSliderSpec.lensAmount(low).fraction(of: 30) - AdjustmentSliderSpec.lensAmount(high).fraction(of: 30)) > 0.05)
        }
        #expect(AdjustmentSliderSpec.lensAmount(.purpleAmount).trackPartner == nil)
    }

    /// A slider with limits stops inside them, by a key as by a drag; without them it has its range.
    @Test func aSliderStopsInsideItsLimits() throws {
        let (slider, _) = fixture(.contrast)
        slider.spec = .lensHue(.purpleHueLow, partner: .purpleHueHigh)
        #expect(slider.limited(95) == 95 && slider.limited(140) == 100 && slider.limited(-3) == 0 && slider.limited(41.6) == 42)
        slider.limits = 0...60
        #expect(slider.limited(95) == 60 && slider.limited(61) == 60 && slider.limited(60) == 60 && slider.limited(12) == 12)
        slider.doubleValue = 58
        #expect(slider.accessibilityPerformIncrement() && slider.doubleValue == 59)
        #expect(slider.accessibilityPerformIncrement() && slider.doubleValue == 60)
        // At its limit a step is nothing.
        _ = slider.accessibilityPerformIncrement()
        #expect(slider.doubleValue == 60)
    }

    @Test func aSliderTakesItsSpecsRangeStepsAndKeys() throws {
        let (slider, actions) = fixture(.contrast)
        slider.spec = .maskAmount
        #expect(slider.minValue == 0 && slider.maxValue == 200)
        slider.doubleValue = 100
        slider.keyDown(with: try typed("="))
        #expect(slider.doubleValue == 105)
        slider.keyDown(with: try typed("_"))
        #expect(slider.doubleValue == 85)
        slider.keyDown(with: try key(.rightArrow))
        #expect(slider.doubleValue == 86)
        slider.keyDown(with: try key(.home))
        #expect(slider.doubleValue == 0)
        slider.keyDown(with: try key(.end))
        #expect(slider.doubleValue == 200)
        #expect(actions.phases.count == actions.values.count * 2)
    }

    @Test func theTypedEntryOfAnySpecIsCheckedAgainstItsRangeAndItsSnapshot() {
        let amount = AdjustmentSliderSpec.maskAmount
        #expect(ManualAdjustmentNumberInput.resolve("150", spec: amount, startingAt: 1, current: 1) == .value(150))
        #expect(ManualAdjustmentNumberInput.resolve("0", spec: amount, startingAt: 1, current: 1) == .value(0))
        #expect(ManualAdjustmentNumberInput.resolve("201", spec: amount, startingAt: 1, current: 1) == .invalid)
        #expect(ManualAdjustmentNumberInput.resolve("-1", spec: amount, startingAt: 1, current: 1) == .invalid)
        #expect(ManualAdjustmentNumberInput.resolve("150", spec: amount, startingAt: 1, current: 2) == .superseded)
        #expect(ManualAdjustmentNumberInput.resolve("150", spec: amount, startingAt: Int?.none, current: 2) == .superseded)
    }

    /// Both groups in one window, the views added out of order: . and , stay in the focused slider's.
    @Test func periodAndCommaStayInsideTheirGroup() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
        window.contentView = content
        var mask: [AdjustmentSliderControl] = []
        var light: [AdjustmentSliderControl] = []
        let specs = [AdjustmentSliderSpec.maskAmount] + ManualAdjustments.Control.allCases.map { AdjustmentSliderSpec.light($0, group: .mask) }
        for (index, spec) in specs.enumerated() {
            let slider = AdjustmentSliderControl(frame: NSRect(x: 10, y: 10 + 30 * index, width: 200, height: 24))
            slider.spec = spec
            mask.append(slider)
        }
        for (index, control) in ManualAdjustments.Control.allCases.enumerated() {
            let slider = AdjustmentSliderControl(frame: NSRect(x: 10, y: 300 + 30 * index, width: 200, height: 24))
            slider.spec = .light(control)
            light.append(slider)
        }
        // Whichever way SwiftUI adds them, the group's order is the spec's.
        for slider in (mask + light).reversed() { content.addSubview(slider) }

        #expect(AdjustmentSliderControl.sliders(in: .mask, under: content) == mask)
        #expect(AdjustmentSliderControl.sliders(in: .light, under: content) == light)

        #expect(window.makeFirstResponder(mask[1]))
        mask[1].keyDown(with: try typed(".", keyCode: 47))
        #expect(window.firstResponder === mask[2])
        // Round the end of the mask's, past Amount, and never to the Light tab's sliders of the same name.
        #expect(window.makeFirstResponder(mask[6]))
        mask[6].keyDown(with: try typed(".", keyCode: 47))
        #expect(window.firstResponder === mask[0])
        mask[0].keyDown(with: try typed(",", keyCode: 43))
        #expect(window.firstResponder === mask[6])

        #expect(window.makeFirstResponder(light[5]))
        light[5].keyDown(with: try typed(".", keyCode: 47))
        #expect(window.firstResponder === light[0])
        light[0].keyDown(with: try typed(",", keyCode: 43))
        #expect(window.firstResponder === light[5])
    }
}

@Suite struct LightControlStepTests {
    @Test func valuesLandOnWholeHundredthsOfAStopAndWholeUnitsInsideTheRange() {
        let exposure = ManualAdjustments.Control.exposure
        for hundredths in -500...500 {
            let value = Float(hundredths) / 100
            #expect(exposure.snapped(value) == value)
            #expect(exposure.snapped(value + 0.004) == value && exposure.snapped(value - 0.004) == value)
        }
        #expect(exposure.snapped(0.333) == 0.33 && exposure.snapped(7) == 5 && exposure.snapped(-5.004) == -5)
        #expect(ManualAdjustments.Control.blacks.snapped(-37.6) == -38 && ManualAdjustments.Control.blacks.snapped(140) == 100)
    }

    @Test func keyboardStepsMatchLightroomAndTheArrowsKeepArgentsFineStep() {
        let exposure = ManualAdjustments.Control.exposure
        #expect(exposure.keyStep(large: false) == 0.1 && exposure.keyStep(large: true) == 0.33 && exposure.arrowStep == 0.05)
        for control in ManualAdjustments.Control.allCases where control != .exposure {
            #expect(control.keyStep(large: false) == 5 && control.keyStep(large: true) == 20 && control.arrowStep == 1)
        }
    }

    @Test func scrubbingMovesOneStepAPointFromTheStartAndStopsAtTheEnds() {
        #expect(ManualAdjustments.Control.exposure.scrubbed(from: 0.5, steps: 12.7) == 0.62)
        #expect(ManualAdjustments.Control.exposure.scrubbed(from: 0.5, steps: -12.7) == 0.38)
        #expect(ManualAdjustments.Control.exposure.scrubbed(from: 4.9, steps: 400) == 5)
        #expect(ManualAdjustments.Control.highlights.scrubbed(from: -20, steps: 135) == 100)
        #expect(ManualAdjustments.Control.highlights.scrubbed(from: -20, steps: 0.9) == -20)
    }
}

@Suite struct LightClippingTests {
    /// An 8-bit picture in `space` as the film previews make one (`.RGBA8`), or BGRA, with these pixels.
    func image(_ pixels: [(UInt8, UInt8, UInt8)], width: Int, bgra: Bool = false, space: OutputSpace = .displayP3) throws -> CGImage {
        var bytes: [UInt8] = []
        for (r, g, b) in pixels { bytes += bgra ? [b, g, r, 255] : [r, g, b, 255] }
        let space = space.colorSpace
        let info = bgra ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: pixels.count / width, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// `image`'s codes in its own colour space, so nothing converts them.
    func pixels(_ image: CGImage) throws -> [(UInt8, UInt8, UInt8)] {
        let space = try #require(image.colorSpace)
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<image.height).flatMap { y in (0..<image.width).map { x in
            let p = data + y * context.bytesPerRow + x * 4
            return (p[0], p[1], p[2])
        } }
    }

    @Test func everyCodeKeepsItsValueThroughTheCopyAndOnlyTheEndCodesClip() throws {
        // Each code in each channel, across an odd width so rows are padded.
        var ramp: [(UInt8, UInt8, UInt8)] = (0...255).map { code in (UInt8(code), UInt8(255 - code), UInt8(code * 7 % 256)) }
        ramp += [(0, 0, 0), (255, 255, 255), (17, 18, 19)]
        let source = try image(ramp, width: 37)
        let white = try pixels(try #require(LightClipping.highlights.picture(of: source)))
        let black = try pixels(try #require(LightClipping.shadows.picture(of: source)))
        for (index, pixel) in ramp.enumerated() {
            let codes = [pixel.0, pixel.1, pixel.2]
            let highlights: [UInt8] = codes.map { $0 == 255 ? 255 : 0 }, shadows: [UInt8] = codes.map { $0 == 0 ? 0 : 255 }
            #expect([white[index].0, white[index].1, white[index].2] == highlights, "\(index)")
            #expect([black[index].0, black[index].1, black[index].2] == shadows, "\(index)")
        }
    }

    @Test func clippedChannelsShowTheirColourOnBlackOrTheirComplementOnWhite() throws {
        let patches: [(UInt8, UInt8, UInt8)] = [(255, 255, 255), (255, 30, 30), (255, 255, 254), (128, 128, 128),
                                                (0, 0, 0), (0, 90, 200), (1, 0, 1), (254, 1, 255), (0, 255, 0)]
        for bgra in [false, true] {
            let source = try image(patches, width: 3, bgra: bgra)
            let white = try pixels(try #require(LightClipping.highlights.picture(of: source)))
            let black = try pixels(try #require(LightClipping.shadows.picture(of: source)))
            #expect(white.map { [$0.0, $0.1, $0.2] } == [[255, 255, 255], [255, 0, 0], [255, 255, 0], [0, 0, 0],
                                                         [0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 255], [0, 255, 0]])
            #expect(black.map { [$0.0, $0.1, $0.2] } == [[255, 255, 255], [255, 255, 255], [255, 255, 255], [255, 255, 255],
                                                         [0, 0, 0], [0, 255, 255], [255, 0, 255], [255, 255, 255], [0, 255, 0]])
        }
    }
}

extension LightClippingTests {
    /// Previews are in the colour space a develop is to write, and the view compares that space's own codes.
    @Test(arguments: OutputSpace.allCases)
    func clipsOnThePicturesOwnCodesInEverySpace(space: OutputSpace) throws {
        let limits = PrintLimits(white: SIMD3(repeating: 251), black: SIMD3(repeating: 17))
        let source = try image([(251, 250, 0), (17, 18, 255)], width: 2, space: space)
        let highlights = try #require(LightClipping.highlights.picture(of: source, limits: limits))
        let shadows = try #require(LightClipping.shadows.picture(of: source, limits: limits))
        #expect(highlights.colorSpace?.name == space.colorSpace.name)
        #expect(shadows.colorSpace?.name == space.colorSpace.name)
        #expect(try pixels(highlights).map { [$0.0, $0.1, $0.2] } == [[255, 0, 0], [0, 0, 255]])
        #expect(try pixels(shadows).map { [$0.0, $0.1, $0.2] } == [[255, 255, 0], [0, 255, 255]])
    }

    /// A Studio print, whose paper white is 251 and deepest black 17 (blue 18), clips there, not at
    /// the display's ends; a print whose ends a curve turned round falls back to the display's.
    @Test func aPrintClipsAtItsOwnWhiteAndBlack() throws {
        let studio = PrintLimits(white: SIMD3(252, 251, 251), black: SIMD3(17, 17, 18))
        let patches: [(UInt8, UInt8, UInt8)] = [(252, 251, 251), (251, 251, 250), (255, 250, 251), (17, 17, 18),
                                                (18, 17, 19), (16, 40, 18), (128, 128, 128), (0, 0, 0), (250, 18, 17)]
        let source = try image(patches, width: 3)
        let white = try pixels(try #require(LightClipping.highlights.picture(of: source, limits: studio)))
        let black = try pixels(try #require(LightClipping.shadows.picture(of: source, limits: studio)))
        #expect(white.map { [$0.0, $0.1, $0.2] } == [[255, 255, 255], [0, 255, 0], [255, 0, 255], [0, 0, 0],
                                                     [0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0]])
        #expect(black.map { [$0.0, $0.1, $0.2] } == [[255, 255, 255], [255, 255, 255], [255, 255, 255], [0, 0, 0],
                                                     [255, 0, 255], [0, 255, 0], [255, 255, 255], [0, 0, 0], [255, 255, 0]])
        let inverted = PrintLimits(white: SIMD3(10, 251, 251), black: SIMD3(240, 17, 18))
        let fallback = try pixels(try #require(LightClipping.highlights.picture(of: source, limits: inverted)))
        #expect(fallback.map { [$0.0, $0.1, $0.2] } == [[0, 0, 0], [0, 0, 0], [255, 0, 0], [0, 0, 0],
                                                        [0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0]])
    }
}

@MainActor private final class SliderActions: NSObject {
    var values: [Double] = []
    var phases: [Bool] = []
    var clipping: [Bool] = []
    @objc func changed(_ sender: NSSlider) { values.append(sender.doubleValue) }
}

@Suite struct ManualAdjustmentNumberInputTests {
    @Test func resetDiscardsPendingExposureEvenWhenExposureItselfWasAlreadyZero() throws {
        let beforeReset = try ManualAdjustments(contrast: 20)
        #expect(beforeReset.exposureEV == ManualAdjustments.identity.exposureEV)
        #expect(ManualAdjustmentNumberInput.resolve("+1", control: .exposure,
            startingAt: beforeReset, current: .identity, locale: Locale(identifier: "en_US")) == .superseded)
    }

    @Test func modelChangesSupersedePendingFieldsBeforeTheyCanCommit() throws {
        let initial = try ManualAdjustments(exposureEV: 1, highlights: 20)
        let afterUndo = try initial.setting(.highlights, to: 0)
        #expect(ManualAdjustmentNumberInput.resolve("+2", control: .exposure,
            startingAt: initial, current: afterUndo) == .superseded)
        #expect(ManualAdjustmentNumberInput.resolve("+2", control: .exposure,
            startingAt: nil, current: initial) == .superseded)
    }

    @Test func unchangedEntriesKeepLocaleParsingPhotographicStepsAndStrictValidation() {
        let locale = Locale(identifier: "de_DE")
        #expect(ManualAdjustmentNumberInput.resolve(" +0,833 ", control: .exposure,
            startingAt: .identity, current: .identity, locale: locale) == .value(0.83))
        #expect(ManualAdjustmentNumberInput.resolve("20,4", control: .shadows,
            startingAt: .identity, current: .identity, locale: locale) == .value(20))
        for (text, value) in [("-5", Float(-5)), ("5,00", 5), ("3,01", 3.01), ("-4,996", -5)] {
            #expect(ManualAdjustmentNumberInput.resolve(text, control: .exposure,
                startingAt: .identity, current: .identity, locale: locale) == .value(value), "\(text)")
        }
        for invalid in ["nan", "inf", "", "20 extra", "5,01", "-5,01"] {
            #expect(ManualAdjustmentNumberInput.resolve(invalid, control: .exposure,
                startingAt: .identity, current: .identity, locale: locale) == .invalid)
        }
    }
}

@MainActor extension AdjustmentSliderTests {
    @Test func lensAmountHasItsOwnKeyboardGroupAndUnipolarDefault() {
        let spec = AdjustmentSliderSpec.lensAmount(.distortion)
        #expect(spec.title == "Amount" && spec.range == 0...200 && spec.defaultValue == 100)
        #expect(spec.polarity == .unipolar && spec.group == .lens && spec.order == 0)
        #expect(spec.arrowStep == 1 && spec.smallKeyStep == 5 && spec.largeKeyStep == 20)
        #expect(spec.clipping == nil && spec.formatted(150) == "150")
        #expect(spec.snapped(150.4) == 150 && spec.snapped(201) == 200)
    }
}
