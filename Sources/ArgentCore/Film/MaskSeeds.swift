import Foundation

// What a render reads of the smart masks' seeds: the pinned rasters themselves, loaded once and checked against their names before
// the render starts, so a print never runs a model and never prints without a seed it needs (masking-plan section 7). The rasters
// live in ArgentRoll's `MaskRasterStore`; this is what one render holds of them.

/// The seeds one render reads, by name. Each was checked against its `RasterID` when it was loaded (`MaskRasterStore.load`), so
/// holding one means holding the pixels the edit pinned, byte for byte, whatever has happened to the files since.
public struct MaskSeeds: Sendable, Equatable {
    public static let none = MaskSeeds()

    public let rasters: [RasterID: MaskRaster]

    public init(_ rasters: [MaskRaster] = []) {
        self.rasters = Dictionary(rasters.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The seed `ref` names, if this set holds it at that size.
    public subscript(ref: RasterRef) -> MaskRaster? {
        guard let raster = rasters[ref.id], raster.width == ref.width, raster.height == ref.height else { return nil }
        return raster
    }

    /// The bytes the planes hold, for a develop's memory gate.
    public var byteCount: Int { rasters.values.reduce(0) { $0 + $1.plane.count } }

    /// One byte a pixel for each distinct seed `refs` names: what holding them costs once loaded.
    public static func byteCount(of refs: [RasterRef]) -> Int {
        Dictionary(refs.map { ($0.id, $0.width * $0.height) }, uniquingKeysWith: { first, _ in first }).values.reduce(0, +)
    }

    /// What a render of `manual` reads of the seeds. None when no mask changes a pixel, since the render then takes today's kernels and
    /// reads no mask at all (`ManualRenderSettings.hasEffectiveMasks`). Otherwise, the seeds of every mask that is on, each once, in
    /// list order, a Follow edges stroke's measured shape among them, and the kinds of the selections a mask that is on has not made
    /// yet: a develop refuses those rather than print the mask as covering nothing. A mask that is off is not read, so its seed is not
    /// needed to print.
    public static func needs(_ manual: ManualRenderSettings) -> Needs {
        guard manual.hasEffectiveMasks else { return Needs(rasters: [], pending: []) }
        var rasters: [RasterRef] = [], seen = Set<RasterID>(), pending: [SmartKind] = []
        for mask in manual.adjustments.masks.masks where mask.isEnabled {
            for component in mask.components {
                if case .brush(let paint) = component.shape {
                    for raster in paint.strokes.compactMap(\.measured?.raster) where seen.insert(raster.id).inserted { rasters.append(raster) }
                }
                guard case .smart(let selection) = component.shape else { continue }
                if let raster = selection.raster {
                    if seen.insert(raster.id).inserted { rasters.append(raster) }
                } else {
                    pending.append(selection.kind)
                }
            }
        }
        return Needs(rasters: rasters, pending: pending)
    }

    public struct Needs: Sendable, Equatable {
        public let rasters: [RasterRef]
        public let pending: [SmartKind]
        public var isEmpty: Bool { rasters.isEmpty && pending.isEmpty }
    }
}
