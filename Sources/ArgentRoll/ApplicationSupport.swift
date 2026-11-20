import Darwin
import Foundation

/// Application Support's Argent folder: the app's recipe library (`RecipeStore.defaultLibrary`), with
/// the Auto decisions and flags kept in it, and its bookmarks (`BookmarkStore.defaultFile`). The
/// sandboxed app's is inside its container; any other process's would be the user's own. It is the
/// app's alone: every test keeps these in a temporary library of its own, and a test process that asks
/// for this folder stops here, before it reads or writes anything in it (docs/ci-regression.md, "Test
/// libraries").
public enum ApplicationSupport {
    public static var folder: URL {
        if ProcessInfo.isRunningTests {
            fatalError("A test asked for Application Support's Argent folder: give it a temporary library of its own")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Argent", isDirectory: true)
    }
}

extension ProcessInfo {
    /// Whether this process runs tests: XCTest or Swift Testing is loaded, as each test bundle links
    /// both. The app links neither, so there this is false and what reads it does as it always did.
    /// `ApplicationSupportTests` checks that it is true under test, so the guards that read it cannot
    /// lapse unseen.
    public static let isRunningTests = NSClassFromString("XCTestCase") != nil
        // RTLD_DEFAULT, which Swift does not import.
        || dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swt_abiv0_getEntryPoint") != nil
}
