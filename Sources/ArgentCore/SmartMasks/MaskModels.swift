import CoreAI
import CryptoKit
import Darwin
import Foundation

/// The two models the app bundles for smart masks (docs/masking-plan.md sections 3 and 7), each built once by a pinned recipe in
/// `scripts/` into `build/models/` and cloned into `Contents/Resources/Models/` by `scripts/build-app.sh`. A conversion is not
/// byte-deterministic, so a model is named by its recipe id, its weights' SHA-256 and its outputs' hash on the canary picture
/// (`scripts/models/canary-DSC06673.png`); these are pinned here and in the scripts, and `MaskModels` refuses a file whose manifest
/// says otherwise. The file's own SHA-256 (`main.hash`) names one conversion, and the compiled copy Core AI keys by it.
public enum BundledMaskModel: String, CaseIterable, Sendable, Codable {
    /// Depth Anything 3 Mono-Large, sky and depth heads, one padded 756 square (S1b): the Sky seed.
    case sky = "da3-sky-sq756-f16"
    /// EoMT-DINOv3-L, ADE20K-150, water, sky and class maps of one padded 768 square (S5): the Sky seed's reflection veto, and Subject's "no subject" gate.
    case water = "eomt-sq768-f16"
    /// S3OD-sod, three masks and their predicted IoUs of one black-padded 1024 square (V4): Subject's region.
    case subject = "s3od-sod-sq1024-f16"
    /// ViTMatte-S, Composition-1k, the alpha of one 1024 tile (Y2): Subject's edge in the low-light rule.
    case matte = "vitmatte-s-c1k-sq1024-f16"

    public var fileName: String { rawValue + ".aimodel" }
    public var manifestName: String { rawValue + ".manifest.json" }

    /// The recipe that made it; a change of meaning is a new id (`scripts/convert-*.zsh`).
    public var recipeID: String {
        switch self {
        case .sky: return "da3-mono-large-sq756-f16-sky-depth-1"
        case .water: return "eomt-dinov3-l-ade150-sq768-f16-maps3-1"
        case .subject: return "s3od-sod-dinov3b-sq1024-f16-masks3-iou-1"
        case .matte: return "vitmatte-s-c1k-sq1024-f16-alpha-1"
        }
    }

    /// The recipe script that builds it, for the row that says how to.
    public var script: String {
        switch self {
        case .sky: return "scripts/convert-da3-sky.zsh"
        case .water: return "scripts/convert-eomt.zsh"
        case .subject: return "scripts/convert-s3od.zsh"
        case .matte: return "scripts/convert-vitmatte.zsh"
        }
    }

    /// The weights' SHA-256: `depth-anything/DA3MONO-LARGE` at `f465978e`, `tue-mps/eomt-dinov3-ade-semantic-large-512` at `1d1f1727`, `okupyn/s3od-sod` at `3752fc7f`
    /// (`s3od.pt`), `hustvl/vitmatte-small-composition-1k` at `6a58ad76` (`model.safetensors`).
    public var weightsSHA256: String {
        switch self {
        case .sky: return "7a799a7f95eb8d4c404c2ca8be3dc3276b350a417ddc4420db72ba850cc0e960"
        case .water: return "319c72ee001fad0f81876fab96ae7148d13c259cd433a7326746e85e6b89d482"
        case .subject: return "28eed1614e4831ac1fda96e2b97ce79c321b8f97ca6db42c0dcc3b3d617df434"
        case .matte: return "bda9289db1bb6762d978b42d1c62ae3f34daf7497171a347a1d09657efd788cb"
        }
    }

    /// The SHA-256 of its outputs on the canary square (`canaryInputSHA256`): sky then depth, the three maps, S3OD's masks in half floats then IoUs in 32-bit floats, or
    /// ViTMatte's alpha. The same across conversions, Python and Swift (measured 2026-11-07, two DA3 conversions; S5's three EoMT conversions; V4's three S3OD conversions, 2026-11-08;
    /// Y2's file for ViTMatte, 2026-11-09).
    public var canarySHA256: String {
        switch self {
        case .sky: return "4873a5f8b6c37fce6806ae33f77ef1ba067503011fe63d590ab5b394a597be26"
        case .water: return "63bdb66c474ed611e32d5ddcc274da3acae07a00b6270fbbcb136dcfd77e7a46"
        case .subject: return "03338301a77595a7cc5a5e7f4bd4ed230d9c958432adfb0da696c1a4cc59614a"
        case .matte: return "a5d9b7870abc021a26617e03470e158956030a1473072a43632d7ac59564e23e"
        }
    }

    /// The SHA-256 of the half-float canary square itself (`scripts/models/canary_check.py`, `canary_s3od.py`, `canary_vitmatte.py`).
    public var canaryInputSHA256: String {
        switch self {
        case .sky: return "746a0694c301cc1355533f06a83c29b4e0430b4b5d6bb992d73ce35c77c2e21b"
        case .water: return "3af48f152d7e420b07d568b36cc18d4f6e20639ac664521011d843f7ea59f032"
        case .subject: return "90987b7fd86b98640b4ee05149ee70fb04a519f341fb925a499aa1173a7535b6"
        case .matte: return "514b0cd2cf0f4458657f0f860647a3a6ba9dffe229af1895c3087e1d3926dd5d"
        }
    }

    /// The side of its square.
    public var side: Int {
        switch self {
        case .sky: return SkyModelRunner.side
        case .water: return EomtModelRunner.side
        case .subject: return S3odModelRunner.side
        case .matte: return MatteRunner.side
        }
    }

    /// How long its first inference takes after an OS update, mostly Metal compiling its shaders, and its specialisation: S5's cold matrix, sandboxed (DA3 5.0 s and 0.63 s,
    /// EoMT 1.8 s and 0.68 s), V4's for S3OD (3.4 s and 0.27 s), Y2's for ViTMatte (2.2 s; its specialisation not timed, about S3OD's). Weights for "Preparing masks"' progress only.
    var preparationSeconds: (specialise: Double, warm: Double) {
        switch self {
        case .sky: return (0.63, 5.0)
        case .water: return (0.68, 1.8)
        case .subject: return (0.27, 3.4)
        case .matte: return (0.27, 2.2)
        }
    }
}

/// Which conversion of a bundled model made a seed: what its provenance records (P0-S5 section 4) and what "Preparing masks"
/// remembers.
public struct MaskModelIdentity: Sendable, Equatable, Codable {
    public var recipeID: String
    public var weightsSHA256: String
    public var canarySHA256: String
    /// `main.mlirb`'s SHA-256 (the file's `main.hash`): this conversion, and Core AI's key for its compiled copy.
    public var fileSHA256: String
    /// The specialisation options, by name: always `MaskModels.optionsName`.
    public var options: String
}

public enum MaskModelError: Error, CustomStringConvertible, Equatable {
    /// Not in the app, or not the model the pins name; the reason says which and how to build it.
    case unavailable(BundledMaskModel, String)
    case notLoaded(String)
    case noFunction(String)
    case badInput(String)
    case missingOutput(String)
    case unsupportedScalarType(String)
    /// A model returned a value that is not a number: a failed click, never a broken mask (research task V4, section 8).
    case nonFinite(String)

    public var description: String {
        switch self {
        case .unavailable(let model, let why): return "\(model.rawValue) is unavailable: \(why)"
        case .notLoaded(let what): return "\(what) is not loaded"
        case .noFunction(let what): return "the model has no usable function: \(what)"
        case .badInput(let what): return "bad input: \(what)"
        case .missingOutput(let what): return "missing output: \(what)"
        case .unsupportedScalarType(let what): return "unsupported output type: \(what)"
        case .nonFinite(let what): return "not a number: \(what)"
        }
    }

    /// The model's `main` function and its `image` input, checked against the shape the runner expects.
    static func mainFunction(of model: AIModel, expecting shape: [Int]) throws -> (InferenceFunction, NDArrayDescriptor) {
        guard let descriptor = model.functionDescriptor(for: "main") else { throw noFunction("main; functions are \(model.functionNames)") }
        guard case .ndArray(let image) = descriptor.inputDescriptor(of: "image") else { throw noFunction("main has no array input named image") }
        let found = Array(NDArray(descriptor: image).shape)
        guard found == shape else { throw badInput("the model takes \(found), not \(shape)") }
        guard let function = try model.loadFunction(named: "main") else { throw noFunction("main could not be loaded") }
        return (function, image)
    }

    /// `values` as the model's input array.
    static func array(_ values: [Float16], descriptor: NDArrayDescriptor) throws -> NDArray {
        var array = NDArray(descriptor: descriptor)
        guard array.scalarType == .float16 else { throw badInput("the model wants \(array.scalarType), not half floats") }
        var view = array.mutableView(as: Float16.self)
        view.copyElements(fromContentsOf: values)
        return array
    }

    /// An output array as floats, row-major; honours strides, because Core AI may pad rows.
    static func flatten(_ array: NDArray) throws -> [Float] {
        switch array.scalarType {
        case .float16: return flat(array, as: Float16.self)
        case .float32: return flat(array, as: Float.self)
        default: throw unsupportedScalarType("\(array.scalarType)")
        }
    }

    private static func flat<T: BinaryFloatingPoint & BitwiseCopyable>(_ array: NDArray, as type: T.Type) -> [Float] {
        let total = array.shape.reduce(1, *)
        var result = [Float](repeating: 0, count: total)
        array.view(as: type).withUnsafePointer { pointer, shape, strides in
            var contiguous = true, expected = 1
            for d in (0..<shape.count).reversed() {
                if strides[d] != expected { contiguous = false }
                expected *= shape[d]
            }
            if contiguous {
                for i in 0..<total { result[i] = Float(pointer[i]) }
                return
            }
            var index = [Int](repeating: 0, count: shape.count)
            for i in 0..<total {
                var offset = 0
                for d in 0..<shape.count { offset += index[d] * strides[d] }
                result[i] = Float(pointer[offset])
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

    /// The SHA-256 of `planes` as half floats, one after the other: the models' outputs are half floats, so this hashes what
    /// they returned (`canary_check.py` hashes the same bytes).
    static func digest(of planes: [[Float]]) -> String {
        var hash = SHA256()
        for plane in planes { plane.map { Float16($0) }.withUnsafeBytes { hash.update(bufferPointer: $0) } }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The SHA-256 of `halves` as half floats, then `floats` as 32-bit floats: S3OD's masks then IoUs (`canary_s3od.py`).
    static func digest(ofHalves halves: [[Float]], thenFloats floats: [[Float]]) -> String {
        var hash = SHA256()
        for plane in halves { plane.map { Float16($0) }.withUnsafeBytes { hash.update(bufferPointer: $0) } }
        for plane in floats { plane.withUnsafeBytes { hash.update(bufferPointer: $0) } }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// "Preparing masks": where it is, for the UI.
public struct MaskPreparationProgress: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// A compiled copy left by an earlier model file or macOS being deleted by its bookmark.
        case removingStale(BundledMaskModel)
        /// `AIModel.specialize`: Core AI compiling the model for this Mac (about 0.65 s each).
        case compiling(BundledMaskModel)
        /// One inference on a blank square, which compiles Metal's shaders (DA3 5.0 s, EoMT 1.8 s, S3OD 3.4 s, ViTMatte 2.2 s).
        case warming(BundledMaskModel)
        case done
    }
    public var step: Step
    /// 0...1, weighted by S5's measured times.
    public var fraction: Double
}

/// The bundled mask models in one place: where they are, whether they are the ones the pins name, "Preparing masks", and running
/// them on a frame's `MaskInputPicture` under the plan's load and unload rules (section 4, rule 5):
///
/// - `sky(for:)` loads DA3 if it is not loaded and leaves it loaded: it stays resident while the Masks tab is open, and the caller
///   unloads it with `unloadSky()` when the tab closes and before a develop admits a frame.
/// - `water(for:)` loads EoMT, runs it and unloads it in the same call, for the 12 % of Sky clicks Vision's gate passes (+0.09 s), and Subject's gate.
/// - `subject(for:)` loads S3OD, runs it and unloads it in the same call, and `matte(seed:on:)` does the same for ViTMatte, inside the low-light rule: neither stays loaded past a click.
/// - Never during a develop: the caller's queue waits for a develop's frames, as `DecodeTurns` makes previews wait.
///
/// Footprint two seconds after unloading: 81 MB DA3 alone, 91 MB EoMT after it, 107 MB if both were resident (S5), 49 MB S3OD (V4); the develop's
/// gate waits for it. Methods may be called from any thread; the runners are actors.
public final class MaskModels: @unchecked Sendable {
    /// One options value for both models, so Core AI keeps one compiled copy of each: every other value, like every other bundle id
    /// or model file, adds another (638 and 602 MiB) and the old one is never purged (S1b, S5).
    public static let specializationOptions = SpecializationOptions.default
    public static let optionsName = "default"
    /// What Subject needs: S3OD for its region, EoMT for its gate, ViTMatte for its edge in the low-light rule.
    public static let subjectModels: [BundledMaskModel] = [.subject, .water, .matte]
    /// The app's own models.
    public static var bundledDirectory: URL? { Bundle.main.resourceURL?.appendingPathComponent("Models", isDirectory: true) }

    /// Where the models are looked for, in order: the app's own folder, then the downloaded models' (`SubjectModelPack`). A model is taken from
    /// the first folder that holds its file.
    public let directories: [URL]
    /// The ledger of compiled copies: for each model, the file, macOS build and options it was last prepared for, and the bookmark
    /// that names that compiled copy (`AIModel.bookmarkData`, about 181 bytes).
    public let ledgerFile: URL
    public let skyRunner = SkyModelRunner()
    public let waterRunner = EomtModelRunner()
    public let subjectRunner = S3odModelRunner()
    public let matteRunner = MatteRunner()
    private let lock = NSLock()
    private var preparing: Task<MaskPreparationReport, any Error>?

    /// `directories` hold `<model>.aimodel` and `<model>.manifest.json` for each model; `ledgerFile` lives in the app's Application
    /// Support (a test's in a temporary folder of its own).
    public init(directories: [URL], ledgerFile: URL) {
        self.directories = directories
        self.ledgerFile = ledgerFile
    }

    /// One folder, the app's own by default.
    public convenience init(directory: URL? = MaskModels.bundledDirectory, ledgerFile: URL) {
        self.init(directories: directory.map { [$0] } ?? [], ledgerFile: ledgerFile)
    }

    /// The first folder that holds `model`'s file, `nil` when none does.
    public func folder(of model: BundledMaskModel) -> URL? {
        directories.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(model.fileName, isDirectory: true).appendingPathComponent("main.hash").path) }
    }

    // MARK: Which models

    /// The model's file, or why it cannot be used: absent, or built by another recipe than the pins name.
    public func url(of model: BundledMaskModel) throws -> URL {
        try locate(model).directory.appendingPathComponent(model.fileName, isDirectory: true)
    }

    /// Which conversion of `model` is here, after checking its manifest against the pins.
    public func identity(of model: BundledMaskModel) throws -> MaskModelIdentity {
        try locate(model).identity
    }

    /// The first folder that holds `model` and the verified identity found there.
    private func locate(_ model: BundledMaskModel) throws -> (directory: URL, identity: MaskModelIdentity) {
        let script = model.script
        guard !directories.isEmpty else { throw MaskModelError.unavailable(model, "the app has no Models folder; build the models with \(script), then the app") }
        guard let directory = folder(of: model),
              let hash = try? Data(contentsOf: directory.appendingPathComponent(model.fileName, isDirectory: true).appendingPathComponent("main.hash")), hash.count == 32 else {
            throw MaskModelError.unavailable(model, "\(model.fileName) is neither in the app nor downloaded; build it with \(script), then the app")
        }
        struct Manifest: Decodable {
            var recipeID: String, weights: String, canary: String
            enum CodingKeys: String, CodingKey { case recipeID = "recipe id", weights = "weights sha256", canary = "canary output sha256" }
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(model.manifestName)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            throw MaskModelError.unavailable(model, "\(model.manifestName) is missing or unreadable; build the model again with \(script)")
        }
        guard manifest.recipeID == model.recipeID, manifest.weights == model.weightsSHA256, manifest.canary == model.canarySHA256 else {
            throw MaskModelError.unavailable(model, "it was built by recipe \(manifest.recipeID) with canary \(manifest.canary.prefix(8)), not \(model.recipeID) "
                                             + "with \(model.canarySHA256.prefix(8)); build it again with \(script)")
        }
        let identity = MaskModelIdentity(recipeID: model.recipeID, weightsSHA256: model.weightsSHA256, canarySHA256: model.canarySHA256,
                                         fileSHA256: hash.map { String(format: "%02x", $0) }.joined(), options: Self.optionsName)
        return (directory, identity)
    }

    /// Why each model is unavailable, empty when all are here.
    public var unavailable: [MaskModelError] {
        BundledMaskModel.allCases.compactMap { model in
            do { _ = try identity(of: model); return nil } catch let error as MaskModelError { return error } catch { return nil }
        }
    }

    /// Why a model of `models` is not here, the first.
    private func missing(_ models: [BundledMaskModel]) -> MaskModelError? {
        for model in models {
            do { _ = try identity(of: model) } catch let error as MaskModelError { return error } catch { return .unavailable(model, String(describing: error)) }
        }
        return nil
    }

    /// Sky needs DA3 and EoMT: the water veto is part of it (decision 4).
    public var isSkyAvailable: Bool { missing([.sky, .water]) == nil }

    /// Subject needs all three: S3OD, EoMT for its gate, and ViTMatte for its edge in the low-light rule.
    public var isSubjectAvailable: Bool { missing(Self.subjectModels) == nil }

    /// The first of Subject's models that is not here, `nil` when all are.
    public var subjectMissing: MaskModelError? { missing(Self.subjectModels) }

    // MARK: Preparing masks

    struct Ledger: Codable {
        struct Entry: Codable {
            var fileSHA256: String
            var osBuild: String
            var options: String
            var bookmark: Data
            var prepared: Date
        }
        var models: [String: Entry] = [:]
    }

    /// The macOS build, which keys Core AI's compiled copies (`26B123`).
    public static var osBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func readLedger() -> Ledger {
        (try? Data(contentsOf: ledgerFile)).flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) } ?? Ledger()
    }

    private func writeLedger(_ ledger: Ledger) throws {
        try FileManager.default.createDirectory(at: ledgerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ledger).write(to: ledgerFile, options: .atomic)
    }

    /// Whether "Preparing masks" has to run before the first Sky click: on first use, after each macOS update, and after a new model
    /// file, the models here were not prepared for this macOS build and options value. A file read; nothing is loaded.
    public var needsPreparation: Bool {
        let ledger = readLedger(), build = Self.osBuild
        return BundledMaskModel.allCases.contains { model in
            guard let identity = try? identity(of: model) else { return false }
            guard let entry = ledger.models[model.rawValue] else { return true }
            return entry.fileSHA256 != identity.fileSHA256 || entry.osBuild != build || entry.options != Self.optionsName
        }
    }

    /// "Preparing masks" (plan section 7): for each model here, the compiled copy an earlier file or macOS left is deleted by the
    /// bookmark stored when it was made (`deleteEntries(for:)` needs the old file, which an update has replaced, S5); then
    /// `AIModel.specialize` makes this one's and its bookmark is stored, and one inference on a blank square compiles Metal's
    /// shaders. About 17 s on first use and after a macOS update for the four models (measured in the sandboxed app, 2026-11-09). Called
    /// when `needsPreparation` is false it compiles nothing but still runs the blank inferences (0.9 to 1.5 s measured for two), so
    /// callers ask first. `progress` is told as each step starts, on no particular thread. A second call while one runs waits for
    /// it. DA3 is left loaded only if it was loaded.
    @discardableResult
    public func prepare(progress: @escaping @Sendable (MaskPreparationProgress) -> Void = { _ in }) async throws -> MaskPreparationReport {
        let task: Task<MaskPreparationReport, any Error> = lock.withLock {
            if let preparing { return preparing }
            let made = Task { try await self.runPreparation(progress: progress) }
            preparing = made
            return made
        }
        defer { lock.withLock { if preparing == task { preparing = nil } } }
        return try await task.value
    }

    private func runPreparation(progress: @escaping @Sendable (MaskPreparationProgress) -> Void) async throws -> MaskPreparationReport {
        let models = BundledMaskModel.allCases.filter { (try? identity(of: $0)) != nil }
        let total = models.reduce(0) { $0 + $1.preparationSeconds.specialise + $1.preparationSeconds.warm }
        var done = 0.0
        func tell(_ step: MaskPreparationProgress.Step) { progress(MaskPreparationProgress(step: step, fraction: total > 0 ? min(done / total, 1) : 1)) }
        var ledger = readLedger()
        var report = MaskPreparationReport(osBuild: Self.osBuild)
        for model in models {
            let identity = try identity(of: model), url = try url(of: model)
            if let old = ledger.models[model.rawValue],
               old.fileSHA256 != identity.fileSHA256 || old.osBuild != report.osBuild || old.options != Self.optionsName {
                tell(.removingStale(model))
                do {
                    try AIModelCache.deleteEntry(referencedBy: old.bookmark)
                    report.staleDeleted.append(model)
                } catch {
                    // Already gone (purged, or the container reset): nothing to free.
                    report.staleNotFound.append(model)
                }
            }
            tell(.compiling(model))
            let started = ContinuousClock.now
            let specialised = try await AIModel.specialize(contentsOf: url, options: Self.specializationOptions)
            report.specialiseSeconds[model] = (ContinuousClock.now - started).seconds
            ledger.models[model.rawValue] = Ledger.Entry(fileSHA256: identity.fileSHA256, osBuild: report.osBuild, options: Self.optionsName,
                                                         bookmark: specialised.bookmarkData, prepared: Date())
            // Stored at once, so a copy made and then interrupted is still found next time.
            try writeLedger(ledger)
            done += model.preparationSeconds.specialise
        }
        for model in models {
            tell(.warming(model))
            let started = ContinuousClock.now
            let url = try url(of: model)
            switch model {
            case .sky:
                let wasLoaded = await skyRunner.isLoaded
                if !wasLoaded { try await skyRunner.load(from: url) }
                _ = try await skyRunner.run(Self.blankSquare(side: model.side))
                if !wasLoaded { await skyRunner.unload() }
            case .water:
                let wasLoaded = await waterRunner.isLoaded
                if !wasLoaded { try await waterRunner.load(from: url) }
                _ = try await waterRunner.run(Self.blankSquare(side: model.side))
                if !wasLoaded { await waterRunner.unload() }
            case .subject:
                let wasLoaded = await subjectRunner.isLoaded
                if !wasLoaded { try await subjectRunner.load(from: url) }
                _ = try await subjectRunner.run(Self.blankSquare(side: model.side))
                if !wasLoaded { await subjectRunner.unload() }
            case .matte:
                let wasLoaded = await matteRunner.isLoaded
                if !wasLoaded { try await matteRunner.load(from: url) }
                _ = try await matteRunner.run(tile: [Float16](repeating: 0, count: 4 * model.side * model.side))
                if !wasLoaded { await matteRunner.unload() }
            }
            report.warmSeconds[model] = (ContinuousClock.now - started).seconds
            done += model.preparationSeconds.warm
        }
        tell(.done)
        return report
    }

    /// A square of zeros: the inputs' values do not matter to the shaders compiled.
    static func blankSquare(side: Int) -> ModelSquare {
        ModelSquare(layout: ModelSquareLayout(side: side, width: side, height: side), input: [Float16](repeating: 0, count: 3 * side * side))
    }

    /// Deletes the compiled copies the ledger names, and any of the files here, and forgets them, so the next use prepares again:
    /// for tests and measurements, and for a user who wants the disk back (2 × about 0.65 GB).
    public func deleteCompiledCopies() throws {
        var ledger = readLedger()
        for (name, entry) in ledger.models {
            try? AIModelCache.deleteEntry(referencedBy: entry.bookmark)
            ledger.models[name] = nil
        }
        for model in BundledMaskModel.allCases {
            if let url = try? url(of: model) { try? AIModelCache.default.deleteEntries(for: url) }
        }
        try writeLedger(ledger)
    }

    // MARK: Running

    /// Sky and depth for `picture`, DA3 loaded first if it is not (0.14 s): 0.225 s warm on an idle GPU plus about 20 ms to make the
    /// square on the CPU. DA3 stays loaded; `unloadSky()` lets it go.
    public func sky(for picture: MaskInputPicture) async throws -> SkyOutputs {
        if await !skyRunner.isLoaded { try await skyRunner.load(from: try url(of: .sky)) }
        return try await skyRunner.run(ModelSquare(picture, side: SkyModelRunner.side, padding: SkyModelRunner.padding))
    }

    /// Water, sky and class maps for `picture`: EoMT loaded (about 0.09 s), run (0.111 s warm) and, unless `keepLoaded`, unloaded
    /// before this returns, as the plan's rule 5 has it for a gated click.
    public func water(for picture: MaskInputPicture, keepLoaded: Bool = false) async throws -> EomtMaps {
        let wasLoaded = await waterRunner.isLoaded
        if !wasLoaded { try await waterRunner.load(from: try url(of: .water)) }
        do {
            let maps = try await waterRunner.run(ModelSquare(picture, side: EomtModelRunner.side, padding: EomtModelRunner.padding))
            if !keepLoaded { await waterRunner.unload() }
            return maps
        } catch {
            if !keepLoaded { await waterRunner.unload() }
            throw error
        }
    }

    /// S3OD's masks for `picture`: loaded (about 0.05 to 0.09 s from the compiled copy), run (0.155 s warm) and unloaded before this returns, even if it throws.
    public func subject(for picture: MaskInputPicture) async throws -> S3odOutputs {
        try await subjectRunner.load(from: try url(of: .subject))
        do {
            let outputs = try await subjectRunner.run(ModelSquare(picture, side: S3odModelRunner.side, padding: S3odModelRunner.padding))
            await subjectRunner.unload()
            return outputs
        } catch {
            await subjectRunner.unload()
            throw error
        }
    }

    /// ViTMatte's alpha for `seed` on `picture`, tile by tile (`SubjectMatte`): loaded, run (68 ms a tile warm) and unloaded before this returns, even if it throws.
    public func matte(seed: MaskRaster, on picture: MaskInputPicture) async throws -> SubjectMatte.Result {
        try await matteRunner.load(from: try url(of: .matte))
        do {
            let runner = matteRunner
            let result = try await picture.withPixelsAsync { bytes, rowBytes in
                try await SubjectMatte.alpha(seed: seed, picturePixels: bytes, width: picture.width, height: picture.height, rowBytes: rowBytes,
                                             bytesPerPixel: MaskInputPicture.bytesPerPixel, run: { try await runner.run(tile: $0) })
            }
            await matteRunner.unload()
            return result
        } catch {
            await matteRunner.unload()
            throw error
        }
    }

    /// Lets DA3 go: when the Masks tab closes, and before a develop admits a frame.
    public func unloadSky() async { await skyRunner.unload() }

    /// Lets every model go.
    public func unloadAll() async {
        await skyRunner.unload()
        await waterRunner.unload()
        await subjectRunner.unload()
        await matteRunner.unload()
    }
}

/// What "Preparing masks" did, for the log and the measurements.
public struct MaskPreparationReport: Sendable {
    public var osBuild: String
    public var staleDeleted: [BundledMaskModel] = []
    /// Stale entries whose compiled copy was already gone.
    public var staleNotFound: [BundledMaskModel] = []
    public var specialiseSeconds: [BundledMaskModel: Double] = [:]
    public var warmSeconds: [BundledMaskModel: Double] = [:]
}
