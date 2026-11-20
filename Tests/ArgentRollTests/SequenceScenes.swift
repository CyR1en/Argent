import ArgentCore
import Foundation

/// Synthetic textured scenes and the `SequenceDescriptor`s of frames that view them, for the sequence
/// evidence's tests (`SequenceEvidenceTests`) and for counting chance links between unrelated scenes
/// (`SequenceEvidenceMeasureTests`).
enum SequenceScenes {
    /// A pseudo-random value in -1…1 for a lattice point, the same on every run.
    static func lattice(_ i: Int, _ j: Int, _ seed: UInt64) -> Float {
        var h = UInt64(bitPattern: Int64(i)) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(bitPattern: Int64(j)) &* 0xC2B2_AE3D_27D4_EB4F
            ^ (seed &+ 1) &* 0x1656_67B1_9E37_79F9
        h ^= h >> 33; h &*= 0xFF51_AFD7_ED55_8CCD; h ^= h >> 33; h &*= 0xC4CE_B9FE_1A85_EC53; h ^= h >> 33
        return Float(h >> 40) / Float(1 << 24) * 2 - 1
    }

    /// Smooth value noise over the plane, lattice points one unit apart.
    static func noise(_ p: SIMD2<Float>, _ seed: UInt64) -> Float {
        let x0 = p.x.rounded(.down), y0 = p.y.rounded(.down)
        let fx = p.x - x0, fy = p.y - y0
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let i = Int(x0), j = Int(y0)
        let bottom = lattice(i, j, seed) * (1 - sx) + lattice(i + 1, j, seed) * sx
        let top = lattice(i, j + 1, seed) * (1 - sx) + lattice(i + 1, j + 1, seed) * sx
        return bottom * (1 - sy) + top * sy
    }

    /// A textured scene's light in stops about mid-gray at a point, in cells of a 64 by 43 frame
    /// of it: shapes from a third of the frame down to under a cell, about a stop either way.
    static func texture(_ seed: UInt64) -> @Sendable (SIMD2<Float>) -> Float {
        { p in
            1.0 * noise(p / 12, seed) + 0.7 * noise(p / 5, seed &+ 1) + 0.45 * noise(p / 2, seed &+ 2)
                + 0.3 * noise(p / 0.7, seed &+ 3)
        }
    }

    /// A sky with no detail: two stops brighter at the top than at the bottom.
    static let sky: @Sendable (SIMD2<Float>) -> Float = { p in 0.5 + p.y / 21.5 }

    /// The descriptor of a frame `width` by `height` cells whose cell point p shows the scene at
    /// `view(p)`, its light `stops(view(p))` about mid-gray times `tint`, made as
    /// `SequenceDescriptor` makes it: each cell the mean of four by four samples, its detail their
    /// log2 luminance's spread. `masked` cells are zero, as Cube++'s cube is.
    static func descriptor(width: Int = 64, height: Int = 43, view: (SIMD2<Float>) -> SIMD2<Float> = { $0 },
                            stops: (SIMD2<Float>) -> Float, brighter: Float = 0,
                            tint: (SIMD2<Float>) -> SIMD3<Float> = { _ in SIMD3(repeating: 1) },
                            masked: (Int, Int) -> Bool = { _, _ in false }) -> SequenceDescriptor {
        var d = SequenceDescriptor(grid: ExposureAnalyzer.grid(pixels: [], width: 0, height: 0))
        d.width = width
        d.height = height
        let floor = 0.18 * exp2(ExposureAnalyzer.floorStops)
        for v in 0..<height {
            for u in 0..<width {
                var sum = SIMD3<Float>(repeating: 0), logs: [Float] = []
                for j in 0..<4 {
                    for i in 0..<4 {
                        let scene = view(SIMD2(Float(u) + (Float(i) + 0.5) / 4, Float(v) + (Float(j) + 0.5) / 4))
                        let light = 0.18 * exp2(stops(scene) + brighter) * tint(scene)
                        sum += light
                        logs.append(log2(max((light * Rec2020.luma).sum(), floor)))
                    }
                }
                let mean = logs.reduce(0, +) / 16
                let light = masked(u, v) ? SIMD3<Float>(repeating: 0) : sum / 16
                d.rgb += [light.x, light.y, light.z]
                d.unclipped.append(1)
                d.detail.append(masked(u, v) ? 0 : (logs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / 16).squareRoot())
            }
        }
        return d
    }

    /// `count` pairs of frames of unrelated textured scenes, each pair two scenes no other pair shows.
    static func unrelated(_ count: Int) -> [(SequenceDescriptor, SequenceDescriptor)] {
        (0..<count).map { k in
            (descriptor(stops: texture(1000 + 2 * UInt64(k))), descriptor(stops: texture(1001 + 2 * UInt64(k))))
        }
    }
}
