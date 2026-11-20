import ArgentCore
import Foundation
import ImageIO
import Vision

/// The app's smart-mask engine: the frame's input picture from `FilmPreviews.maskInputPicture` (task A), Vision's requests on it
/// (`AppleSegmentation`, task B), the bundled models (`MaskModels`, task A), the water veto (`WaterVeto`, task B) and the new Subject (`SmartSeed.subject`). It makes nothing
/// on its own: `MaskInference` calls it, one click at a time, inside a turn it holds.
///
/// It keeps the last two frames' pictures, the input picture (18.6 MB with the models' contents, also kept by `FilmPreviews`) and
/// Vision's 8-bit copy of it (17.5 MB at 3:2), so the frame the Masks tab opened on and the one a run is on can differ without a
/// decode each time. `releasePictures` lets them go, as the tab closes and before a develop.
public final class BundledSmartMasks: SmartMaskEngine, @unchecked Sendable {
    /// What a run finds in: the input picture and Vision's one pixel path over it (`AppleSegmentation.Picture`).
    struct Picture: @unchecked Sendable {
        let key: String
        let input: MaskInputPicture
        let vision: AppleSegmentation.Picture
    }

    /// Pictures kept, most recent last.
    static let keptPictures = 2

    public let models: MaskModels
    private let films: FilmPreviews
    private let app: String
    private let lock = NSLock()
    private var pictures: [Picture] = []
    /// The pictures being made, each shared by whoever asks for it meanwhile and given up when nobody waits for it (`SharedWork`).
    private let making = SharedWork<String, Picture>()
    /// Whether the last `find` ran S3OD or ViTMatte, for the queue's settle after it.
    private var releasedModels = false

    /// `app` is what a seed's provenance records as its maker (`RollModel.software`).
    public init(films: FilmPreviews, models: MaskModels, app: String) {
        self.films = films
        self.models = models
        self.app = app
    }

    // MARK: Availability

    /// Sky needs its two bundled models (the veto is part of it, decision 4); the rest need Vision's requests at the revisions
    /// `AppleSegmentation` pins. Subject and Background need the Subject models too, and offer their download until they are here: there is no Vision
    /// stand-in (the owner, 2026-11-20).
    public func availability(of kind: SmartKind) -> SmartAvailability {
        switch kind {
        case .sky:
            guard models.isSkyAvailable else {
                return .unavailable("Sky needs the sky and water models, and this build of Argent was made without them.")
            }
            return Self.visionAvailability(VNClassifyImageRequest.self, revision: VNClassifyImageRequestRevision2, for: "Sky")
        case .subject, .background:
            if models.subjectMissing != nil { return .needsModels(Self.needsModels(kind)) }
            return Self.visionAvailability(VNGenerateForegroundInstanceMaskRequest.self,
                                           revision: VNGenerateForegroundInstanceMaskRequestRevision1, for: kind.title)
        case .person:
            return Self.visionAvailability(VNGeneratePersonSegmentationRequest.self,
                                           revision: VNGeneratePersonSegmentationRequestRevision1, for: "Person")
        }
    }

    public var pins: SmartModelPins {
        SmartModelPins(sky: (try? models.identity(of: .sky)).map(ModelProvenance.init), water: (try? models.identity(of: .water)).map(ModelProvenance.init),
                       skySquare: SkyModelRunner.squareRecipe,
                       subject: models.isSubjectAvailable ? (try? models.identity(of: .subject)).map(ModelProvenance.init) : nil,
                       matte: models.isSubjectAvailable ? (try? models.identity(of: .matte)).map(ModelProvenance.init) : nil)
    }

    /// The tile's words while the Subject models are not here.
    public static func needsModels(_ kind: SmartKind) -> String {
        "\(kind.title) needs the Subject models, a one-time download. Click to see their licences and download them."
    }

    private static func visionAvailability(_ request: VNRequest.Type, revision: Int, for title: String) -> SmartAvailability {
        request.supportedRevisions.contains(revision)
            ? .available : .unavailable("\(title) needs a Vision request this version of macOS does not have.")
    }

    // MARK: The picture

    /// The picture is made once for everyone who asks while it is being made: the tab's ask ahead and a click on the same frame
    /// share it. An asker whose task is cancelled lets go of it, and with nobody left waiting its decode is given up: skipped if it
    /// has not begun, dropped at its end if it has (`FilmPreviews.maskInputPicture`).
    public func picture(of frame: Frame, lens: LensSettings, stopped: @escaping @Sendable () -> Bool) async -> SmartPictureHandle? {
        let key = films.key(frame, lens: lens)
        if let found = lock.withLock({ pictures.last(where: { $0.key == key }) }) { return SmartPictureHandle(frame: frame.url, content: found) }
        let films = films
        let made = await making.value(for: key, priority: .userInitiated) { () -> Picture? in
            guard let input = await films.maskInputPicture(frame, lens: lens), let vision = try? AppleSegmentation.Picture(input.image) else {
                return nil
            }
            return Picture(key: key, input: input, vision: vision)
        }
        lock.withLock {
            if let made, !pictures.contains(where: { $0.key == key }) {
                pictures.append(made)
                if pictures.count > Self.keptPictures { pictures.removeFirst(pictures.count - Self.keptPictures) }
            }
        }
        guard let made, !stopped() else { return nil }
        return SmartPictureHandle(frame: frame.url, content: made)
    }

    public func releasePictures() { lock.withLock { pictures = [] } }

    // MARK: Finding

    public func find(_ kind: SmartKind, on handle: SmartPictureHandle, frame: Frame, sourceSHA256: String,
                     stage: @escaping @Sendable (SmartStage) -> Void) async throws -> (SmartResult, MaskFrame) {
        guard let picture = handle.content as? Picture else { throw MaskError.invalid("a picture this engine did not make") }
        let source = SeedSource(sourceSHA256: sourceSHA256, decoderVersion: picture.input.source.pinsDecoderVersion ?? picture.input.source.decoderVersion,
                                pinsVersion: picture.input.source.pinsVersion, app: app)
        let maskFrame = try Self.maskFrame(of: frame, picture: picture.input)
        switch kind {
        case .subject, .background: return (try await subject(picture, frame: frame, source: source, stage: stage), maskFrame)
        case .person: return (try AppleSegmentation.person(picture.vision, source: source), maskFrame)
        case .sky: return (try await sky(picture, source: source, stage: stage), maskFrame)
        }
    }

    /// The new Subject: the frozen design (`SmartSeed.subject`). Without S3OD, EoMT or ViTMatte it fails and says which: the tile offers the models first
    /// (`availability(of:)`). "Preparing masks" first when the models were not prepared for this Mac and macOS. S3OD and ViTMatte are loaded, run and let
    /// go inside the click.
    private func subject(_ picture: Picture, frame: Frame, source: SeedSource, stage: @escaping @Sendable (SmartStage) -> Void) async throws -> SmartResult {
        if let missing = models.subjectMissing { throw missing }
        let visionResult = try AppleSegmentation.subject(picture.vision, source: source)
        if models.needsPreparation {
            stage(.preparing(0))
            try await models.prepare { progress in stage(.preparing(progress.fraction)) }
            stage(.finding)
        }
        lock.withLock { releasedModels = true }
        let rule = LowLightRule.decide(Self.metadata(of: frame), medianLuminance: picture.input.medianLuminance)
        let models = models, input = picture.input
        let steps = SmartSeed.SubjectModels(
            region: ModelProvenance(try models.identity(of: .subject)), gate: ModelProvenance(try models.identity(of: .water)), matte: ModelProvenance(try models.identity(of: .matte)),
            runRegion: { try await models.subject(for: input) },
            runGate: { try await models.water(for: input) },
            runMatte: { try await models.matte(seed: $0, on: input) })
        return try await SmartSeed.subject(vision: visionResult, picture: picture.vision, source: source, rule: rule, models: steps)
    }

    /// What the raw says of its exposure: the frame's own header, and ImageIO's for whatever it lacks, as X2's harness read it (ISO under its several Exif keys).
    static func metadata(of frame: Frame) -> LowLightRule.Metadata {
        var meta = LowLightRule.Metadata(iso: frame.info.iso.map(Double.init), exposureTime: frame.info.exposureTime, fNumber: frame.info.fNumber)
        guard meta.iso == nil || meta.exposureTime == nil || meta.fNumber == nil,
              let source = CGImageSourceCreateWithURL(frame.url as CFURL, nil),
              let all = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return meta }
        let exif = all[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let isos = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Double])
            ?? [exif[kCGImagePropertyExifRecommendedExposureIndex], exif[kCGImagePropertyExifISOSpeed], exif[kCGImagePropertyExifStandardOutputSensitivity]].compactMap { $0 as? Double }
        if meta.iso == nil, let iso = isos.first { meta.iso = iso }
        if meta.exposureTime == nil { meta.exposureTime = exif[kCGImagePropertyExifExposureTime] as? Double }
        if meta.fNumber == nil { meta.fNumber = exif[kCGImagePropertyExifFNumber] as? Double }
        return meta
    }

    public func takeReleasedModels() -> Bool {
        lock.withLock {
            let released = releasedModels
            releasedModels = false
            return released
        }
    }

    /// DA3's seed (loaded if need be, and left loaded: the queue decides when it goes), Vision's water gate, and behind it EoMT,
    /// loaded, run and let go inside the click; then the veto (`SmartSeed.sky`). "Preparing masks" first when the models were not
    /// prepared for this Mac and macOS (on first use and after each update; a file read otherwise).
    private func sky(_ picture: Picture, source: SeedSource, stage: @escaping @Sendable (SmartStage) -> Void) async throws -> SmartResult {
        if models.needsPreparation {
            stage(.preparing(0))
            try await models.prepare { progress in stage(.preparing(progress.fraction)) }
            stage(.finding)
        }
        let outputs = try await models.sky(for: picture.input)
        let da3 = ModelProvenance(try models.identity(of: .sky))
        let crop = ModelSquare.crop(outputs.sky, planeSide: SkyModelRunner.side, layout: outputs.layout)
        let seed = try SkySeed(skyHead: crop, width: outputs.layout.contentWidth, height: outputs.layout.contentHeight, model: da3,
                               square: outputs.squareRecipe)
        let gate = try AppleSegmentation.waterScore(picture.vision)
        let models = models
        return try await SmartSeed.sky(seed, picture: picture.vision, source: source, gate: gate) {
            stage(.checkingWater)
            let maps = try await models.water(for: picture.input)
            let eomt = ModelProvenance(try models.identity(of: .water))
            return try WaterMap(side: EomtModelRunner.mapSide, values: maps.water, square: EomtModelRunner.side,
                                contentWidth: maps.layout.contentWidth, contentHeight: maps.layout.contentHeight,
                                originX: maps.layout.originX, originY: maps.layout.originY, model: eomt, mapsSHA256: maps.digest)
        }
    }

    public func unloadSky() async -> Bool {
        let loaded = await models.skyRunner.isLoaded
        if loaded { await models.unloadSky() }
        return loaded
    }

    /// The frame a seed was made on, as `MaskFrame` records it: the brush's rule (`FilmPreviews.maskFrame`) on the decode the
    /// input picture was made from.
    static func maskFrame(of frame: Frame, picture: MaskInputPicture) throws -> MaskFrame {
        let source = picture.source
        return try FilmPreviews.maskFrame(of: frame, pictureWidth: source.pictureWidth, pictureHeight: source.pictureHeight,
                                          decoderVersion: source.decoderVersion, lensCorrection: source.lensCorrection, geometry: source.geometry)
    }
}

extension ModelProvenance {
    /// What a seed's provenance records of a bundled model (`MaskModels.identity(of:)`).
    public init(_ identity: MaskModelIdentity) {
        self.init(recipeID: identity.recipeID, weightsSHA256: identity.weightsSHA256, canarySHA256: identity.canarySHA256,
                  fileSHA256: identity.fileSHA256, options: identity.options)
    }
}

extension SmartKind {
    /// In the panel's and the menus' words: "Sky".
    public var title: String { rawValue.capitalized }
}
