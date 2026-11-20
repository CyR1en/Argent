import ArgentCore
import CoreAI
import Foundation

/// The bundled model: ObjectClear's four graphs from a checked folder, all four resident while loaded, one working size at a time.
///
/// **The one-time preparation.** Core AI compiles each graph for this Mac at its first load and keeps the compiled copy in its
/// cache: `Library/Caches/coreai-cache/<macOS build>/<process>/<main.mlirb's SHA-256>/` of the process's home, which for the
/// sandboxed helper is the app's container. About 5.6 GB for the four, made again after each macOS update and for each new
/// conversion, and never purged by Core AI itself. As "Preparing masks" does (`MaskModels.prepare`), the ledger beside the folder
/// served keeps each graph's file hash, macOS build, options and the copy's bookmark; a copy an earlier file or build left is
/// deleted by its bookmark before the new one is made, by this process, whose cache it is.
final class ObjectClearModel: RemovalModel, @unchecked Sendable {
    static let engineID = "objectclear-coreai"

    let engine = ObjectClearModel.engineID
    let weights = ObjectClearFolder.weightsSHA256
    let folder: ObjectClearFolder
    let runtime: ObjectClearRuntime
    let ledgerFile: URL
    private let lock = NSLock()
    private var text: (states: [Float], pooled: [Float])?

    init(directory: URL, ledgerFile: URL) {
        folder = ObjectClearFolder(directory: directory)
        runtime = ObjectClearRuntime(folder: folder)
        self.ledgerFile = ledgerFile
    }

    // MARK: The ledger

    struct Ledger: Codable {
        struct Entry: Codable, Equatable {
            var fileSHA256: String
            var osBuild: String
            var options: String
            var bookmark: Data
            var prepared: Date
        }
        var graphs: [String: Entry] = [:]
    }

    static let optionsName = "default"

    func readLedger() -> Ledger {
        (try? Data(contentsOf: ledgerFile)).flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) } ?? Ledger()
    }

    private func writeLedger(_ ledger: Ledger) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try RemoveServer.place(try encoder.encode(ledger), at: ledgerFile)
    }

    /// A file read; nothing is loaded. A folder that fails its check needs nothing: the load says why.
    func needsPreparation() -> Bool {
        guard let hashes = try? folder.check() else { return false }
        let ledger = readLedger(), build = MaskModels.osBuild
        return ObjectClearGraph.allCases.contains { graph in
            guard let entry = ledger.graphs[graph.rawValue] else { return true }
            return entry.fileSHA256 != hashes[graph] || entry.osBuild != build || entry.options != Self.optionsName
        }
    }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        let hashes = try folder.check(), build = MaskModels.osBuild
        let total = ObjectClearGraph.allCases.reduce(0) { $0 + $1.preparationWeight }
        var done = 0.0, ledger = readLedger()
        // The small graphs first: the fraction moves at once, and the UNet's long compile is the last.
        for graph in ObjectClearGraph.allCases.sorted(by: { $0.preparationWeight < $1.preparationWeight }) {
            progress(done / total)
            if let old = ledger.graphs[graph.rawValue], old.fileSHA256 != hashes[graph] || old.osBuild != build || old.options != Self.optionsName {
                // Already gone (purged, or the container reset) is nothing to free.
                try? AIModelCache.deleteEntry(referencedBy: old.bookmark)
            }
            let specialised: AIModel
            do {
                specialised = try await AIModel.specialize(contentsOf: folder.url(of: graph), options: ObjectClearRuntime.options)
            } catch {
                throw ObjectClearError.unavailable("\(graph.fileName) could not be compiled for this Mac: \(error.localizedDescription)")
            }
            ledger.graphs[graph.rawValue] = Ledger.Entry(fileSHA256: hashes[graph]!, osBuild: build, options: Self.optionsName,
                                                         bookmark: specialised.bookmarkData, prepared: Date())
            // Stored at once, so a copy made and then interrupted is still found next time.
            try writeLedger(ledger)
            done += graph.preparationWeight
        }
        progress(1)
    }

    /// Deletes the compiled copies the ledger names and forgets them, so the next load prepares again: for the measurements, and
    /// for a user who wants the disk back.
    func deleteCompiledCopies() throws {
        var ledger = readLedger()
        for (name, entry) in ledger.graphs {
            try? AIModelCache.deleteEntry(referencedBy: entry.bookmark)
            ledger.graphs[name] = nil
        }
        for graph in ObjectClearGraph.allCases { try? AIModelCache.default.deleteEntries(for: folder.url(of: graph)) }
        try writeLedger(ledger)
    }

    // MARK: Running

    func load() async throws {
        _ = try folder.check()
        let states = try folder.textStates()
        lock.withLock { text = states }
        try await runtime.load()
    }

    func isWarm(width: Int, height: Int) async -> Bool {
        await runtime.isWarm(width: width, height: height)
    }

    func warm(width: Int, height: Int, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard ObjectClear.sides.contains(width), ObjectClear.sides.contains(height) else { return }
        progress(0)
        try await runtime.warm(width: width, height: height)
        progress(1)
    }

    func run(_ job: RemovalFolder.Job, image: [UInt8], mask: [UInt8], step: @escaping (Int) async throws -> Void) async throws
        -> (picture: [UInt8], attention: [UInt8]) {
        guard ObjectClear.sides.contains(job.width), ObjectClear.sides.contains(job.height) else {
            throw RefusedJob(why: "the model takes sides of \(ObjectClear.sides.lowerBound) to \(ObjectClear.sides.upperBound) pixels, not \(job.width) x \(job.height)")
        }
        guard let text = lock.withLock({ text }) else { throw ObjectClearError.failed("the model is not loaded") }
        let noises = ObjectClearRun.draws(seed: job.seed, width: job.width, height: job.height)
        let result = try await ObjectClearRun.run(image: image, mask: mask, width: job.width, height: job.height, steps: job.steps,
                                                  guidance: job.guidance, noises: noises, states: text.states, pooled: text.pooled,
                                                  networks: runtime, step: step)
        return (result.fused, result.attention)
    }
}

/// No model: `FakeRemovalEngine`'s drawing, to the byte, with the waits it is told to have, so the folder's rules are proven
/// through the app's client without 6 GB. It compiles for a size as the real one does, by waiting.
final class FakeModel: RemovalModel, @unchecked Sendable {
    struct Delays {
        var prepare: TimeInterval = 0
        var load: TimeInterval = 0
        var step: TimeInterval = 0
        /// The first job at a size, or a `prepare.json`, waits this long.
        var compile: TimeInterval = 0
        /// Whether the first load prepares, as after an install.
        var prepares = false
    }

    let engine = FakeRemovalEngine.engineID
    let weights = FakeRemovalEngine.weightsID
    private let delays: Delays
    private let lock = NSLock()
    private var size: (width: Int, height: Int)?
    private var prepared = false

    init(_ delays: Delays) {
        self.delays = delays
    }

    func needsPreparation() -> Bool { delays.prepares && !lock.withLock { prepared } }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        for tenth in 0..<10 {
            progress(Double(tenth) / 10)
            try await Task.sleep(for: .seconds(delays.prepare / 10))
        }
        lock.withLock { prepared = true }
    }

    func load() async throws {
        try await Task.sleep(for: .seconds(delays.load))
    }

    func isWarm(width: Int, height: Int) async -> Bool {
        lock.withLock { size.map { $0.width == width && $0.height == height } ?? false }
    }

    func warm(width: Int, height: Int, progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0)
        try await Task.sleep(for: .seconds(delays.compile))
        lock.withLock { size = (width, height) }
        progress(1)
    }

    func run(_ job: RemovalFolder.Job, image: [UInt8], mask: [UInt8], step: @escaping (Int) async throws -> Void) async throws
        -> (picture: [UInt8], attention: [UInt8]) {
        if await !isWarm(width: job.width, height: job.height) { try await warm(width: job.width, height: job.height) { _ in } }
        for done in 1...job.steps {
            try await Task.sleep(for: .seconds(delays.step))
            try await step(done)
        }
        let removal = try RemovalJob(width: job.width, height: job.height, image: image, mask: mask, steps: 1, guidance: 1, seed: job.seed)
        let drawn = try await FakeRemovalEngine().run(removal) { _, _ in }
        return (drawn.image, drawn.attention)
    }
}
