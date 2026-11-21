import Foundation

public enum SubjectModelLicences {
    public static func filenames(in list: String) -> [String] {
        list.split(whereSeparator: \.isNewline).map(String.init)
    }

    public static func texts(in resources: URL) -> [(name: String, text: String)] {
        guard let list = try? String(contentsOf: resources.appendingPathComponent("subject-licences.txt"), encoding: .utf8) else { return [] }
        let folder = resources.appendingPathComponent("Model Licences", isDirectory: true)
        return filenames(in: list).compactMap { name in
            (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)).map { (name, $0) }
        }
    }
}
