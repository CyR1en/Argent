import CoreAI
import Foundation

/// Runs the bundled water model, EoMT-DINOv3-L (ADE20K-150) converted to Core AI (`scripts/convert-eomt.zsh`): one padded 768 × 768
/// square in, as `image` (1 × 3 × 768 × 768, half floats), `maps` out (1 × 3 × 192 × 192): the summed probability of ADE20K's water
/// classes (water, sea, river, lake, waterfall, swimming pool, fountain), the sky class, and the index of the most probable of the 150
/// classes (docs/masking-plan.md section 3; P0-S5's runner). The Sky mask's reflection veto reads the water plane; the veto itself is
/// `WaterVeto`'s. Warm 0.111 s a call on an idle GPU, 0.239 s while another GPU job runs; 231 MB loaded, about 584 MB running, and
/// loaded for a gated click and unloaded after it (+0.09 s to load from the compiled copy, S5).
public actor EomtModelRunner {
    /// The square's side; the maps are a quarter of it.
    public static let side = 768
    public static let mapSide = side / 4
    /// The edge repeated, as P0-S5's square, which the veto's golden water maps were made with.
    public static let padding: ModelSquare.Padding = .edge
    private var model: AIModel?
    private var function: InferenceFunction?
    private var inputDescriptor: NDArrayDescriptor?

    public init() {}

    public var isLoaded: Bool { function != nil }

    /// Loads the model at `url` with the one options value Argent uses.
    public func load(from url: URL) async throws {
        let model = try await AIModel(contentsOf: url, options: MaskModels.specializationOptions)
        let (function, descriptor) = try MaskModelError.mainFunction(of: model, expecting: [1, 3, Self.side, Self.side])
        self.model = model
        self.function = function
        inputDescriptor = descriptor
    }

    /// The maps for `square`, which must be a `side` square (`ModelSquare(picture, side: EomtModelRunner.side)`).
    public func run(_ square: ModelSquare) async throws -> EomtMaps {
        guard let function, let inputDescriptor else { throw MaskModelError.notLoaded("the water model") }
        guard square.layout.side == Self.side else { throw MaskModelError.badInput("a \(square.layout.side) square for the \(Self.side) water model") }
        let started = ContinuousClock.now
        var outputs = try await function.run(inputs: ["image": try MaskModelError.array(square.input, descriptor: inputDescriptor)])
        guard let maps = outputs.remove("maps")?.ndArray else { throw MaskModelError.missingOutput("maps") }
        let flat = try MaskModelError.flatten(maps)
        let plane = Self.mapSide * Self.mapSide
        guard flat.count == 3 * plane else { throw MaskModelError.missingOutput("maps of 3 × \(Self.mapSide) × \(Self.mapSide)") }
        return EomtMaps(layout: square.layout, water: Array(flat[0..<plane]), sky: Array(flat[plane..<(2 * plane)]),
                        classIndex: Array(flat[(2 * plane)...]), seconds: (ContinuousClock.now - started).seconds)
    }

    /// Lets the model go; the compiled copy stays on disk.
    public func unload() {
        function = nil
        inputDescriptor = nil
        model = nil
    }
}

/// What the water model returns for one square: three planes of `EomtModelRunner.mapSide` squared values over the whole square,
/// row-major, and the square's layout.
public struct EomtMaps: Sendable {
    public let layout: ModelSquareLayout
    /// The summed probability of the water classes, 0...1.
    public let water: [Float]
    /// The sky class's probability.
    public let sky: [Float]
    /// The most probable class, 0...149, exact in half floats.
    public let classIndex: [Float]
    public let seconds: Double

    public init(layout: ModelSquareLayout, water: [Float], sky: [Float], classIndex: [Float], seconds: Double = 0) {
        self.layout = layout; self.water = water; self.sky = sky; self.classIndex = classIndex; self.seconds = seconds
    }

    /// `plane` (one of the three) sampled at the pixel centres of a `width` by `height` grid over the picture's content, the seed's
    /// grid: what S5's veto read (`EomtInput.resample`, bilinear, its golden masks to under 1e-5).
    public func resampled(_ plane: [Float], toWidth width: Int, height: Int) -> [Float] {
        ModelSquare.resample(plane, planeSide: EomtModelRunner.mapSide, layout: layout, toWidth: width, height: height)
    }

    /// The SHA-256 of the maps as the model returned them, half floats, water, sky and class in that order: the canary's hash
    /// (`63bdb66c…` on the CC0 sample, P0-S5), and what a seed's provenance records of the maps it was vetoed with.
    public var digest: String { MaskModelError.digest(of: [water, sky, classIndex]) }
}
