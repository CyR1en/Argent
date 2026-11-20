import AppKit
import ArgentCore
import SwiftUI

struct CurveHistogram: Sendable {
    let channels: [[Float]]

    /// A small, display-tone distribution of the automatic image; no RAW decode or
    /// full-size readback. The working primaries and transfer match the curve domain.
    static func measure(_ image: CGImage) -> Self? {
        let width = 256, height = max(1, Int(Double(image.height) / Double(image.width) * Double(width)))
        guard let color = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) else { return nil }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 32,
                bytesPerRow: width * 16, space: color,
                bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var bins = [[Float]](repeating: .init(repeating: 0, count: 64), count: 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = SIMD3(pixels[i], pixels[i + 1], pixels[i + 2])
            let values = [ManualRenderSettings.luminance(rgb), rgb.x, rgb.y, rgb.z]
            for channel in 0..<4 {
                let encoded = CompiledToneCurves.encode(values[channel])
                guard encoded.isFinite else { continue }
                let index = min(63, max(0, Int(min(1, max(0, encoded)) * 63)))
                bins[channel][index] += 1
            }
        }
        for channel in 0..<4 {
            let original = bins[channel]
            let maximum = max(1, original.max() ?? 1)
            for i in original.indices {
                bins[channel][i] = (original[max(0, i - 1)] + original[i] + original[min(63, i + 1)]) / (3 * maximum)
            }
        }
        return Self(channels: bins)
    }
    func values(for channel: ToneCurves.Channel) -> [Float] {
        channels[ToneCurves.Channel.allCases.firstIndex(of: channel)!]
    }
}

struct CurveGraph: NSViewRepresentable {
    @Binding var curve: ChannelCurve
    @Binding var selectedPoint: Int
    @Binding var channel: ToneCurves.Channel
    var version: String
    var pointMode: Bool
    var histogram: [Float]
    /// The region whose slider the pointer is over, in Regions mode.
    var litRegion: CurveRegion? = nil
    /// Takes the pending keyboard focus request if it still belongs to this graph.
    var takeFocusRequest: (() -> Bool)?
    var onEditingChanged: (Bool) -> Void
    /// The Curve tab's part of the graph's context menu, the presets and Reset Curves (`InspectorMenus.curveShape`), made as it opens.
    var shapeMenu: (@MainActor () -> [MenuEntry])? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> CurveGraphView { CurveGraphView() }
    func updateNSView(_ view: CurveGraphView, context: Context) {
        // The graph is drawn in the theme's colours: a change of theme asks for this update.
        _ = Graphite.palette
        view.curve = curve; view.selectedPoint = selectedPoint; view.channel = channel; view.version = version
        view.pointMode = pointMode; view.histogram = histogram; view.litRegion = litRegion; view.isEnabled = isEnabled
        view.onChange = { curve = $0 }; view.onSelection = { selectedPoint = $0 }; view.onChannel = { channel = $0 }
        view.onEditingChanged = onEditingChanged
        view.shapeEntries = shapeMenu
        view.refresh()
        // Waits while the frame is not ready to adjust; the update that enables the graph takes
        // it. Regions mode has no points to focus, so the request lapses there.
        if let takeFocusRequest, isEnabled {
            // After this update, once the view is in its window.
            DispatchQueue.main.async { [weak view] in
                guard let view, view.isEnabled, let window = view.window, takeFocusRequest() else { return }
                if view.acceptsFirstResponder, window.makeFirstResponder(view) { view.focusedByKeyboard() }
            }
        }
    }
    static func dismantleNSView(_ view: CurveGraphView, coordinator: ()) {
        view.onChange = nil; view.onSelection = nil; view.onChannel = nil; view.onEditingChanged = nil; view.shapeEntries = nil
    }
}

/// A native two-dimensional control, with per-point accessibility sliders and one edit
/// transaction per drag. View geometry owns both drawing and pointer hit testing.
///
/// With the graph focused the keyboard does everything the pointer does: + and − step
/// through the points (Photoshop's Curves keys), Return adds one on the curve after the
/// selected point and Shift-Return before it, arrows move it, Delete removes it, Escape
/// clears the selection, and 1–4 choose the Tone, Red, Green and Blue curves. F, Frame > Flag
/// elsewhere, does nothing here, as in a text field: a key meant for the graph never flags the frame.
///
/// A right-click or a Control-click opens its menu (`contextEntries(at:)`): on a point, which it selects first, Delete Point; anywhere,
/// the Curve shape menu's presets and Reset Curves. It moves no keyboard focus, so the keys go where they went before.
final class CurveGraphView: NSView {
    var curve: ChannelCurve = .identity
    var selectedPoint = -1
    var channel: ToneCurves.Channel = .tone
    var version = ToneCurves.currentVersion
    var pointMode = true
    var histogram: [Float] = []
    /// The region whose slider the pointer is over, in Regions mode: its band is lit.
    var litRegion: CurveRegion?
    var isEnabled = true
    var onChange: ((ChannelCurve) -> Void)?
    var onSelection: ((Int) -> Void)?
    var onChannel: ((ToneCurves.Channel) -> Void)?
    var onEditingChanged: ((Bool) -> Void)?
    /// The Curve tab's part of the context menu, past Delete Point.
    var shapeEntries: (@MainActor () -> [MenuEntry])?
    private var accessibilityPoints: [CurvePointAccessibility] = []
    private lazy var graphActions = [
        NSAccessibilityCustomAction(name: "Add point") { [weak self] in self?.addPoint(announcing: true) ?? false },
        NSAccessibilityCustomAction(name: "Select next point") { [weak self] in self?.selectAdjacent(1, announcing: true) ?? false },
        NSAccessibilityCustomAction(name: "Select previous point") { [weak self] in self?.selectAdjacent(-1, announcing: true) ?? false },
    ]
    private(set) var samples = ChannelCurve.identity.compiled().samples
    override var acceptsFirstResponder: Bool { isEnabled && pointMode }
    override var isFlipped: Bool { true }
    private var graphRect: NSRect { bounds.insetBy(dx: 5, dy: 5) }
    private var curveColor: NSColor { Self.color(of: channel) }

    /// The colour a channel's curve is drawn in, and its dot over the graph (`CurveChannelDot`).
    static func color(of channel: ToneCurves.Channel) -> NSColor {
        switch channel {
        case .tone: NSColor(Graphite.text)
        case .red: Graphite.isDark ? NSColor(srgbRed: 0.85, green: 0.58, blue: 0.55, alpha: 1)
            : NSColor(srgbRed: 0.68, green: 0.20, blue: 0.17, alpha: 1)
        case .green: Graphite.isDark ? NSColor(srgbRed: 0.60, green: 0.75, blue: 0.59, alpha: 1)
            : NSColor(srgbRed: 0.15, green: 0.45, blue: 0.18, alpha: 1)
        case .blue: Graphite.isDark ? NSColor(srgbRed: 0.60, green: 0.69, blue: 0.83, alpha: 1)
            : NSColor(srgbRed: 0.16, green: 0.34, blue: 0.68, alpha: 1)
        }
    }
    private func position(_ point: CurvePoint) -> NSPoint {
        NSPoint(x: graphRect.minX + CGFloat(point.input) / 255 * graphRect.width,
                y: graphRect.maxY - CGFloat(point.output) / 255 * graphRect.height)
    }
    private func coordinates(_ point: NSPoint) -> (input: Int, output: Int) {
        let x = ((point.x - graphRect.minX) / max(1, graphRect.width) * 255).rounded()
        let y = ((graphRect.maxY - point.y) / max(1, graphRect.height) * 255).rounded()
        return (min(255, max(0, Int(x))), min(255, max(0, Int(y))))
    }
    func refresh() {
        samples = (try? curve.compiled(version: version))?.samples ?? []
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(channel.title) curve editor")
        setAccessibilityHelp(pointMode ? "Click or press Return to add a point. Plus and minus select the next or previous point. "
                             + "Drag or use arrows to move it; Shift-arrow uses ten units. Delete removes an interior point. "
                             + "1 to 4 choose the Tone, Red, Green or Blue curve."
                             : "Curve shaped by the four region controls below.")
        setAccessibilityCustomActions(pointMode && isEnabled ? graphActions : [])
        toolTip = "Distribution of the automatic starting point. The diagonal is an unchanged curve."
        // Keep handles alive through redraws and focus changes so accessibility clients
        // retain the selected element while its coordinates or output are edited.
        let pointCount = pointMode ? curve.points.count : 0
        if accessibilityPoints.count != pointCount {
            accessibilityPoints = pointMode ? curve.points.indices.map { CurvePointAccessibility(owner: self, index: $0) } : []
        }
        for point in accessibilityPoints {
            point.setAccessibilityLabel("\(channel.title) curve point \(point.index + 1)")
        }
        setAccessibilityChildren(accessibilityPoints)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
    override func resetCursorRects() {
        guard isEnabled, pointMode else { return }
        addCursorRect(bounds, cursor: .crosshair)
        for point in curve.points {
            let center = position(point)
            addCursorRect(NSRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20), cursor: .openHand)
        }
    }
    /// Graphite's graph: a matte well with a fine quarter
    /// grid, the faint distribution, the dashed unchanged diagonal, the curve and its points in
    /// the theme's text colour (or the channel's colour), and with keyboard focus a ring round the well.
    override func draw(_ dirtyRect: NSRect) {
        // A well of the panel's ink, as the histogram over the tabs is.
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.radius, yRadius: Self.radius)
        Graphite.inkNSColor(0.045).setFill(); box.fill()
        Graphite.inkNSColor(0.09).setStroke(); box.lineWidth = 1; box.stroke()
        let r = graphRect
        if !pointMode {
            // The four regions the sliders under the graph shape, each a quarter of the tones about its centre
            // (`CurveRegion.center`): every other one a shade lighter, the one whose slider the pointer is over lighter still.
            for (index, region) in CurveRegion.allCases.enumerated() {
                let band = NSRect(x: r.minX + CGFloat(index) / 4 * r.width, y: r.minY, width: r.width / 4, height: r.height)
                let ink: CGFloat = region == litRegion ? 0.1 : index.isMultiple(of: 2) ? 0 : 0.035
                if ink > 0 { Graphite.inkNSColor(ink).setFill(); band.fill() }
                let name = NSAttributedString(string: region.title, attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor(region == litRegion ? Graphite.text : Graphite.tertiaryText)])
                // Clear of the curve, which runs from the lower left to the upper right: the two dark regions' names at the
                // graph's head, the two light ones' at its foot.
                let size = name.size()
                name.draw(at: NSPoint(x: band.midX - size.width / 2, y: index < 2 ? band.minY + 3 : band.maxY - size.height - 3))
            }
        }
        let grid = NSBezierPath()
        for i in 1...3 {
            let t = CGFloat(i) / 4
            grid.move(to: NSPoint(x: r.minX + t * r.width, y: r.minY)); grid.line(to: NSPoint(x: r.minX + t * r.width, y: r.maxY))
            grid.move(to: NSPoint(x: r.minX, y: r.minY + t * r.height)); grid.line(to: NSPoint(x: r.maxX, y: r.minY + t * r.height))
        }
        Graphite.inkNSColor(0.08).setStroke(); grid.lineWidth = 1; grid.stroke()
        if histogram.count > 1 {
            let distribution = NSBezierPath(); distribution.move(to: NSPoint(x: r.minX, y: r.maxY))
            for (i, count) in histogram.enumerated() {
                distribution.line(to: NSPoint(x: r.minX + CGFloat(i) / CGFloat(histogram.count - 1) * r.width,
                    y: r.maxY - CGFloat(count) * r.height * 0.55))
            }
            distribution.line(to: NSPoint(x: r.maxX, y: r.maxY)); distribution.close()
            Graphite.inkNSColor(0.07).setFill(); distribution.fill()
        }
        let reference = NSBezierPath(); reference.move(to: NSPoint(x: r.minX, y: r.maxY)); reference.line(to: NSPoint(x: r.maxX, y: r.minY))
        reference.setLineDash([3, 4], count: 2, phase: 0)
        Graphite.inkNSColor(0.2).setStroke(); reference.lineWidth = 1; reference.stroke()
        if pointMode, curve.points.indices.contains(selectedPoint) {
            let point = position(curve.points[selectedPoint]), guides = NSBezierPath()
            guides.move(to: NSPoint(x: point.x, y: r.maxY)); guides.line(to: point); guides.line(to: NSPoint(x: r.minX, y: point.y))
            guides.setLineDash([2, 3], count: 2, phase: 0)
            curveColor.withAlphaComponent(0.3).setStroke(); guides.lineWidth = 1; guides.stroke()
        }
        if samples.count > 1 {
            let line = NSBezierPath()
            for i in stride(from: 0, through: samples.count - 1, by: 4) {
                let point = NSPoint(x: r.minX + CGFloat(i) / CGFloat(samples.count - 1) * r.width,
                                   y: r.maxY - CGFloat(samples[i]) * r.height)
                if i == 0 { line.move(to: point) } else { line.line(to: point) }
            }
            line.lineJoinStyle = .round
            curveColor.withAlphaComponent(isEnabled ? 1 : 0.4).setStroke(); line.lineWidth = 1.6; line.stroke()
        }
        if pointMode {
            let surround = NSColor(Graphite.chrome)
            for (i, point) in curve.points.enumerated() {
                let center = position(point), chosen = i == selectedPoint
                let radius: CGFloat = chosen ? 4.6 : 3.8
                let dot = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                curveColor.withAlphaComponent(isEnabled ? 1 : 0.4).setFill(); dot.fill()
                surround.setStroke(); dot.lineWidth = 1; dot.stroke()
                if chosen {
                    let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius - 2.5, y: center.y - radius - 2.5,
                                                           width: (radius + 2.5) * 2, height: (radius + 2.5) * 2))
                    curveColor.withAlphaComponent(0.75).setStroke(); ring.lineWidth = 1; ring.stroke()
                }
            }
        }
        // Which curve this is, in the corner the curve leaves last. In Regions mode that corner is a region's name, and the
        // chosen dot over the graph and the line's colour say it.
        if pointMode {
            NSAttributedString(string: channel.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(Graphite.secondaryText),
            ]).draw(at: NSPoint(x: r.minX + 4, y: r.minY + 2))
        }
        if pointMode, curve.points.indices.contains(selectedPoint) { drawTag(for: curve.points[selectedPoint]) }
        if window?.firstResponder === self {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: Self.radius, yRadius: Self.radius)
            NSColor(Graphite.selection).withAlphaComponent(0.9).setStroke(); ring.lineWidth = Graphite.Metric.focusRing; ring.stroke()
        }
    }

    /// The well's corners.
    static let radius: CGFloat = 6

    /// The selected point's numbers beside it, the tone it takes and the tone it gives, so a drag is read where the eye is.
    /// Over the point, or under it where the point is near the graph's top; kept inside the graph at either side.
    private func drawTag(for point: CurvePoint) {
        let text = NSAttributedString(string: "\(point.input) → \(point.output)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor(Graphite.text)])
        let size = text.size(), center = position(point)
        let tag = NSSize(width: size.width + 10, height: size.height + 4)
        var origin = NSPoint(x: center.x - tag.width / 2, y: center.y - tag.height - 10)
        if origin.y < bounds.minY + 2 { origin.y = center.y + 10 }
        origin.x = min(bounds.maxX - tag.width - 2, max(bounds.minX + 2, origin.x))
        let plate = NSBezierPath(roundedRect: NSRect(origin: origin, size: tag), xRadius: 5, yRadius: 5)
        NSColor(Graphite.floatingOpaque).setFill(); plate.fill()
        Graphite.inkNSColor(0.16).setStroke(); plate.lineWidth = 1; plate.stroke()
        text.draw(at: NSPoint(x: origin.x + 5, y: origin.y + 2))
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, NSApp.currentEvent?.type == .keyDown { focusedByKeyboard() }
        needsDisplay = true; return result
    }
    /// Tabbing in lands on a point, so the next arrow already edits one.
    func focusedByKeyboard() {
        guard isEnabled, pointMode, !curve.points.indices.contains(selectedPoint) else { return }
        select(0)
    }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }

    fileprivate func focusGraph() {
        window?.makeFirstResponder(self)
        // SwiftUI clears the numeric field's FocusState after the native click returns.
        // Reassert graph focus after that update so the next arrow edits this point.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEnabled, self.pointMode else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    /// The point a press at `location` takes: the nearest within 12 points.
    private func point(near location: NSPoint) -> Int? {
        let hit = curve.points.indices.min { distance(position(curve.points[$0]), location) < distance(position(curve.points[$1]), location) }
        return hit.flatMap { distance(position(curve.points[$0]), location) <= 12 ? $0 : nil }
    }

    override func mouseDown(with event: NSEvent) {
        if popUpContextMenuForControlClick(event) { return }
        guard isEnabled, pointMode, let window else { return }
        let initial = convert(event.locationInWindow, from: nil)
        let nearby = point(near: initial)
        if event.clickCount == 2, let nearby {
            onEditingChanged?(true); select(nearby); deleteSelected()
            onEditingChanged?(false); focusGraph(); return
        }
        onEditingChanged?(true); defer { onEditingChanged?(false); focusGraph() }
        window.makeFirstResponder(self)
        if let nearby { select(nearby) }
        else {
            let p = coordinates(initial)
            if let same = curve.points.firstIndex(where: { abs($0.input - p.input) <= 1 }) { select(same) }
            else if curve.points.count < ChannelCurve.maximumPoints, p.input > 0, p.input < 255,
                    let point = try? CurvePoint(input: p.input, output: p.output) {
                var points = curve.points; points.append(point); points.sort { $0.input < $1.input }
                guard let updated = try? curve.setting(points: points), let index = points.firstIndex(of: point) else { return }
                setCurve(updated); select(index)
            } else { NSSound.beep(); return }
        }
        let center = position(curve.points[selectedPoint])
        let offset = NSPoint(x: initial.x - center.x, y: initial.y - center.y)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                          inMode: .eventTracking, dequeue: true) {
            let p = convert(next.locationInWindow, from: nil)
            let value = coordinates(NSPoint(x: p.x - offset.x, y: p.y - offset.y))
            moveSelected(input: value.input, output: value.output)
            if next.type == .leftMouseUp { break }
        }
    }
    private func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    override func menu(for event: NSEvent) -> NSMenu? {
        NSMenu(entries: contextEntries(at: convert(event.locationInWindow, from: nil)))
    }

    /// The context menu for a right-click at `location`, in the graph's coordinates. On a point it selects the point first, as a click
    /// does and inside the same edit bracket, so a number being typed for the point that was selected is committed there and not on
    /// this one; then Delete Point, an endpoint's disabled. Anywhere, the Curve tab's presets and Reset Curves. Unlike a click it does
    /// not focus the graph: the keyboard stays where it was, but for a number field, which the commit closes.
    func contextEntries(at location: NSPoint) -> [MenuEntry] {
        var deletePoint: MenuEntry?
        if pointMode, let index = point(near: location) {
            if isEnabled, index != selectedPoint {
                onEditingChanged?(true); select(index); onEditingChanged?(false)
            }
            let isInterior = index > 0 && index < curve.points.count - 1
            deletePoint = InspectorMenus.deletePoint(isEnabled: isEnabled && isInterior) { [weak self] in self?.deletePoint(index) }
        }
        return InspectorMenus.curveGraph(deletePoint: deletePoint, shape: shapeEntries?() ?? [])
    }

    /// Delete Point from the menu: what Delete does on the point, and what it says.
    private func deletePoint(_ index: Int) {
        guard isEnabled, pointMode, index > 0, index < curve.points.count - 1 else { return }
        select(index)
        deleteSelected()
        announce("Deleted. \(selection)")
    }

    func select(_ index: Int) {
        guard curve.points.indices.contains(index) else { return }
        selectedPoint = index; onSelection?(index); needsDisplay = true
    }
    /// The next point in `step`'s direction, wrapping round; with none selected, + starts
    /// at the black end and − at the white end.
    @discardableResult func selectAdjacent(_ step: Int, announcing: Bool = false) -> Bool {
        guard isEnabled, pointMode, !curve.points.isEmpty else { return false }
        let count = curve.points.count
        select(curve.points.indices.contains(selectedPoint) ? ((selectedPoint + step) % count + count) % count
               : step > 0 ? 0 : count - 1)
        if announcing { announce(selection) }
        return true
    }
    func deselect() {
        selectedPoint = -1; onSelection?(-1); needsDisplay = true
    }
    /// Adds a handle where the point curve already runs, so adding alone does not change the
    /// picture: after the selected point, before it with `before` or at the white end, and
    /// otherwise in the widest interval. Fails at 32 points or with no interval two units wide.
    @discardableResult func addPoint(before: Bool = false, announcing: Bool = false) -> Bool {
        guard isEnabled, pointMode else { return false }
        let points = curve.points
        func room(_ i: Int) -> Bool { points.indices.contains(i) && i + 1 < points.count && points[i + 1].input - points[i].input >= 2 }
        var interval = points.indices.contains(selectedPoint)
            ? (before ? [selectedPoint - 1, selectedPoint] : [selectedPoint, selectedPoint - 1]).first(where: room) : nil
        interval = interval ?? points.indices.dropLast().filter(room)
            .max { points[$0 + 1].input - points[$0].input < points[$1 + 1].input - points[$1].input }
        guard points.count < ChannelCurve.maximumPoints, let i = interval else {
            NSSound.beep()
            if announcing { announce(points.count < ChannelCurve.maximumPoints ? "No room for another point" : "A curve holds at most 32 points") }
            return false
        }
        let input = (points[i].input + points[i + 1].input) / 2
        let shape = (try? ChannelCurve(points: points))?.compiled().value(at: Float(input) / 255) ?? Float(input) / 255
        guard let point = try? CurvePoint(input: input, output: min(255, max(0, Int((shape * 255).rounded())))) else { return false }
        var updated = points; updated.insert(point, at: i + 1)
        guard let added = try? curve.setting(points: updated) else { return false }
        onEditingChanged?(true); setCurve(added); select(i + 1); onEditingChanged?(false)
        if announcing { announce("Added \(selection)") }
        return true
    }
    private var selection: String {
        guard curve.points.indices.contains(selectedPoint) else { return "No point selected" }
        let point = curve.points[selectedPoint]
        return "\(channel.title) curve point \(selectedPoint + 1) of \(curve.points.count), Input \(point.input), Output \(point.output)"
    }
    private func announce(_ text: String) {
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    private func setCurve(_ value: ChannelCurve) {
        guard value != curve else { return }
        curve = value; onChange?(value); refresh()
    }
    func moveSelected(input: Int, output: Int) {
        guard isEnabled, pointMode, curve.points.indices.contains(selectedPoint) else { return }
        var points = curve.points
        let x = selectedPoint == 0 ? 0 : selectedPoint == points.count - 1 ? 255
            : min(points[selectedPoint + 1].input - 1, max(points[selectedPoint - 1].input + 1, input))
        guard let point = try? CurvePoint(input: x, output: min(255, max(0, output))) else { return }
        points[selectedPoint] = point
        if let changed = try? curve.setting(points: points) { setCurve(changed) }
    }
    func changePoint(_ index: Int, output: Int) {
        guard isEnabled, pointMode, curve.points.indices.contains(index) else { return }
        onEditingChanged?(true); select(index)
        moveSelected(input: curve.points[index].input, output: output)
        onEditingChanged?(false)
    }
    func deleteSelected() {
        guard isEnabled, pointMode, selectedPoint > 0, selectedPoint < curve.points.count - 1 else { return }
        onEditingChanged?(true); defer { onEditingChanged?(false) }
        var points = curve.points; points.remove(at: selectedPoint)
        if let changed = try? curve.setting(points: points) { setCurve(changed); select(min(selectedPoint, points.count - 1)) }
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled, pointMode else { return }
        if event.keyCode == 51 || event.keyCode == 117 {
            let deleted = selectedPoint > 0 && selectedPoint < curve.points.count - 1
            deleteSelected()
            if deleted { announce("Deleted. \(selection)") }
            return
        }
        // Menu shortcuts keep their modifiers; these keys are the graph's own.
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            switch event.charactersIgnoringModifiers {
            case "+", "=": selectAdjacent(1, announcing: true); return
            case "-", "_": selectAdjacent(-1, announcing: true); return
            case "1", "2", "3", "4":
                let chosen = ToneCurves.Channel.allCases[Int(event.charactersIgnoringModifiers!)! - 1]
                if chosen != channel { onChannel?(chosen); announce("\(chosen.title) curve") }
                return
            // Kept from the menu bar, which would otherwise take them for Flag and the Stock keys once the
            // graph passed them on: with 1 to 4 the graph's channels, 5 to 9 switching the stock surprised.
            case "f", "F", "5", "6", "7", "8", "9": return
            default: break
            }
            if event.specialKey == .carriageReturn || event.specialKey == .enter {
                addPoint(before: event.modifierFlags.contains(.shift), announcing: true); return
            }
            if event.keyCode == 53, curve.points.indices.contains(selectedPoint) { deselect(); return }
        }
        guard curve.points.indices.contains(selectedPoint) else { super.keyDown(with: event); return }
        let step = event.modifierFlags.contains(.shift) ? 10 : 1, point = curve.points[selectedPoint]
        let dx: Int, dy: Int
        switch event.specialKey {
        case .leftArrow: (dx, dy) = (-step, 0)
        case .rightArrow: (dx, dy) = (step, 0)
        case .upArrow: (dx, dy) = (0, step)
        case .downArrow: (dx, dy) = (0, -step)
        default: super.keyDown(with: event); return
        }
        onEditingChanged?(true)
        moveSelected(input: point.input + dx, output: point.output + dy)
        onEditingChanged?(false)
    }
    fileprivate func pointFrame(_ index: Int) -> NSRect {
        guard let window, curve.points.indices.contains(index) else { return .zero }
        let p = position(curve.points[index])
        return window.convertToScreen(convert(NSRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16), to: nil))
    }
}

// Virtual NSView children use AppKit's main-actor accessibility interface. Their frames
// come from the graph; they don't add separately drawn controls or retain their owner.
private final class CurvePointAccessibility: NSView {
    weak var owner: CurveGraphView?
    let index: Int
    init(owner: CurveGraphView, index: Int) {
        self.owner = owner; self.index = index; super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityParent(owner); setAccessibilityRole(.slider)
        setAccessibilityLabel("\(owner.channel.title) curve point \(index + 1)")
        setAccessibilityMinValue(0); setAccessibilityMaxValue(255)
        setAccessibilityHelp("Adjust Output with increment or decrement. Select this point to use arrows for Input and Output.")
    }
    required init?(coder: NSCoder) { nil }
    override func isAccessibilityEnabled() -> Bool { owner?.isEnabled == true && owner?.pointMode == true }
    override func accessibilityFrame() -> NSRect { owner?.pointFrame(index) ?? .zero }
    override func accessibilityValue() -> Any? {
        owner.flatMap { $0.curve.points.indices.contains(index) ? $0.curve.points[index].output : nil }
    }
    override func accessibilityValueDescription() -> String? {
        guard let owner, owner.curve.points.indices.contains(index) else { return nil }
        let point = owner.curve.points[index]
        return "Input \(point.input), Output \(point.output)"
    }
    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard let owner, let number = accessibilityValue as? NSNumber, number.doubleValue.isFinite else { return }
        owner.changePoint(index, output: Int(min(255, max(0, number.doubleValue.rounded()))))
    }
    override func accessibilityPerformPress() -> Bool {
        guard let owner, owner.isEnabled, owner.pointMode else { return false }
        owner.onEditingChanged?(true)
        owner.select(index); owner.focusGraph()
        owner.onEditingChanged?(false)
        return true
    }
    override func accessibilityPerformIncrement() -> Bool {
        guard let owner, owner.isEnabled, owner.curve.points.indices.contains(index) else { return false }
        owner.changePoint(index, output: owner.curve.points[index].output + 1); return true
    }
    /// VoiceOver's add and delete: a point is added after this one (before the white end),
    /// and only interior points can be deleted.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let owner, owner.isEnabled, owner.pointMode, owner.curve.points.indices.contains(index) else { return nil }
        let index = index
        var actions = [NSAccessibilityCustomAction(name: "Add point") { [weak owner] in
            guard let owner else { return false }
            owner.select(index); return owner.addPoint(announcing: true)
        }]
        if index > 0, index < owner.curve.points.count - 1 {
            actions.append(NSAccessibilityCustomAction(name: "Delete point") { [weak owner] in
                guard let owner, owner.curve.points.indices.contains(index) else { return false }
                owner.select(index); owner.deleteSelected(); return true
            })
        }
        return actions
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard let owner, owner.isEnabled, owner.curve.points.indices.contains(index) else { return false }
        owner.changePoint(index, output: owner.curve.points[index].output - 1); return true
    }
}
