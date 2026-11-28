import ArgentCore
import CryptoKit
import Foundation

/// How a roll is developed to files: the format, its quality, the colour space, grain and halation.
public struct OutputSettings: Sendable, Equatable, Hashable, Codable {
    public enum Format: String, Sendable, Codable, CaseIterable {
        case jpeg
        case heic
        case tiff16

        public var title: String {
            switch self {
            case .jpeg: return "JPEG"
            case .heic: return "HEIC"
            case .tiff16: return "TIFF, 16-bit"
            }
        }

        /// Whether the format is compressed at a quality: JPEG and HEIC, not the uncompressed TIFF.
        public var hasQuality: Bool { self != .tiff16 }

        /// The quality a develop recorded before the slider existed was made at: JPEG at 92 and
        /// HEIC at 90, the qualities M0 measured.
        public var formerQuality: Int { self == .heic ? 90 : OutputSettings.defaultQuality }

        /// The encoder's format at `quality`, 0 to 100, which ImageIO takes as 0 to 1.
        public func encoding(quality: Int) -> OutputFormat {
            let fraction = Double(min(max(quality, 0), 100)) / 100
            switch self {
            case .jpeg: return .jpeg(quality: fraction)
            case .heic: return .heic(quality: fraction)
            case .tiff16: return .tiff16
            }
        }
    }

    /// The developed file's longer side. Full size keeps the camera's full resolution; the
    /// Instagram presets write sRGB-ready social dimensions (1080 px feed / 1350 px 4:5 portrait).
    /// Legacy 4096 and 2048 cases stay decodable so older recipes still open.
    public enum Size: Int, Sendable, Codable, CaseIterable {
        case full = 0
        case longEdge4096 = 4096
        case longEdge2048 = 2048
        case instagramPortrait = 1350
        case instagramFeed = 1080

        /// The sizes offered in the Develop panel's Size menu.
        public static let pickerOptions: [Size] = [.full, .instagramFeed, .instagramPortrait]

        public var longEdge: Int? { self == .full ? nil : rawValue }

        /// Filename suffix appended to social-sized exports so they never overwrite full-size files.
        public var fileSuffix: String {
            switch self {
            case .instagramFeed: return "-1080px"
            case .instagramPortrait: return "-1350px"
            case .full, .longEdge4096, .longEdge2048: return ""
            }
        }

        public var title: String {
            switch self {
            case .full: return "Full size"
            case .instagramFeed: return "Instagram (1080 px)"
            case .instagramPortrait: return "Instagram Vertical (1350 px)"
            case .longEdge4096, .longEdge2048: return "\(rawValue) px long edge"
            }
        }
    }

    /// Grain, in the stock panel and on the Develop page.
    public enum Grain: String, Sendable, Codable, CaseIterable {
        case natural
        case off

        public var title: String { self == .natural ? "Natural" : "Off" }
        /// The render's multiple of the stock's grain.
        public var amount: Float { self == .natural ? 1 : 0 }
    }

    /// One-click social export presets: sRGB JPEG at quality 90 sized for Instagram.
    public static let instagramFeed = OutputSettings(format: .jpeg, size: .instagramFeed, space: .sRGB, grain: .off, quality: 90)
    public static let instagramPortrait = OutputSettings(format: .jpeg, size: .instagramPortrait, space: .sRGB, grain: .off, quality: 90)

    /// Returns a copy configured for an Instagram sRGB JPEG export at `size` (quality 90) while
    /// preserving the roll's existing `grain` and `halation` settings.
    public func applyingInstagramPreset(_ size: Size) -> OutputSettings {
        var copy = self
        copy.format = .jpeg
        copy.size = size
        copy.space = .sRGB
        copy.quality = 90
        return copy
    }

    /// Whether these settings match one of the Instagram sRGB JPEG presets.
    public var isInstagramPreset: Bool {
        format == .jpeg && space == .sRGB && (size == .instagramFeed || size == .instagramPortrait)
    }

    /// The quality a new develop starts from, JPEG's former 92.
    public static let defaultQuality = 92
    public static let qualityRange = 0...100
    /// Halation as the stock has it, the middle of the control's range.
    public static let defaultHalation = 100
    public static let halationRange = 0...200

    /// The render's multiple of the stock's halation for the control at `value`: 1 at 100.
    public static func halationAmount(_ value: Int) -> Float {
        Float(min(max(value, halationRange.lowerBound), halationRange.upperBound)) / 100
    }

    public var format: Format
    public var size: Size
    public var space: OutputSpace
    public var grain: Grain
    /// Halation, 0 to 200: 100 is the stock's own, 0 none and 200 twice as much. Like grain it is every frame's,
    /// its preview's and its develop's, unless a frame has its own (`FrameControls.halation`).
    public var halation: Int {
        didSet { halation = min(max(halation, Self.halationRange.lowerBound), Self.halationRange.upperBound) }
    }
    /// JPEG and HEIC quality, 0 to 100 as Lightroom's; the uncompressed TIFF ignores it.
    public var quality: Int {
        didSet { quality = min(max(quality, Self.qualityRange.lowerBound), Self.qualityRange.upperBound) }
    }

    public init(format: Format = .jpeg, size: Size = .full, space: OutputSpace = .sRGB, grain: Grain = .natural,
                quality: Int = OutputSettings.defaultQuality, halation: Int = OutputSettings.defaultHalation) {
        self.format = format
        self.size = size
        self.space = space
        self.grain = grain
        self.halation = min(max(halation, Self.halationRange.lowerBound), Self.halationRange.upperBound)
        self.quality = min(max(quality, Self.qualityRange.lowerBound), Self.qualityRange.upperBound)
    }

    /// The encoder's format for these settings.
    public var encoding: OutputFormat { format.encoding(quality: quality) }

    /// Whether a file developed with `other` is the one these settings make: everything alike, the
    /// quality only where the format has one.
    public func makesTheSameFile(as other: OutputSettings) -> Bool {
        var mine = self, theirs = other
        if !format.hasQuality { mine.quality = Self.defaultQuality }
        if !other.format.hasQuality { theirs.quality = Self.defaultQuality }
        return mine == theirs
    }

    private enum CodingKeys: String, CodingKey { case format, size, space, grain, quality, halation }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(Format.self, forKey: .format)
        size = try container.decode(Size.self, forKey: .size)
        space = try container.decode(OutputSpace.self, forKey: .space)
        // Develops recorded before grain existed had none.
        grain = try container.decodeIfPresent(Grain.self, forKey: .grain) ?? .off
        // Develops and settings recorded before the slider were at the format's fixed quality.
        let quality = try container.decodeIfPresent(Int.self, forKey: .quality) ?? format.formerQuality
        self.quality = min(max(quality, Self.qualityRange.lowerBound), Self.qualityRange.upperBound)
        // Develops and settings recorded before the control had the stock's own halation.
        let halation = try container.decodeIfPresent(Int.self, forKey: .halation) ?? Self.defaultHalation
        self.halation = min(max(halation, Self.halationRange.lowerBound), Self.halationRange.upperBound)
    }

    /// Halation is written only off the stock's own, so a develop's record at it keeps the bytes it had before the control
    /// existed, which the golden recipes hold (`LightCompilerGoldenRecipeTests`, `MaskRecipeBytesTests`).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(size, forKey: .size)
        try container.encode(space, forKey: .space)
        try container.encode(grain, forKey: .grain)
        try container.encode(quality, forKey: .quality)
        if halation != Self.defaultHalation { try container.encode(halation, forKey: .halation) }
    }
}

/// A frame's recipe: everything needed to develop it again from the raw alone, and a record
/// of each develop. It is a versioned JSON file beside the raw, `DSC00601.argent` for
/// `DSC00601.ARW`, so a roll's recipes travel with it.
public struct Recipe: Sendable, Equatable, Codable {
    public static let fileExtension = "argent"
    public static let formatName = "camera.argent.recipe"
    public static let currentVersion = 15
    /// Develops kept in the record, newest last.
    public static let keptDevelops = 20

    /// The raw file the recipe belongs to.
    public struct Raw: Sendable, Equatable, Codable {
        public var fileName: String
        public var byteCount: Int
        public var captureDate: Date?
        /// SHA-256 of the whole file, filled in by a develop: what tells that the raw is still the
        /// one the measurement and the develops were made from (`RecipeStore.match`).
        public var sha256: String?
    }

    /// The stock, by id, with a digest of its baked tables so a later bake is visible.
    public struct StockReference: Sendable, Equatable, Codable {
        public var id: String
        public var displayName: String
        public var status: String
        public var boxSpeed: Float
        public var digest: String
    }

    /// What the render graph is given, resolved from the controls, so the recipe develops
    /// the same frame even if a later version maps a control differently.
    public struct Render: Sendable, Equatable, Codable {
        /// The film speed the negative is exposed for, `nil` at box speed.
        public var ratedAt: Float?
        /// Print exposure per channel in paper stops, red, green, blue.
        public var labBalance: [Float]
        public var printExposure: Float
        /// "natural" or "off".
        public var grain: String
        public var halation: String
        /// The multiple of the stock's halation the frame was given (`DevelopSettings.halationAmount`); absent at 1,
        /// the stock's own, as every render had before the Halation control existed.
        public var halationAmount: Float?
        /// Which grain the frame gets, from its name and capture time.
        public var grainSeed: UInt32?
        /// Capture sharpening: "on", or absent for a develop made without it, as every develop
        /// was before it existed, so such a develop is made again.
        public var sharpen: String?
        /// Absent or identity in legacy recipes; nonzero mappings carry their compiler version.
        public var manual: ManualRenderSettings?
        /// Auto's tone step; absent where it had none, as every render had before it existed.
        public var tone: PrintTone?
        /// Auto's own Presence finish (such as Neutral's polish); absent where it had none.
        public var autoPresence: AutoPresence?

        public init(ratedAt: Float?, labBalance: [Float], printExposure: Float, grain: String,
                    halation: String, halationAmount: Float? = nil, grainSeed: UInt32? = nil, sharpen: String? = nil,
                    manual: ManualRenderSettings? = nil, tone: PrintTone? = nil, autoPresence: AutoPresence? = nil) {
            self.ratedAt = ratedAt
            self.labBalance = labBalance
            self.printExposure = printExposure
            self.grain = grain
            self.halation = halation
            self.halationAmount = halationAmount == 1 ? nil : halationAmount
            self.grainSeed = grainSeed
            self.sharpen = sharpen
            self.manual = manual?.adjustments.isIdentity == true ? nil : manual
            self.tone = tone?.isActive == true ? tone : nil
            self.autoPresence = autoPresence?.isActive == true ? autoPresence : nil
        }

        public init(settings: DevelopSettings, grain: OutputSettings.Grain) {
            self.init(ratedAt: settings.ratedAt,
                      labBalance: [settings.labBalance.x, settings.labBalance.y, settings.labBalance.z],
                      printExposure: settings.printExposure, grain: grain.rawValue,
                      halation: settings.halation ? "on" : "off", halationAmount: settings.halation ? settings.halationAmount : nil,
                      grainSeed: grain == .off ? nil : settings.grainSeed,
                      sharpen: settings.sharpen ? "on" : nil, manual: settings.manual, tone: settings.tone,
                      autoPresence: settings.autoPresence)
        }

        public static func == (lhs: Render, rhs: Render) -> Bool {
            lhs.ratedAt == rhs.ratedAt && lhs.labBalance == rhs.labBalance
                && lhs.printExposure == rhs.printExposure && lhs.grain == rhs.grain
                && lhs.halation == rhs.halation && (lhs.halationAmount ?? 1) == (rhs.halationAmount ?? 1)
                && lhs.grainSeed == rhs.grainSeed && lhs.sharpen == rhs.sharpen
                && (lhs.manual ?? .identity) == (rhs.manual ?? .identity) && lhs.tone == rhs.tone
                && (lhs.autoPresence ?? .identity) == (rhs.autoPresence ?? .identity)
        }

        /// The render as a develop receipt keeps it (`Recipe.encoded()`).
        var receipt: Render {
            var kept = self
            kept.manual = manual?.digestingMasks()
            return kept
        }

        public var settings: DevelopSettings {
            DevelopSettings(ratedAt: ratedAt,
                            labBalance: labBalance.count == 3 ? SIMD3(labBalance[0], labBalance[1], labBalance[2]) : .zero,
                            printExposure: printExposure,
                            grain: OutputSettings.Grain(rawValue: grain)?.amount ?? 0, grainSeed: grainSeed ?? 0,
                            halation: halation == "on", halationAmount: halationAmount ?? 1, sharpen: sharpen == "on",
                            manual: manual ?? .identity, tone: tone ?? .identity,
                            autoPresence: autoPresence ?? .identity)
        }
    }

    /// One develop of the frame.
    public struct Develop: Sendable, Equatable, Codable {
        public var date: Date
        /// The app and its version, for example "Argent 0.1.0".
        public var software: String
        public var output: OutputSettings
        /// Where the file was written.
        public var file: String
        public var width: Int
        public var height: Int
        /// The settings the frame was developed with, which the next develop compares.
        public var render: Render
        /// What the decoder was set to and what it reported, so decoder drift is visible.
        public var decode: DecodePins?
        public var readback: DecodeReadback?
        /// The stock's digest when it was developed.
        public var stockDigest: String
        /// The render graph's version (`RenderGraph.version`); absent for a develop made before
        /// it was recorded, so such a develop is made again.
        public var renderVersion: String?
        /// The decoder this develop was meant for when it failed on the file and RAW 8 made it
        /// instead (`InHouseDecoder.version`, or RAW 9's 9), so the next develop does not try it
        /// again; absent when the decoder meant made it.
        public var fallbackFrom: String?
        /// Detect an output replaced by an older binary or another application. Absent on v1. Its device
        /// is not compared, which a share mounted again gives anew.
        public var outputSource: SourceStamp? = nil
        /// The revision of the roll's settled Auto decision the frame was developed at
        /// (`AutoDecisions`; docs/research/auto/sequence-consistency.md, stage 4), so a develop at
        /// another revision is made again. Absent for a develop made before decisions were settled,
        /// which still matches.
        public var autoRevision: String? = nil
        /// The raw the frame was developed from, and its version then; absent for a develop made
        /// before they were recorded.
        public var rawFile: String? = nil
        public var rawSource: SourceStamp? = nil

        /// Whether this develop's file is `frame`'s: made from its raw, or from a raw no longer where
        /// it was, as a moved roll's is, even when another file has since taken its path. A copy of the
        /// roll shares its edits but not its files while the raw it was copied from is still there.
        public func belongs(to frame: Frame) -> Bool {
            guard let rawFile, let rawSource, rawFile.canonicalPath != frame.url.canonicalPath else { return true }
            return SourceStamp.of(URL(fileURLWithPath: rawFile)).map(rawSource.isSameFile(atSamePathAs:)) != true
        }
    }

    public var format: String
    public var version: Int
    public var raw: Raw
    public var stock: StockReference
    /// The roll's own Rated at and Lab balance when the recipe was written.
    public var roll: RollControls
    /// The frame's own, where it differs from the roll.
    public var frame: FrameControls
    /// The roll's stock, by id, when the frame develops through its own (`frame.stock`): `stock` is
    /// then the frame's, and this keeps the roll's for reopening the roll. Absent otherwise.
    public var rollStock: String?
    /// What auto development measured in the frame; its print exposure is in `render`.
    public var analysis: ExposureAnalysis?
    /// The level the print followed, in scene stops against mid-gray, after roll smoothing.
    public var printLevel: Float?
    /// The cast auto lab balance worked from, red, green and blue stops, after roll smoothing.
    public var printCast: [Float]?
    public var render: Render
    public var develops: [Develop]
    public var manual: ManualEdit?
    /// Refinements from a replaced RAW, preserved as intent without attaching its old pin.
    public var heldManual: ManualEdit?
    public var editRevision: UInt64?
    public var editLineage: String?
    public var editDate: Date?

    /// The recipe for `frame` through `stock` on a roll set to `roll`, measured as
    /// `analysis` and printed at `level` (the frame's own bounded level when not given),
    /// keeping the develop record of `previous` while the raw is as large as it was. `sharpen`
    /// is capture sharpening, which the app's develops always have. Whether a raw of the same
    /// size is the same raw is for `RecipeStore.read(for:)` and the develop to tell, from its bytes.
    /// `stock` is the one the frame develops through, its own where it has one (`own.stock`), and
    /// `rollStock` the roll's id, kept only then; `grain` and `halation` are the roll's, which the frame's own replace.
    public init(frame: Frame, byteCount: Int, stock: Stock, stockDigest: String, roll: RollControls,
                own: FrameControls, rollStock: String? = nil, analysis: ExposureAnalysis? = nil, aim: PrintAim? = nil,
                grain: OutputSettings.Grain = .off, halation: Int = OutputSettings.defaultHalation, sharpen: Bool = false,
                previous: Recipe? = nil, manual: ManualEdit? = nil, editRevision: UInt64? = nil, editLineage: String? = nil,
                heldManual: ManualEdit? = nil, resolved: DevelopSettings? = nil) {
        let grain = own.grain ?? grain
        format = Self.formatName
        version = 2
        // A raw of another size is another raw: nothing recorded of the old one carries over.
        let sameSize = previous?.raw.byteCount == byteCount
        raw = Raw(fileName: frame.url.lastPathComponent, byteCount: byteCount, captureDate: frame.info.captureDate,
                  sha256: sameSize ? previous?.raw.sha256 : nil)
        self.stock = StockReference(id: stock.id, displayName: stock.displayName, status: stock.status,
                                    boxSpeed: stock.boxSpeed, digest: stockDigest)
        self.roll = roll
        self.frame = own
        self.rollStock = own.stock == nil ? nil : rollStock
        self.analysis = analysis
        let aim = manual?.baseline.aim ?? aim ?? AutoPrint.aim(analysis)
        let measured = analysis != nil || aim != PrintAim()
        printLevel = measured ? aim.level : nil
        printCast = measured ? [aim.cast.x, aim.cast.y, aim.cast.z] : nil
        let settings = resolved ?? own.applied(to: roll).settings(for: stock, aim: manual?.baseline.aim ?? aim)
        var recorded = settings
        recorded.grain = grain.amount
        recorded.grainSeed = frame.grainSeed
        recorded.halation = stock.halation != nil
        // A stock without halation records none of the control, which does nothing to it.
        recorded.halationAmount = recorded.halation ? OutputSettings.halationAmount(own.halation ?? halation) : 1
        recorded.sharpen = sharpen
        render = Render(settings: recorded, grain: grain)
        self.manual = manual
        self.heldManual = heldManual
        self.editRevision = editRevision
        self.editLineage = editLineage ?? (sameSize ? previous?.editLineage : nil)
        editDate = sameSize ? previous?.editDate : nil
        develops = sameSize ? previous?.develops ?? [] : []
        version = requiredVersion
    }

    /// Builds the complete reproducible render, propagating incompatible baseline and curve errors.
    public static func make(frame: Frame, byteCount: Int, stock: Stock, stockDigest: String, roll: RollControls,
                            own: FrameControls, rollStock: String? = nil, analysis: ExposureAnalysis? = nil, aim: PrintAim? = nil,
                            grain: OutputSettings.Grain = .off, halation: Int = OutputSettings.defaultHalation,
                            sharpen: Bool = false, previous: Recipe? = nil,
                            manual: ManualEdit? = nil, editRevision: UInt64? = nil, editLineage: String? = nil,
                            heldManual: ManualEdit? = nil) throws -> Recipe {
        let aim = aim ?? AutoPrint.aim(analysis)
        let settings = try DevelopmentResolver.resolve(stock: stock, stockDigest: stockDigest,
            controls: own.applied(to: roll), aim: aim, manual: manual, grain: (own.grain ?? grain).amount,
            halation: OutputSettings.halationAmount(own.halation ?? halation), grainSeed: frame.grainSeed, sharpen: sharpen)
        return Recipe(frame: frame, byteCount: byteCount, stock: stock, stockDigest: stockDigest, roll: roll,
                      own: own, rollStock: rollStock, analysis: analysis, aim: aim, grain: grain, halation: halation,
                      sharpen: sharpen, previous: previous,
                      manual: manual, editRevision: editRevision, editLineage: editLineage, heldManual: heldManual, resolved: settings)
    }

    /// The recipe without what it knows of its raw's content, for a raw that is no longer the
    /// file it was made from: no measurement, print level or cast, no develops and no hashes.
    /// The stock and the controls are the user's choices for the frame and stay.
    public func forgettingSource() -> Recipe {
        var recipe = forgettingMeasurement().forgettingDevelops()
        recipe.manual = nil
        recipe.render.manual = nil
        recipe.editRevision = nil
        recipe.editLineage = nil
        recipe.editDate = nil
        return recipe
    }

    /// The recipe without its develops and the hash of the raw they were made from.
    func forgettingDevelops() -> Recipe {
        var recipe = self
        recipe.develops = []
        recipe.raw.sha256 = nil
        return recipe
    }

    /// Whether the recipe holds a measurement of its raw: what auto development measured, or the
    /// print level and cast it led to.
    public var isMeasured: Bool { analysis != nil || printLevel != nil || printCast != nil }

    /// The recipe without its measurement, print level and cast, for a raw not yet shown to be
    /// the file they were measured from. The develops stay for a develop to check.
    public func forgettingMeasurement() -> Recipe {
        var recipe = self
        recipe.analysis = nil
        recipe.printLevel = nil
        recipe.printCast = nil
        // An unverified source must never inherit an automatic pin or its refinements.
        recipe.manual = nil
        recipe.render.manual = nil
        recipe.render.autoPresence = nil
        return recipe
    }

    /// Whether the newest develop is this recipe's: the same settings through the same stock,
    /// to `file` with `output`, decoded by `decoderVersion` with the decoder pinned and the render
    /// graph versioned as this build pins and versions them. Such a develop is skipped when its
    /// file is there. The decoder is RAW 8 unless said otherwise; a develop passes the decoder
    /// the frame goes to (`DecoderChoices.decoderVersion(for:)`), RAW 9 records 9 and the in-house
    /// decoder `InHouseDecoder.version`, and a develop from another decoder is made again, unless
    /// that decoder was meant and failed on the file (`Develop.fallbackFrom`). A develop at another
    /// settled Auto decision than `autoRevision` is made again; one that recorded none matches.
    public func lastDevelopMatches(file: URL, output: OutputSettings,
                                   decoderVersion: String = AppleRawDecoder.pinnedDecoderVersion,
                                   autoRevision: String? = nil, lens: ResolvedLensCorrection? = nil) -> Bool {
        guard let last = develops.last else { return false }
        return last.file.canonicalPath == file.canonicalPath && last.output.makesTheSameFile(as: output) && last.render == render
            && last.stockDigest == stock.digest && last.decode?.version == DecodePins.currentVersion
            && (last.decode?.decoderVersion == decoderVersion || last.fallbackFrom == decoderVersion)
            && (last.renderVersion == RenderGraph.version(for: render.settings, lens: lens)
                || (!RenderGraph.namesLens(last.renderVersion)
                    && last.renderVersion == RenderGraph.version(for: render.settings)
                    && last.decode?.lensCorrection == true))
            && (last.outputSource.map { recorded in SourceStamp.of(file).map(recorded.isSameVersion(atSamePathAs:)) == true } ?? true)
            && (last.autoRevision.map { $0 == autoRevision } ?? true)
    }

    /// Reads existing ISO 8601 millisecond dates, including recipes written before dates were
    /// formatted from an integer millisecond identity.
    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondsStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    private static func milliseconds(_ date: Date) -> Int64? {
        Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Formatting a fractional Date directly can lose a millisecond after ISO parsing. Format
    /// the whole second and append its integer fraction so repeated recipe saves keep the date.
    private static func dateString(_ date: Date) -> String? {
        guard let milliseconds = Self.milliseconds(date) else { return nil }
        var seconds = milliseconds / 1000, fraction = milliseconds % 1000
        if fraction < 0 { seconds -= 1; fraction += 1000 }
        let whole = Date(timeIntervalSince1970: Double(seconds)).formatted(wholeSecondsStyle)
        return String(whole.dropLast()) + String(format: ".%03lldZ", fraction)
    }

    /// Receipts are serialized with millisecond dates. Compare that same identity when
    /// retrying an operation, so an in-memory nanosecond date does not duplicate its record.
    static func sameDevelopReceipt(_ a: Develop, _ b: Develop) -> Bool {
        guard let aMilliseconds = milliseconds(a.date), let bMilliseconds = milliseconds(b.date) else { return false }
        var compared = a
        compared.date = b.date
        return compared == b && aMilliseconds == bMilliseconds
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            guard let timestamp = Self.dateString(date) else {
                throw EncodingError.invalidValue(date, .init(codingPath: encoder.codingPath,
                    debugDescription: "Recipe dates must fit an integer millisecond timestamp."))
            }
            try container.encode(timestamp)
        }
        // Receipts keep the digest of a mask set and never the set: a develop's comparison needs no more, and twenty
        // copies of a brush's points would be twenty times the record.
        var written = self
        written.develops = develops.map { develop in
            var receipt = develop
            receipt.render = develop.render.receipt
            return receipt
        }
        return try encoder.encode(written)
    }

    public enum ReadFailure: Error, LocalizedError, Equatable {
        case wrongFormat
        case unsupportedVersion(Int)
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .wrongFormat: return "This file is not an Argent recipe."
            case .unsupportedVersion(let version): return "This recipe requires Argent recipe version \(version); it has been preserved."
            case .invalid(let reason): return "This recipe could not be read: \(reason). It has been preserved."
            }
        }
    }

    /// Read errors are distinct from missing files so an incompatible recipe cannot be overwritten.
    public static func decodeStrict(_ data: Data) throws -> Recipe { try decodeStrict(data, readerVersion: currentVersion) }

    /// The read of a build whose newest recipe version is `readerVersion`: what an older build does with a record this one writes.
    static func decodeStrict(_ data: Data, readerVersion: Int) throws -> Recipe {
        struct Header: Decodable { var format: String; var version: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: dateStyle) { return date }
            return try Date(text, strategy: .iso8601)
        }
        do {
            let header = try decoder.decode(Header.self, from: data)
            guard header.format == formatName else { throw ReadFailure.wrongFormat }
            guard (1...readerVersion).contains(header.version) else { throw ReadFailure.unsupportedVersion(header.version) }
            let recipe = try decoder.decode(Recipe.self, from: data)
            try recipe.validate()
            return recipe
        } catch let failure as ReadFailure {
            throw failure
        } catch {
            throw ReadFailure.invalid(error.localizedDescription)
        }
    }

    public func validate() throws {
        guard format == Self.formatName else { throw ReadFailure.wrongFormat }
        guard (1...Self.currentVersion).contains(version) else { throw ReadFailure.unsupportedVersion(version) }
        guard version >= requiredVersion || (version == 1 && requiredVersion == 2) else {
            throw ReadFailure.invalid(requiredVersion == 15 ? "Automatic Presence requires recipe version 15"
                                      : requiredVersion == 14 ? "a Halation amount requires recipe version 14"
                                      : requiredVersion == 13 ? "a frame's own stock or grain requires recipe version 13"
                                      : requiredVersion == 12 ? "a removal requires recipe version 12"
                                      : requiredVersion == 11 ? "Vignetting requires recipe version 11"
                                      : requiredVersion == 10 ? "Defringe requires recipe version 10"
                                      : requiredVersion == 9 ? "Lens settings require recipe version 9"
                                      : requiredVersion == 8 ? "the lens stage requires recipe version 8"
                                      : requiredVersion == 7 ? "Presence requires recipe version 7"
                                      : requiredVersion == 6 ? "masks require recipe version 6"
                                      : requiredVersion == 5 ? "a tone step requires recipe version 5"
                                      : requiredVersion == 4 ? "an Original starting point requires recipe version 4"
                                      : "curve refinements require recipe version 3")
        }
        // Halation inside the control's range: a frame's own, and every amount a render records, which is that range over 100.
        let range = OutputSettings.halationRange
        let amounts = ([render] + develops.map(\.render) + [manual, heldManual].compactMap { $0?.baseline.baseRender })
            .compactMap(\.halationAmount)
        let most = OutputSettings.halationAmount(range.upperBound)
        guard frame.halation.map(range.contains) ?? true, amounts.allSatisfy({ $0 >= 0 && $0 <= most }) else {
            throw ReadFailure.invalid("Halation must be from \(range.lowerBound) to \(range.upperBound)")
        }
        func valid(_ render: Render) -> Bool {
            render.labBalance.count == 3 && render.labBalance.allSatisfy(\.isFinite)
                && render.printExposure.isFinite && (render.ratedAt.map { $0.isFinite && $0 > 0 } ?? true)
                && (render.autoPresence.map { $0.referenceStops.isFinite && (-32...32).contains($0.referenceStops) } ?? true)
        }
        guard valid(render), develops.allSatisfy({ valid($0.render) }) else { throw ReadFailure.invalid("non-finite render values") }
        // Only a receipt may hold a digest: what the frame renders now keeps its masks in full.
        let current = [manual?.adjustments.masks, heldManual?.adjustments.masks, render.manual?.adjustments.masks].compactMap { $0 }
        guard !current.contains(where: \.isDigestOnly) else { throw ReadFailure.invalid("an edit's masks are missing") }
        func validateBaseline(_ manual: ManualEdit) throws {
            let baseline = manual.baseline
            guard baseline.sourceSHA256.count == 64, baseline.sourceSHA256.allSatisfy({ $0.isHexDigit }),
                  baseline.aim.level.isFinite, baseline.aim.cast.x.isFinite, baseline.aim.cast.y.isFinite,
                  baseline.aim.cast.z.isFinite, valid(baseline.baseRender) else { throw ReadFailure.invalid("invalid automatic baseline") }
            guard baseline.isConsistent else { throw ReadFailure.invalid("an Original starting point must be at the neutral aim") }
        }
        if let manual {
            guard manual.adjustments.isIdentity || (render.manual?.adjustments == manual.adjustments
                && render.manual?.version == manual.curveVersion) else {
                throw ReadFailure.invalid("manual values do not match the resolved render")
            }
            try validateBaseline(manual)
        }
        if let heldManual { try validateBaseline(heldManual) }

    }

    /// v2 remains sufficient for slider-only records. Curve intent and historical curve
    /// receipts require v3 so a v2 reader cannot silently discard their new fields. An Original
    /// starting point, current or held, requires v4 so a v3 reader cannot take it for an Auto pin.
    /// Receipts need not: each keeps the resolved values its file was made with. Masks anywhere, a
    /// receipt's digest included, require v6; a record with none stays at the version it needed before. Presence anywhere, a receipt
    /// included, requires v7, ahead of masks. A frame's own stock or grain requires v13: an older build would
    /// develop it through the roll's, reopen the roll on the frame's stock, and save the frame back without either.
    /// A frame's own Halation, or a render at any amount but the stock's own, a receipt's included, requires v14: an
    /// older build would print it at the stock's, and take a file developed at another amount for the one it makes. An
    /// amount written out as 1 is the stock's own, and requires nothing.
    public var requiredVersion: Int {
        let renders = [render, manual?.baseline.baseRender, heldManual?.baseline.baseRender].compactMap { $0 }
            + develops.map(\.render)
        if renders.contains(where: { $0.autoPresence != nil }) { return 15 }
        if frame.halation != nil || renders.contains(where: { ($0.halationAmount ?? 1) != 1 }) { return 14 }
        if frame.stock != nil || frame.grain != nil || rollStock != nil { return 13 }
        let lenses = [manual?.adjustments.lens, heldManual?.adjustments.lens].compactMap { $0 }
            + renders.compactMap { $0.manual?.adjustments.lens }
        // A build without Remove would print such a recipe with the object back in it, and could save it without its removals.
        if lenses.contains(where: { !$0.removals.isEmpty }) { return 12 }
        if lenses.contains(where: { $0.vignetting.amount != 0 }) { return 11 }
        if lenses.contains(where: { !$0.defringe.isDefault }) { return 10 }
        if lenses.contains(where: { !$0.isDefault }) { return 9 }
        if develops.contains(where: { RenderGraph.namesLens($0.renderVersion) }) { return 8 }
        // A build without Presence would print such a recipe without it, and could save it back without it, unnoticed.
        let presence = [manual?.adjustments.presence, heldManual?.adjustments.presence].compactMap { $0 }
            + renders.compactMap { $0.manual?.adjustments.presence }
        if presence.contains(where: { !$0.isIdentity }) { return 7 }
        // A build without masks would print such a recipe without them, unnoticed.
        let masks = [manual?.adjustments.masks, heldManual?.adjustments.masks].compactMap { $0 }
            + renders.compactMap { $0.manual?.adjustments.masks }
        if masks.contains(where: { !$0.isEmpty }) { return 6 }
        // A build without the tone step would print such a recipe without it, unnoticed.
        if renders.contains(where: { $0.tone != nil }) { return 5 }
        if manual?.baseline.origin == .original || heldManual?.baseline.origin == .original { return 4 }
        let curves = [manual?.adjustments.curves, heldManual?.adjustments.curves].compactMap { $0 }
            + renders.compactMap { $0.manual?.adjustments.curves }
        return curves.contains(where: { !$0.isIdentity }) ? 3 : 2
    }

    /// The record in `data`, or `nil` when it cannot be read: for callers that treat an unreadable
    /// record as none, as `RecipeStore.stored(for:byteCount:library:)` does.
    public static func decoded(_ data: Data) -> Recipe? { try? decodeStrict(data) }

}

extension Stock {
    /// SHA-256 of the baked tables and the numbers that join them, so a recipe can tell
    /// whether the stock it names is still the stock it was developed through. The grain table
    /// and the halation values count too, each behind its own marker, since a re-bake can change
    /// them alone; a stock without them hashes as it did before they existed.
    public var digest: String {
        var hash = SHA256()
        hash.update(data: negative.binaryData())
        hash.update(data: print.binaryData())
        let numbers = [boxSpeed, densityRange, exposurePerUnit.x, exposurePerUnit.y, exposurePerUnit.z]
        numbers.withUnsafeBufferPointer { hash.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        if let grain {
            hash.update(data: Data("grain".utf8))
            let rows = zip(grain.amounts, grain.sigma48).flatMap { $0 + $1 }
            rows.withUnsafeBufferPointer { hash.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        }
        if let halation {
            hash.update(data: Data("halation".utf8))
            let values = [halation.strength, halation.greenShare, halation.radiusMicrometres]
            values.withUnsafeBufferPointer { hash.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Where recipes live: beside the raw, or, where the raw's folder cannot be written (a
/// locked card), in the app's library.
public enum RecipeStore {
    /// `DSC00601.argent` for `DSC00601.ARW`.
    public static func besideRaw(_ raw: URL) -> URL {
        raw.deletingPathExtension().appendingPathExtension(Recipe.fileExtension)
    }

    /// The seeds of the masks the sidecar names, which travel with it: `DSC00601.argentmasks` for
    /// `DSC00601.argent` (`MaskRasterStore.writePack`), so a moved roll keeps its masks.
    public static func masksBesideRaw(_ raw: URL) -> URL {
        raw.deletingPathExtension().appendingPathExtension(MaskRasterStore.packExtension)
    }

    /// The patches of the removals the sidecar names, which travel with it as the masks' seeds do: `DSC00601.argentpatches` for
    /// `DSC00601.argent` (`PatchStore.writePack`), so a moved roll keeps what was removed (docs/remove-plan.md, section 4.7).
    public static func patchesBesideRaw(_ raw: URL) -> URL {
        raw.deletingPathExtension().appendingPathExtension(PatchStore.packExtension)
    }

    /// The app's own copy, named by what identifies the raw without reading it whole: its
    /// name, size and capture time.
    public static func inLibrary(_ frame: Frame, byteCount: Int, library: URL) -> URL {
        let stamp = frame.info.captureDate.map { String(Int(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "0"
        return library.appendingPathComponent("\(frame.name)-\(byteCount)-\(stamp)").appendingPathExtension(Recipe.fileExtension)
    }

    /// The app's library of recipes, in Application Support; a test process may not use it
    /// (`ApplicationSupport`).
    public static var defaultLibrary: URL {
        ApplicationSupport.folder.appendingPathComponent("Recipes", isDirectory: true)
    }

    /// The file's size as it is now. A URL keeps the resource values it was asked for, so the
    /// frame's own URL would give a raw replaced since it was asked the old raw's size.
    public static func byteCount(of url: URL) -> Int {
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// The frame's recipe, from beside the raw or else from the library, with only what still
    /// holds for the raw there now, its raw read whole if need be; see `checked(for:library:digests:check:)`.
    public static func read(for frame: Frame, library: URL = defaultLibrary, digests: SourceDigests = .shared) -> Recipe? {
        checked(for: frame, library: library, digests: digests)?.recipe
    }

    /// A recipe as it holds for the raw beside it now, and the version of the raw its measurement
    /// was checked against.
    public struct Checked: Sendable, Equatable {
        public var recipe: Recipe
        /// The raw's version when its SHA-256 was found to be the recipe's; `nil` when it was not,
        /// and the recipe then has no measurement.
        public var source: SourceStamp?

        public init(recipe: Recipe, source: SourceStamp?) {
            self.recipe = recipe
            self.source = source
        }
    }

    /// How far a check goes to tell whether a raw is its recipe's.
    public enum Check: Sendable {
        /// Reads the raw whole when `SourceDigests` does not know its version's SHA-256.
        case readingWhole
        /// Only what `SourceDigests` already knows: a raw whose version it does not know is
        /// `.unknown`, and no raw is read. For opening a roll, whose window cannot wait for its
        /// raws to be read whole; the frames are measured again from their decodes instead.
        case knownOnly
    }

    /// The frame's recipe, from beside the raw or else from the library, with only what still
    /// holds for the raw there now (`SourceMatch`): all of it for the raw it was made from, its
    /// settings alone for another raw under the same name, and everything but its measurement for
    /// a raw it cannot tell, whose develops a develop checks. Reads the raw whole when the
    /// recipe has a SHA-256 and `digests` does not know the raw's version yet, unless `check`
    /// is `.knownOnly`.
    public static func checked(for frame: Frame, library: URL = defaultLibrary, digests: SourceDigests = .shared,
                               check: Check = .readingWhole) -> Checked? {
        let size = byteCount(of: frame.url)
        guard let recipe = stored(for: frame, byteCount: size, library: library) else { return nil }
        switch match(recipe.raw, to: frame.url, byteCount: size, digests: digests, check: check) {
        case .same(let source): return Checked(recipe: recipe, source: source)
        case .different: return Checked(recipe: recipe.forgettingSource(), source: nil)
        case .unknown: return Checked(recipe: recipe.forgettingMeasurement(), source: nil)
        }
    }

    /// Each frame's recipe as `checked(for:library:digests:check:)` gives it, `lanes` frames at
    /// once; frames not reached once `stopped` says so have none.
    public static func checked(for frames: [Frame], library: URL = defaultLibrary, digests: SourceDigests = .shared,
                               check: Check = .readingWhole, lanes: Int = RollDeveloper.checkLanes,
                               stopped: @Sendable () -> Bool = { false }) -> [Checked?] {
        let found = Slots<Checked?>(frames.map { _ in nil })
        let next = Ticket()
        DispatchQueue.concurrentPerform(iterations: max(1, min(lanes, frames.count))) { _ in
            while !stopped(), let index = next.take(below: frames.count) {
                found.set(index, checked(for: frames[index], library: library, digests: digests, check: check))
            }
        }
        return found.all
    }

    /// The frame's recipe as it was written, from beside the raw or else from the library.
    static func stored(for frame: Frame, byteCount size: Int, library: URL) -> Recipe? {
        if let data = try? Data(contentsOf: besideRaw(frame.url)), let recipe = Recipe.decoded(data),
           recipe.raw.fileName == frame.url.lastPathComponent {
            return recipe
        }
        if let data = try? Data(contentsOf: inLibrary(frame, byteCount: size, library: library)) {
            return Recipe.decoded(data)
        }
        return nil
    }

    /// Whether a recipe's raw is the file at a URL.
    public enum SourceMatch: Sendable, Equatable {
        /// The same SHA-256, the raw read whole at this version.
        case same(SourceStamp)
        /// Another size or another SHA-256: another raw under the recipe's name.
        case different
        /// No SHA-256 to compare, from a recipe never developed, a raw that cannot be read whole, or
        /// one not read under `.knownOnly`.
        case unknown
    }

    /// How `raw` compares with the file at `url`, `byteCount` bytes long when given: by size, then
    /// by the SHA-256 of the whole file, which `digests` reads unless it knows the file's version or
    /// `check` is `.knownOnly`.
    public static func match(_ raw: Recipe.Raw, to url: URL, byteCount size: Int? = nil,
                             digests: SourceDigests = .shared, check: Check = .readingWhole) -> SourceMatch {
        guard raw.byteCount == size ?? byteCount(of: url) else { return .different }
        guard let recorded = raw.sha256 else { return .unknown }
        let known = check == .knownOnly ? digests.known(url) : try? digests.digest(of: url)
        guard let now = known else { return .unknown }
        return recorded == now.sha256 ? .same(now.source) : .different
    }

    /// Writes `recipe` beside the raw. When the raw's folder cannot be written it goes to the
    /// library instead. Returns where it went.
    @discardableResult
    public static func write(_ recipe: Recipe, for frame: Frame,
                             library: URL = defaultLibrary) throws -> [URL] {
        let data = try recipe.encoded()
        let beside = besideRaw(frame.url)
        do {
            try data.write(to: beside, options: .atomic)
            return [beside]
        } catch {
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let kept = inLibrary(frame, byteCount: recipe.raw.byteCount, library: library)
            try data.write(to: kept, options: .atomic)
            return [kept]
        }
    }

    /// SHA-256 of a file read whole, a megabyte at a time, and not kept; throws when the file
    /// cannot be read to its end or changes while it is read.
    public static func sha256(of url: URL) throws -> String {
        try SourceDigests.read(url).sha256
    }
}

/// What a roll's recipes say about how it was last set up, for opening it again as it was
/// left: the stock and the roll's controls from the most recently developed recipe, each
/// frame's own controls from its recipe, and the folder the roll last developed to.
public struct RestoredRoll: Sendable, Equatable {
    public var stockID: String?
    public var controls: RollControls?
    public var overrides: [URL: FrameControls]
    public var destination: URL?
    /// Each frame's auto-development measurement, where its recipe has one this build makes.
    public var analyses: [URL: ExposureAnalysis]
    /// The version of each frame's raw its measurement in `analyses` was checked against, when
    /// the recipes came with it (`init(frames:checked:)`).
    public var sources: [URL: SourceStamp] = [:]
    public var manualEdits: [URL: ManualEdit] = [:]

    /// `checked[i]` is `frames[i]`'s recipe, if it has one, as `RecipeStore.checked(for:)` gives
    /// it; only a measurement checked against its raw is restored.
    public init(frames: [Frame], checked: [RecipeStore.Checked?]) {
        self.init(frames: frames, recipes: checked.map { $0?.recipe })
        let sources = zip(frames, checked).compactMap { frame, checked in checked?.source.map { (frame.url, $0) } }
        self.sources = Dictionary(sources, uniquingKeysWith: { a, _ in a })
        analyses = analyses.filter { self.sources[$0.key] != nil }
        manualEdits = manualEdits.filter { self.sources[$0.key] != nil }
    }

    /// `recipes[i]` is `frames[i]`'s recipe, if it has one, as `RecipeStore.read(for:)` gives it:
    /// without the measurement of a raw that is not shown to be the one measured.
    public init(frames: [Frame], recipes: [Recipe?]) {
        let found = zip(frames, recipes).compactMap { frame, recipe in recipe.map { (frame, $0) } }
        // Autosaved choices outrank export completion dates. Revisions are monotonic within
        // a roll session; edit dates break ties without export completion races.
        let newest = found.max { a, b in
            if a.1.editRevision != nil || b.1.editRevision != nil {
                let ar = a.1.editRevision ?? 0, br = b.1.editRevision ?? 0
                if ar != br { return ar < br }
                return (a.1.editDate ?? .distantPast) < (b.1.editDate ?? .distantPast)
            }
            return (a.1.develops.last?.date ?? .distantPast) < (b.1.develops.last?.date ?? .distantPast)
        }?.1
        // A frame with its own stock records the roll's beside it.
        stockID = newest.map { $0.frame.stock == nil ? $0.stock.id : $0.rollStock ?? $0.stock.id }
        controls = newest?.roll
        overrides = Dictionary(found.filter { !$0.1.frame.isEmpty }.map { ($0.0.url, $0.1.frame) }, uniquingKeysWith: { a, _ in a })
        // A freshly adjusted, never-exported frame can own the newest choices without
        // erasing the roll's previously used output folder.
        destination = found.compactMap { frame, recipe in recipe.develops.last { $0.belongs(to: frame) } }.max { $0.date < $1.date }
            .map { URL(fileURLWithPath: $0.file).deletingLastPathComponent() }
        manualEdits = Dictionary(found.compactMap { frame, recipe in
            recipe.manual.map { (frame.url, $0) }
        }, uniquingKeysWith: { a, _ in a })
        analyses = Dictionary(found.compactMap { frame, recipe in
            recipe.analysis.flatMap { $0.isCurrent ? (frame.url, $0) : nil }
        }, uniquingKeysWith: { a, _ in a })
    }
}

/// One value per index, set from many threads.
final class Slots<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value]
    init(_ values: [Value]) { self.values = values }
    func set(_ index: Int, _ value: Value) { lock.withLock { values[index] = value } }
    var all: [Value] { lock.withLock { values } }
}

/// Hands out indices in order, each once, to workers on many threads.
final class Ticket: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    func take(below count: Int) -> Int? {
        lock.withLock {
            guard next < count else { return nil }
            defer { next += 1 }
            return next
        }
    }
}
