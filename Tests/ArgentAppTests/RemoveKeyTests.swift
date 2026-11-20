@testable import ArgentCore
import ArgentRoll
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ArgentApp

/// Remove's keys (`RemoveKeys`, docs/remove-plan.md section 4.8) in the masks' key table: Q opens the tab, Return removes what
/// is selected, Escape stops the frame's newest run, Option at a stroke's press subtracts; and none of them does anything while
/// the inspector has no Remove tab.
@MainActor @Suite(.serialized) struct RemoveKeyTests {
    private static let frame = Frame(id: 0, url: URL(fileURLWithPath: "/tmp/keys/DSC1.ARW"), info: ARWFrameInfo())

    /// Every state Remove's rules read, over the states a mask tool can be in.
    private static var states: [MenuState] {
        var states: [MenuState] = []
        for shows in [false, true] {
            for open in [Frame?.none, frame] {
                for page in [WorkspacePage.roll, .develop, .settings] {
                    for tool in [MaskEditor.Tool?.none, .brush, .linear] {
                        for (tab, selected, running) in [(false, false, false), (true, false, false), (true, true, false), (true, false, true), (true, true, true)] {
                            var state = MenuState()
                            state.showsRemoveTab = shows
                            state.openFrame = open
                            state.canMask = open != nil
                            state.page = page
                            state.armedMaskTool = tool
                            state.isRemoveTabShown = tab && open != nil
                            state.canRemoveObject = selected && open != nil
                            state.canCancelRemoval = running && open != nil
                            states.append(state)
                        }
                    }
                }
            }
        }
        return states
    }

    /// What the menu bar binds outside the masks' table (ArgentApp.swift), the strictest reading: all of them, always.
    private static let appChords: [KeyChord] = [KeyChord("f")] + (1...9).map { KeyChord(Character(String($0))) } + [
        KeyChord("k", [.command, .shift]), KeyChord("o", [.command]), KeyChord("o", [.command, .shift]), KeyChord("i", [.command]),
        KeyChord("i", [.command, .shift]), KeyChord(",", [.command]), KeyChord("d", [.command]), KeyChord(".", [.command]),
        KeyChord("r", [.command, .shift]), KeyChord("+", [.command]), KeyChord("-", [.command]), KeyChord("0", [.command]),
        KeyChord("9", [.command]), KeyChord("c", [.command, .shift]), KeyChord("a", [.command, .shift]),
        KeyChord("1", [.command, .option]), KeyChord("2", [.command, .option]), KeyChord("4", [.command, .option]),
        KeyChord("g", [.command, .shift]), KeyChord("q", [.command]), KeyChord("z", [.command]), KeyChord("z", [.command, .shift]),
        ClipboardKeys.copy, ClipboardKeys.paste, ClipboardKeys.pasteToShown, FrameKeys.remove,
    ]

    @Test func theTableIsThePlans() {
        #expect(RemoveKeys.tab.chord == KeyChord("q") && RemoveKeys.tab.command == .showRemove)
        #expect(RemoveKeys.tabView.chord == KeyChord("5", [.option, .command]) && RemoveKeys.tabView.command == .showRemove)
        #expect(RemoveKeys.removeObject.chord == KeyChord(KeyEquivalent.return.character) && RemoveKeys.removeObject.command == .removeObject)
        #expect(RemoveKeys.cancel.chord == KeyChord(KeyEquivalent.escape.character) && RemoveKeys.cancel.command == .cancelRemoval)
        #expect(RemoveKeys.subtracts == .option)
        #expect(RemoveKeys.items.map(\.title) == ["Remove Tool", "Remove Object", "Cancel Removal"])
        #expect(RemoveKeys.tab.chord?.words == "Q" && RemoveKeys.tabView.chord?.symbols == "⌥⌘5" && RemoveKeys.tab.chord?.isPlain == true)
        // They are in the masks' table, so its own tests hold them to one chord each.
        for key in RemoveKeys.items + [RemoveKeys.tabView] {
            #expect(MaskKeys.all.contains { $0.command == key.command && $0.chord == key.chord }, "\(key.title)")
        }
        let chords = MaskKeys.all.compactMap(\.chord)
        #expect(Set(chords).count == chords.count)
        // Option alone is never a chord of the table: it is the stroke's.
        #expect(!chords.contains { $0.modifiers == [.option] && ($0.key == "q" || $0.key == KeyEquivalent.return.character) })
    }

    @Test func eachKeyIsBoundOnlyWhereItHasSomethingToDo() {
        for state in Self.states {
            let open = state.showsRemoveTab && state.openFrame != nil && state.page == .roll
            for key in [RemoveKeys.tab, RemoveKeys.tabView] {
                #expect(key.isEnabled(state) == open, "\(state.page)")
            }
            #expect(RemoveKeys.removeObject.isEnabled(state) == (open && state.isRemoveTabShown && state.canRemoveObject))
            #expect(RemoveKeys.cancel.isEnabled(state) == (open && state.isRemoveTabShown && state.canCancelRemoval))
            // Whatever is bound, no two items share a chord, the menu bar's own included.
            let enabled = MaskKeys.all.filter { $0.isEnabled(state) }.compactMap(\.chord)
            #expect(Set(enabled).count == enabled.count)
            #expect(enabled.allSatisfy { chord in !Self.appChords.contains(chord) || MaskKeys.flowDigits.contains { $0.chord == chord } })
        }
    }

    @Test func theKeysDoNothingWhileTheTabIsHidden() async throws {
        #expect(Self.states.filter { !$0.showsRemoveTab }.allSatisfy { state in
            (RemoveKeys.items + [RemoveKeys.tabView]).allSatisfy { !$0.isEnabled(state) }
        })
        // This build's own switch, as the fixture leaves it when a suite does not turn it on.
        let fixture = try await RemoveFixture()
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame, tab = model.adjustTab
        model.removalRuns.showsTab = false
        model.openFrame()
        model.perform(.showRemove)
        #expect(model.adjustTab == tab && model.remove.frame == nil && fixture.steps.events.isEmpty)
        #expect(!model.menuState.showsRemoveTab && !model.menuState.isRemoveTabShown && !model.isRemoveTabShown)
        // Even with something selected and a run under way, as the interface could not make them: Return and Escape stay out.
        model.removeTabShown(for: frame)
        model.paintRemoval([CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.4, y: 0.4)], on: frame)
        model.adjustTab = .remove
        model.isAdjustmentsShown = true
        defer { model.adjustTab = .light }
        model.perform(.removeObject)
        #expect(fixture.steps.runs.isEmpty && fixture.rows.isEmpty && model.remove.selection.canRemove)
        let state = model.menuState
        #expect(!RemoveKeys.removeObject.isEnabled(state) && !RemoveKeys.tab.isEnabled(state) && !RemoveKeys.cancel.isEnabled(state))
    }

    @Test func qOpensTheTabReturnRemovesAndEscapeStopsTheNewestRun() async throws {
        let gate = RunGate()
        let fixture = try await RemoveFixture(gate: gate)
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame, steps = fixture.steps
        defer { model.adjustTab = .light }
        model.adjustTab = .light
        model.isAdjustmentsShown = false

        // Q is for an open frame.
        #expect(!RemoveKeys.tab.isEnabled(model.menuState))
        model.perform(.showRemove)
        #expect(model.adjustTab == .light && model.remove.frame == nil)
        model.openFrame()
        #expect(RemoveKeys.tab.isEnabled(model.menuState) && RemoveKeys.tabView.isEnabled(model.menuState))
        model.perform(.showRemove)
        #expect(model.adjustTab == .remove && model.isAdjustmentsShown && model.isRemoveTabShown && model.menuState.isRemoveTabShown)
        #expect(model.remove.frame == frame.url && steps.events == [.noteUse], "the model is wanted as the tab opens")

        // Return has nothing to remove until something is selected, and then removes it.
        #expect(!RemoveKeys.removeObject.isEnabled(model.menuState) && !RemoveKeys.cancel.isEnabled(model.menuState))
        model.perform(.removeObject)
        #expect(steps.runs.isEmpty && fixture.rows.isEmpty)
        model.paintRemoval([CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.4, y: 0.4)], on: frame)
        #expect(model.menuState.canRemoveObject && RemoveKeys.removeObject.isEnabled(model.menuState))
        model.perform(.removeObject)
        #expect(fixture.rows.count == 1 && fixture.rows[0].isPending && !model.menuState.canRemoveObject)
        await gate.arrived(1)

        // Escape stops the frame's newest run, and is not bound when there is none.
        #expect(model.menuState.canCancelRemoval && RemoveKeys.cancel.isEnabled(model.menuState))
        model.perform(.cancelRemoval)
        #expect(fixture.rows.isEmpty && !model.menuState.canCancelRemoval && !RemoveKeys.cancel.isEnabled(model.menuState))
        await model.removalsSettled()
        #expect(fixture.removals.isEmpty)

        // On another tab the two are the photograph's again, whatever is running.
        model.removeObject(on: frame)
        await gate.arrived(2)
        model.showInspector(tab: .light)
        #expect(!RemoveKeys.cancel.isEnabled(model.menuState) && !model.isRemoveTabShown)
        model.perform(.cancelRemoval)
        #expect(fixture.rows.count == 1, "Escape on another tab leaves a run alone")
        #expect(model.remove.selection.coverage == nil && model.remove.frame == nil, "the tab's going drops its selection")
        gate.release()
        await model.removalsSettled()
        #expect(fixture.removals.count == 1, "and the run goes on")
    }

    @Test func optionAtThePressSubtracts() async throws {
        let fixture = try await RemoveFixture()
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame
        model.removeTabShown(for: frame)
        model.paintRemoval([CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5)], on: frame)
        let whole = try #require(model.remove.selection.coverage).values.filter { $0 == 255 }.count
        // Held at the press, and let go before the release: the stroke still subtracts.
        let press = MaskCanvasEvent(phase: .press, fractions: CGPoint(x: 0.5, y: 0.5), point: CGPoint(x: 450, y: 300), modifiers: .option, clickCount: 1)
        model.removeBrush(press, on: frame)
        #expect(model.remove.selection.strokeSubtracts)
        model.removeBrush(MaskCanvasEvent(phase: .release, fractions: CGPoint(x: 0.8, y: 0.5), point: CGPoint(x: 720, y: 300), modifiers: [], clickCount: 1), on: frame)
        let left = try #require(model.remove.selection.coverage).values.filter { $0 == 255 }.count
        #expect(left < whole && left > whole / 3 && !model.remove.selection.strokeSubtracts)
        // Pressed after, it changes nothing of the stroke: the stroke adds.
        model.removeBrush(MaskCanvasEvent(phase: .press, fractions: CGPoint(x: 0.5, y: 0.5), point: CGPoint(x: 450, y: 300), modifiers: [], clickCount: 1), on: frame)
        model.removeBrush(MaskCanvasEvent(phase: .release, fractions: CGPoint(x: 0.8, y: 0.5), point: CGPoint(x: 720, y: 300), modifiers: .option, clickCount: 1), on: frame)
        #expect(model.remove.selection.coverage?.values.filter { $0 == 255 }.count == whole)
    }
}
