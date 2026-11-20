import CoreAI
import Foundation

/// Runs the bundled matting model, ViTMatte-S (Composition-1k) converted to Core AI (`scripts/convert-vitmatte.zsh`): one 1024 × 1024 tile in, as `image`
/// (1 × 4 × 1024 × 1024, half floats: normalised RGB and the trimap), `alpha` out (1 × 1 × 1024 × 1024, half floats). The tile loop, the trimap and the blend are
/// `SubjectMatte`'s. Research task Y2's model. Warm 68 ms a tile on the app's path, peak footprint 1171 MB alone and 1405 MB beside a resident DA3 (Y2, measured);
/// loaded, run and let go inside a click, inside the low-light rule only.
public actor MatteRunner {
    /// The tile's side.
    public static let side = 1024
    private var model: AIModel?
    private var function: InferenceFunction?
    private var inputDescriptor: NDArrayDescriptor?

    public init() {}

    public var isLoaded: Bool { function != nil }

    /// Loads the model at `url` with the one options value Argent uses, so it reads the compiled copy "Preparing masks" made.
    public func load(from url: URL) async throws {
        let model = try await AIModel(contentsOf: url, options: MaskModels.specializationOptions)
        let (function, descriptor) = try MaskModelError.mainFunction(of: model, expecting: [1, 4, Self.side, Self.side])
        self.model = model
        self.function = function
        inputDescriptor = descriptor
    }

    /// The alpha for `tile`, 4 × side × side half floats (R, G, B, trimap planes). A non-finite value is a failed click, never a broken mask.
    public func run(tile: [Float16]) async throws -> [Float] {
        guard let function, let inputDescriptor else { throw MaskModelError.notLoaded("the matting model") }
        guard tile.count == 4 * Self.side * Self.side else { throw MaskModelError.badInput("a tile of \(tile.count) values") }
        var outputs = try await function.run(inputs: ["image": try MaskModelError.array(tile, descriptor: inputDescriptor)])
        guard let output = outputs.remove("alpha")?.ndArray else { throw MaskModelError.missingOutput("alpha") }
        let alpha = try MaskModelError.flatten(output)
        guard alpha.count == Self.side * Self.side else { throw MaskModelError.missingOutput("alpha of \(Self.side) × \(Self.side)") }
        guard alpha.allSatisfy(\.isFinite) else { throw MaskModelError.nonFinite("the matting model's alpha") }
        return alpha
    }

    /// Lets the model go; the compiled copy stays on disk.
    public func unload() {
        function = nil
        inputDescriptor = nil
        model = nil
    }
}
