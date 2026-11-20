import ArgentCore
import ArgentRoll
import Foundation

/// Where the overlay reads a smart selection's refined edge on a frame: the previews' (`FilmPreviews.refinedSelection`).
protocol MaskRefinedSelectionSource: AnyObject, Sendable {
    func refinedSelection(_ selection: SmartSelection, on frame: Frame, lens: LensSettings, width: Int, height: Int) -> [UInt8]?
    /// `mask`'s coverage over `fractions` of the picture on `frame`, as the print reads it on the decode of the film `pixels` long (`GPU.regionCoverage`).
    func regionCoverage(of mask: Mask, version: String, on frame: Frame, lens: LensSettings, pixels: Int, fractions: CGRect) async -> RegionCoverage?
}

extension FilmPreviews: MaskRefinedSelectionSource {}

/// The overlay's and the list thumbnails' coverage when a mask holds a smart selection, Background read as `1 − v` and composed with
/// the mask's other components by the bake's own rule (add `c + v − cv`, subtract `c(1 − v)`, intersect with the component inverted).
/// The overlay over a frame reads the selection as the print does, refined on the frame view's decode (task D), at the overlay's
/// size (`refined`, `FilmPreviews.refinedSelection`, blurred by its Feather): built once a seed and decode, so a refresh runs no refinement. Until that decode
/// is held, and for the list's thumbnails, it is the seed as stored, read from the library and stretched over the picture as the
/// coverage engine stretches it (`uv = (x + 0.5) / w` on both axes): so the red shows the selection the moment it lands, before any
/// print, within the seed's own softness of the refined edge. A mask without a selection goes to `MaskCoverageReference` unchanged;
/// a selection not made yet, or a seed that cannot be read, selects nothing. A Follow edges stroke's measured shape is read from the same
/// library, through the same loader.
final class MaskSeedCoverage: MaskCoverageField, @unchecked Sendable {
    private let lock = NSLock()
    private var provider: (any MaskSeedProvider)?
    private weak var refinedSource: (any MaskRefinedSelectionSource)?

    /// Over `store`, with a loader of its own: a test's, or an overlay with no model behind it.
    init(store: MaskRasterStore? = nil) { provider = store.map { StoredMaskSeeds(store: $0) } }

    /// Where seeds and measured shapes are read from: the model's one loader over its library (`StoredMaskSeeds`), set once it is
    /// known, which the previews' renders and the pins read through too. So a seed is read from disk, checked against its name
    /// and kept once for all three, where each had a loader and a cache of its own.
    var seeds: (any MaskSeedProvider)? {
        get { lock.withLock { provider } }
        set { lock.withLock { provider = newValue } }
    }

    /// Where a refined edge is read from on a frame: the model's previews.
    var refined: (any MaskRefinedSelectionSource)? {
        get { lock.withLock { refinedSource } }
        set { lock.withLock { refinedSource = newValue } }
    }

    func raster(of components: [MaskComponent], width: Int, height: Int) -> [UInt8] {
        raster(of: components, width: width, height: height, on: nil, lens: nil)
    }

    func sharpRaster(of request: MaskOverlaySharpRequest) async -> RegionCoverage? {
        var components = request.components
        guard !components.isEmpty, let pixels = request.decode.pixels else { return nil }
        // What is first is added, as a mask's first always is; the set's compiler is the frame's.
        components[0].operation = .add
        var adjustments = ManualAdjustments.identity
        // Tier 2 is decided by Exposure alone, and only the tier comes of it here: the bake reads no slider (rule 2).
        if request.perPixel, let exposed = try? ManualAdjustments(exposureEV: 1) { adjustments = exposed }
        return await refined?.regionCoverage(of: Mask(components: components, adjustments: adjustments), version: request.version, on: request.frame, lens: request.lens?.settings ?? .default,
                                             pixels: pixels, fractions: request.fractions)
    }

    func raster(of components: [MaskComponent], width: Int, height: Int, on frame: Frame?, lens: MaskEditor.PictureLens?) -> [UInt8] {
        guard width > 0, height > 0 else { return [] }
        let extent = MaskPoint(x: Float(width) / Float(max(width, height)), y: Float(height) / Float(max(width, height)))
        let map = lens.map { MaskLens(picture: $0.lens.picture, legacy: $0.lens.legacy, extent: extent) }
        guard components.contains(where: { if case .smart = $0.shape { true } else { false } }) else {
            return MaskCoverageReference(shapes: seeds, lens: map).raster(of: components, width: width, height: height)
        }
        let count = width * height
        var c = [Float](repeating: 0, count: count)
        for (index, component) in components.enumerated() {
            // What is first now is added, as a mask's first always is.
            let operation: MaskOperation = index == 0 ? .add : component.operation
            let inverted = component.invert != (operation == .intersect)
            let v = values(of: component.shape, inverted: inverted, width: width, height: height, on: frame, lens: lens) ?? [Float](repeating: 0, count: count)
            if operation == .add {
                for i in 0..<count { c[i] = c[i] + v[i] - c[i] * v[i] }
            } else {
                for i in 0..<count { c[i] *= 1 - v[i] }
            }
        }
        return c.map { UInt8(min(255, max(0, $0 * 255 + 0.5))) }
    }

    /// One component's coverage over the picture, top row first, with its invert; `nil` for nothing selected.
    private func values(of shape: MaskShape, inverted: Bool, width: Int, height: Int, on frame: Frame?, lens: MaskEditor.PictureLens?) -> [Float]? {
        switch shape {
        case .smart(let selection):
            let complement = selection.kind == .background ? !inverted : inverted
            if let frame, let refined = refined?.refinedSelection(selection, on: frame, lens: lens?.settings ?? .default, width: width, height: height) {
                return refined.map { complement ? 1 - Float($0) / 255 : Float($0) / 255 }
            }
            guard let ref = selection.raster, let seed = seed(ref) else { return nil }
            // The seed under the selection's Feather, blurred at the overlay's size over the same share of the long side as the print.
            return MaskFeather.blurred(Self.stretched(seed, width: width, height: height, complement: complement), width: width, height: height,
                                       feather: selection.feather)
        case .linear, .radial, .brush:
            return try? MaskCoverage.reference(Mask(components: [MaskComponent(shape: shape, invert: inverted)]), width: width, height: height,
                                               shapes: seeds, lens: lens.map { MaskLens(picture: $0.lens.picture, legacy: $0.lens.legacy,
                                                                                       extent: MaskPoint(x: Float(width) / Float(max(width, height)), y: Float(height) / Float(max(width, height)))) })
        }
    }

    private func seed(_ ref: RasterRef) -> MaskRaster? { try? seeds?.seed(for: ref) }

    /// `seed` sampled bilinearly at each pixel's centre of a `width` by `height` picture, the seed stretched over the whole picture
    /// whatever its own aspect (Person's 4:3 over a 3:2 frame), 0 to 1, top row first; with `complement`, `1 − v`.
    static func stretched(_ seed: MaskRaster, width: Int, height: Int, complement: Bool) -> [Float] {
        let sw = seed.width, sh = seed.height
        var out = [Float](repeating: 0, count: width * height)
        seed.plane.withUnsafeBufferPointer { plane in
            for y in 0..<height {
                let fy = min(max((Float(y) + 0.5) / Float(height) * Float(sh) - 0.5, 0), Float(sh - 1))
                let y0 = Int(fy), y1 = min(y0 + 1, sh - 1), ty = fy - Float(y0)
                for x in 0..<width {
                    let fx = min(max((Float(x) + 0.5) / Float(width) * Float(sw) - 0.5, 0), Float(sw - 1))
                    let x0 = Int(fx), x1 = min(x0 + 1, sw - 1), tx = fx - Float(x0)
                    let top = Float(plane[y0 * sw + x0]) * (1 - tx) + Float(plane[y0 * sw + x1]) * tx
                    let bottom = Float(plane[y1 * sw + x0]) * (1 - tx) + Float(plane[y1 * sw + x1]) * tx
                    let v = (top * (1 - ty) + bottom * ty) / 255
                    out[y * width + x] = complement ? 1 - v : v
                }
            }
        }
        return out
    }
}
