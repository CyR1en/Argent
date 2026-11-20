import ArgentCore
@testable import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// Where the photograph is drawn (`FrameGeometry`): the one rectangle the pictures, the divider and the
/// mask canvas use, and a pointer's place on the photograph read from it.
@MainActor @Suite struct FrameGeometryTests {
    private static func frame(portrait: Bool = false) -> Frame {
        var info = ARWFrameInfo()
        if portrait { info.orientation = .right }
        return Frame(id: 0, url: URL(fileURLWithPath: "/tmp/geometry/DSC1.ARW"), info: info)
    }

    /// `FramePicture`'s arithmetic as it stood before it moved, restated: what must not change.
    private static func drawnBeforeTheMove(layout: FrameLayout, zoom: FrameZoom, room: FrameZoom.Room, frame: Frame,
                                           isDeveloping: Bool, film: CGSize?, neutral: CGSize?) -> CGRect {
        let fitPixels = layout.pixels(frame)
        let pixels = isDeveloping ? fitPixels : zoom.pixels(in: room)
        var box = layout.box(frame, pixels: pixels)
        for image in [film, neutral].compactMap({ $0 }) where Int(max(image.width, image.height)) == pixels {
            box = CGSize(width: image.width / layout.displayScale, height: image.height / layout.displayScale)
            break
        }
        let scale = zoom.scale / (CGFloat(pixels) / CGFloat(fitPixels))
        let shown = CGSize(width: box.width * scale, height: box.height * scale)
        let fitted = layout.center(of: shown)
        let center = CGPoint(x: fitted.x + zoom.offset.width, y: fitted.y + zoom.offset.height)
        return CGRect(x: center.x - shown.width / 2, y: center.y - shown.height / 2, width: shown.width, height: shown.height)
    }

    /// The worked example: a landscape frame in a 1188 by 756 area at 2×, of a raw 7008 pixels long.
    private static let area = CGSize(width: 1188, height: 756)

    private func setup(area: CGSize = area, scale: CGFloat = 2, portrait: Bool = false, fullPixels: Int = 7008)
        -> (FrameLayout, FrameZoom.Room, Frame) {
        let frame = Self.frame(portrait: portrait), layout = FrameLayout(area: area, displayScale: scale)
        return (layout, layout.zoomRoom(frame, fullPixels: fullPixels), frame)
    }

    private func make(_ layout: FrameLayout, _ zoom: FrameZoom, _ room: FrameZoom.Room, _ frame: Frame,
                      isDeveloping: Bool = false, rendered: [CGSize] = []) -> FrameGeometry {
        FrameGeometry.make(layout: layout, zoom: zoom, room: room, frame: frame, isDeveloping: isDeveloping, rendered: rendered)
    }

    private func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 1e-9) -> Bool {
        abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
    }

    @Test func fittedAndAtActualSizeTheWorkedExampleLandsWhereItIsDrawn() {
        let (layout, room, frame) = setup()
        let fit = make(layout, FrameZoom(), room, frame)
        #expect(fit.picture == CGRect(x: 27, y: 0, width: 1134, height: 756))
        #expect(fit.area == Self.area && fit.displayScale == 2 && fit.longSide == 1134)
        #expect(close(fit.normalized(CGPoint(x: 594, y: 378)), CGPoint(x: 0.5, y: 0.5)))
        #expect(!fit.canPan)

        // 7008 device pixels at 2×: the render one to one.
        let actual = make(layout, FrameZoom().stepped(.actualSize, in: room), room, frame)
        #expect(actual.picture == CGRect(x: -1158, y: -790, width: 3504, height: 2336))
        #expect(close(actual.normalized(CGPoint(x: 594, y: 378)), CGPoint(x: 0.5, y: 0.5)))
        #expect(actual.canPan)
    }

    /// Every window, display, orientation and zoom of the grid draws where `FramePicture` drew before.
    @Test(arguments: [CGFloat(1), 2, 3])
    func theRectangleIsTheOneDrawnBeforeTheMove(scale: CGFloat) {
        let areas = [CGSize(width: 1188, height: 756), CGSize(width: 1214, height: 710), CGSize(width: 436, height: 410),
                     CGSize(width: 1579, height: 1025), CGSize(width: 817.5, height: 643.25), CGSize(width: 1320, height: 880)]
        for area in areas {
            for portrait in [false, true] {
                for fullPixels in [3840, 7008] {
                    let (layout, room, frame) = setup(area: area, scale: scale, portrait: portrait, fullPixels: fullPixels)
                    let anchor = CGPoint(x: area.width * 0.3, y: area.height * 0.7)
                    let zooms: [FrameZoom] = [
                        FrameZoom(),
                        FrameZoom().stepped(.actualSize, in: room),
                        FrameZoom().zoomed(to: 1.05, around: anchor, in: room),
                        FrameZoom().zoomed(to: 1.6123, around: anchor, in: room),
                        FrameZoom().zoomed(to: 1.6123, around: anchor, in: room).settled(in: room),
                        FrameZoom().zoomed(to: 2.5, around: anchor, in: room).settled(in: room).panned(by: CGSize(width: -77.5, height: 41), in: room),
                        FrameZoom().zoomed(to: room.maximumScale, around: anchor, in: room).settled(in: room),
                    ]
                    for zoom in zooms {
                        let pixels = zoom.pixels(in: room)
                        let exact = CGSize(width: portrait ? (2 * pixels + 2) / 3 : pixels, height: portrait ? pixels : (2 * pixels + 2) / 3)
                        let cases: [(film: CGSize?, neutral: CGSize?, developing: Bool)] = [
                            (nil, nil, false), (exact, nil, false), (nil, exact, false), (exact, exact, true),
                            (CGSize(width: exact.width - 1, height: exact.height), nil, false),
                            (CGSize(width: 512, height: 341), nil, false),
                        ]
                        for (film, neutral, developing) in cases {
                            let rendered = [film, neutral].compactMap { $0 }
                            let new = make(layout, zoom, room, frame, isDeveloping: developing, rendered: rendered).picture
                            let old = Self.drawnBeforeTheMove(layout: layout, zoom: zoom, room: room, frame: frame,
                                                              isDeveloping: developing, film: film, neutral: neutral)
                            #expect(new == old)
                        }
                    }
                }
            }
        }
    }

    @Test func aPointerMapsThroughTheDrawnPictureAndBack() {
        for scale in [CGFloat(1), 2, 3] {
            for portrait in [false, true] {
                let (layout, room, frame) = setup(scale: scale, portrait: portrait)
                let zooms = [FrameZoom(), FrameZoom().stepped(.actualSize, in: room),
                             FrameZoom().zoomed(to: 2.5, around: CGPoint(x: 300, y: 200), in: room).panned(by: CGSize(width: 40, height: -30), in: room)]
                for zoom in zooms {
                    let geometry = make(layout, zoom, room, frame)
                    let picture = geometry.picture
                    #expect(close(geometry.normalized(picture.origin), .zero))
                    #expect(close(geometry.normalized(CGPoint(x: picture.maxX, y: picture.maxY)), CGPoint(x: 1, y: 1)))
                    for fractions in [CGPoint(x: 0.25, y: 0.75), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 0), CGPoint(x: -0.1, y: 1.2)] {
                        #expect(close(geometry.normalized(geometry.point(forNormalized: fractions)), fractions, 1e-6))
                    }
                }
            }
        }
    }

    @Test func aPortraitFrameIsUprightAndItsLongSideIsItsHeight() {
        let (layout, room, frame) = setup(portrait: true)
        let geometry = make(layout, FrameZoom(), room, frame)
        // 756 points tall at 2×, two thirds of it wide, centred on a whole device pixel.
        #expect(geometry.picture.height == 756 && geometry.picture.width == 504)
        #expect(geometry.picture.minY == 0 && geometry.picture.minX == 342)
        #expect(geometry.longSide == 756)
        // Top left is the frame's top left as it is seen, not as it was shot.
        #expect(close(geometry.normalized(CGPoint(x: 342, y: 0)), .zero))
    }

    @Test func aPannedPictureCarriesThePointerWithIt() {
        let (layout, room, frame) = setup()
        let zoomed = FrameZoom().stepped(.actualSize, in: room)
        let before = make(layout, zoomed, room, frame)
        let moved = make(layout, zoomed.panned(by: CGSize(width: 100, height: 50), in: room), room, frame)
        #expect(moved.picture.minX == before.picture.minX + 100 && moved.picture.minY == before.picture.minY + 50)
        // The same place on the picture is 100 and 50 points on in the area.
        let place = CGPoint(x: 0.4, y: 0.6), a = before.point(forNormalized: place), b = moved.point(forNormalized: place)
        #expect(close(CGPoint(x: b.x - a.x, y: b.y - a.y), CGPoint(x: 100, y: 50)))
    }

    /// A film or a refinement of it arriving must not move what the pointer is over.
    @Test func aRenderLandingAtItsSizeDoesNotMoveThePicture() {
        for portrait in [false, true] {
            let (layout, room, frame) = setup(area: CGSize(width: 1579, height: 1025), portrait: portrait)
            for zoom in [FrameZoom(), FrameZoom().stepped(.actualSize, in: room)] {
                let pixels = zoom.pixels(in: room)
                let short = (2 * pixels + 2) / 3
                let film = portrait ? CGSize(width: short, height: pixels) : CGSize(width: pixels, height: short)
                let waiting = make(layout, zoom, room, frame)
                #expect(make(layout, zoom, room, frame, rendered: [film]) == waiting)
                #expect(make(layout, zoom, room, frame, rendered: [film, film]) == waiting)
            }
        }
    }

    @Test func aRenderOfAnotherSizeTakesTheBoxAndOneOfThisSizeIsShownOneToOne() {
        let (layout, room, frame) = setup()
        let box = make(layout, FrameZoom(), room, frame).picture
        // The last render of a resize or a zoom: scaled to the box.
        #expect(make(layout, FrameZoom(), room, frame, rendered: [CGSize(width: 1024, height: 683)]).picture == box)
        // One of this long side but a pixel shorter the other way is shown as it is, not stretched.
        let oneShort = make(layout, FrameZoom(), room, frame, rendered: [CGSize(width: 2268, height: 1511)]).picture
        #expect(oneShort.width == 1134 && oneShort.height == 755.5)
        // The film's size wins over the neutral raw's.
        let two = make(layout, FrameZoom(), room, frame, rendered: [CGSize(width: 2268, height: 1511), CGSize(width: 2268, height: 1512)])
        #expect(two.picture.height == 755.5)
    }

    @Test func aDevelopScalesTheFittedRenderInsteadOfALargerDecode() {
        let (layout, room, frame) = setup()
        let zoom = FrameZoom().stepped(.actualSize, in: room)
        #expect(FrameGeometry.renderPixels(layout: layout, zoom: zoom, room: room, frame: frame, isDeveloping: true) == 2268)
        #expect(FrameGeometry.renderPixels(layout: layout, zoom: zoom, room: room, frame: frame, isDeveloping: false) == 7008)
        let developing = make(layout, zoom, room, frame, isDeveloping: true)
        #expect(abs(developing.picture.width - 3504) < 1e-6 && abs(developing.picture.height - 2336) < 1e-6)
    }

    @Test func aResizeKeepsThePlaceOnThePicture() {
        // A place on the photograph is the same fractions whatever the window: what makes a mask's
        // points survive a resize.
        let place = CGPoint(x: 0.31, y: 0.62)
        let a = make(FrameLayout(area: CGSize(width: 1188, height: 756), displayScale: 2), FrameZoom(), setup().1, Self.frame())
        let small = setup(area: CGSize(width: 700, height: 500))
        let b = make(small.0, FrameZoom(), small.1, small.2)
        #expect(a.picture != b.picture)
        #expect(close(a.normalized(a.point(forNormalized: place)), b.normalized(b.point(forNormalized: place))))
        // The picture's own shape is what scales between them.
        #expect(abs(a.picture.width / a.picture.height - b.picture.width / b.picture.height) < 0.01)
    }

    @Test func theAreaShowsOnlyPartOfAZoomedPicture() {
        let (layout, room, frame) = setup()
        let fit = make(layout, FrameZoom(), room, frame)
        #expect(fit.visiblePicture == fit.picture)
        let actual = make(layout, FrameZoom().stepped(.actualSize, in: room), room, frame)
        #expect(actual.visiblePicture == CGRect(origin: .zero, size: Self.area))
        // A picture too small for the area never pans; one over it on one side does.
        #expect(!FrameGeometry(area: Self.area, picture: CGRect(x: 27, y: 0, width: 1134, height: 756.4), displayScale: 2).canPan)
        #expect(FrameGeometry(area: Self.area, picture: CGRect(x: 27, y: -20, width: 1134, height: 796), displayScale: 2).canPan)
    }

    @Test func aPictureOfNoSizeHasNoPlaces() {
        let empty = FrameGeometry(area: Self.area, picture: .zero, displayScale: 2)
        #expect(empty.normalized(CGPoint(x: 5, y: 5)) == .zero)
    }

    @Test func theSplitComparisonComposesTheGeometry() {
        let (layout, room, frame) = setup()
        let geometry = make(layout, FrameZoom(), room, frame)
        var split = SplitGeometry(geometry)
        #expect(split.frame == geometry)
        #expect(split == SplitGeometry(area: Self.area, picture: CGRect(x: 27, y: 0, width: 1134, height: 756), displayScale: 2))
        #expect(split.dividerX(at: 0.5) == 594 && split.neutralWidth(at: 0.5) == 567)
        // Moving the split's picture moves the geometry it holds.
        split.picture.origin.x = -500
        #expect(split.frame.picture.minX == -500)
    }
}
