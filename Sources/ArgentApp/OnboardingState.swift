import Foundation
import Observation

/// The steps of the first-launch onboarding flow, in order.
enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome
    case appearance
    case preferences
    case maskModels

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .appearance: "Appearance"
        case .preferences: "Preferences"
        case .maskModels: "Mask models"
        }
    }

    var symbol: String {
        switch self {
        case .welcome: "sparkles"
        case .appearance: "paintpalette"
        case .preferences: "slider.horizontal.3"
        case .maskModels: "square.dashed"
        }
    }

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

/// First-launch onboarding state and persistence.
///
/// Never auto-presents during `RollModel.init()`, so unit tests and measurement lanes open directly on the
/// workspace. `AppDelegate.attach(_:)` calls `presentOnLaunchIfNeeded(...)` once the main window appears.
@MainActor @Observable
final class OnboardingController {
    nonisolated static let completedKey = "hasCompletedOnboarding"

    private(set) var hasCompleted: Bool
    private(set) var isPresented = false
    var step: OnboardingStep = .welcome
    /// Direction of the last step change (+1 forward, -1 backward), for subtle horizontal slide motion.
    private(set) var navigationDirection: Int = 1
    /// Whether the Mask models step is showing the full bundled licence texts instead of the summary.
    var showsMaskModelLicences = false

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasCompleted = Self.savedBool(Self.completedKey, in: defaults)
    }

    private static func savedBool(_ key: String, in defaults: UserDefaults) -> Bool {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    /// Pure eligibility check for automatic first-launch presentation, separated for unit tests.
    nonisolated static func shouldPresentOnLaunch(
        hasCompleted: Bool,
        hasPendingURLs: Bool,
        bundleIdentifier: String?,
        environment: [String: String],
        isRunningTests: Bool
    ) -> Bool {
        if isRunningTests || environment["XCTestConfigurationFilePath"] != nil { return false }
        if environment["ARGENT_SKIP_ONBOARDING"] == "1" { return false }
        if environment["ARGENT_SHOW_ONBOARDING"] == "1" { return true }
        // Measurement and lane builds run under distinct bundle identifiers (e.g. camera.argent.Argent.m5).
        if let bundleIdentifier, bundleIdentifier != UpdateController.expectedBundleIdentifier { return false }
        if hasPendingURLs { return false }
        return !hasCompleted
    }

    func presentOnLaunchIfNeeded(
        hasPendingURLs: Bool,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isRunningTests: Bool = NSClassFromString("XCTestCase") != nil
    ) {
        guard Self.shouldPresentOnLaunch(
            hasCompleted: hasCompleted,
            hasPendingURLs: hasPendingURLs,
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            isRunningTests: isRunningTests
        ) else { return }
        present(startingAt: .welcome)
    }

    func present(startingAt step: OnboardingStep = .welcome) {
        navigationDirection = 1
        self.step = step
        showsMaskModelLicences = false
        isPresented = true
    }

    func advance() {
        showsMaskModelLicences = false
        if let next = step.next {
            navigationDirection = 1
            step = next
        } else {
            complete()
        }
    }

    func goBack() {
        showsMaskModelLicences = false
        if let previous = step.previous {
            navigationDirection = -1
            step = previous
        }
    }

    func goTo(_ target: OnboardingStep) {
        guard target != step else { return }
        showsMaskModelLicences = false
        navigationDirection = target.rawValue > step.rawValue ? 1 : -1
        step = target
    }

    /// Marks onboarding completed and dismisses it; safe to call repeatedly.
    func complete() {
        showsMaskModelLicences = false
        isPresented = false
        if !hasCompleted {
            hasCompleted = true
            defaults.set(true, forKey: Self.completedKey)
        }
    }

    /// Clears the persisted completion flag (for Help / debug testing).
    func resetCompletion() {
        hasCompleted = false
        defaults.removeObject(forKey: Self.completedKey)
    }
}
