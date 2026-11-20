import Foundation

/// The lens corrections an a7 IV writes into the raw IFD of every ARW: shading (vignetting),
/// lateral chromatic aberration and distortion, each a setting and a curve (tag names after
/// ExifTool's tag documentation). The curves come from the lens for the focal length, aperture and
/// focus of the frame, so they are the file's own data rather than a profile.
///
/// What each holds, established on the CC0 samples against the camera's own JPEG and checked on the
/// restricted frames against it and against Apple's decoder (docs/decoder.md, section 13):
///
/// - A curve's first value is its knot count `n`, 16 on a full-frame file and 11 in APS-C crop
///   mode; the knots run evenly from the frame's centre (knot 0) to its corner (knot `n - 1`), in
///   the frame's own half diagonal, and are interpolated linearly between.
/// - Distortion (0x7037): the corrected picture at radius `r` shows the uncorrected picture at
///   `r (1 + 2^-14 d(r)) / s`, `s` a scale that keeps the frame filled. Sony's camera divides by the
///   largest factor, Apple's decoder by the factor at the corner.
/// - Lateral colour (0x7035): `2n` values, red's `n` knots then blue's. Read as the public
///   descriptions have it, red and blue scaled by `1 + 2^-21 k(r)` more than green, the curves
///   predict the measured fringes' direction but up to twice their size, so the decoder does not
///   apply them.
/// - Shading (0x7032): rises from 0 at the centre. Neither the camera's JPEG nor Apple's decode
///   brightens the corners against the raw, so the decoder does not apply it either.
public struct SonyLensCorrection: Sendable, Equatable {
    public enum State: String, Sendable {
        case absent
        case identity
        case offByCamera
        case usable
    }

    /// One curve: values at knots evenly spaced from the centre to the corner.
    public struct Curve: Sendable, Equatable {
        public var knots: [Int]

        public init(knots: [Int]) {
            self.knots = knots
        }

        /// The curve at `t`, 0 at the centre and 1 at the corner, linear between knots and held
        /// at the last beyond it.
        public func value(at t: Double) -> Double {
            guard knots.count > 1 else { return Double(knots.first ?? 0) }
            let position = min(max(t, 0), 1) * Double(knots.count - 1)
            let i = min(Int(position), knots.count - 2)
            let f = position - Double(i)
            return Double(knots[i]) * (1 - f) + Double(knots[i + 1]) * f
        }
    }

    /// 0x7031: 256 off, 257 auto, 272 auto (as ExifTool names it for the ILCE-1; every a7 IV file
    /// here writes it), 511 no parameters.
    public var shadingSetting: Int?
    /// 0x7032.
    public var shading: Curve?
    /// 0x7034: 0 off, 1 auto, 255 no parameters.
    public var lateralColourSetting: Int?
    /// 0x7035, the red and blue halves.
    public var red: Curve?
    public var blue: Curve?
    /// 0x7036: 0 off, 1 auto, 17 auto and fixed by the lens (the lens will not let it be turned
    /// off), 255 no parameters.
    public var distortionSetting: Int?
    /// 0x7037.
    public var distortion: Curve?

    public init(shadingSetting: Int? = nil, shading: Curve? = nil, lateralColourSetting: Int? = nil, red: Curve? = nil,
                blue: Curve? = nil, distortionSetting: Int? = nil, distortion: Curve? = nil) {
        self.shadingSetting = shadingSetting
        self.shading = shading
        self.lateralColourSetting = lateralColourSetting
        self.red = red
        self.blue = blue
        self.distortionSetting = distortionSetting
        self.distortion = distortion
    }

    /// Whether the camera was set to correct distortion: auto, or fixed on by the lens. Apple's
    /// decoder corrects exactly these frames (measured: the two lenses whose files say 17 move, the
    /// three frames of two lenses whose files say 0 do not).
    public var correctsDistortion: Bool { distortionSetting == 1 || distortionSetting == 17 }

    public var distortionState: State {
        guard let distortion, distortion.knots.count >= 2, distortionSetting != 255 else { return .absent }
        if distortion.knots.allSatisfy({ $0 == distortion.knots[0] }) { return .identity }
        return distortionSetting == 0 ? .offByCamera : .usable
    }

    public var lateralColourState: State {
        guard let red, let blue, red.knots.count >= 2, red.knots.count == blue.knots.count,
              lateralColourSetting != 255 else { return .absent }
        if red.knots.allSatisfy({ $0 == 0 }) && blue.knots.allSatisfy({ $0 == 0 }) { return .identity }
        return lateralColourSetting == 0 ? .offByCamera : .usable
    }

    public var shadingState: State {
        guard let shading, shading.knots.count >= 2, shadingSetting != 511 else { return .absent }
        if shading.knots.allSatisfy({ $0 == 0 }) { return .identity }
        return shadingSetting == 256 ? .offByCamera : .usable
    }

    /// The largest distortion knot accepted, half of the 2^14 that is the whole radius: a curve past
    /// it would fold the picture, and real lenses stay far inside it (the corpus's reach 774, a
    /// twentieth).
    static let largestDistortionKnot = 8191

    /// The curves in the raw IFD `ifd`, `nil` when it has none of them. A malformed curve is left
    /// out rather than refusing the file: the decode is still right without it. Curves must be
    /// signed shorts, as Sony writes them, and distortion's knots within `largestDistortionKnot`.
    static func parse(_ ifd: [UInt16: TIFFReader.Entry], reader: TIFFReader) -> SonyLensCorrection? {
        func values(_ tag: UInt16, signed: Bool) -> [Int]? {
            guard let entry = ifd[tag], entry.type == 8 || (!signed && entry.type == 3) else { return nil }
            return try? reader.integers(entry)
        }
        func setting(_ tag: UInt16) -> Int? { values(tag, signed: false)?.first }
        /// A count, then that many knots of each of `parts` curves.
        func curves(_ tag: UInt16, parts: Int, largest: Int = .max) -> [Curve]? {
            guard let v = values(tag, signed: true), let total = v.first, total > 0, total % parts == 0 else { return nil }
            let n = total / parts
            guard (2...16).contains(n), v.count >= 1 + total,
                  v[1...total].allSatisfy({ abs($0) <= largest }) else { return nil }
            return (0..<parts).map { Curve(knots: Array(v[(1 + $0 * n)..<(1 + ($0 + 1) * n)])) }
        }
        let colour = curves(0x7035, parts: 2)
        let lens = SonyLensCorrection(
            shadingSetting: setting(0x7031), shading: curves(0x7032, parts: 1)?.first,
            lateralColourSetting: setting(0x7034), red: colour?[0], blue: colour?[1],
            distortionSetting: setting(0x7036), distortion: curves(0x7037, parts: 1, largest: largestDistortionKnot)?.first)
        return lens == SonyLensCorrection() ? nil : lens
    }

    /// The curves in the raw IFD of the ARW at `url`, `nil` when it has none or cannot be read.
    public static func read(from url: URL) -> SonyLensCorrection? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let reader = try? TIFFReader(handle: handle),
              let ifd0 = try? reader.readIFD(at: reader.firstIFDOffset),
              let subIFDs = try? ifd0[0x014A].map({ try reader.integers($0) }) else { return nil }
        for offset in subIFDs {
            guard let ifd = try? reader.readIFD(at: offset) else { continue }
            let subfileType = (try? ifd[0x00FE].map { try reader.integers($0).first ?? 0 }) ?? 0
            guard subfileType == 0, ifd[0x0103] != nil else { continue }
            return parse(ifd, reader: reader)
        }
        return nil
    }
}

/// The distortion correction a decode applies: the corrected picture's pixel at `q`, in crop
/// pixels from the top left before the frame is turned upright, shows the uncorrected picture at
/// `c + (q - c) g(|q - c| / rMax) / scale`, where `c` is the crop's centre, `rMax` its half
/// diagonal and `g = 1 + 2^-14 d` the file's distortion curve (`SonyLensCorrection`).
///
/// `scale` is `g` at the corner, as Apple's decoder has it (measured: its corrections of the FE 55mm
/// F1.8 ZA and the FE 50mm F2.5 G fit the file's curve divided by the corner's factor, 0.5 and 0.3
/// px rms, against 5.6 and 0.3 px divided by the largest, which the camera's JPEG uses), so a frame
/// keeps its corners where Apple's decode puts them. Where that would read past the mosaic's real
/// samples, a barrel lens's correction at the middle of the long edges, the scale rises until it
/// does not, so nothing at the frame's edge is invented.
public struct LensWarp: Sendable, Equatable {
    /// The knots the kernel's parameters hold.
    public static let maximumKnots = 16

    /// The file's distortion knots as `g - 1`, centre to corner.
    public var knots: [Double]
    public var scale: Double
    public var width: Int
    public var height: Int

    /// Rows of the corrected frame rendered at a time: the uncorrected rows they read are rendered
    /// into a band of that height and a little more, never a second full-size frame.
    public var bandRows = 512

    public var centreX: Double { Double(width - 1) / 2 }
    public var centreY: Double { Double(height - 1) / 2 }
    public var rMax: Double { (Double(width * width + height * height)).squareRoot() / 2 }

    /// `g / scale` at `t`, 0 at the centre and 1 at the corner.
    public func factor(at t: Double) -> Double {
        let position = min(max(t, 0), 1) * Double(knots.count - 1)
        let i = min(Int(position), knots.count - 2)
        let f = position - Double(i)
        return (1 + knots[i] * (1 - f) + knots[i + 1] * f) / scale
    }

    /// Where the corrected picture's pixel (x, y) reads the uncorrected one.
    public func source(x: Double, y: Double) -> (x: Double, y: Double) {
        let vx = x - centreX, vy = y - centreY
        let f = factor(at: (vx * vx + vy * vy).squareRoot() / rMax)
        return (centreX + vx * f, centreY + vy * f)
    }

    /// Whether the radius a pixel reads, `r g(r)`, rises with `r` all the way to the corner, so a
    /// picture's furthest read lies on its edge and a band's on the band's edge, as the scale and
    /// `sourceRows` take it. `g` is linear between knots, so the slope of `t g(t)` is linear there
    /// and its ends decide. Lens curves keep far from failing it (their knots reach about 774
    /// against a bound of 8191); a curve that folds the picture fails, and the decoder refuses
    /// the file (review 5).
    public static func readRises(_ curve: SonyLensCorrection.Curve) -> Bool {
        let k = curve.knots.map { Double($0) / 16384 }
        guard k.count >= 2 else { return true }
        let n = Double(k.count - 1)
        for i in 0..<(k.count - 1) {
            let slope = (k[i + 1] - k[i]) * n
            for (t, g) in [(Double(i) / n, 1 + k[i]), (Double(i + 1) / n, 1 + k[i + 1])] where g + t * slope <= 0 {
                return false
            }
        }
        return true
    }

    /// The plan for `curve` on a crop of `width` by `height`, reading no closer than `support`
    /// pixels to the edge of the real samples, which reach `margin` pixels past the crop on each
    /// side. `nil` when the curve moves nothing, every knot equal so `g / scale` is 1, or when
    /// it folds the picture (`readRises`), or has more knots than the kernel holds.
    public static func plan(_ curve: SonyLensCorrection.Curve, width: Int, height: Int,
                            margin: (x: Int, y: Int), support: Int = 2) -> LensWarp? {
        guard (2...maximumKnots).contains(curve.knots.count), width > 1, height > 1, Set(curve.knots).count > 1,
              readRises(curve) else { return nil }
        var warp = LensWarp(knots: curve.knots.map { Double($0) / 16384 }, scale: 1, width: width, height: height)
        warp.scale = 1 + warp.knots[warp.knots.count - 1]
        // The scale that brings the furthest read inside, along x and along y: for a read at
        // c + v g / s, s must be at least v g over the distance to the edge on that side.
        let reachX = warp.centreX + Double(margin.x - support), reachY = warp.centreY + Double(margin.y - support)
        var needed = 0.0
        warp.forEachReadPoint { x, y in
            let vx = x - warp.centreX, vy = y - warp.centreY
            let g = warp.factor(at: (vx * vx + vy * vy).squareRoot() / warp.rMax) * warp.scale
            needed = max(needed, abs(vx) * g / reachX, abs(vy) * g / reachY)
        }
        warp.scale = max(warp.scale, needed)
        return warp
    }

    /// Calls `body` with every point whose read could be the furthest: the crop's edge pixel by
    /// pixel, which holds them all since `plan` takes only curves whose radius read rises.
    func forEachReadPoint(_ body: (Double, Double) -> Void) {
        for x in 0..<width {
            body(Double(x), 0)
            body(Double(x), Double(height - 1))
        }
        for y in 0..<height {
            body(0, Double(y))
            body(Double(width - 1), Double(y))
        }
    }

    /// The uncorrected rows, in crop rows, that the corrected rows `rows` read, widened by the
    /// interpolation's reach (`support` rows before and after) and a row to spare.
    public func sourceRows(_ rows: Range<Int>, support: Int = 2) -> Range<Int> {
        var low = Double.infinity, high = -Double.infinity
        func visit(_ x: Int, _ y: Int) {
            let s = source(x: Double(x), y: Double(y)).y
            low = min(low, s)
            high = max(high, s)
        }
        for x in 0..<width {
            visit(x, rows.lowerBound)
            visit(x, rows.upperBound - 1)
        }
        for y in rows {
            visit(0, y)
            visit(width - 1, y)
        }
        return (Int(low.rounded(.down)) - support)..<(Int(high.rounded(.down)) + support + 2)
    }
}
