import AppKit
import SwiftUI

/// One row of a context menu, as data. A menu is a table of these (docs/context-menus-plan.md), so it is
/// tested as a table, as `MaskKeys` is, and drawn by SwiftUI (`MenuEntries`, `View.contextMenu(entries:)`)
/// and by AppKit (`NSMenu(entries:)`) alike: the sheet's ground, the mask canvas and the curve graph are
/// AppKit views, and a frame's menu is the same wherever it is opened.
@MainActor struct MenuEntry: Identifiable {
    enum Kind {
        case action(() -> Void)
        case submenu([MenuEntry])
        case divider
        /// A line that names what the rows under it act on, such as a mask's name. Never chosen.
        case heading
    }

    /// Stable within its menu, for the tests and for SwiftUI: "frame.copy", "mask.delete".
    let id: String
    var title: String
    var kind: Kind
    var isEnabled = true
    /// A check beside it; `nil` for an item that is no switch.
    var isOn: Bool?
    /// Its key in the menu bar, shown here and never bound here: the menu bar's item owns the key.
    var chord: KeyChord?
    var isDestructive = false

    static func action(_ id: String, _ title: String, chord: KeyChord? = nil, isEnabled: Bool = true, isOn: Bool? = nil,
                       isDestructive: Bool = false, _ run: @escaping () -> Void) -> MenuEntry {
        MenuEntry(id: id, title: title, kind: .action(run), isEnabled: isEnabled, isOn: isOn, chord: chord, isDestructive: isDestructive)
    }

    static func submenu(_ id: String, _ title: String, isEnabled: Bool = true, _ entries: [MenuEntry]) -> MenuEntry {
        MenuEntry(id: id, title: title, kind: .submenu(entries), isEnabled: isEnabled)
    }

    static func heading(_ id: String, _ title: String) -> MenuEntry {
        MenuEntry(id: id, title: title, kind: .heading, isEnabled: false)
    }

    /// The sections one after another with a divider between each two; an empty section leaves none.
    static func sections(_ sections: [[MenuEntry]]) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        for section in sections where !section.isEmpty {
            if !entries.isEmpty { entries.append(MenuEntry(id: "divider.\(entries.count)", title: "", kind: .divider)) }
            entries += section
        }
        return entries
    }

    /// The submenu's rows, or none.
    var children: [MenuEntry] {
        if case .submenu(let entries) = kind { return entries }
        return []
    }

    var isDivider: Bool {
        if case .divider = kind { return true }
        return false
    }

    /// Chooses it, as a click would: nothing for a disabled row, a divider, a heading or a submenu.
    func choose() {
        guard isEnabled, case .action(let run) = kind else { return }
        run()
    }
}

extension [MenuEntry] {
    /// The row with `id`, in this menu or a submenu of it, for the tests.
    @MainActor func entry(_ id: String) -> MenuEntry? {
        for entry in self {
            if entry.id == id { return entry }
            if let found = entry.children.entry(id) { return found }
        }
        return nil
    }

    /// The rows' titles, a divider as "—", for the tests.
    @MainActor var titles: [String] { map { $0.isDivider ? "—" : $0.title } }
}

/// A table of entries as SwiftUI menu content. The table is made in `body`, not by the view that carries the
/// menu, so a cell on the sheet does not read the clipboard or the edit each time it is drawn: SwiftUI asks for a
/// context menu's content when the menu opens, and not as its view is laid out or drawn (`ContextMenuTests`).
struct MenuEntries: View {
    let make: @MainActor () -> [MenuEntry]

    var body: some View {
        ForEach(make()) { entry in MenuEntryRow(entry: entry) }
    }
}

/// An unavailable submenu is a disabled command, as SwiftUI's `Menu.disabled` leaves the native parent
/// enabled. AppKit omits the arrow of a disabled submenu too (`NSMenu(entries:)`).
struct Submenu<Content: View>: View {
    let title: String
    let isEnabled: Bool
    @ViewBuilder let content: () -> Content

    init(_ title: String, isEnabled: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.isEnabled = isEnabled
        self.content = content
    }

    var body: some View {
        if isEnabled {
            Menu(title, content: content)
        } else {
            Button(title) {}.disabled(true)
        }
    }
}

private struct MenuEntryRow: View {
    let entry: MenuEntry

    var body: some View {
        switch entry.kind {
        case .divider:
            Divider()
        case .heading:
            Text(entry.title)
        case .submenu(let children):
            Submenu(entry.title, isEnabled: entry.isEnabled) { MenuEntries(make: { children }) }
        // Shown, not bound: measured, a key on a row of SwiftUI's context menu is not taken while the menu is closed,
        // where the same key on a button in the view is (`ContextMenuTests.aKeyShownInSwiftUIsMenuBindsNothingWhileItIsClosed`),
        // and a one-off run found the same once the menu had been open; the menu bar's item owns the key.
        case .action(let run):
            if let isOn = entry.isOn {
                Toggle(entry.title, isOn: Binding(get: { isOn }, set: { _ in run() }))
                    .keyboardShortcut(entry.chord?.shortcut)
                    .disabled(!entry.isEnabled)
            } else {
                Button(entry.title, role: entry.isDestructive ? .destructive : nil, action: run)
                    .keyboardShortcut(entry.chord?.shortcut)
                    .disabled(!entry.isEnabled)
            }
        }
    }
}

extension View {
    /// A context menu drawn from its table, made when the menu is asked for.
    func contextMenu(entries: @escaping @MainActor () -> [MenuEntry]) -> some View {
        contextMenu { MenuEntries(make: entries) }
    }
}

extension NSMenu {
    /// The same table as an AppKit menu, for a view that is not SwiftUI's. Its keys are shown, and bind
    /// nothing: it is made when it is asked for and let go when it closes, and a contextual menu is not searched
    /// for key equivalents.
    @MainActor convenience init(entries: [MenuEntry]) {
        self.init()
        autoenablesItems = false
        for entry in entries { addItem(MenuEntryItem.make(entry)) }
    }
}

/// An AppKit menu item that runs its entry's action.
private final class MenuEntryItem: NSMenuItem {
    private var run: (() -> Void)?

    @MainActor static func make(_ entry: MenuEntry) -> NSMenuItem {
        switch entry.kind {
        case .divider:
            return .separator()
        case .heading:
            return .sectionHeader(title: entry.title)
        case .submenu(let children):
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(entries: children)
            item.isEnabled = entry.isEnabled
            return item
        case .action(let run):
            let item = MenuEntryItem(title: entry.title, action: #selector(fire), keyEquivalent: "")
            item.target = item
            item.run = run
            item.isEnabled = entry.isEnabled
            if let isOn = entry.isOn { item.state = isOn ? .on : .off }
            if let chord = entry.chord {
                item.keyEquivalent = String(chord.key)
                item.keyEquivalentModifierMask = chord.modifierFlags
            }
            return item
        }
    }

    @objc private func fire() { run?() }
}

// MARK: - A menu from AppKit over a SwiftUI view

/// Shows a context menu at the click that asked for it: AppKit's own pop-up, which tells the view as the menu opens
/// and closes (`willOpenMenu`, `didCloseMenu`). The tests give their own, which keeps the menu and tells the view the
/// same: a menu shown under the test runner can end its whole run.
@MainActor enum ContextMenuPresentation {
    static var popUp: @MainActor (NSMenu, NSEvent, NSView) -> Void = { menu, event, view in
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}

/// Over a SwiftUI view, its menu from AppKit (`NSMenu(entries:)`), made when a right-click or a Control-click asks
/// for it; every other event goes through to the view under it. For a view that marks what its menu is for while
/// the menu is open, which SwiftUI's `contextMenu` does not tell, and whose right-click must not reach the view, as
/// a filmstrip thumbnail's must not open its frame. `anchor` opens the same menu for VoiceOver's Show Menu.
struct ContextMenuArea: NSViewRepresentable {
    let entries: @MainActor () -> [MenuEntry]
    /// Told `true` as the menu opens and `false` once it has closed.
    var isOpen: @MainActor (Bool) -> Void = { _ in }
    var anchor: ContextMenuAnchor?

    func makeNSView(context: Context) -> ContextMenuAreaView {
        let view = ContextMenuAreaView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ContextMenuAreaView, context: Context) {
        view.entries = entries
        view.isOpen = isOpen
        anchor?.view = view
    }
}

/// Where VoiceOver's Show Menu opens a `ContextMenuArea`'s menu: its view, once it has one.
@MainActor final class ContextMenuAnchor {
    fileprivate(set) weak var view: ContextMenuAreaView?

    func open() { view?.openMenu() }
}

final class ContextMenuAreaView: NSView {
    var entries: @MainActor () -> [MenuEntry] = { [] }
    var isOpen: @MainActor (Bool) -> Void = { _ in }

    /// The event the application is handling, which the tests give as the application's queue would.
    static var currentEvent: @MainActor () -> NSEvent? = { NSApp.currentEvent }

    /// Here only for a click that asks for the menu; a click, the pointer's hover and a scroll find the view under
    /// it. A SwiftUI button takes a right-click as a click, so the strip's would otherwise open its frame.
    override func hitTest(_ point: NSPoint) -> NSView? {
        Self.currentEvent()?.asksForContextMenu == true ? super.hitTest(point) : nil
    }

    /// A Control-click in a window in the background opens the menu, as a right-click does, rather than only
    /// bringing the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { event?.asksForContextMenu == true }

    // The menu is opened here rather than given to AppKit by `menu(for:)`, which the window would show itself on a
    // Control-click: one way for both clicks (`ContextMenuPresentation`).
    override func rightMouseDown(with event: NSEvent) { open(with: event) }

    /// Only a Control-click is let in as a click (`hitTest`).
    override func mouseDown(with event: NSEvent) {
        if event.asksForContextMenu { open(with: event) }
    }

    private func open(with event: NSEvent) {
        ContextMenuPresentation.popUp(NSMenu(entries: entries()), event, self)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) { isOpen(true) }
    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) { isOpen(false) }

    /// VoiceOver's Show Menu: the menu at the view's middle, marked while it is open as a click's is.
    func openMenu() {
        isOpen(true)
        NSMenu(entries: entries()).popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
        isOpen(false)
    }
}

extension NSEvent {
    /// A right-click, or a click with Control held: what opens a context menu.
    var asksForContextMenu: Bool {
        switch type {
        case .rightMouseDown: true
        case .leftMouseDown: modifierFlags.contains(.control)
        default: false
        }
    }
}

extension KeyChord {
    /// Its modifiers as AppKit names them.
    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }
}
