import Foundation
import Testing

/// Defaults of a test's own, kept in memory: what a test writes is read back from the same object, as `UserDefaults`
/// gives it, and nothing reaches the preferences on disk. A suite under a name of its own did: clearing one
/// (`removePersistentDomain`) empties its file in ~/Library/Preferences and leaves it there, a suite never cleared
/// leaves it as written, and the file cannot be removed after, as it is written some time later. So the tests that
/// made a suite at each run left a file at each run, 3,877 of them by 2026-11-16.
///
/// The typed readers and writers (`bool(forKey:)`, `set(_:forKey:)` of a `Bool`, and the rest) go through the three
/// overridden here. The suite it is made over is never written, so it has no file; it only keeps what is not
/// overridden away from the defaults of the test's own process.
final class ScratchDefaults: UserDefaults {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: "argent-tests-scratch")! }

    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func removeObject(forKey key: String) { lock.withLock { values[key] = nil } }
}

@Suite struct ScratchDefaultsTests {
    @Test func theyKeepWhatIsWrittenAsUserDefaultsGivesIt() {
        let defaults: UserDefaults = ScratchDefaults()
        #expect(defaults.object(forKey: "word") == nil && defaults.string(forKey: "word") == nil && !defaults.bool(forKey: "flag"))
        defaults.set("kept", forKey: "word")
        defaults.set(true, forKey: "flag")
        defaults.set(7, forKey: "count")
        defaults.set(Data([1, 2]), forKey: "data")
        defaults.set(["size": 2.5], forKey: "sizes")
        #expect(defaults.string(forKey: "word") == "kept" && defaults.bool(forKey: "flag") && defaults.integer(forKey: "count") == 7)
        #expect(defaults.data(forKey: "data") == Data([1, 2]))
        #expect(defaults.dictionary(forKey: "sizes") as? [String: Double] == ["size": 2.5])
        defaults.removeObject(forKey: "word")
        defaults.set(nil, forKey: "count")
        #expect(defaults.string(forKey: "word") == nil && defaults.object(forKey: "count") == nil)
    }

    @Test func eachIsItsOwnAndNoneReachesTheDisk() {
        let one = ScratchDefaults(), other = ScratchDefaults()
        one.set("mine", forKey: "word")
        #expect(other.string(forKey: "word") == nil)
        #expect(UserDefaults(suiteName: "argent-tests-scratch")?.string(forKey: "word") == nil)
    }
}
