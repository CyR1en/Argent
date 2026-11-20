import AppKit

/// How a click on a cell selects, by the keys held with it.
enum SelectionClick: Equatable, Sendable {
    /// A plain click: that item alone.
    case alone
    /// With Command: the item joins those selected, or leaves them.
    case toggle
    /// With Shift: every item shown from where the range starts to that item.
    case range

    /// What the keys held with `flags` ask of a click. Command outranks Shift, as it does in Finder.
    init(_ flags: NSEvent.ModifierFlags) {
        self = flags.contains(.command) ? .toggle : flags.contains(.shift) ? .range : .alone
    }
}

/// Several items selected round a lead, in a list shown in some order: the frames of the contact sheet
/// (`RollModel.picked`) and of an import's review (`ImportReview`), which select by the same rules
/// (docs/M2-shell.md, section 25).
///
/// One item is the lead, the one the arrows move from. The items selected hold it. A plain click or an arrow leaves the
/// item reached alone; a Command-click adds an item or takes it away, one always staying; a Shift-click or a Shift-arrow
/// selects every item shown from the pivot, the item last selected without Shift, to the item reached; Select All takes
/// every item shown. What is shown is given at each change, since a filter may have changed it.
struct MultiSelection<ID: Hashable & Sendable>: Equatable, Sendable {
    private(set) var lead: ID?
    /// The items selected, the lead among them; empty with no lead.
    private(set) var items: Set<ID> = []
    /// Where a range starts.
    private(set) var pivot: ID?

    var isSeveral: Bool { items.count > 1 }

    /// `id` alone, or nothing.
    mutating func selectAlone(_ id: ID?) {
        lead = id
        items = id.map { [$0] } ?? []
        pivot = id
    }

    /// A Command-click on `id`: it joins the items selected and leads them, or leaves them, the nearest one shown then
    /// leading if it led. The last item selected stays.
    mutating func toggle(_ id: ID, in shown: [ID]) {
        guard items.contains(id) else {
            items.insert(id)
            lead = id
            pivot = id
            return
        }
        guard items.count > 1 else { return }
        items.remove(id)
        if lead == id { lead = nearest(to: id, in: shown) ?? items.first }
        pivot = lead
    }

    /// A Shift-click on `id`, or a Shift-arrow that reached it: every item shown from the pivot to it, whichever comes
    /// first; `id` alone when the pivot is no longer shown.
    mutating func selectRange(to id: ID, in shown: [ID]) {
        let start = pivot ?? lead ?? id
        if let from = shown.firstIndex(of: start), let to = shown.firstIndex(of: id) {
            items = Set(shown[min(from, to)...max(from, to)])
        } else {
            items = [id]
        }
        lead = id
        pivot = start
    }

    /// Every item shown. The lead stays where it is, or is the first shown.
    mutating func selectAll(in shown: [ID]) {
        guard let first = shown.first else { return }
        let lead = lead.flatMap { shown.contains($0) ? $0 : nil } ?? first
        self.lead = lead
        items = Set(shown)
        pivot = lead
    }

    /// The lead alone again.
    mutating func collapse() {
        selectAlone(lead)
    }

    /// `id` leads, the items selected staying as they are; nothing for an item that is not selected.
    mutating func lead(with id: ID) {
        guard items.contains(id) else { return }
        lead = id
    }

    /// The items selected that are no longer shown leave the selection; the lead stays.
    mutating func keep(in shown: [ID]) {
        guard items.count > 1 else { return }
        items.formIntersection(shown)
        if let lead { items.insert(lead) }
        if let pivot, !items.contains(pivot) { self.pivot = lead }
    }

    /// The items selected, in the order shown.
    func ordered(in shown: [ID]) -> [ID] {
        shown.filter(items.contains)
    }

    /// The items a menu opened on `id` acts on: the several selected when it is one of them, as in Finder, else it alone.
    func acted(on id: ID, in shown: [ID]) -> [ID] {
        items.count > 1 && items.contains(id) ? ordered(in: shown) : [id]
    }

    /// The item selected nearest `id` in the order shown, the later of two as near.
    private func nearest(to id: ID, in shown: [ID]) -> ID? {
        guard let place = shown.firstIndex(of: id) else { return shown.first(where: items.contains) }
        let places = shown.indices.filter { items.contains(shown[$0]) }
        return places.min { abs($0 - place) == abs($1 - place) ? $0 > $1 : abs($0 - place) < abs($1 - place) }.map { shown[$0] }
    }
}
