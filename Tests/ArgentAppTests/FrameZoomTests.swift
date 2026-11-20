@testable import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

@MainActor @Suite struct FrameZoomTests {
    /// A landscape frame in a 14-inch MacBook Pro's frame view: 1320 by 880 points, 2640 pixels long,
    /// of a full-frame raw 7008 pixels long.
    private static let room = FrameZoom.Room(area: CGSize(width: 1464, height: 880), fitted: CGSize(width: 1320, height: 880),
                                             fitPixels: 2640, fullPixels: 7008, displayScale: 2)

    /// The point of the picture under `point`, as fractions of the picture from its centre.
    private func spot(_ point: CGPoint, _ zoom: FrameZoom, _ room: FrameZoom.Room = room) -> CGPoint {
        CGPoint(x: (point.x - room.area.width / 2 - zoom.offset.width) / (room.fitted.width * zoom.scale),
                y: (point.y - room.area.height / 2 - zoom.offset.height) / (room.fitted.height * zoom.scale))
    }

    @Test func fittedRendersAtTheFittedSize() {
        #expect(FrameZoom().pixels(in: Self.room) == 2640)
        #expect(!FrameZoom().isZoomed)
        #expect(abs(Self.room.actualScale - 7008.0 / 2640) < 1e-12)
        #expect(FrameZoom().settled(in: Self.room) == FrameZoom())
    }

    @Test func pinchKeepsThePointUnderThePointer() {
        let anchor = CGPoint(x: 900, y: 300)
        let start = FrameZoom().zoomed(to: 2, around: CGPoint(x: 732, y: 440), in: Self.room)
        let before = spot(anchor, start)
        let pinched = start.zoomed(to: 3, around: anchor, in: Self.room)
        let after = spot(anchor, pinched)
        #expect(pinched.scale == 3)
        #expect(abs(after.x - before.x) < 1e-9 && abs(after.y - before.y) < 1e-9)
    }

    @Test func aZoomedPictureCoversTheAreaAndASmallerSideIsCentred() {
        // Toward the top left corner, as far as the picture goes.
        let corner = FrameZoom().zoomed(to: 1.5, around: .zero, in: Self.room).panned(by: CGSize(width: 5000, height: 5000), in: Self.room)
        #expect(corner.offset.width == (1320 * 1.5 - 1464) / 2)
        #expect(corner.offset.height == (880 * 1.5 - 880) / 2)
        // 1.05 times is still narrower than the area: centred across, free up and down.
        let narrow = FrameZoom().zoomed(to: 1.05, around: CGPoint(x: 0, y: 0), in: Self.room)
        #expect(narrow.offset.width == 0)
        #expect(abs(narrow.offset.height - 22) < 1e-9)
    }

    @Test func actualSizeRendersTheRawOneToOne() {
        let actual = FrameZoom().stepped(.actualSize, in: Self.room)
        #expect(actual.pixels(in: Self.room) == 7008)
        // The picture's scale is the render's, so its box shows unscaled.
        #expect(actual.scale == CGFloat(7008) / CGFloat(2640))
        #expect(actual.renderedScale == actual.scale)
        // On whole device pixels.
        #expect((actual.offset.width * 2).rounded() == actual.offset.width * 2)
    }

    @Test func settlingMovesToTheRendersOwnScaleAndPastTheRawScalesIt() {
        let between = FrameZoom().zoomed(to: 1.6123, around: CGPoint(x: 400, y: 200), in: Self.room).settled(in: Self.room)
        #expect(between.pixels(in: Self.room) == 4256)
        #expect(between.scale == CGFloat(4256) / CGFloat(2640))
        #expect((between.offset.width * 2).rounded() == between.offset.width * 2)
        #expect((between.offset.height * 2).rounded() == between.offset.height * 2)
        let past = FrameZoom().zoomed(to: 6, around: CGPoint(x: 732, y: 440), in: Self.room).settled(in: Self.room)
        #expect(past.scale == 6)
        #expect(past.pixels(in: Self.room) == 7008)
        #expect(past.renderedScale == CGFloat(7008) / CGFloat(2640))
    }

    @Test func menuStepsDoubleFromFittingToTheMaximumAndBack() {
        let actual = Self.room.actualScale
        var zoom = FrameZoom()
        var scales: [CGFloat] = []
        for _ in 0..<6 {
            zoom = zoom.stepped(.zoomIn, in: Self.room)
            scales.append(zoom.scale)
        }
        // Half of Actual Size, Actual Size, twice and four times it, which is the most.
        #expect(abs(scales[0] - actual / 2) < 0.001)
        #expect(abs(scales[1] - actual) < 1e-12)
        #expect(abs(scales[2] - 2 * actual) < 1e-12)
        #expect(abs(scales[3] - 4 * actual) < 1e-12)
        #expect(scales[4] == scales[3] && scales[5] == scales[3])
        for _ in 0..<4 { zoom = zoom.stepped(.zoomOut, in: Self.room) }
        #expect(zoom == FrameZoom())
        #expect(FrameZoom().stepped(.zoomOut, in: Self.room) == FrameZoom())
        #expect(zoom.stepped(.actualSize, in: Self.room).stepped(.fit, in: Self.room) == FrameZoom())
    }

    @Test func smartZoomGoesToActualSizeAboutThePointerAndBack() {
        let anchor = CGPoint(x: 1000, y: 600)
        let zoomed = FrameZoom().toggled(around: anchor, in: Self.room)
        #expect(zoomed.pixels(in: Self.room) == 7008)
        // The point tapped stays within a device pixel of the pointer.
        let tapped = spot(anchor, FrameZoom())
        let now = spot(anchor, zoomed)
        #expect(abs(now.x - tapped.x) * 1320 * zoomed.scale < 0.5)
        #expect(abs(now.y - tapped.y) * 880 * zoomed.scale < 0.5)
        #expect(zoomed.toggled(around: anchor, in: Self.room) == FrameZoom())
    }

    @Test func aPinchBelowFittingSpringsBack() {
        let pinched = FrameZoom().zoomed(to: 0.5, around: CGPoint(x: 100, y: 100), in: Self.room, floor: FrameZoom.pinchFloor)
        #expect(pinched.scale == FrameZoom.pinchFloor)
        #expect(pinched.offset == .zero)
        #expect(pinched.settled(in: Self.room) == FrameZoom())
    }

    @Test func actualSizeCanBeSmallerThanFitAndSmartZoomReturnsToFit() {
        let small = FrameZoom.Room(area: CGSize(width: 2600, height: 1600), fitted: CGSize(width: 2400, height: 1600),
                                   fitPixels: 4800, fullPixels: 3504, displayScale: 2)
        #expect(small.actualScale == CGFloat(3504) / 4800)
        let actual = FrameZoom().stepped(.actualSize, in: small)
        #expect(!actual.isFitted)
        #expect(actual.pixels(in: small) == 3504)
        #expect(actual.scale * CGFloat(small.fitPixels) == CGFloat(small.fullPixels))
        #expect(actual.offset == .zero)
        let zoomed = FrameZoom().toggled(around: CGPoint(x: 1300, y: 800), in: small)
        #expect(zoomed == actual)
        #expect(zoomed.toggled(around: .zero, in: small) == FrameZoom())
        #expect(FrameZoom().stepped(.zoomOut, in: small) == actual)
        #expect(actual.stepped(.zoomOut, in: small) == actual)
        #expect(actual.stepped(.zoomIn, in: small) == FrameZoom())
        // A pinch can reach the smaller native size and springs back if taken past it.
        let pinched = actual.zoomed(to: 0.1, around: .zero, in: small, floor: FrameZoom.pinchFloor)
        #expect(pinched.settled(in: small) == actual)
    }

    private func room(fitPixels: Int, fullPixels: Int = 7008, displayScale: CGFloat = 2,
                      portrait: Bool = false) -> FrameZoom.Room {
        let long = CGFloat(fitPixels) / displayScale
        let short = CGFloat((2 * fitPixels + 2) / 3) / displayScale
        let fitted = portrait ? CGSize(width: short, height: long) : CGSize(width: long, height: short)
        return FrameZoom.Room(area: CGSize(width: fitted.width + 144, height: fitted.height), fitted: fitted,
                              fitPixels: fitPixels, fullPixels: fullPixels, displayScale: displayScale)
    }

    @Test(arguments: [2200, 3200], [false, true])
    func actualSizeStaysOneToOneWhenTheRoomChanges(fitPixels: Int, portrait: Bool) {
        let originalRoom = room(fitPixels: 2640, portrait: portrait)
        let original = FrameZoom().stepped(.actualSize, in: originalRoom)
        let changedRoom = room(fitPixels: fitPixels, portrait: portrait)
        let changed = original.reframed(from: originalRoom, to: changedRoom)
        #expect(changed.pixels(in: changedRoom) == changedRoom.fullPixels)
        #expect(abs(CGFloat(changedRoom.fitPixels) * changed.scale - CGFloat(changedRoom.fullPixels)) < 0.5)
        #expect(!changed.isFitted)
        #expect(FrameZoom().reframed(from: originalRoom, to: changedRoom) == FrameZoom())
    }

    @Test func actualSizeAtFitRemainsDistinctAndFollowsTheNativeSizeOnceKnown() {
        let unknown = room(fitPixels: 2640, fullPixels: 2640)
        let actual = FrameZoom().stepped(.actualSize, in: unknown)
        #expect(actual.scale == 1 && !actual.isFitted)
        let known = room(fitPixels: 2640)
        let ready = actual.reframed(from: unknown, to: known)
        #expect(ready.pixels(in: known) == known.fullPixels)
        #expect(ready.scale == known.actualScale)
        #expect(FrameZoom().reframed(from: unknown, to: known) == FrameZoom())
    }

    @Test func changingDisplayScaleKeepsSourceMagnificationAndTheCenteredSubject() {
        let previous = Self.room
        let actual = FrameZoom().stepped(.actualSize, in: previous)
            .panned(by: CGSize(width: -40, height: 12), in: previous).settled(in: previous)
        let otherDisplay = FrameZoom.Room(area: previous.area, fitted: previous.fitted,
                                         fitPixels: 1320, fullPixels: 7008, displayScale: 1)
        let changed = actual.reframed(from: previous, to: otherDisplay)
        #expect(changed.pixels(in: otherDisplay) == otherDisplay.fullPixels)
        #expect(changed.scale == otherDisplay.actualScale)
        #expect(changed.offset == CGSize(width: -80, height: 24))
        let center = CGPoint(x: previous.area.width / 2, y: previous.area.height / 2)
        let before = spot(center, actual, previous), after = spot(center, changed, otherDisplay)
        #expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9)
    }

    @Test func smartZoomBeforeTheHeaderArrivesFollowsActualSize() {
        var unknown = room(fitPixels: 2640, fullPixels: 2640)
        unknown.fullPixelsKnown = false
        let anchor = CGPoint(x: 1000, y: 600)
        let pending = FrameZoom().toggled(around: anchor, in: unknown)
        #expect(!pending.isFitted)
        #expect(pending.scale == 1)
        let known = room(fitPixels: 2640)
        let ready = pending.reframed(from: unknown, to: known)
        #expect(ready.scale == known.actualScale)
        #expect(ready.pixels(in: known) == known.fullPixels)
        let before = spot(anchor, pending, unknown), after = spot(anchor, ready, known)
        #expect(abs(before.x - after.x) * known.fitted.width * ready.scale < 0.5)
        #expect(abs(before.y - after.y) * known.fitted.height * ready.scale < 0.5)
        // A known RAW already at native size still uses the intentional 2x smart zoom.
        unknown.fullPixelsKnown = true
        #expect(FrameZoom().toggled(around: .zero, in: unknown).scale == 2)
    }

    @Test func resizingCanPutAnExplicitZoomBelowFitWithoutEnlargingIt() {
        let previous = room(fitPixels: 2000)
        let zoom = FrameZoom().zoomed(to: 1.1, around: .zero, in: previous).settled(in: previous)
        let wider = room(fitPixels: 4912)
        let changed = zoom.reframed(from: previous, to: wider)
        #expect(changed.scale < 1 && !changed.isFitted)
        #expect(changed.pixels(in: wider) == zoom.pixels(in: previous))
        #expect(changed.stepped(.zoomOut, in: wider) == changed)
        #expect(changed.settled(in: wider) == changed)
        let pinched = changed.zoomed(to: 0.1, around: .zero, in: wider, floor: FrameZoom.pinchFloor)
        #expect(pinched.settled(in: wider) == changed)
        #expect(changed.toggled(around: .zero, in: wider) == FrameZoom())
    }

    @Test func anUnchangedRoomDoesNotSettleAnActivePinch() {
        let pinched = FrameZoom().zoomed(to: 1.7, around: CGPoint(x: 732, y: 440), in: Self.room,
                                        floor: FrameZoom.pinchFloor)
        #expect(pinched.renderedScale == 1)
        #expect(pinched.reframed(from: Self.room, to: Self.room) == pinched)
    }

    @Test func nativeDimensionsArrivingDuringAPinchKeepTheGestureAndItsAnchor() {
        let unknown = room(fitPixels: 2640, fullPixels: 2640)
        let anchor = CGPoint(x: 1000, y: 600)
        let pinched = FrameZoom().zoomed(to: 1.2, around: anchor, in: unknown, floor: FrameZoom.pinchFloor)
        let known = room(fitPixels: 2640)
        let continued = pinched.reframed(from: unknown, to: known)
        #expect(continued == pinched)
        #expect(continued.pixels(in: known) == unknown.fitPixels)
        let ended = continued.settled(in: known)
        #expect(ended.pixels(in: known) == 3168)
        #expect(ended.scale == CGFloat(3168) / 2640)
        // The fit boundary still springs back after the dimensions become known.
        let below = FrameZoom().zoomed(to: 0.8, around: anchor, in: unknown, floor: FrameZoom.pinchFloor)
        #expect(below.reframed(from: unknown, to: known).settled(in: known) == FrameZoom())
        // An ordinary menu zoom also keeps its displayed size when metadata arrives.
        let menu = FrameZoom().stepped(.zoomIn, in: unknown)
        let resolved = menu.reframed(from: unknown, to: known)
        #expect(resolved.scale == menu.scale)
        #expect(resolved.pixels(in: known) == 5280)
    }

    @Test func aSmallerNativeSizeArrivingDuringAPinchAllowsItsNewMinimum() {
        let unknown = room(fitPixels: 4800, fullPixels: 4800)
        let pinched = FrameZoom().zoomed(to: 0.8, around: .zero, in: unknown, floor: FrameZoom.pinchFloor)
        let small = room(fitPixels: 4800, fullPixels: 3504)
        let continued = pinched.reframed(from: unknown, to: small)
        #expect(continued.scale == pinched.scale)
        #expect(continued.offset == pinched.offset)
        #expect(continued.renderedScale == pinched.renderedScale)
        // The old placeholder minimum must not force this gesture back to Fit.
        #expect(continued.settled(in: small).scale == 0.8)
        let below = continued.zoomed(to: 0.1, around: .zero, in: small, floor: FrameZoom.pinchFloor)
        #expect(below.settled(in: small) == FrameZoom().stepped(.actualSize, in: small))
    }

    @Test func theModelZoomsTheShownFrameAndFitsAnother() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-zoom-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        model.frameZoomRoom = Self.room
        // A fitted frame leaves scrolls to others.
        #expect(!model.panFrame(by: CGSize(width: 10, height: 0), ended: true))
        model.zoomFrame(.actualSize)
        #expect(model.frameZoom.pixels(in: Self.room) == 7008)
        #expect(model.panFrame(by: CGSize(width: -40.3, height: 12), ended: true))
        #expect(model.frameZoom.offset.width == -40)
        model.pinchFrame(by: 0.5, at: CGPoint(x: 732, y: 440), ended: false)
        #expect(model.frameZoom.renderedScale == CGFloat(7008) / CGFloat(2640))
        model.pinchFrame(by: 0, at: CGPoint(x: 732, y: 440), ended: true)
        #expect(model.frameZoom.isZoomed)
        model.selection = 3
        #expect(model.frameZoom == FrameZoom())
        model.smartZoomFrame(at: CGPoint(x: 732, y: 440))
        model.closeFrame()
        #expect(model.frameZoom == FrameZoom() && model.frameZoomRoom == nil)
    }
}
