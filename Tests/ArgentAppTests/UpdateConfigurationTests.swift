import Foundation
import Testing
@testable import ArgentApp

/// Guards the Sparkle 2 bundle configuration (`App/Info.plist`), sandbox XPC entitlements
/// (`App/Argent.entitlements`), and `UpdateController` eligibility, channel, and relaunch rules.
@Suite struct UpdateConfigurationTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func infoPlistConfiguresSparkle2ForSandboxedHTTPSUpdates() throws {
        let plist = Self.repoRoot.appendingPathComponent("App/Info.plist")
        let info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])

        let feed = try #require(info["SUFeedURL"] as? String)
        let feedURL = try #require(URL(string: feed))
        #expect(feedURL.scheme == "https")
        #expect(feed == "https://cyr1en.github.io/Argent/appcast.xml")

        let key = try #require(info["SUPublicEDKey"] as? String)
        let decoded = try #require(Data(base64Encoded: key))
        #expect(decoded.count == 32)

        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(info["SUEnableInstallerLauncherService"] as? Bool == true)
        #expect(info["SUEnableDownloaderService"] as? Bool != true)
    }

    @Test func entitlementsIncludeLiteralSparkleMachLookupServices() throws {
        let entitlementsURL = Self.repoRoot.appendingPathComponent("App/Argent.entitlements")
        let entitlements = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: entitlementsURL), format: nil) as? [String: Any]
        )

        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(entitlements["com.apple.security.network.client"] as? Bool == true)

        let machServices = try #require(
            entitlements["com.apple.security.temporary-exception.mach-lookup.global-name"] as? [String]
        )
        #expect(machServices.contains("camera.argent.Argent-spks"))
        #expect(machServices.contains("camera.argent.Argent-spki"))
        // SwiftPM + codesign does not expand Xcode build variables.
        #expect(machServices.allSatisfy { !$0.contains("$(") })
    }

    @Test func updateChannelDefaultsAndSparkleSets() {
        #expect(UpdateChannel.defaultChannel(bundleChannel: "nightly") == .nightly)
        #expect(UpdateChannel.defaultChannel(bundleChannel: "release") == .stable)
        #expect(UpdateChannel.defaultChannel(bundleChannel: "dev") == .stable)
        #expect(UpdateChannel.defaultChannel(bundleChannel: nil) == .stable)

        #expect(UpdateChannel.stable.sparkleChannels == [])
        #expect(UpdateChannel.nightly.sparkleChannels == ["nightly"])
    }

    @Test func shouldStartUpdaterGuardsTestsLanesAndDebugBuilds() {
        let appURL = URL(fileURLWithPath: "/Applications/Argent.app")
        let validInfo: [String: Any] = [
            "SUFeedURL": "https://cyr1en.github.io/Argent/appcast.xml",
            "SUPublicEDKey": "NRTEHtCbq54jY8ZwNBw+3dlf0Y4leIkYmCVoY0SS5gQ=",
        ]

        // Release app bundle starts Sparkle.
        #expect(UpdateController.shouldStartUpdater(
            bundleURL: appURL, bundleIdentifier: "camera.argent.Argent",
            infoDictionary: validInfo, environment: [:], isDebugBuild: false, isRunningTests: false
        ))
        // Tests never start Sparkle.
        #expect(!UpdateController.shouldStartUpdater(
            bundleURL: appURL, bundleIdentifier: "camera.argent.Argent",
            infoDictionary: validInfo, environment: [:], isDebugBuild: false, isRunningTests: true
        ))
        #expect(!UpdateController.shouldStartUpdater(
            bundleURL: appURL, bundleIdentifier: "camera.argent.Argent",
            infoDictionary: validInfo, environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
            isDebugBuild: false, isRunningTests: false
        ))
        // Debug builds stay off unless explicitly opted in for local OTA testing.
        #expect(!UpdateController.shouldStartUpdater(
            bundleURL: appURL, bundleIdentifier: "camera.argent.Argent",
            infoDictionary: validInfo, environment: [:], isDebugBuild: true, isRunningTests: false
        ))
        #expect(UpdateController.shouldStartUpdater(
            bundleURL: appURL, bundleIdentifier: "camera.argent.Argent",
            infoDictionary: validInfo, environment: ["ARGENT_ENABLE_SPARKLE_DEBUG": "1"],
            isDebugBuild: true, isRunningTests: false
        ))
        // Lane/measurement apps and unbundled binaries never start Sparkle.
        #expect(!UpdateController.shouldStartUpdater(
            bundleURL: appURL, bundleIdentifier: "camera.argent.Argent.m5",
            infoDictionary: validInfo, environment: [:], isDebugBuild: false, isRunningTests: false
        ))
        #expect(!UpdateController.shouldStartUpdater(
            bundleURL: URL(fileURLWithPath: "/tmp/Argent"), bundleIdentifier: "camera.argent.Argent",
            infoDictionary: validInfo, environment: [:], isDebugBuild: false, isRunningTests: false
        ))
        // Rejects insecure or missing feed URL.
        #expect(!UpdateController.shouldStartUpdater(
            bundleURL: appURL, bundleIdentifier: "camera.argent.Argent",
            infoDictionary: ["SUFeedURL": "http://example.com/appcast.xml", "SUPublicEDKey": "abc"],
            environment: [:], isDebugBuild: false, isRunningTests: false
        ))
    }

    @MainActor @Test func channelChoicePersistsAndActiveWorkDefersRelaunch() async throws {
        let suiteName = "camera.argent.Argent.tests.updates.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = UpdateController(defaults: defaults, bundleChannel: "release")
        #expect(controller.channel == .stable)
        controller.setChannel(.nightly)
        #expect(controller.channel == .nightly)

        let reloaded = UpdateController(defaults: defaults, bundleChannel: "release")
        #expect(reloaded.channel == .nightly)

        #expect(UpdateController.activeWorkDescription(isDeveloping: true, isImporting: false, isDownloadingModels: false, isMovingFrames: false) == "developing frames")
        #expect(UpdateController.activeWorkDescription(isDeveloping: false, isImporting: true, isDownloadingModels: false, isMovingFrames: false) == "importing a roll")
        #expect(UpdateController.activeWorkDescription(isDeveloping: false, isImporting: false, isDownloadingModels: true, isMovingFrames: false) == "downloading the Subject models")
        #expect(UpdateController.activeWorkDescription(isDeveloping: false, isImporting: false, isDownloadingModels: false, isMovingFrames: false) == nil)

        @MainActor final class FlagBox { var busy = true; var installed = false }
        let state = FlagBox()
        controller.deferRelaunchUntilIdle(isBusy: { state.busy }, installHandler: { state.installed = true })
        try await Task.sleep(for: .milliseconds(50))
        #expect(!state.installed)
        state.busy = false
        for _ in 0..<20 where !state.installed {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(state.installed)
    }

    @MainActor @Test func switchingToStableDisclosesAndConfirmsStagedNightlyInstall() throws {
        let suiteName = "camera.argent.Argent.tests.updates.staged.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = UpdateController(defaults: defaults, bundleChannel: "nightly")
        #expect(controller.channel == .nightly)

        // When a nightly is already staged to install on quit, canceling keeps Nightly selected.
        @MainActor final class PromptBox { var prompted: UpdateController.PendingQuitUpdate?; var shouldConfirm = false }
        let prompt = PromptBox()
        controller.confirmChannelSwitchWithPendingNightly = { pending in
            prompt.prompted = pending
            return prompt.shouldConfirm
        }
        let stagedNightly = UpdateController.PendingQuitUpdate(
            buildVersion: "1200",
            version: "0.2.0 nightly (abc1234)",
            isNightly: true
        )
        controller.notePendingQuitUpdate(stagedNightly)

        controller.setChannel(.stable)
        #expect(prompt.prompted == stagedNightly)
        #expect(controller.channel == .nightly)
        #expect(controller.channelNote == UpdateChannel.nightly.note)

        // Confirming switches to Stable and keeps the disclosure note visible.
        prompt.shouldConfirm = true
        controller.setChannel(.stable)
        #expect(controller.channel == .stable)
        #expect(controller.channelNote.contains("0.2.0 nightly (abc1234)"))
        #expect(controller.channelNote.contains("subsequent updates"))

        // Dismissing (Install on Quit) or skipping a different build preserves the staged nightly;
        // skipping the matching build clears it so switching to Stable no longer prompts or warns.
        controller.setChannel(.nightly)
        prompt.prompted = nil
        prompt.shouldConfirm = false
        controller.noteUserUpdateChoice(.dismiss, buildVersion: "1200")
        controller.noteUserUpdateChoice(.skip, buildVersion: "1190")
        #expect(controller.pendingQuitUpdate == stagedNightly)
        controller.noteUserUpdateChoice(.skip, buildVersion: "1200")
        #expect(controller.pendingQuitUpdate == nil)
        controller.setChannel(.stable)
        #expect(prompt.prompted == nil)
        #expect(controller.channel == .stable)
        #expect(controller.channelNote == UpdateChannel.stable.note)

        // Switching when a stable update (not nightly) is staged does not prompt.
        prompt.prompted = nil
        controller.setChannel(.nightly)
        controller.notePendingQuitUpdate(UpdateController.PendingQuitUpdate(
            buildVersion: "1202",
            version: "0.2.0",
            isNightly: false
        ))
        controller.setChannel(.stable)
        #expect(prompt.prompted == nil)
        #expect(controller.channel == .stable)
        #expect(controller.channelNote == UpdateChannel.stable.note)
    }
}
