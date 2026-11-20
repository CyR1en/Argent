import AppKit
import ArgentCore
import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// What the Remove tab's suites stand on: a roll of two frames with the first open and ready to adjust, the inspector on the tab
/// asked for, and a stand-in for the model's commands that says what was asked of it. The model's own are stubs until package E
/// builds them, so a suite sees what the interface calls here and nowhere else.
@MainActor final class RemoveBench {
    let model: RollModel, frame: Frame
    private let folder: URL
    private let shown = UserDefaults.standard.object(forKey: "manualInspectorShown")
    private let stored = UserDefaults.standard.object(forKey: AdjustInspectorTab.storageKey)

    private static func header(_ url: URL) throws {
        func u16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255)] }
        func u32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(n >> (8 * $0) & 255) } }
        var b: [UInt8] = [0x49, 0x49] + u16(42) + u32(8)
        b += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(26) + u32(0)
        b += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(100) + u16(0) + u32(0)
        try Data(b).write(to: url, options: .atomic)
    }

    init(tab: AdjustInspectorTab = .remove) async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-remove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.header(folder.appendingPathComponent("DSC1.ARW"))
        try Self.header(folder.appendingPathComponent("DSC2.ARW"))
        model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                          stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                          recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        await model.open(folder)
        if let restore = model.manualRestoreTask { await restore.value }
        frame = try #require(model.roll?.frames.first)
        model.selection = frame.id
        model.openFrame()
        let verified = try SourceDigests.shared.digest(of: frame.url)
        model.manualReadySources[frame.url] = verified
        model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 0.3, validWeight: 1), source: verified.source), for: frame)
        let pin = AutomaticBaseline(sourceSHA256: verified.sha256, stockID: "test", stockDigest: "digest",
            controls: .init(), aim: PrintAim(level: -0.65, cast: .zero), analysisVersion: ExposureAnalysis.currentVersion,
            baseRender: Recipe.Render(settings: DevelopSettings(), grain: .off))
        model.manualEdits[frame.url] = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.5), baseline: pin)
        model.adjustTab = tab
        model.isAdjustmentsShown = true
    }

    /// Puts back what the model wrote to the defaults, and lets go of the roll.
    func finish() {
        model.maskEditor.reset()
        model.remove.reset()
        UserDefaults.standard.set(shown, forKey: "manualInspectorShown")
        UserDefaults.standard.set(stored, forKey: AdjustInspectorTab.storageKey)
        try? FileManager.default.removeItem(at: folder)
    }

    /// An issue holds the frame, so it cannot be adjusted.
    func block(_ blocked: Bool) {
        model.manualPreparationErrors[frame.url] = blocked ? "Could not prepare adjustments: test" : nil
    }

    /// Lets the main run loop turn until `ready` holds, for what SwiftUI draws a turn later. Counted in turns and not in time:
    /// a wait on a clock grows fragile when the machine is busy.
    static func turns(until ready: () -> Bool) async {
        for _ in 0..<20_000 where !ready() { await Task.yield() }
    }
}

/// The model's Remove commands, written down as they are asked for: each call by its name and what it was given.
@MainActor final class RemoveRecorder: RemoveCommands {
    private(set) var calls: [String] = []
    private(set) var ids: [UUID] = []
    private(set) var brush: [MaskCanvasEvent] = []
    private(set) var frames: [URL] = []

    private func note(_ call: String, _ id: UUID? = nil, on frame: Frame? = nil) {
        calls.append(call)
        if let id { ids.append(id) }
        if let frame { frames.append(frame.url) }
    }

    func removeBrush(_ event: MaskCanvasEvent, on frame: Frame) {
        brush.append(event)
        note("removeBrush", on: frame)
    }

    func setRemoveSnapsToObject(_ snaps: Bool) { note("setRemoveSnapsToObject \(snaps)") }
    func commitRemoval(on frame: Frame) { note("commitRemoval", on: frame) }
    func cancelRemoval(_ id: UUID, on frame: Frame) { note("cancelRemoval", id, on: frame) }
    func setRemoval(_ id: UUID, isOn: Bool, on frame: Frame) { note("setRemoval isOn \(isOn)", id, on: frame) }
    func setRemoval(_ id: UUID, includesEffects: Bool, on frame: Frame) { note("setRemoval includesEffects \(includesEffects)", id, on: frame) }
    func remakeRemoval(_ id: UUID, better: Bool, on frame: Frame) { note("remakeRemoval better \(better)", id, on: frame) }
    func deleteRemoval(_ id: UUID, on frame: Frame) { note("deleteRemoval", id, on: frame) }
    func resetRemovals(for frame: Frame) { note("resetRemovals", on: frame) }
    func showRemovalFace(_ id: UUID, on frame: Frame) { note("showRemovalFace", id, on: frame) }
}

/// Defaults that keep what is written in memory and touch no file, as the app suites' own of this name: a bundle cannot reach
/// another's helpers.
final class ScratchDefaults: UserDefaults {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: "argent-remove-tests-scratch")! }

    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func removeObject(forKey key: String) { lock.withLock { values[key] = nil } }
}
