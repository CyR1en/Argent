import CoreImage
import Foundation
import Metal
import Vision

/// A face auto development found in a frame and how bright it is.
public struct FaceMeasure: Sendable, Equatable, Codable {
    /// The face's box in the upright frame, as fractions of its width and height from the top
    /// left: x, y, width, height.
    public var box: [Float]
    /// The mean log2 luminance of the inset's retained skin cells, against mid-gray; the whole
    /// inset's mean log2 luminance when too little skin can be measured.
    public var levelStops: Float
    /// The metered inset's share of the frame.
    public var area: Float
    /// The mean light of the inset's skin, linear red, green and blue in the working space: the
    /// inset's cells less those that do not look like the rest of it (eyes, brows, lips, hair,
    /// highlights; `FaceMeter.skin`). `nil` when too little of the inset looks alike, and in
    /// measurements made before 2026-10-07.
    public var skin: [Float]?
    /// The skin cells' share of the frame.
    public var skinArea: Float?
    /// How sure Vision is that the box holds a face, 0 to 1 (`VNFaceObservation.confidence`).
    /// `nil` for a box that did not come from Vision, and in measurements written before
    /// 2026-10-22, which stay current since the level is measured as before. For telling a doubtful
    /// face from a reliable one between frames (docs/auto-exposure-consistency-plan.md, step 2);
    /// placement does not read it yet.
    public var confidence: Float?
    /// The share of the inset's pixels that are clipped: one less the mean unclipped share of the
    /// cells it was metered over, each counted by its pixels. `nil` in measurements written before
    /// 2026-10-22. Placement does not read it yet.
    public var clipped: Float?

    public init(box: [Float], levelStops: Float, area: Float, skin: [Float]? = nil, skinArea: Float? = nil,
                confidence: Float? = nil, clipped: Float? = nil) {
        self.box = box
        self.levelStops = levelStops
        self.area = area
        self.skin = skin
        self.skinArea = skinArea
        self.confidence = confidence
        self.clipped = clipped
    }
}

/// Finds faces with Vision in a scene-linear decode, and meters them.
///
/// Vision reads scene-linear light inside a colour-managed image (M3 research: confidence 0.69
/// to 0.75 from -6 to +4 EV, 4 to 6 ms a frame at 1 to 2 megapixels). The revision is pinned so
/// macOS 26 and 27 find the same faces; revision 3 is the newest macOS 26 has. Each face is
/// metered over the middle of its box, 11/16 of its width and 14/16 of its height (Apple's
/// face-metering patent), which keeps hair and background out.
public enum FaceMeter {
    public static let insetWidth: Float = 11.0 / 16
    public static let insetHeight: Float = 14.0 / 16

    /// A face Vision found: its box, upright, as fractions of the frame's size from the top left,
    /// and how sure Vision is of it, `nil` for a box from elsewhere.
    public struct Detection: Sendable, Equatable {
        public var box: CGRect
        public var confidence: Float?

        public init(box: CGRect, confidence: Float? = nil) {
            self.box = box
            self.confidence = confidence
        }
    }

    /// The face boxes in `texture`, upright, as fractions of its size from the top left.
    public static func detect(_ texture: MTLTexture, workingSpace: CGColorSpace) -> [CGRect] {
        detections(texture, workingSpace: workingSpace).map(\.box)
    }

    /// The faces in `texture` with Vision's confidence in each; `detect`'s boxes.
    public static func detections(_ texture: MTLTexture, workingSpace: CGColorSpace) -> [Detection] {
        // The render graph's textures are laid out as Core Image renders them, first row at the
        // picture's bottom, so the texture read as an image is upright as it is.
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: workingSpace]) else { return [] }
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).map { face in
            // Vision's boxes are normalized with the origin at the bottom left.
            let b = face.boundingBox
            return Detection(box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height),
                             confidence: face.confidence)
        }
    }

    /// Meters each box over `pixels`, RGBA half floats in the working space, row by row from
    /// the picture's bottom, as a texture of the render graph reads back.
    public static func meter(_ boxes: [CGRect], pixels: [Float16], width: Int, height: Int) -> [FaceMeasure] {
        meter(boxes, grid: ExposureAnalyzer.grid(pixels: pixels, width: width, height: height))
    }

    /// Meters each box over the analysis grid, its confidence unknown.
    public static func meter(_ boxes: [CGRect], grid: ExposureAnalyzer.Grid) -> [FaceMeasure] {
        meter(boxes.map { Detection(box: $0) }, grid: grid)
    }

    /// Meters each face over the analysis grid's cells whose middles fall inside its box's inset, or
    /// the one cell under the inset's middle when the inset is smaller than a cell. Its level is the
    /// mean log2 luminance of the same unclipped, noise-corrected cells used for its skin colour,
    /// or of all the inset's cells when skin is unavailable, against mid-gray. Its confidence is
    /// the detection's, and its clipped share is over all the inset's cells, skin or not.
    public static func meter(_ detections: [Detection], grid: ExposureAnalyzer.Grid) -> [FaceMeasure] {
        let width = grid.frameWidth, height = grid.frameHeight
        let floor = 0.18 * exp2(ExposureAnalyzer.floorStops)
        // Clip in floating point before converting: finite CGRect coordinates can exceed Float
        // or Int, even when the inset is wholly off the frame. Keep the usual pixel rounding.
        func bound(_ position: Float, by limit: Int) -> Int? {
            guard !position.isNaN else { return nil }
            return Int(exactly: min(max(position, 0), Float(limit)).rounded())
        }
        return detections.compactMap { detection in
            let box = detection.box
            // A box that is not a number, empty, or whose inset lies off the frame meters nothing.
            guard [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite), box.width > 0, box.height > 0
            else { return nil }
            let measuredBox = [Float(box.minX), Float(box.minY), Float(box.width), Float(box.height)]
            guard measuredBox.allSatisfy(\.isFinite) else { return nil }
            let insetW = Float(box.width) * insetWidth, insetH = Float(box.height) * insetHeight
            let midRow = 1 - Float(box.midY)
            guard let x0 = bound((Float(box.midX) - insetW / 2) * Float(width), by: width),
                  let x1 = bound((Float(box.midX) + insetW / 2) * Float(width), by: width),
                  let y0 = bound((midRow - insetH / 2) * Float(height), by: height),
                  let y1 = bound((midRow + insetH / 2) * Float(height), by: height) else { return nil }
            guard max(0, x0) < min(width, x1), max(0, y0) < min(height, y1), grid.width > 0, grid.height > 0 else { return nil }
            let xs = max(0, x0)..<min(width, x1), ys = max(0, y0)..<min(height, y1)
            let step = grid.step
            // Cells whose middle, at step / 2 past their corner, lies in the inset.
            let columns = max(0, (xs.lowerBound - step / 2 + step - 1) / step)..<min(grid.width, max(0, (xs.upperBound - step / 2 + step - 1) / step))
            let rows = max(0, (ys.lowerBound - step / 2 + step - 1) / step)..<min(grid.height, max(0, (ys.upperBound - step / 2 + step - 1) / step))
            var cells: [Int] = []
            for row in rows { for column in columns { cells.append(row * grid.width + column) } }
            if cells.isEmpty {
                let column = min(grid.width - 1, (xs.lowerBound + xs.upperBound) / 2 / step)
                let row = min(grid.height - 1, (ys.lowerBound + ys.upperBound) / 2 / step)
                cells = [row * grid.width + column]
            }
            var sum: Float = 0
            // The cells' pixels, and those not clipped: a cell in the grid's last column or row
            // can hold fewer pixels than the rest.
            var pixels: Float = 0, unclipped: Float = 0
            for index in cells {
                sum += log2(max((grid.all[index] * Rec2020.luma).sum(), floor))
                let x = index % grid.width * step, y = index / grid.width * step
                let count = Float(max(0, min(step, width - x)) * max(0, min(step, height - y)))
                pixels += count
                unclipped += grid.unclipped[index] * count
            }
            let area = Float(xs.count * ys.count) / Float(width * height)
            let skin = Self.skin(cells, grid: grid)
            // A recipe cannot hold a value that is not finite, as a hand-made grid's cells of no
            // pixels would give.
            let clipped = 1 - unclipped / pixels
            return FaceMeasure(box: measuredBox,
                               levelStops: skin?.level ?? (sum / Float(cells.count) - log2(0.18)), area: area,
                               skin: skin.map { [$0.rgb.x, $0.rgb.y, $0.rgb.z] }, skinArea: skin.map { area * $0.share },
                               confidence: detection.confidence.flatMap { $0.isFinite ? $0 : nil },
                               clipped: clipped.isFinite ? clipped : nil)
        }
    }

    /// A cell of the inset is skin when its luminance lies within `skinLuminance` stops of the
    /// inset's median and its colour within `skinRedBlue` and `skinGreenMagenta` stops of the
    /// median colour: the inset is mostly skin, and eyes, brows, lips, nostrils, hair and specular
    /// highlights stand apart from it in brightness or colour. Round values (engineering).
    public static let skinLuminance: ClosedRange<Float> = -1...0.75
    public static let skinRedBlue: Float = 0.35
    public static let skinGreenMagenta: Float = 0.2
    /// The share of the inset's cells that must be skin for the face to give its skin's colour
    /// and level.
    public static let minimumSkinShare: Float = 0.5

    /// The mean light of the cells of `cells` that look like skin, their share of `cells`, and
    /// their mean log2 luminance against mid-gray; `nil` when under `minimumSkinShare` of them
    /// do, or fewer than four. Colour averages linear RGB; level averages each cell's log light.
    static func skin(_ cells: [Int], grid: ExposureAnalyzer.Grid) -> (rgb: SIMD3<Float>, share: Float, level: Float)? {
        let floor = 0.18 * exp2(ExposureAnalyzer.floorStops)
        struct Cell { var rgb: SIMD3<Float>; var stops: Float; var redBlue: Float; var greenMagenta: Float }
        let usable = cells.compactMap { index -> Cell? in
            let rgb = grid.light[index]
            guard grid.unclipped[index] >= 0.5, rgb.min() > 0, (rgb * Rec2020.luma).sum() > floor else { return nil }
            let r = log2(rgb.x), g = log2(rgb.y), b = log2(rgb.z)
            return Cell(rgb: rgb, stops: log2((rgb * Rec2020.luma).sum()), redBlue: r - b, greenMagenta: g - (r + b) / 2)
        }
        guard usable.count >= 4 else { return nil }
        func median(_ v: [Float]) -> Float { let s = v.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2 }
        let stops = median(usable.map(\.stops)), redBlue = median(usable.map(\.redBlue)), greenMagenta = median(usable.map(\.greenMagenta))
        let kept = usable.filter {
            skinLuminance.contains($0.stops - stops) && abs($0.redBlue - redBlue) <= skinRedBlue
                && abs($0.greenMagenta - greenMagenta) <= skinGreenMagenta
        }
        let share = Float(kept.count) / Float(cells.count)
        guard kept.count >= 4, share >= minimumSkinShare else { return nil }
        return (kept.reduce(SIMD3<Float>(repeating: 0)) { $0 + $1.rgb } / Float(kept.count), share,
                kept.reduce(Float(0)) { $0 + $1.stops } / Float(kept.count) - log2(0.18))
    }
}
