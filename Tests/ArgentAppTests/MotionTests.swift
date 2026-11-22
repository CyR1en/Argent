import AppKit
import ArgentCore
import ArgentRoll
import SwiftUI
import Testing
@testable import ArgentApp

/// The arithmetic and the state under the interface's motion (Roll workflow section 24): where the frame view grows
/// from and shrinks to, how far a drop is stretched, which lines roll, how the shared hover highlight travels, which
/// rail item the lens is on, a run of changes told from one by itself, and a slider's glide to a value it did not set.
@MainActor @Suite struct MotionTests {
    private typealias Spacing = ContactSheet.Spacing

    // MARK: The frame view's way to the sheet and back

    @Test func aWellIsItsCellsPictureWithoutTheFileName() {
        let geometry = SheetGeometry(width: 1000, targetCell: 168)
        let cell = geometry.frame(ofItem: 7), well = geometry.well(ofItem: 7)
        #expect(well.origin == cell.origin)
        #expect(well.width == geometry.cell)
        #expect(well.height == geometry.cell * 2 / 3)
    }

    @Test func aSheetComingBackPutsTheWellWhereItsScrollWill() {
        let geometry = SheetGeometry(width: 1000, targetCell: 168)
        let count = 300, viewport: CGFloat = 600
        // A cell far down the roll is brought to the middle of the view.
        let far = geometry.wellRevealed(ofItem: 150, count: count, viewport: viewport)
        #expect(abs(far.minY + geometry.rowHeight / 2 - viewport / 2) < 1)
        // The first row cannot be: the sheet stays at its top, and the well where the layout has it.
        #expect(geometry.wellRevealed(ofItem: 0, count: count, viewport: viewport) == geometry.well(ofItem: 0))
        // Nor the last, which stays above the sheet's foot.
        let last = geometry.wellRevealed(ofItem: count - 1, count: count, viewport: viewport)
        #expect(last.maxY <= viewport - Spacing.bottomFade)
    }

    @Test func theHeroPutsTheFittedPictureOnTheWell() {
        let size = CGSize(width: 1200, height: 800)
        let well = CGRect(x: 300, y: 200, width: 168, height: 112)
        let move = FrameHero.move(to: well, in: size, isPortrait: false)
        // The frame view fits a 3:2 picture in the workspace above the dock's band.
        let area = CGSize(width: size.width, height: size.height - Graphite.Metric.dockBand)
        let long = min(area.width, area.height * 1.5)
        let picture = CGRect(x: (area.width - long) / 2, y: (area.height - long * 2 / 3) / 2, width: long, height: long * 2 / 3)
        func moved(_ point: CGPoint) -> CGPoint {
            CGPoint(x: move.offset.width + move.scale * point.x, y: move.offset.height + move.scale * point.y)
        }
        let from = moved(picture.origin), to = moved(CGPoint(x: picture.maxX, y: picture.maxY))
        #expect(abs(from.x - well.minX) < 0.001 && abs(from.y - well.minY) < 0.001)
        #expect(abs(to.x - well.maxX) < 0.001 && abs(to.y - well.maxY) < 0.001)
    }

    @Test func aPortraitFrameLandsUprightInTheMiddleOfItsWell() {
        let size = CGSize(width: 1200, height: 800)
        let well = CGRect(x: 300, y: 200, width: 168, height: 112)
        let move = FrameHero.move(to: well, in: size, isPortrait: true)
        let area = CGSize(width: size.width, height: size.height - Graphite.Metric.dockBand)
        let long = min(area.height, area.width * 1.5)
        let picture = CGRect(x: (area.width - long * 2 / 3) / 2, y: (area.height - long) / 2, width: long * 2 / 3, height: long)
        let width = move.scale * picture.width, height = move.scale * picture.height
        #expect(abs(height - well.height) < 0.001)
        #expect(abs(width - well.height * 2 / 3) < 0.001)
        #expect(abs(move.offset.width + move.scale * picture.midX - well.midX) < 0.001)
    }

    @Test func theWayInIsFromTheSheetsOwnWellAndTheWayBackToTheOneForetold() {
        // The sheet up: its own answer, in the window.
        let shown = CGRect(x: 160, y: 252, width: 168, height: 112)
        #expect(FrameHero.Well(inWindow: shown).rect == shown)
        // A cell the sheet has scrolled out of view has no well to come from: the frame view fades in, and does not
        // grow from where the cell would be were the sheet centred on it.
        #expect(FrameHero.Well().rect == nil)
        // The sheet gone: where it will put the frame when it comes back, under its filter row, in the room it will have.
        let room = CGRect(x: 60, y: 52, width: 1000, height: 700)
        let gone = FrameHero.Well(index: 3, count: 24, cell: 168, sheetTop: 50, sheetBottom: 82, room: room)
        let geometry = SheetGeometry(width: room.width, targetCell: 168)
        #expect(gone.rect == geometry.wellRevealed(ofItem: 3, count: 24, viewport: 700 - 50 - 82).offsetBy(dx: 60, dy: 52 + 50))
        // A frame the sheet will not show has no well, nor has any before the room is known: the frame view fades.
        #expect(FrameHero.Well(index: nil, count: 24, room: room).rect == nil)
        #expect(FrameHero.Well(index: 3, count: 24).rect == nil)
    }

    @Test func theWayBackEndsOnTheSameWellBesideTheInspectorAsWithoutIt() throws {
        // The sheet comes back as wide as the workspace is with no panel beside it, whatever the frame view's width.
        let room = CGRect(x: 60, y: 52, width: 1200, height: 800)
        let well = try #require(FrameHero.Well(index: 17, count: 30, cell: 168, sheetTop: 50, sheetBottom: 82, room: room).rect)
        let beside = room.width - Graphite.Metric.inspectorWidth + Graphite.Metric.workspaceInset
        #expect(SheetGeometry(width: beside, targetCell: 168).columns != SheetGeometry(width: room.width, targetCell: 168).columns)
        for width in [room.width, beside] {
            let size = CGSize(width: width, height: room.height)
            let move = FrameHero.move(to: well.offsetBy(dx: -room.minX, dy: -room.minY), in: size, isPortrait: false)
            let area = CGSize(width: size.width, height: size.height - Graphite.Metric.dockBand)
            let long = min(area.width, area.height * 1.5)
            let picture = CGRect(x: (area.width - long) / 2, y: (area.height - long * 2 / 3) / 2, width: long, height: long * 2 / 3)
            // Where the picture ends, in the window.
            let landed = CGRect(x: room.minX + move.offset.width + move.scale * picture.minX,
                                y: room.minY + move.offset.height + move.scale * picture.minY,
                                width: move.scale * picture.width, height: move.scale * picture.height)
            #expect(abs(landed.minX - well.minX) < 0.001 && abs(landed.minY - well.minY) < 0.001)
            #expect(abs(landed.width - well.width) < 0.001 && abs(landed.height - well.height) < 0.001)
        }
    }

    // MARK: The spring the frame view leaves on

    /// The frame view's spring (`Graphite.Motion.hero`), in real seconds.
    private static let heroSpring = Spring(response: 0.46, dampingRatio: 0.86)

    @Test func aRestingSpringEndsOnceItIsAtRestToTheEye() throws {
        let spring = Self.heroSpring, leg = SpringLeg<Double>()
        // Still on its way as it lands, and at rest well inside a second: SwiftUI's own spring kept the frame view 1.3 s.
        #expect(!leg.state(at: 0, to: 1, spring: spring).isAtRest)
        #expect(!leg.state(at: 0.4, to: 1, spring: spring).isAtRest)
        let rested = try #require(stride(from: 0.0, through: 2, by: 1.0 / 120).first { leg.state(at: $0, to: 1, spring: spring).isAtRest })
        #expect(rested > 0.5 && rested < 0.8)
        // Within `restFraction` of the move of where it was going, and it stays at rest from then on.
        let end = leg.state(at: rested, to: 1, spring: spring)
        #expect(abs(end.position - 1) <= SpringLeg<Double>.restFraction)
        #expect(stride(from: rested, through: 4, by: 1.0 / 120).allSatisfy { leg.state(at: $0, to: 1, spring: spring).isAtRest })
        // A move of no length is at rest before it starts.
        #expect(leg.state(at: 0, to: 0, spring: spring).isAtRest)
    }

    @Test func aRestingSpringMovesAsTheSpringDoes() {
        let spring = Self.heroSpring, leg = SpringLeg<Double>()
        for time in stride(from: 0.0, through: 0.5, by: 0.05) {
            let now = leg.state(at: time, to: 300, spring: spring)
            #expect(abs(now.position - spring.value(target: 300.0, time: time)) < 1e-9)
            #expect(abs(now.velocity - spring.velocity(target: 300.0, time: time)) < 1e-9)
        }
    }

    @Test func aSpringSentBackGoesOnFromWhereItIsAtTheSpeedItHas() {
        let spring = Self.heroSpring, out = SpringLeg<Double>()
        // On its way to 1, the frame opening, and sent back to 0 before it has settled, the frame closed.
        let turned = 0.2, before = out.state(at: turned, to: 1, spring: spring)
        let back = out.redirected(at: turned, from: 1, spring: spring)
        let after = back.state(at: turned, to: 0, spring: spring)
        #expect(before.position > 0.5 && before.velocity > 0)
        #expect(abs(after.position - before.position) < 1e-12)
        #expect(abs(after.velocity - before.velocity) < 1e-12)
        // It carries on a little the way it was going, then comes back, and is at rest within the second: on SwiftUI's
        // own spring a frame view with its picture in it, sent back so, stayed 3.2 s.
        #expect(back.state(at: turned + 0.02, to: 0, spring: spring).position > before.position)
        #expect(!back.state(at: turned + 0.3, to: 0, spring: spring).isAtRest)
        let end = back.state(at: turned + 0.8, to: 0, spring: spring)
        #expect(end.isAtRest && abs(end.position) <= SpringLeg<Double>.restFraction)
    }

    @Test func aSpringSentAHairFurtherAtRestIsAtRestAtOnce() {
        let spring = Self.heroSpring, first = SpringLeg<Double>()
        // At rest after a move of 1000, then sent a millionth of a point on: at rest as measured against the whole
        // move, and not held until it is within a thousandth of that millionth.
        let nudged = first.redirected(at: 2, from: 1000, spring: spring)
        #expect(nudged.state(at: 2, to: 1000.000001, spring: spring).isAtRest)
        // Sent somewhere it can be seen to go, it goes.
        #expect(!nudged.state(at: 2, to: 1010, spring: spring).isAtRest)
        #expect(nudged.state(at: 2.8, to: 1010, spring: spring).isAtRest)
    }

    @Test func aRestingSpringMovesAPairOfValuesTogether() {
        // An offset across and down, as the frame view's way to its cell has one: one spring, at rest for both at once.
        typealias Pair = AnimatablePair<Double, Double>
        let spring = Self.heroSpring, leg = SpringLeg<Pair>()
        let target = Pair(1053, 312.5)
        let midway = leg.state(at: 0.2, to: target, spring: spring)
        #expect(abs(midway.position.first / target.first - midway.position.second / target.second) < 1e-9)
        #expect(!midway.isAtRest)
        #expect(leg.state(at: 0.8, to: target, spring: spring).isAtRest)
    }

    // MARK: A run of changes

    @Test func aChangeSoonAfterTheLastIsOneOfARun() {
        var time: CFTimeInterval = 100
        let pace = ChangePace<Int>(now: { time })
        // The first value is no run's, nor is one long after it.
        #expect(!pace.isInRun(1))
        time += 1
        #expect(!pace.isInRun(2))
        // Asked again about the same value, as a view drawn again asks, the answer is the same.
        time += 0.05
        #expect(!pace.isInRun(2))
        // Each that follows within the gap is the run's, a value come back to among them.
        #expect(pace.isInRun(3))
        time += Graphite.Motion.runGap - 0.01
        #expect(pace.isInRun(2))
        time += 5
        #expect(pace.isInRun(2))
        // The next by itself is animated to again.
        #expect(!pace.isInRun(7))
    }

    @Test func aRowGlidesToAValueFromElsewhereThatComesByItself() {
        var time: CFTimeInterval = 100
        let arrivals = ValueArrivals(now: { time })
        // The first value the row shows is put there.
        #expect(!arrivals.glides(to: 10, isOwn: false))
        // A reset long after is glided to, and the answer is the same when the row is drawn again.
        time += 2
        #expect(arrivals.glides(to: 0, isOwn: false))
        time += 0.05
        #expect(arrivals.glides(to: 0, isOwn: false))
        // The row's own steps are shown at once, however far apart, and an undo after them is glided to.
        time += 2
        #expect(!arrivals.glides(to: 4, isOwn: true))
        time += 2
        #expect(!arrivals.glides(to: 8, isOwn: true))
        time += 2
        #expect(arrivals.glides(to: 0, isOwn: false))
        // A run from elsewhere, a handle dragged on the photograph: the first is glided to, the rest shown as they come.
        time += 2
        #expect(arrivals.glides(to: 1, isOwn: false))
        for value in [Float(2), 3, 4, 5] {
            time += 0.04
            #expect(!arrivals.glides(to: value, isOwn: false))
        }
        // And a value by itself after the run is glided to again.
        time += 1
        #expect(arrivals.glides(to: 0, isOwn: false))
    }

    // MARK: A drop

    @Test func aDropIsStretchedByHowFarPastItsRestItIs() {
        #expect(Span(start: 10, end: 50).length == 40)
        #expect(Span(start: 10, end: 50).mid == 30)
        #expect(Span(start: 0, end: 40).stretch(from: 40) == 0)
        #expect(Span(start: 0, end: 60).stretch(from: 40) == 0.5)
        // No more than twice as long counts, and a drop shorter than its rest is not stretched.
        #expect(Span(start: 0, end: 200).stretch(from: 40) == 1)
        #expect(Span(start: 0, end: 20).stretch(from: 40) == 0)
        #expect(Span(start: 0, end: 20).stretch(from: 0) == 0)
    }

    // MARK: Lines that change

    @Test func aCountsStepRollsAndAnotherLineFades() {
        #expect(RollingText.rolls(from: "10 of 24 · DSC04059", to: "11 of 24 · DSC04060"))
        #expect(RollingText.rolls(from: "Flagged 3", to: "Flagged 4"))
        #expect(RollingText.rolls(from: "Develop 24", to: "Develop 23"))
        // Another line, or one of another length.
        #expect(!RollingText.rolls(from: "24 frames · Auto ready", to: "10 of 24 · DSC04059"))
        #expect(!RollingText.rolls(from: "Saving…", to: "Saved"))
        #expect(!RollingText.rolls(from: "Develop 24", to: "Stop"))
        #expect(!RollingText.rolls(from: "", to: ""))
    }

    // MARK: The shared hover highlight

    @Test func theHighlightTravelsFromOneControlToTheNext() {
        let glide = HoverGlide()
        let a = HoverGlide.Place(id: glide.makeID(), frame: CGRect(x: 0, y: 0, width: 60, height: 28), radius: 7)
        let b = HoverGlide.Place(id: glide.makeID(), frame: CGRect(x: 80, y: 0, width: 60, height: 28), radius: 7)
        #expect(a.id != b.id)
        // The first control it comes to: placed, not travelled to.
        glide.hover(a, true)
        #expect(glide.place == a && glide.isOver && glide.travel == 0)
        // Straight on to the next, whichever of the two the system says first.
        glide.hover(b, true)
        glide.hover(a, false)
        #expect(glide.place == b && glide.isOver && glide.travel == 1)
        // Across the gap between two: it fades where it was, and still travels while that fade is under way.
        glide.hover(b, false)
        #expect(glide.place == b && !glide.isOver)
        glide.hover(a, true)
        #expect(glide.place == a && glide.isOver && glide.travel == 2)
    }

    @Test func theHighlightIsPlacedAgainOnceItHasFaded() async throws {
        let glide = HoverGlide()
        let a = HoverGlide.Place(id: glide.makeID(), frame: CGRect(x: 0, y: 0, width: 60, height: 28), radius: 7)
        let b = HoverGlide.Place(id: glide.makeID(), frame: CGRect(x: 80, y: 0, width: 60, height: 28), radius: 7)
        glide.hover(a, true)
        glide.hover(a, false)
        try await Task.sleep(for: .seconds(HoverGlide.linger + 0.1))
        glide.hover(b, true)
        #expect(glide.place == b && glide.isOver && glide.travel == 0)
    }

    @Test func aPressDipsTheHighlightOnlyUnderTheControlItIsOn() {
        let glide = HoverGlide()
        let a = HoverGlide.Place(id: glide.makeID(), frame: CGRect(x: 0, y: 0, width: 60, height: 28), radius: 7)
        let b = HoverGlide.Place(id: glide.makeID(), frame: CGRect(x: 80, y: 0, width: 60, height: 28), radius: 7)
        glide.hover(a, true)
        glide.press(b.id, true)
        #expect(!glide.isPressed)
        glide.press(a.id, true)
        #expect(glide.isPressed)
        // Leaving lets it go, as the release would.
        glide.hover(a, false)
        #expect(!glide.isPressed)
        // A control that moves, as a dock's do when its room changes, takes the highlight with it.
        glide.hover(a, true)
        var moved = a
        moved.frame.origin.x = 20
        glide.moved(moved)
        #expect(glide.place == moved && glide.travel == 0)
    }

    // MARK: The rail's lens

    @Test func theLensIsOnTheItemOfThePageTheWorkspaceShows() {
        #expect(RailPlace.page(.rolls, isFrameOpen: false) == .rolls)
        // An import's review is the Rolls page's.
        #expect(RailPlace.page(.importReview, isFrameOpen: false) == .rolls)
        #expect(RailPlace.page(.roll, isFrameOpen: false) == .roll)
        #expect(RailPlace.page(.roll, isFrameOpen: true) == .frame)
        // A frame left open under another page is not where the workspace is.
        #expect(RailPlace.page(.develop, isFrameOpen: true) == .develop)
        #expect(RailPlace.page(.settings, isFrameOpen: true) == .settings)
        // Stock and Adjust are tools, with lenses of their own.
        #expect(!RailPlace.stock.isPage && !RailPlace.adjust.isPage)
        let pages: [RailPlace] = [.rolls, .roll, .frame, .develop, .settings]
        #expect(pages.filter { !$0.isPage }.isEmpty)
    }

    // MARK: A slider's glide

    @Test func aGlidingSliderStandsForWhereItIsGoing() {
        _ = NSApplication.shared
        let slider = AdjustmentSliderControl()
        slider.spec = .light(.contrast)
        slider.doubleValue = 40
        #expect(slider.settledValue == 40)
        slider.glide(to: 0)
        // The knob has not moved yet; the slider already stands for the value it was given.
        #expect(slider.doubleValue == 40)
        #expect(slider.settledValue == 0)
        // Another value before it arrives: it goes on to that one.
        slider.glide(to: -20)
        #expect(slider.settledValue == -20)
        slider.endGlide()
        #expect(slider.doubleValue == -20 && slider.settledValue == -20)
        // Ended twice, or with no glide under way, nothing changes.
        slider.endGlide()
        #expect(slider.doubleValue == -20)
    }

    @Test func aKeyStepsFromTheValueAGlideWasGoingTo() {
        _ = NSApplication.shared
        let slider = AdjustmentSliderControl()
        slider.spec = .light(.contrast)
        slider.doubleValue = 40
        slider.glide(to: 0)
        #expect(slider.accessibilityPerformIncrement())
        #expect(slider.doubleValue == Double(AdjustmentSliderSpec.light(.contrast).arrowStep))
        #expect(slider.settledValue == slider.doubleValue)
    }
}
