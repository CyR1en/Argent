@testable import ArgentCore
import ArgentRoll
import AppKit
import Foundation
import Testing
@testable import ArgentApp

/// The Remove tab's selection (docs/remove-plan.md, section 4.6): a stroke as painted, a stroke or a click snapped to its object,
/// more strokes adding and Option taking away.
@MainActor @Suite(.serialized) struct RemoveSelectionTests {
    /// A selection of `width` by `height` whose pixels from column `from` to column `to` are selected.
    private static func columns(_ from: Int, _ to: Int, width: Int = 60, height: Int = 40) throws -> RemovalPipeline.Selection {
        var coverage = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in from..<to { coverage[y * width + x] = 255 } }
        return try RemovalPipeline.Selection(width: width, height: height, coverage: coverage)
    }

    private static func value(_ coverage: RemoveCoverage?, _ x: Double, _ y: Double) -> UInt8? {
        guard let coverage else { return nil }
        return coverage.values[min(coverage.height - 1, Int(y * Double(coverage.height))) * coverage.width + min(coverage.width - 1, Int(x * Double(coverage.width)))]
    }

    @Test func aStrokeIsPaintedWithRoundCapsOfTheBrushsSize() throws {
        let stroke = [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.75, y: 0.5)]
        // Ten hundredths of the long side across: a radius of 30 pixels in 600.
        let painted = try #require(RemoveCoverage.painted(stroke, brushSize: 10, width: 600, height: 400))
        #expect(painted.width == 600 && painted.height == 400 && painted.frame == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(Set(painted.values) == [0, 255])
        func at(_ x: Int, _ y: Int) -> UInt8 { painted.values[y * 600 + x] }
        #expect(at(300, 200) == 255 && at(300, 172) == 255 && at(300, 228) == 255 && at(300, 168) == 0 && at(300, 232) == 0)
        // Round at its ends: selected a radius past them along the stroke, and not in the corners of that square.
        #expect(at(122, 200) == 255 && at(118, 200) == 0 && at(478, 200) == 255 && at(482, 200) == 0)
        #expect(at(124, 174) == 0 && at(476, 226) == 0)
        // A click is one dab.
        let dab = try #require(RemoveCoverage.painted([CGPoint(x: 0.5, y: 0.5)], brushSize: 10, width: 600, height: 400))
        #expect(dab.values[200 * 600 + 300] == 255 && dab.values[200 * 600 + 328] == 255 && dab.values[200 * 600 + 332] == 0)
        let area = dab.values.filter { $0 == 255 }.count
        #expect(abs(Double(area) - Double.pi * 900) < 120)
        // Outside the picture nothing is painted, and the smallest brush still selects.
        #expect(RemoveCoverage.painted([CGPoint(x: 2, y: 2)], brushSize: 1, width: 600, height: 400) == nil)
        #expect(RemoveCoverage.painted([CGPoint(x: 0.5, y: 0.5)], brushSize: 0.01, width: 600, height: 400) != nil)
        #expect(RemoveCoverage.painted([], brushSize: 10, width: 600, height: 400) == nil)
    }

    /// The bundled model compiles for a size at its first call with it, so the engine hears the size as soon as something is
    /// selected, and not again for a selection that is dropped.
    @Test func aSelectionTellsTheEngineTheSizeItsJobWillHave() async throws {
        let fixture = try await RemoveFixture()
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame, steps = fixture.steps
        model.removeTabShown(for: frame)
        await model.removalsSettled()
        #expect(steps.sizes.isEmpty)
        model.paintRemoval([CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.5, y: 0.5)], on: frame)
        await model.removalRuns.sizeTask?.value
        // The fake's plan is a box of sixteen pixels a side, which the model works on at 512.
        #expect(steps.sizes == [[512, 512]])
        model.clearRemoveSelection()
        #expect(model.removalRuns.sizeTask == nil && steps.sizes.count == 1)
    }

    @Test func selectionsAddAndSubtractAtAnySize() throws {
        let left = RemoveCoverage(try Self.columns(0, 20)), right = RemoveCoverage(try Self.columns(80, 120, width: 120, height: 80))
        let both = left.adding(right)
        #expect(both.width == 60 && both.height == 40)
        #expect(both.values[0] == 255 && both.values[30] == 0 && both.values[45] == 255)
        #expect(both.subtracting(right) == left)
        #expect(left.subtracting(left) == nil && left.selection != nil)
        #expect(RemoveCoverage(width: 2, height: 2, values: [0, 0, 0, 0]).selection == nil)
    }

    @Test func aPaintedStrokeIsTheSelectionAndOptionTakesItAway() async throws {
        let fixture = try await RemoveFixture()
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame, steps = fixture.steps
        model.removeTabShown(for: frame)
        await model.removalsSettled()
        #expect(model.remove.frame == frame.url && steps.events == [.noteUse] && model.remove.engine == .ready)
        #expect(model.remove.selection.snap == .unavailable("not in this test") && !model.remove.selection.canRemove)

        // The stroke shows while it is drawn, and is the selection the moment it is released.
        let down = MaskCanvasEvent(phase: .press, fractions: CGPoint(x: 0.3, y: 0.5), point: CGPoint(x: 270, y: 300), modifiers: [], clickCount: 1)
        model.removeBrush(down, on: frame)
        #expect(model.remove.selection.stroke == [CGPoint(x: 0.3, y: 0.5)] && !model.remove.selection.strokeSubtracts)
        #expect(steps.events == [.noteUse, .noteUse], "a stroke begun wants the model too")
        var move = down
        move.phase = .drag
        move.fractions = CGPoint(x: 0.5, y: 0.5)
        move.point = CGPoint(x: 450, y: 300)
        model.removeBrush(move, on: frame)
        #expect(model.remove.selection.stroke.count == 2 && model.remove.selection.coverage == nil)
        move.phase = .release
        model.removeBrush(move, on: frame)
        let painted = try #require(model.remove.selection.coverage)
        #expect(model.remove.selection.stroke.isEmpty && model.remove.selection.canRemove && model.removalRuns.canRemove)
        #expect(painted.width == 2048 && painted.height == 1366)
        #expect(Self.value(painted, 0.4, 0.5) == 255 && Self.value(painted, 0.7, 0.5) == 0 && Self.value(painted, 0.4, 0.6) == 0)
        #expect(steps.snaps.isEmpty)

        // More strokes add; a larger brush paints wider.
        model.remove.brushSize = 20
        model.paintRemoval([CGPoint(x: 0.7, y: 0.2), CGPoint(x: 0.8, y: 0.2)], on: frame)
        #expect(Self.value(model.remove.selection.coverage, 0.4, 0.5) == 255 && Self.value(model.remove.selection.coverage, 0.75, 0.2) == 255)
        #expect(Self.value(model.remove.selection.coverage, 0.75, 0.3) == 255 && Self.value(painted, 0.4, 0.44) == 0)

        // Option at the press takes the stroke away, and the last of a selection leaves none.
        var option = down
        option.modifiers = .option
        option.fractions = CGPoint(x: 0.75, y: 0.2)
        model.removeBrush(option, on: frame)
        #expect(model.remove.selection.strokeSubtracts)
        model.removeBrush(MaskCanvasEvent(phase: .release, fractions: CGPoint(x: 0.75, y: 0.2), point: CGPoint(x: 270, y: 300), modifiers: [], clickCount: 1), on: frame)
        #expect(Self.value(model.remove.selection.coverage, 0.75, 0.2) == 0 && Self.value(model.remove.selection.coverage, 0.4, 0.5) == 255)
        #expect(!model.remove.selection.strokeSubtracts)
        model.remove.brushSize = 40
        model.paintRemoval([CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.1, y: 0.1)], option: true, on: frame)
        #expect(model.remove.selection.coverage == nil && !model.remove.selection.canRemove && !model.removalRuns.canRemove)

        // Return with nothing selected does nothing; Clear and the tab's going drop a selection.
        model.commitRemoval(on: frame)
        #expect(fixture.rows.isEmpty && steps.runs.isEmpty)
        model.paintRemoval([CGPoint(x: 0.5, y: 0.5)], on: frame)
        #expect(model.remove.selection.canRemove)
        model.clearRemoveSelection()
        #expect(model.remove.selection.coverage == nil && model.remove.frame == frame.url)
        model.paintRemoval([CGPoint(x: 0.5, y: 0.5)], on: frame)
        model.removeTabHidden()
        #expect(model.remove.selection.coverage == nil && model.remove.frame == nil && !model.removalRuns.canRemove)
    }

    @Test func aStrokeSnapsToItsObjectWhereTheSegmenterIsReady() async throws {
        let fixture = try await RemoveFixture()
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame, steps = fixture.steps
        steps.snap = .ready
        steps.found = try Self.columns(0, 20)
        model.removeTabShown(for: frame)
        await model.removalsSettled()
        #expect(model.remove.selection.snap == .ready && model.remove.selection.snapsToObject)

        // A stroke is the segmenter's scribble, and shows until its object is found.
        model.paintRemoval([CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.2, y: 0.5)], on: frame)
        #expect(model.remove.selection.isSnapping && !model.remove.selection.canRemove && model.remove.selection.stroke.count == 2)
        model.commitRemoval(on: frame)
        #expect(fixture.rows.isEmpty, "Return waits for the object")
        await model.removalsSettled()
        #expect(!model.remove.selection.isSnapping && model.remove.selection.stroke.isEmpty && model.remove.selection.canRemove)
        #expect(model.remove.selection.coverage == RemoveCoverage(try Self.columns(0, 20)))
        guard case .scribble(let width, let height, let scribble)? = steps.snaps.first?.prompt else {
            Issue.record("a stroke is asked for as a scribble")
            return
        }
        #expect(width == 2048 && height == 1366 && scribble.contains(255) && steps.snaps[0].excluded.isEmpty)

        // A click is a point, and what it finds is added.
        steps.found = try Self.columns(40, 60)
        model.paintRemoval([CGPoint(x: 0.8, y: 0.5)], on: frame)
        await model.removalsSettled()
        #expect(steps.snaps.count == 2 && steps.snaps[1].prompt == .point(x: 0.8, y: 0.5))
        let both = try #require(model.remove.selection.coverage)
        #expect(both.values[0] == 255 && both.values[30] == 0 && both.values[45] == 255)

        // Option says where the object is not: the same object is asked for again, and replaces what it found before.
        steps.found = try Self.columns(50, 60)
        model.paintRemoval([CGPoint(x: 0.7, y: 0.5)], option: true, on: frame)
        await model.removalsSettled()
        #expect(steps.snaps.count == 3 && steps.snaps[2].prompt == .point(x: 0.8, y: 0.5) && steps.snaps[2].excluded == [CGPoint(x: 0.7, y: 0.5)])
        let apart = try #require(model.remove.selection.coverage)
        #expect(apart.values[0] == 255 && apart.values[45] == 0 && apart.values[55] == 255)

        // The segmenter sees the picture as it is shown, removals made before included.
        model.commitRemoval(on: frame)
        await model.removalsSettled()
        let made = try #require(fixture.removals.first)
        steps.found = try Self.columns(20, 30)
        model.paintRemoval([CGPoint(x: 0.4, y: 0.5)], on: frame)
        await model.removalsSettled()
        #expect(steps.snaps.last?.removals == [made.id])
    }

    @Test func aStrokeIsTheSelectionAsPaintedWhereTheSegmenterFindsNothingOrIsOff() async throws {
        let fixture = try await RemoveFixture()
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame, steps = fixture.steps
        steps.snap = .ready
        model.removeTabShown(for: frame)
        await model.removalsSettled()
        // The segmenter fails: the stroke as painted.
        model.paintRemoval([CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.5, y: 0.5)], on: frame)
        await model.removalsSettled()
        #expect(steps.snaps.count == 1 && !model.remove.selection.isSnapping && model.remove.selection.stroke.isEmpty)
        #expect(Self.value(model.remove.selection.coverage, 0.4, 0.5) == 255 && Self.value(model.remove.selection.coverage, 0.7, 0.5) == 0)
        // Option with no snapped object to ask again erases as painted.
        model.paintRemoval([CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.5, y: 0.5)], option: true, on: frame)
        await model.removalsSettled()
        #expect(steps.snaps.count == 1 && model.remove.selection.coverage == nil)

        // The switch off: nothing is asked of the segmenter.
        steps.found = try Self.columns(0, 20)
        model.setRemoveSnapsToObject(false)
        model.paintRemoval([CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.5, y: 0.5)], on: frame)
        #expect(steps.snaps.count == 1 && !model.remove.selection.isSnapping && model.remove.selection.canRemove)
        #expect(model.remove.selection.coverage?.width == 2048)
        // And it stays off when the selection is dropped.
        model.removeTabHidden()
        #expect(!model.remove.selection.snapsToObject)

        // A selection dropped while its stroke is on its way to the segmenter stays dropped.
        model.setRemoveSnapsToObject(true)
        model.removeTabShown(for: frame)
        model.paintRemoval([CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.5, y: 0.5)], on: frame)
        #expect(model.remove.selection.isSnapping)
        model.clearRemoveSelection()
        await model.removalsSettled()
        #expect(model.remove.selection.coverage == nil && !model.remove.selection.isSnapping && !model.remove.selection.canRemove)
    }
}
