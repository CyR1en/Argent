import AppKit
import Testing
@testable import ArgentApp

/// The rules several items are selected by (`MultiSelection`), which the contact sheet and the import's review share.
@Suite struct MultiSelectionTests {
    private let shown = Array(0..<8)

    @Test func aPlainSelectionIsOneItemAndNothingIsNone() {
        var selection = MultiSelection<Int>()
        #expect(selection.lead == nil && selection.items.isEmpty && !selection.isSeveral)
        selection.selectAlone(3)
        #expect(selection.lead == 3 && selection.items == [3] && selection.pivot == 3)
        selection.selectAlone(nil)
        #expect(selection.lead == nil && selection.items.isEmpty && selection.pivot == nil)
    }

    @Test func commandAddsAnItemOrTakesItAwayAndOneAlwaysStays() {
        var selection = MultiSelection<Int>()
        // With nothing selected it selects.
        selection.toggle(2, in: shown)
        #expect(selection.lead == 2 && selection.items == [2])
        selection.toggle(6, in: shown)
        selection.toggle(4, in: shown)
        #expect(selection.lead == 4 && selection.items == [2, 4, 6] && selection.pivot == 4)
        // One that does not lead leaves, and the lead stays.
        selection.toggle(2, in: shown)
        #expect(selection.lead == 4 && selection.items == [4, 6])
        // The lead leaves: the nearest one selected leads, the later of two as near.
        selection.toggle(2, in: shown)
        selection.lead(with: 4)
        selection.toggle(4, in: shown)
        #expect(selection.lead == 6 && selection.items == [2, 6], "2 and 6 are as near to 4")
        selection.toggle(6, in: shown)
        #expect(selection.lead == 2 && selection.items == [2])
        selection.toggle(2, in: shown)
        #expect(selection.lead == 2 && selection.items == [2], "the last one stays")
    }

    @Test func shiftSelectsFromThePivotAndTurnsRoundIt() {
        var selection = MultiSelection<Int>()
        selection.selectAlone(3)
        selection.selectRange(to: 5, in: shown)
        #expect(selection.lead == 5 && selection.items == [3, 4, 5] && selection.pivot == 3)
        selection.selectRange(to: 1, in: shown)
        #expect(selection.lead == 1 && selection.items == [1, 2, 3] && selection.pivot == 3)
        // Over the items shown only, in their order.
        selection.selectRange(to: 7, in: [1, 3, 7])
        #expect(selection.items == [3, 7])
        // A pivot no longer shown: the item reached alone.
        selection.selectRange(to: 1, in: [0, 1, 2])
        #expect(selection.lead == 1 && selection.items == [1])
        // With nothing selected a range is its end.
        var empty = MultiSelection<Int>()
        empty.selectRange(to: 4, in: shown)
        #expect(empty.lead == 4 && empty.items == [4] && empty.pivot == 4)
    }

    @Test func selectAllCollapseAndWhatIsNoLongerShown() {
        var selection = MultiSelection<Int>()
        selection.selectAll(in: [])
        #expect(selection.items.isEmpty)
        selection.selectAll(in: shown)
        #expect(selection.lead == 0 && selection.items == Set(shown))
        selection.selectAlone(5)
        selection.selectAll(in: shown)
        #expect(selection.lead == 5 && selection.items.count == 8 && selection.pivot == 5)
        // The lead becomes another of them, and they stay.
        selection.lead(with: 2)
        selection.lead(with: 40)
        #expect(selection.lead == 2 && selection.items.count == 8)
        // What is no longer shown leaves; the lead stays even so.
        selection.keep(in: [1, 4, 6])
        #expect(selection.lead == 2 && selection.items == [1, 2, 4, 6] && selection.pivot == 2)
        #expect(selection.ordered(in: [6, 4, 2, 1, 0]) == [6, 4, 2, 1])
        // A menu on one of several is theirs; on another item, that item's.
        #expect(selection.acted(on: 4, in: shown) == [1, 2, 4, 6] && selection.acted(on: 7, in: shown) == [7])
        selection.collapse()
        #expect(selection.lead == 2 && selection.items == [2])
        #expect(selection.acted(on: 2, in: shown) == [2])
    }

    @Test func theKeysHeldSayHowAClickSelects() {
        #expect(SelectionClick([]) == .alone && SelectionClick(.option) == .alone)
        #expect(SelectionClick(.shift) == .range && SelectionClick(.command) == .toggle)
        #expect(SelectionClick([.command, .shift]) == .toggle, "Command outranks Shift")
    }
}
