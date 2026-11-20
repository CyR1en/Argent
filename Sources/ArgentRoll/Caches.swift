import Foundation

/// Caches' Argent folder: the contact sheet's decodes kept on disk (`LinearDiskCache.defaultFolder`) and
/// the raws' SHA-256 kept across launches (`SourceDigests.defaultFile`). The sandboxed app's is inside
/// its container; any other process's would be the user's own. It is the app's alone, as Application
/// Support's is (`ApplicationSupport`): every test keeps its caches in a temporary folder of its own, or
/// in memory, and a test process that asks for this folder stops here, before it reads or writes anything
/// in it (docs/ci-regression.md, "Test libraries").
public enum Caches {
    public static var folder: URL {
        if ProcessInfo.isRunningTests {
            fatalError("A test asked for Caches' Argent folder: give it temporary caches of its own")
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Argent", isDirectory: true)
    }
}
