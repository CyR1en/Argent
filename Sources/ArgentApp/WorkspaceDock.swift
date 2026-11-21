import AppKit
import SwiftUI

/// The command bar stays in place while its center changes and the film samples unfold above it.
struct WorkspaceDock: View {
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settingsShown = false
    @State private var width: CGFloat = 0
    @FocusState private var shelfFocused: Bool

    private enum Center { case roll, frame, stocks }

    private var center: Center {
        if model.isStockShelfVisible { return .stocks }
        return model.isFrameOpen ? .frame : .roll
    }

    var body: some View {
        VStack(spacing: 0) {
            if center == .stocks {
                VStack(spacing: 0) {
                    StockShelf()
                        .focusable()
                        .focused($shelfFocused)
                        .focusEffectDisabled()
                        .workspaceHorizontalArrows { _, _ in .ignored }
                        .accessibilityAction(.escape) { dismissLayer() }
                    SectionDivider()
                }
                .transition(reduceMotion ? .identity : .offset(y: 5).combined(with: .opacity))
            }
            commandBar
                .zIndex(1)
        }
        .frame(maxWidth: 930)
        .graphiteFloating(cornerRadius: Graphite.Metric.dockRadius)
        .animation(reduceMotion ? nil : Graphite.Motion.surface, value: center)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // Point above the settings button, including when the shelf sits between it and the popover.
        .popover(isPresented: $settingsShown,
                 attachmentAnchor: .point(UnitPoint(x: 1 - 24 / max(48, width), y: 0)), arrowEdge: .top) {
            RollControlsView(frame: model.shownFrame)
                .padding(14)
                .foregroundStyle(Graphite.text)
                .accessibilityAction(.escape) { settingsShown = false }
        }
        .background {
            if center == .stocks || settingsShown {
                DockEscapeKey {
                    guard model.workspacePage == .roll, !model.isSheetShown,
                          settingsShown || center == .stocks else { return false }
                    dismissLayer()
                    return true
                }
            }
        }
        .onChange(of: model.isStockShelfVisible) { _, shown in
            settingsShown = false
            if shown { shelfFocused = true }
        }
        .onChange(of: model.isFrameOpen) { settingsShown = false }
        .onChange(of: model.isSheetShown) { _, shown in
            if shown { settingsShown = false }
        }
        .padding(.horizontal, Graphite.Metric.dockInset)
        .padding(.bottom, Graphite.Metric.dockInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editing dock")
    }

    private var commandBar: some View {
        HStack(spacing: 8) {
            GraphiteSegmented(selection: Binding(get: { model.isFrameOpen }, set: { opens in
                if opens { model.showFrame() } else { model.showRoll() }
            }), segments: [
                .init(value: false, title: "Contact sheet", help: "Show the roll as a contact sheet.", symbol: "square.grid.2x2"),
                .init(value: true, title: "Single frame", help: "Open the selected frame.", isEnabled: model.isFrameOpen || model.canOpenFrame, symbol: "photo")
            ], size: .regular)
            .fixedSize()
            DockDivider(height: 22)
            ZStack(alignment: .leading) {
                switch center {
                case .roll: RollDock().transition(centerTransition)
                case .frame: FilmstripDock().transition(centerTransition)
                case .stocks: stockContext.transition(centerTransition)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            DockDivider(height: 22)
            StockChooserButton(isExpanded: center == .stocks) {
                model.toggleStockPanel()
            }
            .fixedSize()
            Button {
                settingsShown.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(settingsShown ? Graphite.dockAccent : Graphite.secondaryText)
            }
            .buttonStyle(.graphite(.quiet, size: .small, isOn: settingsShown))
            .help("Film settings: Rated at, Lab balance and Grain.")
            .accessibilityLabel("Film settings")
            .accessibilityValue(settingsShown ? "Expanded" : "Collapsed")
        }
        .hoverGlide()
        .padding(.horizontal, 8)
        .frame(height: Graphite.Metric.dockHeight)
    }

    private var centerTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(insertion: .opacity.animation(Graphite.Motion.ease(0.18).delay(0.045 * Graphite.Motion.slow)),
                           removal: .opacity.animation(Graphite.Motion.ease(0.12)))
    }

    /// What the stock panel's choice applies to: the whole roll on the sheet, the open frame alone in the frame view.
    private var stockContext: some View {
        let character = StockCharacter.sentence(for: model.shownStock?.id)
        let frame = model.shownFrame
        let scope = ControlsScope(frame: frame).title
        return HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    stockScopeIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Film stock · \(scope)")
                            .textCase(.uppercase)
                            .tracking(0.6)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Graphite.dockAccent)
                        if let character {
                            Text(verbatim: character)
                                .font(Graphite.Typeface.small)
                                .contentTransition(.opacity)
                        }
                    }
                }
                .fixedSize()
                HStack(spacing: 6) {
                    stockScopeIcon
                    Text(verbatim: scope).font(Graphite.Typeface.small)
                }
                .fixedSize()
                stockScopeIcon
            }
            .help([model.shownStockName, character].compactMap { $0 }.joined(separator: " · "))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(frame == nil ? "Film stock for the whole roll" : "Film stock for this frame")
            .accessibilityValue(character ?? "")
            if let frame, model.hasOwnStock(frame) {
                Button("Same as roll") { model.setStock(nil, for: frame) }
                    .buttonStyle(.graphite(.quiet, size: .small))
                    .fixedSize()
                    .help("Make this frame develop through the roll's stock" + (model.stockName.map { ", \($0)" } ?? ""))
            }
        }
    }

    private var stockScopeIcon: some View {
        Image(systemName: model.shownFrame == nil ? "square.3.layers.3d" : "photo")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Graphite.dockAccent)
            .accessibilityHidden(true)
    }

    private func dismissLayer() {
        if settingsShown {
            settingsShown = false
        } else {
            model.isStockPanelShown = false
        }
    }
}

extension View {
    /// The shelf stays open across view changes, even when the photograph or sheet takes keyboard focus.
    func workspaceHorizontalArrows(_ navigate: @escaping (Int, KeyPress) -> KeyPress.Result) -> some View {
        modifier(WorkspaceHorizontalArrows(navigate: navigate))
    }
}

private struct WorkspaceHorizontalArrows: ViewModifier {
    @Environment(RollModel.self) private var model
    let navigate: (Int, KeyPress) -> KeyPress.Result

    func body(content: Content) -> some View {
        content.onKeyPress(keys: [.leftArrow, .rightArrow]) { key in
            guard !model.isSheetShown else { return .ignored }
            let step = key.key == .rightArrow ? 1 : -1
            if model.isStockShelfVisible,
               key.modifiers.intersection([.shift, .control, .option, .command]).isEmpty {
                model.selectStock(model.shownStockIndex + step)
                return .handled
            }
            return navigate(step, key)
        }
    }
}

/// Escape reaches the dock before the photograph or grid. A menu, text editor,
/// popover window or sheet still receives the Escape intended for it.
private struct DockEscapeKey: NSViewRepresentable {
    let dismiss: () -> Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.dismiss = dismiss
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.dismiss = dismiss
    }

    final class KeyView: NSView {
        var dismiss: (() -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard let newWindow else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak newWindow] event in
                guard event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                      let window = newWindow, event.window === window, window.attachedSheet == nil,
                      !(window.firstResponder is NSText) else { return event }
                return MainActor.assumeIsolated { self?.dismiss?() == true } ? nil : event
            }
        }
    }
}
