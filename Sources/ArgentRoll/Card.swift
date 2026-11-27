import Foundation

/// A mounted camera card holding raw files, found without opening it as a roll.
public struct Card: Sendable, Equatable, Identifiable {
    /// The volume's root, which is the roll when the card is opened.
    public let volume: URL
    /// The volume's name as Finder shows it, usually "Untitled" for a card the camera formatted.
    public let name: String
    /// ARW files in the card's DCF folders, or `nil` when DCIM or one of its DCF folders cannot
    /// be listed. macOS may let an app see a removable volume's folders even when the app cannot
    /// list them (docs/research/camera.md, section 4).
    public let rawCount: Int?

    public var id: URL { volume }

    public init(volume: URL, name: String, rawCount: Int?) {
        self.volume = volume
        self.name = name
        self.rawCount = rawCount
    }
}

public enum CardScanner {
    /// Whether `name` is a DCF folder under DCIM: three digits from 100 to 999 and five more
    /// characters. Sony's standard form is `100MSDCF`; its date form is `10021006`.
    public static func isDCFFolder(_ name: String) -> Bool {
        let characters = Array(name)
        guard characters.count == 8, let number = Int(String(characters[0..<3])) else { return false }
        return (100...999).contains(number)
    }

    /// The card on `volume`, if it is one: a DCIM folder whose DCF folders hold ARW files.
    /// Reads two directory levels and never a file, so it costs a few milliseconds even on a
    /// full card. If DCIM or a DCF folder is visible but cannot be listed, the card has an unknown
    /// count; `nil` if no card is found.
    public static func card(on volume: URL, name: String? = nil) -> Card? {
        let fileManager = FileManager.default
        let dcim = volume.appendingPathComponent("DCIM", isDirectory: true)
        let shown = name ?? (try? volume.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName)
            ?? volume.lastPathComponent
        guard let folders = try? fileManager.contentsOfDirectory(at: dcim, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles])
        else {
            // Seeing the folder needs no consent; listing it does (measured, the research's section 4).
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: dcim.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return Card(volume: volume, name: shown, rawCount: nil)
        }
        var count = 0
        for folder in folders where isDCFFolder(folder.lastPathComponent) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let files = try? fileManager.contentsOfDirectory(atPath: folder.path) else {
                return Card(volume: volume, name: shown, rawCount: nil)
            }
            count += files.filter { !$0.hasPrefix(".") && ($0 as NSString).pathExtension.lowercased() == "arw" }.count
        }
        guard count > 0 else { return nil }
        return Card(volume: volume, name: shown, rawCount: count)
    }

    /// Whether `volume` is one a card reader or a camera would mount: removable or ejectable,
    /// and not the startup disk. Network volumes are left out, since they are not cards.
    public static func isCardLike(_ volume: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsRootFileSystemKey,
                                         .volumeIsLocalKey]
        guard let values = try? volume.resourceValues(forKeys: keys) else { return false }
        if values.volumeIsRootFileSystem == true || values.volumeIsLocal == false { return false }
        return values.volumeIsRemovable == true || values.volumeIsEjectable == true
    }

    /// Cards among the mounted volumes, in mount order.
    public static func mountedCards() -> [Card] {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                            options: [.skipHiddenVolumes]) ?? []
        return volumes.filter(isCardLike).compactMap { card(on: $0) }
    }
}
