import Foundation

/// Frames' preview scores as a file: a JSON array with one object a frame, `{"path": "DSC04142.ARW",
/// "captureDate": 1792841365.639, "scores": {"faceQuality": 0.359, "aesthetics": 0.414,
/// "featurePrint": "…"}}`. `captureDate` is seconds since 1970 and may be null, as may `scores` and
/// `faceQuality`. `featurePrint` is base64 of little-endian Float16 values, which hold Vision's
/// revision 2 prints exactly.
public enum CullScoreFile {
    public struct ReadError: LocalizedError, Equatable {
        public var line: Int
        public var message: String

        public var errorDescription: String? { "line \(line): \(message)" }
    }

    /// The frames in `data`; no frames for an empty file. A malformed file throws `ReadError`,
    /// naming the line of the frame at fault.
    public static func read(_ data: Data) throws -> [CullInput] {
        let bytes = [UInt8](data)
        guard bytes.contains(where: { !isWhitespace($0) }) else { return [] }
        let frames: [Frame]
        do {
            frames = try JSONDecoder().decode([Frame].self, from: data)
        } catch let error as DecodingError {
            throw readError(error, bytes)
        }
        let lines = elementLines(bytes)
        var seen: [String: Int] = [:]
        var printLength: Int?
        return try frames.enumerated().map { index, frame in
            let line = Self.line(index, of: lines)
            if let first = seen[frame.path] {
                throw ReadError(line: line, message: "\(frame.path) appears again; first on line \(first)")
            }
            seen[frame.path] = line
            let date = frame.captureDate.map(Date.init(timeIntervalSince1970:))
            guard let scores = frame.scores else { return CullInput(path: frame.path, captureDate: date, scores: nil) }
            guard let print = Data(base64Encoded: scores.featurePrint).map([UInt8].init), !print.isEmpty, print.count % 2 == 0 else {
                throw ReadError(line: line, message: "featurePrint is not base64 of Float16 values")
            }
            let values = stride(from: 0, to: print.count, by: 2).map {
                Float(Float16(bitPattern: UInt16(print[$0]) | UInt16(print[$0 + 1]) << 8))
            }
            guard values.allSatisfy(\.isFinite), scores.aesthetics.isFinite, scores.faceQuality?.isFinite ?? true else {
                throw ReadError(line: line, message: "scores hold a value that is not a finite number")
            }
            if let printLength, values.count != printLength {
                throw ReadError(line: line, message: "featurePrint holds \(values.count) values where earlier frames hold \(printLength)")
            }
            printLength = values.count
            return CullInput(path: frame.path, captureDate: date,
                             scores: PreviewScores(faceQuality: scores.faceQuality, aesthetics: scores.aesthetics, featurePrint: values))
        }
    }

    private struct Frame: Decodable {
        var path: String
        var captureDate: Double?
        var scores: Scores?
    }

    private struct Scores: Decodable {
        var faceQuality: Double?
        var aesthetics: Double
        var featurePrint: String
    }

    private static func readError(_ error: DecodingError, _ bytes: [UInt8]) -> ReadError {
        let context: DecodingError.Context
        switch error {
        case let .typeMismatch(_, c), let .valueNotFound(_, c), let .keyNotFound(_, c), let .dataCorrupted(c): context = c
        @unknown default: return ReadError(line: 1, message: "\(error)")
        }
        if let index = context.codingPath.first?.intValue {
            let field = context.codingPath.dropFirst().map(\.stringValue).joined(separator: ".")
            let message: String
            if case let .keyNotFound(key, _) = error {
                message = (field.isEmpty ? "" : field + ".") + key.stringValue + " is missing"
            } else {
                message = field.isEmpty ? context.debugDescription : "\(field): \(context.debugDescription)"
            }
            return ReadError(line: line(index, of: elementLines(bytes)), message: message)
        }
        // JSONSerialization names the byte where the syntax broke, or none at the end of the file.
        guard let underlying = context.underlyingError as NSError? else {
            return ReadError(line: 1, message: context.debugDescription)
        }
        let message = underlying.userInfo[NSDebugDescriptionErrorKey] as? String ?? context.debugDescription
        let offset = underlying.userInfo["NSJSONSerializationErrorIndex"] as? Int ?? bytes.count - 1
        return ReadError(line: line(at: offset, bytes), message: message)
    }

    private static func elementLines(_ bytes: [UInt8]) -> [Int] {
        var lines: [Int] = []
        var line = 1, depth = 0, inString = false, escaped = false, expectingElement = false
        for byte in bytes {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            if byte == UInt8(ascii: "\n") { line += 1 }
            if isWhitespace(byte) { continue }
            if depth == 1, expectingElement, byte != UInt8(ascii: "]") {
                lines.append(line)
                expectingElement = false
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                if depth == 1 { expectingElement = true }
            case UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
            case UInt8(ascii: ","): if depth == 1 { expectingElement = true }
            default: break
            }
        }
        return lines
    }

    private static func line(_ element: Int, of lines: [Int]) -> Int {
        lines.indices.contains(element) ? lines[element] : lines.last ?? 1
    }

    private static func line(at offset: Int, _ bytes: [UInt8]) -> Int {
        1 + bytes.prefix(max(0, offset)).filter { $0 == UInt8(ascii: "\n") }.count
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\t")
    }
}
