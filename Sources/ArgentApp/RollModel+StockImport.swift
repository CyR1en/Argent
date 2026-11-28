import AppKit
import ArgentCore
import ArgentRoll
import UniformTypeIdentifiers

extension UTType {
    static let argentStock = UTType(exportedAs: "camera.argent.stock", conformingTo: .zip)
    static let cubeLUT = UTType(importedAs: "camera.argent.cube-lut", conformingTo: .plainText)
}

struct StockImportSource: Identifiable {
    let url: URL
    var id: URL { url }
    var isCube: Bool { url.pathExtension.lowercased() == "cube" }

    init?(url: URL) {
        self.url = url
        if isCube || url.pathExtension.lowercased() == "argentstock" { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              FileManager.default.fileExists(atPath: url.appendingPathComponent(Stock.manifestName).path) else { return nil }
    }
}

extension RollModel {
    func chooseStockImport() {
        guard !isSheetShown, presetPresentation == nil, userStockStore != nil, !isQuitting else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.argentStock, .cubeLUT, UTType(filenameExtension: "cube") ?? .cubeLUT]
        panel.message = "Choose a .cube LUT, an .argentstock archive, or a stock folder."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let source = StockImportSource(url: url) else {
                self.message = "Choose a .cube, an .argentstock, or a folder containing stock.json."
                return
            }
            self.presentStockImport(source)
        }
    }

    @discardableResult
    func presentStockImport(_ source: StockImportSource) -> Bool {
        guard stockImportSource == nil, presetPresentation == nil, userStockStore != nil, !isQuitting else { return false }
        stockImportSource = source
        return true
    }

    func chooseStockExport() {
        guard !isSheetShown, presetPresentation == nil, !isQuitting, let store = userStockStore,
              let stock = shownStock, stock.isUserStock else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.argentStock]
        panel.nameFieldStringValue = stock.displayName.replacingOccurrences(of: "/", with: "-") + ".argentstock"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await Task.detached {
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                        try store.exportStock(id: stock.id, to: url)
                    }.value
                } catch {
                    self.message = "Could not export the stock: \(error.localizedDescription)"
                }
            }
        }
    }
}
