import CoreGraphics
import Foundation
import ImageIO
import Testing
import Vision
@testable import ArgentCore

/// The neutral print of a CC0 sample, made as masking plan section 3 says: the frame's own RAW 9 decode through
/// `LUT3D.neutralPrint`, 2560 px on the long side, as `argent-spike --decoder raw9 --long-edge 2560` made the prints R2, S4 and
/// S5 measured (a 16-bit TIFF here, not their JPEG). The app's picture is task A's, made in memory at the same point: delete
/// this helper when that lands and build the tests' picture with it.
enum NeutralPrintFixture {
    static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples")
    static let sample = samples.appendingPathComponent("ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW")
    static var hasSamples: Bool { FileManager.default.fileExists(atPath: sample.path) }

    /// Made once a process, since a RAW 9 decode takes about a second.
    static let print: Result<AppleSegmentation.Picture, any Error> = Result { try make(sample) }

    static func make(_ raw: URL) throws -> AppleSegmentation.Picture {
        let gpu = try GPU()
        let pipeline = try DevelopPipeline(gpu: gpu, decoder: AppleRawDecoder(gpu: gpu), lut: LUT3D.neutralPrint())
        var options = DecodeOptions()
        options.appleDecoder = .learned
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-neutral-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("print.tif")
        try pipeline.develop(raw, to: file, options: options, format: .tiff16, longEdge: 2560)
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw MaskError.invalid("the print can be read") }
        return try AppleSegmentation.Picture(image)
    }
}

/// Pictures and seeds made by hand.
private enum Make {
    static let model = ModelProvenance(recipeID: "da3-test", weightsSHA256: String(repeating: "1", count: 64),
                                       canarySHA256: String(repeating: "2", count: 64), fileSHA256: String(repeating: "3", count: 64))
    static let source = SeedSource(sourceSHA256: String(repeating: "f", count: 64), decoderVersion: "raw9-test", pinsVersion: "pins-test",
                                   app: "ArgentCoreTests", created: Date(timeIntervalSince1970: 1_793_000_000))

    /// An 8-bit picture of pseudo-random bytes in `space`, with the given layout.
    static func image(width: Int, height: Int, space: CGColorSpace, bitmapInfo: UInt32, bitsPerComponent: Int = 8,
                      seed: UInt64 = 7) -> CGImage {
        let bytesPerPixel = 4 * bitsPerComponent / 8
        var state = seed
        let bytes = (0..<(width * height * bytesPerPixel)).map { _ -> UInt8 in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 56)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: bitsPerComponent, bitsPerPixel: 8 * bytesPerPixel,
                       bytesPerRow: width * bytesPerPixel, space: space, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func rgb(_ image: CGImage) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        return data.enumerated().compactMap { $0.offset % 4 == 3 ? nil : $0.element }
    }

    static func picture() throws -> AppleSegmentation.Picture {
        try AppleSegmentation.Picture(image(width: 96, height: 64, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    }

    static func sky(_ value: (Int, Int) -> Float) throws -> SkySeed {
        try SkySeed(width: 756, height: 504, values: (0..<(756 * 504)).map { value($0 % 756, $0 / 756) }, model: model)
    }
}

@Suite struct AppleSegmentationTests {
    /// Vision reads one pixel path: an 8-bit sRGB picture keeps its bytes, whatever their order, and any other picture is
    /// converted to it the same way every time.
    @Test func everyPictureTakesOneFixedPixelPath() throws {
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let rgbx = Make.image(width: 61, height: 37, space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        let picture = try AppleSegmentation.Picture(rgbx)
        #expect(picture.width == 61 && picture.height == 37)
        #expect(Make.rgb(picture.image) == Make.rgb(rgbx))
        #expect(picture.bytes.enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 255 })
        #expect(picture.image.bitsPerComponent == 8 && picture.image.colorSpace?.name == CGColorSpace.sRGB)
        // The same pixels laid out as BGRA keep the same bytes, and so the same digest.
        let rgb = Make.rgb(rgbx)
        var bgra = [UInt8](repeating: 255, count: 61 * 37 * 4)
        for i in 0..<(61 * 37) { bgra[i * 4] = rgb[i * 3 + 2]; bgra[i * 4 + 1] = rgb[i * 3 + 1]; bgra[i * 4 + 2] = rgb[i * 3] }
        let swapped = try #require(CGImage(width: 61, height: 37, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 61 * 4, space: srgb,
                                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                           provider: CGDataProvider(data: Data(bgra) as CFData)!, decode: nil, shouldInterpolate: false,
                                           intent: .defaultIntent))
        #expect(try AppleSegmentation.Picture(swapped).sha256 == picture.sha256)
        // Another space and depth: converted, to the same bytes each time.
        let p3 = Make.image(width: 61, height: 37, space: try #require(CGColorSpace(name: CGColorSpace.displayP3)),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue,
                            bitsPerComponent: 16)
        let once = try AppleSegmentation.Picture(p3), twice = try AppleSegmentation.Picture(p3)
        #expect(once.sha256 == twice.sha256 && once.sha256 != picture.sha256 && once.image.bitsPerComponent == 8)
        #expect(picture.sha256.count == 64 && RasterID(hex: picture.sha256) != nil)
    }

    /// Finding nothing is a result with what was run, and each kind has its row's words.
    @Test func anEmptyResultIsAResult() throws {
        let picture = try Make.picture()
        let decision = WaterVeto.Decision(gate: WaterScore(labels: [:]), ran: false, fired: false, candidateShare: 0, removedPixels: 0,
                                          removedSelectedShare: 0, removedSoftShare: 0,
                                          seedBefore: WaterVeto.quantize([Float](repeating: 0.49, count: 756 * 504), width: 756, height: 504).identity)
        // Soft everywhere, nothing at 0.5: no sky.
        let none = SmartSeed.sky(try Make.sky { _, _ in 0.49 }, decision: decision, picture: picture, source: Make.source)
        #expect(none.seed == nil && none.kind == .sky && none.provenance.parameters["veto"] == WaterVeto.version)
        #expect(SmartResult.nothingFoundMessage(.sky) == "No sky found in this frame")
        for kind in SmartKind.allCases { #expect(!SmartResult.nothingFoundMessage(kind).isEmpty) }
        // A subject's absence is the background's too.
        let noSubject = SmartResult.nothingFound(.subject, none.provenance)
        let background = AppleSegmentation.background(from: noSubject)
        #expect(background.kind == .background && background.seed == nil && background.provenance == none.provenance)
        // One selected pixel is a seed.
        let one = SmartSeed.sky(try Make.sky { x, y in x == 10 && y == 10 ? 0.5 : 0 }, decision: decision, picture: picture, source: Make.source)
        #expect(one.seed?.raster.plane.filter { $0 >= SmartSeed.selectedLevel }.count == 1)
    }

    /// Background is Subject's raster and provenance under its own kind, not a second raster.
    @Test func backgroundIsSubjectsRaster() throws {
        let raster = try MaskRaster(width: 512, height: 512, plane: (0..<(512 * 512)).map { $0 % 512 < 200 ? 255 : 0 })
        let provenance = Make.source.provenance(engine: AppleSegmentation.subjectEngine, revision: 1, parameters: [:], picture: try Make.picture())
        let subject = SmartResult.seed(SmartSeed(kind: .subject, raster: raster, provenance: provenance))
        let background = try #require(AppleSegmentation.background(from: subject).seed)
        #expect(background.kind == .background && background.raster == raster && background.raster.ref == subject.seed?.raster.ref)
        #expect(background.provenance == provenance)
    }

    /// A Sky seed's provenance, the veto's decision and gate included, goes through T2's types and back: into `MaskNotes` by
    /// raster id, through the recipe's JSON, and out as the same decision; its selection goes into a valid `MaskSet`.
    @Test func provenanceRoundTripsThroughTheRecipesTypes() async throws {
        let picture = try Make.picture()
        let gate = WaterScore(labels: ["lake": 0.125, "ocean": 0.0625])
        let water = try WaterMap(side: 192, values: (0..<(192 * 192)).map { $0 / 192 >= 120 ? 0.9 : 0 }, square: 768, contentWidth: 768,
                                 contentHeight: 512, originX: 0, originY: 128,
                                 model: ModelProvenance(recipeID: "eomt-dinov3-l-ade150-sq768-f16-maps3-1", weightsSHA256: String(repeating: "4", count: 64),
                                                        canarySHA256: "63bdb66c474ed611e32d5ddcc274da3acae07a00b6270fbbcb136dcfd77e7a46",
                                                        fileSHA256: String(repeating: "5", count: 64)),
                                 mapsSHA256: String(repeating: "6", count: 64))
        let seed = try Make.sky { _, y in y < 200 ? 1 : y > 300 ? 0.9 : 0.2 }
        let result = await SmartSeed.sky(seed, picture: picture, source: Make.source, gate: gate) { water }
        let made = try #require(result.seed)
        #expect(made.kind == .sky && made.raster.width == 756 && made.raster.height == 504)
        let p = made.provenance
        #expect(p.engine == "coreai:da3-test" && p.engineRevision == "da3-test@sha256:" + String(repeating: "1", count: 64))
        #expect(p.input.kind == "neutral-print" && p.input.width == 96 && p.input.height == 64 && p.input.colorSpace == "sRGB")
        #expect(p.input.sourceSHA256 == Make.source.sourceSHA256 && p.input.decoderVersion == "raw9-test" && p.input.pinsVersion == "pins-test")
        #expect(p.parameters["input.sha256"] == picture.sha256 && p.operatingSystem == Make.source.operatingSystem)
        #expect(p.parameters["model.canary"] == String(repeating: "2", count: 64))
        let decision = try #require(WaterVeto.Decision(parameters: p.parameters))
        #expect(decision.fired && decision.ran && decision.gate == gate && decision.mapsSHA256 == water.mapsSHA256 && decision.waterModel == water.model)
        #expect(decision.seedBefore == WaterVeto.quantize(seed.values, width: 756, height: 504).identity)
        #expect(made.raster.plane[100 * 756 + 10] == 255 && made.raster.plane[400 * 756 + 10] == 0)

        // Through the recipe's notes and JSON, by raster id, and back.
        let notes = MaskNotes(names: [:], rasters: [made.raster.identity.hex: p])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoded = try JSONDecoder().decode(MaskNotes.self, from: encoder.encode(notes))
        #expect(decoded == notes)
        let back = try #require(decoded.rasters[made.raster.identity.hex])
        #expect(WaterVeto.Decision(parameters: back.parameters) == decision && WaterScore(parameters: back.parameters) == gate)
        // Another version's decision is not read as this one's.
        var other = back.parameters
        other["veto"] = "water-veto-0"
        #expect(WaterVeto.Decision(parameters: other) == nil)

        // The seed's selection, once stored, is a valid component, and its notes stay with it.
        let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let mask = Mask(components: [MaskComponent(shape: .smart(made.selection(frame: frame)))])
        let set = try MaskSet(masks: [mask])
        #expect(set.rasters == [made.raster.ref] && notes.keeping(set) == notes)
        #expect(made.selection(frame: frame) == SmartSelection(kind: .sky, raster: made.raster.ref, frame: frame))
    }
}

/// Vision on the CC0 sample's neutral print, a garden wall under trees in which Vision finds no subject and no person, and on
/// three crops of it in which it does: the bush (one instance), the two parking signs (two instances, stored as one mask) and
/// the orange barrier, which Vision also calls a person, as R2 saw it call dogs and a flower people. Runs only where the
/// samples are present.
@Suite(.serialized) struct AppleSegmentationSampleTests {
    static var hasSamples: Bool { NeutralPrintFixture.hasSamples }
    static let source = SeedSource(sourceSHA256: String(repeating: "0", count: 64), decoderVersion: "raw9", app: "ArgentCoreTests",
                                   created: Date(timeIntervalSince1970: 1_793_000_000))

    /// The crops, in pixels of the 2560 × 1707 print from its top left.
    static let bush = CGRect(x: 0, y: 512, width: 1024, height: 683)
    static let signs = CGRect(x: 896, y: 1229, width: 308, height: 205)
    static let barrier = CGRect(x: 1689, y: 1280, width: 871, height: 427)

    static func crop(_ rect: CGRect) throws -> AppleSegmentation.Picture {
        try AppleSegmentation.Picture(try #require(try NeutralPrintFixture.print.get().image.cropping(to: rect)))
    }

    /// What one process gets: each picture's digest, then Subject's and Person's stored raster (or "none") and the water score.
    static func digests() throws -> [String] {
        var out: [String] = []
        for picture in [try NeutralPrintFixture.print.get(), try crop(bush), try crop(signs), try crop(barrier)] {
            let subject = try AppleSegmentation.subject(picture, source: source)
            let person = try AppleSegmentation.person(picture, source: source)
            out += [picture.sha256, subject.seed?.raster.identity.hex ?? "none", person.seed?.raster.identity.hex ?? "none",
                    person.provenance.parameters["maximum"] ?? "-", String(try AppleSegmentation.waterScore(picture).score.bitPattern, radix: 16)]
        }
        return out
    }

    /// The same bytes every time in one process: every request five times, and again on pictures made afresh from the same
    /// image (R2: bit-identical in 15 runs of 3 processes).
    @Test(.enabled(if: AppleSegmentationSampleTests.hasSamples))
    func visionGivesTheSameBytesEveryTime() throws {
        let first = try Self.digests()
        #expect(first.contains { $0 == "none" } && first.filter { $0 != "none" && $0.count == 64 }.count >= 7)
        for _ in 0..<4 { #expect(try Self.digests() == first) }
        let again = try AppleSegmentation.Picture(try NeutralPrintFixture.print.get().image)
        #expect(try AppleSegmentation.subject(again, source: Self.source) == AppleSegmentation.subject(try NeutralPrintFixture.print.get(), source: Self.source))
        print("MEASURE vision digests: \(first.joined(separator: " "))")
    }

    /// What each kind returns and stores: on the whole print nothing, with its provenance; Subject's 512 × 512 map, every
    /// instance 255, over a picture of any aspect; Background as Subject's raster; Person's matte as returned, 2016 × 1512.
    @Test(.enabled(if: AppleSegmentationSampleTests.hasSamples))
    func eachKindsSeedOnTheSample() throws {
        let whole = try NeutralPrintFixture.print.get()
        #expect(whole.width == 2560 && whole.height == 1707)

        // The whole print: nothing found, as results.
        let none = try AppleSegmentation.subject(whole, source: Self.source)
        #expect(none.seed == nil && none.kind == .subject && none.provenance.parameters["instances"] == "0")
        #expect(none.provenance.engine == "vision.foreground-instance" && none.provenance.engineRevision == "1")
        #expect(none.provenance.input.width == 2560 && none.provenance.input.height == 1707 && none.provenance.parameters["input.sha256"] == whole.sha256)
        #expect(try AppleSegmentation.background(whole, source: Self.source) == .nothingFound(.background, none.provenance))
        let nobody = try AppleSegmentation.person(whole, source: Self.source)
        #expect(nobody.seed == nil && nobody.provenance.parameters["returned"] == "2016x1512")
        #expect(Int(nobody.provenance.parameters["maximum"] ?? "") ?? 255 < 128)
        #expect(nobody.provenance.engine == "vision.person-segmentation" && nobody.provenance.parameters["quality"] == "accurate")

        // The bush: one instance, a hard 512 × 512 map over a 3:2 picture, and Background the same raster.
        let bush = try Self.crop(Self.bush)
        let subject = try #require(try AppleSegmentation.subject(bush, source: Self.source).seed)
        #expect(subject.kind == .subject && subject.raster.width == 512 && subject.raster.height == 512)
        #expect(subject.raster.plane.allSatisfy { $0 == 0 || $0 == 255 } && subject.raster.plane.contains(255))
        #expect(subject.provenance.parameters["instances"] == "1" && subject.provenance.input.width == 1024)
        let background = try #require(try AppleSegmentation.background(bush, source: Self.source).seed)
        #expect(background.kind == .background && background.raster == subject.raster && background.provenance == subject.provenance)

        // The signs: two instances, stored as one mask, their union.
        let signs = try Self.crop(Self.signs)
        let both = try #require(try AppleSegmentation.subject(signs, source: Self.source).seed)
        #expect(both.provenance.parameters["instances"] == "2")
        let labels = try Self.labels(signs)
        #expect(Set(labels.plane.filter { $0 > 0 }).count == 2)
        #expect(both.raster.plane == labels.plane.map { $0 > 0 ? 255 : 0 })

        // The barrier, taken for a person: the matte as returned, soft, 2016 × 1512 though the crop is about 2:1.
        let barrier = try Self.crop(Self.barrier)
        let person = try #require(try AppleSegmentation.person(barrier, source: Self.source).seed)
        #expect(person.kind == .person && person.raster.width == 2016 && person.raster.height == 1512)
        #expect(person.raster.plane.contains { $0 > 0 && $0 < 255 } && person.provenance.parameters["maximum"] == nil)

        let water = try AppleSegmentation.waterScore(whole)
        #expect(water.labels.count == WaterGate.identifiers.count && !water.passes)
        print("MEASURE vision on DSC06673: whole print subject none, person none (matte maximum \(nobody.provenance.parameters["maximum"] ?? "?")); "
              + "bush subject \(subject.raster.plane.filter { $0 > 0 }.count) of 512 x 512 set, confidence \(subject.provenance.parameters["confidence"] ?? "?"); "
              + "signs 2 instances, \(both.raster.plane.filter { $0 > 0 }.count) set; barrier person \(person.raster.plane.filter { $0 >= 128 }.count) selected of 2016 x 1512; "
              + "water score \(water.score) (\(water.parameters["gate.labels"] ?? ""))")
    }

    /// Vision's own label map, read as `AppleSegmentation.subject` reads it.
    static func labels(_ picture: AppleSegmentation.Picture) throws -> (width: Int, height: Int, plane: [UInt8]) {
        let request = VNGenerateForegroundInstanceMaskRequest()
        try VNImageRequestHandler(cgImage: picture.image, orientation: .up, options: [:]).perform([request])
        return try AppleSegmentation.plane(of: try #require(request.results?.first).instanceMask)
    }

    /// A portrait picture gets a portrait matte, 1512 × 2016, and Subject's map stays 512 × 512. (Turned on its side the bush
    /// is no subject to Vision; the signs still are.)
    @Test(.enabled(if: AppleSegmentationSampleTests.hasSamples))
    func aPortraitPictureGetsAPortraitMatte() throws {
        for (rect, name) in [(CGRect(x: 0, y: 0, width: 2560, height: 1707), "print"), (Self.signs, "signs")] {
            let landscape = try Self.crop(rect)
            let w = landscape.height, h = landscape.width
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.translateBy(x: CGFloat(w), y: 0)
            context.rotate(by: .pi / 2)
            context.draw(landscape.image, in: CGRect(x: 0, y: 0, width: h, height: w))
            let portrait = try AppleSegmentation.Picture(try #require(context.makeImage()))
            #expect(portrait.width == landscape.height && portrait.height == landscape.width)
            #expect(try AppleSegmentation.person(portrait, source: Self.source).provenance.parameters["returned"] == "1512x2016", "\(name)")
            if name == "signs" {
                let seed = try #require(try AppleSegmentation.subject(portrait, source: Self.source).seed)
                #expect(seed.raster.width == 512 && seed.raster.height == 512)
            }
        }
    }

    /// A Sky click on a frame Vision scores under the gate never asks for the water map, so EoMT never loads, and the seed is
    /// stored as DA3 gave it, with the gate's score in its provenance. DA3's seed here is made by hand.
    @Test(.enabled(if: AppleSegmentationSampleTests.hasSamples))
    func aSkyClickBelowTheGateNeverLoadsEoMT() async throws {
        let picture = try NeutralPrintFixture.print.get()
        let gate = try AppleSegmentation.waterScore(picture)
        #expect(!gate.passes, "the sample, a garden wall, has no water: \(gate.score)")
        let seed = try Make.sky { _, y in y < 60 ? 0.9 : 0.1 }
        let asked = Counter()
        let result = try await SmartSeed.sky(seed, picture: picture, source: Self.source, gate: gate) {
            asked.add()
            throw MaskError.invalid("EoMT was asked for")
        }
        #expect(asked.value == 0)
        let made = try #require(result.seed)
        #expect(made.raster == WaterVeto.quantize(seed.values, width: 756, height: 504))
        let decision = try #require(WaterVeto.Decision(parameters: made.provenance.parameters))
        #expect(!decision.ran && !decision.fired && decision.gate == gate && made.provenance.parameters["eomt.maps"] == nil)
    }

    /// Across processes: the bytes this process gets equal those pinned from earlier runs, on the macOS build they were taken
    /// on, from the same print. Every run of the suite is a new process, so two runs check R2's claim. On another build, or a
    /// different print (RAW 9 changed, or the print is made another way), the pins are stale: the test prints the new values to
    /// pin and does not compare. A macOS update re-pins them, as the mask canary re-hashes its frames (plan section 8).
    @Test(.enabled(if: AppleSegmentationSampleTests.hasSamples))
    func visionGivesTheSameBytesInEveryProcess() throws {
        let got = try Self.digests()
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        guard os == Pinned.operatingSystem, got.first == Pinned.digests.first else {
            print("MEASURE vision pins are stale: \(os), print \(got[0]); pinned \(Pinned.operatingSystem), print \(Pinned.digests[0]). Now: \(got)")
            return
        }
        #expect(got == Pinned.digests)
    }

    /// Taken from this suite's print (`NeutralPrintFixture`), in five groups: the print, its bush, signs and barrier crops;
    /// each the picture's digest, Subject's raster, Person's raster, the matte's maximum when nobody is found, and the water
    /// score's bits. Recorded again on `main` at `e5bca7c7` on 2026-11-23 (macOS 27.2 build 26B123), the same in three
    /// processes. The first pins, of 2026-11-07 on the same build, were of a print made before two changes to it: the lens
    /// stage, which corrects the decode in place of RAW 9 (2026-11-13), and scene gamut compression in the shader's
    /// `encode_log` (2026-11-19). With both taken out of the sources again, this process gave those pins back, every
    /// value; with either alone, it did not. Vision itself had not moved.
    enum Pinned {
        static let operatingSystem = "Version 27.2 (Build 26B123)"
        static let digests = [
            "37adb0470708fb46845385b54ff8b5c281b63298e73ef550434064013d090fbb", "none", "none", "51", "399837f0",
            "d6908aea023d4c02f3d6be135315f3d57ebfe81882fd95dd55bfdfb5e1c260fb", "855d11787541d5c1aed1fc2b8df06cd3e3acedae0f0a5a6031541a056632263c", "none", "6", "3ac965f4",
            "9ea7ec8b929e6e8d8a791912c4537e30851a0808196968b2c937c44c5c3bf4ed", "28a782b90249ae64d996c3bf03a17fd2926b830fec6520ea99e53e85ba5743db", "none", "7", "399837f0",
            "42b89d6165368c982f3f510ea833637c7e8eba046525785afef065f14adcf9ca", "944418c155be98d2d6c72c2374208c74dc2765ea5a083263c168981ab38e9541", "50d368f1aecf4c1bb22dd4500cd5a38cf8f0d73209fbda130023e5253ee2ff78", "-", "3b1088e5",
        ]
    }
}
