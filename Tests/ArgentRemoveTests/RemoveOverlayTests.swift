import ArgentCore
@testable import ArgentRoll
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ArgentApp

/// Remove on the photograph (docs/remove-plan.md, section 4.8): where a coverage and a stroke land on the picture as drawn, at a
/// zoom and a pan; the edge found on a coverage; and when a new film is a removal's change of the picture.
@MainActor @Suite struct RemoveOverlayTests {
    private static let area = CGSize(width: 1188, height: 756)

    private static func frame() -> Frame {
        Frame(id: 0, url: URL(fileURLWithPath: "/tmp/remove-overlay/DSC1.ARW"), info: ARWFrameInfo())
    }

    /// The frame view's geometry fitted, and zoomed in about a point and panned, as `FrameGeometryTests` makes them.
    private func geometries() -> (fit: FrameGeometry, zoomed: FrameGeometry) {
        let frame = Self.frame(), layout = FrameLayout(area: Self.area, displayScale: 2)
        let room = layout.zoomRoom(frame, fullPixels: 7008)
        let zoom = FrameZoom().zoomed(to: 2.5, around: CGPoint(x: 356, y: 529), in: room).settled(in: room)
            .panned(by: CGSize(width: -77.5, height: 41), in: room)
        return (FrameGeometry.make(layout: layout, zoom: FrameZoom(), room: room, frame: frame, isDeveloping: false),
                FrameGeometry.make(layout: layout, zoom: zoom, room: room, frame: frame, isDeveloping: false))
    }

    private func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 1e-9) -> Bool { abs(a - b) < tolerance }

    private func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 1e-9) -> Bool {
        close(a.x, b.x, tolerance) && close(a.y, b.y, tolerance)
    }

    // MARK: Where it lands

    /// A removal's outline is its patch's box, smaller than the picture: it lies on that part of the photograph, fitted and at a
    /// zoom and a pan.
    @Test func aCoverageSmallerThanThePictureLandsOnItsPartOfThePhotograph() {
        let coverage = RemoveCoverage(width: 4, height: 8, values: [UInt8](repeating: 255, count: 32),
                                      frame: CGRect(x: 0.25, y: 0.5, width: 0.2, height: 0.25))
        let (fit, zoomed) = geometries()
        // The worked example: the picture 1134 by 756 from (27, 0).
        #expect(fit.picture == CGRect(x: 27, y: 0, width: 1134, height: 756))
        let fitted = RemoveOverlayGeometry.rect(of: coverage.frame, in: fit)
        #expect(close(fitted.minX, 27 + 283.5) && close(fitted.minY, 378) && close(fitted.width, 226.8) && close(fitted.height, 189))
        // Zoomed and panned, the picture runs past the area, and the coverage keeps its part of it.
        #expect(zoomed.picture != fit.picture && zoomed.picture.width > 2 * fit.picture.width && zoomed.canPan)
        let moved = RemoveOverlayGeometry.rect(of: coverage.frame, in: zoomed)
        #expect(close(moved.origin, zoomed.point(forNormalized: CGPoint(x: 0.25, y: 0.5))))
        #expect(close(CGPoint(x: moved.maxX, y: moved.maxY), zoomed.point(forNormalized: CGPoint(x: 0.45, y: 0.75)), 1e-6))
        #expect(close(moved.width, 0.2 * zoomed.picture.width) && close(moved.height, 0.25 * zoomed.picture.height))
        // And back: the rectangle's corners are the coverage's box on the picture.
        #expect(close(zoomed.normalized(moved.origin), CGPoint(x: 0.25, y: 0.5)))
        // The whole picture's coverage is the picture.
        #expect(RemoveOverlayGeometry.rect(of: RemoveCoverage(width: 1, height: 1, values: [255]).frame, in: zoomed) == zoomed.picture)
    }

    @Test func aStrokesPointsAndItsWidthFollowThePicture() {
        let stroke = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1), CGPoint(x: 1.1, y: -0.2)]
        let (fit, zoomed) = geometries()
        #expect(RemoveOverlayGeometry.points(of: stroke, in: fit)
                == [CGPoint(x: 27, y: 0), CGPoint(x: 594, y: 378), CGPoint(x: 1161, y: 756), CGPoint(x: 27 + 1.1 * 1134, y: -0.2 * 756)])
        let moved = RemoveOverlayGeometry.points(of: stroke, in: zoomed)
        #expect(moved.count == stroke.count)
        for (point, fraction) in zip(moved, stroke) {
            #expect(close(zoomed.normalized(point), fraction))
        }
        #expect(close(moved[0], zoomed.picture.origin) && close(moved[2], CGPoint(x: zoomed.picture.maxX, y: zoomed.picture.maxY), 1e-6))
        // A brush of size 4 is 4 hundredths of the long side across: the ring's diameter, which grows with the zoom.
        #expect(close(RemoveOverlayGeometry.strokeWidth(size: 4, in: fit), 0.04 * 1134))
        #expect(close(RemoveOverlayGeometry.strokeWidth(size: 4, in: zoomed), 0.04 * zoomed.longSide))
        #expect(close(RemovePhotograph.brushRadius(size: 4), 0.02) && close(RemovePhotograph.brushRadius(size: 10), 0.05))
        // Inside the range the masks' brush keeps to.
        #expect(RemovePhotograph.brushRadius(size: 400) == CGFloat(MaskSpace.brushRadiusRange.upperBound))
        #expect(RemovePhotograph.brushRadius(size: 0) == CGFloat(MaskSpace.brushRadiusRange.lowerBound))
        #expect(RemovePhotograph.size(Float(4.1)) == 4.1 && RemovePhotograph.size(Float(0.2)) == 0.2)
    }

    /// A split comparison's neutral side shows neither the tint nor the removal.
    @Test func theOverlayKeepsToTheFilmSideOfASplit() {
        let (fit, _) = geometries()
        #expect(RemoveOverlayGeometry.filmSide(of: fit, neutralWidth: nil) == fit.picture)
        #expect(RemoveOverlayGeometry.filmSide(of: fit, neutralWidth: 400) == CGRect(x: 427, y: 0, width: 734, height: 756))
        #expect(RemoveOverlayGeometry.filmSide(of: fit, neutralWidth: 5000).width == 0)
    }

    // MARK: The edge

    private nonisolated static func coverage(width: Int, height: Int, frame: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                                             inside: (Int, Int) -> Bool) -> RemoveCoverage {
        var values = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width where inside(x, y) { values[y * width + x] = 255 }
        }
        return RemoveCoverage(width: width, height: height, values: values, frame: frame)
    }

    private static func bounds(_ loop: [CGPoint]) -> CGRect {
        let xs = loop.map(\.x), ys = loop.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    @Test func aBlocksEdgeIsOneClosedLoopRoundIt() {
        // Columns 10 to 29 and rows 20 to 39 of 100 by 80.
        let block = Self.coverage(width: 100, height: 80) { x, y in (10..<30).contains(x) && (20..<40).contains(y) }
        let loops = RemoveOutline.loops(of: block)
        #expect(loops.count == 1)
        let box = Self.bounds(try! #require(loops.first))
        // The edge crosses one half between the last pixel outside and the first inside: at the pixels' shared side.
        #expect(close(box.minX, 0.10, 1e-6) && close(box.maxX, 0.30, 1e-6) && close(box.minY, 0.25, 1e-6) && close(box.maxY, 0.50, 1e-6))
        #expect(loops[0].allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        // The path is the loop, rounded, inside the same box.
        let path = RemoveOutline.path(of: loops)
        #expect(!path.isEmpty && box.insetBy(dx: -1e-6, dy: -1e-6).contains(path.boundingRect))
    }

    @Test func twoObjectsHaveTwoLoopsAndNothingHasNone() {
        let two = Self.coverage(width: 64, height: 64) { x, y in ((4..<20).contains(x) || (40..<60).contains(x)) && (8..<30).contains(y) }
        #expect(RemoveOutline.loops(of: two).count == 2)
        #expect(RemoveOutline.loops(of: Self.coverage(width: 16, height: 16) { _, _ in false }).isEmpty)
        #expect(RemoveOutline.path(of: []).isEmpty)
        // A raster whose values are not its size is drawn as nothing.
        #expect(RemoveOutline.loops(of: RemoveCoverage(width: 4, height: 4, values: [255])).isEmpty)
        #expect(RemovePicture.make(RemoveCoverage(width: 4, height: 4, values: [255])).tint == nil)
        // A hole is an edge too.
        let ring = Self.coverage(width: 64, height: 64) { x, y in
            (8..<56).contains(x) && (8..<56).contains(y) && !((24..<40).contains(x) && (24..<40).contains(y))
        }
        #expect(RemoveOutline.loops(of: ring).count == 2)
    }

    /// A selection that runs off the picture is cut by the raster's side, and its edge closes along that side.
    @Test func aCoverageCutByItsRastersSideStillCloses() {
        let cut = Self.coverage(width: 40, height: 30) { x, _ in x >= 25 }
        let loops = RemoveOutline.loops(of: cut)
        #expect(loops.count == 1)
        let box = Self.bounds(loops[0])
        #expect(close(box.minX, 25.0 / 40, 1e-6) && close(box.maxX, 1) && close(box.minY, 0) && close(box.maxY, 1))
        let all = RemoveOutline.loops(of: Self.coverage(width: 8, height: 8) { _, _ in true })
        #expect(all.count == 1 && Self.bounds(all[0]) == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// A selection at the brush picture's size is found on a smaller grid, in the same place to within one of its cells.
    @Test func aLargeCoverageIsTracedSmallerInTheSamePlace() async {
        // Off the main actor, as the overlay traces it: six megapixels in a debug build are two seconds that the suites running
        // beside this one would wait through.
        let (large, loops, picture, small) = await Task.detached {
            let large = Self.coverage(width: 3000, height: 2000) { x, y in (600..<1500).contains(x) && (400..<1000).contains(y) }
            let picture = RemovePicture.make(RemoveCoverage(width: large.width, height: large.height, values: large.values,
                                                             frame: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)))
            return (large, RemoveOutline.loops(of: large), picture, RemovePicture.make(Self.coverage(width: 100, height: 80) { x, _ in x < 50 }))
        }.value
        #expect(large.width == 3000 && loops.count == 1)
        let box = Self.bounds(loops[0]), cell = CGFloat(6) / 2000
        #expect(abs(box.minX - 0.2) < cell && abs(box.maxX - 0.5) < cell && abs(box.minY - 0.2) < cell && abs(box.maxY - 0.5) < cell)
        #expect(loops[0].count < 2 * (RemoveOutline.longSide + RemoveOutline.longSide))
        // Its tint is no larger than the masks' overlay's, and it keeps its box.
        let tint = try! #require(picture.tint)
        #expect(max(tint.width, tint.height) <= RemovePicture.tintLongSide && tint.width == 1000 && tint.height == 667)
        #expect(picture.frame == CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4) && !picture.edge.isEmpty)
        // A small one is drawn as it is.
        #expect(small.tint?.width == 100 && small.tint?.height == 80)
    }

    // MARK: A removal's arrival

    private static func settings(_ removals: [Removal]) throws -> DevelopSettings {
        DevelopSettings(manual: try ManualRenderSettings(adjustments: try ManualAdjustments(exposureEV: 0.5).settingRemovals(removals),
                                                         referenceStops: 0))
    }

    private static func removal(_ byte: String, isOn: Bool = true, includesEffects: Bool = true) throws -> Removal {
        Removal(patch: try PatchRef(id: PatchID(hex: String(repeating: byte, count: 32))!, width: 512, height: 1328),
                isOn: isOn, includesEffects: includesEffects)
    }

    /// The frame view fades a film in over the last when a removal changed the picture between them, in about 150 ms, and
    /// takes any other film of an edited frame in place.
    @Test func aFilmWhoseRemovalsDifferFromTheLastIsARemovalsArrival() throws {
        let one = try Self.removal("ab"), other = try Self.removal("cd")
        let none = try Self.settings([]), first = try Self.settings([one])
        #expect(RemovalArrival.isOne(from: none, to: first))
        #expect(RemovalArrival.isOne(from: first, to: none), "a delete or an undo is the object coming back")
        #expect(RemovalArrival.isOne(from: first, to: try Self.settings([one, other])))
        #expect(RemovalArrival.isOne(from: first, to: try Self.settings([one.replacingPatch(other.patch)])), "Try Again")
        #expect(RemovalArrival.isOne(from: first, to: try Self.settings([one.setting(includesEffects: false)])), "the shadow switch")
        #expect(RemovalArrival.isOne(from: first, to: try Self.settings([one.setting(isOn: false)])), "the eye")
        // The same removals under another slider are a slider's film, and a first film is nobody's arrival.
        #expect(!RemovalArrival.isOne(from: first, to: first) && !RemovalArrival.isOne(from: none, to: none))
        var brighter = first
        brighter.printExposure = 0.3
        #expect(!RemovalArrival.isOne(from: first, to: brighter))
        #expect(!RemovalArrival.isOne(from: nil, to: first))
        // A removal that is off composites nothing, so hiding one that was off changes no picture.
        #expect(!RemovalArrival.isOne(from: none, to: try Self.settings([one.setting(isOn: false)])))
        #expect(RemovalArrival.seconds == 0.15)
    }
}
