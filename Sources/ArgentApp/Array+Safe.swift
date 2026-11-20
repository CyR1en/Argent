extension Array {
    /// The element at `index`, or `nil` where the array has none: a mask's component by a number a selection or a key carries,
    /// which an Undo may have taken away since.
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
