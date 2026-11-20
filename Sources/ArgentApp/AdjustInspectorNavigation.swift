import ArgentCore
import ArgentRoll
import Foundation

enum AdjustInspectorFilter: Hashable {
    case allTools, edited
}

struct AdjustInspectorNavigation: Equatable {
    private(set) var preferredSection: AdjustInspectorTab
    private(set) var filter = AdjustInspectorFilter.allTools
    private var isExpanded = true
    private(set) var destination: InspectorDestination?

    init(preferredSection: AdjustInspectorTab = .light) {
        self.preferredSection = preferredSection
    }

    var openSection: AdjustInspectorTab? { filter == .allTools && isExpanded ? preferredSection : nil }

    mutating func select(_ filter: AdjustInspectorFilter) {
        self.filter = filter
        destination = nil
    }

    mutating func open(_ section: AdjustInspectorTab) {
        destination = nil
        preferredSection = section
        isExpanded = true
        filter = .allTools
    }

    mutating func reveal(_ item: InspectorDestination) {
        open(item.section)
        destination = item
    }

    mutating func clearDestination() {
        destination = nil
    }

    mutating func toggle(_ section: AdjustInspectorTab) {
        destination = nil
        if openSection == section { isExpanded = false } else { open(section) }
    }
}

extension RollModel {
    func setInspectorFilter(_ filter: AdjustInspectorFilter, for frame: Frame) {
        guard inspectorNavigation.filter != filter else { return }
        endLightAdjusting(for: frame)
        inspectorNavigation.select(filter)
    }

    func toggleInspectorSection(_ section: AdjustInspectorTab, for frame: Frame) {
        endLightAdjusting(for: frame)
        inspectorNavigation.toggle(section)
    }
}

/// One item per changed slider or distortion switch, shaped curve channel, mask and saved removal.
struct InspectorEdits {
    let light: [ManualAdjustments.Slider]
    let curves: [ToneCurves.Channel]
    let lens: [LensSettings.Control]
    let distortionChanged: Bool
    let masks: [Mask]
    let removals: [Removal]

    init(_ values: ManualAdjustments) {
        light = ManualAdjustments.Control.allCases.map(ManualAdjustments.Slider.light)
            .filter { values.value(for: $0) != 0 }
            + Presence.Control.allCases.map(ManualAdjustments.Slider.presence)
            .filter { values.value(for: $0) != 0 }
        curves = ToneCurves.Channel.allCases.filter { !values.curves.curve(for: $0).isIdentity }
        lens = LensSettings.Control.allCases.filter { values.lens.value(for: $0) != $0.defaultValue }
        distortionChanged = values.lens.distortion.isOn != LensSettings.default.distortion.isOn
        masks = values.masks.masks
        removals = values.removals
    }

    var count: Int { AdjustInspectorTab.allCases.reduce(0) { $0 + count(in: $1) } }

    func count(in section: AdjustInspectorTab) -> Int {
        switch section {
        case .light: light.count
        case .curve: curves.count
        case .masks: masks.count
        case .lens: lens.count + (distortionChanged ? 1 : 0)
        case .remove: removals.count
        }
    }

    static func editCount(_ count: Int) -> String { count == 1 ? "1 edit" : "\(count) edits" }

    func summary(for section: AdjustInspectorTab, hasLensProfile: Bool?) -> String {
        let count = count(in: section)
        switch section {
        case .masks: return count == 0 ? "No masks" : count == 1 ? "1 mask" : "\(count) masks"
        case .remove: return count == 0 ? "No removals" : RemoveCopy.count(count)
        case .light: return count == 0 ? "At starting point" : Self.editCount(count)
        case .curve: return count == 0 ? "Linear" : count == 1 ? "\(curves[0].title) shaped" : "\(count) channels"
        case .lens:
            if count > 0 { return Self.editCount(count) }
            return hasLensProfile.map { $0 ? "From file" : "No profile" } ?? ""
        }
    }
}

enum InspectorDestination: Hashable {
    case curve(ToneCurves.Channel), mask(UUID), removal(UUID)

    var section: AdjustInspectorTab {
        switch self {
        case .curve: .curve
        case .mask: .masks
        case .removal: .remove
        }
    }

    var channel: ToneCurves.Channel? {
        if case .curve(let channel) = self { return channel }
        return nil
    }

    var removal: UUID? {
        if case .removal(let id) = self { return id }
        return nil
    }
}

extension RollModel {
    func inspectorEdits(for frame: Frame) -> InspectorEdits {
        let values = manualAdjustments(for: frame)
        guard let printedLight, printedLight.frame == frame.url else { return InspectorEdits(values) }
        return InspectorEdits(values.setting(.sliders, from: printedLight.values))
    }
}
