import Foundation
import Metal

/// Where a frame-filling gray card lands in a pinned decode: the measurement that closes the
/// camera-side anchor in `ExposureAnchor`, which three indirect routes put at 0.080 plus or
/// minus 0.2 EV.
///
/// The camera meters the card to its own mid-tone, so after the decode's gain the card should
/// read `ExposureAnchor.filmMidGray`. What it reads instead says how far off the anchor is.
public enum GrayCard {
    public struct Reading: Sendable, Equatable {
        /// Median Rec. 2020 luminance of the central box, after every pin and gain.
        public var luminance: Double
        /// 90th over 10th percentile luminance in the box: about 1 for an evenly lit card.
        public var spread: Double
        /// Stops the anchor is off by: log2(luminance / filmMidGray).
        public var anchorErrorStops: Double { log2(luminance / Double(ExposureAnchor.filmMidGray)) }
        /// The `ExposureAnchor.decodedMidTone` this frame implies.
        public var impliedDecodedMidTone: Double { Double(ExposureAnchor.decodedMidTone) * luminance / Double(ExposureAnchor.filmMidGray) }
    }

    /// A spread above this means the card is unevenly lit or does not fill the box.
    public static let maximumSpread = 1.15

    /// Reads the central `fraction` of the frame on each axis. The texture must be CPU-readable
    /// RGBA16Float, as the decoder's pooled textures are.
    public static func read(_ texture: MTLTexture, fraction: Double = 0.2) -> Reading {
        let width = texture.width, height = texture.height
        let boxWidth = max(1, Int(Double(width) * fraction)), boxHeight = max(1, Int(Double(height) * fraction))
        let x0 = (width - boxWidth) / 2, y0 = (height - boxHeight) / 2
        var halves = [Float16](repeating: 0, count: boxWidth * boxHeight * 4)
        halves.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: boxWidth * 8,
                             from: MTLRegionMake2D(x0, y0, boxWidth, boxHeight), mipmapLevel: 0)
        }
        var luminances = [Double](repeating: 0, count: boxWidth * boxHeight)
        for i in 0..<luminances.count {
            let red = Double(halves[i * 4]), green = Double(halves[i * 4 + 1]), blue = Double(halves[i * 4 + 2])
            luminances[i] = 0.2627 * red + 0.6780 * green + 0.0593 * blue
        }
        luminances.sort()
        func percentile(_ p: Double) -> Double { luminances[min(luminances.count - 1, Int(p * Double(luminances.count - 1)))] }
        let low = max(percentile(0.1), 1e-9)
        return Reading(luminance: percentile(0.5), spread: percentile(0.9) / low)
    }
}
