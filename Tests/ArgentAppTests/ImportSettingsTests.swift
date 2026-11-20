import ArgentCore
import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

@MainActor @Suite struct ImportSettingsTests {
    private static func defaults() -> UserDefaults { ScratchDefaults() }

    @Test func aFreshStoreGivesTheCullsDefaults() {
        let settings = ImportSettings(defaults: Self.defaults())
        #expect(settings.cull == CullSettings())
        #expect(settings.destination == .pictures)
        #expect(BurstGapChoice(settings.cull) == .normal)
        #expect(SoftFocusChoice(settings.cull) == .normal)
        #expect(SameMomentChoice(settings.cull) == .normal)
    }

    @Test func aSavedChangeReadsBack() {
        let defaults = Self.defaults()
        var settings = ImportSettings(defaults: defaults)
        SoftFocusChoice.strict.apply(to: &settings.cull)
        settings.cull.burstGap = BurstGapChoice.long.seconds
        settings.cull.sameMomentWithin = SameMomentChoice.wide.within
        settings.cull.leavesEyesClosed = false
        settings.destination = .folder(URL(fileURLWithPath: "/Volumes/Archive/Keepers", isDirectory: true))
        settings.save(to: defaults)

        let read = ImportSettings(defaults: defaults)
        #expect(read == settings)
        #expect(SoftFocusChoice(read.cull) == .strict)
        #expect(BurstGapChoice(read.cull) == .long)
        #expect(SameMomentChoice(read.cull) == .wide)
    }

    @Test func unreadableSettingsGiveTheDefaults() {
        let defaults = Self.defaults()
        defaults.set(Data("{\"cull\": {\"burstGap\": ".utf8), forKey: ImportSettings.key)
        #expect(ImportSettings(defaults: defaults) == ImportSettings())
        defaults.set("not data", forKey: ImportSettings.key)
        #expect(ImportSettings(defaults: defaults) == ImportSettings())
    }

    @Test(arguments: [(SoftFocusChoice.strict, 0.30, 0.34), (.normal, 0.26, 0.30), (.loose, 0.20, 0.24)])
    func softFocusSetsBothFaceThresholds(_ choice: SoftFocusChoice, softFocusBelow: Double, eyesClosedBelow: Double) {
        var cull = CullSettings()
        choice.apply(to: &cull)
        #expect(cull.softFocusBelow == softFocusBelow)
        #expect(cull.eyesClosedBelow == eyesClosedBelow)
        #expect(SoftFocusChoice(cull) == choice)
        var others = cull
        others.softFocusBelow = CullSettings().softFocusBelow
        others.eyesClosedBelow = CullSettings().eyesClosedBelow
        #expect(others == CullSettings())
    }

    @Test(arguments: [(SameMomentChoice.narrow, 0.15), (.normal, 0.25), (.wide, 0.35)])
    func sameMomentSetsItsDistance(_ choice: SameMomentChoice, within: Double) {
        #expect(choice.within == within)
        var cull = CullSettings()
        cull.sameMomentWithin = choice.within
        #expect(SameMomentChoice(cull) == choice)
    }

    @Test(arguments: [(BurstGapChoice.short, 0.2), (.normal, 0.35), (.long, 0.6)])
    func burstGapSetsItsSeconds(_ choice: BurstGapChoice, seconds: TimeInterval) {
        #expect(choice.seconds == seconds)
        var cull = CullSettings()
        cull.burstGap = choice.seconds
        #expect(BurstGapChoice(cull) == choice)
    }

    @Test func aSettingMissingFromTheStoreTakesItsDefaultAndKeepsTheRest() throws {
        let defaults = Self.defaults()
        var settings = ImportSettings()
        settings.cull.burstGap = BurstGapChoice.long.seconds
        settings.cull.leavesEyesClosed = false
        settings.destination = .folder(URL(fileURLWithPath: "/Volumes/Archive/Keepers", isDirectory: true))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        var cull = try #require(object["cull"] as? [String: Any])
        cull["failedBelow"] = nil
        object["cull"] = cull
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: ImportSettings.key)

        #expect(ImportSettings(defaults: defaults) == settings)
    }

    @Test func thresholdsNoChoiceSetsSelectNone() {
        let cull = CullSettings(burstGap: 0.4, softFocusBelow: 0.26, eyesClosedBelow: 0.32, sameMomentWithin: 0.2)
        #expect(BurstGapChoice(cull) == nil)
        #expect(SoftFocusChoice(cull) == nil)
        #expect(SameMomentChoice(cull) == nil)
    }

    @Test func aChosenDestinationIsKeptForTheNextLaunch() throws {
        let saved = UserDefaults.standard.data(forKey: ImportSettings.key)
        defer { UserDefaults.standard.set(saved, forKey: ImportSettings.key) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("import-settings-\(UUID().uuidString)", isDirectory: true)
        let destination = folder.appendingPathComponent("Keepers", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("bookmarks.json")

        let model = RollModel(bookmarks: BookmarkStore(file: file, securityScoped: false), stocksDirectory: folder,
                              decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        model.setImportDestination(.folder(destination))
        #expect(ImportSettings(defaults: .standard).destination == .folder(destination))
        #expect(BookmarkStore(file: file, securityScoped: false).destination(atPath: destination.path)?.standardizedFileURL
            == destination.standardizedFileURL)

        model.setImportDestination(.pictures)
        #expect(ImportSettings(defaults: .standard).destination == .pictures)
    }
}
