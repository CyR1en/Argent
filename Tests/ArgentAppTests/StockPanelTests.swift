import ArgentRoll
import CoreGraphics
import SwiftUI
import Testing
@testable import ArgentApp

/// Scope and menu wording, plus the shelf's layout, paging and selection visibility.
@MainActor @Suite struct StockPanelTests {
    @Test func eachLineSaysWhatItSets() {
        #expect(ControlsScope.roll.title == "Whole roll")
        #expect(ControlsScope.frame.title == "This frame")
        #expect(ControlsScope(frame: nil) == .roll)
        // VoiceOver hears whether a frame's value is its own; the roll's values need no such word.
        #expect(RollControlsView.ownership(.frame, isOwn: true) == ", this frame only")
        #expect(RollControlsView.ownership(.frame, isOwn: false) == ", same as roll")
        #expect(RollControlsView.ownership(.roll, isOwn: true) == "")
    }

    @Test func ratedAtShowsTheSpeedOnItsFaceAndInWordsInItsItems() {
        #expect(RollControlsView.ratedAtFace(.boxSpeed, boxSpeed: 400) == "400")
        #expect(RollControlsView.ratedAtFace(.oneStopUnder, boxSpeed: 400) == "800")
        #expect(RollControlsView.ratedAtFace(.oneStopOver, boxSpeed: 400) == "200")
        // No grouping separator: 1600, not 1,600.
        #expect(RollControlsView.ratedAtFace(.twoStopsUnder, boxSpeed: 400) == "1600")
        #expect(RollControlsView.ratedAtFace(.oneStopUnder, boxSpeed: 0) == "One stop under")
        #expect(RollControlsView.ratedAtItem(.oneStopUnder, boxSpeed: 400) == "800, one stop under")
        #expect(RollControlsView.sameAsRollItem(RollControlsView.ratedAtItem(.boxSpeed, boxSpeed: 400))
                == "Same as roll, 400, box speed")
        #expect(RollControlsView.sameAsRollItem(RollControls.LabBalance.auto.title) == "Same as roll, Auto")
    }

    @Test func theStockInUseIsDescribedInASentence() {
        #expect(StockCharacter.sentence(for: "kodak-portra-400") == "Warm neutral skin, soft highlight roll-off")
        #expect(StockCharacter.line(for: "kodak-portra-400") == "warm neutral skin, soft highlight roll-off")
        #expect(StockCharacter.sentence(for: "unknown-stock") == nil)
        #expect(StockCharacter.sentence(for: nil) == nil)
    }

    @Test func theStockChooserSharesItsNumberKeysWithTheMenu() {
        #expect(StockChooserButton.key(for: 0) == KeyboardShortcut(KeyEquivalent("1"), modifiers: []))
        #expect(StockChooserButton.key(for: 5) == KeyboardShortcut(KeyEquivalent("6"), modifiers: []))
        #expect(StockChooserButton.key(for: 9) == nil)
        #expect(StockChooserButton.help(stockCount: 6)
                == "The film stock for the whole roll: every frame without its own develops through it. Keys 1 to 6.")
        #expect(StockChooserButton.help(stockCount: 12).hasSuffix("Keys 1 to 9."))
        #expect(StockChooserButton.help(stockCount: 0) == "The film stock for the whole roll: every frame without its own develops through it.")
        // In the frame view it is the open frame's.
        #expect(StockChooserButton.help(stockCount: 6, isFrame: true, isOwn: true, roll: "Portra 400")
                == "This frame's own film stock. The roll's is Portra 400. Keys 1 to 6.")
        #expect(StockChooserButton.help(stockCount: 0, isFrame: true)
                == "This frame's film stock, the same as the roll's. Choosing another gives the frame its own.")
    }

    @Test func sixShallowSamplesFitAWideShelfAndBrowseInANarrowOne() {
        let wide = StockShelfLayout(width: 1076, count: 6)
        #expect(!wide.showsPaging)
        #expect(wide.contentWidth <= wide.viewportWidth)
        #expect(wide.viewportWidth - wide.contentWidth < 6)
        #expect(StockShelfLayout.pictureHeight < StockShelfLayout.minimumSampleWidth / 2)
        #expect(StockShelfLayout.sampleHeight < 80)

        let narrow = StockShelfLayout(width: 346, count: 6)
        #expect(narrow.showsPaging)
        #expect(narrow.sampleWidth == StockShelfLayout.minimumSampleWidth)
        #expect(narrow.viewportWidth + 2 * (StockShelfLayout.pagingWidth + StockShelfLayout.pagingGap) == 346)
        #expect(narrow.contentWidth > narrow.viewportWidth)
    }

    @Test func pagingCanReachBothEnds() {
        for width: CGFloat in [240, 346, 600] {
            let layout = StockShelfLayout(width: width, count: 6)
            var offset: CGFloat = 0
            var pages = 0
            while offset < layout.maximumOffset, pages < 6 {
                let next = layout.pageOffset(forward: true, from: offset)
                #expect(next > offset)
                #expect(next <= layout.maximumOffset)
                offset = next
                pages += 1
            }
            #expect(offset == layout.maximumOffset)
            #expect(layout.pageOffset(forward: true, from: offset) == offset)
            while offset > 0, pages < 12 {
                let previous = layout.pageOffset(forward: false, from: offset)
                #expect(previous < offset)
                offset = previous
                pages += 1
            }
            #expect(offset == 0)
            #expect(layout.pageOffset(forward: false, from: offset) == 0)
        }
    }

    @Test func everyKeyboardSelectionStaysVisibleAcrossResizing() {
        for selected in 0..<6 {
            var offset: CGFloat = 0
            // Wider, narrower, then wider again; cover the point where paging buttons appear.
            for width: CGFloat in [1076, 346, 680, 677, 240, 900, 346] {
                let layout = StockShelfLayout(width: width, count: 6)
                offset = layout.offset(revealing: selected, from: offset)
                let leading = CGFloat(selected) * (layout.sampleWidth + StockShelfLayout.gap)
                #expect(offset >= 0 && offset <= layout.maximumOffset)
                #expect(leading >= offset)
                #expect(leading + layout.sampleWidth <= offset + layout.viewportWidth)
                // An already visible selection preserves the user's browsing position.
                #expect(layout.offset(revealing: selected, from: offset) == offset)
            }
        }
        let narrow = StockShelfLayout(width: 346, count: 6)
        #expect(narrow.offset(revealing: 0, from: narrow.maximumOffset) == 0)
        #expect(narrow.offset(revealing: 5, from: 0) == narrow.maximumOffset)
    }

    @Test func emptyAndTinyShelvesHaveFiniteScrollTargets() {
        let empty = StockShelfLayout(width: 346, count: 0)
        #expect(!empty.showsPaging && empty.contentWidth == 0 && empty.maximumOffset == 0)
        #expect(empty.offset(revealing: 0, from: 100) == 0)
        #expect(empty.pageOffset(forward: true, from: 0) == 0)
        for width: CGFloat in [0, 40, 90] {
            let layout = StockShelfLayout(width: width, count: 6)
            #expect(layout.viewportWidth >= 0 && layout.sampleWidth >= StockShelfLayout.minimumSampleWidth)
            for index in 0..<6 {
                let offset = layout.offset(revealing: index, from: 0)
                #expect(offset.isFinite && offset >= 0 && offset <= layout.maximumOffset)
            }
        }
    }
}
