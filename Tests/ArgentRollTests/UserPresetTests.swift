import ArgentCore
import ArgentRoll
import Foundation
import Testing

@Suite struct UserPresetTests {
    @Test func retainsMetadataAndVersionedValuesButNeverSpatialEdits() throws {
        let mask = Mask(components: [MaskComponent(shape: .linear(.init(full: .init(x: 0.5, y: 0), zero: .init(x: 0.5, y: 0.5))))])
        let patch = try PatchRef(id: #require(PatchID(hex: String(repeating: "ab", count: 32))), width: 512, height: 512)
        let values = try ManualAdjustments(exposureEV: 1.25, masks: MaskSet(masks: [mask]), presence: Presence([.clarity: 10]),
                                           lens: LensSettings.default.setting(.distortion, to: 80))
            .settingRemovals([Removal(patch: patch)])
        let preset = UserPreset(name: "September", canisterColor: [0.25, 0.5, 1], baseStockID: "user-september",
                                ratedAt: .oneStopUnder, labBalance: .warm, grain: .off, halation: 150,
                                monochromeFilter: .yellow, paperGrade: .hard, origin: .original, adjustments: values)
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(UserPreset.self, from: data)
        #expect(decoded == preset)
        #expect(decoded.version == UserPreset.currentVersion)
        #expect(decoded.adjustments.exposureEV == 1.25)
        #expect(decoded.adjustments.presence == values.presence)
        #expect(decoded.adjustments.masks.isEmpty && decoded.adjustments.removals.isEmpty && decoded.adjustments.lens == .default)
        #expect(decoded.createdAt == decoded.updatedAt)

        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["adjustments"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(values))
        let imported = try JSONDecoder().decode(UserPreset.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(imported == preset, "a file containing spatial data cannot introduce it into the preset")
    }

    @Test func omittedPartsAreNotCapturedAndFutureVersionsAreRejected() throws {
        var preset = UserPreset(name: "Grain only", includedParts: [.filmControls], baseStockID: "toy", grain: .off,
                                origin: .original, adjustments: try ManualAdjustments(exposureEV: 1))
        #expect(preset.includedParts == [.filmControls])
        #expect(preset.baseStockID == nil && preset.origin == nil && preset.adjustments.isIdentity && preset.grain == .off)
        preset.version += 1
        let future = try JSONEncoder().encode(preset)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(UserPreset.self, from: future) }
    }
}
