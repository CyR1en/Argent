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

    /// Every stock folder under `directory` (bundled) plus optional user stocks under `userDirectory`.
    /// Bundled stocks appear first in library order (then any extra bundled test stocks by id),
    /// followed by user stocks sorted alphabetically by display name.
    public static func load(from directory: URL, userDirectory: URL? = nil, includeMonochrome: Bool = false) -> LoadResult {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: [.skipsHiddenFiles])) ?? []
        var bundled: [Stock] = includeMonochrome ? MonochromeFilm.stocks : []
        var failures: [(String, String)] = []
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            do {
                let stock = try Stock.load(from: folder, origin: .bundled)
                if !bundled.contains(where: { $0.id == stock.id && $0.monochrome != nil }) { bundled.append(stock) }
            } catch {
                failures.append((folder.lastPathComponent, "\(error)"))
            }
        }
        let ordered = includeMonochrome ? order + MonochromeFilm.stocks.map(\.id) : order
        let rank = { (id: String) in ordered.firstIndex(of: id) ?? ordered.count }
        bundled.sort { (rank($0.id), $0.id) < (rank($1.id), $1.id) }

        var stocks = bundled
        if let userDirectory {
            let userResult = loadUserStocks(from: userDirectory, excluding: Set(bundled.map(\.id)))
            stocks.append(contentsOf: userResult.stocks)
            failures.append(contentsOf: userResult.failures)
        }
        return LoadResult(stocks: stocks, failures: failures.sorted { $0.0 < $1.0 })
    }

    /// Loads user stock folders from `directory`, enforcing the `user-` id prefix and rejecting any id
    /// that collides with `reservedIDs` or another folder in `directory`.
    public static func loadUserStocks(from directory: URL, excluding reservedIDs: Set<String> = []) -> LoadResult {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: [.skipsHiddenFiles])) ?? []
        let sortedFolders = folders.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var seenIDs = reservedIDs
        var stocks: [Stock] = []
        var failures: [(String, String)] = []
        for folder in sortedFolders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let hasSpec = FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(Stock.specFileName).path
            )
            let origin: Stock.Origin = hasSpec ? .userBuilt : .userImported
            do {
                let stock = try Stock.load(from: folder, origin: origin)
                guard stock.id.hasPrefix(Stock.userIDPrefix), stock.id.count > Stock.userIDPrefix.count else {
                    failures.append((folder.lastPathComponent,
                                     "user stock id '\(stock.id)' must start with '\(Stock.userIDPrefix)'"))
                    continue
                }
                guard seenIDs.insert(stock.id).inserted else {
                    failures.append((folder.lastPathComponent,
                                     "stock id '\(stock.id)' collides with an existing stock"))
                    continue
                }
                stocks.append(stock)
            } catch {
                failures.append((folder.lastPathComponent, "\(error)"))
            }
        }
        stocks.sort {
            ($0.displayName.lowercased(), $0.id) < ($1.displayName.lowercased(), $1.id)
        }
        return LoadResult(stocks: stocks, failures: failures.sorted { $0.0 < $1.0 })
    }
}
