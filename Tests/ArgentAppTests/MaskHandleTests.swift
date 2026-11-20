import ArgentCore
@testable import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// The gradient's arithmetic on the photograph (`MaskHandleModel`, `FrameGeometry`'s `MaskSpace`): at fit, zoomed
/// and panned, portrait, and at device scales 1, 2 and 3, a place on the photograph stays the same place.
@MainActor @Suite struct MaskHandleTests {
    private static func frame(portrait: Bool = false) -> Frame {
        var info = ARWFrameInfo()
        if portrait { info.orientation = .right }
        return Frame(id: 0, url: URL(fileURLWithPath: "/tmp/handles/DSC1.ARW"), info: info)
    }

    /// Every view of a frame that a handle has to survive: each scale and shape, fitted, at actual size and panned.
    private static var views: [(name: String, geometry: FrameGeometry)] {
        var views: [(String, FrameGeometry)] = []
        for scale in [CGFloat(1), 2, 3] {
            for portrait in [false, true] {
                let frame = Self.frame(portrait: portrait), layout = FrameLayout(area: CGSize(width: 1188, height: 756), displayScale: scale)
                let room = layout.zoomRoom(frame, fullPixels: 7008)
                let fit = FrameGeometry.make(layout: layout, zoom: FrameZoom(), room: room, frame: frame, isDeveloping: false)
                var zoom = FrameZoom().stepped(.actualSize, in: room)
                let actual = FrameGeometry.make(layout: layout, zoom: zoom, room: room, frame: frame, isDeveloping: false)
                zoom.offset = CGSize(width: -120, height: 80)
                let panned = FrameGeometry.make(layout: layout, zoom: zoom, room: room, frame: frame, isDeveloping: false)
                let tag = "\(scale)x \(portrait ? "portrait" : "landscape")"
                views += [("fit \(tag)", fit), ("actual \(tag)", actual), ("panned \(tag)", panned)]
            }
        }
        return views
    }

    private static let linear = MaskShape.linear(.init(full: MaskPoint(x: 0.5, y: 0.1), zero: MaskPoint(x: 0.5, y: 0.4)))
    private static let radial = MaskShape.radial(.init(center: MaskPoint(x: 0.5, y: 0.33), semiAxisA: 0.2, semiAxisB: 0.1, angle: 0, feather: 50))

    private func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 1e-3) -> Bool {
        abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
    }

    private func close(_ a: MaskPoint, _ b: MaskPoint, _ tolerance: Float = 1e-5) -> Bool {
        abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
    }

    private func linear(_ shape: MaskShape) throws -> MaskShape.LinearGradient {
        guard case .linear(let g) = shape else { throw Failure.wrongShape }
        return g
    }

    private func radial(_ shape: MaskShape) throws -> MaskShape.RadialGradient {
        guard case .radial(let g) = shape else { throw Failure.wrongShape }
        return g
    }

    private enum Failure: Error { case wrongShape }

    // MARK: MaskSpace

    @Test func aPlaceOnThePictureIsLongSidesFromItsTopLeftInEveryView() {
        for (name, geometry) in Self.views {
            #expect(close(geometry.maskPoint(geometry.picture.origin), MaskPoint(x: 0, y: 0)), "\(name)")
            let far = CGPoint(x: geometry.picture.maxX, y: geometry.picture.maxY)
            #expect(close(geometry.maskPoint(far), geometry.maskExtent), "\(name)")
            // Long-side units on both axes: the same distance on screen is the same distance in the mask.
            let across = geometry.maskPoint(CGPoint(x: geometry.picture.minX + 100, y: geometry.picture.minY))
            let down = geometry.maskPoint(CGPoint(x: geometry.picture.minX, y: geometry.picture.minY + 100))
            #expect(abs(across.x - down.y) < 1e-5, "\(name): not fractions of each side")
            let long = max(geometry.picture.width, geometry.picture.height)
            #expect(abs(CGFloat(across.x) - 100 / long) < 1e-5, "\(name)")
            // There and back.
            for place in [CGPoint(x: 10.5, y: 700.25), geometry.center, CGPoint(x: -40, y: 900)] {
                #expect(close(geometry.point(for: geometry.maskPoint(place)), place), "\(name)")
            }
        }
    }

    /// The same mask point lands on the same part of the photograph whatever the zoom or the display.
    @Test func theSamePointIsTheSamePlaceOnThePictureAtEveryZoomAndScale() {
        let point = MaskPoint(x: 0.25, y: 0.5)
        for portrait in [false, true] {
            let shaped = Self.views.filter { $0.name.contains(portrait ? "portrait" : "landscape") }
            let fractions = shaped.map { $0.geometry.normalized($0.geometry.point(for: point)) }
            for fraction in fractions {
                #expect(abs(fraction.x - fractions[0].x) < 1e-3 && abs(fraction.y - fractions[0].y) < 1e-3)
            }
        }
    }

    /// `MaskSpace.extent`, T2's, is what the picture's rectangle says: 3:2 to within the rounding of its short side.
    @Test func theExtentIsThePicturesOwn() throws {
        for (name, geometry) in Self.views {
            let space = try MaskSpace(width: Int(geometry.picture.width * 3), height: Int(geometry.picture.height * 3))
            #expect(close(geometry.maskExtent, space.extent, 1e-3), "\(name)")
        }
    }

    // MARK: Handles and hits

    @Test func aHandleIsWhereItsShapeSaysInEveryView() throws {
        for (name, geometry) in Self.views {
            let g = try linear(Self.linear)
            let handles = Dictionary(uniqueKeysWithValues: MaskHandleModel.handles(of: Self.linear, in: geometry).map { ($0.handle, $0.point) })
            #expect(close(try #require(handles[.full]), geometry.point(for: g.full)), "\(name)")
            #expect(close(try #require(handles[.zero]), geometry.point(for: g.zero)), "\(name)")
            #expect(close(try #require(handles[.middle]), geometry.point(for: MaskPoint(x: 0.5, y: 0.25))), "\(name)")
        }
    }

    @Test func aRadialHasFiveHandlesThatTurnWithIt() throws {
        let geometry = FrameGeometry(area: CGSize(width: 1000, height: 800), picture: CGRect(x: 0, y: 0, width: 1000, height: 667), displayScale: 2)
        var g = try radial(Self.radial)
        g.angle = .pi / 2
        let handles = Dictionary(uniqueKeysWithValues: MaskHandleModel.handles(of: .radial(g), in: geometry).map { ($0.handle, $0.point) })
        #expect(Set(handles.keys) == [.center, .axisA, .axisB, .rotation, .feather])
        let center = try #require(handles[.center])
        // Turned a quarter, axis A runs down the picture and axis B to its left.
        #expect(close(try #require(handles[.axisA]), CGPoint(x: center.x, y: center.y + 200), 1e-2))
        #expect(close(try #require(handles[.axisB]), CGPoint(x: center.x - 100, y: center.y), 1e-2))
    }

    /// Hit targets are points on screen: 24 across at any zoom, and the nearest wins.
    @Test func aHitIsTheNearestHandleWithinItsRadiusInEveryView() {
        for (name, geometry) in Self.views {
            for (handle, point) in MaskHandleModel.handles(of: Self.radial, in: geometry)
                where CGRect(origin: .zero, size: geometry.area).insetBy(dx: 1, dy: 1).contains(point) {
                #expect(MaskHandleModel.hit(at: point, of: Self.radial, in: geometry) == handle, "\(name) \(handle)")
            }
            let g = geometry.point(for: MaskPoint(x: 0.5, y: 0.25))
            if CGRect(origin: .zero, size: geometry.area).insetBy(dx: 40, dy: 40).contains(g) {
                #expect(MaskHandleModel.hit(at: CGPoint(x: g.x + MaskHandleModel.hitRadius - 1, y: g.y), of: Self.linear, in: geometry) == .middle, "\(name)")
                #expect(MaskHandleModel.hit(at: CGPoint(x: g.x + MaskHandleModel.hitRadius + 1, y: g.y), of: Self.linear, in: geometry) == nil, "\(name)")
            }
        }
    }

    /// What lies between the handles is not a target: a press there still pans a zoomed frame.
    @Test func aPressBetweenTheHandlesTakesNothing() {
        let geometry = FrameGeometry(area: CGSize(width: 1188, height: 756), picture: CGRect(x: 27, y: 0, width: 1134, height: 756), displayScale: 2)
        // On the line from Full to Zero, between Full and the middle.
        let between = geometry.point(for: MaskPoint(x: 0.5, y: 0.175))
        #expect(MaskHandleModel.hit(at: between, of: Self.linear, in: geometry) == nil)
        #expect(MaskHandleModel.hit(at: geometry.point(for: MaskPoint(x: 0.9, y: 0.6)), of: Self.radial, in: geometry) == nil)
    }

    @Test func aHandleOffThePictureCountsUnlessItIsOffTheAreaToo() {
        let geometry = FrameGeometry(area: CGSize(width: 1188, height: 756), picture: CGRect(x: 27, y: 100, width: 1134, height: 556), displayScale: 2)
        // In the surround: a gradient can start above the picture.
        let above = MaskShape.linear(.init(full: MaskPoint(x: 0.5, y: -0.05), zero: MaskPoint(x: 0.5, y: 0.3)))
        let full = geometry.point(for: MaskPoint(x: 0.5, y: -0.05))
        #expect(!geometry.picture.contains(full) && CGRect(origin: .zero, size: geometry.area).contains(full))
        #expect(MaskHandleModel.hit(at: full, of: above, in: geometry) == .full)
        // Past the area: under the dock or off the workspace.
        let lost = MaskShape.linear(.init(full: MaskPoint(x: 0.5, y: 0.9), zero: MaskPoint(x: 0.5, y: 0.3)))
        #expect(MaskHandleModel.hit(at: geometry.point(for: MaskPoint(x: 0.5, y: 0.9)), of: lost, in: geometry) == nil)
    }

    // MARK: Drawing

    @Test func aLinearIsDrawnFromFullToZero() throws {
        let g = try linear(try #require(MaskHandleModel.drawn(.linear, from: MaskPoint(x: 0.2, y: 0.1), to: MaskPoint(x: 0.6, y: 0.5))))
        #expect(close(g.full, MaskPoint(x: 0.2, y: 0.1)) && close(g.zero, MaskPoint(x: 0.6, y: 0.5)))
    }

    @Test func aRadialIsDrawnFromTheCentreOutward() throws {
        let g = try radial(try #require(MaskHandleModel.drawn(.radial, from: MaskPoint(x: 0.5, y: 0.3), to: MaskPoint(x: 0.3, y: 0.4))))
        #expect(close(g.center, MaskPoint(x: 0.5, y: 0.3)))
        #expect(abs(g.semiAxisA - 0.2) < 1e-5 && abs(g.semiAxisB - 0.1) < 1e-5 && g.angle == 0 && g.feather == 50)
    }

    @Test func shiftMakesALinearLevelOrPlumbAndARadialACircle() throws {
        let plumb = try linear(try #require(MaskHandleModel.drawn(.linear, from: MaskPoint(x: 0.2, y: 0.1), to: MaskPoint(x: 0.25, y: 0.5), constrain: true)))
        #expect(plumb.zero.x == plumb.full.x && plumb.zero.y == 0.5)
        let level = try linear(try #require(MaskHandleModel.drawn(.linear, from: MaskPoint(x: 0.2, y: 0.1), to: MaskPoint(x: 0.6, y: 0.12), constrain: true)))
        #expect(level.zero.y == level.full.y && level.zero.x == 0.6)
        let circle = try radial(try #require(MaskHandleModel.drawn(.radial, from: MaskPoint(x: 0.5, y: 0.3), to: MaskPoint(x: 0.6, y: 0.3), constrain: true)))
        #expect(circle.semiAxisA == circle.semiAxisB && abs(circle.semiAxisA - 0.1) < 1e-5)
    }

    /// A circle stays a circle on either shape of picture: the axes are long sides, not fractions of each side.
    @Test func aCircleDrawnOnScreenIsACircleOnAnyPicture() throws {
        for (name, geometry) in Self.views {
            let from = geometry.maskPoint(geometry.center)
            let to = geometry.maskPoint(CGPoint(x: geometry.center.x + 60, y: geometry.center.y + 60))
            let g = try radial(try #require(MaskHandleModel.drawn(.radial, from: from, to: to)))
            #expect(abs(g.semiAxisA - g.semiAxisB) < 1e-4, "\(name)")
        }
    }

    @Test func aDrawOnTheSpotDrawsNothing() {
        let here = MaskPoint(x: 0.5, y: 0.3)
        #expect(MaskHandleModel.drawn(.linear, from: here, to: here) == nil)
        #expect(MaskHandleModel.drawn(.radial, from: here, to: MaskPoint(x: 0.5005, y: 0.3)) == nil)
        #expect(MaskHandleModel.drawn(.brush, from: here, to: MaskPoint(x: 0.9, y: 0.9)) == nil)
    }

    @Test func aFlatDragStillMakesAnEllipseTheKernelCanRead() throws {
        let g = try radial(try #require(MaskHandleModel.drawn(.radial, from: MaskPoint(x: 0.5, y: 0.3), to: MaskPoint(x: 0.8, y: 0.3))))
        #expect(g.semiAxisB == MaskHandleModel.minimumExtent && abs(g.semiAxisA - 0.3) < 1e-5)
        #expect(throws: Never.self) { _ = try MaskSet(masks: [Mask(components: [MaskComponent(shape: .radial(g))])]) }
    }

    @Test func theKeyboardsPlaceIsOnThePictureOfEitherShape() throws {
        for extent in [MaskPoint(x: 1, y: 2.0 / 3), MaskPoint(x: 2.0 / 3, y: 1)] {
            let g = try linear(try #require(MaskHandleModel.placed(.linear, extent: extent)))
            #expect(g.full.y == 0 && abs(g.zero.y - extent.y / 2) < 1e-5 && abs(g.full.x - extent.x / 2) < 1e-5)
            let r = try radial(try #require(MaskHandleModel.placed(.radial, extent: extent)))
            #expect(close(r.center, MaskPoint(x: extent.x / 2, y: extent.y / 2)))
        }
        #expect(MaskHandleModel.placed(.brush, extent: MaskPoint(x: 1, y: 1)) == nil)
    }

    // MARK: Dragging

    @Test func noMovementChangesNothing() throws {
        let at = MaskPoint(x: 0.4, y: 0.4)
        for handle in [MaskHandle.full, .zero, .middle] {
            #expect(MaskHandleModel.dragged(handle, start: Self.linear, from: at, to: at) == Self.linear, "\(handle)")
        }
        for handle in [MaskHandle.center, .axisA, .axisB, .rotation] {
            #expect(MaskHandleModel.dragged(handle, start: Self.radial, from: at, to: at) == Self.radial, "\(handle)")
        }
    }

    /// A drag moves the handle by the pointer's movement, so a press beside it does not make it jump.
    @Test func aLinearsPointsMoveAloneAndItsMiddleMovesItWhole() throws {
        let from = MaskPoint(x: 0.51, y: 0.12), to = MaskPoint(x: 0.61, y: 0.22)
        let full = try linear(MaskHandleModel.dragged(.full, start: Self.linear, from: from, to: to))
        #expect(close(full.full, MaskPoint(x: 0.6, y: 0.2)) && close(full.zero, MaskPoint(x: 0.5, y: 0.4)))
        let zero = try linear(MaskHandleModel.dragged(.zero, start: Self.linear, from: from, to: to))
        #expect(close(zero.zero, MaskPoint(x: 0.6, y: 0.5)) && close(zero.full, MaskPoint(x: 0.5, y: 0.1)))
        let whole = try linear(MaskHandleModel.dragged(.middle, start: Self.linear, from: from, to: to))
        #expect(close(whole.full, MaskPoint(x: 0.6, y: 0.2)) && close(whole.zero, MaskPoint(x: 0.6, y: 0.5)))
    }

    @Test func aGradientMovedWholeKeepsItsShapeAtTheLimit() throws {
        let start = try linear(Self.linear)
        let moved = try linear(MaskHandleModel.dragged(.middle, start: Self.linear, from: MaskPoint(x: 0, y: 0), to: MaskPoint(x: 0, y: 9)))
        #expect(close(MaskPoint(x: moved.zero.x - moved.full.x, y: moved.zero.y - moved.full.y), MaskPoint(x: start.zero.x - start.full.x, y: start.zero.y - start.full.y)))
        #expect(moved.zero.y <= MaskHandleModel.positionRange.upperBound)
    }

    @Test func fullNeverLandsOnZero() throws {
        let g = try linear(Self.linear)
        let dragged = try linear(MaskHandleModel.dragged(.full, start: Self.linear, from: g.full, to: g.zero))
        let span = hypot(dragged.zero.x - dragged.full.x, dragged.zero.y - dragged.full.y)
        #expect(span >= MaskHandleModel.minimumExtent * 0.99)
        #expect(throws: Never.self) { _ = try MaskSet(masks: [Mask(components: [MaskComponent(shape: .linear(dragged))])]) }
    }

    @Test func aRadialsHandlesEachChangeOneThing() throws {
        let start = try radial(Self.radial)
        let from = MaskPoint(x: 0.7, y: 0.33)
        let center = try radial(MaskHandleModel.dragged(.center, start: Self.radial, from: from, to: MaskPoint(x: 0.8, y: 0.43)))
        #expect(close(center.center, MaskPoint(x: 0.6, y: 0.43)) && center.semiAxisA == start.semiAxisA && center.semiAxisB == start.semiAxisB)
        let a = try radial(MaskHandleModel.dragged(.axisA, start: Self.radial, from: from, to: MaskPoint(x: 0.8, y: 0.5)))
        #expect(abs(a.semiAxisA - 0.3) < 1e-5 && a.semiAxisB == start.semiAxisB && a.center == start.center && a.angle == start.angle)
        let b = try radial(MaskHandleModel.dragged(.axisB, start: Self.radial, from: MaskPoint(x: 0.5, y: 0.43), to: MaskPoint(x: 0.9, y: 0.53)))
        #expect(abs(b.semiAxisB - 0.2) < 1e-5 && b.semiAxisA == start.semiAxisA)
        let turned = try radial(MaskHandleModel.dragged(.rotation, start: Self.radial, from: MaskPoint(x: 0.5, y: 0.1), to: MaskPoint(x: 0.73, y: 0.33)))
        #expect(abs(turned.angle - .pi / 2) < 1e-4 && turned.semiAxisA == start.semiAxisA && turned.semiAxisB == start.semiAxisB && turned.feather == start.feather)
    }

    /// On a turned ellipse a drag acts along the axis, not along the screen.
    @Test func anAxisDragFollowsTheAxisOfATurnedEllipse() throws {
        var g = try radial(Self.radial)
        g.angle = .pi / 2
        let along = try radial(MaskHandleModel.dragged(.axisA, start: .radial(g), from: MaskPoint(x: 0.5, y: 0.5), to: MaskPoint(x: 0.5, y: 0.6)))
        #expect(abs(along.semiAxisA - 0.3) < 1e-4)
        let across = try radial(MaskHandleModel.dragged(.axisA, start: .radial(g), from: MaskPoint(x: 0.5, y: 0.5), to: MaskPoint(x: 0.6, y: 0.5)))
        #expect(abs(across.semiAxisA - 0.2) < 1e-4)
    }

    @Test func theFeatherHandleSetsFeatherFromItsOwnPlace() throws {
        for feather in [Float(0), 25, 50, 100] {
            #expect(MaskHandleModel.featherValue(atPosition: MaskHandleModel.featherPosition(feather)) == feather)
        }
        var g = try radial(Self.radial)
        g.feather = 50
        // The handle stands on the side opposite axis A: toward the centre feathers more, away less.
        let inward = try radial(MaskHandleModel.dragged(.feather, start: .radial(g), from: MaskPoint(x: 0.38, y: 0.33), to: MaskPoint(x: 0.40, y: 0.33)))
        #expect(inward.feather > 50 && inward.center == g.center && inward.semiAxisA == g.semiAxisA)
        let outward = try radial(MaskHandleModel.dragged(.feather, start: .radial(g), from: MaskPoint(x: 0.38, y: 0.33), to: MaskPoint(x: 0.36, y: 0.33)))
        #expect(outward.feather < 50)
        let far = try radial(MaskHandleModel.dragged(.feather, start: .radial(g), from: MaskPoint(x: 0.38, y: 0.33), to: MaskPoint(x: -3, y: 0.33)))
        #expect(far.feather == 0)
        let through = try radial(MaskHandleModel.dragged(.feather, start: .radial(g), from: MaskPoint(x: 0.38, y: 0.33), to: MaskPoint(x: 3, y: 0.33)))
        #expect(through.feather == 100)
    }

    /// However far a pointer goes, what comes out is a mask T2's validation takes.
    @Test func everyDragStaysValid() throws {
        let extremes = [MaskPoint(x: -40, y: -40), MaskPoint(x: 40, y: 40), MaskPoint(x: 0.5, y: 0.33), MaskPoint(x: 0, y: 40)]
        for to in extremes {
            for handle in [MaskHandle.full, .zero, .middle] {
                let shape = MaskHandleModel.dragged(handle, start: Self.linear, from: MaskPoint(x: 0.5, y: 0.25), to: to)
                #expect(throws: Never.self) { _ = try MaskSet(masks: [Mask(components: [MaskComponent(shape: shape)])]) }
            }
            for handle in [MaskHandle.center, .axisA, .axisB, .rotation, .feather] {
                let shape = MaskHandleModel.dragged(handle, start: Self.radial, from: MaskPoint(x: 0.5, y: 0.25), to: to)
                #expect(throws: Never.self) { _ = try MaskSet(masks: [Mask(components: [MaskComponent(shape: shape)])]) }
            }
            for tool in [MaskEditor.Tool.linear, .radial] {
                if let shape = MaskHandleModel.drawn(tool, from: MaskPoint(x: 0.5, y: 0.25), to: to) {
                    #expect(throws: Never.self) { _ = try MaskSet(masks: [Mask(components: [MaskComponent(shape: shape)])]) }
                }
            }
        }
    }

    @Test func aBrushOrASeedHasNoHandlesYet() throws {
        let smart = MaskShape.smart(SmartSelection(kind: .sky))
        let geometry = try #require(Self.views.first?.geometry)
        #expect(MaskHandleModel.handles(of: smart, in: geometry).isEmpty)
        #expect(MaskHandleModel.hit(at: geometry.center, of: smart, in: geometry) == nil)
        #expect(MaskHandleModel.dragged(.full, start: smart, from: MaskPoint(x: 0, y: 0), to: MaskPoint(x: 1, y: 1)) == smart)
    }

    // MARK: The panel's numbers

    @Test func eachShapeHasItsNumbersAndTheyReadAndWriteBack() throws {
        #expect(MaskShapeField.fields(of: Self.linear) == [.fullX, .fullY, .zeroX, .zeroY])
        #expect(MaskShapeField.fields(of: Self.radial) == [.feather, .centerX, .centerY, .width, .height, .angle])
        #expect(MaskShapeField.fields(of: .smart(SmartSelection(kind: .sky))) == [.selectionFeather])
        for (field, shape, number) in [(MaskShapeField.fullX, Self.linear, Float(50)), (.fullY, Self.linear, 10), (.zeroX, Self.linear, 50), (.zeroY, Self.linear, 40),
                                       (.centerX, Self.radial, 50), (.centerY, Self.radial, 33), (.width, Self.radial, 20), (.height, Self.radial, 10),
                                       (.angle, Self.radial, 0), (.feather, Self.radial, 50)] {
            #expect(abs((field.value(in: shape) ?? .nan) - number) < 1e-3, "\(field)")
            let written = try #require(field.setting(number + 7, in: shape), "\(field)")
            #expect(abs((field.value(in: written) ?? .nan) - number - 7) < 1e-3, "\(field)")
            #expect(field.tool == (shape == Self.linear ? .linear : .radial), "\(field)")
        }
        // One shape's number does not read on the other.
        #expect(MaskShapeField.fullX.value(in: Self.radial) == nil && MaskShapeField.width.value(in: Self.linear) == nil)
        #expect(MaskShapeField.fullX.setting(10, in: Self.radial) == nil)
    }

    /// A smart selection's one number is its Feather (decision 19): a row like the radial's, 0 to 100, resetting to 0, headed by the
    /// selection's kind, its own undo name, and no tool places it. It reads and writes the selection's feather and nothing else.
    @Test func aSelectionsNumberIsItsFeather() throws {
        let sky = MaskShape.smart(SmartSelection(kind: .sky, feather: 20))
        let field = MaskShapeField.selectionFeather
        #expect(field.value(in: sky) == 20 && field.value(in: Self.radial) == nil && MaskShapeField.feather.value(in: sky) == nil)
        #expect(field.setting(65, in: sky) == .smart(SmartSelection(kind: .sky, feather: 65)))
        #expect(field.setting(140, in: sky) == .smart(SmartSelection(kind: .sky, feather: 100)) && field.setting(-3, in: sky) == .smart(SmartSelection(kind: .sky)))
        #expect(field.setting(.nan, in: sky) == nil && field.setting(30, in: Self.radial) == nil)
        #expect(field.tool == nil && field.title == "Feather")
        let spec = field.spec(default: nil, order: 10)
        #expect(spec.range == 0...100 && spec.defaultValue == 0 && spec.step == 1 && spec.group == .mask && spec.order == 10 && spec.title == "Feather")
        #expect(spec.smallKeyStep == MaskShapeField.feather.spec(default: nil, order: 10).smallKeyStep
                && spec.largeKeyStep == MaskShapeField.feather.spec(default: nil, order: 10).largeKeyStep)
        #expect(MaskShapeField.heading(of: sky) == "Sky" && MaskShapeField.heading(of: Self.radial) == "Radial gradient"
                && MaskShapeField.heading(of: Self.linear) == "Linear gradient")
        #expect(MaskShapeField.actionName(of: sky) == "Feather Mask" && MaskShapeField.actionName(of: Self.radial) == "Adjust Gradient")
        // Every kind has it, Background too.
        for kind in SmartKind.allCases { #expect(MaskShapeField.fields(of: .smart(SmartSelection(kind: kind))) == [.selectionFeather]) }
    }

    @Test func aNumberThatMakesNoGradientIsRefused() throws {
        let g = try linear(Self.linear)
        // Full typed onto Zero.
        var onZero = MaskShape.linear(.init(full: MaskPoint(x: g.zero.x, y: 0.1), zero: g.zero))
        #expect(MaskShapeField.fullY.setting(g.zero.y * 100, in: onZero) == nil)
        onZero = MaskShapeField.fullY.setting(5, in: onZero) ?? onZero
        #expect(MaskShapeField.fullY.value(in: onZero) == 5)
        #expect(MaskShapeField.fullX.setting(.nan, in: Self.linear) == nil)
        // A size is held at what a gesture can make, not refused.
        let thin = try radial(try #require(MaskShapeField.width.setting(0, in: Self.radial)))
        #expect(thin.semiAxisA == MaskHandleModel.minimumExtent)
    }

    @Test func theNumbersRowsAreTheMasksGroupsAfterItsSeven() throws {
        let placed = MaskHandleModel.placed(.radial, extent: MaskPoint(x: 1, y: 2.0 / 3))
        let spec = MaskShapeField.centerX.spec(default: placed, order: 11)
        #expect(spec.group == .mask && spec.order == 11 && spec.title == "Centre X")
        // A position's reset is the placed gradient's, since no position means no change.
        #expect(spec.defaultValue == 50 && spec.range == -100...200)
        #expect(MaskShapeField.feather.spec(default: placed, order: 10).range == 0...100 && MaskShapeField.feather.spec(default: placed, order: 10).defaultValue == 50)
        #expect(MaskShapeField.angle.spec(default: placed, order: 12).range == -180...180 && MaskShapeField.angle.spec(default: placed, order: 12).unit == "°")
        // A number on the row's resolution reads back as it is, so a field left alone commits no change.
        #expect(spec.snapped(spec.formatted(spec.snapped(33.34)).floatValue) == spec.snapped(33.34))
    }
}

private extension String {
    var floatValue: Float { Float(self) ?? .nan }
}
