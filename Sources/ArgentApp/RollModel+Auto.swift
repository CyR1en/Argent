import ArgentCore
import ArgentRoll
import Foundation
import os

/// A frame whose measurement failed for good: the version of its raw that could not be decoded or
/// its header read, `nil` when the file was gone.
struct MeasurementFailure: Equatable {
    let source: SourceStamp?
}

/// The film inputs Auto reads for a roll, captured together before any wait.
struct AutoFilmSettings {
    let stock: Stock
    let stockDigest: String
    let controls: RollControls
    let overrides: [URL: FrameControls]
    let frameStocks: [URL: Stock]
    let frameStockDigests: [URL: String]

    func recordControls(for frames: [Frame]) -> AutoDecisions.Record.Controls? {
        let method = AutoDecisions.method
        guard AutoDecisions.readsStock(method) else { return nil }
        return AutoDecisions.Record.Controls(stockID: stock.id, stockDigest: stockDigest, roll: controls,
                                             frames: AutoDecisions.ownControls(frames, overrides),
                                             frameStockDigests: method == .detail
                                                ? AutoDecisions.names(frames, frameStockDigests) : nil)
    }
}

/// The roll's settled Auto decision (`AutoDecisions`; docs/research/auto/sequence-consistency.md,
/// "Stage 4 either way").
///
/// While the roll is measured each frame shows its own aim (`AutoDecisions.ownAim`), never roll
/// smoothing over a roll partly measured. Once every frame has a measurement or a failure and the
/// saved choices are restored, one fixed snapshot of the roll is resolved off the main actor and its
/// aims published at once, as a new revision, and kept (`AutoDecisionStore`). Opening the roll again
/// unchanged publishes the kept decision at once, without balancing; measuring a frame again leaves a
/// settled decision standing. A new revision comes only from a replaced raw, a frame the decision
/// printed at the fallback that measures now (on open, from its recipe or measured again), Roll >
/// Rebalance Roll, and a change of stock or controls for a method that reads them. While a changed
/// roll balances again, its other frames keep their settled aims, and the changed ones show their own.
extension RollModel {
    nonisolated private static let autoLog = Logger(subsystem: "camera.argent.Argent", category: "auto")

    /// Whether the frame has its measurement, or has failed to be measured for good: either way it
    /// takes its part in the roll's decision.
    func isMeasured(_ frame: Frame) -> Bool {
        analyses[frame.url] != nil || measurementFailures[frame.url] != nil
    }

    /// Whether the window says the roll is balancing: frames have been measured, and the roll has not
    /// settled on them yet.
    var isBalancing: Bool {
        roll != nil && currentStock != nil && !isBalanced && !(analyses.isEmpty && measurementFailures.isEmpty)
    }

    /// Roll > Rebalance Roll, once the roll has settled and while it is not developing.
    var canRebalance: Bool { roll != nil && films != nil && isBalanced && !isDeveloping && !isScanning && !isQuitting }

    /// Records that the frame's raw at `source` could not be decoded or its header read, if it is the
    /// frame's raw as it is now: the frame prints at the fallback aim and the roll can settle.
    func recordFailure(at source: SourceStamp?, for frame: Frame) {
        guard roll?.frames.contains(where: { $0.url == frame.url }) == true, SourceStamp.of(frame.url) == source,
              !isMeasured(frame) else { return }
        measurementFailures[frame.url] = MeasurementFailure(source: source)
        measurementArrived(for: frame.url)
    }

    /// A frame's measurement or failure has arrived. A frame the settled decision still covers, being
    /// measured again, leaves it standing, and so does one it printed at the fallback that fails
    /// again; any other is a new input, balanced with the rest once every frame has its part. A frame
    /// that failed and measures now shows its own aim meanwhile.
    func measurementArrived(for url: URL) {
        if analyses[url] != nil, autoDecision?.failed.contains(url) == true { decidedAims[url] = nil }
        if isBalanced, decidedAims[url] != nil { return }
        unsettle()
    }

    /// `url`'s raw is not the one the decision and the measurements were made of: they go, and the
    /// roll balances again once it is measured.
    func forgetDecision(for url: URL) {
        decidedAims[url] = nil
        if measurementFailures[url] != nil { measurementFailures[url] = nil }
        descriptors[url] = nil
    }

    /// The roll's decision no longer holds: a balance under way is for inputs that are not the roll's,
    /// and another starts once every frame has its part.
    func unsettle() {
        if isBalanced { isBalanced = false }
        balanceGeneration &+= 1
        balanceTask?.cancel()
        balanceTask = nil
        refreshAims()
        balanceIfReady()
    }

    /// Forgets the open roll's decision, for another roll.
    func resetAuto() {
        balanceGeneration &+= 1
        balanceTask?.cancel()
        balanceTask = nil
        autoDecision = nil
        decidedAims = [:]
        isBalanced = false
        isDevelopBalancing = false
        measurementFailures = [:]
        descriptors = [:]
    }

    /// Each frame's aim: the settled decision's, else its own once measured. Set only when it changes,
    /// so a frame measured again does not redraw every frame on screen.
    func refreshAims() {
        var aims: [URL: PrintAim] = [:]
        for frame in roll?.frames ?? [] {
            if let decided = decidedAims[frame.url] {
                aims[frame.url] = decided
            } else if let analysis = analyses[frame.url] {
                aims[frame.url] = AutoDecisions.ownAim(analysis)
            }
        }
        if aims != printAims { printAims = aims }
    }

    /// Publishes `record`, the decision the roll settled on before, if it holds for the roll as
    /// `identities` say its raws are now.
    func restoreDecision(_ record: AutoDecisions.Record, identities: [URL: AutoDecisions.Identity]) {
        guard let roll, let decision = AutoDecisions.restored(
            record, frames: roll.frames, identities: identities,
            stockDigest: stockDigests.indices.contains(stockIndex) ? stockDigests[stockIndex] : nil,
            controls: controls, frameControls: overrides, frameStockDigests: autoStockDigests(roll.frames)) else { return }
        // Save projected membership after a cull, while retaining the revision that made the aims.
        publish(decision, keeping: decision.record != record)
    }

    /// A settled roll lost files while open. Keep its surviving decisions and revision, and save
    /// the smaller membership so reopening it cannot rebalance the survivors. The sheet keeps its
    /// positions until the next scan; missing raws are terminal failures until they return.
    func preserveDecisionAfterRemoving(_ urls: Set<URL>, dropping: Bool = false) -> Bool {
        guard isBalanced, let previous = autoDecision, let roll else { return false }
        let frames = roll.frames.filter { previous.aims[$0.url] != nil && !urls.contains($0.url) }
        let identities = Dictionary(uniqueKeysWithValues: frames.map {
            ($0.url, AutoDecisions.Identity($0, stamp: sourceStamp(for: $0)))
        })
        guard let decision = AutoDecisions.restored(
            previous.record, frames: frames, identities: identities,
            stockDigest: stockDigests.indices.contains(stockIndex) ? stockDigests[stockIndex] : nil,
            controls: controls, frameControls: overrides, frameStockDigests: autoStockDigests(frames)) else { return false }
        // A frame whose raw has gone stays in the roll, as one that cannot be measured; one taken out of the roll
        // (`dropping`, `dropFrames`) leaves nothing behind.
        if !dropping { for url in urls { measurementFailures[url] = MeasurementFailure(source: nil) } }
        publish(decision, keeping: true)
        return true
    }

    /// Takes the roll's snapshot and resolves it, once every frame has its measurement or its
    /// failure, the saved choices are restored and a stock is in use, unless it is settled or doing so.
    func balanceIfReady() {
        guard !isBalanced, balanceTask == nil, let roll, !roll.frames.isEmpty, let stock = currentStock,
              manualRestoreTask == nil else { return }
        let frames = balanceFrames(in: roll)
        guard frames.allSatisfy(isMeasured) else { return }
        let generation = balanceGeneration, film = autoFilmSettings(for: frames, stock: stock)
        balanceTask = Task { [weak self] in
            await self?.balance(frames, film: film, generation: generation)
        }
    }

    private func balanceFrames(in roll: Roll) -> [Frame] {
        guard let decision = autoDecision else { return roll.frames }
        let projected = roll.frames.filter {
            !(measurementFailures[$0.url] == MeasurementFailure(source: nil) && decision.aims[$0.url] == nil)
        }
        return projected.isEmpty ? roll.frames : projected
    }

    private func balance(_ frames: [Frame], film: AutoFilmSettings, generation: UInt64) async {
        await prepareAutoDescriptors(for: frames, generation: generation)
        guard generation == balanceGeneration, !Task.isCancelled else { return }
        let decision = await resolveAuto(frames, film: film)
        guard generation == balanceGeneration, !Task.isCancelled else { return }
        balanceTask = nil
        publish(decision, keeping: true)
    }

    func prepareAutoDescriptors(for frames: [Frame], generation: UInt64) async {
        // A method that reads spatial samples needs each frame's descriptor; a frame whose measurement a recipe
        // gave has none until the sheet's decode of it is described, its measurement kept. As many at
        // once as the previews decode.
        if AutoDecisions.readsDescriptors(AutoDecisions.method), measureFrame == nil, let films {
            var missing = frames.filter { analyses[$0.url] != nil && descriptors[$0.url] == nil }.makeIterator()
            await withTaskGroup(of: (Frame, SequenceDescriptor?).self) { group in
                for _ in 0..<FilmPreviews.concurrentDecodes {
                    guard let frame = missing.next() else { break }
                    group.addTask { (frame, await films.descriptor(frame, priority: .high)) }
                }
                for await (frame, described) in group {
                    guard generation == balanceGeneration, !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    if let described, SourceStamp.of(frame.url) == measuredFrom[frame.url] { descriptors[frame.url] = described }
                    if let next = missing.next() { group.addTask { (next, await films.descriptor(next, priority: .high)) } }
                }
            }
        }
    }

    /// Detail smooths within each capture cluster, then protects each frame independently. Only
    /// replace saved aims for changed settings when the target's cluster and descriptor are ready.
    func autoAims(applying changed: [URL: FrameControls]) -> [URL: PrintAim] {
        guard AutoDecisions.method == .detail, !changed.isEmpty, isBalanced,
              let decision = autoDecision, let roll, let stock = currentStock else { return [:] }
        let frames = roll.frames.filter { decision.aims[$0.url] != nil }
        let measured = analyses.filter { !decision.failed.contains($0.key) }
        let ready = RollSmoothing.clusters(frames, analyses: measured).filter { cluster in
            cluster.allSatisfy { decision.failed.contains($0.url) || measured[$0.url] != nil }
        }
        let samples = Dictionary(uniqueKeysWithValues: ready.joined().compactMap { frame in
            changed[frame.url].flatMap { _ in descriptors[frame.url].map { (frame.url, $0) } }
        })
        guard !samples.isEmpty else { return [:] }
        let frameStocks = changed.compactMapValues { films?.stocks[safe: stockIndex(own: $0)] }
        let input = SequenceAims.Input(frames: frames, analyses: measured,
                                       descriptors: samples, stock: stock, controls: controls,
                                       frameControls: changed, frameStocks: frameStocks)
        return SequenceAims.resolve(input, method: .detail).aims.filter { samples[$0.key] != nil }
    }

    private func autoInputs(_ frames: [Frame], film: AutoFilmSettings) -> (input: SequenceAims.Input, failed: Set<URL>, stamps: [URL: SourceStamp?]) {
        let failed = Set(measurementFailures.keys)
        let input = SequenceAims.Input(frames: frames, analyses: analyses.filter { !failed.contains($0.key) },
                                       descriptors: descriptors, stock: film.stock, controls: film.controls,
                                       frameControls: film.overrides, frameStocks: film.frameStocks)
        let stamps = Dictionary(uniqueKeysWithValues: frames.map { frame in
            (frame.url, measurementFailures[frame.url].map(\.source) ?? measuredFrom[frame.url])
        })
        return (input, failed, stamps)
    }

    private nonisolated static func autoSnapshot(frames: [Frame], input: SequenceAims.Input, failed: Set<URL>,
                                                 stamps: [URL: SourceStamp?], film: AutoFilmSettings) -> AutoDecisions.Snapshot {
        // Each raw by its SHA-256 where it is known for the version measured, else by its stamp.
        let identities = Dictionary(uniqueKeysWithValues: frames.map { frame in
            (frame.url, AutoDecisions.Identity(frame, stamp: stamps[frame.url] ?? nil))
        })
        return AutoDecisions.Snapshot(input: input, stockDigest: film.stockDigest,
                                      identities: identities, failed: failed,
                                      frameStockDigests: film.frameStockDigests)
    }

    private func resolveAuto(_ frames: [Frame], film: AutoFilmSettings) async -> AutoDecisions.Decision {
        let (input, failed, stamps) = autoInputs(frames, film: film)
        return await Task.detached(priority: .userInitiated) {
            AutoDecisions.decide(Self.autoSnapshot(frames: frames, input: input, failed: failed, stamps: stamps, film: film))
        }.value
    }

    /// Puts `decision`'s aims on every frame at once, and keeps it for the roll's next open.
    private func publish(_ decision: AutoDecisions.Decision, keeping: Bool) {
        let moved = autoDecision?.revision != decision.revision
        autoDecision = decision
        decidedAims = decision.aims
        isBalanced = true
        refreshAims()
        // Reveal in Finder gives way to Develop once the aims a develop printed at are not the roll's.
        if moved, developPhase == .done { developPhase = .idle }
        observeAutoDecision?(decision)
        if keeping, let folder = roll?.folder { keep(decision.record, for: folder) }
    }

    /// Writes `record` as the roll's, after any write before it.
    private func keep(_ record: AutoDecisions.Record, for folder: URL) {
        let store = decisions, previous = decisionSave
        decisionSave = Task.detached(priority: .utility) {
            await previous?.value
            do {
                if try !store.save(record, for: folder) {
                    Self.autoLog.notice("left a decision file this build cannot read for \(folder.lastPathComponent, privacy: .public)")
                }
            } catch {
                Self.autoLog.error("decision not kept: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The roll's settled decision: its frames still unmeasured measured at `priority`, then balanced
    /// if need be. `nil` once the task is cancelled, another roll opens, or the roll cannot be balanced
    /// (no stock).
    func settledDecision(priority: Operation.QueuePriority = .high) async -> AutoDecisions.Decision? {
        let session = manualGeneration
        while !Task.isCancelled, session == manualGeneration, roll != nil {
            balanceIfReady()
            if isBalanced, let autoDecision { return autoDecision }
            if let balancing = balanceTask {
                await balancing.value
                continue
            }
            if let restoration = manualRestoreTask {
                await restoration.value
                continue
            }
            guard currentStock != nil, let unmeasured = roll?.frames.filter({ !isMeasured($0) }), !unmeasured.isEmpty
            else { return nil }
            await withTaskGroup(of: Void.self) { group in
                for frame in unmeasured { group.addTask { await self.analyze(frame, priority: priority) } }
            }
            // A measurement given up on, its raw changing under it, is made again once the source
            // watcher has seen the change.
            if roll?.frames.contains(where: { !isMeasured($0) }) == true {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return nil
    }

    /// Develop uses the live decision only if it matches the film settings captured for the jobs.
    /// Otherwise reuse the settled measurements, but do not publish the export's decision to the sheet.
    func settledDecision(for film: AutoFilmSettings) async -> AutoDecisions.Decision? {
        guard let settled = await settledDecision(), !Task.isCancelled, let roll else { return nil }
        let frames = roll.frames.filter { settled.aims[$0.url] != nil }
        if settled.record.controls == film.recordControls(for: frames) { return settled }
        return await resolveAuto(frames, film: film)
    }

    /// Roll > Rebalance Roll: the roll balanced again from its frames' measurements as they are now,
    /// in place of the decision it settled on, this session or before, its failed frames measured
    /// again first. A new revision when anything it rests on differs; the same one otherwise. Its
    /// other frames keep their settled aims until it settles.
    func rebalanceRoll() {
        guard canRebalance else { return }
        measurementFailures = [:]
        unsettle()
        analyzeRoll()
    }

    /// A stock, Rated at or Lab balance other than the decision's, for a method that reads them,
    /// balances the roll again, as it does a balance under way, which began with the ones before;
    /// roll smoothing's decision reads neither and stands.
    func autoControlsChanged() {
        guard AutoDecisions.readsStock(AutoDecisions.method) else { return }
        guard isBalanced else {
            if balanceTask != nil { unsettle() }
            return
        }
        guard let decision = autoDecision, let roll, let stock = currentStock else { return }
        let frames = roll.frames.filter { decision.aims[$0.url] != nil }
        let film = autoFilmSettings(for: frames, stock: stock)
        let now = film.recordControls(for: frames)
        guard decision.record.controls != now else { return }
        let perFrameOnly = decision.record.controls?.stockDigest == film.stockDigest
            && decision.record.controls?.roll == film.controls
        let hasDescriptors = measureFrame != nil || frames.allSatisfy { analyses[$0.url] == nil || descriptors[$0.url] != nil }
        if AutoDecisions.method == .detail, manualRestoreTask == nil, !frames.isEmpty, frames.allSatisfy(isMeasured),
           hasDescriptors, perFrameOnly || frames.count <= 64 {
            let (input, failed, stamps) = autoInputs(frames, film: film)
            publish(AutoDecisions.decide(Self.autoSnapshot(frames: frames, input: input, failed: failed, stamps: stamps, film: film)), keeping: true)
            return
        }
        unsettle()
    }

    func autoFilmSettings(for frames: [Frame], stock: Stock) -> AutoFilmSettings {
        let frameStockDigests = autoStockDigests(frames)
        let frameStocks = Dictionary(uniqueKeysWithValues: frames.compactMap { frame in
            frameStockDigests[frame.url].flatMap { _ in self.stock(for: frame).map { (frame.url, $0) } }
        })
        return AutoFilmSettings(stock: stock, stockDigest: stockDigests[stockIndex], controls: controls,
                                overrides: overrides, frameStocks: frameStocks, frameStockDigests: frameStockDigests)
    }

    private func autoStockDigests(_ frames: [Frame]) -> [URL: String] {
        Dictionary(uniqueKeysWithValues: frames.compactMap { frame in
            let index = stockIndex(for: frame)
            return index == stockIndex ? nil : (frame.url, stockDigests[index])
        })
    }
}
