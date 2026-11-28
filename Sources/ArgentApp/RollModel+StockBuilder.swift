import ArgentCore
import ArgentRoll
import Foundation

struct StockBuilderPresentation: Identifiable {
    let id = UUID()
    let stockID: String?
    let name: String
    let spec: CustomStockSpec
    let frame: Frame?

    init(stockID: String? = nil, name: String = "", spec: CustomStockSpec = .init(), frame: Frame?) {
        self.stockID = stockID
        self.name = name
        self.spec = spec
        self.frame = frame
    }
}

extension RollModel {
    var canShowStockBuilder: Bool {
        !isSheetShown && userStockStore != nil && !isQuitting
    }

    func showStockBuilder(from stock: Stock? = nil) {
        guard canShowStockBuilder else { return }
        stockBuilder = .init(name: stock.map { "\($0.displayName) Custom" } ?? "",
                             spec: stock.map(CustomStockSpec.init(derivedFrom:)) ?? .init(),
                             frame: shownFrame ?? selectedFrame)
    }

    func editCustomStock(_ stock: Stock) {
        guard canShowStockBuilder else { return }
        do { stockBuilder = try stockRecipe(for: stock) }
        catch { message = "Could not open the stock recipe: \(error)" }
    }

    func stockRecipe(for stock: Stock) throws -> StockBuilderPresentation {
        guard stock.isUserStock, stock.hasSpec, let data = userStockStore?.specData(for: stock.id) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let spec = try JSONDecoder().decode(CustomStockSpec.self, from: data)
        return .init(stockID: stock.id, name: stock.displayName, spec: spec, frame: shownFrame ?? selectedFrame)
    }

    func canBakeFrameAsStock(_ frame: Frame) -> Bool {
        canShowStockBuilder && canMakeBakedStock(from: frame)
    }

    func bakeFrameAsStock(_ frame: Frame) {
        guard canBakeFrameAsStock(frame) else { return }
        do {
            stockBuilder = try bakedStock(from: frame)
        } catch {
            message = "Could not bake this frame: \(error)"
        }
    }

    func canMakeBakedStock(from frame: Frame) -> Bool {
        userStockStore != nil && canSavePreset(from: frame) && stock(for: frame) != nil
    }

    func bakePresetAsStock(from frame: Frame, name: String, canisterColor: [Float]?) throws {
        guard case .save(let source) = presetPresentation, source == frame else { return }
        presetPresentation = .builder(try bakedStock(from: frame, name: name, canisterColor: canisterColor))
    }

    private func bakedStock(from frame: Frame, name: String? = nil, canisterColor: [Float]? = nil) throws -> StockBuilderPresentation {
        guard canMakeBakedStock(from: frame), let stock = stock(for: frame) else { throw CocoaError(.featureUnsupported) }
        var render = settings(for: frame, stock: stockIndex(for: frame))
        // The reusable look carries the chosen rating and filtration, not this image's automatic white balance.
        let daylight = controls(for: frame).settings(for: stock)
        render.labBalance = daylight.labBalance
        var spec = try CustomStockSpec(baking: stock, settings: render)
        if let canisterColor { spec.canisterColor = canisterColor }
        return .init(name: name ?? "\(stock.displayName) Custom", spec: spec, frame: frame)
    }
}
