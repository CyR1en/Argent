import ArgentCore
@testable import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// The split comparison's geometry in the frame view's area (`SplitGeometry`) and what its tags say
/// (`CompareTags`).
@MainActor @Suite struct FrameCompareTests {
    /// A landscape frame fitted in a 1280 by 860 window's frame view: 1134 by 756 points, centred.
    private static let fitted = SplitGeometry(area: CGSize(width: 1188, height: 756),
                                              picture: CGRect(x: 27, y: 0, width: 1134, height: 756), displayScale: 2)

    @Test func theNeutralRawIsThePictureLeftOfTheDivider() {
        let split = Self.fitted
        #expect(split.dividerX(at: 0.5) == 594)
        // Measured from the picture's own left edge, not the area's.
        #expect(split.neutralWidth(at: 0.5) == 567)
        #expect(split.neutralPercent(at: 0.5) == 50)
    }

    @Test func aZoomedPictureMovesUnderADividerThatStaysPut() {
        // Zoomed past the area and panned: the divider keeps its place in the area, and the mask
        // follows the picture's coordinates so the two sides stay one picture.
        var split = Self.fitted
        split.picture = CGRect(x: -300, y: -200, width: 1752, height: 1168)
        #expect(split.dividerX(at: 0.5) == 594)
        #expect(split.neutralWidth(at: 0.5) == 894)
        split.picture.origin.x = -500
        #expect(split.dividerX(at: 0.5) == 594)
        #expect(split.neutralWidth(at: 0.5) == 1094)
        // The span is the part of the area the picture covers: all of it.
        #expect(split.span == 0...1188)
    }

    @Test func theDividerNeverLeavesAPortraitPicture() {
        // A portrait frame leaves surround each side; the divider stays over the photograph.
        let split = SplitGeometry(area: CGSize(width: 1188, height: 756),
                                  picture: CGRect(x: 342, y: 0, width: 504, height: 756), displayScale: 2)
        #expect(split.dividerX(at: 0.1) == 342)
        #expect(split.neutralWidth(at: 0.1) == 0)
        #expect(split.dividerX(at: 0.9) == 846)
        #expect(split.neutralWidth(at: 0.9) == 504)
        // A pointer beyond the picture puts the divider at its edge.
        #expect(split.position(atX: 20) == CGFloat(342) / 1188)
        #expect(split.position(atX: 1100) == CGFloat(846) / 1188)
    }

    @Test func theDividerStandsOnAWholeDevicePixel() {
        let split = Self.fitted
        let x = split.dividerX(at: 594.3 / 1188)
        #expect(x == 594.5)
        #expect((x * 2).rounded() == x * 2)
    }

    @Test func theKeysAndVoiceOverMoveItByATwentiethAndStopAtThePicture() {
        let split = Self.fitted
        #expect(abs(split.position(0.5, steppedBy: -1) - 0.45) < 1e-9)
        #expect(abs(split.position(0.5, steppedBy: 2) - 0.6) < 1e-9)
        // Twenty steps left go no further than the picture's left edge.
        #expect(split.position(0.5, steppedBy: -20) == CGFloat(27) / 1188)
        // VoiceOver's percent of the picture comes back as the position that gives it.
        let position = split.position(neutralPercent: 25)
        #expect(split.neutralPercent(at: position) == 25)
    }

    @Test func aSideTooNarrowForItsTagGoesWithout() {
        let split = Self.fitted
        let centred = split.tagCenters(at: 0.5)
        #expect(centred.neutral == CGFloat(27 + 594) / 2)
        #expect(centred.film == CGFloat(594 + 1161) / 2)
        let left = split.tagCenters(at: 0.08)
        #expect(left.neutral == nil)
        #expect(left.film != nil)
    }

    @Test func theTagsSitOnThePhotograph() {
        var split = Self.fitted
        // A picture to the top of the area: under the top bar.
        #expect(split.tagY(height: 26, belowBar: 78) == 91)
        #expect(split.hintY(height: 26) == CGFloat(756 - 14 - 13))
        // A picture with surround above and below it: just inside its own edges.
        split.picture = CGRect(x: 0, y: 77, width: 902, height: 601)
        #expect(split.tagY(height: 26, belowBar: 78) == CGFloat(77 + 12 + 13))
        #expect(split.hintY(height: 26) == CGFloat(678 - 14 - 13))
    }

    @Test func eachComparisonIsTaggedApart() {
        func tags(split: Bool = false, space: Bool = false, neutral: Bool = true, start: String? = nil, ready: Bool = true) -> CompareTags {
            CompareTags.shown(splitting: split, holdingSpace: space, neutralReady: neutral, startingPoint: start,
                              startingPointReady: ready, filmName: "Portra 400")
        }
        #expect(tags() == .none)
        #expect(tags(split: true) == .split(film: "Portra 400"))
        #expect(tags(space: true) == .single("Neutral RAW"))
        // Space shows the whole neutral raw in either mode.
        #expect(tags(split: true, space: true) == .single("Neutral RAW"))
        #expect(tags(start: "Auto") == .single("Auto starting point"))
        #expect(tags(start: "Original") == .single("Original starting point"))
        #expect(tags(split: true, start: "Original") == .split(film: "Original starting point"))
        // Not ready: said so, never film under a neutral raw's name.
        #expect(tags(split: true, neutral: false) == .single("Decoding the neutral RAW…", busy: true))
        #expect(tags(space: true, neutral: false) == .single("Decoding the neutral RAW…", busy: true))
        #expect(tags(start: "Auto", ready: false) == .single("Rendering the Auto starting point…", busy: true))
    }
}

/// The filmstrip's windowing: whole thumbnails, and which shows first so the open frame is in view.
@MainActor @Suite struct FilmstripWindowTests {
    @Test func theStripShowsWholeThumbnails() {
        // 48-by-32-point thumbnails 4 apart, and 3 at each end for the ring.
        #expect(FilmstripWindow.thumbnail * 2 / 3 == 32)
        #expect(FilmstripWindow.slots(fitting: 6 + 48) == 1)
        #expect(FilmstripWindow.slots(fitting: 6 + 3 * 52 - 4) == 3)
        #expect(FilmstripWindow.slots(fitting: 6 + 3 * 52 - 5) == 2)
        #expect(FilmstripWindow.slots(fitting: 0) == 1)
        #expect(FilmstripWindow(count: 24, slots: 9).width == CGFloat(9 * 52 - 4 + 6))
        // Never wider than the frames it holds.
        #expect(FilmstripWindow(count: 2, slots: 9).width == CGFloat(2 * 52 - 4 + 6))
        // In more room than its whole thumbnails take, a long strip fills it; a short one keeps to its frames.
        #expect(FilmstripWindow(count: 24, slots: 9).shownWidth(in: 850) == 850)
        #expect(FilmstripWindow(count: 2, slots: 9).shownWidth(in: 850) == CGFloat(2 * 52 - 4 + 6))
    }

    @Test func theSelectedFrameFitsBesideTheFlagInATinyCenter() {
        // A 145-point center, less the flag's 30 points and its 6-point gap.
        let room: CGFloat = 109
        let window = FilmstripWindow(count: 24, slots: FilmstripWindow.slots(fitting: room))
        #expect(window.slots == 2)
        for selected in 0..<24 {
            let offset = window.scrollOffset(showing: selected, from: nil, in: room)
            let leading = CGFloat(selected) * FilmstripWindow.pitch
            #expect(leading >= offset)
            #expect(leading + 54 <= offset + room)
        }
        // At the roll's end the scroll is clamped to its actual content, not a whole pitch.
        #expect(window.scrollOffset(showing: 23, from: 0, in: room) == window.contentWidth - room)
        #expect(FilmstripWindow(count: 1, slots: 2).scrollOffset(showing: 0, from: 0, in: room) == 0)
        #expect(FilmstripWindow(count: 0, slots: 2).shownWidth(in: 0) == 0)
    }

    @Test func followingAfterATrackpadScrollOrResizeKeepsTheWholeRingVisible() {
        let window = FilmstripWindow(count: 24, slots: 2)
        // A partial scroll hides the start of frame 5, although its rounded slot is unchanged.
        #expect(window.scrollOffset(showing: 5, from: 5 * 52 + 12, in: 109) == CGFloat(5 * 52))
        // Width changes inside the same slot count must still reveal the ring at the right edge.
        #expect(window.scrollOffset(showing: 6, from: 5 * 52 - 8, in: 109) == CGFloat(6 * 52 + 54 - 109))
        // A selected frame wholly inside a fractional scroll stays put.
        #expect(window.scrollOffset(showing: 6, from: 5 * 52 + 8, in: 109) == CGFloat(5 * 52 + 8))
        // Even a viewport with room for only one thumbnail follows jumps in either direction.
        let single = FilmstripWindow(count: 24, slots: 1)
        #expect(single.scrollOffset(showing: 18, from: 0, in: 54) == CGFloat(18 * 52))
        #expect(single.scrollOffset(showing: 0, from: 18 * 52, in: 54) == 0)
    }

    @Test func itOpensCentredOnTheFrame() {
        let window = FilmstripWindow(count: 24, slots: 9)
        #expect(window.first(showing: 12, from: nil) == 8)
        #expect(window.first(showing: 1, from: nil) == 0)
        #expect(window.first(showing: 23, from: nil) == 15)
    }

    @Test func movingByKeysScrollsOnlyAtTheEnds() {
        let window = FilmstripWindow(count: 24, slots: 9)
        // Clear of the ends: still.
        #expect(window.first(showing: 5, from: 3) == 3)
        #expect(window.first(showing: 10, from: 3) == 3)
        // The last but one in view: one more beyond it comes in.
        #expect(window.first(showing: 11, from: 3) == 4)
        #expect(window.first(showing: 3, from: 3) == 2)
        // Home and End, far from the strip's place.
        #expect(window.first(showing: 0, from: 10) == 0)
        #expect(window.first(showing: 23, from: 0) == 15)
        // A short strip keeps no thumbnail beyond.
        let short = FilmstripWindow(count: 24, slots: 3)
        #expect(short.first(showing: 5, from: 3) == 3)
        #expect(short.first(showing: 6, from: 3) == 4)
        // Fewer frames than room: always from the first.
        #expect(FilmstripWindow(count: 4, slots: 9).first(showing: 3, from: 0) == 0)
    }

    @Test func anOpenFrameTheFilterLeavesOutRestsWhereItWouldBe() {
        let frames = [2, 5, 9].map { Frame(id: $0, url: URL(fileURLWithPath: "/tmp/strip/\($0).ARW"), info: ARWFrameInfo()) }
        #expect(FilmstripWindow.index(of: 5, in: frames) == 1)
        #expect(FilmstripWindow.index(of: 6, in: frames) == 2)
        #expect(FilmstripWindow.index(of: 12, in: frames) == 2)
        #expect(FilmstripWindow.index(of: 0, in: frames) == 0)
        #expect(FilmstripWindow.index(of: nil, in: frames) == nil)
        #expect(FilmstripWindow.index(of: 1, in: []) == nil)
    }
}

/// The frame fitted in the workspace above the dock's band, with no margin of its own.
@MainActor @Suite struct FrameFramingTests {
    private static func frame(portrait: Bool) -> Frame {
        var info = ARWFrameInfo()
        if portrait { info.orientation = .right }
        return Frame(id: 0, url: URL(fileURLWithPath: "/tmp/framing/DSC1.ARW"), info: info)
    }

    /// The frame view's area for a window: the workspace under the title strip and beside the
    /// rail's column, inset 6 points at the bottom and trailing edge (none trailing with the
    /// inspector beyond it), above the band.
    private static func area(window: CGSize, inspector: Bool = false) -> CGSize {
        let width = window.width - Graphite.Metric.railWidth - (inspector ? Graphite.Metric.inspectorWidth : Graphite.Metric.workspaceInset)
        let height = window.height - Graphite.Metric.titleStripHeight - Graphite.Metric.workspaceInset - Graphite.Metric.dockBand
        return CGSize(width: width, height: height)
    }

    @Test(arguments: [CGSize(width: 1280, height: 860), CGSize(width: 900, height: 600), CGSize(width: 1600, height: 1000),
                      CGSize(width: 800, height: 560)], [false, true])
    func theWholeFrameFitsAndFillsOneWay(window: CGSize, inspector: Bool) {
        let area = Self.area(window: window, inspector: inspector)
        let layout = FrameLayout(area: area, displayScale: 2)
        for portrait in [false, true] {
            let frame = Self.frame(portrait: portrait)
            let box = layout.box(frame)
            // Never cropped: inside the area, to within the decoder's rounding of a half pixel.
            #expect(box.width <= area.width + 0.5 && box.height <= area.height + 0.5)
            // As large as the area allows: one side meets it.
            #expect(min(area.width - box.width, area.height - box.height) < 1)
            // 3:2 or 2:3, undistorted.
            let ratio = max(box.width, box.height) / min(box.width, box.height)
            #expect(abs(ratio - 1.5) < 0.01)
            // Centred, its corner on a whole device pixel.
            let center = layout.center(of: box)
            let corner = (center.x - box.width / 2) * 2
            #expect(corner.rounded() == corner)
        }
    }

    @Test func atTheApprovedSizeALandscapeFrameMeetsTheTopOfTheWorkspaceAndTheBand() {
        let area = Self.area(window: CGSize(width: 1280, height: 860))
        #expect(area == CGSize(width: 1214, height: 726))
        let box = FrameLayout(area: area, displayScale: 2).box(Self.frame(portrait: false))
        #expect(box == CGSize(width: 1089, height: 726))
    }
}
