import Foundation
import SwiftUI
import Testing
@testable import ArgentApp

/// The contact sheet's filter row: each segment's count follows the roll's flags, VoiceOver hears the
/// filter and its count, the help tags name View > Show's keys, and a flag followed by the Flagged
/// filter carries through to the title's line and the frames Develop develops. The size control
/// names each of the thumbnails' sizes.
@MainActor @Suite(.serialized) struct ContactSheetFilterTests {
    typealias Flags = FlagStateTests

    @Test func segmentTitlesAndLabelsCarryTheirCounts() {
        #expect(FlagFilter.allCases.map { SheetFilterBar.title($0, total: 24, flagged: 3) }
                == ["All 24", "Flagged 3", "Unflagged 21"])
        #expect(FlagFilter.allCases.map { SheetFilterBar.accessibilityLabel($0, total: 24, flagged: 3) }
                == ["All, 24 frames", "Flagged, 3 frames", "Unflagged, 21 frames"])
        // One frame is a frame; none is still frames.
        #expect(SheetFilterBar.accessibilityLabel(.flagged, total: 2, flagged: 1) == "Flagged, 1 frame")
        #expect(SheetFilterBar.accessibilityLabel(.flagged, total: 2, flagged: 0) == "Flagged, 0 frames")
        // Every frame flagged leaves none unflagged, never a negative count.
        #expect(SheetFilterBar.count(.unflagged, total: 5, flagged: 5) == 0)
        #expect(SheetFilterBar.count(.unflagged, total: 0, flagged: 0) == 0)
    }

    @Test func eachSegmentsHelpNamesItsViewShowKey() {
        for filter in FlagFilter.allCases {
            let key = String(filter.key.character)
            #expect(SheetFilterBar.help(filter).hasSuffix("Control-Command-\(key)."), "\(SheetFilterBar.help(filter))")
        }
    }

    @Test func everyThumbnailSizeHasAName() {
        let names = Metrics.thumbnailWidths.indices.map(ThumbnailSizeControl.sizeName)
        #expect(names == ["Small", "Medium", "Large", "Largest"])
        #expect(Set(names).count == names.count)
    }

    /// Flag, filter, counts and Develop's frames agree: the segments count the roll's flags as they
    /// change, the Flagged filter's title line says how many of the roll show, and Develop develops
    /// exactly those.
    @Test func aFlagCarriesThroughTheFilterToTheCountsAndDevelop() async throws {
        try await Flags.withRoll { fixture in
            let model = Flags.model(fixture), gate = MeasurementGate()
            let frames = try await Flags.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            @MainActor func titles() -> [String] {
                FlagFilter.allCases.map { SheetFilterBar.title($0, total: frames.count, flagged: model.flaggedCount) }
            }
            #expect(titles() == ["All 8", "Flagged 0", "Unflagged 8"])

            Flags.flag(model, [2, 5, 7])
            #expect(titles() == ["All 8", "Flagged 3", "Unflagged 5"])
            #expect(model.shownCountText == "8 frames")

            model.showFrames(.flagged)
            #expect(model.flagFilter == .flagged)
            #expect(model.shownCountText == "Flagged · 3 of 8 frames")
            #expect(WorkspaceTopBar.context(model).subtitle.hasPrefix("Flagged · 3 of 8 frames"))
            #expect(Flags.ids(model.shownFrames) == [2, 5, 7])
            #expect(model.canDevelop && Flags.ids(model.framesToDevelop()) == [2, 5, 7])
            // The segment counts are the roll's, whichever filter is on.
            #expect(titles() == ["All 8", "Flagged 3", "Unflagged 5"])

            // A flag removed under the filter leaves it, and every count follows.
            model.setFlag(false, for: frames[5])
            #expect(titles() == ["All 8", "Flagged 2", "Unflagged 6"])
            #expect(model.shownCountText == "Flagged · 2 of 8 frames")
            #expect(Flags.ids(model.framesToDevelop()) == [2, 7])

            model.showFrames(.all)
            #expect(model.shownCountText == "8 frames" && model.shownFrames.count == 8)
        }
    }
}
