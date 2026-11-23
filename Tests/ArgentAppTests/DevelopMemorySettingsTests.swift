import ArgentCore
@testable import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// The "Memory while developing" setting store and its wiring to develops: kept across launches
/// under its own key, never touching `ArgentDevelopMemoryMB`, ignoring choices a Mac no longer
/// offers, and resolved fresh at the start of every develop including Resume.
@MainActor @Suite(.serialized) struct DevelopMemorySettingsTests {
    private static func defaults() -> UserDefaults { ScratchDefaults() }

    @Test func aFirstLaunchStartsAtDefaultAndOffersChoicesForItsMac() {
        let small = DevelopMemorySettings(defaults: Self.defaults(), physicalMemory: 8 << 30, environment: [:])
        #expect(small.choice == .default)
        #expect(small.offeredChoices == [.default])
        #expect(!small.hasExtraChoices)
        #expect(small.resolvedTarget() == 1024 << 20)

        let twelve = DevelopMemorySettings(defaults: Self.defaults(), physicalMemory: 12 << 30, environment: [:])
        #expect(twelve.choice == .default)
        #expect(twelve.offeredChoices == [.default, .gb3])
        #expect(twelve.hasExtraChoices)
        #expect(twelve.resolvedTarget() == 1536 << 20)

        let sixteen = DevelopMemorySettings(defaults: Self.defaults(), physicalMemory: 16 << 30, environment: [:])
        #expect(sixteen.offeredChoices == [.default, .gb3, .gb4])
        #expect(sixteen.hasExtraChoices)
        #expect(sixteen.resolvedTarget() == 2000 << 20)

        let twentyFour = DevelopMemorySettings(defaults: Self.defaults(), physicalMemory: 24 << 30, environment: [:])
        #expect(twentyFour.offeredChoices == [.default, .gb3, .gb4, .gb6])
        #expect(twentyFour.hasExtraChoices)
        #expect(twentyFour.resolvedTarget() == 2000 << 20)
    }

    @Test func theChoiceSavesAndRestoresUnderItsOwnKeyAndNeverWritesTheMeasuringOverride() {
        let defaults = Self.defaults()
        let first = DevelopMemorySettings(defaults: defaults, physicalMemory: 24 << 30, environment: [:])
        first.setChoice(.gb4)
        #expect(first.choice == .gb4)
        #expect(defaults.string(forKey: DevelopMemorySettings.key) == DevelopBudget.Choice.gb4.rawValue)
        #expect(defaults.object(forKey: DevelopBudget.overrideDefaultsKey) == nil)
        #expect(first.resolvedTarget() == 4000 << 20)

        let second = DevelopMemorySettings(defaults: defaults, physicalMemory: 24 << 30, environment: [:])
        #expect(second.choice == .gb4)
        #expect(second.resolvedTarget() == 4000 << 20)

        second.setChoice(.gb6)
        #expect(defaults.string(forKey: DevelopMemorySettings.key) == DevelopBudget.Choice.gb6.rawValue)
        #expect(defaults.object(forKey: DevelopBudget.overrideDefaultsKey) == nil)

        second.setChoice(.default)
        let third = DevelopMemorySettings(defaults: defaults, physicalMemory: 24 << 30, environment: [:])
        #expect(third.choice == .default)
        #expect(third.resolvedTarget() == 2000 << 20)
        #expect(defaults.object(forKey: DevelopBudget.overrideDefaultsKey) == nil)
    }

    @Test func aStaleOrInvalidSavedChoiceFallsBackToDefault() {
        let defaults = Self.defaults()
        // Saved on a 24 GB Mac, then restored on smaller Macs that no longer offer it.
        let large = DevelopMemorySettings(defaults: defaults, physicalMemory: 24 << 30, environment: [:])
        large.setChoice(.gb6)
        #expect(large.choice == .gb6)

        let onSixteen = DevelopMemorySettings(defaults: defaults, physicalMemory: 16 << 30, environment: [:])
        #expect(onSixteen.choice == .default)
        #expect(onSixteen.resolvedTarget() == 2000 << 20)

        let onEight = DevelopMemorySettings(defaults: defaults, physicalMemory: 8 << 30, environment: [:])
        #expect(onEight.choice == .default)
        #expect(onEight.resolvedTarget() == 1024 << 20)

        // Programmatically setting an unoffered choice also falls back to default.
        onEight.setChoice(.gb3)
        #expect(onEight.choice == .default)
        #expect(defaults.object(forKey: DevelopBudget.overrideDefaultsKey) == nil)

        // Unknown strings and wrong types fall back to default.
        for bad: Any in ["", "8gb", "unlimited", true, false, 4000, [1, 2]] as [Any] {
            defaults.set(bad, forKey: DevelopMemorySettings.key)
            let restored = DevelopMemorySettings(defaults: defaults, physicalMemory: 24 << 30, environment: [:])
            #expect(restored.choice == .default)
            #expect(restored.resolvedTarget() == 2000 << 20)
        }
    }

    @Test func measuringOverridesTakePrecedenceOverTheSavedChoice() {
        let defaults = Self.defaults()
        let settings = DevelopMemorySettings(defaults: defaults, physicalMemory: 24 << 30, environment: [:])
        settings.setChoice(.gb4)
        #expect(settings.resolvedTarget() == 4000 << 20)

        defaults.set(3200, forKey: DevelopBudget.overrideDefaultsKey)
        #expect(settings.resolvedTarget() == 3200 << 20)

        let withEnv = DevelopMemorySettings(defaults: defaults, physicalMemory: 24 << 30,
                                            environment: [DevelopBudget.overrideEnvironmentKey: "2800"])
        #expect(withEnv.choice == .gb4)
        #expect(withEnv.resolvedTarget() == 2800 << 20)
    }

    /// Every develop resolves the budget when it starts, reusing the same `RollDeveloper`: a change
    /// between develops takes effect on the next one, a change while a develop is running leaves it
    /// alone, and Resume resolves the new choice.
    @Test func rollModelResolvesBudgetPerDevelopAndOnResume() async throws {
        try await FlagStateTests.withRoll { fixture in
            let defaults = Self.defaults()
            let memory = DevelopMemorySettings(defaults: defaults, physicalMemory: 24 << 30, environment: [:])
            memory.setChoice(.gb3)
            let model = RollModel(bookmarks: BookmarkStore(file: fixture.folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                                  stocksDirectory: fixture.stocks, decisions: AutoDecisionStore(library: fixture.library),
                                  flagStore: FlagStore(library: fixture.library), recipeLibrary: fixture.library,
                                  previewCache: fixture.folder.appendingPathComponent("Linear Previews"), digestsFile: nil,
                                  developMemory: memory)
            fixture.made.models.append(model)
            let gate = MeasurementGate()
            let frames = try await FlagStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }

            let destination = fixture.folder.appendingPathComponent("Export")
            model.developFolder.usesSubfolder = false
            model.chooseDestination(destination)

            // First develop with 3 GB: reaches the gate on the synthetic frame.
            await FlagStateTests.develop(model) { model.developFrame(frames[0]) }
            let developer = try #require(model.developer)
            #expect(developer.lastMemoryTarget == 3000 << 20)
            #expect(developer.lastGateCeiling == (3000 << 20) - DevelopBudget.margin)

            // Change to 4 GB before the next develop: the same RollDeveloper instance picks it up.
            memory.setChoice(.gb4)
            await FlagStateTests.develop(model) { model.developFrame(frames[0]) }
            #expect(model.developer === developer)
            #expect(developer.lastMemoryTarget == 4000 << 20)
            #expect(developer.lastGateCeiling == (4000 << 20) - DevelopBudget.margin)

            // Change to 6 GB while a develop is already under way and stop it: the running develop keeps 4 GB.
            model.observeDevelopJobs = { _ in
                memory.setChoice(.gb6)
                model.stopDevelop()
            }
            await FlagStateTests.develop(model) { model.developFrame(frames[0]) }
            let stopped = try #require(model.lastDevelop)
            #expect(stopped.wasStopped)
            #expect(developer.lastMemoryTarget == 4000 << 20)

            // Resume resolves the new 6 GB choice when it starts, still reusing the same RollDeveloper.
            model.observeDevelopJobs = nil
            await FlagStateTests.develop(model) { model.develop(resuming: stopped) }
            #expect(model.developer === developer)
            #expect(developer.lastMemoryTarget == 6000 << 20)
            #expect(developer.lastGateCeiling == (6000 << 20) - DevelopBudget.margin)
            #expect(defaults.object(forKey: DevelopBudget.overrideDefaultsKey) == nil)
        }
    }
}
