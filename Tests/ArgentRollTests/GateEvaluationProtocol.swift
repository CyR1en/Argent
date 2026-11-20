import ArgentCore
import Foundation

/// The evaluation cohort lives outside the repository with the restricted source images.
/// Captured regions and orientations are scoring inputs, independent of the current detector.
struct GateEvaluationProtocol: Codable {
    struct Region: Codable, Equatable {
        var x0: Int
        var x1: Int
        var y0: Int
        var y1: Int

        func area(width: Int, height: Int) -> Double {
            Double((x1 - x0) * (y1 - y0)) / Double(width * height)
        }
    }

    struct Face: Codable, Equatable {
        var box: [Float]
        var region: Region

        init(_ face: FaceMeasure, width: Int, height: Int) {
            box = face.box
            let bounds = GateMeasureTests.inset(box, width: width, height: height)
            region = Region(x0: bounds.xs.lowerBound, x1: bounds.xs.upperBound,
                            y0: bounds.ys.lowerBound, y1: bounds.ys.upperBound)
        }
    }

    struct Frame: Codable {
        var name: String
        var width: Int
        var height: Int
        /// Zero is upright; one is the vertical flip used by the historical alignment.
        var orientations: [Int]
        var face: Face?

        func validateDimensions(width: Int, height: Int) throws {
            guard self.width == width, self.height == height else {
                throw Invalid("\(name): decoded dimensions changed")
            }
        }
    }

    struct Invalid: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    var version = 1
    var jnd = 2.3
    var experts = ["a", "b", "c", "d", "e"]
    var inputs: [String]
    var frames: [Frame] = []
    var exclusions: [String: String] = [:]

    func validate() throws {
        guard version == 1, jnd == 2.3, experts == ["a", "b", "c", "d", "e"] else {
            throw Invalid("unsupported evaluation protocol, expert order or JND")
        }
        guard !inputs.isEmpty, Set(inputs).count == inputs.count,
              inputs.allSatisfy({ !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." }),
              !frames.isEmpty, frames.contains(where: { $0.face != nil }),
              Set(frames.map(\.name)).count == frames.count,
              Set(frames.map(\.name)).isDisjoint(with: exclusions.keys),
              Set(frames.map(\.name)).union(exclusions.keys) == Set(inputs),
              exclusions.values.allSatisfy({ !$0.isEmpty }) else {
            throw Invalid("incomplete, empty or duplicate evaluation cohort")
        }
        for frame in frames {
            guard frame.width > 0, frame.height > 0, frame.orientations.count == experts.count,
                  frame.orientations.allSatisfy({ $0 == 0 || $0 == 1 }) else {
                throw Invalid("\(frame.name): invalid dimensions or orientations")
            }
            if let face = frame.face {
                let r = face.region
                guard face.box.count == 4, face.box.allSatisfy(\.isFinite),
                      face.box[2] > 0, face.box[3] > 0,
                      r.x0 >= 0, r.y0 >= 0, r.x0 < r.x1, r.y0 < r.y1,
                      r.x1 <= frame.width, r.y1 <= frame.height else {
                    throw Invalid("\(frame.name): invalid evaluation face region")
                }
            }
        }
    }

    func validateInventory(_ names: [String], label: String) throws {
        guard names.count == inputs.count, Set(names) == Set(inputs) else {
            throw Invalid("\(label): evaluation inputs missing, duplicated or added")
        }
    }

    /// A locked frame with no evaluation face stays faceless even if a new detector finds one.
    /// A locked portrait keeps its region even if detection is now empty or chooses another face.
    static func evaluationFace(locked: Frame?, detected: FaceMeasure?, width: Int, height: Int) -> Face? {
        if let locked { return locked.face }
        return detected.map { Face($0, width: width, height: height) }
    }

    static func read(_ url: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }

    func write(_ url: URL) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .withoutOverwriting)
    }
}
