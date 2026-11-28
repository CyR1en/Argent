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
        !isSheetShown && presetPresentation == nil && userStockStore != nil && !isQuitting
    }

    func showStockBuilder(from stock: Stock? = nil) {
        guard canShowStockBuilder else { return }
        stockBuilder = .init(name: stock.map { "\($0.displayName) Custom" } ?? "",
                             spec: stock.map(CustomStockSpec.init(derivedFrom:)) ?? .init(),
                             frame: shownFrame ?? selectedFrame)
    }

    func editCustomStock(_ stock: Stock) {
        guard canShowStockBuilder, stock.isUserStock, stock.hasSpec,
              let data = userStockStore?.specData(for: stock.id) else { return }
        do {
            let spec = try JSONDecoder().decode(CustomStockSpec.self, from: data)
            stockBuilder = .init(stockID: stock.id, name: stock.displayName, spec: spec, frame: shownFrame ?? selectedFrame)
        } catch {
            message = "Could not open the stock recipe: \(error)"
        }
    }

    func canBakeFrameAsStock(_ frame: Frame) -> Bool {
        canShowStockBuilder && canSavePreset(from: frame) && stock(for: frame) != nil
    }

    func bakeFrameAsStock(_ frame: Frame) {
        guard canBakeFrameAsStock(frame), let stock = stock(for: frame) else { return }
        do {
            var render = settings(for: frame, stock: stockIndex(for: frame))
            // The reusable look carries the chosen rating and filtration, not this image's automatic white balance.
            let daylight = controls(for: frame).settings(for: stock)
            render.labBalance = daylight.labBalance
            let spec = try CustomStockSpec(baking: stock, settings: render)
            stockBuilder = .init(name: "\(stock.displayName) Custom", spec: spec, frame: frame)
        } catch {
            message = "Could not bake this frame: \(error)"
        }
    }
}
