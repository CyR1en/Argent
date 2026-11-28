import ArgentCore
import ArgentRoll
import Foundation

enum PresetPresentation: Identifiable {
    case save(Frame)
    case library([Frame])

    var id: String {
        switch self {
        case .save: "save"
        case .library: "library"
        }
    }
}

extension RollModel {
    func canSavePreset(from frame: Frame) -> Bool {
        !isScanning && !isQuitting && !isRestoringManual && frameMove == nil && manualLoaded.contains(frame.url)
            && heldManualEdits[frame.url] == nil && manualErrors[frame.url] == nil && manualPreparationErrors[frame.url] == nil
    }

    func showSavePreset(from frame: Frame) {
        guard canSavePreset(from: frame) else { return }
        presetPresentation = .save(frame)
    }

    func showPresetLibrary(for frames: [Frame]) {
        presetPresentation = .library(frames)
    }

    func makePreset(from frame: Frame, name: String, includedParts: PresetParts, canisterColor: [Float]? = nil) -> UserPreset {
        let own = frameControls(frame), controls = controls(for: frame)
        return UserPreset(name: name, canisterColor: canisterColor, includedParts: includedParts,
                          baseStockID: own.stock ?? missingRollStockID ?? stock(for: frame)?.id,
                          ratedAt: controls.ratedAt, labBalance: controls.labBalance, grain: grain(for: frame),
                          halation: halation(for: frame), monochromeFilter: controls.monochromeFilter ?? MonochromeFilter.none,
                          paperGrade: controls.paperGrade ?? .normal,
                          origin: startingPoint(for: frame), adjustments: manualAdjustments(for: frame))
    }

    func presetUnavailableReason(_ preset: UserPreset) -> String? {
        if preset.includedParts.contains(.stock), let id = preset.baseStockID,
           films?.stocks.contains(where: { $0.id == id }) != true {
            return "The preset’s base stock “\(id)” is not installed."
        }
        return nil
    }

    @discardableResult
    func applyPreset(_ preset: UserPreset, to frame: Frame) -> Task<PasteReport?, Never>? {
        applyPreset(preset, to: [frame], batch: false)
    }

    @discardableResult
    func applyPresetToRoll(_ preset: UserPreset) -> Task<PasteReport?, Never>? {
        applyPreset(preset, to: roll?.frames ?? [], batch: true)
    }

    @discardableResult
    func applyPreset(_ preset: UserPreset, to frames: [Frame], batch: Bool) -> Task<PasteReport?, Never>? {
        if let reason = presetUnavailableReason(preset) {
            showClipboardNotice(ClipboardNotice(kind: .failed, text: "Could not apply preset", details: [reason]))
            return nil
        }
        let included = preset.includedParts
        var parts: AdjustmentParts = []
        if included.contains(.light) { parts.insert(.light) }
        if included.contains(.presence) { parts.insert(.presence) }
        if included.contains(.curves) { parts.insert(.curve) }
        if included.contains(.stock) { parts.insert(.stock) }
        if included.contains(.filmControls) { parts.formUnion([.frameControls, .filmSettings]) }
        let clipboard = AdjustmentsClipboard(source: URL(fileURLWithPath: "/"), sourceName: preset.name,
                                             origin: preset.origin ?? .auto, adjustments: preset.adjustments, maskNotes: .none,
                                             frameControls: FrameControls(ratedAt: preset.ratedAt, labBalance: preset.labBalance,
                                                                          stock: preset.baseStockID, grain: preset.grain,
                                                                          halation: preset.halation, monochromeFilter: preset.monochromeFilter,
                                                                          paperGrade: preset.paperGrade))
        return paste(clipboard, parts: parts, to: frames, batch: batch, includingEmptyParts: true)
    }
}
