import CoreAI
import Foundation

/// Runs the bundled Subject region model, S3OD-sod converted to Core AI (`scripts/convert-s3od.zsh`): one padded 1024 × 1024 square in, black all round, as `image`
/// (1 × 3 × 1024 × 1024, half floats), and out `masks` (1 × 3 × 1024 × 1024, half floats: three sigmoid masks) and `iou` (1 × 3, 32-bit floats: their predicted IoUs).
/// Research task V4's runner. Warm 0.155 s on an idle GPU, 348 MB loaded and 605 MB peak running, 49 MB two seconds after `unload` (V4, measured); it is loaded, run and
/// let go inside a click, as EoMT is, so a develop never waits on it.
public actor S3odModelRunner {
    /// The square's side.
    public static let side = 1024
    /// Black all round, as S3OD's own predictor pads and V3 and V4 measured.
    public static let padding: ModelSquare.Padding = .black
    /// What a Subject seed's provenance records of its square (`model.square`).
    public static let squareRecipe = ModelSquare.recipe(side: side, padding: padding)
    private var model: AIModel?
    private var function: InferenceFunction?
    private var inputDescriptor: NDArrayDescriptor?

    public init() {}

    public var isLoaded: Bool { function != nil }

    /// Loads the model at `url` with the one options value Argent uses, so it reads the compiled copy "Preparing masks" made.
    public func load(from url: URL) async throws {
        let model = try await AIModel(contentsOf: url, options: MaskModels.specializationOptions)
        let (function, descriptor) = try MaskModelError.mainFunction(of: model, expecting: [1, 3, Self.side, Self.side])
        self.model = model
        self.function = function
        inputDescriptor = descriptor
    }

    /// The masks and IoUs for `square`, a `side` square (`ModelSquare(picture, side: S3odModelRunner.side, padding: S3odModelRunner.padding)`). Throws rather than returns
    /// a non-finite output: a failed click is the row's to say, never a NaN mask.
    public func run(_ square: ModelSquare) async throws -> S3odOutputs {
        guard let function, let inputDescriptor else { throw MaskModelError.notLoaded("the Subject model") }
        guard square.layout.side == Self.side else { throw MaskModelError.badInput("a \(square.layout.side) square for the \(Self.side) Subject model") }
        let started = ContinuousClock.now
        var outputs = try await function.run(inputs: ["image": try MaskModelError.array(square.input, descriptor: inputDescriptor)])
        guard let masksArray = outputs.remove("masks")?.ndArray else { throw MaskModelError.missingOutput("masks") }
        guard let iouArray = outputs.remove("iou")?.ndArray else { throw MaskModelError.missingOutput("iou") }
        let masks = try MaskModelError.flatten(masksArray), iou = try MaskModelError.flatten(iouArray)
        let plane = Self.side * Self.side
        guard masks.count == S3odOutputs.maskCount * plane, iou.count == S3odOutputs.maskCount else {
            throw MaskModelError.missingOutput("masks of \(S3odOutputs.maskCount) × \(Self.side) × \(Self.side) and \(S3odOutputs.maskCount) IoUs")
        }
        guard masks.allSatisfy(\.isFinite), iou.allSatisfy(\.isFinite) else { throw MaskModelError.nonFinite("the Subject model's masks or IoUs") }
        return S3odOutputs(layout: square.layout, masks: masks, iou: iou, seconds: (ContinuousClock.now - started).seconds)
    }

    /// Lets the model go; the compiled copy stays on disk.
    public func unload() {
        function = nil
        inputDescriptor = nil
        model = nil
    }
}

/// What the Subject model returns for one square: three masks over the whole square, row-major, one after the other, the three IoUs, and the square's layout.
public struct S3odOutputs: Sendable {
    public static let maskCount = 3

    public let layout: ModelSquareLayout
    /// `maskCount` planes of `S3odModelRunner.side` squared values, 0...1, one after the other.
    public let masks: [Float]
    public let iou: [Float]
    public let seconds: Double

    public init(layout: ModelSquareLayout, masks: [Float], iou: [Float], seconds: Double = 0) {
        self.layout = layout; self.masks = masks; self.iou = iou; self.seconds = seconds
    }

    /// The argmax of the predicted IoUs, by the frozen `max` on the IoU's order (V4's selection).
    public var selectedIndex: Int { iou.indices.max { iou[$0] < iou[$1] } ?? 0 }

    /// The selected mask cropped to the picture's content, row-major.
    public var selectedContent: [Float] {
        let plane = S3odModelRunner.side * S3odModelRunner.side, k = selectedIndex
        return ModelSquare.crop(Array(masks[(k * plane)..<((k + 1) * plane)]), planeSide: S3odModelRunner.side, layout: layout)
    }

    /// The SHA-256 of the outputs as the model returned them, masks in half floats, then the IoUs in 32-bit floats: the canary's hash (`canary_s3od.py`).
    public var digest: String { MaskModelError.digest(ofHalves: [masks], thenFloats: [iou]) }
}
