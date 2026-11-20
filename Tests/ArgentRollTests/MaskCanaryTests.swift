import ArgentCore
import CoreAI
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// The ten-frame mask canary (masking-plan section 8): every smart selection a click makes, on ten fixed pictures, hashed, to be
/// run again after each macOS update, as T8's canary is for RAW 9. Apple's segmentation has one revision a request and Core AI's
/// compiled models are tied to the OS build (plan section 3), so an update may move what a click finds; a saved seed never
/// changes, but new clicks would. The canary says whether they did.
///
/// For each frame: the picture's own hash (`AppleSegmentation.Picture.sha256`), Vision's water score and the gate's decision, DA3's
/// output hash, EoMT's when the gate lets it run, whether the veto fired and what it removed, and the stored seed of Sky, Subject
/// and Person (`MaskRaster.identity`); and the new Subject's click: S3OD's output hash and IoU argmax, what the "no subject" gate and the
/// low-light rule decided, and the seed and ViTMatte's alpha on it (identity of the raster, the matte taken "as if in the rule" for a frame
/// outside it so an update's effect on the model is seen). On the macOS build the pins were taken on, everything must be equal. On another, the
/// decisions must hold (the gate, the veto firing, the removed share within half a point, the Subject's selection and gate) and the plan's expectations too: the
/// veto fires on `4908`, `a1017` and `DSC04073` (about 29, 4.7 and 1.2 % of the frame) and not on `DSC04064` or `DSC04080`; the
/// hashes that moved are printed as `CANARY` lines to pin again.
///
/// Opt-in, since it loads all four models (about 30 s with the compiles) and most of its frames are private: `ARGENT_MASK_CANARY=1`
/// runs the CC0 frame alone, from `samples/`, through the app's own route (its RAW 9 decode and input picture, task A);
/// `ARGENT_MASK_CANARY=<folder>` adds each of the other nine whose 2560-pixel neutral print is in that folder as `<name>.jpg`
/// (P0-S4's `testset/neutral`, outside Git), and skips the rest. Needs `build/models`. Leaves no compiled copy behind.
@Suite(.serialized, .rawDecodes, .enabled(if: MaskCanary.enabled))
struct MaskCanaryTests {
    @Test func theCanaryFindsWhatItFoundBefore() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("argent-mask-canary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let models = MaskModels(directory: MaskCanary.models, ledgerFile: support.appendingPathComponent("ledger.json"))
        #expect(models.isSkyAvailable, "\(models.unavailable)")
        defer { for model in BundledMaskModel.allCases { try? AIModelCache.default.deleteEntries(for: try models.url(of: model)) } }
        let build = MaskModels.osBuild, pinnedBuild = build == MaskCanary.pinnedBuild
        print("CANARY macOS \(build); pins from \(MaskCanary.pinnedBuild)")

        var ran: [String] = []
        for name in MaskCanary.frames {
            guard let entry = try await MaskCanary.measure(name, models: models, support: support) else {
                print("CANARY \(name): skipped, not present")
                continue
            }
            ran.append(name)
            print("CANARY \(entry.line)")
            guard let pin = MaskCanary.pins[name] else {
                Issue.record("\(name) has no pin; paste its CANARY line into MaskCanary.pins")
                continue
            }
            if pinnedBuild {
                #expect(entry == pin, "\(name) moved on the pinned build: \(entry.line) against \(pin.line)")
            } else if entry != pin {
                print("CANARY \(name) re-hashed on \(build): was \(pin.line)")
            }
            // What must hold on any build.
            #expect(entry.gatePasses == pin.gatePasses && entry.fired == pin.fired, "\(name): the gate or the veto changed its mind")
            #expect(abs(entry.removed - pin.removed) <= 0.5, "\(name): the veto removes \(entry.removed) %, pinned \(pin.removed) %")
            #expect(entry.selection == pin.selection && entry.subjectGate == pin.subjectGate && entry.rule == pin.rule, "\(name): the Subject click changed its mind")
            if let expected = MaskCanary.plan[name] {
                #expect(entry.fired == (expected > 0), "\(name): the plan says the veto \(expected > 0 ? "fires" : "does not fire")")
                if expected > 0 { #expect(abs(entry.removed - expected) <= 1.5, "\(name): removes \(entry.removed) %, the plan about \(expected) %") }
            }
        }
        await models.unloadAll()
        #expect(ran.contains(MaskCanary.cc0), "the CC0 frame is in samples/")
        print("CANARY ran \(ran.count) of \(MaskCanary.frames.count): \(ran.joined(separator: ", "))")
    }
}

enum MaskCanary {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let cc0 = "ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed"
    /// The ten: the CC0 sample; the plan's five; and four more from S5's golden set (the veto fires on `DSC04074` and `a3755`, the
    /// lagoon S5 read as water; it removes nothing on `DSC04091`, all reflection, or `DSC04100`, S1b's branch frame).
    static let frames = [cc0, "Y-JG-A7-IV-FE-24-105-4908", "a1017-kme_427", "DSC04073", "DSC04064", "DSC04080",
                         "DSC04074", "a3755-07-11-19-at-15h49m11s-_MG_5217", "DSC04091", "DSC04100"]
    /// The plan's share of the frame the veto removes (section 8), 0 where it must not fire. a1017's is 7.25, not the plan's 4.7:
    /// with DA3's square mirrored one patch past the picture's edge (task H) DA3 calls 7.25 % of the frame sky where it called 4.84 %,
    /// all of it over the lake, and the veto takes all of it either way (measured; a correction for the plan).
    static let plan: [String: Double] = ["Y-JG-A7-IV-FE-24-105-4908": 29, "a1017-kme_427": 7.25, "DSC04073": 1.2, "DSC04064": 0, "DSC04080": 0]

    static var setting: String? { ProcessInfo.processInfo.environment["ARGENT_MASK_CANARY"] }
    static var prints: URL? { setting.flatMap { $0 == "1" ? nil : URL(fileURLWithPath: $0, isDirectory: true) } }
    static var models: URL {
        ProcessInfo.processInfo.environment["ARGENT_MASK_MODELS"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("build/models")
    }
    static var sample: URL { root.appendingPathComponent("samples/\(cc0).ARW") }
    static var enabled: Bool {
        setting != nil && BundledMaskModel.allCases.allSatisfy {
            FileManager.default.fileExists(atPath: models.appendingPathComponent("\($0.fileName)/main.hash").path)
        }
    }

    /// What one frame's clicks come to.
    struct Entry: Equatable {
        var name: String
        var picture: String
        var gate: Float
        var gatePasses: Bool
        var da3: String
        var eomt: String
        var fired: Bool
        /// The share of the seed's pixels the veto took from the selection, in percent; and its values summed, soft ones included.
        var removed: Double
        var soft: Double
        var sky: String
        var subject: String
        var person: String
        /// S3OD's output hash, the argmax of its IoUs, and its selected share in percent.
        var s3od: String
        var argmax: String
        var selected: Double
        /// What the new Subject click decided: `kept`, `empty` or `gate`.
        var selection: String
        /// The "no subject" gate's stuff share, `-` when Vision found something.
        var subjectGate: String
        /// `in` or `out` of the low-light rule, `na` for a frame with no raw (a print).
        var rule: String
        /// The new Subject's stored raster (`none` when it found nothing) and ViTMatte's alpha on its seed (`-` with no seed).
        var clicked: String
        var alpha: String

        var line: String {
            "\(name) picture \(picture) gate \(String(format: "%.4f", gate)) \(gatePasses ? "pass" : "below") da3 \(da3) eomt \(eomt) "
                + "veto \(fired ? "fired" : "no") removed \(String(format: "%.2f", removed)) soft \(String(format: "%.2f", soft)) sky \(sky) subject \(subject) person \(person) "
                + "s3od \(s3od) argmax \(argmax) selected \(String(format: "%.2f", selected)) selection \(selection) subjectgate \(subjectGate) rule \(rule) clicked \(clicked) alpha \(alpha)"
        }

        static func == (a: Self, b: Self) -> Bool { a.line == b.line }

        init(name: String, picture: String, gate: Float, gatePasses: Bool, da3: String, eomt: String, fired: Bool, removed: Double,
             soft: Double, sky: String, subject: String, person: String, s3od: String, argmax: String, selected: Double,
             selection: String, subjectGate: String, rule: String, clicked: String, alpha: String) {
            self.name = name; self.picture = picture; self.gate = gate; self.gatePasses = gatePasses; self.da3 = da3; self.eomt = eomt
            self.fired = fired; self.removed = removed; self.soft = soft; self.sky = sky; self.subject = subject; self.person = person
            self.s3od = s3od; self.argmax = argmax; self.selected = selected; self.selection = selection; self.subjectGate = subjectGate
            self.rule = rule; self.clicked = clicked; self.alpha = alpha
        }

        /// A pinned line read back.
        init(line: String) {
            let words = line.split(separator: " ").map(String.init)
            func after(_ key: String) -> String { words.firstIndex(of: key).map { words[$0 + 1] } ?? "" }
            self.init(name: words[0], picture: after("picture"), gate: Float(after("gate")) ?? .nan,
                      gatePasses: words.contains("pass"), da3: after("da3"), eomt: after("eomt"), fired: after("veto") == "fired",
                      removed: Double(after("removed")) ?? .nan, soft: Double(after("soft")) ?? .nan, sky: after("sky"),
                      subject: after("subject"), person: after("person"), s3od: after("s3od"), argmax: after("argmax"),
                      selected: Double(after("selected")) ?? .nan, selection: after("selection"), subjectGate: after("subjectgate"),
                      rule: after("rule"), clicked: after("clicked"), alpha: after("alpha"))
        }
    }

    /// The macOS build the pins were taken on.
    static let pinnedBuild = "26B123"
    /// What each frame came to on `pinnedBuild` (2026-11-07, task F; again in task H, after DA3's square mirrored one patch past the
    /// picture's edge; the new Subject's fields 2026-11-09, task B1), as `Entry.line` prints it.
    static let pins: [String: Entry] = Dictionary(uniqueKeysWithValues: [
        "ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed picture 0be88d15ddcae45d gate 0.0003 below da3 75cc16ef3069a94c eomt - veto no removed 0.00 soft 0.00 sky ff2135187ffd6f81 subject none person none s3od 8f7231643c650a6c argmax 1 selected 1.08 selection kept subjectgate 0.0084 rule out clicked 8e8cb4181db09386 alpha 20abb58216d6767b",
        "Y-JG-A7-IV-FE-24-105-4908 picture c5656a3bc97ff758 gate 0.5205 pass da3 483cef3d84159fd6 eomt 5a7bce65164b2926 veto fired removed 29.29 soft 27.06 sky none subject none person none s3od bcc71875db31d55f argmax 1 selected 2.39 selection kept subjectgate 0.0371 rule na clicked 374f42831bd8394e alpha b1fc8434fe7f8463",
        "a1017-kme_427 picture b003d24f1f43171e gate 0.0886 pass da3 0627d8c9919a26c9 eomt 0fc49be13093a7d1 veto fired removed 7.25 soft 9.53 sky none subject none person none s3od 8102d3dbe0d1bdd2 argmax 1 selected 0.05 selection gate subjectgate 1.0000 rule na clicked none alpha -",
        "DSC04073 picture 3be16021ef43c6fc gate 0.1328 pass da3 db1c31bcdd70a031 eomt da7e6098c3f4523a veto fired removed 1.07 soft 1.08 sky 96f5282b3d2bbf6c subject none person none s3od 8ee1e649595c0053 argmax 1 selected 0.30 selection kept subjectgate 0.1507 rule na clicked 9e8abd7053a69ae9 alpha 74155041c2f1751b",
        "DSC04064 picture d3372df83eb9f66f gate 0.2867 pass da3 41e0438f1ca0fc7d eomt 333caf1d5fad5c16 veto no removed 0.00 soft 0.00 sky 756bdab268dc1a2b subject 0f77a96ed8f5b7da person none s3od 5159021106fdf6b5 argmax 0 selected 45.56 selection kept subjectgate - rule na clicked 626ca98f0b48e72d alpha fb0cc82cb1d40118",
        "DSC04080 picture bf0c2c302612f163 gate 0.0445 pass da3 f694628d6f5bd174 eomt ff1af227c9f096b7 veto no removed 0.00 soft 0.00 sky 27e36838da6511cd subject 99d76f2427313b04 person f0e97f6f03b74c6c s3od 44219cf587d002c3 argmax 0 selected 60.06 selection kept subjectgate - rule na clicked f43929c1bbe8c60f alpha 5a33e089e731ee5a",
        "DSC04074 picture 3a3318a031a67a74 gate 0.1375 pass da3 06efdad42b4aaa64 eomt 1f8c17aee4f1396b veto fired removed 1.33 soft 1.30 sky 954e0c72737c4478 subject none person none s3od 44d04603b2c8b755 argmax 1 selected 0.31 selection kept subjectgate 0.1572 rule na clicked d90beaca0c98d137 alpha efd227b2fa2d9ba8",
        "a3755-07-11-19-at-15h49m11s-_MG_5217 picture 2820630331079e1d gate 0.3192 pass da3 7e43c53624ebaa43 eomt 462e003ea1f6011d veto fired removed 1.32 soft 1.32 sky 0ddd223da8de47fe subject none person none s3od fb01f5ce9bafebcc argmax 1 selected 12.01 selection kept subjectgate 0.0162 rule na clicked 3b2c36266ae8f139 alpha 6e5f5f049acde2e4",
        "DSC04091 picture 3ce1ec1a62c48c2f gate 0.1040 pass da3 68b16917574fedaf eomt d3d0003063781ee2 veto no removed 0.00 soft 0.00 sky none subject none person none s3od 63ea63541eb03eab argmax 1 selected 0.00 selection empty subjectgate 0.0000 rule na clicked none alpha -",
        "DSC04100 picture 150c90a3db39a9da gate 0.0018 below da3 25965144e43eb1d6 eomt - veto no removed 0.00 soft 0.00 sky 8552bcd09c11548e subject none person ac456c03fcff0378 s3od 077eaf37af8f2f37 argmax 1 selected 2.04 selection kept subjectgate 0.4847 rule na clicked dc62d5cdf05dd094 alpha dd667531f29a89ee",
    ].map { line in (String(line.prefix { $0 != " " }), Entry(line: line)) })

    private static func id(_ result: SmartResult) -> String {
        result.seed.map { String($0.raster.identity.hex.prefix(16)) } ?? "none"
    }

    /// The frame's picture and every click on it; `nil` when the frame is not here.
    static func measure(_ name: String, models: MaskModels, support: URL) async throws -> Entry? {
        let source = SeedSource(sourceSHA256: String(repeating: "0", count: 64), app: "canary", created: Date(timeIntervalSince1970: 0),
                                operatingSystem: "canary")
        let vision: AppleSegmentation.Picture
        let sky: SkyOutputs
        let water: () async throws -> EomtMaps
        let input: MaskInputPicture
        var rule: LowLightRule.Decision?
        if name == cc0 {
            // The app's route: RAW 9's decode at 2560 and task A's input picture.
            guard FileManager.default.fileExists(atPath: sample.path) else { return nil }
            try writeToyStock(id: "kodak-portra-400", in: support)
            let films = try FilmPreviews(stocks: StockLibrary.load(from: support).stocks, decoderChoices: DecoderChoices(route: .raw9))
            let frame = try #require(await RollScanner.scan(sample.deletingLastPathComponent()).frames.first { $0.name == cc0 })
            let picture = try #require(await films.maskInputPicture(frame, lens: .default))
            input = picture
            vision = try AppleSegmentation.Picture(picture.image)
            sky = try await models.sky(for: picture)
            water = { try await models.water(for: picture) }
            rule = LowLightRule.decide(BundledSmartMasks.metadata(of: frame), medianLuminance: picture.medianLuminance)
        } else {
            // A fixed print: the bundled models' squares made from it on the CPU (OpenCV's area resize, as Phase 0 made them).
            guard let folder = prints, let url = ["jpg", "png"].map({ folder.appendingPathComponent("\(name).\($0)") })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  let file = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(file, 0, nil) else { return nil }
            vision = try AppleSegmentation.Picture(image)
            let bytes = vision.bytes, w = vision.width, h = vision.height
            input = try MaskInputPicture(pixels: Data(bytes) as CFData, width: w, height: h,
                                         source: .init(decodeWidth: w, decodeHeight: h, decoderVersion: "canary-print", pinsVersion: nil, pinsDecoderVersion: nil, decodeScale: 1))
            var rgb = [UInt8](repeating: 0, count: w * h * 3)
            for i in 0..<(w * h) { rgb[i * 3] = bytes[i * 4]; rgb[i * 3 + 1] = bytes[i * 4 + 1]; rgb[i * 3 + 2] = bytes[i * 4 + 2] }
            func square(_ side: Int) -> ModelSquare {
                let layout = ModelSquareLayout(side: side, width: w, height: h)
                return ModelSquare(contentRGB8: ModelSquare.areaResize(rgb, width: w, height: h, toWidth: layout.contentWidth, height: layout.contentHeight),
                                   layout: layout, padding: side == SkyModelRunner.side ? SkyModelRunner.padding : EomtModelRunner.padding)
            }
            if await !models.skyRunner.isLoaded { try await models.skyRunner.load(from: try models.url(of: .sky)) }
            sky = try await models.skyRunner.run(square(SkyModelRunner.side))
            water = {
                try await models.waterRunner.load(from: try models.url(of: .water))
                let maps = try await models.waterRunner.run(square(EomtModelRunner.side))
                await models.waterRunner.unload()
                return maps
            }
        }
        let gate = try AppleSegmentation.waterScore(vision)
        let da3 = ModelProvenance(try models.identity(of: .sky)), eomt = ModelProvenance(try models.identity(of: .water))
        let seed = try SkySeed(skyHead: ModelSquare.crop(sky.sky, planeSide: SkyModelRunner.side, layout: sky.layout),
                               width: sky.layout.contentWidth, height: sky.layout.contentHeight, model: da3, square: sky.squareRecipe)
        var mapsDigest = "-"
        let (vetoed, decision) = try await WaterVeto.apply(to: seed, gate: gate) {
            let maps = try await water()
            mapsDigest = String(maps.digest.prefix(16))
            return try WaterMap(side: EomtModelRunner.mapSide, values: maps.water, square: EomtModelRunner.side,
                                contentWidth: maps.layout.contentWidth, contentHeight: maps.layout.contentHeight,
                                originX: maps.layout.originX, originY: maps.layout.originY, model: eomt, mapsSHA256: maps.digest)
        }
        let skyResult = SmartSeed.sky(vetoed, decision: decision, picture: vision, source: source)
        let subject = try AppleSegmentation.subject(vision, source: source), person = try AppleSegmentation.person(vision, source: source)

        // The new Subject's click on the frame: S3OD, the gate where Vision found nothing, the rule's decision, the raster it stores; then ViTMatte's alpha on its seed.
        let box = S3odRun()
        let steps = SmartSeed.SubjectModels(
            region: ModelProvenance(try models.identity(of: .subject)), gate: ModelProvenance(try models.identity(of: .water)), matte: ModelProvenance(try models.identity(of: .matte)),
            runRegion: { let outputs = try await models.subject(for: input); box.set(outputs); return outputs },
            runGate: { try await models.water(for: input) },
            runMatte: { try await models.matte(seed: $0, on: input) })
        let decision2 = rule ?? LowLightRule.decide(.init(), medianLuminance: nil)
        let click = try await SmartSeed.subject(vision: subject, picture: vision, source: source, rule: decision2, models: steps)
        let p = click.provenance.parameters
        let clicked = click.seed.map { String($0.raster.identity.hex.prefix(16)) } ?? "none"
        var alpha = "-"
        if let seed = click.seed {
            if seed.edge == .matte {
                alpha = clicked
            } else {
                let matte = try await models.matte(seed: seed.raster, on: input)
                alpha = String(matte.alpha.identity.hex.prefix(16))
            }
        }
        let run = try #require(box.outputs)
        return Entry(name: name, picture: String(vision.sha256.prefix(16)), gate: gate.score, gatePasses: gate.passes,
                     da3: String(sky.digest.prefix(16)), eomt: mapsDigest, fired: decision.fired,
                     removed: (decision.removedSelectedShare * 10_000).rounded() / 100,
                     soft: (decision.removedSoftShare * 10_000).rounded() / 100,
                     sky: id(skyResult), subject: id(subject), person: id(person),
                     s3od: String(run.digest.prefix(16)), argmax: String(run.selectedIndex), selected: (Double(p["selected.share"] ?? "") ?? .nan) * 100,
                     selection: p["selection"] ?? "?", subjectGate: p["gate.stuffShare"].map { String(format: "%.4f", Double($0) ?? .nan) } ?? "-",
                     rule: rule == nil ? "na" : (rule!.inRule ? "in" : "out"), clicked: clicked, alpha: alpha)
    }

    /// The S3OD outputs of the canary's click, kept for their hash.
    private final class S3odRun: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: S3odOutputs?
        func set(_ outputs: S3odOutputs) { lock.withLock { kept = outputs } }
        var outputs: S3odOutputs? { lock.withLock { kept } }
    }
}
