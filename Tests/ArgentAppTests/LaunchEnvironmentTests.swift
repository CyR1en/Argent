import Foundation
import Testing

/// The app is launched with malloc's large cache off, which keeps develops to HEIC under 2 GB
/// (App/Info.plist; docs/M2-shell.md section 10). scripts/build-app.sh copies this Info.plist into the
/// bundle and checks the same key there.
@Suite struct LaunchEnvironmentTests {
    @Test func theAppIsLaunchedWithMallocsLargeCacheOff() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("App/Info.plist")
        let info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        let environment = try #require(info["LSEnvironment"] as? [String: String])
        #expect(environment["MallocLargeCache"] == "0")
    }
}
