import AppKit
import ArgentRoll
import CoreGraphics
import SwiftUI
import Testing
@testable import ArgentApp

/// The sheet's glide to another thumbnail size (`SheetGridController.sizeGlide`) when the next size comes before the
/// last has landed, as a fast drag of the size slider sends them: each cell's contents end the size of their cell,
/// so on their place (`HostedCellView`). The import review's cells keep theirs on them the same way.
@MainActor @Suite(.serialized) struct SizeGlideTests {
    /// Whether a glide can be seen here at all. A hosting view's glide is stepped at the display's refreshes, so with the
    /// display asleep or the screen locked not one lands; with Reduce Motion nothing glides. Read before the test runs.
    nonisolated static var glidesShow: Bool {
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return CGDisplayIsAsleep(CGMainDisplayID()) == 0 && !locked && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// A roll of more frames than the window shows at any size, so cells come and go as the size changes, its sheet
    /// in a window, and frame `selected` selected, which the sheet keeps in view.
    private static func withSheet(selecting selected: Int,
                                  _ body: (RollModel, NSWindow, NSView, NSCollectionView) throws -> Void) async throws {
        try await FlagStateTests.withRoll { fixture in
            for index in 8..<72 {
                try writeSequenceHeader(fixture.roll.appendingPathComponent(String(format: "DSC1%03d.ARW", index)),
                                        captured: String(format: "2026:10:21 11:%02d:%02d", index / 60, index % 60),
                                        tail: Data(UUID().uuidString.utf8))
            }
            let model = FlagStateTests.model(fixture), gate = MeasurementGate()
            let frames = try await FlagStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            #expect(frames.count == 72)
            model.selection = frames[selected].id
            let (window, host, collection) = try FrameMenuTests.sheet(model, size: NSSize(width: 1100, height: 760))
            defer { window.close() }
            ContextMenuTests.settle(host)
            #expect(misfits(collection) == [])
            try body(model, window, host, collection)
        }
    }

    /// Turns the run loop for `seconds`: the sheet takes a size in, and a glide moves on.
    private static func run(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The hosting view a cell keeps at its bounds, and the cell's view; `nil` for a cell that has not both.
    private static func contents(of path: IndexPath, in collection: NSCollectionView) -> (cell: NSView, hosted: NSView)? {
        guard let cell = collection.item(at: path)?.view as? HostedCellView, let hosted = cell.hosted else { return nil }
        return (cell, hosted)
    }

    /// What is wrong with the cells in view: each whose hosting view is not at its cell's bounds, with the two, each
    /// with no item or no hosting view, and no cells in view at all. Empty only when some cells were looked at.
    private static func misfits(_ collection: NSCollectionView) -> [String] {
        let paths = collection.indexPathsForVisibleItems().sorted()
        guard !paths.isEmpty else { return ["no cell in view"] }
        return paths.compactMap { path in
            guard let found = contents(of: path, in: collection) else { return "cell \(path.item) has no item with a hosting view" }
            return found.hosted.frame == found.cell.bounds ? nil
                : "cell \(path.item) is \(found.cell.bounds.size), its contents \(found.hosted.frame)"
        }
    }

    /// Whether some cell in view has its contents at another frame than its bounds, as a glide on its way leaves them.
    private static func isGliding(_ collection: NSCollectionView) -> Bool {
        collection.indexPathsForVisibleItems().contains { path in
            contents(of: path, in: collection).map { $0.hosted.frame != $0.cell.bounds } ?? false
        }
    }

    /// Waits for the glide under way to land, as long as a busy machine's late turns take.
    private static func land(_ collection: NSCollectionView) {
        run(SheetGridController.sizeGlide + 0.2)
        for _ in 0..<60 where !misfits(collection).isEmpty { run(0.05) }
    }

    /// Sends the sizes `steps`, each `gap` seconds after the last, far sooner than one is glided to, and waits for the
    /// last glide to land. Returns how many went out while a glide was on its way: how many came before the last had
    /// landed, as the test means them to, rather than after it, as a late turn or a coalesced step leaves them.
    @discardableResult
    private static func send(_ steps: [Int], every gap: TimeInterval = 0.03, to model: RollModel, in collection: NSCollectionView) -> Int {
        var overlapping = 0
        for step in steps {
            if isGliding(collection) { overlapping += 1 }
            model.changeSize(by: step)
            run(gap)
        }
        land(collection)
        return overlapping
    }

    @Test(.enabled(if: glidesShow, "a glide is stepped at the display's refreshes: none with it asleep or locked, or with Reduce Motion"))
    func sizesSentFasterThanTheyAreGlidedToLeaveEachCellsContentsOnTheirCell() async throws {
        // A selection in the middle of the roll, which each size brings back to the middle of the view.
        try await Self.withSheet(selecting: 36) { model, _, _, collection in
            let start = model.sizeStep
            // One size, left to land: the sheet takes it in a turn or a few later, and its cells are another width.
            let before = FrameMenuTests.frame(ofCell: 0, in: collection).width
            model.changeSize(by: 1)
            for _ in 0..<100 where FrameMenuTests.frame(ofCell: 0, in: collection).width == before { Self.run(0.01) }
            #expect(FrameMenuTests.frame(ofCell: 0, in: collection).width != before)
            Self.land(collection)
            try #require(Self.misfits(collection) == [], "a single glide left cells' contents off their cell")

            // To the largest and down to the smallest, as a drag across the slider sends them, every 30 ms. Each run
            // has some size sent while the last was on its way, or it would not be what it is here to show.
            #expect(Self.send([1, -1, -1, -1], to: model, in: collection) >= 1)
            #expect(model.sizeStep == 0)
            #expect(Self.misfits(collection) == [])

            // Back up, and to and fro.
            #expect(Self.send([1, 1, 1], to: model, in: collection) >= 1)
            #expect(model.sizeStep == Metrics.thumbnailWidths.count - 1)
            #expect(Self.misfits(collection) == [])
            #expect(Self.send([-1, -1, 1, -1, -1, 1, 1, -1], to: model, in: collection) >= 1)
            #expect(Self.misfits(collection) == [])

            // A size sent in the middle of a glide, not at its start: once the glide is seen on its way and a third of
            // it has gone. Again if a late turn let it land first.
            var midway = 0
            for _ in 0..<3 where midway == 0 {
                model.changeSize(by: 1)
                let sent = Date()
                for _ in 0..<100 where !Self.isGliding(collection) || Date().timeIntervalSince(sent) < SheetGridController.sizeGlide / 3 {
                    Self.run(0.01)
                }
                midway = Self.send([-1], to: model, in: collection)
            }
            #expect(midway == 1)
            #expect(model.sizeStep == start)
            #expect(Self.misfits(collection) == [])
        }
    }

    /// What the glide's run comes down to, with no glide and so no clock or display in it: a cell's contents caught at
    /// another size than their cell, as a glide's steps leave them part of the way, are their cell's size once it is
    /// sized again, here by a narrower window.
    @Test func aCellResizedPutsItsContentsOnItselfWhateverSizeTheyWereCaughtAt() async throws {
        // The first frame selected, so the sheet stays at its top and the same cells in view.
        try await Self.withSheet(selecting: 0) { _, window, host, collection in
            let paths = collection.indexPathsForVisibleItems()
            #expect(!paths.isEmpty)
            for path in paths {
                let contents = try #require(Self.contents(of: path, in: collection)).hosted
                contents.setFrameSize(NSSize(width: contents.frame.width + 31, height: contents.frame.height + 20.5))
            }
            #expect(Self.misfits(collection).count == paths.count)

            let before = FrameMenuTests.frame(ofCell: 0, in: collection).size
            window.setContentSize(NSSize(width: 900, height: 760))
            for _ in 0..<40 where FrameMenuTests.frame(ofCell: 0, in: collection).size == before { ContextMenuTests.settle(host, turns: 1) }
            ContextMenuTests.settle(host)
            // Each cell is another size, and cells that were in view still are.
            #expect(FrameMenuTests.frame(ofCell: 0, in: collection).size != before)
            let after = collection.indexPathsForVisibleItems()
            #expect(!paths.intersection(after).isEmpty)
            for path in after {
                #expect(collection.item(at: path)?.view.frame == FrameMenuTests.frame(ofCell: path.item, in: collection))
            }
            #expect(Self.misfits(collection) == [])
        }
    }

    /// An import review's cell, out of any window: its contents are its size once shown, and once it is sized again
    /// whatever size they were caught at, and once it is recycled.
    @Test func anImportCellsContentsFollowItsSize() throws {
        let item = ImportItem()
        item.view.setFrameSize(NSSize(width: 160, height: 200))
        let inputs = ImportCellInputs(frame: ImportFrame(id: "DCIM/100MSDCF/DSC00001.ARW", frame: nil), badge: nil, isKept: true,
                                      isChanged: false, leftPlace: "on the card", width: 160, isSelected: false)
        item.show(inputs, loader: ThumbnailLoader(), toggle: {}, press: {}, select: {})
        let cell = try #require(item.view as? HostedCellView)
        let contents = try #require(cell.hosted)
        #expect(contents.superview === cell)
        #expect(contents.frame == cell.bounds)

        contents.setFrameSize(NSSize(width: contents.frame.width + 31, height: contents.frame.height + 20.5))
        cell.setFrameSize(NSSize(width: 120, height: 150))
        #expect(contents.frame == NSRect(x: 0, y: 0, width: 120, height: 150))

        contents.setFrameSize(NSSize(width: 64, height: 48))
        item.prepareForReuse()
        #expect(contents.frame == cell.bounds)
    }

    /// Only the hosting view is kept at the cell's bounds: another view in the cell resizes by its own autoresizing mask.
    @Test func aCellsOtherViewsResizeByTheirOwnMask() {
        let cell = HostedCellView(frame: NSRect(x: 0, y: 0, width: 160, height: 200))
        let hosted = NSView(), badge = NSView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        badge.autoresizingMask = [.width]
        cell.host(hosted)
        cell.addSubview(badge)
        hosted.setFrameSize(NSSize(width: 60, height: 60))
        cell.setFrameSize(NSSize(width: 200, height: 100))
        #expect(hosted.frame == NSRect(x: 0, y: 0, width: 200, height: 100))
        #expect(badge.frame == NSRect(x: 10, y: 10, width: 60, height: 20))
    }
}
