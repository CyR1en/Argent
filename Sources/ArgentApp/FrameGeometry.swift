import ArgentRoll
import SwiftUI

/// Where the photograph is drawn in the frame view's area, in points from the area's top left (the
/// named space `framePicture`): the area, the picture's rectangle in it as placed and zoomed, and the
/// display's scale. Pure, and the one rectangle there is: the pictures, the split divider
/// (`SplitGeometry` composes it), the mask overlay and the mask canvas all take it from here, so a
/// pointer's place on the photograph comes from what is drawn. `scale × fitted`, which
/// `FrameZoomTests` sketches, is up to 5.5 points away from it, since the fitted box's shorter side is
/// rounded up and that grows with the zoom (docs/masking-plan.md, "The canvas").
struct FrameGeometry: Equatable {
    var area: CGSize
    var picture: CGRect
    var displayScale: CGFloat
    /// Where the film side begins in the area while Compare splits the picture, the divider's x (`SplitGeometry.dividerX`); nil
    /// with no split up. Set only on the geometry the canvas reads afresh at each event (`FramePicture.liveGeometry`).
    var filmEdge: CGFloat?

    /// The picture's centre, where `FramePicture` positions its pictures.
    var center: CGPoint { CGPoint(x: picture.midX, y: picture.midY) }
    var longSide: CGFloat { max(picture.width, picture.height) }
    /// The part of the picture the area shows. A zoomed picture runs on past the area, under the dock
    /// and to the workspace's rounded edges, and nothing out there is the frame view's to take.
    var visiblePicture: CGRect { picture.intersection(CGRect(origin: .zero, size: area)) }
    /// What a tool in hand presses: the part of the picture the area shows, less a split's neutral side, which shows neither the
    /// red nor the mask's effect. A stroke or a gradient begun there would leave nothing to see.
    var toolPicture: CGRect {
        guard let filmEdge else { return visiblePicture }
        let shown = visiblePicture
        guard !shown.isNull else { return shown }
        let left = min(max(shown.minX, filmEdge), shown.maxX)
        return CGRect(x: left, y: shown.minY, width: shown.maxX - left, height: shown.height)
    }
    /// The part of the picture the area shows, as fractions of the whole picture from its top left; `nil` when none of it shows.
    var visibleFractions: CGRect? {
        let shown = visiblePicture
        guard !shown.isNull, !shown.isEmpty, picture.width > 0, picture.height > 0 else { return nil }
        return CGRect(x: (shown.minX - picture.minX) / picture.width, y: (shown.minY - picture.minY) / picture.height,
                      width: shown.width / picture.width, height: shown.height / picture.height)
    }
    /// A drag would move the picture: it is larger than the area on at least one side, the half point
    /// being what a render one pixel over the box comes to (`FrameZoom.clamped` is what stops a pan).
    var canPan: Bool { picture.width > area.width + 0.5 || picture.height > area.height + 0.5 }

    /// The pictures' longer side in pixels: the fitted frame's, or the settled zoom's. A develop's
    /// memory gate does not count a larger decode, so meanwhile the fitted render is scaled instead.
    static func renderPixels(layout: FrameLayout, zoom: FrameZoom, room: FrameZoom.Room, frame: Frame, isDeveloping: Bool) -> Int {
        isDeveloping ? layout.pixels(frame) : zoom.pixels(in: room)
    }

    /// The rectangle `FramePicture` draws. `rendered` is the film's and the neutral raw's sizes in
    /// pixels, those on screen: one rendered for this size is shown one to one, so its own size is the
    /// box; until then the layout's box, which the decode comes out at. A render for another size, the
    /// last one during a live resize or a zoom, is scaled to fit the box. The box is then scaled from
    /// the zoom its pictures are rendered for to the zoom now: the box itself once the zoom settles.
    static func make(layout: FrameLayout, zoom: FrameZoom, room: FrameZoom.Room, frame: Frame, isDeveloping: Bool,
                     rendered: [CGSize] = []) -> FrameGeometry {
        let pixels = renderPixels(layout: layout, zoom: zoom, room: room, frame: frame, isDeveloping: isDeveloping)
        var box = layout.box(frame, pixels: pixels)
        if let shown = rendered.first(where: { Int(max($0.width, $0.height)) == pixels }) {
            box = CGSize(width: shown.width / layout.displayScale, height: shown.height / layout.displayScale)
        }
        let scale = zoom.scale / (CGFloat(pixels) / CGFloat(layout.pixels(frame)))
        let size = CGSize(width: box.width * scale, height: box.height * scale)
        let fitted = layout.center(of: size)
        let center = CGPoint(x: fitted.x + zoom.offset.width, y: fitted.y + zoom.offset.height)
        return FrameGeometry(area: layout.area,
                             picture: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                             width: size.width, height: size.height),
                             displayScale: layout.displayScale)
    }

    /// An area point as fractions of the whole picture, upright, from its top left: 0 to 1 across it
    /// and down it, outside that off the picture. The render is already upright (the decoder rotates).
    func normalized(_ point: CGPoint) -> CGPoint {
        guard picture.width > 0, picture.height > 0 else { return .zero }
        return CGPoint(x: (point.x - picture.minX) / picture.width, y: (point.y - picture.minY) / picture.height)
    }

    /// The area point of a place on the picture, given as `normalized` gives it.
    func point(forNormalized fractions: CGPoint) -> CGPoint {
        CGPoint(x: picture.minX + fractions.x * picture.width, y: picture.minY + fractions.y * picture.height)
    }
}
