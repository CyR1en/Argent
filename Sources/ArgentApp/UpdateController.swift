import AppKit
import Foundation
import Observation
import os
import Sparkle

/// Which builds Argent offers through Sparkle 2 (`SPUUpdaterDelegate.allowedChannels(for:)`).
/// Sparkle always includes the default (stable) channel, so Nightly also receives newer stable releases.
enum UpdateChannel: String, CaseIterable, Equatable, Sendable {
    case stable
    case nightly

    var title: String {
        switch self {
        case .stable: "Stable"
        case .nightly: "Nightly"
        }
    }

    var note: String {
        switch self {
        case .stable: "Versioned releases only"
        case .nightly: "Every build of main, plus releases and pre-releases"
        }
    }

    /// Additional Sparkle channel names beyond the default channel.
    var sparkleChannels: Set<String> {
        switch self {
        case .stable: []
        case .nightly: ["nightly"]
        }
    }

    /// Default channel when the user has not chosen one yet: a nightly build stays on nightlies;
    /// a release or local dev build defaults to stable.
    static func defaultChannel(bundleChannel: String?) -> UpdateChannel {
        bundleChannel == "nightly" ? .nightly : .stable
    }
}

/// Manages Sparkle 2 over-the-air updates, channel selection, Settings bindings, and relaunch safety.
///
/// Nothing starts on `init()`, so tests and `RollModel()` construction never touch the network or
/// Sparkle's XPC services. `AppDelegate.attach(_:)` starts the updater once the main window appears,
/// only in a bundled `camera.argent.Argent` app (and in debug builds only when
/// `ARGENT_ENABLE_SPARKLE_DEBUG=1` is set).
@MainActor @Observable
final class UpdateController: NSObject, SPUUpdaterDelegate {
    nonisolated static let channelDefaultsKey = "updateChannel"
    nonisolated static let expectedBundleIdentifier = "camera.argent.Argent"
    private static let logger = Logger(subsystem: expectedBundleIdentifier, category: "updates")

    /// Whether Sparkle started in this build (false in tests, swift run, lanes, and unconfigured builds).
    private(set) var isAvailable = false
    /// Observed from `SPUUpdater.canCheckForUpdates` so the menu bar and Settings button stay in sync.
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = true
    private(set) var automaticallyDownloadsUpdates = false
    private(set) var allowsAutomaticUpdates = false
    private(set) var lastUpdateCheckDate: Date?
    private(set) var channel: UpdateChannel

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private weak var model: RollModel?
    @ObservationIgnored private var pendingInstallHandler: (() -> Void)?
    @ObservationIgnored private var activeWorkWatchTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, bundleChannel: String? = Bundle.main.infoDictionary?["ArgentChannel"] as? String) {
        self.defaults = defaults
        let saved = (defaults.string(forKey: Self.channelDefaultsKey)).flatMap(UpdateChannel.init(rawValue:))
        self.channel = saved ?? UpdateChannel.defaultChannel(bundleChannel: bundleChannel)
        super.init()
    }

    /// Whether this process should start Sparkle. Separated as a pure check for unit tests.
    nonisolated static func shouldStartUpdater(
        bundleURL: URL,
        bundleIdentifier: String?,
        infoDictionary: [String: Any]?,
        environment: [String: String],
        isDebugBuild: Bool,
        isRunningTests: Bool
    ) -> Bool {
        guard !isRunningTests else { return false }
        guard environment["XCTestConfigurationFilePath"] == nil else { return false }
        guard bundleURL.pathExtension == "app" else { return false }
        guard bundleIdentifier == expectedBundleIdentifier else { return false }
        if isDebugBuild && environment["ARGENT_ENABLE_SPARKLE_DEBUG"] != "1" { return false }
        guard let feed = infoDictionary?["SUFeedURL"] as? String,
              let feedURL = URL(string: feed),
              feedURL.scheme?.lowercased() == "https",
              let host = feedURL.host, !host.isEmpty else { return false }
        guard let key = infoDictionary?["SUPublicEDKey"] as? String, !key.isEmpty else { return false }
        return true
    }

    /// Starts Sparkle once when the running app is eligible. Called from `AppDelegate.attach(_:)`,
    /// after the main window appears, so launch-to-empty-state latency is unaffected.
    func start(for model: RollModel, bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.model = model
        guard controller == nil else { return }
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        let isTesting = NSClassFromString("XCTestCase") != nil
        guard Self.shouldStartUpdater(
            bundleURL: bundle.bundleURL,
            bundleIdentifier: bundle.bundleIdentifier,
            infoDictionary: bundle.infoDictionary,
            environment: environment,
            isDebugBuild: isDebug,
            isRunningTests: isTesting
        ) else { return }

        let standard = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try standard.updater.start()
        } catch {
            Self.logger.error("Sparkle updater failed to start: \(error.localizedDescription, privacy: .public)")
            return
        }
        controller = standard
        isAvailable = true
        syncFromUpdater(standard.updater)
        observe(standard.updater)
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        automaticallyChecksForUpdates = enabled
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        automaticallyDownloadsUpdates = enabled
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }

    func setChannel(_ newChannel: UpdateChannel) {
        guard channel != newChannel else { return }
        channel = newChannel
        defaults.set(newChannel.rawValue, forKey: Self.channelDefaultsKey)
        controller?.updater.resetUpdateCycleAfterShortDelay()
    }

    /// Human-readable description of active long-running work that should not be interrupted silently
    /// by an update relaunch, or `nil` when idle.
    nonisolated static func activeWorkDescription(
        isDeveloping: Bool,
        isImporting: Bool,
        isDownloadingModels: Bool,
        isMovingFrames: Bool
    ) -> String? {
        if isDeveloping { return "developing frames" }
        if isImporting { return "importing a roll" }
        if isDownloadingModels { return "downloading the Subject models" }
        if isMovingFrames { return "moving frames" }
        return nil
    }

    private func currentActiveWork() -> String? {
        guard let model else { return nil }
        return Self.activeWorkDescription(
            isDeveloping: model.isDeveloping,
            isImporting: model.importSession.isCopying,
            isDownloadingModels: model.subjectModels.isRunning,
            isMovingFrames: model.frameMove != nil
        )
    }

    /// Schedules `installHandler` to run once `isBusy` turns false; testable without Sparkle.
    func deferRelaunchUntilIdle(isBusy: @escaping @MainActor () -> Bool, installHandler: @escaping () -> Void) {
        pendingInstallHandler = installHandler
        activeWorkWatchTask?.cancel()
        activeWorkWatchTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                if !isBusy() {
                    let handler = self.pendingInstallHandler
                    self.pendingInstallHandler = nil
                    self.activeWorkWatchTask = nil
                    handler?()
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func syncFromUpdater(_ updater: SPUUpdater) {
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
    }

    private func observe(_ updater: SPUUpdater) {
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
                Task { @MainActor [weak self] in self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] updater, _ in
                Task { @MainActor [weak self] in
                    self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
                    self?.allowsAutomaticUpdates = updater.allowsAutomaticUpdates
                }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] updater, _ in
                Task { @MainActor [weak self] in self?.automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates }
            },
            updater.observe(\.allowsAutomaticUpdates, options: [.new]) { [weak self] updater, _ in
                Task { @MainActor [weak self] in self?.allowsAutomaticUpdates = updater.allowsAutomaticUpdates }
            },
        ]
    }

    // MARK: SPUUpdaterDelegate

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channel.sparkleChannels
    }

    #if DEBUG
    func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["ARGENT_SPARKLE_FEED_URL"]
    }
    #endif

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastUpdateCheckDate = updater.lastUpdateCheckDate
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let work = currentActiveWork() else { return false }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Argent is currently \(work)."
        alert.informativeText = "Wait until it finishes before installing the update, or stop now and relaunch."
        alert.addButton(withTitle: "Wait Until Finished")
        alert.addButton(withTitle: "Stop and Install Now")
        if alert.runModal() == .alertSecondButtonReturn {
            return false
        }
        deferRelaunchUntilIdle(isBusy: { [weak self] in self?.currentActiveWork() != nil }, installHandler: installHandler)
        return true
    }
}
