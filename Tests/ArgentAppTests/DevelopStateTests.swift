import ArgentCore
@testable import ArgentRoll
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import ArgentApp

@MainActor @Suite(.serialized) struct DevelopStateTests {
    enum Edit: CaseIterable, Sendable {
        case stock, rollControls, frameControls, format, quality, space, grain
    }

    private static let frame = Frame(id: 0, url: URL(fileURLWithPath: "/tmp/develop-state/DSC1.ARW"), info: ARWFrameInfo())

    private static func withModel(_ body: (RollModel) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-develop-settings-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let savedOutput = UserDefaults.standard.data(forKey: "outputSettings")
        defer {
            UserDefaults.standard.set(savedOutput, forKey: "outputSettings")
            try? FileManager.default.removeItem(at: folder)
        }
        body(RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                       stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                       recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil))
    }

    private static func report(_ outcomes: [RollDeveloper.Outcome] = [.developed(URL(fileURLWithPath: "/tmp/develop-state/DSC1.jpg"))]) -> DevelopReport {
        DevelopReport(frames: [frame], outcomes: outcomes, destination: URL(fileURLWithPath: "/tmp/develop-state"))
    }

    private static func writeHeader(_ url: URL, iso: UInt16, tail: Data = Data()) throws {
        func u16(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8(value >> 8 & 255)] }
        func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 255) } }
        let exif = 8 + 2 + 12 + 4
        var bytes = [UInt8]([0x49, 0x49]) + u16(42) + u32(8)
        bytes += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(exif) + u32(0)
        bytes += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(Int(iso)) + u16(0) + u32(0)
        try (Data(bytes) + tail).write(to: url, options: .atomic)
    }

    /// Saves a develop of `frame` to `file`, as a develop's receipt reaches the recipe writer, in `library`.
    private static func saveReceipt(for frame: Frame, file: URL, revision: UInt64, library: URL) async throws {
        let stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                          exposurePerUnit: SIMD3(0.8, 0.8, 0.8), negative: LUT3D.identity(size: 2), print: LUT3D.identity(size: 2))
        var recipe = Recipe(frame: frame, byteCount: RecipeStore.byteCount(of: frame.url), stock: stock, stockDigest: stock.digest,
                            roll: RollControls(), own: FrameControls(), editRevision: revision)
        recipe.raw.sha256 = try SourceDigests.shared.digest(of: frame.url).sha256
        recipe.develops = [Recipe.Develop(date: Date(), software: "Argent test", output: OutputSettings(), file: file.path,
            width: 1, height: 1, render: recipe.render, decode: nil, readback: nil, stockDigest: stock.digest,
            renderVersion: nil, fallbackFrom: nil, outputSource: SourceStamp.of(file))]
        _ = try await RecipeWriter.shared.mergeExport(recipe: recipe, for: frame, library: library)
    }

    /// A roll of one header-only raw and a toy stock, opened; `before` gets the roll's folder, the
    /// destination and the model's library before it opens. The library, of recipes, decisions and
    /// flags, is the run's own folder, and goes with the roll.
    private static func withExportModel(before: (URL, URL, URL) async throws -> Void = { _, _, _ in },
                                        _ body: (RollModel, URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-develop-lifecycle-\(UUID().uuidString)")
        let roll = folder.appendingPathComponent("Roll")
        let stocks = folder.appendingPathComponent("Stocks")
        let stock = stocks.appendingPathComponent("toy")
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stock, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roll.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let raw = roll.appendingPathComponent("DSC1.ARW")
        try Self.writeHeader(raw, iso: 100, tail: Data(UUID().uuidString.utf8))
        let lut = LUT3D.identity(size: 2)
        try lut.binaryData().write(to: stock.appendingPathComponent("negative.lut3d"))
        try lut.binaryData().write(to: stock.appendingPathComponent("print.lut3d"))
        let manifest: [String: Any] = [
            "schema": 2, "id": "toy", "displayName": "Toy", "status": "synthetic", "boxSpeed": 400, "densityRange": 2.5,
            "negative": ["file": "negative.cube", "binary": "negative.lut3d", "size": 2,
                         "logEncoding": ["stopsBelowMidGray": 8, "stopsAboveMidGray": 5, "midGray": 0.18]],
            "print": ["file": "print.cube", "binary": "print.lut3d", "size": 2, "exposurePerUnit": [0.8, 0.8, 0.8]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: stock.appendingPathComponent(Stock.manifestName))
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: stocks, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        defer {
            model.stopDevelop()
            model.clearManualSession()
            model.analysisTask?.cancel()
        }
        try await before(roll, folder.appendingPathComponent("Export"), folder)
        await model.open(roll)
        if let restoration = model.manualRestoreTask { await restoration.value }
        _ = try #require(model.films)
        try await body(model, folder.appendingPathComponent("Export"))
    }

    @Test(arguments: [false, true])
    func developWaitingForRestorationIsTrackedAndCanBeStopped(saveFailed: Bool) async throws {
        try await Self.withExportModel { model, destination in
            let gate = AsyncStream<Void>.makeStream()
            defer { gate.continuation.finish() }
            model.manualSaveFailed = saveFailed
            model.manualSaveMessage = saveFailed ? "fixture save failure" : nil
            model.isRestoringManual = true
            model.manualRestoreTask = Task {
                for await _ in gate.stream { }
                model.manualRestoreTask = nil
                model.isRestoringManual = false
            }

            model.startDevelop(to: destination)
            let running = try #require(model.developTask)
            #expect(model.isDeveloping)
            model.startDevelop(to: destination.appendingPathComponent("Another"))
            #expect(model.developTask == running)
            #expect(model.developDestination == destination)

            model.stopDevelop()
            #expect(running.isCancelled)
            gate.continuation.finish()
            await running.value

            #expect(model.developPhase == .idle)
            #expect(model.developTask == nil)
            #expect(model.lastDevelop == nil)
            #expect(model.message == nil)
            #expect(model.manualSaveFailed == saveFailed)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    enum DevelopEnd: CaseIterable, Sendable { case stopped, couldNotStart }

    /// The names of the idle-sleep assertions this process holds, as `pmset -g assertions` lists
    /// them; a user-initiated activity takes one under its reason.
    private static func heldAssertions() -> [String] {
        var all: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&all) == kIOReturnSuccess,
              let byProcess = all?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return (byProcess[NSNumber(value: getpid())] ?? []).compactMap { $0["AssertName"] as? String }
    }

    private static var holdsDevelopActivity: Bool { heldAssertions().contains(RollModel.developActivityReason) }

    /// Whether the system still lists the develop's activity for this process after two seconds,
    /// in case it lets an assertion go after `endActivity` returns.
    private static func keepsDevelopActivity() async -> Bool {
        for _ in 0..<100 {
            guard holdsDevelopActivity else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// A develop holds a user-initiated activity, which keeps App Nap off it while the app is
    /// hidden (docs/manual-development-validation.md, "App Nap and a develop in the background"),
    /// from its start while it waits on restoration, and lets it go when it is stopped or cannot
    /// start. One run to its end is not run here: its notification needs the app's bundle. The
    /// app's own runs show the nap back once such a develop ends.
    @Test(arguments: DevelopEnd.allCases)
    func developHoldsAnActivityUntilItEnds(_ end: DevelopEnd) async throws {
        try await Self.withExportModel { model, destination in
            #expect(!(await Self.keepsDevelopActivity()))
            let gate = AsyncStream<Void>.makeStream()
            defer { gate.continuation.finish() }
            model.isRestoringManual = true
            model.manualRestoreTask = Task {
                for await _ in gate.stream { }
                model.manualRestoreTask = nil
                model.isRestoringManual = false
            }
            if end == .couldNotStart {
                model.manualSaveFailed = true
                model.manualSaveMessage = "fixture save failure"
            }

            model.startDevelop(to: destination)
            let running = try #require(model.developTask)
            // Listed before the develop's task first runs, and while it waits on restoration.
            #expect(Self.holdsDevelopActivity)
            try await Task.sleep(for: .milliseconds(50))
            #expect(Self.holdsDevelopActivity)
            if end == .stopped { model.stopDevelop() }
            gate.continuation.finish()
            await running.value

            #expect(!(await Self.keepsDevelopActivity()))
            #expect(model.developTask == nil)
            switch end {
            case .stopped: #expect(model.lastDevelop == nil && model.message == nil)
            case .couldNotStart: #expect(model.message?.hasPrefix("Develop could not start") == true)
            }
        }
    }

    @Test func quittingRejectsNewDevelopRequests() async throws {
        try await Self.withExportModel { model, destination in
            model.isQuitting = true
            model.develop()
            model.startDevelop(to: destination)

            #expect(model.developPhase == .idle)
            #expect(model.developTask == nil)
            #expect(model.chosenDevelopFolder == nil)
        }
    }

    @Test(arguments: [false, true])
    func replacingAnAlreadyWrittenRawDuringExportKeepsTheRollReadyToDevelop(observedBeforeCompletion: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-develop-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("DSC1.ARW")
        try Self.writeHeader(raw, iso: 100)
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        await model.open(folder)
        let frame = try #require(model.selectedFrame)
        let source = try #require(model.sourceStamp(for: frame))
        model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 0, validWeight: 1), source: source), for: frame)
        let inputs = DevelopInputs(model)
        model.developPhase = .developing(DevelopProgress(total: 1))
        let report = DevelopReport(frames: [frame], outcomes: [.developed(folder.appendingPathComponent("DSC1.jpg"))], destination: folder)
        try Self.writeHeader(raw, iso: 6400)
        if observedBeforeCompletion { #expect(model.forgetChangedSources()) }

        model.recordDevelop(report, inputs: inputs)

        #expect(model.developPhase == .idle)
        #expect(model.lastDevelop == report)
        #expect(model.selectedFrame?.info.iso == 6400)
        #expect(model.sourceStamp(for: frame) == SourceStamp.of(raw))
        #expect(model.analysis(for: frame) == nil)
    }

    @Test(arguments: Edit.allCases)
    func editsMadeDuringExportLeaveTheCurrentSettingsReadyToDevelop(_ edit: Edit) {
        Self.withModel { model in
            let inputs = DevelopInputs(model)
            model.developPhase = .developing(DevelopProgress(total: 1))
            switch edit {
            case .stock: model.stockIndex += 1
            case .rollControls: model.controls.labBalance = model.controls.labBalance == .warm ? .cool : .warm
            case .frameControls: model.setRatedAt(.oneStopUnder, for: Self.frame)
            case .format: model.output.format = model.output.format == .heic ? .jpeg : .heic
            case .quality: model.output.quality = model.output.quality == 60 ? 92 : 60
            case .space: model.output.space = model.output.space == .sRGB ? .displayP3 : .sRGB
            case .grain: model.output.grain = model.output.grain == .natural ? .off : .natural
            }
            #expect(model.developPhase == .developing(DevelopProgress(total: 1)))

            let report = Self.report()
            model.recordDevelop(report, inputs: inputs)

            #expect(model.developPhase == .idle)
            #expect(model.lastDevelop == report)
        }
    }

    /// A mask made while a develop runs is an edit like any other: the develop's inputs are older, so when it ends
    /// the frame is ready to develop again rather than Done.
    @Test func aMaskEditDuringADevelopLeavesDevelopAvailable() async throws {
        try await Self.withExportModel { model, _ in
            let frame = try #require(model.roll?.frames.first)
            let verified = try SourceDigests.shared.digest(of: frame.url)
            model.manualReadySources[frame.url] = verified
            model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 0.3, validWeight: 1), source: verified.source), for: frame)
            model.startFrom(.original, for: frame)
            #expect(model.canAddMask(frame))
            model.selection = frame.id
            model.openFrame()
            defer { model.maskEditor.reset() }
            let inputs = DevelopInputs(model)
            model.developPhase = .developing(DevelopProgress(total: 1))
            model.perform(.newMask(.linear))
            #expect(model.placeArmedGradient())
            #expect(model.masks(for: frame).count == 1)
            #expect(model.developPhase == .developing(DevelopProgress(total: 1)))
            model.recordDevelop(Self.report(), inputs: inputs)
            #expect(model.developPhase == .idle)
        }
    }

    @Test func aNewQualityTurnsRevealBackIntoDevelop() {
        Self.withModel { model in
            let inputs = DevelopInputs(model)
            model.developPhase = .developing(DevelopProgress(total: 1))
            model.recordDevelop(Self.report(), inputs: inputs)
            #expect(model.developPhase == .done)

            model.output.quality = model.output.quality == 60 ? 92 : 60
            #expect(model.developPhase == .idle)
        }
    }

    @Test func unchangedSettingsAndAnEditRevertedDuringExportFinishDone() {
        Self.withModel { model in
            let inputs = DevelopInputs(model)
            model.developPhase = .developing(DevelopProgress(total: 1))
            model.recordDevelop(Self.report(), inputs: inputs)
            #expect(model.developPhase == .done)

            model.developPhase = .developing(DevelopProgress(total: 1))
            let original = model.controls
            model.controls.labBalance = original.labBalance == .warm ? .cool : .warm
            model.controls = original
            model.recordDevelop(Self.report(), inputs: inputs)
            #expect(model.developPhase == .done)
        }
    }

    @Test func stoppedOrFailedExportsRemainReadyToDevelop() {
        Self.withModel { model in
            let inputs = DevelopInputs(model)
            for outcome in [RollDeveloper.Outcome.stopped, .failed("could not write")] {
                model.developPhase = .developing(DevelopProgress(total: 1))
                model.recordDevelop(Self.report([outcome]), inputs: inputs)
                #expect(model.developPhase == .idle)
            }
        }
    }

    /// A develop's receipts become the session's recipes for the frames it wrote, so the next
    /// develop in the session starts from them, and later roll-level choices are saved for them.
    @Test func aDevelopsReceiptsAreTheSessionsRecipesAfterIt() async throws {
        try await Self.withExportModel { model, destination in
            let frame = try #require(model.selectedFrame)
            #expect(model.manualRecipes[frame.url] == nil)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let file = destination.appendingPathComponent("DSC1.jpg")
            try Data("developed".utf8).write(to: file)
            try await Self.saveReceipt(for: frame, file: file, revision: model.editRevision, library: model.recipeLibrary)

            await model.adoptDevelopedRecipes([frame], [.developed(file)])
            #expect(model.manualRecipes[frame.url]?.develops.last?.file == file.path)
            model.controls.labBalance = model.controls.labBalance == .warm ? .cool : .warm
            let saving = try #require(model.manualSaveTasks[frame.url])
            await saving.value
            #expect(!model.manualSaveFailed)
        }
    }

    /// A raw that cannot be read while the roll's recipes are restored, as a share can fail for a
    /// moment, leaves its saved adjustments unknown: said readably, and read again before a develop
    /// rather than refusing every develop of the roll until it is opened again.
    @Test func aRecipeUnreadableAtRestoreIsReadAgainBeforeItBlocksADevelop() async throws {
        try await Self.withExportModel { model, _ in
            let roll = try #require(model.roll), frame = try #require(model.selectedFrame)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: frame.url.path)
            // Seen now, so the source watcher does not take the change for a replaced raw meanwhile.
            model.forgetChangedSources()
            model.clearManualSession()
            model.restoreManualSession(roll)
            await model.manualRestoreTask?.value

            let issue = try #require(model.manualIssue(for: frame))
            #expect(issue.contains("could not be read"), "\(issue)")
            #expect(!model.manualLoaded.contains(frame.url))
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: frame.url.path)
            model.forgetChangedSources()
            await model.retryUnreadManualRecipes(roll.frames)
            #expect(model.manualIssue(for: frame) == nil)
            #expect(model.manualLoaded.contains(frame.url))
        }
    }

    /// A save whose library write failed stays with the recipe writer, whose flush before a
    /// develop or a quit saves it; the save is then no longer reported as failed.
    @Test func aSaveTheFlushCompletesIsNoLongerAFailure() async throws {
        try await Self.withExportModel { model, _ in
            let frame = try #require(model.selectedFrame)
            let sha = try SourceDigests.shared.digest(of: frame.url).sha256
            let journals = RecipeWriter.journalURL(sha256: sha, lineage: "unwritable", library: model.recipeLibrary)
                .deletingLastPathComponent()
            try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: journals.path) }
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: journals.path)
            model.saveManualFrame(frame)
            await model.manualSaveTasks[frame.url]?.value
            #expect(model.manualSaveFailed)

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: journals.path)
            try await model.flushManualSaves()
            #expect(!model.manualSaveFailed)
            #expect(model.manualSaveMessage == nil)
        }
    }

    #if DEBUG
    @Test(.enabled(if: hasLensGeometrySample))
    func quickDevelopAndDevelopWriteToTheSelectedSubfolderOrItsParent() async throws {
        let stored = UserDefaults.standard.data(forKey: "outputSettings")
        defer { UserDefaults.standard.set(stored, forKey: "outputSettings") }
        try await Self.withExportModel(before: { roll, _, _ in
            try cloneLensGeometrySample(to: roll.appendingPathComponent("DSC1.ARW"))
        }) { model, base in
            let roll = try #require(model.roll)
            model.askToDevelop(roll.frames)
            model.quickDevelop?.output.format = .jpeg
            model.quickDevelop?.folder.base = base
            model.quickDevelop?.folder.subfolderName = "Proof prints"
            await FlagStateTests.develop(model) { model.confirmQuickDevelop() }

            let nested = base.appendingPathComponent("Proof prints", isDirectory: true)
            let photo = try #require(model.lastDevelop?.files.first)
            #expect(photo.deletingLastPathComponent().canonicalPath == nested.canonicalPath)
            #expect(FileManager.default.fileExists(atPath: photo.path))

            await model.open(roll.folder)
            await model.manualRestoreTask?.value
            #expect(model.developFolder.base.canonicalPath == base.canonicalPath)
            #expect(model.developFolder.usesSubfolder && model.developFolder.subfolderName == "Proof prints")
            model.showDevelopPage()
            model.developFolder.usesSubfolder = false
            await FlagStateTests.develop(model) { model.performDevelopPrimary() }
            let flat = try #require(model.lastDevelop?.files.first)
            #expect(flat.deletingLastPathComponent().canonicalPath == base.canonicalPath)
            #expect(FileManager.default.fileExists(atPath: flat.path))
        }
    }

    @Test(.enabled(if: hasLensGeometrySample))
    func reopeningAMovedRollKeepsItsSubfolderChoice() async throws {
        try await Self.withProofsExport { model, roll, proofs in
            let entry = try #require(model.openLibraryRoll)
            let moved = roll.folder.deletingLastPathComponent().appendingPathComponent("Moved Roll", isDirectory: true)
            try FileManager.default.moveItem(at: roll.folder, to: moved)
            await model.open(moved)
            await model.manualRestoreTask?.value

            #expect(model.openLibraryRoll?.id == entry.id)
            #expect(model.developFolder.usesSubfolder)
            #expect(model.developDestination?.canonicalPath == proofs.canonicalPath)
            model.developFolder.usesSubfolder = false
            #expect(model.developDestination?.canonicalPath == proofs.deletingLastPathComponent().canonicalPath)
        }
    }

    @Test(.enabled(if: hasLensGeometrySample))
    func reopeningFollowsARenamedExportSubfolder() async throws {
        try await Self.withProofsExport { model, roll, proofs in
            let finals = proofs.deletingLastPathComponent().appendingPathComponent("Finals", isDirectory: true)
            try FileManager.default.moveItem(at: proofs, to: finals)
            // A new folder at the old path must not take over the next develop.
            try FileManager.default.createDirectory(at: proofs, withIntermediateDirectories: false)
            for _ in 0..<2 {
                await model.open(roll.folder)
                await model.manualRestoreTask?.value
                #expect(model.developFolder.usesSubfolder && model.developFolder.subfolderName == "Finals")
                #expect(model.developDestination?.canonicalPath == finals.canonicalPath)
            }
            model.askToDevelop(roll.frames)
            await FlagStateTests.develop(model) { model.confirmQuickDevelop() }
            let photo = try #require(model.lastDevelop?.files.first)
            #expect(photo.deletingLastPathComponent().canonicalPath == finals.canonicalPath)
            #expect(FileManager.default.fileExists(atPath: photo.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: proofs.path).isEmpty)
        }
    }

    /// A copy of a developed roll, as Finder makes one with or without its recipes, shares the
    /// roll's edits but not its export: it opens with no folder chosen, and developing it into the
    /// roll's folder writes a file of its own rather than over the roll's (#20).
    @Test(.enabled(if: hasLensGeometrySample), arguments: [true, false])
    func aCopyOfADevelopedRollDoesNotTakeOverItsExport(keepingRecipes: Bool) async throws {
        try await Self.withProofsExport { model, roll, proofs in
            let original = try #require(model.lastDevelop?.files.first)
            let developed = try Data(contentsOf: original)
            let copy = roll.folder.deletingLastPathComponent().appendingPathComponent("Roll copy", isDirectory: true)
            try FileManager.default.copyItem(at: roll.folder, to: copy)
            if !keepingRecipes {
                for frame in roll.frames {
                    try? FileManager.default.removeItem(at: RecipeStore.besideRaw(copy.appendingPathComponent(frame.url.lastPathComponent)))
                }
            }
            await model.open(copy)
            await model.manualRestoreTask?.value
            #expect(model.chosenDevelopFolder == nil)

            let frames = try #require(model.roll?.frames)
            model.controls.labBalance = model.controls.labBalance == .warm ? .cool : .warm
            model.askToDevelop(frames)
            model.quickDevelop?.output.format = .jpeg
            model.quickDevelop?.folder.base = proofs.deletingLastPathComponent()
            model.quickDevelop?.folder.subfolderName = proofs.lastPathComponent
            await FlagStateTests.develop(model) { model.confirmQuickDevelop() }

            let photo = try #require(model.lastDevelop?.files.first)
            #expect(photo.canonicalPath != original.canonicalPath)
            #expect(FileManager.default.fileExists(atPath: photo.path))
            #expect(try Data(contentsOf: original) == developed)
        }
    }

    private static func withProofsExport(_ body: (RollModel, Roll, URL) async throws -> Void) async throws {
        let stored = UserDefaults.standard.data(forKey: "outputSettings")
        defer { UserDefaults.standard.set(stored, forKey: "outputSettings") }
        try await withExportModel(before: { roll, _, _ in
            try cloneLensGeometrySample(to: roll.appendingPathComponent("DSC1.ARW"))
        }) { model, base in
            let roll = try #require(model.roll)
            model.askToDevelop(roll.frames)
            model.quickDevelop?.output.format = .jpeg
            model.quickDevelop?.folder.base = base
            model.quickDevelop?.folder.subfolderName = "Proofs"
            await FlagStateTests.develop(model) { model.confirmQuickDevelop() }
            let photo = try #require(model.lastDevelop?.files.first)
            try await body(model, roll, photo.deletingLastPathComponent())
        }
    }
    #endif

    @Test func developAndQuickDevelopSuggestTheLibraryNameUntilTheUserNamesTheSubfolder() async throws {
        try await Self.withExportModel { model, base in
            let roll = try #require(model.roll)
            let entry = try #require(model.openLibraryRoll)
            model.chooseDestination(base)
            model.renameLibraryRoll(id: entry.id, to: "Summer in Denver")
            #expect(model.developFolder.subfolderName == "Summer in Denver")
            model.askToDevelop(roll.frames)
            #expect(model.quickDevelop?.folder.subfolderName == "Summer in Denver")

            model.developFolder.subfolderName = "Prints"
            model.renameLibraryRoll(id: entry.id, to: "Colorado")
            #expect(model.developFolder.subfolderName == "Prints")
            await model.open(roll.folder)
            await model.manualRestoreTask?.value
            #expect(model.developFolder.subfolderName == "Colorado")
        }
    }

    /// On a locked card only the library's working record keeps a develop: opening the roll
    /// again still restores the folder it developed to.
    @Test func aReadOnlyRollOpensWithTheFolderItLastDevelopedTo() async throws {
        try await Self.withExportModel(before: { roll, destination, library in
            let raw = roll.appendingPathComponent("DSC1.ARW")
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roll.path)
            // A digest is kept, and restoring trusts the raw's measurement, only once it has settled.
            try await Task.sleep(for: .seconds(2.5))
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let file = destination.appendingPathComponent("DSC1.jpg")
            try Data("developed".utf8).write(to: file)
            try await Self.saveReceipt(for: Frame(id: 0, url: raw, info: ARWFrameInfo()), file: file, revision: 1, library: library)
            #expect(!FileManager.default.fileExists(atPath: RecipeStore.besideRaw(raw).path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["DSC1.jpg"])
        }) { model, destination in
            #expect(model.developDestination?.canonicalPath == destination.canonicalPath)
        }
    }
}
