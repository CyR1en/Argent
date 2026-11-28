import AppKit
import ArgentCore
import ArgentRoll
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let argentPreset = UTType(exportedAs: "camera.argent.preset", conformingTo: .json)
}

extension UserPreset {
    var tagTint: Stock.CanisterColor? {
        guard let rgb = canisterColor, rgb.count == 3 else { return nil }
        return .init(red: rgb[0], green: rgb[1], blue: rgb[2])
    }
}

enum PresetPresentation: Identifiable {
    case save(Frame)
    case library([Frame], selection: UUID?, managing: Bool)
    case builder(StockBuilderPresentation)

    var id: String {
        switch self {
        case .save: "save"
        case .library: "library"
        case .builder(let presentation): presentation.id.uuidString
        }
    }
}

extension RollModel {
    var canApplyLookPreset: Bool {
        !isScanning && !isQuitting && !isRestoringManual && frameMove == nil
    }

    var canShowPresetLibrary: Bool { !isSheetShown && !isQuitting }

    func reloadLookPresets() {
        if let result = try? presetStore.loadAll() { lookPresets = result.presets }
    }

    func isPresetFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == PresetStore.fileExtension
    }

    @discardableResult
    func openPreset(_ url: URL) -> Bool {
        guard canShowPresetLibrary, isPresetFile(url) else { return false }
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let preset = try presetStore.importPreset(from: url)
            reloadLookPresets()
            showPresetLibrary(for: shownFrame.map { [$0] } ?? selectedFrames, selecting: preset.id)
        } catch {
            message = "Could not import the preset: \(error.localizedDescription)"
        }
        return true
    }

    func choosePresetImport() {
        guard canShowPresetLibrary else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.argentPreset]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.openPreset(url)
        }
    }

    func choosePresetExport(_ preset: UserPreset, onError: (@MainActor (Error) -> Void)? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.argentPreset]
        panel.nameFieldStringValue = preset.name.replacingOccurrences(of: "/", with: "-") + "." + PresetStore.fileExtension
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                try self.presetStore.exportPreset(id: preset.id, to: url)
            } catch {
                if let onError { onError(error) }
                else { self.message = "Could not export the preset: \(error.localizedDescription)" }
            }
        }
    }

    func canSavePreset(from frame: Frame) -> Bool {
        canApplyLookPreset && manualLoaded.contains(frame.url)
            && heldManualEdits[frame.url] == nil && manualErrors[frame.url] == nil && manualPreparationErrors[frame.url] == nil
    }

    func showSavePreset(from frame: Frame) {
        guard !isSheetShown, canSavePreset(from: frame) else { return }
        presetPresentation = .save(frame)
    }

    func showPresetLibrary(for frames: [Frame], selecting id: UUID? = nil, managing: Bool = false) {
        guard canShowPresetLibrary else { return }
        presetPresentation = .library(frames, selection: id, managing: managing)
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
           !installedStocks.contains(where: { $0.id == id }) {
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
