import ArgentCore
import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// The Remove tab's words and rules that the model and the interface both read (docs/remove-plan.md, section 4.8).
@MainActor @Suite struct RemoveStateTests {
    @Test func aRowHasOneCaptionAndTheRunComesFirst() {
        typealias Row = RemovalRowState
        #expect(Row.caption(run: nil, isMissing: false, redrewFace: false, olderDecode: false, isSoft: false) == nil)
        #expect(Row.caption(run: .removing(step: 3, of: 8), isMissing: true, redrewFace: true, olderDecode: true, isSoft: true)
                == .removing(step: 3, of: 8))
        #expect(Row.caption(run: nil, isMissing: true, redrewFace: true, olderDecode: true, isSoft: true) == .missing)
        #expect(Row.caption(run: nil, isMissing: false, redrewFace: true, olderDecode: true, isSoft: true) == .redrewFace)
        #expect(Row.caption(run: nil, isMissing: false, redrewFace: false, olderDecode: true, isSoft: true) == .olderDecode)
        #expect(Row.caption(run: nil, isMissing: false, redrewFace: false, olderDecode: false, isSoft: true) == .soft)
        // That no model drew it is said last, where nothing else is.
        #expect(Row.caption(run: nil, isMissing: false, redrewFace: false, olderDecode: false, isSoft: true, isHealed: true) == .soft)
        #expect(Row.caption(run: nil, isMissing: false, redrewFace: false, olderDecode: false, isSoft: false, isHealed: true) == .healed)
        #expect(Row.caption(run: .loading, isMissing: false, redrewFace: false, olderDecode: false, isSoft: false, isHealed: true) == .loading)
    }

    @Test func theCaptionsSayWhatThePlanSays() {
        typealias Caption = RemovalRowState.Caption
        #expect(Caption.removing(step: 3, of: 8).text == "Removing… 3 of 8")
        #expect(Caption.healed.text == "Filled from its surroundings" && Caption.healed.help?.contains("no model ran") == true)
        #expect(!Caption.healed.isBusy && Caption.healed.progress == nil && Caption.healed.symbol == nil && !Caption.healed.opensFace)
        #expect(Caption.preparing(0.4).text == "Preparing Remove… 40 %" && Caption.preparing(nil).text == "Preparing Remove…")
        #expect(Caption.loading.text == "Loading the model…" && Caption.waitingForDevelop.text == "Waiting for the develop…")
        #expect(Caption.missing.text == "Patch missing" && Caption.soft.text == "Soft at full size")
        #expect(Caption.olderDecode.text == "Made before the decoder changed")
        #expect(Caption.redrewFace.text == "Redrew part of a face" && Caption.redrewFace.symbol == "face.dashed" && Caption.redrewFace.opensFace)
        #expect(Caption.redrewFace.help == "This removal drew new pixels inside a face. Look at it at full size before you develop.")
        #expect(Caption.failed("The model stopped answering").help == "The model stopped answering")
        #expect(Caption.removing(step: 2, of: 8).progress == 0.25 && Caption.removing(step: 2, of: 8).isBusy)
        #expect(!Caption.soft.isBusy && Caption.soft.progress == nil && Caption.soft.symbol == nil && !Caption.soft.opensFace)
    }

    @Test func theQueuesWordsBecomeTheRowsCaption() {
        typealias Row = RemovalRowState
        #expect(Row.caption(for: .step(5, of: 8)) == .removing(step: 5, of: 8))
        #expect(Row.caption(for: .queued) == .queued)
        #expect(Row.caption(for: .waiting(.loading, forDevelop: false)) == .loading)
        #expect(Row.caption(for: .waiting(.idle, forDevelop: false)) == .loading)
        #expect(Row.caption(for: .waiting(.preparing(0.5), forDevelop: false)) == .preparing(0.5))
        #expect(Row.caption(for: .waiting(.preparing(0.5), forDevelop: true)) == .waitingForDevelop)
    }

    @Test func aRowsControlsFollowItsState() {
        let id = UUID()
        let made = RemovalRowState(id: id, number: 2)
        #expect(made.title == "Removal 2" && made.canToggle && made.canRemake && made.canDelete && !made.canCancel)
        let pending = RemovalRowState(id: id, number: 3, isPending: true, caption: .removing(step: 1, of: 8))
        #expect(pending.canCancel && !pending.canToggle && !pending.canRemake && !pending.canDelete)
        let again = RemovalRowState(id: id, number: 1, caption: .loading)
        #expect(again.canCancel && again.canToggle && !again.canRemake && again.canDelete, "made again: its old pixels and its controls stay")
        let missing = RemovalRowState(id: id, number: 1, caption: .missing)
        #expect(!missing.canToggle && missing.canDelete && missing.canRemake)
    }

    @Test func theSelectionCanBeRemovedOnceItIsThereAndHasSnapped() {
        var selection = RemoveSelectionState()
        #expect(!selection.canRemove)
        selection.coverage = RemoveCoverage(width: 2, height: 2, values: [255, 0, 0, 0])
        #expect(selection.canRemove)
        selection.isSnapping = true
        #expect(!selection.canRemove)
    }

    @Test func theSessionKeepsTheSwitchWhenTheSelectionIsDroppedAndTheModelIsEmptyUntilItIsBuilt() {
        let session = RemoveSession()
        session.selection.snapsToObject = false
        session.selection.coverage = RemoveCoverage(width: 1, height: 1, values: [255])
        session.frame = URL(fileURLWithPath: "/rolls/DSC1.ARW")
        session.hovered = UUID()
        session.reset()
        #expect(session.frame == nil && session.selection.coverage == nil && session.hovered == nil && !session.selection.snapsToObject)
    }
}
