import AppKit
import ArgentCore
import ArgentRoll
import Foundation
import Observation
import SwiftUI
import Testing
@testable import ArgentApp

/// Onboarding flow, launch eligibility, background mask-model downloads from onboarding, Settings mask-model
/// state/removal, rail progress indicators, and menu guards.
@MainActor @Suite(.serialized) struct OnboardingTests {
    private static func makeModel(
        in folder: URL,
        defaults: UserDefaults = ScratchDefaults()
    ) -> RollModel {
        let library = folder.appendingPathComponent("Recipes", isDirectory: true)
        return RollModel(
            bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
            stocksDirectory: folder,
            decisions: AutoDecisionStore(library: library),
            flagStore: FlagStore(library: library),
            recipeLibrary: library,
            previewCache: folder.appendingPathComponent("Linear Previews"),
            digestsFile: nil,
            onboarding: OnboardingController(defaults: defaults)
        )
    }

    private static func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func launchEligibilityGuardsTestsLanesPendingURLsAndOverrides() {
        let appID = UpdateController.expectedBundleIdentifier

        // Fresh normal app launch shows onboarding.
        #expect(OnboardingController.shouldPresentOnLaunch(
            hasCompleted: false, hasPendingURLs: false, bundleIdentifier: appID, environment: [:], isRunningTests: false
        ))
        // Unbundled `swift run` also shows onboarding on fresh run.
        #expect(OnboardingController.shouldPresentOnLaunch(
            hasCompleted: false, hasPendingURLs: false, bundleIdentifier: nil, environment: [:], isRunningTests: false
        ))
        // Completed launches skip onboarding.
        #expect(!OnboardingController.shouldPresentOnLaunch(
            hasCompleted: true, hasPendingURLs: false, bundleIdentifier: appID, environment: [:], isRunningTests: false
        ))
        // Launching directly onto a roll via Finder / `open -a` defers onboarding.
        #expect(!OnboardingController.shouldPresentOnLaunch(
            hasCompleted: false, hasPendingURLs: true, bundleIdentifier: appID, environment: [:], isRunningTests: false
        ))
        // Measurement and lane builds never present onboarding automatically.
        #expect(!OnboardingController.shouldPresentOnLaunch(
            hasCompleted: false, hasPendingURLs: false, bundleIdentifier: "camera.argent.Argent.m5", environment: [:], isRunningTests: false
        ))
        // Unit test runs never present onboarding automatically.
        #expect(!OnboardingController.shouldPresentOnLaunch(
            hasCompleted: false, hasPendingURLs: false, bundleIdentifier: appID, environment: [:], isRunningTests: true
        ))
        #expect(!OnboardingController.shouldPresentOnLaunch(
            hasCompleted: false, hasPendingURLs: false, bundleIdentifier: appID,
            environment: ["XCTestConfigurationFilePath": "/tmp/t.xctestconfiguration"], isRunningTests: false
        ))
        // Explicit environment overrides work cleanly.
        #expect(!OnboardingController.shouldPresentOnLaunch(
            hasCompleted: false, hasPendingURLs: false, bundleIdentifier: appID,
            environment: ["ARGENT_SKIP_ONBOARDING": "1"], isRunningTests: false
        ))
        #expect(OnboardingController.shouldPresentOnLaunch(
            hasCompleted: true, hasPendingURLs: true, bundleIdentifier: "camera.argent.Argent.m5",
            environment: ["ARGENT_SHOW_ONBOARDING": "1"], isRunningTests: false
        ))
    }

    @Test func onboardingNavigationAndCompletionPersistAcrossLaunches() {
        let defaults = ScratchDefaults()
        let controller = OnboardingController(defaults: defaults)
        #expect(!controller.hasCompleted && !controller.isPresented && controller.step == .welcome)

        controller.present()
        #expect(controller.isPresented && controller.step == .welcome)

        controller.advance()
        #expect(controller.step == .appearance && controller.navigationDirection == 1)
        controller.advance()
        #expect(controller.step == .preferences && controller.navigationDirection == 1)
        controller.goBack()
        #expect(controller.step == .appearance && controller.navigationDirection == -1)
        controller.goTo(.maskModels)
        #expect(controller.step == .maskModels && controller.navigationDirection == 1)
        controller.showsMaskModelLicences = true
        controller.goBack()
        #expect(controller.step == .preferences && !controller.showsMaskModelLicences)

        controller.goTo(.maskModels)
        controller.advance()
        #expect(!controller.isPresented && controller.hasCompleted)

        // Persisted across relaunch.
        let reloaded = OnboardingController(defaults: defaults)
        #expect(reloaded.hasCompleted && !reloaded.isPresented)

        // Reset clears completion.
        reloaded.resetCompletion()
        #expect(!reloaded.hasCompleted)
        #expect(!OnboardingController(defaults: defaults).hasCompleted)

        // Non-boolean stored value safely falls back to false.
        defaults.set("yes", forKey: OnboardingController.completedKey)
        #expect(!OnboardingController(defaults: defaults).hasCompleted)
    }

    @Test func downloadingMaskModelsFromOnboardingRunsInBackgroundAndUpdatesRailAndSettings() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-onboarding-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let defaults = ScratchDefaults()
        let model = Self.makeModel(in: folder, defaults: defaults)
        let engine = SessionSmartEngine()
        engine.availabilities = [
            .sky: .needsModels(BundledSmartMasks.needsModels(.sky)),
            .subject: .needsModels(BundledSmartMasks.needsModels(.subject)),
            .background: .needsModels(BundledSmartMasks.needsModels(.background)),
        ]
        model.smartMasks.inference = MaskInference(engine: engine, turns: DecodeTurns())
        #expect(model.maskModelsInstallState == .notInstalled)

        model.showOnboarding(startingAt: .maskModels)
        #expect(model.onboarding.isPresented && model.isSheetShown && model.menuState.isShowingOnboarding && model.menuState.isSheetShown)

        let gate = OnboardingGate()
        model.maskModels.installer = { _, _, step in
            step(.downloading(0.5))
            try await gate.wait()
            engine.lock.withLock {
                engine.availabilities[.sky] = .available
                engine.availabilities[.subject] = .available
                engine.availabilities[.background] = .available
            }
            step(.done)
        }

        model.downloadMaskModelsAndFinishOnboarding()
        #expect(!model.onboarding.isPresented && model.onboarding.hasCompleted)
        #expect(!model.maskModels.isShown, "background download does not pop the modal sheet")
        #expect(model.maskModels.isRunning)
        #expect(model.maskModels.noticeKind == .running)

        try await Self.waitFor { gate.isWaiting && (model.maskModelsFraction ?? 0) > 0.4 }
        #expect(!model.maskModelsWantsAttention)
        let fraction = try #require(model.maskModelsFraction)
        #expect(fraction > 0.4 && fraction < 0.6)

        // Navigating from the background download notice opens Settings targeting Mask models.
        model.showSettings(section: .maskModels)
        #expect(model.workspacePage == .settings && model.pendingSettingsSection == .maskModels)

        // Complete the background download and confirm install state updates immediately.
        gate.resume()
        try await Self.waitFor { model.maskModels.phase == .done }
        #expect(!model.maskModels.isRunning && model.maskModelsFraction == nil)
        #expect(model.maskModelsInstallState == .downloaded)
        #expect(model.maskModelsInstallState.isInstalled && model.maskModelsInstallState.canRemove)
    }

    @Test func backgroundDownloadFailureRaisesAttentionUntilSettingsIsOpened() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-onboarding-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let model = Self.makeModel(in: folder)
        model.maskModels.installer = { _, _, _ in
            throw MaskModelPack.Failure.download("network unavailable")
        }

        model.showOnboarding(startingAt: .maskModels)
        model.downloadMaskModelsAndFinishOnboarding()
        try await Self.waitFor { !model.maskModels.isRunning }

        guard case .failed(let why) = model.maskModels.phase else {
            Issue.record("expected failed phase, got \(model.maskModels.phase)")
            return
        }
        #expect(why.contains("network unavailable"))
        #expect(model.maskModelsWantsAttention)
        #expect(model.maskModels.noticeKind == .failed)

        // Visiting Settings acknowledges the unseen failure attention dot while keeping the error readable in Settings.
        model.showWorkspacePage(.settings)
        #expect(!model.maskModelsWantsAttention)
        #expect(model.maskModels.phase == .failed(why))

        // Dismissing in Settings clears the failure cleanly.
        model.maskModels.clearOutcome()
        #expect(model.maskModels.phase == .idle && model.maskModels.noticeKind == .none)
    }

    @Test func removingDownloadedMaskModelsInSettingsUpdatesInstallState() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-settings-remove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let model = Self.makeModel(in: folder)
        let engine = SessionSmartEngine()
        engine.availabilities = [.sky: .available, .subject: .available, .background: .available]
        model.smartMasks.inference = MaskInference(engine: engine, turns: DecodeTurns())
        #expect(model.maskModelsInstallState == .downloaded)

        let removed = OnboardingCounter()
        model.maskModelsRemover = { _, _ in
            removed.increment()
            engine.lock.withLock {
                engine.availabilities[.sky] = .needsModels(BundledSmartMasks.needsModels(.sky))
                engine.availabilities[.subject] = .needsModels(BundledSmartMasks.needsModels(.subject))
                engine.availabilities[.background] = .needsModels(BundledSmartMasks.needsModels(.background))
            }
        }

        let observed = OnboardingCounter()
        withObservationTracking { _ = model.maskModelsInstallState } onChange: { observed.increment() }

        await model.removeDownloadedMaskModels()
        #expect(removed.value == 1)
        #expect(observed.value == 1)
        #expect(!model.isRemovingMaskModels && model.maskModelsRemovalError == nil)
        #expect(model.maskModelsInstallState == .notInstalled)
    }

    @Test func installStateDistinguishesBundledDownloadedAndNotInstalledOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-mask-inspect-\(UUID().uuidString)")
        let bundled = folder.appendingPathComponent("Bundled", isDirectory: true)
        let downloaded = folder.appendingPathComponent("Downloaded", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloaded, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func writeValidModel(_ model: BundledMaskModel, in dir: URL) throws {
            let modelDir = dir.appendingPathComponent(model.fileName, isDirectory: true)
            try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
            try Data(repeating: 0xAB, count: 32).write(to: modelDir.appendingPathComponent("main.hash"))
            let manifest: [String: String] = [
                "recipe id": model.recipeID,
                "weights sha256": model.weightsSHA256,
                "canary output sha256": model.canarySHA256,
            ]
            try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent(model.manifestName))
        }

        let ledger = folder.appendingPathComponent("Mask models.json")
        let emptyModels = MaskModels(directories: [bundled, downloaded], downloadableDirectory: downloaded, ledgerFile: ledger)
        #expect(MaskModelsInstallState.inspect(models: emptyModels) == .notInstalled)

        // All four in downloaded folder -> .downloaded (removable).
        for m in MaskModelPack.models { try writeValidModel(m, in: downloaded) }
        #expect(MaskModelsInstallState.inspect(models: emptyModels) == .downloaded)

        // All four in bundled folder -> .bundled (not removable).
        for m in MaskModelPack.models { try writeValidModel(m, in: bundled) }
        #expect(MaskModelsInstallState.inspect(models: emptyModels) == .bundled)
    }

    @Test func onboardingViewAndSettingsPageRenderInHostedWindowAcrossSteps() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-onboarding-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let model = Self.makeModel(in: folder)
        model.showOnboarding()

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: ContentView().environment(model))

        for step in OnboardingStep.allCases {
            model.onboarding.goTo(step)
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        model.onboarding.complete()
        model.showSettings(section: .maskModels)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        #expect(!model.onboarding.isPresented && model.workspacePage == .settings)
    }
}

private final class OnboardingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var resumed = false

    var isWaiting: Bool { lock.withLock { continuation != nil } }

    func wait() async throws {
        try await withCheckedThrowingContinuation { cont in
            let already: Bool = lock.withLock {
                if resumed { return true }
                continuation = cont
                return false
            }
            if already { cont.resume() }
        }
    }

    func resume() {
        let cont: CheckedContinuation<Void, any Error>? = lock.withLock {
            resumed = true
            defer { continuation = nil }
            return continuation
        }
        cont?.resume()
    }
}

private final class OnboardingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
