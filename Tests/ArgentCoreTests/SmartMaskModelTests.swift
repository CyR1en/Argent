import CoreAI
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Metal
import Testing
@testable import ArgentCore

/// The repository's root, its CC0 sample, the canary picture and the models `scripts/convert-*.zsh` build.
enum SmartMaskFixtures {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let canaryPicture = root.appendingPathComponent("scripts/models/canary-DSC06673.png")
    static let sample = root.appendingPathComponent("samples/ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW")
    /// `ARGENT_MASK_MODELS`, or `build/models`.
    static var models: URL {
        ProcessInfo.processInfo.environment["ARGENT_MASK_MODELS"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("build/models")
    }
    static var modelsPresent: Bool {
        BundledMaskModel.allCases.allSatisfy {
            FileManager.default.fileExists(atPath: models.appendingPathComponent("\($0.fileName)/main.hash").path)
        }
    }
    static var hasSample: Bool { FileManager.default.fileExists(atPath: sample.path) }
    static var measuring: Bool { ProcessInfo.processInfo.environment["ARGENT_MEASURE"] == "1" }

    static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("argent-mask-models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The canary picture's 768 × 512 RGB bytes, as stored.
    static func canaryRGB() throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithURL(canaryPicture as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 768 && image.height == 512 && image.bitsPerComponent == 8)
        let data = try #require(image.dataProvider?.data) as Data
        let bytesPerPixel = image.bitsPerPixel / 8
        var rgb = [UInt8](repeating: 0, count: 768 * 512 * 3)
        for y in 0..<512 { for x in 0..<768 { for c in 0..<3 { rgb[(y * 768 + x) * 3 + c] = data[y * image.bytesPerRow + x * bytesPerPixel + c] } } }
        return rgb
    }

    /// The canary squares `canary_check.py` makes: EoMT's the whole picture at row 128 of 768, DA3's its centre 756 × 504 at row 126.
    static func canarySquares() throws -> (sky: ModelSquare, water: ModelSquare) {
        let rgb = try canaryRGB()
        var centre = [UInt8](repeating: 0, count: 756 * 504 * 3)
        for y in 0..<504 { for x in 0..<756 { for c in 0..<3 { centre[(y * 756 + x) * 3 + c] = rgb[((y + 4) * 768 + x + 6) * 3 + c] } } }
        return (ModelSquare(contentRGB8: centre, layout: ModelSquareLayout(side: 756, contentWidth: 756, contentHeight: 504, originX: 0, originY: 126)),
                ModelSquare(contentRGB8: rgb, layout: ModelSquareLayout(side: 768, contentWidth: 768, contentHeight: 512, originX: 0, originY: 128)))
    }

    /// S3OD's canary square (`canary_s3od.py`): the 768 × 512 picture centred in the 1024 square, black all round.
    static func canaryS3odSquare() throws -> ModelSquare {
        ModelSquare(contentRGB8: try canaryRGB(), layout: ModelSquareLayout(side: 1024, contentWidth: 768, contentHeight: 512, originX: 128, originY: 256), padding: .black)
    }

    /// ViTMatte's canary tile (`canary_vitmatte.py`): the picture centred in the 1024 square on black, normalised (x / 255 − 0.5) / 0.5, the trimap a rectangle: 255 in its interior,
    /// 128 in the 32 pixel band along its inside edge, 0 outside it.
    static func canaryMatteTile() throws -> [Float16] {
        let rgb = try canaryRGB(), side = 1024, plane = side * side, top = (side - 512) / 2, left = (side - 768) / 2
        let (y0, y1, x0, x1) = (top + 64, top + 512 - 64, left + 64, left + 768 - 64)
        func tri(_ y: Int, _ x: Int) -> UInt8 {
            guard y >= y0, y < y1, x >= x0, x < x1 else { return 0 }
            return y >= y0 + 32 && y < y1 - 32 && x >= x0 + 32 && x < x1 - 32 ? 255 : 128
        }
        var tile = [Float16](repeating: 0, count: 4 * plane)
        for y in 0..<side {
            for x in 0..<side {
                let inPicture = y >= top && y < top + 512 && x >= left && x < left + 768
                for c in 0..<3 {
                    let code: UInt8 = inPicture ? rgb[((y - top) * 768 + x - left) * 3 + c] : 0
                    tile[c * plane + y * side + x] = Float16((Float(code) / 255 - 0.5) / 0.5)
                }
                tile[3 * plane + y * side + x] = Float16(Float(tri(y, x)) / 255)
            }
        }
        return tile
    }

    static func sha256(_ values: [Float16]) -> String {
        values.withUnsafeBytes { SHA256.hash(data: $0) }.map { String(format: "%02x", $0) }.joined()
    }

    /// The process's physical footprint now and at its peak, in MB, as S1b and S5 measured.
    static func footprintMB() -> (now: Double, peak: Double) {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return (.nan, .nan) }
        return (Double(info.ri_phys_footprint) / 1e6, Double(info.ri_lifetime_max_phys_footprint) / 1e6)
    }

    /// The CC0 sample decoded as the frame view decodes it at `longSide` (RAW 9, filling the long side).
    static func decodeSample(gpu: GPU, longSide: Int = 4912) throws -> LinearFrame {
        var options = DecodeOptions()
        options.maxLongSide = longSide
        options.fillsMaxLongSide = true
        options.appleDecoder = .learned
        return try AppleRawDecoder(gpu: gpu).decode(sample, options: options)
    }
}

@Suite struct ModelSquareTests {
    @Test func aThreeTwoFrameSitsWherePhaseZerosSquaresPutIt() {
        // S1b's DA3 square: 756 × 504 at row 126, portrait 504 × 756 at column 126; S5's EoMT square: 768 × 512 at row 128.
        #expect(ModelSquareLayout(side: 756, width: 2560, height: 1707)
                == ModelSquareLayout(side: 756, contentWidth: 756, contentHeight: 504, originX: 0, originY: 126))
        #expect(ModelSquareLayout(side: 756, width: 1707, height: 2560)
                == ModelSquareLayout(side: 756, contentWidth: 504, contentHeight: 756, originX: 126, originY: 0))
        #expect(ModelSquareLayout(side: 768, width: 2560, height: 1707)
                == ModelSquareLayout(side: 768, contentWidth: 768, contentHeight: 512, originX: 0, originY: 128))
        // A 4:3 frame keeps its shape, where S1b's prototype stretched it to 756 × 504.
        #expect(ModelSquareLayout(side: 756, width: 2560, height: 1920)
                == ModelSquareLayout(side: 756, contentWidth: 756, contentHeight: 567, originX: 0, originY: 94))
    }

    @Test func theSquareRepeatsTheEdgeAndIsNormalisedAsNumpyDoes() {
        let layout = ModelSquareLayout(side: 4, contentWidth: 4, contentHeight: 2, originX: 0, originY: 1)
        let content: [UInt8] = (0..<24).map { UInt8($0 * 10) }
        let square = ModelSquare(contentRGB8: content, layout: layout)
        func value(_ c: Int, _ x: Int, _ y: Int) -> Float16 { square.input[c * 16 + y * 4 + x] }
        func expected(_ code: UInt8, _ c: Int) -> Float16 {
            Float16(((Float(code) / 255) - ModelSquare.mean[c]) / ModelSquare.std[c])
        }
        for c in 0..<3 {
            for x in 0..<4 {
                #expect(value(c, x, 0) == expected(content[x * 3 + c], c))          // row 0 repeats the content's first row
                #expect(value(c, x, 1) == expected(content[x * 3 + c], c))
                #expect(value(c, x, 2) == expected(content[(4 + x) * 3 + c], c))
                #expect(value(c, x, 3) == expected(content[(4 + x) * 3 + c], c))    // and row 3 its last
            }
        }
    }

    /// The Sky model's square mirrors the picture past its edge about the edge pixel for one of DA3's patches, then repeats that
    /// patch's last line (task H), so the patch at the frame's edge sees the scene go on rather than a smear; the content itself is the
    /// same either way, and the water model's square still repeats the edge (S5's).
    @Test func theSkySquareMirrorsOnePatchPastTheEdge() {
        let layout = ModelSquareLayout(side: 8, contentWidth: 8, contentHeight: 4, originX: 0, originY: 2)
        let content: [UInt8] = (0..<(8 * 4 * 3)).map { UInt8($0 * 2) }
        let mirrored = ModelSquare(contentRGB8: content, layout: layout, padding: .mirror)
        let band = ModelSquare(contentRGB8: content, layout: layout, padding: ModelSquare.Padding(mirrored: 1))
        let repeated = ModelSquare(contentRGB8: content, layout: layout, padding: .edge)
        #expect(mirrored.padding == .mirror && repeated.padding == .edge && band.padding.mirrored == 1)
        func value(_ square: ModelSquare, _ c: Int, _ x: Int, _ y: Int) -> Float16 { square.input[c * 64 + y * 8 + x] }
        func expected(_ row: Int, _ x: Int, _ c: Int) -> Float16 {
            Float16(((Float(content[(row * 8 + x) * 3 + c]) / 255) - ModelSquare.mean[c]) / ModelSquare.std[c])
        }
        // Square rows 0 to 7 read the content's rows 2, 1, then 0 to 3, then 2, 1 mirrored (OpenCV's BORDER_REFLECT_101); with one
        // line mirrored, 1, 1, 0 to 3, 2, 2; with none, 0, 0, 0 to 3, 3, 3.
        for (square, rows) in [(mirrored, [2, 1, 0, 1, 2, 3, 2, 1]), (band, [1, 1, 0, 1, 2, 3, 2, 2]), (repeated, [0, 0, 0, 1, 2, 3, 3, 3])] {
            for c in 0..<3 {
                for x in 0..<8 {
                    for (y, row) in rows.enumerated() { #expect(value(square, c, x, y) == expected(row, x, c)) }
                }
            }
        }
        #expect(ModelSquare.source(-5, count: 4, padding: .mirror) == 1 && ModelSquare.source(9, count: 4, padding: .mirror) == 3)
        #expect(ModelSquare.source(-3, count: 1, padding: .mirror) == 0 && ModelSquare.source(-30, count: 504, padding: SkyModelRunner.padding) == 14)
        #expect(SkyModelRunner.padding == ModelSquare.Padding(mirrored: 14) && EomtModelRunner.padding == .edge)
        #expect(SkyModelRunner.squareRecipe == "square 756, area-resized, centred, padding mirror 14, then edge")
        #expect(ModelSquare.recipe(side: 756, padding: .edge) == "square 756, area-resized, centred, padding edge")
    }

    @Test func areaResizeAveragesBlocksAndKeepsAFlatField() {
        // 4 × 2 to 2 × 1: each output the mean of a 2 × 2 block, rounded half to even.
        let rgb: [UInt8] = [0, 0, 0, 10, 10, 10, 100, 100, 100, 101, 101, 101,
                            20, 20, 20, 31, 31, 31, 200, 200, 200, 201, 201, 201]
        #expect(ModelSquare.areaResize(rgb, width: 4, height: 2, toWidth: 2, height: 1) == [15, 15, 15, 150, 150, 150])
        let flat = [UInt8](repeating: 77, count: 2560 * 1707 * 3)
        #expect(Set(ModelSquare.areaResize(flat, width: 2560, height: 1707, toWidth: 756, height: 504)) == [77])
    }

    @Test func cropAndResampleReadTheContentOnly() {
        let layout = ModelSquareLayout(side: 8, contentWidth: 8, contentHeight: 4, originX: 0, originY: 2)
        let plane: [Float] = (0..<64).map { (i: Int) -> Float in Float(i / 8) }    // each row its index
        let contentRows: [Float] = (0..<32).map { (i: Int) -> Float in Float(2 + i / 8) }
        #expect(ModelSquare.crop(plane, planeSide: 8, layout: layout) == contentRows)
        // A quarter-size plane whose value is its row: the content's rows 2...5 of 8 are rows 0.5...1.5 of 2 at their centres.
        let quarter: [Float] = [0, 0, 1, 1]
        let rows = ModelSquare.resample(quarter, planeSide: 2, layout: layout, toWidth: 2, height: 2)
        // y = (2 + (i + 0.5) × 4 / 2) / 4 − 0.5: 0.25 and 0.75.
        #expect(rows == [0.25, 0.25, 0.75, 0.75])
        #expect(Set(ModelSquare.resample([Float](repeating: 0.3, count: 4), planeSide: 2, layout: layout, toWidth: 5, height: 3)) == [0.3])
    }
}

/// `EomtMaps.resampled` against P0-S5's golden files (`out/golden_sq768_t05`, derived from private frames, so outside Git): the
/// water map resampled to the seed's grid as its veto read it. `ARGENT_S5_GOLDEN` names the folder.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ARGENT_S5_GOLDEN"] != nil)) struct EomtResampleGoldenTests {
    @Test func theWaterMapReachesTheSeedGridAsS5sVetoReadIt() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARGENT_S5_GOLDEN"]!)
        let ids = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".meta.json") }
            .map { String($0.dropLast(".meta.json".count)) })
        #expect(!ids.isEmpty)
        func floats(_ name: String) throws -> [Float] {
            try Data(contentsOf: folder.appendingPathComponent(name)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        var worst: Float = 0
        for id in ids.sorted() {
            let meta = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("\(id).meta.json"))) as? [String: Any])
            let geo = try #require(meta["geo"] as? [String: Any])
            let (w, h) = (try #require(meta["w"] as? Int), try #require(meta["h"] as? Int))
            let layout = ModelSquareLayout(side: try #require(geo["H"] as? Int), contentWidth: try #require(geo["w"] as? Int),
                                           contentHeight: try #require(geo["h"] as? Int), originX: try #require(geo["left"] as? Int),
                                           originY: try #require(geo["top"] as? Int))
            // S5's squares are this layout's for the picture's own size (the seed's grid was S1b's 756 × 504 even for a crop).
            let picture = (Int((Double(layout.contentWidth) / (geo["scale_x"] as? Double ?? 1)).rounded()),
                           Int((Double(layout.contentHeight) / (geo["scale_y"] as? Double ?? 1)).rounded()))
            #expect(layout == ModelSquareLayout(side: 768, width: picture.0, height: picture.1), "\(id)")
            let raw = try floats("\(id).waterraw.f32"), expected = try floats("\(id).waterseed.f32")
            let maps = EomtMaps(layout: layout, water: raw, sky: raw, classIndex: raw)
            let resampled = maps.resampled(raw, toWidth: w, height: h)
            let difference = zip(resampled, expected).map { abs($0 - $1) }.max() ?? .infinity
            let flips = zip(resampled, expected).filter { ($0 >= 0.5) != ($1 >= 0.5) }.count
            worst = max(worst, difference)
            #expect(difference < 1e-5 && flips == 0, "\(id): \(difference), \(flips) flips")
        }
        print("MEASURE EoMT resample against S5's \(ids.count) golden frames: largest difference \(worst)")
    }
}

@Suite struct MaskInputPictureTests {
    @Test func theSizeIsTheFixedLongSideOrTheRawsOwn() {
        #expect(MaskInputPicture.size(decodeWidth: 4912, decodeHeight: 3275) == (2560, 1707))
        #expect(MaskInputPicture.size(decodeWidth: 3275, decodeHeight: 4912) == (1707, 2560))
        #expect(MaskInputPicture.size(decodeWidth: 2000, decodeHeight: 1333) == (2000, 1333))
        // A scaled decode shorter than the picture cannot make it; the whole raw can.
        #expect(!MaskInputPicture.canBeMade(fromDecodeLongSide: 2190, scale: 0.31))
        #expect(MaskInputPicture.canBeMade(fromDecodeLongSide: 2000, scale: 1))
        #expect(MaskInputPicture.canBeMade(fromDecodeLongSide: 4912, scale: 0.7))
    }

    /// A linear frame lit 1.0 over its top half and 0.01 under it comes out top row first, 2560 pixels long, in the neutral print's
    /// codes, tagged sRGB.
    @Test func aDecodeIsPrintedTopRowFirstAtTheFixedSize() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let (w, h) = (3000, 2000)
        let texture = try gpu.makeTexture(width: w, height: h)
        var halves = [Float16](repeating: 1, count: w * h * 4)
        // Argent's textures hold the picture's bottom row first: rows 0..<1000 are the picture's lower half.
        for y in 0..<(h / 2) { for x in 0..<w { for c in 0..<3 { halves[(y * w + x) * 4 + c] = 0.01 } } }
        halves.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 8) }
        let frame = LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "test", scale: 0.5)
        let picture = try MaskInputPictureMaker(gpu: gpu).make(from: frame)
        #expect((picture.width, picture.height) == (2560, 1707))
        #expect(picture.image.colorSpace?.name == CGColorSpace.sRGB && picture.image.bitsPerPixel == 32)
        #expect(picture.source == MaskInputPicture.Source(decodeWidth: w, decodeHeight: h, decoderVersion: "test", pinsVersion: nil,
                                                           pinsDecoderVersion: nil, decodeScale: 0.5))
        func code(_ linear: Float) -> Int { Int((LUT3D.srgbEncode(LUT3D.filmicPlaceholder(SIMD3(repeating: linear)).x) * 255).rounded()) }
        picture.withPixels { bytes, rowBytes in
            let top = Int(bytes[10 * rowBytes + 100 * 4]), bottom = Int(bytes[1690 * rowBytes + 100 * 4])
            #expect(abs(top - code(1)) <= 3, "top \(top), the print of 1.0 \(code(1))")
            #expect(abs(bottom - code(0.01)) <= 3, "bottom \(bottom), the print of 0.01 \(code(0.01))")
            #expect(bytes[3] == 255)
        }
        #expect(picture.provenance(sourceSHA256: "abc") == RasterProvenance.Input(kind: "neutral-print", decoderVersion: "test", width: 2560,
                                                                                    height: 1707, colorSpace: "sRGB", sourceSHA256: "abc"))
        // A scaled decode too small for it.
        let small = LinearFrame(image: try gpu.texturePool.acquire(width: 2190, height: 1460), decoderVersion: "test", scale: 0.3)
        #expect(throws: MaskInputError.decodeTooSmall(longSide: 2190)) { try MaskInputPictureMaker(gpu: gpu).make(from: small) }
    }

    /// The decode's median luminance, read a strip of rows at a time and counted, is the number the whole decode read back and
    /// selected gives, to the bit: on a decode several strips tall whose last strip is short, even and odd in its count.
    @Test(arguments: [(1500, 1101), (1501, 1101), (700, 300)])
    func theMedianLuminanceIsTheWholeDecodes(w: Int, h: Int) throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let texture = try gpu.makeTexture(width: w, height: h)
        var halves = [Float16](repeating: 1, count: w * h * 4)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15 &+ UInt64(w)
        func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }
        // A scene's spread: most of it dark, some of it near and past 1, a little of it just under 0, as a decode's blacks are.
        for i in 0..<(w * h) {
            let v = next(), level = v * v * 1.4 - 0.002
            halves[i * 4] = Float16(level * 1.1); halves[i * 4 + 1] = Float16(level); halves[i * 4 + 2] = Float16(level * 0.7)
        }
        halves.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 8) }
        var luma = (0..<(w * h)).map { i in
            0.2627 * Float(halves[i * 4]) + 0.6780 * Float(halves[i * 4 + 1]) + 0.0593 * Float(halves[i * 4 + 2])
        }
        let whole = try #require(LowLightRule.median(&luma))
        #expect(w * h > MaskInputPictureMaker.medianStripTexels || h < 400, "the larger ones span several strips")
        #expect(MaskInputPictureMaker.medianLuminance(of: texture)?.bitPattern == whole.bitPattern)
        #expect(whole > 0.05 && whole < 0.6)
    }

    /// The CC0 sample through the frame view's decode (RAW 9 at 4912 pixels), the picture, and the canary's resize, against the
    /// canary picture, which came from `argent-spike`'s 2560-pixel JPEG of a full-size decode (P0-S5): the same picture within the
    /// JPEG's noise and the two decodes' difference, and the right way up.
    @Test(.enabled(if: SmartMaskFixtures.hasSample))
    func theSamplesPictureIsPhaseZerosPrint() throws {
        let gpu = try GPU()
        let frame = try SmartMaskFixtures.decodeSample(gpu: gpu)
        let picture = try MaskInputPictureMaker(gpu: gpu).make(from: frame)
        #expect(picture.width == 2560)
        let small = picture.withPixels { bytes, rowBytes in
            ModelSquare.areaResize(bytes, width: picture.width, height: picture.height, bytesPerPixel: 4, bytesPerRow: rowBytes, toWidth: 768, height: 512)
        }
        let canary = try SmartMaskFixtures.canaryRGB()
        // The 2560 picture resized again on the CPU, and the content the models get, resized from the print on the GPU (route B).
        for (name, content) in [("picture, then the CPU", small), ("print to 768 on the GPU", try #require(picture.modelContents[768]))] {
            let differences = zip(content, canary).map { abs(Int($0) - Int($1)) }.sorted()
            let mean = Double(differences.reduce(0, +)) / Double(differences.count)
            let p99 = differences[differences.count * 99 / 100]
            print(String(format: "MEASURE DSC06673 from a %d × %d decode, %@, against the canary picture: mean %.2f codes, p99 %d, max %d",
                         frame.width, frame.height, name, mean, p99, differences.last!))
            #expect(mean < 3 && p99 < 16)
        }
        #expect(picture.modelContents[756]?.count == 756 * 504 * 3)
    }
}

@Suite struct MaskModelsTests {
    /// A folder that looks like `build/models` to `MaskModels`, without the weights: `main.hash` and the manifest.
    static func fakeModels(canary: (BundledMaskModel) -> String = { $0.canarySHA256 }) throws -> URL {
        let folder = try SmartMaskFixtures.temporaryFolder()
        for model in BundledMaskModel.allCases {
            let file = folder.appendingPathComponent(model.fileName, isDirectory: true)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            try Data(repeating: model == .sky ? 0xab : 0xcd, count: 32).write(to: file.appendingPathComponent("main.hash"))
            let manifest = ["recipe id": model.recipeID, "weights sha256": model.weightsSHA256, "canary output sha256": canary(model)]
            try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent(model.manifestName))
        }
        return folder
    }

    @Test func withoutTheModelsSkyIsUnavailableAndSaysHowToBuildThem() throws {
        let empty = try SmartMaskFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: empty) }
        for directory in [empty, nil] {
            let models = MaskModels(directory: directory, ledgerFile: empty.appendingPathComponent("ledger.json"))
            #expect(!models.isSkyAvailable && models.unavailable.count == BundledMaskModel.allCases.count && !models.isSubjectAvailable)
            #expect(!models.needsPreparation)
            #expect(throws: MaskModelError.self) { try models.url(of: .sky) }
            #expect(models.unavailable.first?.description.contains("scripts/convert-da3-sky.zsh") == true)
        }
    }

    /// Sky needs DA3 and EoMT and nothing else: a lost Subject model must not take Sky with it, and Subject says which model it lost.
    @Test func skyAndSubjectEachNeedOnlyTheirOwnModels() throws {
        for lost in [BundledMaskModel.subject, .matte] {
            let folder = try Self.fakeModels()
            defer { try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.removeItem(at: folder.appendingPathComponent(lost.fileName, isDirectory: true))
            let models = MaskModels(directory: folder, ledgerFile: folder.appendingPathComponent("ledger.json"))
            #expect(models.isSkyAvailable && !models.isSubjectAvailable)
            #expect(models.subjectMissing?.description.contains(lost.rawValue) == true && models.subjectMissing?.description.contains(lost.script) == true)
        }
        let folder = try Self.fakeModels()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.removeItem(at: folder.appendingPathComponent(BundledMaskModel.sky.fileName, isDirectory: true))
        let models = MaskModels(directory: folder, ledgerFile: folder.appendingPathComponent("ledger.json"))
        #expect(!models.isSkyAvailable && models.isSubjectAvailable, "EoMT is Subject's gate, DA3 is Sky's alone")
        // Sky says which model it lost, as Subject does: what a download that held Subject's three alone left a Mac with.
        #expect(models.skyMissing?.description.contains(BundledMaskModel.sky.rawValue) == true && models.skyMissing?.description.contains(BundledMaskModel.sky.script) == true)
        #expect(models.subjectMissing == nil)
    }

    @Test func aModelIsKnownByItsManifestAndItsFileByMainHash() throws {
        let folder = try Self.fakeModels()
        defer { try? FileManager.default.removeItem(at: folder) }
        let models = MaskModels(directory: folder, ledgerFile: folder.appendingPathComponent("ledger.json"))
        #expect(models.isSkyAvailable)
        #expect(try models.identity(of: .sky) == MaskModelIdentity(recipeID: "da3-mono-large-sq756-f16-sky-depth-1",
                                                                   weightsSHA256: BundledMaskModel.sky.weightsSHA256,
                                                                   canarySHA256: BundledMaskModel.sky.canarySHA256,
                                                                   fileSHA256: String(repeating: "ab", count: 32), options: "default"))
        // A file another recipe made computes something else: refused, so no seed names the wrong model.
        let other = try Self.fakeModels(canary: { $0 == .water ? String(repeating: "0", count: 64) : $0.canarySHA256 })
        defer { try? FileManager.default.removeItem(at: other) }
        let refused = MaskModels(directory: other, ledgerFile: other.appendingPathComponent("ledger.json"))
        #expect(!refused.isSkyAvailable)
        #expect(refused.unavailable.map(\.description).first?.contains("eomt-sq768-f16 is unavailable: it was built by recipe") == true)
    }

    @Test func preparationIsNeededOnFirstUseAfterAnOSUpdateAndForANewFile() throws {
        let folder = try Self.fakeModels()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledgerFile = folder.appendingPathComponent("Support/Mask models.json")
        let models = MaskModels(directory: folder, ledgerFile: ledgerFile)
        #expect(models.needsPreparation)
        func write(build: String, skyFile: String) throws {
            var ledger = MaskModels.Ledger()
            for model in BundledMaskModel.allCases {
                ledger.models[model.rawValue] = .init(fileSHA256: model == .sky ? skyFile : try models.identity(of: model).fileSHA256,
                                                      osBuild: build, options: "default", bookmark: Data(), prepared: Date())
            }
            try FileManager.default.createDirectory(at: ledgerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ledger).write(to: ledgerFile)
        }
        let skyFile = try models.identity(of: .sky).fileSHA256
        try write(build: MaskModels.osBuild, skyFile: skyFile)
        #expect(!models.needsPreparation)
        try write(build: "1A1", skyFile: skyFile)
        #expect(models.needsPreparation)
        try write(build: MaskModels.osBuild, skyFile: String(repeating: "0", count: 64))
        #expect(models.needsPreparation)
        #expect(MaskModels.osBuild.count >= 5 && MaskModels.osBuild != "unknown")
    }

    /// The pins here are the recipes' own.
    @Test func thePinsAreTheRecipes() throws {
        for model in BundledMaskModel.allCases {
            let script = try String(contentsOf: SmartMaskFixtures.root.appendingPathComponent(
                model.script), encoding: .utf8)
            func pinned(_ name: String) -> String? {
                script.split(separator: "\n").first { $0.hasPrefix(name + "=") }
                    .map { String($0.dropFirst(name.count + 1).prefix { !$0.isWhitespace }) }
            }
            #expect(pinned("RECIPE_ID") == model.recipeID)
            #expect(pinned("WEIGHTS_SHA256") == model.weightsSHA256)
            #expect(pinned("CANARY_SHA256") == model.canarySHA256)
            #expect(pinned("CANARY_INPUT_SHA256") == model.canaryInputSHA256)
        }
    }

    /// Multi-directory lookup takes each model from the first folder that holds its file, and falls through to later folders for the rest.
    @Test func multiDirectoryPrecedenceTakesTheFirstFolderHoldingAModel() throws {
        let root = try SmartMaskFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("Bundled", isDirectory: true)
        let downloaded = root.appendingPathComponent("Downloaded", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloaded, withIntermediateDirectories: true)

        func write(_ model: BundledMaskModel, in folder: URL, hashByte: UInt8, canary: String? = nil) throws {
            let dir = folder.appendingPathComponent(model.fileName, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: hashByte, count: 32).write(to: dir.appendingPathComponent("main.hash"))
            let manifest = ["recipe id": model.recipeID, "weights sha256": model.weightsSHA256, "canary output sha256": canary ?? model.canarySHA256]
            try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent(model.manifestName))
        }

        // Bundled holds Sky and EoMT (0x11); Downloaded holds EoMT (0x22), S3OD and ViTMatte.
        try write(.sky, in: bundled, hashByte: 0x11)
        try write(.water, in: bundled, hashByte: 0x11)
        try write(.water, in: downloaded, hashByte: 0x22)
        try write(.subject, in: downloaded, hashByte: 0x22)
        try write(.matte, in: downloaded, hashByte: 0x22)

        let models = MaskModels(directories: [bundled, downloaded], ledgerFile: root.appendingPathComponent("ledger.json"))
        #expect(models.isSkyAvailable && models.isSubjectAvailable)
        #expect(models.folder(of: .sky) == bundled)
        #expect(models.folder(of: .water) == bundled)
        #expect(models.folder(of: .subject) == downloaded)
        #expect(models.folder(of: .matte) == downloaded)
        #expect(try models.url(of: .water) == bundled.appendingPathComponent(BundledMaskModel.water.fileName, isDirectory: true))
        #expect(try models.identity(of: .water).fileSHA256 == String(repeating: "11", count: 32))
        #expect(try models.url(of: .subject) == downloaded.appendingPathComponent(BundledMaskModel.subject.fileName, isDirectory: true))
        #expect(try models.identity(of: .subject).fileSHA256 == String(repeating: "22", count: 32))

        // A bad manifest in the earlier folder does not fall through silently.
        try write(.subject, in: bundled, hashByte: 0x33, canary: String(repeating: "0", count: 64))
        #expect(models.folder(of: .subject) == bundled)
        #expect(!models.isSubjectAvailable)
        #expect(throws: MaskModelError.self) { try models.url(of: .subject) }
    }

    /// An invalid copy in a non-downloadable folder (the app bundle) shadows the downloadable folder and cannot be fixed by downloading,
    /// even when another dependency is genuinely missing; an invalid copy only in the downloadable folder can be replaced by downloading.
    @Test func statusDistinguishesMissingModelsFromInvalidBundledCopies() throws {
        let root = try SmartMaskFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("Bundled", isDirectory: true)
        let downloaded = root.appendingPathComponent("Downloaded", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloaded, withIntermediateDirectories: true)

        func write(_ model: BundledMaskModel, in folder: URL, hashBytes: Data = Data(repeating: 0x11, count: 32), canary: String? = nil) throws {
            let dir = folder.appendingPathComponent(model.fileName, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try hashBytes.write(to: dir.appendingPathComponent("main.hash"))
            let manifest = ["recipe id": model.recipeID, "weights sha256": model.weightsSHA256, "canary output sha256": canary ?? model.canarySHA256]
            try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent(model.manifestName))
        }

        let models = MaskModels(directories: [bundled, downloaded], downloadableDirectory: downloaded, ledgerFile: root.appendingPathComponent("ledger.json"))
        // Neither folder has models: downloading satisfies both Sky and Subject.
        guard case .needsDownload = models.status(of: MaskModels.skyModels) else { Issue.record("expected needsDownload for empty Sky"); return }
        guard case .needsDownload = models.status(of: MaskModels.subjectModels) else { Issue.record("expected needsDownload for empty Subject"); return }

        // A corrupt/mismatched copy only in the downloadable folder can be replaced by downloading.
        try write(.sky, in: downloaded, canary: String(repeating: "0", count: 64))
        try write(.water, in: downloaded)
        guard case .needsDownload = models.status(of: MaskModels.skyModels) else { Issue.record("expected needsDownload for invalid downloaded DA3"); return }

        // Put valid copies in downloaded, then shadow DA3 with an invalid bundled copy: downloading cannot repair it.
        try write(.sky, in: downloaded)
        try write(.sky, in: bundled, canary: String(repeating: "0", count: 64))
        if case .invalid(let error) = models.status(of: MaskModels.skyModels) {
            #expect(error.description.contains(BundledMaskModel.sky.rawValue))
            #expect(error.description.contains(BundledMaskModel.sky.script))
        } else {
            Issue.record("expected invalid for bad bundled DA3, got \(models.status(of: MaskModels.skyModels))")
        }

        // Remove bundled DA3 (and downloaded DA3) so DA3 is genuinely missing, while bundled EoMT has a corrupt main.hash:
        // missing DA3 must not hide the invalid bundled EoMT.
        try FileManager.default.removeItem(at: bundled.appendingPathComponent(BundledMaskModel.sky.fileName))
        try FileManager.default.removeItem(at: downloaded.appendingPathComponent(BundledMaskModel.sky.fileName))
        try write(.water, in: bundled, hashBytes: Data([0x01, 0x02]))
        if case .invalid(let error) = models.status(of: MaskModels.skyModels) {
            #expect(error.description.contains(BundledMaskModel.water.rawValue))
            #expect(error.description.contains("main.hash"))
        } else {
            Issue.record("expected invalid for missing DA3 + bad bundled EoMT, got \(models.status(of: MaskModels.skyModels))")
        }
        if case .invalid(let error) = models.status(of: MaskModels.subjectModels) {
            #expect(error.description.contains(BundledMaskModel.water.rawValue))
        } else {
            Issue.record("expected invalid for bad bundled EoMT in Subject, got \(models.status(of: MaskModels.subjectModels))")
        }
    }
}

/// The models' canary (docs/masking-plan.md section 8): their outputs' hashes on the CC0 sample's canary squares, which a macOS
/// update that changes what they compute changes. Runs when `build/models` holds all four models (`scripts/convert-*.zsh`), or
/// `ARGENT_MASK_MODELS` names a folder that does; it leaves no compiled copy behind.
@Suite(.serialized, .enabled(if: SmartMaskFixtures.modelsPresent))
struct MaskModelCanaryTests {
    @Test func theCanaryHashesAreThePinnedOnes() async throws {
        let support = try SmartMaskFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let models = MaskModels(directory: SmartMaskFixtures.models, ledgerFile: support.appendingPathComponent("ledger.json"))
        #expect(models.isSkyAvailable, "\(models.unavailable)")
        let squares = try SmartMaskFixtures.canarySquares()
        #expect(SmartMaskFixtures.sha256(squares.sky.input) == BundledMaskModel.sky.canaryInputSHA256)
        #expect(SmartMaskFixtures.sha256(squares.water.input) == BundledMaskModel.water.canaryInputSHA256)
        let subjectSquare = try SmartMaskFixtures.canaryS3odSquare()
        #expect(SmartMaskFixtures.sha256(subjectSquare.input) == BundledMaskModel.subject.canaryInputSHA256)
        let matteTile = try SmartMaskFixtures.canaryMatteTile()
        #expect(SmartMaskFixtures.sha256(matteTile) == BundledMaskModel.matte.canaryInputSHA256)
        defer { for model in BundledMaskModel.allCases { try? AIModelCache.default.deleteEntries(for: try models.url(of: model)) } }

        try await models.skyRunner.load(from: try models.url(of: .sky))
        let sky = try await models.skyRunner.run(squares.sky), skyAgain = try await models.skyRunner.run(squares.sky)
        await models.skyRunner.unload()
        print("MEASURE DA3 canary \(sky.digest), \(String(format: "%.3f", skyAgain.seconds)) s warm")
        #expect(sky.digest == BundledMaskModel.sky.canarySHA256 && skyAgain.digest == sky.digest)
        #expect(!sky.sky.contains { $0.isNaN } && !sky.depth.contains { $0.isNaN })

        try await models.subjectRunner.load(from: try models.url(of: .subject))
        let region = try await models.subjectRunner.run(subjectSquare), regionAgain = try await models.subjectRunner.run(subjectSquare)
        await models.subjectRunner.unload()
        print("MEASURE S3OD canary \(region.digest), argmax \(region.selectedIndex)")
        #expect(region.digest == BundledMaskModel.subject.canarySHA256 && regionAgain.digest == region.digest)

        try await models.matteRunner.load(from: try models.url(of: .matte))
        let alpha = try await models.matteRunner.run(tile: matteTile), alphaAgain = try await models.matteRunner.run(tile: matteTile)
        await models.matteRunner.unload()
        let matteDigest = MaskModelError.digest(of: [alpha])
        print("MEASURE ViTMatte canary \(matteDigest)")
        #expect(matteDigest == BundledMaskModel.matte.canarySHA256 && MaskModelError.digest(of: [alphaAgain]) == matteDigest)

        let maps = try await models.water(for: squares.water, keepLoaded: true), mapsAgain = try await models.water(for: squares.water)
        let stillLoaded = await models.waterRunner.isLoaded
        #expect(!stillLoaded)
        print("MEASURE EoMT canary \(maps.digest), \(String(format: "%.3f", mapsAgain.seconds)) s warm")
        #expect(maps.digest == BundledMaskModel.water.canarySHA256 && mapsAgain.digest == maps.digest)
        // S5's reading of the canary: tree, plant, wall, building, door; no water.
        #expect(maps.water.allSatisfy { $0 < 0.5 })
    }
}

extension MaskModels {
    /// `water(for:)` on a square already made, for the canary.
    func water(for square: ModelSquare, keepLoaded: Bool = false) async throws -> EomtMaps {
        if await !waterRunner.isLoaded { try await waterRunner.load(from: try url(of: .water)) }
        let maps = try await waterRunner.run(square)
        if !keepLoaded { await waterRunner.unload() }
        return maps
    }
}

/// What the models cost, as P0-S1b and P0-S5 measured it: "Preparing masks" from cold Core AI caches, loads, warm calls on the CC0
/// sample's picture, the footprint after unloading, and the stale-copy rule. `ARGENT_MEASURE=1`, with the models built and the sample
/// fetched; `ARGENT_STALE_MODEL` may name a second conversion of DA3 (another `main.hash`) to show a stale copy deleted by bookmark
/// after its file is gone. Everything it compiles it deletes. Timings mean little while another job holds the GPU.
@Suite(.serialized, .enabled(if: SmartMaskFixtures.measuring && SmartMaskFixtures.modelsPresent && SmartMaskFixtures.hasSample))
struct MaskModelMeasureTests {
    @Test func preparationRunsAndUnloads() async throws {
        let support = try SmartMaskFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let models = MaskModels(directory: SmartMaskFixtures.models, ledgerFile: support.appendingPathComponent("Mask models.json"))
        for model in BundledMaskModel.allCases { try? AIModelCache.default.deleteEntries(for: try models.url(of: model)) }
        defer { try? models.deleteCompiledCopies() }
        #expect(models.needsPreparation)
        let steps = StepLog()
        let started = ContinuousClock.now
        let report = try await models.prepare { steps.add($0) }
        let wall = (ContinuousClock.now - started).seconds
        print(String(format: "MEASURE Preparing masks, Core AI caches cold: %.2f s; specialise DA3 %.2f, EoMT %.2f; warm DA3 %.2f, EoMT %.2f s; %d steps told",
                     wall, report.specialiseSeconds[.sky] ?? .nan, report.specialiseSeconds[.water] ?? .nan,
                     report.warmSeconds[.sky] ?? .nan, report.warmSeconds[.water] ?? .nan, steps.count))
        #expect(!models.needsPreparation)
        #expect(steps.last?.step == .done && steps.last?.fraction == 1)
        let again = ContinuousClock.now
        try await models.prepare()
        print(String(format: "MEASURE Preparing masks again, prepared: %.2f s", (ContinuousClock.now - again).seconds))

        let gpu = try GPU()
        let decodeStarted = ContinuousClock.now
        let frame = try SmartMaskFixtures.decodeSample(gpu: gpu)
        let decodeSeconds = (ContinuousClock.now - decodeStarted).seconds
        let maker = try MaskInputPictureMaker(gpu: gpu)
        _ = try maker.make(from: frame)
        var pictureTimes: [Double] = []
        var picture = try maker.make(from: frame)
        for _ in 0..<10 {
            let t = ContinuousClock.now
            picture = try maker.make(from: frame)
            pictureTimes.append((ContinuousClock.now - t).seconds)
        }
        var squareTimes: [Double] = []
        for _ in 0..<5 {
            let t = ContinuousClock.now
            _ = ModelSquare(picture, side: SkyModelRunner.side, padding: SkyModelRunner.padding)
            squareTimes.append((ContinuousClock.now - t).seconds)
        }
        print(String(format: "MEASURE input picture from a %d × %d decode (%.2f s): median %.1f ms; DA3's square from it %.1f ms",
                     frame.width, frame.height, decodeSeconds, median(pictureTimes) * 1000, median(squareTimes) * 1000))

        let base = SmartMaskFixtures.footprintMB().now
        var t = ContinuousClock.now
        _ = try await models.sky(for: picture)
        let firstSky = (ContinuousClock.now - t).seconds
        var skyTimes: [Double] = []
        var outputs: SkyOutputs?
        for _ in 0..<20 { outputs = try await models.sky(for: picture); skyTimes.append(outputs!.seconds) }
        let skyRunning = SmartMaskFixtures.footprintMB()
        await models.unloadSky()
        try await Task.sleep(for: .seconds(2))
        let afterSky = SmartMaskFixtures.footprintMB().now
        t = ContinuousClock.now
        _ = try await models.water(for: picture)
        let firstWater = (ContinuousClock.now - t).seconds
        var waterTimes: [Double] = [], clickTimes: [Double] = []
        for _ in 0..<10 { t = ContinuousClock.now; _ = try await models.water(for: picture); clickTimes.append((ContinuousClock.now - t).seconds) }
        for _ in 0..<20 { waterTimes.append(try await models.water(for: picture, keepLoaded: true).seconds) }
        let waterRunning = SmartMaskFixtures.footprintMB()
        await models.unloadAll()
        try await Task.sleep(for: .seconds(2))
        let afterWater = SmartMaskFixtures.footprintMB()
        let seed = try #require(outputs).seed
        print(String(format: "MEASURE DA3 on the sample: first (load and run) %.3f s, warm min %.3f median %.3f s; footprint %.0f MB before, %.0f running, %.0f 2 s after unload; seed %d × %d, %.1f %% at 0.5",
                     firstSky, skyTimes.min()!, median(skyTimes), base, skyRunning.now, afterSky, seed.width, seed.height,
                     100 * Double(seed.values.filter { $0 >= 0.5 }.count) / Double(seed.values.count)))
        print(String(format: "MEASURE EoMT on the sample: first (load, run, unload) %.3f s, a gated click's load-run-unload median %.3f s, warm call min %.3f median %.3f s; footprint %.0f MB running, %.0f 2 s after unload, peak %.0f MB",
                     firstWater, median(clickTimes), waterTimes.min()!, median(waterTimes), waterRunning.now, afterWater.now, afterWater.peak))
    }

    /// S5's lifecycle, in a process that holds nothing else (run it alone): the footprint at each step, two seconds after each
    /// unload, one model after the other and both resident.
    @Test func footprintThroughLoadRunAndUnload() async throws {
        let support = try SmartMaskFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let models = MaskModels(directory: SmartMaskFixtures.models, ledgerFile: support.appendingPathComponent("Mask models.json"))
        try await models.prepare()
        defer { try? models.deleteCompiledCopies() }
        var line: [String] = []
        func note(_ step: String) { line.append(String(format: "%@ %.0f", step, SmartMaskFixtures.footprintMB().now)) }
        let sky = MaskModels.blankSquare(side: SkyModelRunner.side), water = MaskModels.blankSquare(side: EomtModelRunner.side)
        try await Task.sleep(for: .seconds(2))
        note("start")
        try await models.skyRunner.load(from: models.url(of: .sky)); note("DA3 loaded")
        for _ in 0..<3 { _ = try await models.skyRunner.run(sky) }; note("DA3 run")
        await models.skyRunner.unload(); note("unloaded")
        try await Task.sleep(for: .seconds(2)); note("+2 s")
        try await models.waterRunner.load(from: models.url(of: .water)); note("EoMT loaded")
        for _ in 0..<3 { _ = try await models.waterRunner.run(water) }; note("EoMT run")
        await models.waterRunner.unload(); note("unloaded")
        try await Task.sleep(for: .seconds(2)); note("+2 s")
        try await models.skyRunner.load(from: models.url(of: .sky)); try await models.waterRunner.load(from: models.url(of: .water))
        _ = try await models.skyRunner.run(sky); _ = try await models.waterRunner.run(water); note("both resident, run")
        await models.unloadAll(); note("both unloaded")
        try await Task.sleep(for: .seconds(2)); note("+2 s")
        print("MEASURE footprint MB, one process: " + line.joined(separator: ", ")
              + String(format: "; lifetime peak %.0f", SmartMaskFixtures.footprintMB().peak))
    }

    /// S5's stale-copy rule: a compiled copy whose model file is gone (an update replaced the bundle) is deleted by the bookmark
    /// "Preparing masks" stored when it made it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ARGENT_STALE_MODEL"] != nil))
    func aStaleCopyIsDeletedByItsBookmark() async throws {
        let support = try SmartMaskFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let ledger = support.appendingPathComponent("Mask models.json")
        func folder(_ name: String, sky: URL) throws -> URL {
            let folder = support.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for model in BundledMaskModel.allCases {
                let from = model == .sky ? sky : SmartMaskFixtures.models
                try FileManager.default.copyItem(at: from.appendingPathComponent(model.fileName), to: folder.appendingPathComponent(model.fileName))
                try FileManager.default.copyItem(at: from.appendingPathComponent(model.manifestName), to: folder.appendingPathComponent(model.manifestName))
            }
            return folder
        }
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/coreai-cache/\(MaskModels.osBuild)")
        // The first build of the app: one conversion of DA3, prepared, then its file replaced by an update.
        let old = try folder("old", sky: SmartMaskFixtures.models)
        let oldModels = MaskModels(directory: old, ledgerFile: ledger)
        try await oldModels.prepare()
        let oldHash = try oldModels.identity(of: .sky).fileSHA256
        let withOld = Self.bytes(cache)
        try FileManager.default.removeItem(at: old)
        // The update: another conversion of DA3, the same model by its canary, another file and so another compiled copy.
        let new = try folder("new", sky: URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARGENT_STALE_MODEL"]!))
        let newModels = MaskModels(directory: new, ledgerFile: ledger)
        #expect(try newModels.identity(of: .sky).fileSHA256 != oldHash)
        #expect(newModels.needsPreparation)
        let report = try await newModels.prepare()
        let after = Self.bytes(cache)
        print(String(format: "MEASURE stale copy: coreai-cache %.0f MB with the old file's copy, %.0f MB after the update's preparation (deleted by bookmark: %@)",
                     Double(withOld) / 1e6, Double(after) / 1e6, report.staleDeleted.map(\.rawValue).joined(separator: ", ")))
        #expect(report.staleDeleted == [.sky])
        try newModels.deleteCompiledCopies()
        try FileManager.default.removeItem(at: new)
    }

    static func bytes(_ folder: URL) -> Int {
        var total = 0
        if let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let file as URL in files { total += (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0 }
        }
        return total
    }
}

private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [MaskPreparationProgress] = []
    func add(_ step: MaskPreparationProgress) { lock.withLock { steps.append(step) } }
    var count: Int { lock.withLock { steps.count } }
    var last: MaskPreparationProgress? { lock.withLock { steps.last } }
}
