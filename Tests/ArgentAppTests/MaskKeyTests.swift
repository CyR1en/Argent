import AppKit
import ArgentCore
@testable import ArgentRoll
import Foundation
import SwiftUI
import Testing
@testable import ArgentApp

/// The masks' key table (`MaskKeys`) against docs/masking-plan.md's, and against what the app already binds.
/// What a real key does in the running app needs a real keystroke (P0-S2); `mask chords` reads the live menu.
@MainActor @Suite struct MaskKeyTests {
    private static let frame = Frame(id: 0, url: URL(fileURLWithPath: "/tmp/keys/DSC1.ARW"), info: ARWFrameInfo())

    /// Every state the Mask menu's rules read.
    private static var states: [MenuState] {
        var states: [MenuState] = []
        for open in [Frame?.none, frame] {
            for page in [WorkspacePage.roll, .rolls, .settings] {
                for tool in [MaskEditor.Tool?.none, .brush, .linear, .radial] {
                    for (hasMasks, selected) in [(false, false), (true, false), (true, true)] {
                        var state = MenuState()
                        state.openFrame = open
                        state.canMask = open != nil
                        state.page = page
                        state.armedMaskTool = tool
                        state.hasMasks = hasMasks
                        state.hasSelectedMask = selected
                        states.append(state)
                    }
                }
            }
        }
        return states
    }

    /// What the app's menus bind outside the masks' table (ArgentApp.swift), with when each is enabled.
    /// Those a state does not change are always counted, the strictest reading. Stock's digits stand aside
    /// while the brush is in hand, when they are Flow's.
    private static func appChords(in state: MenuState) -> [KeyChord] {
        var chords = [KeyChord("f")]
        if state.page == .roll && state.armedMaskTool != .brush { chords += (1...9).map { KeyChord(Character(String($0))) } }
        chords += [KeyChord("k", [.command, .shift]), KeyChord("o", [.command]), KeyChord("o", [.command, .shift]),
                   KeyChord(",", [.command]), KeyChord("d", [.command]), KeyChord("d", [.command, .shift]), KeyChord(".", [.command]),
                   KeyChord("r", [.command, .shift]), KeyChord("+", [.command]), KeyChord("-", [.command]), KeyChord("0", [.command]),
                   KeyChord("9", [.command]), KeyChord("c", [.command, .shift]), KeyChord("a", [.command, .shift]),
                   KeyChord("1", [.command, .option]), KeyChord("2", [.command, .option]), KeyChord("g", [.command, .shift]),
                   KeyChord("0", [.command, .control]), KeyChord("1", [.command, .control]), KeyChord("2", [.command, .control]),
                   KeyChord("z", [.command]), KeyChord("z", [.command, .shift])]
        return chords
    }

    private static func item(_ command: MaskCommand) -> MaskKey? {
        MaskKeys.all.first { $0.command == command }
    }

    @Test func noTwoEnabledItemsShareAChordInAnyState() {
        for state in Self.states {
            let enabled = MaskKeys.all.filter { $0.isEnabled(state) }.compactMap(\.chord)
            let chords = enabled + Self.appChords(in: state)
            #expect(Set(chords).count == chords.count, "\(enabled) in \(state.page), tool \(String(describing: state.armedMaskTool))")
        }
    }

    @Test func theTableItselfGivesNoChordTwice() {
        let chords = MaskKeys.all.compactMap(\.chord)
        #expect(Set(chords).count == chords.count)
    }

    @Test func theTableIsThePlans() {
        let expected: [(MaskCommand, KeyChord)] = [
            (.newMask(.brush), KeyChord("k")), (.newMask(.linear), KeyChord("m")), (.newMask(.radial), KeyChord("m", [.shift])),
            (.addBrush, KeyChord("k", [.shift])), (.subtractBrush, KeyChord("k", [.option])), (.newLikeSelected, KeyChord("n")),
            (.showOverlay, KeyChord("o")), (.nextOverlayColour, KeyChord("o", [.shift])),
            (.invert, KeyChord("'")), (.showPins, KeyChord("h")),
            (.largerBrush, KeyChord("]")), (.smallerBrush, KeyChord("[")),
            (.moreFeather, KeyChord("]", [.shift])), (.lessFeather, KeyChord("[", [.shift])),
            (.followEdges, KeyChord("a")),
        ]
        for (command, chord) in expected {
            #expect(Self.item(command)?.chord == chord, "\(command)")
        }
        #expect(MaskKeys.masksTab.chord == KeyChord("w", [.shift]))
        #expect(MaskKeys.masksTabView.chord == KeyChord("3", [.option, .command]))
        #expect(MaskKeys.flowDigits.map(\.title) == ["Flow 10", "Flow 20", "Flow 30", "Flow 40", "Flow 50", "Flow 60", "Flow 70", "Flow 80", "Flow 90", "Flow 100"])
        #expect(MaskKeys.flowDigits.compactMap(\.chord) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 0].map { KeyChord(Character(String($0))) })
    }

    @Test func theMasksTabOpensWhereAFrameIs() {
        for key in [MaskKeys.masksTab, MaskKeys.masksTabView] {
            for state in Self.states {
                #expect(key.isEnabled(state) == (state.openFrame != nil && state.page == .roll))
            }
        }
    }

    /// H means something only where pins are: the Masks tab open on a frame with masks. Elsewhere it is off, and a disabled item never
    /// swallows the key (P0-S2).
    @Test func showPinsIsThereWhereThePinsAre() throws {
        let key = try #require(Self.item(.showPins))
        #expect(key.chord == KeyChord("h"))
        for var state in Self.states {
            for tab in [false, true] {
                state.isMasksTabShown = tab && state.openFrame != nil
                #expect(key.isEnabled(state) == (state.openFrame != nil && state.page == .roll && state.hasMasks && state.isMasksTabShown),
                        "\(state.page) masks \(state.hasMasks) tab \(state.isMasksTabShown)")
            }
        }
    }

    @Test func aNewGradientIsThereOnAnyFrameOpen() {
        for key in [MaskKeys.newLinear, MaskKeys.newRadial] {
            for state in Self.states {
                #expect(key.isEnabled(state) == (state.openFrame != nil && state.page == .roll), "\(key.title)")
            }
        }
    }

    /// What acts on a mask is there while one is selected.
    @Test func whatActsOnTheSelectionNeedsOne() {
        let commands: [MaskCommand] = [.newLikeSelected, .showOverlay, .nextOverlayColour, .invert, .renameMask, .duplicateMask, .switchMask, .deleteMask,
                                       .addShape(.linear, .add), .addShape(.radial, .add), .addShape(.linear, .subtract), .addShape(.radial, .subtract),
                                       .addShape(.linear, .intersect), .addShape(.radial, .intersect)]
        for command in commands {
            let key = Self.item(command)
            #expect(key != nil, "\(command)")
            for state in Self.states {
                #expect(key?.isEnabled(state) == (state.openFrame != nil && state.page == .roll && state.hasSelectedMask), "\(command)")
            }
        }
    }

    @Test func goingThroughTheListNeedsAMaskAndPlacingNeedsATool() {
        for state in Self.states {
            let open = state.openFrame != nil && state.page == .roll
            for command in [MaskCommand.nextMask, .previousMask, .resetMasks] {
                #expect(Self.item(command)?.isEnabled(state) == (open && state.hasMasks), "\(command)")
            }
            #expect(Self.item(.placeGradient)?.isEnabled(state) == (open && (state.armedMaskTool == .linear || state.armedMaskTool == .radial)))
        }
        #expect(Self.item(.nextMask)?.chord == KeyChord(KeyEquivalent.downArrow.character, [.option]))
        #expect(Self.item(.previousMask)?.chord == KeyChord(KeyEquivalent.upArrow.character, [.option]))
    }

    /// Everything the brief lists as keyed is enabled by a real item in a state a person gets to.
    @Test func thePlansGradientKeysAreLive() {
        var state = MenuState()
        state.openFrame = Self.frame
        state.canMask = true
        state.page = .roll
        state.hasMasks = true
        state.hasSelectedMask = true
        for chord in [KeyChord("m"), KeyChord("m", [.shift]), KeyChord("o"), KeyChord("o", [.shift]), KeyChord("'"), KeyChord("n")] {
            #expect(MaskKeys.all.contains { $0.chord == chord && $0.isEnabled(state) }, "\(chord.words)")
        }
        // The brush's own: K always, ⇧K and ⌥K into the selected mask.
        for chord in [KeyChord("k"), KeyChord("k", [.shift]), KeyChord("k", [.option])] {
            #expect(MaskKeys.all.contains { $0.chord == chord && $0.isEnabled(state) }, "\(chord.words)")
        }
        // And what needs the brush in hand, or the plan leaves for later, stays out of a person's way.
        for chord in [KeyChord("h"), KeyChord("["), KeyChord("]"), KeyChord("a"), KeyChord("[", [.shift]), KeyChord("]", [.shift])] {
            #expect(!MaskKeys.all.contains { $0.chord == chord && $0.isEnabled(state) }, "\(chord.words)")
        }
    }

    /// The digits are Flow's while the brush is in hand, and Stock's otherwise (`appChords`): never both, never neither on the roll.
    @Test func theDigitsAreFlowsOnlyWhileTheBrushIsInHand() {
        let digits = Set((0...9).map { KeyChord(Character(String($0))) })
        for state in Self.states {
            let flow = MaskKeys.all.filter { $0.isEnabled(state) }.compactMap(\.chord).filter(digits.contains)
            let brush = state.openFrame != nil && state.page == .roll && state.armedMaskTool == .brush
            #expect(Set(flow) == (brush ? digits : []), "\(state.page), tool \(String(describing: state.armedMaskTool))")
            // Stock's stand aside for the tool, whatever else the state says (a tool outlives no frame, so the two never both go).
            let stock = Self.appChords(in: state).filter(digits.contains)
            #expect(stock.count == (state.page == .roll && state.armedMaskTool != .brush ? 9 : 0))
            #expect(flow.isEmpty || stock.isEmpty)
        }
    }

    /// ] [ ⇧] ⇧[ and A are the brush's, there only while it is in hand; K is there wherever a frame is open, ⇧K and ⌥K with a mask selected.
    @Test func theBrushsKeysAreLiveOnlyWithTheBrushInHand() {
        for state in Self.states {
            let open = state.openFrame != nil && state.page == .roll
            for command in [MaskCommand.largerBrush, .smallerBrush, .moreFeather, .lessFeather, .followEdges] {
                #expect(Self.item(command)?.isEnabled(state) == (open && state.armedMaskTool == .brush), "\(command)")
            }
            #expect(MaskKeys.newBrush.isEnabled(state) == open)
            for command in [MaskCommand.addBrush, .subtractBrush] {
                #expect(Self.item(command)?.isEnabled(state) == (open && state.hasSelectedMask), "\(command)")
            }
        }
    }

    /// A component and a smart row's buttons have no key of their own: the Mask menu is how a keyboard gets to them (plan section 5).
    @Test func theMenuReachesComponentsAndASmartRowsButtons() {
        for command in [MaskCommand.nextComponent, .previousComponent, .componentOperation(.add), .componentOperation(.subtract), .componentOperation(.intersect),
                        .smart(.cancel), .smart(.retry), .smart(.paintInstead), .smart(.update), .smart(.keep)] {
            #expect(Self.item(command) != nil && Self.item(command)?.chord == nil, "\(command)")
        }
        var state = MenuState()
        state.openFrame = Self.frame
        state.canMask = true
        state.page = .roll
        state.hasMasks = true
        state.hasSelectedMask = true
        // Next Component needs a mask selected; the first component's operation is fixed, so Set Component waits for a later one.
        #expect(Self.item(.nextComponent)?.isEnabled(state) == true)
        #expect(Self.item(.componentOperation(.subtract))?.isEnabled(state) == false)
        state.selectedComponent = 0
        #expect(Self.item(.componentOperation(.subtract))?.isEnabled(state) == false)
        state.selectedComponent = 1
        #expect(Self.item(.componentOperation(.subtract))?.isEnabled(state) == true)
        // A smart row's item follows what the row offers, nothing more.
        #expect(SmartRowStatus.Action.allCases.allSatisfy { Self.item(.smart($0))?.isEnabled(state) != true })
        state.selectedSmartActions = [.update, .keep]
        #expect(Self.item(.smart(.update))?.isEnabled(state) == true)
        #expect(Self.item(.smart(.keep))?.isEnabled(state) == true)
        #expect(Self.item(.smart(.cancel))?.isEnabled(state) == false)
        state.hasSelectedMask = false
        #expect(Self.item(.smart(.update))?.isEnabled(state) == false)
    }

    @Test func deleteIsNeverAMenuKeyAndBindsWhatTheKeySends() {
        #expect(Self.item(.deleteMask)?.chord == nil)
        let menuKeys = MaskKeys.all.compactMap(\.chord?.key)
        #expect(!menuKeys.contains("\u{7F}") && !menuKeys.contains("\u{8}"))
        // SwiftUI's `.delete` is not what the Mac's Delete key sends.
        #expect(KeyEquivalent.delete.character != "\u{7F}")
        #expect(MaskKeys.delete.contains(KeyEquivalent("\u{7F}")) && MaskKeys.delete.contains(.deleteForward))
        #expect(!MaskKeys.delete.contains(.delete))
    }

    private func key(_ text: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                      characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 13))
    }

    @Test func aPlainKeyIsIgnoredWhileATextFieldHasTheKeyboard() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = content
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 24))
        let slider = AdjustmentSliderControl(frame: NSRect(x: 10, y: 50, width: 100, height: 24))
        content.addSubview(field)
        content.addSubview(slider)

        #expect(window.makeFirstResponder(field))
        // The field editor is what a field's keys reach, as in the inspector's value fields.
        let responder = try #require(window.firstResponder)
        #expect(responder is NSText)
        #expect(MaskKeys.isTypedIntoField(try key("W", flags: .shift), firstResponder: responder))
        #expect(MaskKeys.isTypedIntoField(try key("m"), firstResponder: responder))
        #expect(MaskKeys.isTypedIntoField(try key("k", flags: .option), firstResponder: responder))
        // A chord with Command or Control is the menu's, and a pointer in the menu is not a key.
        #expect(!MaskKeys.isTypedIntoField(try key("3", flags: [.command, .option]), firstResponder: responder))
        #expect(!MaskKeys.isTypedIntoField(try key("w", flags: .control), firstResponder: responder))
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        #expect(!MaskKeys.isTypedIntoField(click, firstResponder: responder))
        #expect(!MaskKeys.isTypedIntoField(nil, firstResponder: responder))

        // A slider or the photograph lets the same key through to the menu.
        #expect(window.makeFirstResponder(slider))
        #expect(!MaskKeys.isTypedIntoField(try key("W", flags: .shift), firstResponder: window.firstResponder))
        #expect(!MaskKeys.isTypedIntoField(try key("W", flags: .shift), firstResponder: nil))
    }

    @Test func chordsReadInTheAppsWords() {
        #expect(MaskKeys.masksTab.chord?.symbols == "⇧W")
        #expect(MaskKeys.masksTabView.chord?.symbols == "⌥⌘3")
        #expect(MaskKeys.newRadial.chord?.words == "Shift-M")
        #expect(MaskKeys.newBrush.chord?.words == "K")
        #expect(KeyChord("a", [.command, .shift]).words == "Shift-Command-A")
        #expect(KeyChord("3", [.command, .option]).isPlain == false && KeyChord("k", [.option]).isPlain)
    }

    /// The shortcut SwiftUI is handed is the chord: the key and exactly its modifiers.
    @Test func aChordMakesItsShortcut() {
        let radial = KeyChord("m", [.shift]).shortcut
        #expect(radial.key == KeyEquivalent("m") && radial.modifiers == .shift)
        let view = KeyChord("3", [.option, .command]).shortcut
        #expect(view.key == KeyEquivalent("3") && view.modifiers == [.option, .command])
        let plain = KeyChord("'").shortcut
        #expect(plain.key == KeyEquivalent("'") && plain.modifiers.isEmpty)
    }
}
