import ArgentCore
import CoreAI
import CryptoKit
import Darwin
import Foundation

/// The four graphs package H1 converted (`scripts/convert-objectclear.zsh`), built into `build/models/` and cloned into the app's
/// `Contents/Resources/Models/`. A conversion is not byte-deterministic, so each graph is named by its recipe id and its outputs'
/// hash on the canary input (`scripts/models/objectclear_canary.py`); these are pinned here, and a folder whose manifests say
/// otherwise is refused, as `MaskModels.identity(of:)` refuses a mask model. Every input and output is a 32-bit float.
enum ObjectClearGraph: String, CaseIterable, Sendable, Codable {
    /// CLIP ViT-L/14 vision and the fusion module: the object, 224 square, to the row that stands for it in the prompt.
    case objectEncoder = "objectclear-object-encoder"
    case vaeEncoder = "objectclear-vae-encoder"
    /// The UNet, with the cross-attention at the object's token as a second output.
    case unet = "objectclear-unet"
    case vaeDecoder = "objectclear-vae-decoder"

    var fileName: String { rawValue + ".aimodel" }
    var manifestName: String { rawValue + ".manifest.json" }

    var recipeID: String { "objectclear-c052d91-sym64to1344-f16-1-" + recipeSuffix }

    private var recipeSuffix: String {
        switch self {
        case .objectEncoder: "object_encoder"
        case .vaeEncoder: "vae_encoder"
        case .unet: "unet"
        case .vaeDecoder: "vae_decoder"
        }
    }

    /// The SHA-256 of its float32 outputs on the canary input, in output order (measured by H1 in Python, four conversions alike).
    var canarySHA256: String {
        switch self {
        case .objectEncoder: "c428d36849a4be7e69efb5f3232b29e5490ce7a2cb4fd4272669591df7e82f91"
        case .vaeEncoder: "539a7d750adf0abd113940bfd58db5ee2d1080b71563db429c3ebacfaf2cb890"
        case .unet: "2bb82a3ae1d28130a0de4fa07a624af7804a6cb9359f8d45ee7c4327a766c9b4"
        case .vaeDecoder: "cc781c1c5e6e0129ab0a8f5f761db9c1f490040a060ba75fbe81862853ec0bbe"
        }
    }

    /// The SHA-256 of the canary input itself, the float32 inputs in input order.
    var canaryInputSHA256: String {
        switch self {
        case .objectEncoder: "b50897a8bdea79c915def9c8c8e8808464cf5085b0af8fe3dc0461fc1ce2348c"
        case .vaeEncoder: "376d63130e3e5118e2a5658b610d56332ad2eb751da1b6d829fca4ec88dce261"
        case .unet: "249e704421cd2f63beaa597856d5e39777e406f1402384bda1eedd5b6eb621e0"
        case .vaeDecoder: "f5b3d43b0790c8b78450438ca8440688e2378047877413e55eba504fac05a9b5"
        }
    }

    var inputNames: [String] {
        switch self {
        case .objectEncoder: ["object"]
        case .vaeEncoder: ["picture"]
        case .unet: ["sample", "timestep", "states", "pooled", "time_ids"]
        case .vaeDecoder: ["latents"]
        }
    }

    var outputNames: [String] {
        switch self {
        case .objectEncoder: ["fused", "embeds"]
        case .vaeEncoder: ["moments"]
        case .unet: ["noise", "attention"]
        case .vaeDecoder: ["picture"]
        }
    }

    /// Whether its height and width are the working size's, compiled for each size at the first call with it.
    var isSized: Bool { self != .objectEncoder }

    /// Seconds of the one-time preparation, for its fraction only: H1's first loads, about 8 s for the UNet and under 1 s each else.
    var preparationWeight: Double { self == .unet ? 8 : 1 }

    /// The canary's inputs: value `i` of a tensor is `((i + salt) * 2654435761 mod 2^32) >> 8` over 2^24, times 2, less 1, at 512
    /// high and 768 wide (`objectclear_canary.py`), so Swift builds the same bytes as Python.
    var canaryInputs: [(name: String, values: [Float], shape: [Int])] {
        let height = 512, width = 768, h = height / 8, w = width / 8
        func pattern(_ shape: [Int], _ salt: UInt64) -> [Float] {
            (0..<UInt64(shape.reduce(1, *))).map { i in
                let v = (((i + salt) &* 2_654_435_761) & 0xFFFF_FFFF) >> 8
                return Float(v) / Float(1 << 24) * 2 - 1
            }
        }
        switch self {
        case .vaeDecoder: return [("latents", pattern([1, 4, h, w], 1), [1, 4, h, w])]
        case .vaeEncoder: return [("picture", pattern([1, 3, height, width], 2), [1, 3, height, width])]
        case .objectEncoder: return [("object", pattern([1, 3, 224, 224], 3), [1, 3, 224, 224])]
        case .unet:
            let ids = [Float(height), Float(width), 0, 0, Float(height), Float(width)]
            return [("sample", pattern([1, 9, h, w], 4), [1, 9, h, w]), ("timestep", [501], [1]),
                    ("states", pattern([1, 77, 2048], 5), [1, 77, 2048]), ("pooled", pattern([1, 1280], 6), [1, 1280]),
                    ("time_ids", ids, [1, 6])]
        }
    }
}

enum ObjectClearError: Error, CustomStringConvertible, Equatable {
    /// The folder lacks a graph, or holds one the pins do not name: why, and how to build it.
    case unavailable(String)
    /// A call gave no usable answer: why. Never a picture.
    case failed(String)

    var description: String {
        switch self {
        case .unavailable(let why): "The model is unavailable: \(why)"
        case .failed(let why): why
        }
    }
}

/// The model's folder: the four graphs, their manifests and the fixed text states, checked before anything is loaded.
struct ObjectClearFolder: Sendable {
    static let textStatesFile = "objectclear-text-states.f16"
    /// The text states' SHA-256: the same on every run of the recipe (H1).
    static let textStatesSHA256 = "1e180c5ec607d149b4e3b4cb839f5f67e7a8c6df7b95aa5964cb0d94cfef6a80"
    /// The UNet's weights, `unet/diffusion_pytorch_model.fp16.safetensors`: what a removal records as the model that drew it.
    static let weightsSHA256 = "fb0c35b0be8bba4ecd61dfca4e716a0a9878639c5fc271a05a780b4dc2366c31"
    static let script = "scripts/convert-objectclear.zsh"

    let directory: URL

    func url(of graph: ObjectClearGraph) -> URL { directory.appendingPathComponent(graph.fileName, isDirectory: true) }

    /// `main.hash` of each graph, after checking its manifest against the pins: this conversion, and Core AI's key for its
    /// compiled copy.
    func check() throws -> [ObjectClearGraph: String] {
        var hashes: [ObjectClearGraph: String] = [:]
        for graph in ObjectClearGraph.allCases {
            guard let hash = try? Data(contentsOf: url(of: graph).appendingPathComponent("main.hash")), hash.count == 32 else {
                throw ObjectClearError.unavailable("\(graph.fileName) is not in \(directory.path); build it with \(Self.script)")
            }
            struct Manifest: Decodable {
                var recipeID: String, canary: String, canaryInput: String
                enum CodingKeys: String, CodingKey {
                    case recipeID = "recipe id", canary = "canary output sha256", canaryInput = "canary input sha256"
                }
            }
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(graph.manifestName)),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
                throw ObjectClearError.unavailable("\(graph.manifestName) is missing or unreadable; build the model again with \(Self.script)")
            }
            guard manifest.recipeID == graph.recipeID, manifest.canary == graph.canarySHA256,
                  manifest.canaryInput == graph.canaryInputSHA256 else {
                throw ObjectClearError.unavailable("\(graph.fileName) was built by recipe \(manifest.recipeID) with canary "
                                                   + "\(manifest.canary.prefix(8)), not \(graph.recipeID) with \(graph.canarySHA256.prefix(8)); "
                                                   + "build it again with \(Self.script)")
            }
            if graph == .unet {
                struct Weights: Decodable {
                    var weights: String
                    enum CodingKeys: String, CodingKey { case weights = "weights sha256" }
                }
                guard (try? JSONDecoder().decode(Weights.self, from: data))?.weights == Self.weightsSHA256 else {
                    throw ObjectClearError.unavailable("\(graph.manifestName) names other weights than \(Self.weightsSHA256.prefix(8))")
                }
            }
            hashes[graph] = hash.map { String(format: "%02x", $0) }.joined()
        }
        return hashes
    }

    /// The prompt's fixed states (`1 x 77 x 2048`) and pooled state (`1 x 1280`), checked against their hash.
    func textStates() throws -> (states: [Float], pooled: [Float]) {
        let file = directory.appendingPathComponent(Self.textStatesFile)
        guard let data = try? Data(contentsOf: file) else {
            throw ObjectClearError.unavailable("\(Self.textStatesFile) is not in \(directory.path); build it with \(Self.script)")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let count = ObjectClear.tokens * ObjectClear.stateWidth + ObjectClear.pooledWidth
        guard digest == Self.textStatesSHA256, data.count == 2 * count else {
            throw ObjectClearError.unavailable("\(Self.textStatesFile) is not the recipe's (\(digest.prefix(8))); build it again with \(Self.script)")
        }
        let values = data.withUnsafeBytes { raw in
            (0..<count).map { Float(Float16(bitPattern: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 2 * $0, as: UInt16.self)))) }
        }
        let split = ObjectClear.tokens * ObjectClear.stateWidth
        return (Array(values[..<split]), Array(values[split...]))
    }
}

/// What the pipeline needs of the four networks, so the loop around them is tested on recorded tensors and run on the graphs.
protocol ObjectClearNetworks: Sendable {
    /// The object, `1 x 3 x 224 x 224` in [-1, 1], to its fused row, `2048` values.
    func encodeObject(_ object: [Float]) async throws -> [Float]
    /// The picture, `1 x 3 x H x W`, to its moments, `1 x 8 x h x w`.
    func encodePicture(_ picture: [Float], width: Int, height: Int) async throws -> [Float]
    /// One UNet call: the noise, `1 x 4 x h x w`, and the reduced attention, `1 x 1 x h/2 x w/2`.
    func unet(sample: [Float], timestep: Float, states: [Float], pooled: [Float], timeIDs: [Float], width: Int, height: Int)
        async throws -> (noise: [Float], attention: [Float])
    /// The latents, `1 x 4 x h x w`, to the picture, `1 x 3 x H x W`.
    func decode(_ latents: [Float], width: Int, height: Int) async throws -> [Float]
}

/// The four graphs in Core AI, loaded from a checked folder, with one working size at a time for the three that take it.
///
/// A loaded graph keeps on the GPU what it compiled for each size it has seen. H1 found the UNet's fourth size fail with the GPU
/// out of memory, and every call after it, with no error but outputs of zeros; dropping the model and loading it again for a new
/// size works. So a new size drops and reloads the sized graphs, and every output is checked: a value that is not a number, or a
/// noise or picture of zeros, is a failed call with its reason, never a picture.
actor ObjectClearRuntime: ObjectClearNetworks {
    /// One options value, so Core AI keeps one compiled copy of each graph (as `MaskModels.specializationOptions`).
    static let options = SpecializationOptions.default

    let folder: ObjectClearFolder
    private var functions: [ObjectClearGraph: InferenceFunction] = [:]
    /// The size the sized graphs have been called at since they were loaded, width then height.
    private(set) var size: (width: Int, height: Int)?
    /// Seconds each load and call took, the last of each, for the log and the measurements.
    private(set) var timings: [String: Double] = [:]

    init(folder: ObjectClearFolder) {
        self.folder = folder
    }

    var loaded: Set<ObjectClearGraph> { Set(functions.keys) }

    /// Loads `graphs` not yet loaded, from Core AI's compiled copy where there is one.
    func load(_ graphs: [ObjectClearGraph] = ObjectClearGraph.allCases) async throws {
        for graph in graphs where functions[graph] == nil {
            let started = ContinuousClock.now
            let model: AIModel
            do {
                model = try await AIModel(contentsOf: folder.url(of: graph), options: Self.options)
            } catch {
                throw ObjectClearError.unavailable("\(graph.fileName) did not load: \(error.localizedDescription)")
            }
            guard let function = try model.loadFunction(named: "main") else {
                throw ObjectClearError.unavailable("\(graph.fileName) has no function main; its functions are \(model.functionNames)")
            }
            let names = function.descriptor.inputNames, outputs = function.descriptor.outputNames
            guard Set(names) == Set(graph.inputNames), Set(outputs) == Set(graph.outputNames) else {
                throw ObjectClearError.unavailable("\(graph.fileName) takes \(names) and gives \(outputs), not \(graph.inputNames) and \(graph.outputNames)")
            }
            functions[graph] = function
            timings["load \(graph.rawValue)"] = (ContinuousClock.now - started).seconds
        }
    }

    func unload(_ graphs: [ObjectClearGraph] = ObjectClearGraph.allCases) {
        for graph in graphs { functions[graph] = nil }
        if graphs.contains(where: \.isSized) { size = nil }
    }

    /// Whether the sized graphs have been called at this size since they were loaded: if not, their next call compiles for it.
    func isWarm(width: Int, height: Int) -> Bool {
        size.map { $0.width == width && $0.height == height } ?? false
    }

    /// Readies the sized graphs for a size: dropped and loaded again when they have been called at another, so a loaded graph
    /// never holds two sizes. Returns whether they were dropped.
    @discardableResult func use(width: Int, height: Int) async throws -> Bool {
        if let size, size.width == width && size.height == height { return false }
        let dropped = size != nil
        if dropped {
            let sized = ObjectClearGraph.allCases.filter(\.isSized)
            unload(sized)
            try await load(sized)
        }
        size = (width, height)
        return dropped
    }

    /// Compiles the sized graphs for a size by calling each once on zeros: the first call with a size is what compiles it
    /// (Core AI has no call that compiles for a shape ahead).
    func warm(width: Int, height: Int) async throws {
        try await use(width: width, height: height)
        let h = height / ObjectClear.latentScale, w = width / ObjectClear.latentScale
        let started = ContinuousClock.now
        _ = try await call(.unet, [
            ("sample", [Float](repeating: 0, count: 9 * h * w), [1, 9, h, w]), ("timestep", [501], [1]),
            ("states", [Float](repeating: 0, count: ObjectClear.tokens * ObjectClear.stateWidth), [1, ObjectClear.tokens, ObjectClear.stateWidth]),
            ("pooled", [Float](repeating: 0, count: ObjectClear.pooledWidth), [1, ObjectClear.pooledWidth]),
            ("time_ids", [Float(height), Float(width), 0, 0, Float(height), Float(width)], [1, 6]),
        ], checked: false)
        _ = try await call(.vaeEncoder, [("picture", [Float](repeating: 0, count: 3 * width * height), [1, 3, height, width])], checked: false)
        _ = try await call(.vaeDecoder, [("latents", [Float](repeating: 0, count: 4 * h * w), [1, 4, h, w])], checked: false)
        timings["warm"] = (ContinuousClock.now - started).seconds
    }

    // MARK: The networks

    func encodeObject(_ object: [Float]) async throws -> [Float] {
        let side = ObjectClear.objectSide
        return try await call(.objectEncoder, [("object", object, [1, 3, side, side])])["fused"]!
    }

    func encodePicture(_ picture: [Float], width: Int, height: Int) async throws -> [Float] {
        try await use(width: width, height: height)
        return try await call(.vaeEncoder, [("picture", picture, [1, 3, height, width])])["moments"]!
    }

    func unet(sample: [Float], timestep: Float, states: [Float], pooled: [Float], timeIDs: [Float], width: Int, height: Int)
        async throws -> (noise: [Float], attention: [Float]) {
        try await use(width: width, height: height)
        let h = height / ObjectClear.latentScale, w = width / ObjectClear.latentScale
        let out = try await call(.unet, [
            ("sample", sample, [1, 9, h, w]), ("timestep", [timestep], [1]),
            ("states", states, [1, ObjectClear.tokens, ObjectClear.stateWidth]), ("pooled", pooled, [1, ObjectClear.pooledWidth]),
            ("time_ids", timeIDs, [1, 6]),
        ])
        return (out["noise"]!, out["attention"]!)
    }

    func decode(_ latents: [Float], width: Int, height: Int) async throws -> [Float] {
        try await use(width: width, height: height)
        let h = height / ObjectClear.latentScale, w = width / ObjectClear.latentScale
        return try await call(.vaeDecoder, [("latents", latents, [1, 4, h, w])])["picture"]!
    }

    // MARK: Calls

    /// One call of `graph`, its outputs as floats in their names' order. `checked` refuses an output that is not a number, and a
    /// noise or a picture that is all zeros: H1's out-of-memory GPU answered that way, with nothing thrown.
    func call(_ graph: ObjectClearGraph, _ inputs: [(name: String, values: [Float], shape: [Int])], checked: Bool = true)
        async throws -> [String: [Float]] {
        guard let function = functions[graph] else { throw ObjectClearError.failed("\(graph.rawValue) is not loaded") }
        var arrays: [String: NDArray] = [:]
        for input in inputs {
            guard input.values.count == input.shape.reduce(1, *) else {
                throw ObjectClearError.failed("\(graph.rawValue)'s \(input.name) has \(input.values.count) values, not \(input.shape)")
            }
            arrays[input.name] = NDArray(scalars: input.values, shape: input.shape)
        }
        let started = ContinuousClock.now
        var outputs: InferenceFunction.Outputs
        do {
            outputs = try await function.run(inputs: arrays)
        } catch {
            throw ObjectClearError.failed("\(graph.rawValue) failed: \(error.localizedDescription)")
        }
        var result: [String: [Float]] = [:]
        for name in graph.outputNames {
            guard let array = outputs.remove(name)?.ndArray else { throw ObjectClearError.failed("\(graph.rawValue) gave no \(name)") }
            let values = try Self.floats(array)
            if checked {
                guard values.allSatisfy(\.isFinite) else { throw ObjectClearError.failed("\(graph.rawValue)'s \(name) is not a number") }
                if name == "noise" || name == "picture", !values.contains(where: { $0 != 0 }) {
                    throw ObjectClearError.failed("\(graph.rawValue)'s \(name) came back all zeros: the call failed, likely the GPU out of memory")
                }
            }
            result[name] = values
        }
        timings["call \(graph.rawValue)"] = (ContinuousClock.now - started).seconds
        return result
    }

    /// An output as floats, row-major; honours strides, because Core AI may pad rows.
    static func floats(_ array: NDArray) throws -> [Float] {
        guard array.scalarType == .float32 else { throw ObjectClearError.failed("an output is \(array.scalarType), not 32-bit floats") }
        let total = array.shape.reduce(1, *)
        var result = [Float](repeating: 0, count: total)
        array.view(as: Float.self).withUnsafePointer { pointer, shape, strides in
            var contiguous = true, expected = 1
            for d in (0..<shape.count).reversed() {
                if shape[d] != 1 && strides[d] != expected { contiguous = false }
                expected *= shape[d]
            }
            if contiguous {
                result.withUnsafeMutableBufferPointer { out in
                    _ = memcpy(out.baseAddress!, pointer, total * MemoryLayout<Float>.size)
                }
                return
            }
            var index = [Int](repeating: 0, count: shape.count)
            for i in 0..<total {
                var offset = 0
                for d in 0..<shape.count { offset += index[d] * strides[d] }
                result[i] = pointer[offset]
                var d = shape.count - 1
                while d >= 0 {
                    index[d] += 1
                    if index[d] < shape[d] { break }
                    index[d] = 0
                    d -= 1
                }
            }
        }
        return result
    }

    /// The canary of `graph`: the SHA-256 of its float32 outputs on `canaryInputs`, in output order, as Python hashes them.
    func canary(_ graph: ObjectClearGraph) async throws -> String {
        try await load([graph])
        if graph.isSized { try await use(width: 768, height: 512) }
        let outputs = try await call(graph, graph.canaryInputs, checked: false)
        var hash = SHA256()
        for name in graph.outputNames { outputs[name]!.withUnsafeBytes { hash.update(bufferPointer: $0) } }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
