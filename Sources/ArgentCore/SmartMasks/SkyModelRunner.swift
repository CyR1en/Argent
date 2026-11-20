import CoreAI
import CryptoKit
import Foundation

/// Runs the bundled Sky model, Depth Anything 3 Mono-Large's sky and depth heads converted to Core AI (`scripts/convert-da3-sky.zsh`):
/// one padded 756 × 756 square in, as `image` (1 × 1 × 3 × 756 × 756, half floats), `sky` and `depth` out, each 756 × 756, from one
/// call (docs/masking-plan.md section 3). P0-S1b's runner, with the square kept beside the outputs. Warm, 0.225 s a call on an idle
/// GPU and about twice that while another job holds it (S1b); 277 MB loaded, about 610 MB while running, 81 MB two seconds after
/// `unload` (S5). The compiled copy stays in Core AI's cache after an unload; `MaskModels` decides when to load and unload.
public actor SkyModelRunner {
    /// The square's side.
    public static let side = 756
    /// DA3's patch, in the square's pixels: its ViT-L/14 sees the 756 square as 54 × 54 patches.
    public static let patch = 14
    /// One patch of the picture mirrored past its edges, then that patch's last line repeated (`ModelSquare.Padding`). With the edge
    /// repeated all the way, as P0-S1b's square had it, DA3 left a seed's outer columns at 190 to 245 of 255 over open sky on portraits
    /// and its top rows on some landscapes, a pale strip at fit once refined (task D); with one patch mirrored they read 255 and the
    /// refined coverage at the edge 1.000 (DSC04059's left, Y-JG-SONY-A7-IV-0405's top; task H, measured). Mirroring the whole margin
    /// fixed those too, but a landscape's top mirrored whole reads as a reflection: on DSC04080 it lost the sky in the top fifth.
    public static let padding = ModelSquare.Padding(mirrored: patch)
    /// What a Sky seed's provenance records of its square (`model.square`). A seed without it was cut from the edge-repeated square.
    public static let squareRecipe = ModelSquare.recipe(side: side, padding: padding)
    private var model: AIModel?
    private var function: InferenceFunction?
    private var inputDescriptor: NDArrayDescriptor?

    public init() {}

    public var isLoaded: Bool { function != nil }

    /// Loads the model at `url` with the one options value Argent uses, so it reads the compiled copy "Preparing masks" made.
    /// About 0.14 s with the compiled copy present (S1b).
    public func load(from url: URL) async throws {
        let model = try await AIModel(contentsOf: url, options: MaskModels.specializationOptions)
        let (function, descriptor) = try MaskModelError.mainFunction(of: model, expecting: [1, 1, 3, Self.side, Self.side])
        self.model = model
        self.function = function
        inputDescriptor = descriptor
    }

    /// Sky and depth for `square`, which must be a `side` square (`ModelSquare(picture, side: SkyModelRunner.side)`).
    public func run(_ square: ModelSquare) async throws -> SkyOutputs {
        guard let function, let inputDescriptor else { throw MaskModelError.notLoaded("the Sky model") }
        guard square.layout.side == Self.side else { throw MaskModelError.badInput("a \(square.layout.side) square for the \(Self.side) Sky model") }
        let started = ContinuousClock.now
        var outputs = try await function.run(inputs: ["image": try MaskModelError.array(square.input, descriptor: inputDescriptor)])
        guard let sky = outputs.remove("sky")?.ndArray else { throw MaskModelError.missingOutput("sky") }
        guard let depth = outputs.remove("depth")?.ndArray else { throw MaskModelError.missingOutput("depth") }
        let skyPlane = try MaskModelError.flatten(sky), depthPlane = try MaskModelError.flatten(depth)
        let plane = Self.side * Self.side
        guard skyPlane.count == plane, depthPlane.count == plane else { throw MaskModelError.missingOutput("sky and depth of \(Self.side) × \(Self.side)") }
        return SkyOutputs(layout: square.layout, padding: square.padding, sky: skyPlane, depth: depthPlane,
                          seconds: (ContinuousClock.now - started).seconds)
    }

    /// Lets the model go; the compiled copy stays on disk. The footprint settles about two seconds later (S1b, S5).
    public func unload() {
        function = nil
        inputDescriptor = nil
        model = nil
    }
}

/// What the Sky model returns for one square: both heads over the whole square, row-major, and the square's layout to crop them.
public struct SkyOutputs: Sendable {
    /// The seed's cap: the sky head is clipped to 0...0.6 and divided by 0.6 (R4, R9; S1b kept it, as a lower cap traded twig
    /// leak for sky deficit almost one for one).
    public static let seedCap: Float = 0.6

    public let layout: ModelSquareLayout
    /// How the square was padded around the picture.
    public let padding: ModelSquare.Padding
    /// The sky head, `SkyModelRunner.side` squared values, the model's own (relu'd) output.
    public let sky: [Float]
    /// The depth head, the same size, in the model's relative units.
    public let depth: [Float]
    /// The call, with the outputs read into arrays.
    public let seconds: Double

    public init(layout: ModelSquareLayout, padding: ModelSquare.Padding, sky: [Float], depth: [Float],
                seconds: Double = 0) {
        self.layout = layout; self.padding = padding; self.sky = sky; self.depth = depth; self.seconds = seconds
    }

    /// What the seed's provenance records of the square (`ModelSquare.recipe`).
    public var squareRecipe: String { ModelSquare.recipe(side: layout.side, padding: padding) }

    /// The Sky seed: the sky head over the picture's content (756 × 504 for a 3:2 landscape frame), clip(sky, 0, 0.6) / 0.6, row-major
    /// from the top (S1b section 3.8). Stored in 8 bits by the seed store, refined at render time.
    public var seed: (values: [Float], width: Int, height: Int) {
        let crop = ModelSquare.crop(sky, planeSide: SkyModelRunner.side, layout: layout)
        return (crop.map { min(max($0, 0), Self.seedCap) / Self.seedCap }, layout.contentWidth, layout.contentHeight)
    }

    /// The SHA-256 of the outputs as the model returned them, half floats, sky then depth: the canary's hash, equal to Python's
    /// `canary_check.py` on the same square.
    public var digest: String { MaskModelError.digest(of: [sky, depth]) }
}
