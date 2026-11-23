import AppKit
import SwiftUI
import Testing
@testable import ArgentApp

/// Exercise focus and scrolling in an attached workspace, where SwiftUI installs its responders and scroll views.
@MainActor @Suite(.serialized) struct DockNavigationTests {
    private func withWorkspace(frameCount: Int = 8, _ body: @MainActor (RollModel, NSWindow, NSView) async throws -> Void) async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            for index in AutoDecisionStateTests.names.count..<frameCount {
                let raw = fixture.roll.appendingPathComponent("Extra-\(index).ARW")
                try writeSequenceHeader(raw, captured: AutoDecisionStateTests.captured(index), tail: Data(UUID().uuidString.utf8))
            }
            try AutoDecisionStateTests.writeToyStock("alternate", in: fixture.stocks)
            let model = fixture.model()
            await model.open(fixture.roll)
            let wasShown = model.isAdjustmentsShown
            model.isAdjustmentsShown = false
            defer { model.isAdjustmentsShown = wasShown }
            let (window, host) = ContextMenuTests.window(ContentView().environment(model), size: CGSize(width: 1280, height: 860))
            defer { window.close() }
            try await body(model, window, host)
        }
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        // Let the dock transition finish while other windows can still handle their events.
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
    }

    private func press(_ key: KeyEquivalent, code: UInt16, in window: NSWindow) throws {
        let characters = String(key.character)
        let flags: NSEvent.ModifierFlags = (key == .leftArrow || key == .rightArrow) ? [.numericPad, .function] : []
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        if key == .escape {
            // The dock intercepts Escape in a window-scoped application event monitor, so the key goes through the application,
            // which hands what its monitors pass on to its key window and not to the window the event names. Suites running beside
            // this one make their own windows key, so this one is made key here, in the same turn as the press: as a hand's
            // press, it goes to the window in front of the hand.
            window.makeKey()
            NSApp.sendEvent(event)
        } else {
            window.sendEvent(event)
        }
    }

    @Test func developGridNavigatesWithTheStockShelfLeftOpen() async throws {
        try await withWorkspace { model, window, host in
            let frames = try #require(model.roll?.frames)
            model.select(frames[1])
            model.toggleStockPanel()
            try await settle(host)
            try #require(model.stockNames.count == 2)
            model.selectStock(1)
            try press(.leftArrow, code: 123, in: window)
            #expect(model.stockIndex == 0)
            #expect(model.selection == frames[1].id)
            model.showDevelopPage()
            try await settle(host)
            let stock = model.stockIndex
            try press(.rightArrow, code: 124, in: window)
            #expect(model.selection == frames[2].id)
            #expect(model.stockIndex == stock)
            try press(.leftArrow, code: 123, in: window)
            #expect(model.selection == frames[1].id)
            #expect(model.stockIndex == stock)
            #expect(model.isStockPanelShown)
        }
    }

    @Test(arguments: [false, true])
    func dismissingShelfRestoresNavigation(inFrame: Bool) async throws {
        try await withWorkspace { model, window, host in
            let frames = try #require(model.roll?.frames)
            model.select(frames[1])
            if inFrame { model.showFrame() }
            try await settle(host)
            model.toggleStockPanel()
            try await settle(host)
            try press(.escape, code: 53, in: window)
            try await settle(host)
            #expect(!model.isStockPanelShown)
            #expect(model.isFrameOpen == inFrame)
            try press(.rightArrow, code: 124, in: window)
            #expect(model.selection == frames[2].id)
            if inFrame {
                try press(.escape, code: 53, in: window)
                #expect(!model.isFrameOpen)
            } else {
                try press(.return, code: 36, in: window)
                #expect(model.isFrameOpen)
            }
        }
    }

    private func horizontalScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, let document = scroll.documentView,
           scroll.documentVisibleRect.width > 0, document.bounds.width > scroll.documentVisibleRect.width {
            return scroll
        }
        return view.subviews.lazy.compactMap { horizontalScrollView(in: $0) }.first
    }

    @Test func filmstripShowsTheSelectedFrameOnOpenAndAfterDismissingTheShelf() async throws {
        try await withWorkspace(frameCount: 40) { model, window, host in
            let frames = try #require(model.roll?.frames)
            let selected = 20
            model.select(frames[selected])
            model.showFrame()

            @MainActor func checkVisible() async throws {
                try await settle(host)
                let scroll = try #require(horizontalScrollView(in: host))
                let visible = scroll.documentVisibleRect
                let leading = CGFloat(selected) * FilmstripWindow.pitch
                let trailing = leading + FilmstripWindow.thumbnail + 2 * FilmstripWindow.inset
                #expect(visible.minX <= leading && trailing <= visible.maxX)
            }

            try await checkVisible()
            model.toggleStockPanel()
            try await settle(host)
            model.toggleStockPanel()
            try await checkVisible()
            window.setContentSize(CGSize(width: 800, height: 640))
            try await checkVisible()
        }
    }
}
