import Accelerate
import AppKit
import ArgentCore
import ArgentRoll
import SwiftUI

/// The sliders `.` and `,` move among, each a tab's or a selected mask's own, so the keys never leave
/// the set on screen for one of the same name elsewhere in the window.
enum AdjustmentSliderGroup: Hashable, Sendable {
    /// The Light tab's eleven: Light's six, then Presence's five.
    case light
    case lens
    /// A selected mask's Amount and its six.
    case mask
    /// The brush's Size, Feather and Flow, while it is in hand.
    case brush
}

/// What an inspector slider is, apart from what it is bound to: the range and the default, how it
/// steps and reads, and how its track is drawn. A Light control's spec comes from the control
/// (`light(_:group:)`); others say their own, as a mask's Amount does (`maskAmount`).
struct AdjustmentSliderSpec: Equatable, Sendable {
    /// How the track reads a value.
    enum Polarity: Equatable, Sendable {
        /// Either way from its default, which is what "no change" means: the fill runs from the default
        /// to the knob, and a value carries its sign.
        case bipolar
        /// An amount, from its lower end: the fill runs from that end to the knob, with no sign. A
        /// default that is not the lower end has the track's mark.
        case unipolar
    }

    var title: String
    var range: ClosedRange<Float>
    /// The resolution a drag or a typed value lands on.
    var step: Float
    /// What a reset returns to, and what reads as nothing changed.
    var defaultValue: Float = 0
    var polarity = Polarity.bipolar
    /// Arrow keys and accessibility increment and decrement; Shift-arrow moves ten.
    var arrowStep: Float
    /// = and −, and with Shift. Only a slider in a group takes them.
    var smallKeyStep: Float
    var largeKeyStep: Float
    var fractionDigits = 0
    /// After the value when it is read out: " EV".
    var unit = ""
    /// The view Option shows while the slider moves, when it has one.
    var clipping: LightClipping?
    /// Whose `.` and `,` it answers. In a group it also takes = and − and Option's clipping hold; out
    /// of one, as a curve region's slider is, only the arrows.
    var group: AdjustmentSliderGroup?
    /// Its place in the group, for `.` and `,`.
    var order = 0
    /// The two colours the track runs between, for a slider that pushes a colour one way or the other. Such a track has no fill:
    /// its own colours say which way the knob stands.
    var tint: Tint?

    /// A tinted track's two ends, the lower first.
    enum Tint: Equatable, Sendable {
        /// A mask's Warmth: cooler to warmer.
        case warmth
        /// A mask's Magenta: green to magenta.
        case magenta
    }

    /// The place in its group (`order`) of the slider it shares one track with, when it is one end of a range: the two are
    /// laid one over the other on a track their row draws (`LensHueRow`), each draws its knob alone, and a press goes to the
    /// one whose knob is nearer (`AdjustmentSliderControl.mouseDown`).
    var trackPartner: Int?

    /// One end of a Defringe hue range, Low or High: read on the whole strip, 0 to 100, so the two knobs stand where their
    /// hues are, though Low ends at 90 and High begins at 10 (`Defringe.hueLowRange`); its row keeps each ten short of the
    /// other (`ManualAdjustmentRow.limits`), as the values themselves are kept.
    static func lensHue(_ control: LensSettings.Control, partner: LensSettings.Control) -> AdjustmentSliderSpec {
        var spec = lensAmount(control)
        spec.range = 0...100
        spec.trackPartner = LensSettings.Control.allCases.firstIndex(of: partner)
        return spec
    }

    /// The Light control `control`'s: from zero either way, to its own steps. `group: nil` is a curve
    /// region's slider, borrowing the range without Lightroom's keys.
    static func light(_ control: ManualAdjustments.Control, group: AdjustmentSliderGroup? = .light) -> AdjustmentSliderSpec {
        light(.light(control), group: group)
    }

    /// A Light-tab slider's: one of Light's six, or of Presence's five, which step as Light's ±100 controls do and have no clipping
    /// view, so Option shows nothing on them and their drag asks for no clipping probe. Its place among `.` and `,` is its place in
    /// the tab, `ManualAdjustments.Slider.allCases`.
    static func light(_ slider: ManualAdjustments.Slider, group: AdjustmentSliderGroup? = .light) -> AdjustmentSliderSpec {
        var spec = switch slider {
        case .light(let control):
            AdjustmentSliderSpec(title: control.title, range: control.range, step: control.step, arrowStep: control.arrowStep,
                                 smallKeyStep: control.keyStep(large: false), largeKeyStep: control.keyStep(large: true),
                                 fractionDigits: control == .exposure ? 2 : 0, unit: control == .exposure ? " EV" : "",
                                 clipping: control.clipping)
        case .lens(let control):
            AdjustmentSliderSpec(title: control.title, range: control.range, step: 1, defaultValue: control.defaultValue, arrowStep: 1,
                                 smallKeyStep: 5, largeKeyStep: 20)
        case .presence(let control):
            AdjustmentSliderSpec(title: control.title, range: control.range, step: control.step, arrowStep: 1, smallKeyStep: 5,
                                 largeKeyStep: 20)
        }
        spec.group = group
        spec.order = ManualAdjustments.Slider.allCases.firstIndex(of: slider) ?? 0
        return spec
    }

    /// A mask's Amount, read as 0 to 200 with 100 as its default; the stored value is a hundredth of
    /// this, 0 to 2 (docs/masking-plan.md, section 4), so its binding divides. First in a mask's group,
    /// over the six.
    static let maskAmount = AdjustmentSliderSpec(title: "Amount", range: 0...200, step: 1, defaultValue: 100, polarity: .unipolar,
                                                 arrowStep: 1, smallKeyStep: 5, largeKeyStep: 20, group: .mask, order: -1)

    /// Film settings' Halation, 0 to 200 with 100 the stock's own (`OutputSettings.halation`), as a mask's Amount reads. In no
    /// group: it stands alone in its popover, and takes the arrows.
    static let halation = AdjustmentSliderSpec(title: "Halation", range: Float(OutputSettings.halationRange.lowerBound)...Float(OutputSettings.halationRange.upperBound),
                                               step: 1, defaultValue: Float(OutputSettings.defaultHalation), polarity: .unipolar,
                                               arrowStep: 1, smallKeyStep: 5, largeKeyStep: 20)

    static func lensAmount(_ control: LensSettings.Control) -> AdjustmentSliderSpec {
        AdjustmentSliderSpec(title: control.title, range: control.range, step: 1, defaultValue: control.defaultValue,
                             polarity: control == .vignette ? .bipolar : .unipolar,
                             arrowStep: 1, smallKeyStep: 5, largeKeyStep: 20, group: .lens,
                             order: LensSettings.Control.allCases.firstIndex(of: control) ?? 0)
    }

    /// A mask's Warmth or Magenta: from zero either way, after the six Light rows in a mask's group.
    static func maskBalance(_ control: MaskBalanceControl) -> AdjustmentSliderSpec {
        AdjustmentSliderSpec(title: control.title, range: MaskBalance.range, step: 1, arrowStep: 1, smallKeyStep: 5, largeKeyStep: 20,
                             group: .mask, order: ManualAdjustments.Control.allCases.count + (MaskBalanceControl.allCases.firstIndex(of: control) ?? 0),
                             tint: control == .warmth ? .warmth : .magenta)
    }

    /// `value` on the spec's resolution, inside its range. Snapped as a whole number of hundredths,
    /// so 0.33 EV is stored as 0.33, not as 33 × 0.01 rounded twice.
    func snapped(_ value: Float) -> Float {
        let perUnit = (1 / step).rounded()
        return min(range.upperBound, max(range.lowerBound, (value * perUnit).rounded() / perUnit))
    }

    func keyStep(large: Bool) -> Float { large ? largeKeyStep : smallKeyStep }

    /// Dragging over the value: one resolution step a point (ten with Shift, which `ValueScrubView`
    /// counts into `steps`), from the value the drag began at.
    func scrubbed(from start: Float, steps: CGFloat) -> Float {
        snapped(start + Float(steps.rounded(.towardZero)) * step)
    }

    /// `value` as the row's field shows it.
    func formatted(_ value: Float) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits))
            .sign(strategy: polarity == .bipolar ? .always(includingZero: false) : .automatic))
    }

    /// `value` as VoiceOver reads it.
    func spoken(_ value: Float) -> String { formatted(value) + unit }

    /// How far along the track `value` stands, 0 to 1.
    func fraction(of value: Float) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? CGFloat((value - range.lowerBound) / span) : 0.5
    }

    /// Where the track's fill starts, as a fraction of the track; it ends at the knob.
    var fillOrigin: CGFloat { polarity == .bipolar ? fraction(of: defaultValue) : 0 }

    /// Where the track's mark stands, as a fraction of the track; none at a unipolar slider's lower end.
    var markFraction: CGFloat? {
        polarity == .unipolar && defaultValue == range.lowerBound ? nil : fraction(of: defaultValue)
    }

    /// The slider's help tag: `does`, what the control does, and how to work it.
    func sliderHelp(_ does: String) -> String {
        let keys = group == nil ? "Arrows step it, Shift in larger steps."
            : "Arrows, = and − step it, Shift in larger steps; . and , move to the next or previous slider."
        return does + " Double-click to reset. " + keys
            + (clipping == .highlights ? " Hold Option as you drag to see clipped highlights."
               : clipping == .shadows ? " Hold Option as you drag to see clipped shadows." : "")
    }

    /// What the field takes: its range, in the words a rejected entry is told.
    var entryLimits: String { "Enter \(formatted(range.lowerBound)) to \(formatted(range.upperBound))\(unit)." }

    /// The value field's help tag.
    func entryHelp(_ does: String) -> String { entryLimits + " " + does }
}

/// A native control owns tracking, focus and accessibility; its cell draws the track.
/// Stepping belongs to the input adapter, so it doesn't require hundreds of tick marks.
///
/// A slider in a group (`AdjustmentSliderSpec.group`), as the Light tab's eleven are, also takes
/// Lightroom Classic's keys: = and − step the focused slider (`keyStep`), . and , move focus to the
/// next or previous one in the group, and Option held while one moves shows the clipping view
/// (`LightClipping`).
struct AdjustmentSlider: NSViewRepresentable {
    @Binding var value: Float
    let spec: AdjustmentSliderSpec
    var label: String? = nil
    /// Which of its value's gestures a drag is in (`ManualAdjustmentRow.gesture`): a new one while the pointer is down drops the write
    /// the drag has queued and puts the knob at `value`, where the drag goes on from (`AdjustmentSliderControl.gesture`).
    var gesture = 0
    /// A value the slider did not set itself, such as a reset's, an undo's or a paste's, is glided to rather than jumped to
    /// (`AdjustmentSliderControl.glide`). Its row says when (`ManualAdjustmentRow`); a slider on its own jumps.
    var glides = false
    let onEditingChanged: (Bool) -> Void
    let onReset: () -> Void
    let onFocusChanged: (Bool) -> Void
    /// Option began or stopped showing the clipping view; see `AdjustmentSliderControl.onClipping`.
    var onClipping: (Bool) -> Void = { _ in }
    /// Whether a clipping view is up. Another view can end it, as the value's scrub does when
    /// Option comes up during its own event loop, unseen here; the slider then lets go of its
    /// own, so the next Option hold shows the view again.
    var isClippingShown = true
    /// Its row's context menu (`InspectorMenus.sliderRow`), made as it opens; none for a slider in no such row.
    var menu: (@MainActor () -> [MenuEntry])? = nil
    /// The track's ruler shows: the pointer is over its row, or the slider is held or has the keyboard (`ManualAdjustmentRow`).
    var showsRuler = false
    var showsEVScale = false
    /// Where inside its range the knob may stand just now, when that is less than the range: one end of a range stops short
    /// of the other.
    var limits: ClosedRange<Float>? = nil
    @Environment(\.editedInspectorFocus) private var editedFocus
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> AdjustmentSliderControl {
        let slider = AdjustmentSliderControl()
        slider.cell = AdjustmentSliderCell()
        // The new cell holds the range, from 0 to 1, and `updateNSView` sets a spec only when it differs from the control's first,
        // which Contrast's equals: set here, so every slider's range is its spec's.
        slider.spec = spec
        slider.isVertical = false
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.focusRingType = .none
        // The knob's focus ring reaches past the track's ends.
        slider.clipsToBounds = false
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return slider
    }

    /// Called whenever the row around it is evaluated, which a write of the edit can do for every slider on
    /// show at once; so each property is set, and the slider drawn, only when what it shows has changed. Drawn
    /// every time, the six to fourteen sliders cost most of a refresh at each step of a drag (measured, T8, T9).
    func updateNSView(_ slider: AdjustmentSliderControl, context: Context) {
        // The track is drawn in the theme's colours: a change of theme asks for this update.
        let palette = Graphite.palette
        context.coordinator.parent = self
        var redraw = false
        if slider.spec != spec { slider.spec = spec; redraw = true }
        // The gesture was replaced while the pointer may be down: what the drag queued was the old one's.
        let replaced = slider.gesture != gesture
        if replaced { slider.gesture = gesture; context.coordinator.dropPending() }
        // NSControl draws again on any set, the same value too. While the pointer drags it the slider's own value leads
        // the edit's, which follows at most every `dragWriteInterval`, so the knob is not put back to the last write,
        // unless the gesture was replaced.
        if !slider.isTrackingPointer || replaced, slider.settledValue != Double(value) {
            // A knob that has shown a value goes to the next on a spring when its row asks; the first value, a gesture's
            // replacement and a slider in no window are put there.
            if glides, !replaced, !slider.isTrackingPointer, slider.hasShownValue, slider.window != nil {
                slider.glide(to: Double(value))
            } else {
                slider.endGlide()
                slider.doubleValue = Double(value)
                redraw = true
            }
        }
        slider.hasShownValue = true
        if slider.isEnabled != isEnabled { slider.isEnabled = isEnabled; redraw = true }
        if slider.drawnPalette != palette { slider.drawnPalette = palette; redraw = true }
        if slider.showsRuler != showsRuler { slider.showsRuler = showsRuler; redraw = true }
        if slider.showsEVScale != showsEVScale { slider.showsEVScale = showsEVScale; redraw = true }
        slider.editedFocus = editedFocus
        slider.limits = limits
        slider.onEditingChanged = onEditingChanged
        slider.onTrackingEnded = { [weak coordinator = context.coordinator] in coordinator?.writePending() }
        slider.onReset = onReset
        slider.onFocusChanged = onFocusChanged
        slider.onClipping = onClipping
        slider.menuEntries = menu
        // Only a view of its own: a pending Option hold must survive ordinary updates.
        if !isEnabled || (!isClippingShown && slider.isClipping) { slider.endClipping() }
        let title = label ?? spec.title
        if slider.accessibilityLabel() != title {
            slider.setAccessibilityLabel(title)
            slider.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: "Reset \(title.lowercased())", target: slider,
                                            selector: #selector(AdjustmentSliderControl.resetFromAccessibility(_:)))
            ])
        }
        let spoken = spec.spoken(value)
        if slider.accessibilityValueDescription() != spoken { slider.setAccessibilityValueDescription(spoken) }
        if redraw { slider.needsDisplay = true }
    }

    static func dismantleNSView(_ slider: AdjustmentSliderControl, coordinator: Coordinator) {
        slider.handOffEditedFocusIfNeeded()
        slider.endGlide()
        slider.endClipping()
        slider.onClipping = nil
        slider.onTrackingEnded = nil
        slider.onEditingChanged = nil
        slider.onReset = nil
        slider.onFocusChanged = nil
        slider.menuEntries = nil
        slider.target = nil
    }

    /// The least time between a pointer drag's writes to the edit: the print and the row's number follow at about 30 Hz while
    /// the knob follows every event, as a moving gradient's print does (`MaskEditor.flushInterval`, R7 5.4). Written at each event,
    /// 120 a second, a mask slider's drag lost half the refreshes to the views that read the edit (T9). The release always writes.
    static let dragWriteInterval = MaskEditor.flushInterval

    @MainActor final class Coordinator: NSObject {
        var parent: AdjustmentSlider
        /// A pointer drag's newest value not yet written, and when the last write was.
        private var pending: Float?
        private var lastWrite: CFTimeInterval = 0
        private var writeTask: Task<Void, Never>?
        init(_ parent: AdjustmentSlider) { self.parent = parent }

        @objc func changed(_ slider: AdjustmentSliderControl) {
            let value = slider.limited(Float(slider.doubleValue))
            slider.doubleValue = Double(value)
            guard slider.isTrackingPointer else {
                // A key step writes at once; native accessibility can send an action outside mouse/key tracking.
                if !slider.isInteracting { parent.onEditingChanged(true) }
                parent.value = value
                if !slider.isInteracting { parent.onEditingChanged(false) }
                return
            }
            pending = value
            let now = CACurrentMediaTime(), wait = slider.dragWriteInterval - (now - lastWrite)
            if wait <= 0 {
                writePending()
            } else if writeTask == nil {
                writeTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard let self, !Task.isCancelled else { return }
                    self.writeTask = nil
                    self.writePending()
                }
            }
        }

        /// Writes the drag's newest value, if one waits: when it is time, and at the release, before the gesture ends.
        func writePending() {
            let value = pending
            dropPending()
            guard let value else { return }
            lastWrite = CACurrentMediaTime()
            parent.value = value
        }

        /// Lets the drag's newest value go unwritten: its gesture was replaced.
        func dropPending() {
            writeTask?.cancel()
            writeTask = nil
            pending = nil
        }
    }
}

final class AdjustmentSliderControl: NSSlider {
    /// The slider's range, resolution, keyboard steps and group.
    var spec = AdjustmentSliderSpec.light(.contrast) {
        didSet {
            minValue = Double(spec.range.lowerBound)
            maxValue = Double(spec.range.upperBound)
        }
    }
    /// The theme the track was last drawn in, so a change of theme draws it again and nothing else does.
    var drawnPalette: ThemePalette?
    /// Whether the track draws its ruler (`AdjustmentSlider.showsRuler`).
    var showsRuler = false
    var showsEVScale = false
    var editedFocus: EditedInspectorFocus?
    /// Where the knob may stand just now (`AdjustmentSlider.limits`).
    var limits: ClosedRange<Float>?
    var onEditingChanged: ((Bool) -> Void)?
    /// The pointer let go: what the drag has not yet written is written, before the gesture ends.
    var onTrackingEnded: (() -> Void)?
    var onReset: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    /// Its row's context menu, made when a right-click or a Control-click asks for it.
    var menuEntries: (@MainActor () -> [MenuEntry])?
    /// Lightroom's clipping view, on while Option is held as the slider moves: from a press with
    /// Option, or Option going down during the drag, to the release or Option coming up; and from a
    /// key step made with Option, or Option held on its own for `optionSettle` while the slider has
    /// focus, to Option coming up. Losing focus or the key window, or being disabled, ends it.
    var onClipping: ((Bool) -> Void)?
    private(set) var isInteracting = false
    /// The pointer is dragging the knob, inside `mouseDown`'s loop.
    private(set) var isTrackingPointer = false
    private(set) var isClipping = false
    private var optionHold: Task<Void, Never>?
    /// Option held on its own waits this long, so a chord that begins with it, such as ⌥⌘1, never
    /// flashes the clipping view.
    static let optionSettle: Duration = .milliseconds(250)
    /// This slider's own wait, `optionSettle`. A test shortens it on its own slider, never for every slider in
    /// the process, which a suite running beside it would see.
    var optionWait = AdjustmentSliderControl.optionSettle
    /// This slider's own `AdjustmentSlider.dragWriteInterval`. A test lengthens it on its own slider, so a drag's newest value is still
    /// waiting to be written when the test looks.
    var dragWriteInterval = AdjustmentSlider.dragWriteInterval
    /// Which of its value's gestures the knob shows (`AdjustmentSlider.gesture`). A pointer drag watches it: when it changes, the
    /// knob was put at the value the gesture's replacement left.
    var gesture = 0
    /// Whether the pointer rests over an armed canvas, where Option is the tool's: the canvases' shared answer
    /// (`MaskCanvasView.pointerOverArmedCanvas`). A test gives its slider an answer of its own, so the canvases of
    /// suites running beside it, which write the shared one, cannot change what it reads.
    var isPointerOverArmedCanvas: @MainActor () -> Bool = { MaskCanvasView.pointerOverArmedCanvas }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }

    // MARK: Gliding to a value

    /// Whether the knob has been given a value yet: the first is put there, never glided to from the cell's own start.
    var hasShownValue = false
    /// Where a glide under way is going, the value the slider stands for meanwhile.
    private var glideTarget: Double?
    private var glideSpeed = 0.0
    private var glideTime: CFTimeInterval = 0
    private var glideLink: CADisplayLink?

    /// The value the slider stands for: where a glide under way will end, else where the knob is.
    var settledValue: Double { glideTarget ?? doubleValue }

    /// Takes the knob to `value` on a spring (`Graphite.Motion.value`'s, response 0.36 and damping 0.9), a display frame
    /// at a time: a reset, an undo or a paste is seen to move the knob, rather than leave it somewhere else. A glide under
    /// way goes on to the new value at the speed it has. Any press or key ends it where it was going (`endGlide`).
    func glide(to value: Double) {
        guard value != settledValue else { return }
        glideTarget = value
        guard glideLink == nil else { return }
        glideSpeed = 0
        glideTime = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(glideStep(_:)))
        link.add(to: .main, forMode: .common)
        glideLink = link
    }

    /// Ends a glide with the knob where it was going.
    func endGlide() {
        glideLink?.invalidate()
        glideLink = nil
        guard let target = glideTarget else { return }
        glideTarget = nil
        glideSpeed = 0
        if doubleValue != target { doubleValue = target; needsDisplay = true }
    }

    @objc private func glideStep(_ link: CADisplayLink) {
        guard let target = glideTarget, maxValue > minValue else { endGlide(); return }
        let now = CACurrentMediaTime()
        var time = min(now - glideTime, 1.0 / 30)
        glideTime = now
        let response = 0.36 * Graphite.Motion.slow
        let stiffness = pow(2 * Double.pi / response, 2), damping = 2 * 0.9 * (2 * Double.pi / response)
        var value = doubleValue
        // Small steps, so the spring is the same at any display rate.
        while time > 0 {
            let step = min(time, 0.002)
            glideSpeed += (-stiffness * (value - target) - damping * glideSpeed) * step
            value += glideSpeed * step
            time -= step
        }
        let span = maxValue - minValue
        if abs(value - target) < span * 0.0005, abs(glideSpeed) < span * 0.02 {
            endGlide()
        } else {
            doubleValue = value
            needsDisplay = true
        }
    }

    /// Its row's menu, never during the slider's own gesture, which a menu would cut across; and on a disabled slider too, its row
    /// disabled, so the menu keeps its shape.
    override func menu(for event: NSEvent) -> NSMenu? {
        // On a track two ends share, the menu is the nearer end's, as a press is: a right-click reaches the end on top
        // wherever it lands, and would offer that end's reset over the other's knob.
        if let partner = isPartners(event) { return partner.menu(for: event) }
        guard !isInteracting, let entries = menuEntries?(), !entries.isEmpty else { return nil }
        return NSMenu(entries: entries)
    }

    /// `value` on the spec's resolution, inside its range and inside `limits`.
    func limited(_ value: Float) -> Float {
        let snapped = spec.snapped(value)
        guard let limits else { return snapped }
        return min(limits.upperBound, max(limits.lowerBound, snapped))
    }

    /// The slider laid on the same track, when this one is an end of a range (`AdjustmentSliderSpec.trackPartner`).
    private var trackPartner: AdjustmentSliderControl? {
        guard let order = spec.trackPartner, let group = spec.group, let content = window?.contentView else { return nil }
        return Self.sliders(in: group, under: content).first { $0.spec.order == order && $0 !== self }
    }

    /// Whether a press at `event` is the other end's: its knob is the nearer. The one of the two on top is the one pressed,
    /// wherever on the track the press is, so it hands the other its own, a press and a menu alike. The two are enabled and
    /// disabled together, their rows being one row's.
    private func isPartners(_ event: NSEvent) -> AdjustmentSliderControl? {
        guard let partner = trackPartner, partner.isEnabled == isEnabled, let mine = cell as? AdjustmentSliderCell, let theirs = partner.cell as? AdjustmentSliderCell
        else { return nil }
        let x = convert(event.locationInWindow, from: nil).x, other = partner.convert(event.locationInWindow, from: nil).x
        let own = abs(x - mine.knobRect(flipped: isFlipped).midX), far = abs(other - theirs.knobRect(flipped: partner.isFlipped).midX)
        return far < own ? partner : nil
    }

    override func mouseDown(with event: NSEvent) {
        if let partner = isPartners(event) { partner.mouseDown(with: event); return }
        if popUpContextMenuForControlClick(event) { return }
        guard isEnabled, let window, let cell = cell as? AdjustmentSliderCell else { return }
        endGlide()
        window.makeFirstResponder(self)
        if event.clickCount == 2 { onReset?(); return }
        isInteracting = true
        isTrackingPointer = true
        onEditingChanged?(true)
        defer {
            isTrackingPointer = false
            onTrackingEnded?()
            endClipping(); onEditingChanged?(false); isInteracting = false
        }
        setClipping(clips(event.modifierFlags))
        let point = convert(event.locationInWindow, from: nil)
        let knob = cell.knobRect(flipped: isFlipped)
        var offset = knob.insetBy(dx: -4, dy: -7).contains(point) ? point.x - knob.midX : 0, pointer = point.x, held = gesture
        trackPointer(at: pointer - offset, in: cell.barRect(flipped: isFlipped))
        // AppKit's stock cell tracks its private knob geometry. Track our drawn geometry
        // through the same native event loop, including release outside the control.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .flagsChanged],
                                          until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            setClipping(clips(next.modifierFlags))
            if next.type == .flagsChanged { continue }
            // The knob was put at the value a reset, a paste or an undo left: it is taken up where the pointer is, so the drag goes
            // on from that value, and a release without a move writes nothing.
            if gesture != held { held = gesture; offset = pointer - cell.knobRect(flipped: isFlipped).midX }
            pointer = convert(next.locationInWindow, from: nil).x
            trackPointer(at: pointer - offset, in: cell.barRect(flipped: isFlipped))
            if next.type == .leftMouseUp { break }
        }
    }

    override func keyDown(with event: NSEvent) {
        endGlide()
        let arrow = Double(spec.arrowStep) * (event.modifierFlags.contains(.shift) ? 10 : 1)
        switch event.specialKey {
        case .leftArrow, .downArrow: step(to: doubleValue - arrow, event); return
        case .rightArrow, .upArrow: step(to: doubleValue + arrow, event); return
        case .home: step(to: minValue, event); return
        case .end: step(to: maxValue, event); return
        default: break
        }
        // Lightroom's keys. Command and Control keep their menu shortcuts.
        guard spec.group != nil, event.modifierFlags.isDisjoint(with: [.command, .control]) else { super.keyDown(with: event); return }
        let large = event.modifierFlags.contains(.shift)
        switch event.charactersIgnoringModifiers {
        case "=", "+": step(to: doubleValue + Double(spec.keyStep(large: large)), event)
        case "-", "_": step(to: doubleValue - Double(spec.keyStep(large: large)), event)
        case ".": focusNeighbour(1)
        case ",": focusNeighbour(-1)
        default: super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard isEnabled, clips(event.modifierFlags), window?.firstResponder === self else { endClipping(); return }
        // Option with the pointer over an armed canvas is the tool's (an eraser's, on a brush), even with
        // this slider still focused, so the wait does not start, and a pointer arriving during it ends it.
        guard !isClipping, optionHold == nil, !isPointerOverArmedCanvas() else { return }
        let wait = optionWait
        optionHold = Task { [weak self] in
            try? await Task.sleep(for: wait)
            // Option's release, another modifier, focus or the key window leaving cancel the wait.
            guard let self, !Task.isCancelled, self.isEnabled, self.window?.firstResponder === self,
                  !self.isPointerOverArmedCanvas() else { return }
            self.setClipping(true)
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        endGlide()
        change(to: doubleValue + Double(spec.arrowStep))
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        endGlide()
        change(to: doubleValue - Double(spec.arrowStep))
        return true
    }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard let value = accessibilityValue as? NSNumber else { return }
        change(to: value.doubleValue)
    }

    @objc func resetFromAccessibility(_ action: NSAccessibilityCustomAction) -> Bool {
        guard isEnabled else { return false }
        onReset?()
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChanged?(true); needsDisplay = true }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            handOffEditedFocusIfNeeded()
            endClipping()
            onFocusChanged?(false)
            needsDisplay = true
        }
        return accepted
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        if let window { center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window) }
        if let newWindow {
            center.addObserver(self, selector: #selector(windowResignedKey(_:)), name: NSWindow.didResignKeyNotification, object: newWindow)
        } else {
            endClipping()
            endGlide()
        }
    }

    /// Option's release goes to whichever window is key then, so the view ends with the key window.
    @objc private func windowResignedKey(_ notification: Notification) { endClipping() }

    /// Ends the clipping view, or the wait to show it.
    func endClipping() { setClipping(false) }

    private func setClipping(_ on: Bool) {
        optionHold?.cancel()
        optionHold = nil
        guard on != isClipping else { return }
        isClipping = on
        onClipping?(on)
    }

    /// Option, with Shift or alone, on a slider in a group.
    private func clips(_ flags: NSEvent.ModifierFlags) -> Bool {
        spec.group != nil && flags.contains(.option) && flags.isDisjoint(with: [.command, .control])
    }

    private func step(to value: Double, _ event: NSEvent) {
        if isEnabled, clips(event.modifierFlags) { setClipping(true) }
        change(to: value)
    }

    /// Period and comma wrap within the current tool or across the visible controls in Edited.
    private func focusNeighbour(_ offset: Int) {
        guard let group = spec.group, let window, let content = window.contentView else { return }
        let sliders: [AdjustmentSliderControl]
        if editedFocus != nil {
            sliders = Self.editedSliders(in: content)
        } else {
            sliders = Self.sliders(in: group, under: content)
        }
        guard let index = sliders.firstIndex(where: { $0 === self }) else { return }
        let slider = sliders[(index + offset + sliders.count) % sliders.count]
        guard window.makeFirstResponder(slider) else { return }
        slider.scrollToVisible(slider.bounds)
    }

    /// AppKit can resign a removed row before SwiftUI dismantles it, or dismantle it while it still
    /// owns the keyboard. In either case, wait for the new rows before choosing a successor.
    fileprivate func handOffEditedFocusIfNeeded() {
        guard let editedFocus, editedFocus.isCurrent, let window, window.firstResponder === self else { return }
        let group = spec.group, order = spec.order
        DispatchQueue.main.async { [weak self, weak window] in
            guard editedFocus.isCurrent, let window, let content = window.contentView else { return }
            content.layoutSubtreeIfNeeded()
            let remaining = Self.editedSliders(in: content)
            guard !remaining.contains(where: { $0 === self }),
                  !(window.firstResponder is AdjustmentSliderControl) || window.firstResponder === self else { return }
            let next = remaining.first { slider in
                (slider.spec.group == group && slider.spec.order > order) || (group == .light && slider.spec.group == .lens)
            } ?? remaining.first
            if let next, window.makeFirstResponder(next) {
                next.scrollToVisible(next.bounds)
            } else {
                editedFocus.requestFilterFocus()
            }
        }
    }

    private static func editedSliders(in content: NSView) -> [AdjustmentSliderControl] {
        [.light, .lens].flatMap { sliders(in: $0, under: content) }
            .filter { $0.editedFocus != nil && $0.isEnabled }
    }

    /// `group`'s sliders in `view`'s hierarchy, in the group's order, whichever way the views were added.
    static func sliders(in group: AdjustmentSliderGroup, under view: NSView) -> [AdjustmentSliderControl] {
        func found(_ view: NSView) -> [AdjustmentSliderControl] {
            if let slider = view as? AdjustmentSliderControl { return slider.spec.group == group ? [slider] : [] }
            return view.subviews.flatMap(found)
        }
        return found(view).sorted { $0.spec.order < $1.spec.order }
    }

    private func change(to value: Double) {
        guard isEnabled, value.isFinite else { return }
        endGlide()
        let snapped = Double(limited(Float(value)))
        guard snapped != doubleValue else { return }
        isInteracting = true
        onEditingChanged?(true)
        doubleValue = snapped
        sendAction(action, to: target)
        onEditingChanged?(false)
        isInteracting = false
        needsDisplay = true
    }

    private func trackPointer(at x: CGFloat, in track: NSRect) {
        guard track.width > 0 else { return }
        let fraction = min(1, max(0, (x - track.minX) / track.width))
        let snapped = Double(limited(Float(minValue + Double(fraction) * (maxValue - minValue))))
        guard snapped != doubleValue else { return }
        doubleValue = snapped
        sendAction(action, to: target)
        needsDisplay = true
    }
}

/// The Graphite slider: a fine matte track running its row's width, the stretch from its mark to the value in the theme's
/// selection colour and a point heavier than the track (from the lower end, on a unipolar slider), so what has moved and which
/// way reads down a column without its numbers, and the system's small knob. A tinted track (`AdjustmentSliderSpec.tint`) is
/// drawn in its two colours and has no fill. While the pointer is over its row, or the slider is held or has the keyboard, a
/// ruler of twenty divisions shows under the track. Keyboard focus draws a ring round the knob, clear of it, so the focused one
/// of a tab's sliders reads at a glance; the control does not clip, so the ring stays whole at either end. Tracking reads the
/// same geometry (`AdjustmentSliderControl.mouseDown`).
private final class AdjustmentSliderCell: NSSliderCell {
    private static let knob: CGFloat = 11
    private static let inset: CGFloat = 6
    /// The fill's height, over the track's 2 points, and a tinted track's.
    private static let fill: CGFloat = 3
    private static let tinted: CGFloat = 4
    /// The ruler's divisions, and each tick's height.
    private static let divisions = 20
    private static let tick: CGFloat = 3

    override func barRect(flipped: Bool) -> NSRect {
        guard let view = controlView else { return .zero }
        return NSRect(x: Self.inset, y: view.bounds.midY - 1, width: max(0, view.bounds.width - 2 * Self.inset), height: 2)
    }

    override func knobRect(flipped: Bool) -> NSRect {
        let track = barRect(flipped: flipped)
        let fraction = maxValue > minValue ? (doubleValue - minValue) / (maxValue - minValue) : 0.5
        return NSRect(x: track.minX + CGFloat(fraction) * track.width - Self.knob / 2,
                      y: track.midY - Self.knob / 2, width: Self.knob, height: Self.knob)
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = barRect(flipped: flipped)
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        let control = controlView as? AdjustmentSliderControl
        let spec = control?.spec ?? .light(.contrast)
        if control?.showsEVScale == true {
            drawEVScale(in: track, alpha: alpha)
            return
        }
        // One end of a range: its row draws the track the two share, and each draws its knob.
        if spec.trackPartner != nil { return }
        // The track runs the control's whole width, so it ends where the row's name and value do; the knob's centre travels
        // `barRect`, half a knob in from either end.
        let rail = NSRect(x: 0, y: track.minY, width: controlView?.bounds.width ?? track.width, height: track.height)
        if control?.showsRuler == true, isEnabled {
            // Under the track, where the knob's lower edge does not reach.
            Graphite.inkNSColor(0.3).setFill()
            let top = flipped ? track.maxY + 2.5 : track.minY - 2.5 - Self.tick
            for division in 0...Self.divisions {
                let x = track.minX + CGFloat(division) / CGFloat(Self.divisions) * track.width
                NSRect(x: x - 0.5, y: top, width: 1, height: Self.tick).fill()
            }
        }
        if let tint = spec.tint {
            let bar = NSRect(x: rail.minX, y: track.midY - Self.tinted / 2, width: rail.width, height: Self.tinted)
            let colors = Self.colors(of: tint).map { $0.withAlphaComponent(alpha) }
            NSGradient(colors: colors)?.draw(in: NSBezierPath(roundedRect: bar, xRadius: Self.tinted / 2, yRadius: Self.tinted / 2), angle: 0)
            return
        }
        Graphite.inkNSColor(0.17 * alpha).setFill()
        NSBezierPath(roundedRect: rail, xRadius: 1, yRadius: 1).fill()
        let knob = knobRect(flipped: flipped)
        // From the track's own start on a unipolar slider, whose fill is an amount; from the mark on a bipolar one.
        let origin = spec.fillOrigin == 0 ? rail.minX : track.minX + spec.fillOrigin * track.width
        let fill = NSRect(x: min(origin, knob.midX), y: track.midY - Self.fill / 2, width: abs(knob.midX - origin), height: Self.fill)
        NSColor(Graphite.selection).withAlphaComponent(0.9 * alpha).setFill()
        NSBezierPath(roundedRect: fill, xRadius: Self.fill / 2, yRadius: Self.fill / 2).fill()
        if let mark = spec.markFraction {
            Graphite.inkNSColor(0.34 * alpha).setFill()
            NSRect(x: track.minX + mark * track.width - 0.5, y: track.midY - 4, width: 1, height: 8).fill()
        }
    }

    private func drawEVScale(in track: NSRect, alpha: CGFloat) {
        // Three subdivisions per stop, matching the third-stop keyboard step. Tracking remains continuous.
        let divisions = 30
        for division in 0...divisions {
            let x = track.minX + CGFloat(division) / CGFloat(divisions) * track.width
            let wholeStop = division.isMultiple(of: 3)
            let center = division == divisions / 2
            let height: CGFloat = center ? 13 : wholeStop ? 9 : 4
            Graphite.inkNSColor((wholeStop ? 0.52 : 0.32) * alpha).setFill()
            NSRect(x: x - 0.5, y: track.midY - height / 2, width: 1, height: height).fill()
        }
        let marker = knobRect(flipped: controlView?.isFlipped ?? false).midX
        NSColor(Graphite.selection).withAlphaComponent(0.75 * alpha).setFill()
        NSRect(x: min(track.midX, marker), y: track.midY - 1, width: abs(marker - track.midX), height: 2).fill()
    }

    /// A tinted track's colours, the lower end first, through a neutral at its middle, where the slider does nothing.
    private static func colors(of tint: AdjustmentSliderSpec.Tint) -> [NSColor] {
        let neutral = NSColor(srgbRed: 0.60, green: 0.63, blue: 0.65, alpha: 1)
        switch tint {
        case .warmth: return [NSColor(srgbRed: 0.31, green: 0.53, blue: 0.85, alpha: 1), neutral, NSColor(srgbRed: 0.88, green: 0.64, blue: 0.24, alpha: 1)]
        case .magenta: return [NSColor(srgbRed: 0.30, green: 0.69, blue: 0.42, alpha: 1), neutral, NSColor(srgbRed: 0.78, green: 0.35, blue: 0.75, alpha: 1)]
        }
    }

    override func drawKnob(_ knobRect: NSRect) {
        if let view = controlView, view.window?.firstResponder === view {
            NSColor(Graphite.selection).withAlphaComponent(isEnabled ? 0.9 : 0.4).setStroke()
            let ring = NSBezierPath(ovalIn: knobRect.insetBy(dx: -3.5, dy: -3.5))
            ring.lineWidth = Graphite.Metric.focusRing - 0.5
            ring.stroke()
        }
        if (controlView as? AdjustmentSliderControl)?.showsEVScale == true {
            NSColor(Graphite.selection).withAlphaComponent(isEnabled ? 1 : 0.4).setFill()
            let mark = NSRect(x: knobRect.midX - 1, y: knobRect.midY - 8, width: 2, height: 16)
            mark.fill()
            let top = controlView?.isFlipped == true ? mark.minY : mark.maxY - 2
            NSRect(x: knobRect.midX - 3, y: top, width: 6, height: 2).fill()
        } else {
            super.drawKnob(knobRect)
        }
    }
}

/// Lightroom's scrubbing over a Light value: a drag left or right changes it (`scrubbed`), as one
/// edit gesture; a click without a drag types into it instead. It covers the value's field only
/// while the field is not being edited, so text selection there stays the field's own.
struct ValueScrubber: NSViewRepresentable {
    let spec: AdjustmentSliderSpec
    let value: Float
    /// Which of the value's gestures a scrub is in (`ManualAdjustmentRow.gesture`).
    var gesture = 0
    let onEditingChanged: (Bool) -> Void
    let onScrub: (Float) -> Void
    let onClick: () -> Void
    let onClipping: (Bool) -> Void
    /// Its row's context menu, as the slider's.
    var menu: (@MainActor () -> [MenuEntry])? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> ValueScrubView { ValueScrubView() }

    func updateNSView(_ view: ValueScrubView, context: Context) {
        view.spec = spec
        view.value = value
        view.gesture = gesture
        view.isEnabled = isEnabled
        view.onEditingChanged = onEditingChanged
        view.onScrub = onScrub
        view.onClick = onClick
        view.onClipping = onClipping
        view.menuEntries = menu
    }

    static func dismantleNSView(_ view: ValueScrubView, coordinator: ()) {
        view.onEditingChanged = nil; view.onScrub = nil; view.onClick = nil; view.onClipping = nil; view.menuEntries = nil
    }
}

final class ValueScrubView: NSView {
    var spec = AdjustmentSliderSpec.light(.contrast)
    var value: Float = 0
    /// Which of the value's gestures `value` belongs to; a scrub watches it, as the slider's drag does.
    var gesture = 0
    var isEnabled = true {
        didSet { if isEnabled != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    var onEditingChanged: ((Bool) -> Void)?
    var onScrub: ((Float) -> Void)?
    var onClick: (() -> Void)?
    var onClipping: ((Bool) -> Void)?
    /// Its row's context menu, made when a right-click or a Control-click asks for it. It covers the value only while the value is not
    /// typed in, so the field being typed in keeps its own text menu.
    var menuEntries: (@MainActor () -> [MenuEntry])?
    /// How far the pointer moves before a press becomes a drag rather than a click, in points.
    static let dragThreshold: CGFloat = 3

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .resizeLeftRight) } }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let entries = menuEntries?(), !entries.isEmpty else { return nil }
        return NSMenu(entries: entries)
    }

    override func mouseDown(with event: NSEvent) {
        if popUpContextMenuForControlClick(event) { return }
        guard isEnabled, let window else { return }
        let pressed = convert(event.locationInWindow, from: nil).x
        var start = value, held = gesture, last = pressed, steps: CGFloat = 0, dragging = false, clipping = false
        // Each move counted on its own, so Shift can change mid-drag without a jump.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .flagsChanged],
                                          until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            let option = next.modifierFlags.contains(.option) && next.modifierFlags.isDisjoint(with: [.command, .control])
            if dragging, option != clipping { clipping = option; onClipping?(option) }
            guard next.type == .leftMouseDragged else { continue }
            // A reset, a paste or an undo replaced the gesture, and `value` is what it left: the scrub goes on from there.
            if gesture != held { held = gesture; start = value; steps = 0 }
            let x = convert(next.locationInWindow, from: nil).x
            if !dragging {
                guard abs(x - pressed) >= Self.dragThreshold else { continue }
                dragging = true
                // Counted from the press, so the threshold's points are steps too: one a point.
                last = pressed
                onEditingChanged?(true)
                if option { clipping = true; onClipping?(true) }
            }
            steps += (x - last) * (next.modifierFlags.contains(.shift) ? 10 : 1)
            last = x
            let scrubbed = spec.scrubbed(from: start, steps: steps)
            if scrubbed != value { value = scrubbed; onScrub?(scrubbed) }
        }
        if clipping { onClipping?(false) }
        if dragging { onEditingChanged?(false) } else { onClick?() }
    }
}

/// How each Light control moves. Lightroom Classic 15.6, observed on this Mac: = and − step
/// Exposure by 0.10 EV and Shift-= (+) by 0.33, a third of a stop; the ±100 controls' steps were
/// not measured, so they take 5 and 20, Lightroom's usual pair, as Presence's five do (`AdjustmentSliderSpec.light`).
extension ManualAdjustments.Control {
    /// `value` on the control's resolution, `step`, inside its range (`AdjustmentSliderSpec.snapped`).
    func snapped(_ value: Float) -> Float { AdjustmentSliderSpec.light(self).snapped(value) }

    /// Arrow keys and accessibility increment and decrement: Argent's fine step from before
    /// Lightroom's keys, 0.05 EV or 1. Shift-arrow moves ten.
    var arrowStep: Float { self == .exposure ? 0.05 : 1 }

    /// = and −: 0.10 EV or 5; with Shift, 0.33 EV or 20.
    func keyStep(large: Bool) -> Float {
        self == .exposure ? (large ? 0.33 : 0.1) : (large ? 20 : 5)
    }

    /// Dragging over the value: one resolution step a point, 0.01 EV or 1 (`AdjustmentSliderSpec.scrubbed`).
    func scrubbed(from start: Float, steps: CGFloat) -> Float {
        AdjustmentSliderSpec.light(self).scrubbed(from: start, steps: steps)
    }

    /// The clipping view Option shows while the control moves, as in Lightroom: clipped highlights
    /// for Exposure, Highlights and Whites, clipped shadows for Shadows and Blacks, none for Contrast.
    var clipping: LightClipping? {
        switch self {
        case .exposure, .highlights, .whites: .highlights
        case .shadows, .blacks: .shadows
        case .contrast: nil
        }
    }
}

/// Lightroom's clipping views of the adjusted frame, on the picture the frame view shows: the
/// film preview in 8-bit codes of the colour space a develop is to write (`FilmPreviews.displayImage`).
/// Lightroom marks a channel clipped at its output's ends; a film print ends at its own paper white and
/// deepest black, which can sit inside the display's codes (Portra 400's at 251 and 17 in Display P3;
/// Summer and Bold reach 255), so a channel clips here where its code reaches the print's own end for
/// the frame's stock and settings (`PrintLimits`, from two tiny renders): at or above its white, or at
/// or below its black. A saturated colour the space cannot hold reaches those ends too, and shows as
/// clipped because it is clipped in the file.
enum LightClipping: Equatable, Sendable {
    /// Black, with each channel that reaches the print's white at full: a pixel shows the colour of
    /// the channels it clips, and white where all three do.
    case highlights
    /// White, with each channel that reaches the print's black at zero: a pixel shows the colour of
    /// the channels that did not clip, and black where all three did.
    case shadows

    /// What `code` in channel `channel` (0 red, 1 green, 2 blue) becomes in the view.
    func mapped(_ code: UInt8, channel: Int, limits: PrintLimits) -> UInt8 {
        switch self {
        case .highlights: code >= limits.white[channel] ? 255 : 0
        case .shadows: code <= limits.black[channel] ? 0 : 255
        }
    }

    /// The view of `image`: one copy of it as RGBA8 in its own colour space, which keeps its codes,
    /// and one table lookup over that copy (vImage, on all cores). 1.7 ms for a 2560-pixel film and
    /// 6 ms at the frame view's 4912-pixel cap, debug or optimized (M5 Pro, 2026-10-29). A curve that
    /// turns the print's ends round (white below black) leaves the display's ends to compare with.
    /// Nil for an image that is not RGB.
    func picture(of image: CGImage, limits: PrintLimits = .display) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = image.colorSpace, space.model == .rgb,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return nil }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let limits = (0..<3).allSatisfy { limits.white[$0] > limits.black[$0] } ? limits : .display
        let tables = (0..<3).map { channel in (0...255).map { mapped(UInt8($0), channel: channel, limits: limits) } }
        let opaque = [UInt8](repeating: 255, count: 256)
        var buffer = vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                   rowBytes: context.bytesPerRow)
        // The function names the bytes A, R, G, B; here they are R, G, B and the skipped fourth.
        let error = vImageTableLookUp_ARGB8888(&buffer, &buffer, tables[0], tables[1], tables[2], opaque, vImage_Flags(kvImageNoFlags))
        return error == kvImageNoError ? context.makeImage() : nil
    }
}
