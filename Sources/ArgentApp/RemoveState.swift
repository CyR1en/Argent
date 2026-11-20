import ArgentCore
import ArgentRoll
import Foundation
import Observation

// What the Remove tab shows and what it can ask for (docs/remove-plan.md, section 4.8): the seam between the model (package E, which
// fills in `RollModel+Remove.swift`) and the interface (package F, which draws from these and calls those). Neither package edits
// this file; a change here is the coordinator's.

/// Coverage to draw over the photograph: a selection, or a removal's outline. 0 outside and 255 inside, row 0 the top, at any size,
/// stretched over `frame`, which is in fractions of the corrected picture from its top left.
struct RemoveCoverage: Equatable, Sendable {
    var width: Int
    var height: Int
    var values: [UInt8]
    var frame = CGRect(x: 0, y: 0, width: 1, height: 1)
}

/// The selection being made on the open frame, before Return.
struct RemoveSelectionState: Equatable, Sendable {
    /// What is selected so far; `nil` when nothing is.
    var coverage: RemoveCoverage?
    /// The stroke under the pointer, in fractions of the picture from its top left, shown until it is released and snaps.
    var stroke: [CGPoint] = []
    /// That stroke takes away from the selection (Option held at the press).
    var strokeSubtracts = false
    /// The segmenter is finding the object under the last stroke.
    var isSnapping = false
    /// Snap to Object, the tab's switch, and whether this Mac can (`ObjectSelector.availability`). Off, or unavailable, a stroke is
    /// the selection as painted.
    var snapsToObject = true
    var snap: ObjectSelector.Availability = .unavailable("Snap to Object is not built yet")

    /// Whether Return and the Remove button have something to remove.
    var canRemove: Bool { coverage != nil && !isSnapping }
}

/// One row of the Remove tab: a removal in the frame's edit, or a run that has no patch yet.
struct RemovalRowState: Identifiable, Equatable, Sendable {
    /// The removal's id; a run's own while it has no patch.
    let id: UUID
    /// Its place in the frame's list, from 1.
    var number: Int
    var isOn = true
    var includesEffects = true
    /// A run with no patch yet: the row has its caption and Cancel, and nothing else. A removal being made again (Try Again,
    /// Better) is not pending: it keeps its controls and its old pixels, and its caption says it is running.
    var isPending = false
    var caption: Caption?

    var title: String { "Removal \(number)" }

    /// The one line under a row's name.
    enum Caption: Equatable, Sendable {
        /// The model's one-time preparation, and how far it is where that is known.
        case preparing(Double?)
        case loading
        case waitingForDevelop
        /// Behind another removal.
        case queued
        case removing(step: Int, of: Int)
        /// The run ended without a picture, and why. The row offers Try Again.
        case failed(String)
        case missing
        case redrewFace
        case olderDecode
        case soft
        /// Filled from its surroundings, with no model (`RemovalPipeline.healed`).
        case healed

        var text: String {
            switch self {
            case .preparing(let fraction?): "Preparing Remove… \(Int((fraction * 100).rounded())) %"
            case .preparing(nil): "Preparing Remove…"
            case .loading: "Loading the model…"
            case .waitingForDevelop: "Waiting for the develop…"
            case .queued: "Waiting for another removal…"
            case .removing(let step, let of): "Removing… \(step) of \(of)"
            case .failed: "Could not remove it"
            case .missing: "Patch missing"
            case .redrewFace: "Redrew part of a face"
            case .olderDecode: "Made before the decoder changed"
            case .soft: "Soft at full size"
            case .healed: "Filled from its surroundings"
            }
        }

        /// The longer sentence, for the help tag.
        var help: String? {
            switch self {
            case .failed(let why): why
            case .missing: "This removal’s pixels are not in the library or beside the RAW. Delete it, or put its .argentpatches pack back."
            case .redrewFace: "This removal drew new pixels inside a face. Look at it at full size before you develop."
            case .olderDecode: "The frame is decoded differently now than when this was made. Try Again makes it again."
            case .soft: "The model works at a small size, so a large removal is soft at 100 %."
            case .healed: "What is round this is smooth, so it was filled from that and no model ran. Try Again asks the model."
            default: nil
            }
        }

        /// A wait: a spinner, or `progress` as a bar.
        var isBusy: Bool {
            switch self {
            case .preparing, .loading, .waitingForDevelop, .queued, .removing: true
            default: false
            }
        }

        /// 0 to 1 where the wait can say how far it is.
        var progress: Double? {
            switch self {
            case .preparing(let fraction): fraction
            case .removing(let step, let of): of > 0 ? Double(step) / Double(of) : nil
            default: nil
            }
        }

        /// The caption's symbol, where it has one.
        var symbol: String? { self == .redrewFace ? "face.dashed" : nil }

        /// A click on it glides the frame to the face at 100 % (`RollModel.showRemovalFace`).
        var opensFace: Bool { self == .redrewFace }
    }

    /// The first caption that applies, in section 4.8's order: the run's state, then what is wrong or notable about the patch,
    /// and last that no model drew it (section 18).
    static func caption(run: Caption?, isMissing: Bool, redrewFace: Bool, olderDecode: Bool, isSoft: Bool, isHealed: Bool = false) -> Caption? {
        if let run { return run }
        if isMissing { return .missing }
        if redrewFace { return .redrewFace }
        if olderDecode { return .olderDecode }
        if isSoft { return .soft }
        return isHealed ? .healed : nil
    }

    /// The caption of a run that waits on the engine or runs, from the queue's own words (`RemovalQueue.Progress`).
    static func caption(for progress: RemovalQueue.Progress) -> Caption {
        switch progress {
        case .waiting(_, forDevelop: true): .waitingForDevelop
        case .waiting(.preparing(let fraction), forDevelop: false): .preparing(fraction)
        case .waiting(_, forDevelop: false): .loading
        case .queued: .queued
        case .step(let step, of: let of): .removing(step: step, of: of)
        }
    }

    /// What the row's controls may do. A pending row can only be cancelled; a patch that is missing can only be deleted.
    var canCancel: Bool { caption?.isBusy == true }
    var canToggle: Bool { !isPending && caption != .missing }
    var canRemake: Bool { !isPending && caption?.isBusy != true }
    var canDelete: Bool { !isPending }
}

/// The Remove tab's state that is not in the frame's edit: the selection, the runs in flight and what the pointer is over. The
/// model writes it and the interface reads it; what the model needs beyond this (its queue, its store, its tasks) it keeps itself.
@MainActor @Observable
final class RemoveSession {
    /// The frame the selection is being made on.
    var frame: URL?
    var selection = RemoveSelectionState()
    /// Runs with no patch yet, by frame, oldest first; and the caption of a removal being made again, by its id.
    var pending: [URL: [RemovalRowState]] = [:]
    var remaking: [UUID: RemovalRowState.Caption] = [:]
    /// The engine as the tab last saw it.
    var engine: RemovalEngineState = .absent("Remove is not built yet")
    /// The brush's diameter, in hundredths of the picture's long side, as the masks' brush counts it.
    var brushSize: Double = 4
    /// The row the pointer is over, whose outline shows.
    var hovered: UUID?

    /// Nothing is written that is already so: the menu bar's state reads `frame`, and a write of the same value would have it made
    /// again on every arrow press between frames while the Remove tab shows.
    func reset() {
        if frame != nil { frame = nil }
        let cleared = RemoveSelectionState(snapsToObject: selection.snapsToObject, snap: selection.snap)
        if selection != cleared { selection = cleared }
        if hovered != nil { hovered = nil }
    }
}
