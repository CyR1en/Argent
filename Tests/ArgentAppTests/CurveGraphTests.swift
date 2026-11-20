import AppKit
import ArgentCore
import Testing
@testable import ArgentApp

@MainActor @Suite(.serialized) struct CurveGraphTests {
    private func key(_ key: NSEvent.SpecialKey, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let text = String(try #require(UnicodeScalar(key.rawValue)))
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: flags.union(.function), timestamp: 0, windowNumber: 0, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0))
    }

    @Test func keysKeepPointsOrderedAndEachMoveIsOneGesture() throws {
        _ = NSApplication.shared
        let graph = CurveGraphView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        graph.curve = ToneCurves.Preset.softContrast.curve
        var phases: [Bool] = []
        graph.onEditingChanged = { phases.append($0) }
        graph.select(2)
        graph.keyDown(with: try key(.upArrow, flags: .shift))
        #expect(graph.curve.points[2].output == 147)
        #expect(phases == [true, false])
        graph.moveSelected(input: 255, output: -10)
        #expect(graph.curve.points[2].input == 191)
        #expect(graph.curve.points[2].output == 0)
        graph.select(0)
        graph.keyDown(with: try key(.rightArrow))
        graph.deleteSelected()
        #expect(graph.curve.points[0].input == 0 && graph.curve.points.count == 5)
        graph.select(2)
        graph.deleteSelected()
        #expect(graph.curve.points.count == 4)
        #expect(phases.count == 6)
    }

    private func typed(_ text: String, keyCode: UInt16 = 0, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: keyCode))
    }

    @Test func keyboardAloneStepsAddsEditsAndDeletesPoints() throws {
        _ = NSApplication.shared
        let graph = CurveGraphView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        graph.curve = ToneCurves.Preset.softContrast.curve
        var phases: [Bool] = [], selections: [Int] = []
        graph.onEditingChanged = { phases.append($0) }
        graph.onSelection = { selections.append($0) }
        graph.focusedByKeyboard()
        #expect(graph.selectedPoint == 0)
        for (key, expected) in [("+", 1), ("=", 2), ("-", 1), ("_", 0), ("-", 4), ("+", 0)] {
            graph.keyDown(with: try typed(key))
            #expect(graph.selectedPoint == expected)
        }
        graph.keyDown(with: try typed("\u{1b}", keyCode: 53))
        #expect(graph.selectedPoint == -1 && selections.last == -1)
        graph.keyDown(with: try typed("-"))
        #expect(graph.selectedPoint == 4)
        #expect(phases.isEmpty)

        // Return at the white end adds before it, on the existing point curve.
        let before = graph.curve.compiled().samples
        graph.keyDown(with: try key(.carriageReturn))
        #expect(graph.curve.points.count == 6 && graph.selectedPoint == 4)
        let added = graph.curve.points[4]
        let shape = try ChannelCurve(points: ToneCurves.Preset.softContrast.curve.points).compiled()
        #expect(added.input == 223 && added.output == Int((shape.value(at: 223 / 255) * 255).rounded()))
        #expect(zip(before, graph.curve.compiled().samples).allSatisfy { abs($0 - $1) <= 1.0 / 255 })
        #expect(phases == [true, false])

        // Arrows edit the added point, and Shift-Return adds before the selected one.
        graph.keyDown(with: try key(.upArrow))
        #expect(graph.curve.points[4] == (try CurvePoint(input: 223, output: added.output + 1)))
        graph.select(2)
        graph.keyDown(with: try key(.carriageReturn, flags: .shift))
        #expect(graph.selectedPoint == 2 && graph.curve.points[2].input == 96 && graph.curve.points.count == 7)
        graph.keyDown(with: try key(.enter))
        #expect(graph.selectedPoint == 3 && graph.curve.points[3].input == 112)

        // Delete removes the selected interior point and selects the one after it.
        graph.keyDown(with: try typed("\u{7f}", keyCode: 51))
        #expect(graph.curve.points.count == 7 && graph.selectedPoint == 3 && graph.curve.points[3].input == 128)
        graph.select(0)
        graph.keyDown(with: try typed("\u{7f}", keyCode: 51))
        #expect(graph.curve.points.count == 7)
        #expect(phases.count == 10)

        // Keys with Command, Control or Option belong to menus, not to the graph.
        graph.keyDown(with: try typed("=", flags: .command))
        #expect(graph.selectedPoint == 0)
    }

    @Test func addingNeedsRoomAndStopsAtThirtyTwoPoints() throws {
        _ = NSApplication.shared
        let graph = CurveGraphView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        graph.curve = try ChannelCurve(points: [(0, 0), (1, 1), (2, 2), (255, 255)].map { try CurvePoint(input: $0.0, output: $0.1) })
        graph.select(1)
        // Neither neighbour interval is two units wide, so the widest interval takes it.
        #expect(graph.addPoint())
        #expect(graph.curve.points.map(\.input) == [0, 1, 2, 128, 255] && graph.selectedPoint == 3)
        graph.curve = try ChannelCurve(points: (0..<31).map { try CurvePoint(input: $0, output: $0) } + [CurvePoint(input: 255, output: 255)])
        graph.deselect()
        #expect(graph.addPoint() == false)
        #expect(graph.curve.points.count == 32)
        graph.pointMode = false
        graph.curve = .identity
        #expect(graph.addPoint() == false && graph.curve == .identity)
    }

    @Test func numberKeysChooseTheChannel() throws {
        _ = NSApplication.shared
        let graph = CurveGraphView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        var chosen: [ToneCurves.Channel] = []
        graph.onChannel = { chosen.append($0); graph.channel = $0 }
        for key in ["2", "3", "4", "4", "1"] { graph.keyDown(with: try typed(key)) }
        #expect(chosen == [.red, .green, .blue, .tone])
        graph.keyDown(with: try typed("2", flags: .option))
        #expect(chosen.count == 4)
    }

    /// What the graph passes on up the responder chain, where the menu bar would take F for Flag.
    private final class Passed: NSResponder {
        var keys: [String] = []
        override func keyDown(with event: NSEvent) { keys.append(event.charactersIgnoringModifiers ?? "") }
    }

    /// F is Frame > Flag elsewhere; with the graph focused it does nothing, as in a text field, with a
    /// point selected or not, and another letter still goes on up the chain.
    @Test func fNeverLeavesTheGraph() throws {
        _ = NSApplication.shared
        let graph = CurveGraphView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        graph.curve = ToneCurves.Preset.softContrast.curve
        let passed = Passed()
        graph.nextResponder = passed
        for selected in [-1, 2] {
            if selected < 0 { graph.deselect() } else { graph.select(selected) }
            graph.keyDown(with: try typed("f", keyCode: 3))
            graph.keyDown(with: try typed("F", keyCode: 3, flags: .shift))
        }
        #expect(passed.keys.isEmpty && graph.curve == ToneCurves.Preset.softContrast.curve)
        graph.keyDown(with: try typed("g", keyCode: 5))
        #expect(passed.keys == ["g"])
    }

    /// 1 to 4 choose the graph's channel; 5 to 9, the Stock keys past them, do nothing there either,
    /// so no digit switches the stock while the graph has focus. With Command they still go on.
    @Test func noDigitLeavesTheGraphForTheStockMenu() throws {
        _ = NSApplication.shared
        let graph = CurveGraphView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        graph.curve = ToneCurves.Preset.softContrast.curve
        let passed = Passed()
        graph.nextResponder = passed
        let codes: [Character: UInt16] = ["5": 23, "6": 22, "7": 26, "8": 28, "9": 25]
        for selected in [-1, 2] {
            if selected < 0 { graph.deselect() } else { graph.select(selected) }
            for (digit, code) in codes { graph.keyDown(with: try typed(String(digit), keyCode: code)) }
        }
        #expect(passed.keys.isEmpty && graph.curve == ToneCurves.Preset.softContrast.curve)
        graph.deselect()
        graph.keyDown(with: try typed("5", keyCode: 23, flags: .command))
        #expect(passed.keys == ["5"])
    }

    @Test func voiceOverCanAddAndDeletePoints() throws {
        _ = NSApplication.shared
        let graph = CurveGraphView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        graph.curve = ToneCurves.Preset.softContrast.curve
        graph.refresh()
        #expect(graph.accessibilityCustomActions()?.map(\.name) == ["Add point", "Select next point", "Select previous point"])
        let endpoint = try #require(graph.accessibilityChildren()?[0] as? NSView)
        #expect(endpoint.accessibilityCustomActions()?.map(\.name) == ["Add point"])
        let point = try #require(graph.accessibilityChildren()?[2] as? NSView)
        let actions = try #require(point.accessibilityCustomActions())
        #expect(actions.map(\.name) == ["Add point", "Delete point"])
        #expect(actions[0].handler?() == true)
        #expect(graph.curve.points.map(\.input) == [0, 64, 128, 160, 192, 255] && graph.selectedPoint == 3)
        #expect(actions[1].handler?() == true)
        #expect(graph.curve.points.map(\.input) == [0, 64, 160, 192, 255])
        let next = try #require(graph.accessibilityCustomActions()?[1])
        #expect(next.handler?() == true && graph.selectedPoint == 3)
        graph.pointMode = false
        graph.refresh()
        #expect(graph.accessibilityCustomActions()?.isEmpty == true)
    }

    @Test func accessibilityEditsAreBoundedAndCannotChangeDisabledOrRegionGraphs() throws {
        _ = NSApplication.shared
        let graph = CurveGraphView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        graph.curve = ToneCurves.Preset.softContrast.curve
        graph.refresh()
        let point = try #require(graph.accessibilityChildren()?[2] as? NSView)
        point.setAccessibilityValue(NSNumber(value: 300))
        #expect(graph.curve.points[2].output == 255)
        #expect(point.accessibilityPerformDecrement())
        #expect(graph.curve.points[2].output == 254)
        graph.refresh()
        #expect(graph.accessibilityChildren()?[2] as? NSView === point)
        point.setAccessibilityValue(NSNumber(value: Double.nan))
        #expect(graph.curve.points[2].output == 254)
        graph.isEnabled = false
        #expect(!point.isAccessibilityEnabled())
        #expect(!point.accessibilityPerformIncrement())
        point.setAccessibilityValue(NSNumber(value: 10))
        #expect(graph.curve.points[2].output == 254)
        graph.isEnabled = true; graph.pointMode = false
        point.setAccessibilityValue(NSNumber(value: 10))
        #expect(graph.curve.points[2].output == 254)
        graph.refresh()
        #expect(graph.accessibilityChildren()?.isEmpty == true)
    }

    @Test func graphUsesTheSavedCompilerGridAndDoesNotShowAnUnsupportedShape() {
        _ = NSApplication.shared
        let graph = CurveGraphView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        graph.curve = ToneCurves.Preset.softContrast.curve
        graph.version = "2026-10-09-curves-1"
        graph.refresh()
        #expect(graph.samples.count == 1025)
        graph.version = ToneCurves.currentVersion
        graph.refresh()
        #expect(graph.samples.count == 1021)
        graph.version = "future-compiler"
        graph.refresh()
        #expect(graph.samples.isEmpty)
    }
}
