import Foundation

public enum StockError: Error, CustomStringConvertible {
    case unreadableManifest(URL, reason: String)
    case unsupportedSchema(Int)
    case badValue(String)
    case unreadableCube(String, reason: String)
    case unreadableBinary(String, reason: String)
    case sizeMismatch(file: String, manifest: Int, found: Int)

    public var description: String {
        switch self {
        case .unreadableManifest(let url, let reason): return "Could not read the stock manifest at \(url.path): \(reason)"
        case .unsupportedSchema(let n): return "Stock manifest schema \(n) is not supported; this build reads schema 1 and 2."
        case .badValue(let what): return "Stock manifest is invalid: \(what)."
        case .unreadableCube(let file, let reason): return "Could not read \(file): \(reason)"
        case .unreadableBinary(let file, let reason): return "Could not read \(file): \(reason)"
        case .sizeMismatch(let file, let manifest, let found):
            return "\(file) is \(found)^3 but the manifest says \(manifest)^3."
        }
    }
}

/// A film stock as `argent-bake` writes it: the Negative LUT, the Print LUT, and the
/// numbers that join them.
///
/// On disk it is a folder holding `stock.json` and the LUT files the manifest names. Bake
/// contract 2 writes each LUT twice, as a `.cube` and as a `.lut3d` binary that holds the
/// same table; the loader takes the binary when the manifest names it and the file is
/// there, and the `.cube` otherwise. A schema 1 folder has only the `.cube` files.
public struct Stock: Sendable {
    public static let manifestName = "stock.json"
    /// Optional parametric builder specification stored beside `stock.json` for re-editable user stocks.
    public static let specFileName = "spec.json"
    /// Prefix required for all user-created or user-imported stock identifiers so they never shadow bundled stocks.
    public static let userIDPrefix = "user-"
    /// The manifest schemas this build reads.
    public static let supportedSchemas = 1...2

    /// Where the stock came from: shipped with Argent, built in the app's stock builder, or imported from a LUT/bundle.
    public enum Origin: String, Sendable, Equatable, Hashable, Codable {
        case bundled
        case userBuilt
        case userImported
    }

    /// Custom RGB tint (0...1 per channel) shown on the stock's canister icon in the dock.
    public struct CanisterColor: Sendable, Equatable, Hashable, Codable {
        public var red: Float
        public var green: Float
        public var blue: Float

        public init(red: Float, green: Float, blue: Float) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        public var components: [Float] { [red, green, blue] }
    }

    public let id: String
    /// The name the app shows: the film's own without its maker, for example "Portra 400".
    public let displayName: String
    /// The film the stock models, for example "Kodak Portra 400": named only in `afterLine`,
    /// never as the stock's label. `nil` for a stock modelled on no film, and for a manifest
    /// written before the field existed.
    public let modelledFilm: String?
    public let modelledPrint: String?
    /// How the profile behind the bake was made, for example `synthetic` or `datasheet`.
    /// Only a stock fitted to ground-truth scans is a look.
    public let status: String
    /// Where this stock originated.
    public let origin: Origin
    /// Optional custom canister tint for the dock picker; `nil` falls back to the built-in palette.
    public let canisterColor: CanisterColor?
    /// Optional short description of the stock's look, used for custom stocks in tooltips and accessibility.
    public let characterLine: String?
    /// Whether a `spec.json` sits beside `stock.json`, allowing the stock to be reopened in the Stock Builder.
    public let hasSpec: Bool
    /// The speed printed on the box, which the Negative LUT is baked at.
    public let boxSpeed: Float
    /// The Negative LUT stores the amount of each of the negative's dyes divided by this,
    /// and the Print LUT reads them the same way.
    public let densityRange: Float
    /// How far one unit of negative dye moves the paper layer behind it, as the magnitude
    /// of d(log10 paper exposure) / d(dye amount) at the daylight-reference mid-gray, per
    /// channel: red layer behind cyan dye, green behind magenta, blue behind yellow. Lab
    /// balance and print exposure divide by it to become a Print LUT offset. A schema 1
    /// manifest carries none and gets ones, which was the behaviour before contract 2.
    public let exposurePerUnit: SIMD3<Float>
    /// Log-encoded scene-linear RGB to normalized dye amounts.
    public let negative: LUT3D
    /// Normalized dye amounts to display-linear RGB in the working primaries.
    public let print: LUT3D
    /// The stock's grain, when its profile has one: per layer, the dye amount sigma at a 48
    /// micrometre aperture against the layer's own normalized dye amount.
    public let grain: GrainTable?
    /// The stock's halation, when its profile has one.
    public let halation: Halation?
    public let monochrome: MonochromeFilm?

    public var isUserStock: Bool { origin != .bundled }

    /// Halation as the profile gives it, a guess until a point source is shot on film
    /// (docs/M3-research.md section 4).
    public struct Halation: Sendable, Equatable {
        /// The share of the source's energy the base returns.
        public var strength: Float
        /// Green's share of red's; blue gets none.
        public var greenShare: Float
        /// The kernel's scale on the film plane.
        public var radiusMicrometres: Float

        public init(strength: Float, greenShare: Float, radiusMicrometres: Float) {
            self.strength = strength
            self.greenShare = greenShare
            self.radiusMicrometres = radiusMicrometres
        }
    }

    public init(id: String, displayName: String, modelledFilm: String? = nil, status: String, boxSpeed: Float,
                densityRange: Float, exposurePerUnit: SIMD3<Float> = SIMD3<Float>(repeating: 1), negative: LUT3D,
                print: LUT3D, grain: GrainTable? = nil, halation: Halation? = nil, modelledPrint: String? = nil,
                monochrome: MonochromeFilm? = nil, origin: Origin = .bundled, canisterColor: CanisterColor? = nil,
                characterLine: String? = nil, hasSpec: Bool = false) {
        self.grain = grain
        self.halation = halation
        self.monochrome = monochrome
        self.origin = origin
        self.canisterColor = canisterColor
        self.characterLine = characterLine
        self.hasSpec = hasSpec
        self.id = id
        self.displayName = displayName
        self.modelledFilm = modelledFilm
        self.modelledPrint = modelledPrint
        self.status = status
        self.boxSpeed = boxSpeed
        self.densityRange = densityRange
        self.exposurePerUnit = exposurePerUnit
        self.negative = negative
        self.print = print
    }

    public static func load(from directory: URL, origin: Origin = .bundled) throws -> Stock {
        let manifestURL = directory.appendingPathComponent(manifestName)
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw StockError.unreadableManifest(manifestURL, reason: error.localizedDescription)
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw StockError.unreadableManifest(manifestURL, reason: "\(error)")
        }
        guard supportedSchemas.contains(manifest.schema) else { throw StockError.unsupportedSchema(manifest.schema) }
        guard manifest.boxSpeed > 0 else { throw StockError.badValue("boxSpeed must be positive") }
        guard manifest.densityRange > 0 else { throw StockError.badValue("densityRange must be positive") }

        let encoding = LogEncoding(stopsBelowMidGray: manifest.negative.logEncoding.stopsBelowMidGray,
                                   stopsAboveMidGray: manifest.negative.logEncoding.stopsAboveMidGray,
                                   midGray: manifest.negative.logEncoding.midGray)
        guard encoding.range > 0, encoding.midGray > 0 else { throw StockError.badValue("logEncoding is degenerate") }

        // Schema 2 always carries it; a schema 2 manifest without it would turn a stop of lab
        // balance into about 0.8 of a stop without saying so.
        if manifest.schema >= 2, manifest.print.exposurePerUnit == nil {
            throw StockError.badValue("schema \(manifest.schema) needs print.exposurePerUnit")
        }
        var exposurePerUnit = SIMD3<Float>(repeating: 1)
        if let values = manifest.print.exposurePerUnit {
            guard values.count == 3 else { throw StockError.badValue("print.exposurePerUnit must have three values") }
            guard values.allSatisfy({ $0 > 0 && $0.isFinite }) else {
                throw StockError.badValue("print.exposurePerUnit must be positive")
            }
            exposurePerUnit = SIMD3<Float>(values[0], values[1], values[2])
        }

        var grain: GrainTable?
        if let table = manifest.grain {
            guard table.amounts.count == table.sigma48.count, table.amounts.count >= 2,
                  table.amounts.allSatisfy({ $0.count == 3 }), table.sigma48.allSatisfy({ $0.count == 3 && $0.allSatisfy { $0 >= 0 } })
            else { throw StockError.badValue("grain needs matching rows of three amounts and three non-negative sigmas") }
            grain = GrainTable(amounts: table.amounts, sigma48: table.sigma48)
        }
        let halation: Halation?
        if let h = manifest.halation {
            guard h.strength.isFinite, h.strength >= 0,
                  h.greenShare.isFinite, (0...1).contains(h.greenShare),
                  h.radiusMicrometres.isFinite, h.radiusMicrometres >= 0,
                  h.strength == 0 || h.radiusMicrometres > 0 else {
                throw StockError.badValue("halation needs finite strength >= 0, greenShare in 0...1, and a positive radiusMicrometres when enabled")
            }
            halation = h.strength > 0
                ? Halation(strength: h.strength, greenShare: h.greenShare, radiusMicrometres: h.radiusMicrometres) : nil
        } else {
            halation = nil
        }

        let canisterColor: CanisterColor?
        if let color = manifest.canisterColor {
            guard color.count == 3, color.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw StockError.badValue("canisterColor must have three finite values in 0...1")
            }
            canisterColor = CanisterColor(red: color[0], green: color[1], blue: color[2])
        } else {
            canisterColor = nil
        }

        let characterLine = manifest.characterLine
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let hasSpec = FileManager.default.fileExists(atPath: directory.appendingPathComponent(specFileName).path)

        return Stock(
            id: manifest.id, displayName: manifest.displayName,
            modelledFilm: manifest.modelledFilm.flatMap { $0.isEmpty ? nil : $0 }, status: manifest.status,
            boxSpeed: manifest.boxSpeed, densityRange: manifest.densityRange, exposurePerUnit: exposurePerUnit,
            negative: try loadLUT(cube: manifest.negative.file, binary: manifest.negative.binary,
                                  size: manifest.negative.size, encoding: encoding, in: directory),
            print: try loadLUT(cube: manifest.print.file, binary: manifest.print.binary,
                               size: manifest.print.size, encoding: LogEncoding(), in: directory),
            grain: grain, halation: halation, modelledPrint: manifest.modelledPrint,
            origin: origin, canisterColor: canisterColor, characterLine: characterLine, hasSpec: hasSpec)
    }

    /// Writes this stock as a schema-2 folder (`stock.json`, `negative.lut3d`, `print.lut3d`).
    public func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let negativeBinary = "negative.lut3d"
        let printBinary = "print.lut3d"
        try negative.binaryData().write(to: directory.appendingPathComponent(negativeBinary), options: .atomic)
        try print.binaryData().write(to: directory.appendingPathComponent(printBinary), options: .atomic)

        let manifest = Manifest(
            schema: 2,
            id: id,
            displayName: displayName,
            modelledFilm: modelledFilm,
            modelledPrint: modelledPrint,
            status: status,
            boxSpeed: boxSpeed,
            densityRange: densityRange,
            canisterColor: canisterColor?.components,
            characterLine: characterLine,
            negative: .init(
                file: "negative.cube",
                binary: negativeBinary,
                size: negative.size,
                logEncoding: .init(
                    stopsBelowMidGray: negative.encoding.stopsBelowMidGray,
                    stopsAboveMidGray: negative.encoding.stopsAboveMidGray,
                    midGray: negative.encoding.midGray
                )
            ),
            print: .init(
                file: "print.cube",
                binary: printBinary,
                size: print.size,
                exposurePerUnit: [exposurePerUnit.x, exposurePerUnit.y, exposurePerUnit.z]
            ),
            grain: grain.map { .init(amounts: $0.amounts, sigma48: $0.sigma48) },
            halation: halation.map { .init(strength: $0.strength, greenShare: $0.greenShare, radiusMicrometres: $0.radiusMicrometres) }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    /// The one line that names the film the stock models, where the app names it at all
    /// (spec, Naming policy): "After Kodak Portra 400: Argent's model of the film, built from
    /// its published datasheet." `nil` when the stock models no film.
    public var afterLine: String? {
        guard let modelledFilm else { return nil }
        if let modelledPrint {
            return "After \(modelledFilm) on \(modelledPrint): Argent's projection model, based on published data."
        }
        let basis: String
        switch status {
        case "datasheet": basis = ", built from its published datasheet"
        case "fitted": basis = ", built from its published datasheet and fitted to lab scans"
        case "approximation": return "After \(modelledFilm): Argent's approximation, using proxy data and not fitted to scans."
        default: basis = ""
        }
        return "After \(modelledFilm): Argent's model of the film\(basis)."
    }

    /// The binary file when the manifest names one and it exists, else the `.cube`. A binary
    /// file that is there but will not parse is an error, not a reason to read the `.cube`:
    /// the two are meant to hold the same table, and a broken one says the bake went wrong.
    private static func loadLUT(cube: String, binary: String?, size: Int, encoding: LogEncoding,
                                in directory: URL) throws -> LUT3D {
        // Both names are checked whichever one is read: a manifest that points outside its
        // folder is not a stock even when the other file would do.
        let cubeURL = try url(for: cube, in: directory)
        let binaryURL = try binary.map { try url(for: $0, in: directory) }
        let lut: LUT3D
        let file: String
        if let binary, let binaryURL, FileManager.default.fileExists(atPath: binaryURL.path) {
            file = binary
            do {
                lut = try LUT3D.parseBinary(Data(contentsOf: binaryURL), encoding: encoding)
            } catch {
                throw StockError.unreadableBinary(binary, reason: "\(error)")
            }
        } else {
            file = cube
            do {
                lut = try LUT3D.parseCube(String(contentsOf: cubeURL, encoding: .utf8), encoding: encoding)
            } catch {
                throw StockError.unreadableCube(cube, reason: "\(error)")
            }
        }
        guard lut.size == size else { throw StockError.sizeMismatch(file: file, manifest: size, found: lut.size) }
        return lut
    }

    /// The manifest names files beside it; a path that leaves the folder is not a stock.
    private static func url(for file: String, in directory: URL) throws -> URL {
        guard !file.isEmpty, file == URL(fileURLWithPath: file).lastPathComponent, file != "..", file != "." else {
            throw StockError.badValue("\(file) is not a plain file name")
        }
        return directory.appendingPathComponent(file)
    }

    private struct Manifest: Codable {
        struct Negative: Codable {
            struct Encoding: Codable {
                var stopsBelowMidGray: Float
                var stopsAboveMidGray: Float
                var midGray: Float
            }
            var file: String
            var binary: String?
            var size: Int
            var logEncoding: Encoding
        }
        struct Print: Codable {
            var file: String
            var binary: String?
            var size: Int
            var exposurePerUnit: [Float]?
        }

        var schema: Int
        var id: String
        var displayName: String
        var modelledFilm: String?
        var modelledPrint: String?
        var status: String
        var boxSpeed: Float
        var densityRange: Float
        var canisterColor: [Float]?
        var characterLine: String?
        struct Grain: Codable {
            var amounts: [[Float]]
            var sigma48: [[Float]]
        }
        struct HalationEntry: Codable {
            var strength: Float
            var greenShare: Float
            var radiusMicrometres: Float
        }

        var negative: Negative
        var print: Print
        var grain: Grain?
        var halation: HalationEntry?
    }
}
