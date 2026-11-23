import ArgentRoll
import Foundation
import Observation

/// The owner's choice of how much memory a develop may hold, kept across launches (`DevelopBudget`).
/// Stored under its own UserDefaults key, never `ArgentDevelopMemoryMB`, which is the measuring override.
@MainActor @Observable final class DevelopMemorySettings {
    static let shared = DevelopMemorySettings(defaults: .standard)
    static let key = "developMemory"

    /// The choices offered on this Mac, always starting with `.default`.
    let offeredChoices: [DevelopBudget.Choice]
    /// This Mac's physical memory, in bytes, injected so tests can stand in other Macs.
    let physicalMemory: UInt64
    /// The choice in effect on this Mac; a saved choice this Mac no longer offers falls back to `.default`.
    private(set) var choice: DevelopBudget.Choice

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environmentOverride: () -> String?
    @ObservationIgnored private var choiceListeners: [@MainActor () -> Bool] = []

    /// Whether this Mac offers any choice beyond the default.
    var hasExtraChoices: Bool { offeredChoices.count > 1 }
    /// What the default rule gives this Mac, in bytes, whatever is chosen or overridden: the amount the Settings row shows
    /// for its default.
    var defaultTarget: Int { DevelopBudget.resolve(choice: .default, physicalMemory: physicalMemory) }

    init(defaults: UserDefaults,
         physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
         environment: [String: String]? = nil) {
        self.defaults = defaults
        self.physicalMemory = physicalMemory
        self.offeredChoices = DevelopBudget.choices(physicalMemory: physicalMemory)
        self.environmentOverride = environment.map { env in { env[DevelopBudget.overrideEnvironmentKey] } }
            ?? { ProcessInfo.processInfo.environment[DevelopBudget.overrideEnvironmentKey] }
        let saved = (defaults.object(forKey: Self.key) as? String).flatMap(DevelopBudget.Choice.init(rawValue:)) ?? .default
        self.choice = DevelopBudget.effectiveChoice(saved, physicalMemory: physicalMemory)
    }

    /// Saves `choice` when this Mac offers it, falling back to `.default` otherwise.
    func setChoice(_ choice: DevelopBudget.Choice) {
        let effective = DevelopBudget.effectiveChoice(choice, physicalMemory: physicalMemory)
        let changed = self.choice != effective
        self.choice = effective
        defaults.set(effective.rawValue, forKey: Self.key)
        if changed { choiceListeners = choiceListeners.filter { $0() } }
    }

    /// Calls `listener` synchronously whenever `choice` changes, dropping it once it returns `false`.
    func onChoiceChange(_ listener: @escaping @MainActor () -> Bool) {
        choiceListeners.append(listener)
    }

    /// The develop memory target in bytes, resolved at the moment a develop starts:
    /// `ARGENT_DEVELOP_MEMORY_MB`, then `ArgentDevelopMemoryMB`, then the user's choice, then the default rule.
    func resolvedTarget() -> Int {
        DevelopBudget.resolve(choice: choice,
                              environmentOverride: environmentOverride(),
                              defaultsOverride: defaults.object(forKey: DevelopBudget.overrideDefaultsKey),
                              physicalMemory: physicalMemory)
    }

    /// RAW 9's develop tile size for the currently resolved memory target (`DevelopBudget.learnedDecodeTile(forMemoryTarget:)`).
    func resolvedLearnedDecodeTile() -> Int {
        DevelopBudget.learnedDecodeTile(forMemoryTarget: resolvedTarget())
    }
}
