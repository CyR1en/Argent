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

        var busy = true
        var installed = false
        controller.deferRelaunchUntilIdle(isBusy: { busy }, installHandler: { installed = true })
        try await Task.sleep(for: .milliseconds(50))
        #expect(!installed)
        busy = false
        for _ in 0..<20 where !installed {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(installed)
    }
}
