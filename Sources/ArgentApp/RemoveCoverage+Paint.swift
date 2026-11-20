import ArgentCore
import ArgentRoll
import CoreGraphics
import Foundation

/// A selection as the Remove brush paints it (docs/remove-plan.md, section 4.6): round dabs of the brush's size along the
/// stroke, hard at the edge, over the whole corrected picture. It is rasterised here, on the CPU: a selection is never in the
/// edit and never printed, so it needs neither a mask's canvas nor a decode held by the frame view, and a stroke is selected the
/// moment it is released.
extension RemoveCoverage {
    /// A painted selection's long side, in pixels. A quarter of a 33 MP frame's, near the size the segmenter answers at, so a
    /// stroke and a snapped object mix without either being coarsened much; 2.8 MB a selection.
    static let paintedLongSide = 2048

    /// The raster's size for `frame`'s picture, which is three by two either way up.
    static func paintedSize(for frame: Frame) -> (width: Int, height: Int) {
        let short = (2 * paintedLongSide + 2) / 3
        return frame.info.isPortrait ? (short, paintedLongSide) : (paintedLongSide, short)
    }

    /// The stroke through `points`, fractions of the picture from its top left, painted with a brush `brushSize` hundredths of
    /// the long side across (`MaskBrushSettings.size`). One point is a dab. `nil` when it paints nothing inside the picture.
    ///
    /// Core Graphics draws it, a line with round ends and joins and no smoothing, straight into the raster: this runs on the main
    /// thread at each stroke's release, and a loop over the pixels in Swift took a debug build up to 300 ms there.
    static func painted(_ points: [CGPoint], brushSize: Double, width: Int, height: Int) -> RemoveCoverage? {
        guard width > 0, height > 0, let first = points.first, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        // Never so small that a dab falls between pixels' centres: the smallest brush still selects.
        let radius = max(0.75, brushSize / 200 * Double(max(width, height)))
        // The raster's first row is the picture's top; the context counts up from the bottom.
        func place(_ point: CGPoint) -> CGPoint { CGPoint(x: Double(point.x) * Double(width), y: Double(height) - Double(point.y) * Double(height)) }
        var values = [UInt8](repeating: 0, count: width * height)
        let drawn = values.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setShouldAntialias(false)
            context.setAllowsAntialiasing(false)
            context.setFillColor(gray: 1, alpha: 1)
            context.setStrokeColor(gray: 1, alpha: 1)
            let start = place(first)
            // The dab at the stroke's start, which is all a click is and what a stroke that never moved would otherwise lack.
            context.fillEllipse(in: CGRect(x: start.x - radius, y: start.y - radius, width: 2 * radius, height: 2 * radius))
            if points.count > 1 {
                context.setLineWidth(2 * radius)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.move(to: start)
                for point in points.dropFirst() { context.addLine(to: place(point)) }
                context.strokePath()
            }
            return true
        }
        guard drawn else { return nil }
        let painted = RemoveCoverage(width: width, height: height, values: values)
        return painted.isEmpty ? nil : painted
    }

    /// What the segmenter or the pipeline calls a selection, as the overlay draws it.
    init(_ selection: RemovalPipeline.Selection) {
        self.init(width: selection.width, height: selection.height, values: selection.coverage)
    }

    /// This as the pipeline takes it; `nil` when nothing is selected.
    var selection: RemovalPipeline.Selection? {
        try? RemovalPipeline.Selection(width: width, height: height, coverage: values)
    }

    /// Whether nothing is selected. Read eight bytes at a time: a selection is 2.8 MB, and this runs on the main thread at each
    /// stroke's release.
    var isEmpty: Bool {
        values.withUnsafeBytes { bytes in
            let words = bytes.count / 8
            for word in 0..<words where bytes.loadUnaligned(fromByteOffset: word * 8, as: UInt64.self) & 0x8080_8080_8080_8080 != 0 {
                return false
            }
            for byte in (words * 8)..<bytes.count where bytes[byte] >= 128 { return false }
            return true
        }
    }

    /// `other` at this raster's size, by the nearest pixel: both cover the whole picture.
    private func sized(_ other: RemoveCoverage) -> [UInt8] {
        guard other.width != width || other.height != height else { return other.values }
        var values = [UInt8](repeating: 0, count: width * height)
        let width = width, height = height
        values.withUnsafeMutableBufferPointer { out in
            other.values.withUnsafeBufferPointer { source in
                for y in 0..<height {
                    let row = min(other.height - 1, (2 * y + 1) * other.height / (2 * height)) * other.width
                    for x in 0..<width {
                        out[y * width + x] = source[row + min(other.width - 1, (2 * x + 1) * other.width / (2 * width))]
                    }
                }
            }
        }
        return values
    }

    /// This with `other` selected too. Eight bytes at a time, each pair of bytes joined bit by bit: for a selection's 0 and 255 that
    /// is the larger of the two, and a byte at a time cost a debug build 160 ms on the main thread at each stroke's release.
    func adding(_ other: RemoveCoverage) -> RemoveCoverage {
        let added = sized(other)
        var result = self
        result.values.withUnsafeMutableBytes { out in
            added.withUnsafeBytes { more in
                let count = min(out.count, more.count), words = count / 8
                for word in 0..<words {
                    let at = word * 8
                    let mine = out.loadUnaligned(fromByteOffset: at, as: UInt64.self)
                    let both = mine | more.loadUnaligned(fromByteOffset: at, as: UInt64.self)
                    if both != mine { out.storeBytes(of: both, toByteOffset: at, as: UInt64.self) }
                }
                for index in (words * 8)..<count { out[index] |= more[index] }
            }
        }
        return result
    }

    /// This without what `other` selects; `nil` when nothing is left.
    func subtracting(_ other: RemoveCoverage) -> RemoveCoverage? {
        let taken = sized(other)
        var result = self, left = false
        result.values.withUnsafeMutableBytes { out in
            taken.withUnsafeBytes { less in
                let count = min(out.count, less.count), words = count / 8, tops: UInt64 = 0x8080_8080_8080_8080
                for word in 0..<words {
                    let at = word * 8
                    let mine = out.loadUnaligned(fromByteOffset: at, as: UInt64.self)
                    // Each byte of `less` at 128 or more, spread to a whole byte of ones.
                    let selected = ((less.loadUnaligned(fromByteOffset: at, as: UInt64.self) & tops) >> 7) &* 0xFF
                    let kept = mine & ~selected
                    if kept != mine { out.storeBytes(of: kept, toByteOffset: at, as: UInt64.self) }
                    if kept & tops != 0 { left = true }
                }
                for index in (words * 8)..<count {
                    if less[index] >= 128 { out[index] = 0 } else if out[index] >= 128 { left = true }
                }
            }
        }
        return left ? result : nil
    }
}
