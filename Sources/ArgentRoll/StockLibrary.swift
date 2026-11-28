import ArgentCore
import Foundation

/// The stocks the app offers, with Portra 400 as the default and the first nine in number-key
/// order. Recipes and caches refer to stocks by id.
public enum StockLibrary {
    public static let order = [
        "argent-neutral",
        "kodak-portra-160", "kodak-portra-160-natural", "kodak-portra-400", "kodak-portra-800",
        "kodak-ektar-100", "kodak-gold-200", "kodak-colorplus-200", "kodak-ultramax-400",
        "fujifilm-pro-400h", "fujifilm-c200", "fujifilm-superia-400",
        "kodak-vision3-500t", "kodak-vision3-500t-cinema", "cinestill-800t",
    ]

    public struct LoadResult: Sendable {
        public let stocks: [Stock]
        /// Folders that are not loadable stocks, with the reason, for a log line.
        public let failures: [(folder: String, reason: String)]
    }

    /// Every stock folder under `directory`: the library's stocks in library order, then any
    /// others by id, so a stock baked for testing still shows up.
    public static func load(from directory: URL, includeMonochrome: Bool = false) -> LoadResult {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: [.skipsHiddenFiles])) ?? []
        var stocks: [Stock] = includeMonochrome ? MonochromeFilm.stocks : []
        var failures: [(String, String)] = []
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            do {
                let stock = try Stock.load(from: folder)
                if !stocks.contains(where: { $0.id == stock.id && $0.monochrome != nil }) { stocks.append(stock) }
            } catch {
                failures.append((folder.lastPathComponent, "\(error)"))
            }
        }
        let ordered = includeMonochrome ? order + MonochromeFilm.stocks.map(\.id) : order
        let rank = { (id: String) in ordered.firstIndex(of: id) ?? ordered.count }
        stocks.sort { (rank($0.id), $0.id) < (rank($1.id), $1.id) }
        return LoadResult(stocks: stocks, failures: failures.sorted { $0.0 < $1.0 })
    }
}
