import AppKit
import SwiftUI
import Testing
@testable import ArgentApp

/// A menu as a table (`MenuEntry`), and its two drawings: SwiftUI's (`MenuEntries`) and AppKit's (`NSMenu(entries:)`,
/// and `ContextMenuArea` over a SwiftUI view). No menu is shown: one shown under the test runner can end its whole run,
/// so AppKit's pop-up is given to `ShownMenus`, which keeps each menu and tells its view it opened and closed.
@MainActor @Suite(.serialized) struct ContextMenuTests {
    /// What the rows chosen ran, in order.
    @MainActor final class Ran {
        var rows: [String] = []
    }

    /// Each menu a click asked AppKit to show, in place of showing it: its rows, with their keys, and what `noting` said
    /// as it was asked for. The view is told it opened and closed, as AppKit's pop-up tells it.
    @MainActor final class ShownMenus {
        private(set) var menus: [NSMenu] = []
        private(set) var noted: [String] = []
        var noting: () -> String = { "" }

        private var shownAnyway: NSObjectProtocol?

        init() {
            ContextMenuPresentation.popUp = { [weak self] menu, event, view in
                self?.menus.append(menu)
                self?.noted.append(self?.noting() ?? "")
                view.willOpenMenu(menu, with: event)
                view.didCloseMenu(menu, with: event)
            }
            // A menu shown another way waits for a hand, and the test with it: it fails, and is closed.
            shownAnyway = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                nonisolated(unsafe) let menu = note.object as? NSMenu
                MainActor.assumeIsolated {
                    Issue.record("a menu was shown: \(menu?.items.map(\.title) ?? [])")
                    RunLoop.main.perform(inModes: [.eventTracking]) { MainActor.assumeIsolated { menu?.cancelTrackingWithoutAnimation() } }
                }
            }
        }

        func stop() {
            ContextMenuPresentation.popUp = { menu, event, view in NSMenu.popUpContextMenu(menu, with: event, for: view) }
            if let shownAnyway { NotificationCenter.default.removeObserver(shownAnyway) }
            shownAnyway = nil
        }

        var rows: [[String]] { menus.map { $0.items.map(ShownMenus.row) } }

        /// "Copy Adjustments ⌥⌘C", "—" for a divider.
        static func row(_ item: NSMenuItem) -> String {
            guard !item.isSeparatorItem else { return "—" }
            guard !item.keyEquivalent.isEmpty else { return item.title }
            let flags = item.keyEquivalentModifierMask
            let mods = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
                .filter { flags.contains($0.0) }.map(\.1).joined()
            return "\(item.title) \(mods)\(item.keyEquivalent.uppercased())"
        }
    }

    private func table(_ ran: Ran) -> [MenuEntry] {
        MenuEntry.sections([
            [.heading("test.heading", "For DSC1"),
             .action("test.alpha", "Alpha", chord: KeyChord("c", [.option, .command])) { ran.rows.append("alpha") }],
            [],
            [.action("test.beta", "Beta", isEnabled: false) { ran.rows.append("beta") },
             .action("test.toggle", "Toggle", isOn: true) { ran.rows.append("toggle") },
             .action("test.off", "Off", isOn: false) { ran.rows.append("off") },
             .submenu("test.sub", "Sub", [
                 .action("test.sub.one", "One") { ran.rows.append("one") },
                 .action("test.sub.two", "Two", isEnabled: false) { ran.rows.append("two") },
             ])],
            [.action("test.gamma", "Gamma", chord: KeyChord(KeyEquivalent.downArrow.character, [.command])) { ran.rows.append("gamma") }],
        ])
    }

    @Test func sectionsAreDividedOnceAndAnEmptyOneLeavesNoDivider() {
        let entries = table(Ran())
        #expect(entries.titles == ["For DSC1", "Alpha", "—", "Beta", "Toggle", "Off", "Sub", "—", "Gamma"])
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(MenuEntry.sections([]).isEmpty)
        #expect(MenuEntry.sections([[], [.action("a", "A") {}], []]).titles == ["A"])
        #expect(entries.first?.isDivider == false && entries.last?.isDivider == false)
    }

    @Test func anEntryIsFoundInItsMenuOrASubmenuOfIt() {
        let entries = table(Ran())
        #expect(entries.entry("test.alpha")?.title == "Alpha")
        #expect(entries.entry("test.sub.two")?.title == "Two")
        #expect(entries.entry("test.sub")?.children.titles == ["One", "Two"])
        #expect(entries.entry("test.none") == nil)
        #expect(entries.entry("test.alpha")?.children.isEmpty == true)
    }

    @Test func choosingRunsAnEnabledActionAndNothingElse() throws {
        let ran = Ran()
        let entries = table(ran)
        for id in ["test.alpha", "test.beta", "test.heading", "test.sub", "test.sub.one", "test.sub.two", "test.toggle"] {
            try #require(entries.entry(id)).choose()
        }
        entries.first(where: \.isDivider)?.choose()
        #expect(ran.rows == ["alpha", "one", "toggle"])
        #expect(entries.entry("test.heading")?.isEnabled == false)
    }

    @Test func anAppKitMenuHasTheTablesRowsAndRunsTheOneChosen() throws {
        _ = NSApplication.shared
        let ran = Ran()
        let menu = NSMenu(entries: table(ran))
        #expect(!menu.autoenablesItems)
        #expect(menu.items.map(ShownMenus.row) == ["For DSC1", "Alpha ⌥⌘C", "—", "Beta", "Toggle", "Off", "Sub", "—", "Gamma ⌘\u{F701}"])
        #expect(menu.items[0].isSectionHeader)
        // A heading is never chosen, whatever AppKit says of it; a divider is never enabled.
        #expect(menu.items.filter { !$0.isSectionHeader && !$0.isSeparatorItem }.map(\.isEnabled) == [true, false, true, true, true, true])
        #expect(menu.items[4].state == .on && menu.items[5].state == .off && menu.items[1].state == .off)
        #expect(menu.items[1].keyEquivalentModifierMask == [.option, .command])
        #expect(menu.items[8].keyEquivalentModifierMask == [.command])
        let sub = try #require(menu.items[6].submenu)
        #expect(sub.items.map(\.title) == ["One", "Two"] && sub.items.map(\.isEnabled) == [true, false] && !sub.autoenablesItems)

        menu.performActionForItem(at: 1)
        sub.performActionForItem(at: 0)
        menu.performActionForItem(at: 4)
        #expect(ran.rows == ["alpha", "one", "toggle"])
    }

    @Test func unavailableSubmenusAreDisabledInBothDrawings() throws {
        _ = NSApplication.shared
        for enabled in [false, true] {
            for children: [MenuEntry] in [[], [.action("child", "Child") {}]] {
                let entries = [MenuEntry.submenu("sub", "Sub", isEnabled: enabled, children)]
                let native = NSMenu(entries: entries)
                let hosted = NSHostingMenu(rootView: MenuEntries(make: { entries }))
                hosted.delegate?.menuNeedsUpdate?(hosted)
                hosted.delegate?.menuWillOpen?(hosted)
                hosted.update()
                defer { hosted.delegate?.menuDidClose?(hosted) }
                let nativeItem = try #require(native.items.first)
                let hostedItem = try #require(hosted.items.first)
                #expect(nativeItem.title == "Sub" && hostedItem.title == "Sub")
                #expect(nativeItem.isEnabled == enabled && hostedItem.isEnabled == enabled)
                #expect((hostedItem.submenu != nil) == enabled)
                #expect(nativeItem.submenu?.items.count == children.count)
            }
        }
    }

    @Test func anAvailableSwiftUISubmenuKeepsItsActionsAndTheirPredicates() throws {
        _ = NSApplication.shared
        let ran = Ran()
        let entries = [MenuEntry.submenu("sub", "Sub", [
            .action("enabled", "Enabled") { ran.rows.append("enabled") },
            .action("disabled", "Disabled", isEnabled: false) { ran.rows.append("disabled") },
        ])]
        let menu = NSHostingMenu(rootView: MenuEntries(make: { entries }))
        menu.delegate?.menuNeedsUpdate?(menu)
        let sub = try #require(menu.items.first?.submenu)
        sub.delegate?.menuNeedsUpdate?(sub)
        sub.update()
        #expect(sub.items.map(\.isEnabled) == [true, false])
        sub.performActionForItem(at: 0)
        #expect(ran.rows == ["enabled"])
    }

    /// A window with `view`, laid out and drawn, in front for the events sent to it.
    static func window(_ view: some View, size: NSSize = NSSize(width: 300, height: 200)) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        settle(host)
        return (window, host)
    }

    static func settle(_ view: NSView, turns: Int = 5) {
        for _ in 0..<turns {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    private func key(_ text: String, code: UInt16, _ flags: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                                      isARepeat: false, keyCode: code))
    }

    /// A press and its release at `point` in `window`, each the current event while the window's views take it, as the
    /// application's queue makes a hand's. Not drawn from that queue: a test that did ended the test run when it returned.
    static func click(_ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws {
        let up: NSEvent.EventType = type == .rightMouseDown ? .rightMouseUp : .leftMouseUp
        defer { ContextMenuAreaView.currentEvent = { NSApp.currentEvent } }
        for kind in [type, up] {
            let event = try #require(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: flags,
                                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                        context: nil, eventNumber: 0, clickCount: 1, pressure: kind == up ? 0 : 1))
            ContextMenuAreaView.currentEvent = { event }
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    /// The menu bar binds a key once; a row of SwiftUI's context menu shows it (`MenuEntries`). Measured here through the
    /// window's key equivalents, the way a pressed key goes: the same key on a button in the view is taken, the menu's
    /// is not. Nor is the menu made, by the view's layout, its drawing or the keys: only when it opens.
    @Test func aKeyShownInSwiftUIsMenuBindsNothingWhileItIsClosed() throws {
        @MainActor final class Counts {
            var inView = 0, inMenu = 0, made = 0
        }
        let counts = Counts()
        let view = VStack(spacing: 0) {
            Button("In the view") { counts.inView += 1 }
                .keyboardShortcut("j", modifiers: [.option, .command])
            Color.gray
                .frame(width: 300, height: 150)
                .contextMenu(entries: {
                    counts.made += 1
                    return [.action("test.menu", "In the menu", chord: KeyChord("k", [.option, .command])) { counts.inMenu += 1 }]
                })
        }
        let (window, _) = Self.window(view)
        defer { window.close() }

        #expect(window.performKeyEquivalent(with: try key("j", code: 38, [.option, .command], in: window)))
        #expect(!window.performKeyEquivalent(with: try key("k", code: 40, [.option, .command], in: window)))
        #expect(counts.inView == 1 && counts.inMenu == 0 && counts.made == 0)
    }

    @Test func aClickAsksForAMenuWhenItIsARightClickOrAControlClick() throws {
        func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1))
        }
        #expect(try event(.rightMouseDown).asksForContextMenu)
        #expect(try event(.leftMouseDown, .control).asksForContextMenu)
        #expect(try !event(.leftMouseDown).asksForContextMenu)
        #expect(try !event(.leftMouseDown, .command).asksForContextMenu)
        #expect(try !event(.rightMouseUp).asksForContextMenu)
        #expect(try !event(.mouseMoved).asksForContextMenu)
    }

    /// `ContextMenuArea` over a SwiftUI button, which takes a right-click as a click of its own: a click reaches the
    /// button and makes no menu; a right-click and a Control-click make the menu then, are told it open and closed,
    /// and never reach the button.
    @Test func anAreaOverAViewOpensItsMenuOnARightClickAndLetsAClickThrough() throws {
        @MainActor final class Counts {
            var pressed = 0, made = 0
            var open: [Bool] = []
        }
        let counts = Counts()
        let view = Button { counts.pressed += 1 } label: { Color.gray.frame(width: 200, height: 100) }
            .buttonStyle(.plain)
            .overlay {
                ContextMenuArea(entries: {
                    counts.made += 1
                    return [.action("test.flag", "Flag", chord: KeyChord("f")) {}]
                }, isOpen: { counts.open.append($0) })
            }
            .frame(width: 300, height: 200)
        let (window, host) = Self.window(view)
        defer { window.close() }
        let shown = ShownMenus()
        defer { shown.stop() }
        let middle = host.convert(NSPoint(x: 150, y: 100), to: nil)

        try Self.click(.leftMouseDown, at: middle, in: window)
        #expect(counts.pressed == 1 && counts.made == 0 && shown.menus.isEmpty)

        try Self.click(.rightMouseDown, at: middle, in: window)
        #expect(shown.rows == [["Flag F"]])
        #expect(counts.made == 1 && counts.open == [true, false] && counts.pressed == 1)

        try Self.click(.leftMouseDown, at: middle, flags: .control, in: window)
        #expect(shown.menus.count == 2 && counts.made == 2 && counts.open == [true, false, true, false])
        #expect(counts.pressed == 1)
    }
}
