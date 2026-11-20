import Foundation
import Testing
@testable import ArgentCore

/// Synthetic a7 IV raws for the measurements behind docs/provenance.md: copies of the CC0
/// uncompressed sample (raw.pixls.us, `samples/ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW`)
/// with their raw samples changed and their Exif ISO rewritten, so Apple's decoder and the in-house
/// one both read them as the a7 IV frames they stand for. Two kinds:
///
/// - `simulated(iso:)`: the sample's own scene at a higher ISO. Raw counts are proportional to ISO
///   times exposure, so a metered scene keeps its counts at any ISO and only its noise grows; the
///   copy gets the noise the higher ISO adds on top of the sample's own.
/// - `patches(_:iso:)`: flat patches of chosen colours with the noise of that ISO.
///
/// The noise model, in digital numbers above black: a sample of `s` varies by `shot * s + read`.
/// `read` is PhotonsToPhotos' published input-referred read noise of the ILCE-7M4 in electrons
/// (https://www.photonstophotos.net/Charts/RN_e.htm, read 2026-10-07; reported) times the
/// conversion gain that chart uses, unity at ISO 411 (its `unityEv` of 7.04): the read noise in
/// digital numbers as its dark frames showed it. `shot` is that conversion gain, 100 / 411.3 = 0.243
/// at ISO 100 and proportional to the ISO, which with Poisson photon noise gives DXOMARK's measured
/// SNR at 18 percent within 0.2 dB from ISO 800 to 51200 (computed; `BodyNoise`). Until 2026-10-07
/// it was 0.355, what `SensorNoise` reads from the CC0 sample at ISO 250, where the scene's texture
/// raises the estimate (docs/research/noise-and-hardware.md). The CC0 samples reach no lower than
/// about 100 DN, where read noise is a few percent of the variance, so they cannot give it themselves.
enum SyntheticRaw {
    static let base = InHouseDecoderMeasureTests.root.appendingPathComponent("samples/ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW")
    static let baseISO = 250.0
    /// The a7 IV's noise model, from its body profile (`BodyNoise`), where the analysis also reads
    /// it to take the decoder's lift of dark noise out (`DecodedNoise`). ARGENT_SIM_SHOT replaces its
    /// shot term at ISO 100, for making frames with another model's noise than the analysis assumes.
    static var noise: BodyNoise {
        var model = BodyProfile.a7IV.noise!
        if let shot = ProcessInfo.processInfo.environment["ARGENT_SIM_SHOT"].flatMap(Double.init) { model.shotAtISO100 = shot }
        return model
    }

    static func shot(iso: Double, model: BodyNoise = noise) -> Double { model.shotAtISO100 * iso / 100 }

    static func read(iso: Double, model: BodyNoise = noise) -> Double { model.read(iso: iso) }

    // MARK: Writing copies

    struct Layout {
        var width: Int
        var height: Int
        var strip: Int
        var cropX: Int
        var cropY: Int
        var cropWidth: Int
        var cropHeight: Int
        var black: Int
        var white: Int
        var cfa: [Int]
        var isoOffsets: [(offset: Int, long: Bool)]
    }

    static func layout(_ data: Data) throws -> Layout {
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        func entries(_ offset: Int) -> [Int: (type: Int, count: Int, value: Int)] {
            var out: [Int: (Int, Int, Int)] = [:]
            for i in 0..<u16(offset) {
                let e = offset + 2 + 12 * i
                let type = u16(e + 2), count = u32(e + 4)
                let size = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8][type, default: 1] * count
                out[u16(e)] = (type, count, size <= 4 ? e + 8 : u32(e + 8))
            }
            return out
        }
        func values(_ e: (type: Int, count: Int, value: Int)) -> [Int] {
            (0..<e.count).map { e.type == 3 ? u16(e.value + 2 * $0) : e.type == 4 ? u32(e.value + 4 * $0) : Int(data[e.value + $0]) }
        }
        let ifd0 = entries(u32(4))
        guard let sub = ifd0[0x014A], let exifPointer = ifd0[0x8769] else { throw ARWLayout.ReadError.noRawIFD }
        let raw = entries(values(sub)[0])
        guard let w = raw[0x100], let h = raw[0x101], let strip = raw[0x111], let count = raw[0x117], values(raw[0x103]!)[0] == 1,
              values(count)[0] == values(w)[0] * values(h)[0] * 2 else { throw ARWLayout.ReadError.noRawIFD }
        let exif = entries(values(exifPointer)[0])
        var isoOffsets: [(Int, Bool)] = []
        if let e = exif[0x8827] { isoOffsets.append((e.value, false)) }
        if let e = exif[0x8832] { isoOffsets.append((e.value, true)) }
        let origin = values(raw[0xC61F]!), size = values(raw[0xC620]!)
        return Layout(width: values(w)[0], height: values(h)[0], strip: values(strip)[0], cropX: origin[0], cropY: origin[1],
                      cropWidth: size[0], cropHeight: size[1], black: values(raw[0x7310]!)[0], white: values(raw[0xC61D]!)[0],
                      cfa: values(raw[0x828E]!), isoOffsets: isoOffsets)
    }

    /// A seeded Gaussian source (xoshiro256** and Box-Muller), so a copy is the same every run.
    struct Gaussian {
        var s: (UInt64, UInt64, UInt64, UInt64)
        var spare: Double?

        init(seed: UInt64) {
            var z = seed &+ 0x9E37_79B9_7F4A_7C15
            func next() -> UInt64 {
                z = z &+ 0x9E37_79B9_7F4A_7C15
                var x = z
                x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
                x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
                return x ^ (x >> 31)
            }
            s = (next(), next(), next(), next())
        }

        mutating func uniform() -> Double {
            let result = ((s.1 &* 5) << 7 | (s.1 &* 5) >> 57) &* 9
            let t = s.1 << 17
            s.2 ^= s.0; s.3 ^= s.1; s.1 ^= s.2; s.0 ^= s.3; s.2 ^= t
            s.3 = s.3 << 45 | s.3 >> 19
            return (Double(result >> 11) + 0.5) / 9_007_199_254_740_992
        }

        mutating func next() -> Double {
            if let v = spare { spare = nil; return v }
            let r = (-2 * log(uniform())).squareRoot(), a = 2 * Double.pi * uniform()
            spare = r * sin(a)
            return r * cos(a)
        }
    }

    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("argent-synthetic-raws")
    /// The folder of the suite run writing raws (`SyntheticRawFolder`), so one suite's cleanup
    /// cannot take another's files.
    @TaskLocal static var scope = "unscoped"

    static var folder: URL {
        let url = root.appendingPathComponent(scope)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a copy of `source`, the CC0 sample unless given (any uncompressed ARW), with its ISO set
    /// unless `iso` is nil and its samples changed by `change(samples, layout)`.
    static func write(_ name: String, from source: URL = base, iso: Int?,
                      change: (UnsafeMutableBufferPointer<UInt16>, Layout) -> Void) throws -> URL {
        var data = try Data(contentsOf: source)
        let l = try layout(data)
        data.withUnsafeMutableBytes { bytes in
            for (offset, long) in l.isoOffsets {
                guard let iso else { break }
                if long {
                    bytes.storeBytes(of: UInt32(iso).littleEndian, toByteOffset: offset, as: UInt32.self)
                } else {
                    bytes.storeBytes(of: UInt16(min(iso, 65535)).littleEndian, toByteOffset: offset, as: UInt16.self)
                }
            }
            let samples = UnsafeMutableBufferPointer(start: (bytes.baseAddress! + l.strip).assumingMemoryBound(to: UInt16.self),
                                                     count: l.width * l.height)
            change(samples, l)
        }
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// The CC0 sample's scene at `iso`: the noise that ISO adds to the sample's own. With `stops`
    /// below 0, the scene that much darker, as if the light were dimmer and the camera exposed the
    /// same: the signal is scaled down and given the whole noise of `iso` at its new level (the
    /// sample's own noise scales down with it and is left in, a small addition).
    /// With `rectified`, every sample under black is raised to black, as a decoder that clips its
    /// input at black would see it (for telling whether Apple's decoder does). `model` replaces the
    /// noise model and `tag` the ISO written into the Exif, for measuring how the decoders respond to
    /// a frame whose noise is not its ISO's; `name` tells such copies apart.
    static func simulated(iso: Int, seed: UInt64 = 1, stops: Double = 0, rectified: Bool = false, model: BodyNoise = noise,
                          tag: Int? = nil, name label: String = "") throws -> URL {
        let gain = exp2(min(stops, 0))
        let addShot = gain < 1 ? shot(iso: Double(iso), model: model) : max(0, shot(iso: Double(iso), model: model) - shot(iso: baseISO, model: model))
        let addRead = gain < 1 ? read(iso: Double(iso), model: model) : max(0, read(iso: Double(iso), model: model) - read(iso: baseISO, model: model))
        let name = "simulated-iso\(iso)-seed\(seed)" + (gain < 1 ? String(format: "-%.2fEV", -stops) : "")
            + (rectified ? "-rectified" : "") + (tag.map { "-tag\($0)" } ?? "") + label + ".ARW"
        return try write(name, iso: tag ?? iso) { samples, l in
            var g = Gaussian(seed: seed &* 7919 &+ UInt64(iso))
            let black = Double(l.black), white = Double(l.white)
            let low = rectified ? black : 0
            for i in samples.indices {
                let v = Double(samples[i])
                let s = max(v - black, 0) * gain
                let noisy = (gain < 1 ? black + s : v) + g.next() * (addShot * s + addRead).squareRoot()
                samples[i] = UInt16(min(max(noisy.rounded(), low), white))
            }
        }
    }

    /// A flat patch of the raw frame: its corner and side in samples, and its camera RGB as fractions
    /// of the white level above black, red, green, blue.
    struct Patch {
        var x: Int
        var y: Int
        var side: Int
        var rgb: SIMD3<Double>
    }

    /// Camera RGB of a D55 neutral relative to green: a design aid for spreading colours around
    /// neutral, the inverse of Sony's own Daylight preset (2.398 and 1.651, M1's reading of the
    /// file's tags), so it owes nothing to the fit it serves.
    static let neutral = SIMD3<Double>(1 / 2.398, 1, 1 / 1.651)

    /// A grid of flat patches covering the crop: `colours`, a first row of neutral steps from 0.02 to
    /// 0.64 of green's clip and then chromaticities spread to `spread` stops either way in red and
    /// blue against green at luminances from 0.02 to 0.55, from a fixed seed; or `flat`, rows of
    /// neutral and three tints at eight levels a stop apart from 0.005 of green's clip.
    static func patchGrid(_ kind: String, layout l: Layout, spread: Double = 1.2, seed: UInt64 = 3) -> [Patch] {
        var patches: [Patch] = []
        var g = Gaussian(seed: seed)
        if kind == "colours" {
            let side = 288, columns = l.cropWidth / side, rows = l.cropHeight / side
            for r in 0..<rows {
                for c in 0..<columns {
                    var rgb: SIMD3<Double>
                    if r == 0 {
                        rgb = neutral * 0.02 * exp2(Double(c) * 5 / Double(max(columns - 1, 1)))
                    } else {
                        let dr = (2 * g.uniform() - 1) * spread, db = (2 * g.uniform() - 1) * spread
                        let level = exp2(log2(0.02) + g.uniform() * (log2(0.55) - log2(0.02)))
                        rgb = neutral * SIMD3(exp2(dr), 1, exp2(db)) * level
                        rgb *= min(1, 0.85 / rgb.max())
                    }
                    patches.append(Patch(x: l.cropX + c * side, y: l.cropY + r * side, side: side, rgb: rgb))
                }
            }
        } else {
            let side = 384, columns = l.cropWidth / side, rows = l.cropHeight / side
            let tints: [SIMD3<Double>] = kind == "neutral" ? [SIMD3(1, 1, 1)]
                : [SIMD3(1, 1, 1), SIMD3(1.6, 1, 0.7), SIMD3(0.7, 1, 1.5), SIMD3(1.4, 0.8, 1.3)]
            for r in 0..<rows {
                for c in 0..<columns {
                    var rgb = neutral * tints[r % tints.count] * 0.005 * exp2(Double(c % 8))
                    rgb *= min(1, 0.85 / rgb.max())
                    patches.append(Patch(x: l.cropX + c * side, y: l.cropY + r * side, side: side, rgb: rgb))
                }
            }
        }
        return patches
    }

    /// Flat patches (`patchGrid`) on a mid-gray ground, with the noise of `iso` when `noise` is set.
    static func patches(_ kind: String, iso: Int, noise: Bool, seed: UInt64 = 1, patternSeed: UInt64 = 3, model: BodyNoise = SyntheticRaw.noise,
                        name label: String = "") throws -> (url: URL, patches: [Patch], layout: Layout) {
        let l = try layout(try Data(contentsOf: base))
        let grid = patchGrid(kind, layout: l, seed: patternSeed)
        let shotVariance = shot(iso: Double(iso), model: model), readVariance = read(iso: Double(iso), model: model)
        let url = try write("patches-\(kind)-\(patternSeed)-iso\(iso)-\(noise ? "noise" : "clean")-seed\(seed)\(label).ARW", iso: iso) { samples, l in
            let range = Double(l.white - l.black), black = Double(l.black)
            var g = Gaussian(seed: seed &* 104_729 &+ UInt64(iso))
            var ground = [Double](repeating: 0, count: l.width * l.height)
            func colour(_ x: Int, _ y: Int) -> Int { l.cfa[(y & 1) * 2 + (x & 1)] }
            for y in 0..<l.height { for x in 0..<l.width { ground[y * l.width + x] = neutral[colour(x, y)] * 0.1 } }
            for p in grid {
                for y in p.y..<(p.y + p.side) { for x in p.x..<(p.x + p.side) { ground[y * l.width + x] = p.rgb[colour(x, y)] } }
            }
            for i in samples.indices {
                let s = ground[i] * range
                let v = noise ? s + g.next() * (shotVariance * s + readVariance).squareRoot() : s
                samples[i] = UInt16(min(max((v + black).rounded(), 0), Double(l.white)))
            }
        }
        return (url, grid, l)
    }
}

/// Gives a suite's synthetic raws a folder of their own and removes it when the suite has run:
/// they come to about 2 GB.
struct SyntheticRawFolder: SuiteTrait, TestTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let id = UUID().uuidString
        defer { try? FileManager.default.removeItem(at: SyntheticRaw.root.appendingPathComponent(id)) }
        try await SyntheticRaw.$scope.withValue(id) { try await function() }
    }
}

extension Trait where Self == SyntheticRawFolder {
    static var syntheticRaws: Self { Self() }
}
