import ArgentCore
import Foundation

public enum UserStockStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidID(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidID(let id):
            "Invalid user stock id '\(id)': must start with '\(Stock.userIDPrefix)' and contain only letters, digits, '-' or '_'."
        case .notFound(let id):
            "User stock '\(id)' does not exist."
        }
    }
}

/// Manages user-created and user-imported stock folders on disk (`Application Support/Argent/Stocks/`).
/// Every write stages into a temporary sibling directory and swaps atomically so readers never observe
/// a half-written manifest or LUT.
public struct UserStockStore: Sendable {
    public let folder: URL

    /// The app's user-stocks folder in Application Support. Never call from tests (`ApplicationSupport`).
    public static var defaultFolder: URL {
        ApplicationSupport.folder.appendingPathComponent("Stocks", isDirectory: true)
    }

    public init(folder: URL) {
        self.folder = folder
    }

    /// Valid user stock identifiers start with `user-` followed by one or more ASCII letters, digits, `-`, or `_`.
    public static func isValidUserStockID(_ id: String) -> Bool {
        guard id.hasPrefix(Stock.userIDPrefix) else { return false }
        let suffix = id.dropFirst(Stock.userIDPrefix.count)
        guard !suffix.isEmpty else { return false }
        return suffix.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_")
        }
    }

    /// Builds a unique `user-<slug>` identifier from `displayName`, avoiding `existingIDs`.
    public static func makeID(from displayName: String, existingIDs: Set<String> = []) -> String {
        var slug = ""
        var lastWasDash = false
        for scalar in displayName.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        let base = Stock.userIDPrefix + (slug.isEmpty ? "stock" : slug)
        if !existingIDs.contains(base) { return base }
        var n = 2
        while existingIDs.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// The directory on disk for user stock `id`, after validating `id` as a safe single-component user ID.
    public func stockDirectory(for id: String) throws -> URL {
        guard Self.isValidUserStockID(id) else { throw UserStockStoreError.invalidID(id) }
        return folder.appendingPathComponent(id, isDirectory: true)
    }

    /// Loads every valid user stock in `folder`, rejecting IDs in `reservedIDs` or without the `user-` prefix.
    public func loadAll(excluding reservedIDs: Set<String> = []) -> StockLibrary.LoadResult {
        StockLibrary.loadUserStocks(from: folder, excluding: reservedIDs)
    }

    /// Atomically writes `stock` (and optional builder `specData`) into `folder/<stock.id>`.
    @discardableResult
    public func save(_ stock: Stock, specData: Data? = nil) throws -> URL {
        let target = try stockDirectory(for: stock.id)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let staging = folder.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try stock.write(to: staging)
            if let specData {
                try specData.write(to: staging.appendingPathComponent(Stock.specFileName), options: .atomic)
            }
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: target)
            }
            return target
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Deletes the user stock folder for `id`.
    public func delete(id: String) throws {
        let target = try stockDirectory(for: id)
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { throw UserStockStoreError.notFound(id) }
        try fm.removeItem(at: target)
    }

    /// Reads `spec.json` for `id`, or `nil` if the stock is missing or has no builder spec.
    public func specData(for id: String) -> Data? {
        guard let target = try? stockDirectory(for: id) else { return nil }
        return try? Data(contentsOf: target.appendingPathComponent(Stock.specFileName))
    }
}
