import Foundation
import Testing
@testable import ArgentCore

/// What the base commit fixes for every Presence package: the one list, the versions, and that identity is today's value.
@Suite struct PresenceTests {
    @Test func theCurrentVersionHasConstants() throws {
        #expect(PresenceConstants.named(Presence.currentVersion) != nil)
        #expect(Set(PresenceConstants.all.map(\.version)).count == PresenceConstants.all.count)
    }

    @Test func theLightTabsSlidersComeFromTheTwoLists() {
        #expect(ManualAdjustments.Slider.allCases.count == ManualAdjustments.Control.allCases.count + Presence.Control.allCases.count + LensSettings.Control.allCases.count)
        #expect(Presence.Control.allCases.map(\.flag) == ["--texture", "--clarity", "--dehaze", "--vibrance", "--saturation"])
        for slider in ManualAdjustments.Slider.allCases { #expect(ManualAdjustments.Slider(name: slider.name) == slider) }
    }

    /// The inspector's rows, the spike's flags, the recipe's keys and the drive hook's names all come from `Presence.Control.allCases`.
    @Test func theControlListIsTheOneSource() throws {
        let names = Presence.Control.allCases.map(\.rawValue)
        #expect(names == ["texture", "clarity", "dehaze", "vibrance", "saturation"])
        #expect(ManualAdjustments.Slider.allCases.dropLast(LensSettings.Control.allCases.count).suffix(names.count).map(\.name) == names, "the rows after Light's six")
        for control in Presence.Control.allCases {
            #expect(Presence.Control(flag: control.flag) == control && Presence.Control(rawValue: control.rawValue) == control)
            #expect(ManualAdjustments.Slider(name: control.rawValue) == .presence(control))
        }
        #expect(Presence.Control(flag: "--exposure-ev") == nil && Presence.Control(flag: "clarity") == nil)
        let values = Dictionary(uniqueKeysWithValues: Presence.Control.allCases.enumerated().map { ($0.element, Float($0.offset * 10 - 20)) })
        let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(try Presence(values))) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == Set(names + ["version"]), "the recipe's keys")
    }

    @Test func aSliderStepMovesPresenceAndNothingElse() throws {
        let moved = try ManualAdjustments.identity.setting(.presence(.clarity), to: 40)
        #expect(moved.presence.clarity == 40 && moved.exposureEV == 0 && !moved.isIdentity)
        #expect(try moved.setting(.presence(.clarity), to: -0).isIdentity)
        #expect(throws: ManualDevelopmentError.self) { try moved.setting(.presence(.dehaze), to: 101) }
        #expect(moved.clearing(.light).presence == moved.presence)
    }

    @Test func identityIsWrittenAsBeforePresenceExisted() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let text = String(decoding: try encoder.encode(ManualAdjustments.identity), as: UTF8.self)
        #expect(!text.contains("presence"))
    }

    @Test func presenceRoundTripsThroughTheRecipeForm() throws {
        let values = try ManualAdjustments(contrast: 10, presence: Presence([.texture: -30, .saturation: 55]))
        let decoded = try JSONDecoder().decode(ManualAdjustments.self, from: try JSONEncoder().encode(values))
        #expect(decoded == values && decoded.presence.version == Presence.currentVersion)
    }

    @Test func thePartsAreOneDecisionForTheLaneThePasteAndTheResets() throws {
        let source = try ManualAdjustments(shadows: 20, presence: Presence([.clarity: 30]))
        let destination = try ManualAdjustments(exposureEV: 1, curves: ToneCurves(tone: ToneCurves.Preset.softContrast.curve))
        #expect(source.heldParts == [.light, .presence])
        let lane = destination.setting(.sliders, from: source)
        #expect(lane.shadows == 20 && lane.exposureEV == 0 && lane.presence == source.presence && lane.curves == destination.curves)
        #expect(destination.setting(.presence, from: source).exposureEV == 1)
        let reset = source.clearing(.light)
        #expect(reset.shadows == 0 && reset.presence == source.presence)
        #expect(source.clearing(.sliders).isIdentity)
    }

    /// What the spike prints for a piece not built yet, from a render's error and from a setting's, names the piece, its package and
    /// this plan.
    @Test func aPieceNotBuiltSaysWhoseItIs() {
        let error: any Error = PresenceError.notBuilt("Texture's band (PresenceAnalysisBuilder.texture)", package: "B")
        let text = "Texture's band (PresenceAnalysisBuilder.texture) is not built yet: package B of docs/presence-plan.md builds it."
        #expect("\(error)" == text && error.localizedDescription == text)
    }
}

@Suite struct PresenceOnAMaskTests {
    private static let gradient = MaskComponent(shape: .linear(.init(full: MaskPoint(x: 0.5, y: 0.2), zero: MaskPoint(x: 0.5, y: 0.6))))

    @Test func aMaskHoldingPresenceIsRefused() throws {
        let presence = try ManualAdjustments(exposureEV: 1, presence: Presence([.texture: 20]))
        let mask = Mask(components: [Self.gradient], adjustments: presence)
        #expect(throws: MaskError.invalid("a mask's own adjustments hold no masks, no curves, no Presence and no Lens settings")) { try MaskSet(masks: [mask]) }
        #expect(try MaskSet(masks: [Mask(components: [Self.gradient], adjustments: presence.settingPresence(.identity))]).masks.count == 1)
    }

    /// The same refusal on the way in from a file, so a recipe cannot carry Presence into a mask that a build would then ignore.
    @Test func aRecordedMaskHoldingPresenceIsRefused() throws {
        let set = try MaskSet(masks: [Mask(components: [Self.gradient], adjustments: try ManualAdjustments(exposureEV: 1))])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let text = String(decoding: try encoder.encode(set), as: UTF8.self)
        let presence = String(decoding: try encoder.encode(try Presence([.texture: 20])), as: UTF8.self)
        let changed = text.replacingOccurrences(of: "\"exposureEV\":1", with: "\"exposureEV\":1,\"presence\":\(presence)")
        #expect(changed != text)
        #expect(throws: MaskError.invalid("a mask's own adjustments hold no masks, no curves, no Presence and no Lens settings")) {
            try JSONDecoder().decode(MaskSet.self, from: Data(changed.utf8))
        }
    }
}
