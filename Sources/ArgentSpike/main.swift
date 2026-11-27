import ArgentCore
import ArgentRoll
import Foundation
import ImageIO
import Metal

// argent-spike: the M0 gate. One 33 MP ARW through decode, a LUT pass, and encode,
// with per-stage timings. The original M0 gate was under 400 ms (docs/M1-spikes.md); the
// app's T4 is in docs/SPEC.md, Performance targets.
// With --stock it runs the M1 film chain instead: Negative LUT, lab balance, Print LUT.

struct Options {
    var inputs: [URL] = []
    var outputDirectory = URL(fileURLWithPath: "argent-out")
    var lutPath: URL?
    var stockPath: URL?
    var settings = DevelopSettings()
    var scale: Float = 1.0
    var longEdge: Int?
    var repeats = 1
    var heic = false
    var skipWarmup = false
    var noiseReduction: Float = 0.5
    var lumaNoiseReduction: Float?
    var lens = LensSettings.default
    var lensCorrection = true
    var defringe: LensSettings.Defringe?
    var lensStage: String?
    var lensScale: Double?
    var measureAnchor = false
    var inHouse = false
    /// RAW 9 rather than RAW 8 for Apple's decoder.
    var learned = false
    /// Light values relative to the frame's automatic development, by control.
    var light: [ManualAdjustments.Control: Float] = [:]
    /// Presence's values, by control, from `--texture` to `--saturation`.
    var presence: [Presence.Control: Float] = [:]
    var manualVersion = ManualRenderSettings.currentVersion
    /// Masks on the frame, in list order, from `--mask`.
    var masks: [Mask] = []
    /// The manual reference in stops; `nil` for the level the print is aimed at.
    var referenceStops: Float?
    /// Each frame printed at its automatic aim, as the app develops it.
    var auto = false
    var tiff = false
    var saveLuminance = false
    /// The arrays `--scene-out`, `--scene-in` and `--print-out` name.
    var sceneOut: URL?
    var sceneIn: URL?
    var printOut: URL?
    var hasArrays: Bool { sceneOut != nil || sceneIn != nil || printOut != nil }
}

func usage() -> Never {
    print("""
    usage: argent-spike <file.ARW | folder> [...] [options]
           argent-spike lens FILE.ARW
           argent-spike cull FOLDER | --scores FILE [cull options]

    options:
      --out DIR        output folder (default: ./argent-out)
      --lut FILE.cube  3D LUT in the log input domain (default: built-in neutral print)
      --stock DIR      baked stock folder from argent-bake: Negative LUT, lab balance, Print LUT
      --rated-at ISO   film speed the roll is rated at (default: the stock's box speed)
      --lab-balance R,G,B
                       print exposure per channel in stops; positive adds that channel (default: 0,0,0)
      --print-exposure STOPS
                       overall print exposure in stops, positive lightens (default: 0)
      --grain X        grain as a multiple of the stock's own, 1 is Natural (default: 0, none)
      --halation       the stock's halation (default: none)
      --sharpen        capture sharpening on the dye amounts (default: none)
      --scale S        decode scale, 1.0 full size, 0.25 quarter-size preview (default: 1.0)
      --long-edge N    write the picture with its longer side N pixels, area-resized as a
                       long-edge develop is (default: the render's own size)
      --repeat N       develop each file N times and report the median (default: 1)
      --heic           write HEIC instead of JPEG
      --tiff           write 16-bit uncompressed TIFF in sRGB instead of JPEG, for measuring
      --auto           develop each frame as the app's Auto does at box speed with Lab balance Auto:
                       measure its 960-pixel decode, print it at its own automatic aim (level and
                       cast), and take the manual reference from that aim's level (with --stock)
      --exposure-ev EV, --contrast V, --highlights V, --shadows V, --whites V, --blacks V
                       the Light controls, relative to the automatic development (with --stock;
                       Exposure -5...5 EV, the others -100...100; default 0, the automatic render)
      \(Presence.Control.allCases.map { $0.flag + " V" }.joined(separator: ", "))
                       Presence's controls, -100...100 (with --stock; default 0). A value whose stage this build does
                       not have yet stops the develop with the piece and the package that builds it
                       (docs/presence-plan.md)
      --manual-version V
                       the manual compiler the Light values are rendered with (default: the current
                       one, \(ManualRenderSettings.currentVersion), whose Highlights and Shadows read the base
                       before Exposure; recorded: \(ManualRenderSettings.exposedBaseVersion), which reads it
                       after, and \(ManualRenderSettings.regionsVersion))
      --mask SHAPE:VALUES  a mask, as many as wanted, in list order (with --stock). SHAPE is
                       linear,FX,FY,ZX,ZY (Full and Zero points) or radial,CX,CY,A,B,ANGLE,FEATHER, in long
                       sides from the top left. VALUES is exposure=-1.5,whites=20,amount=1.5
      --reference-stops S
                       the manual reference, 0.18 * 2^(-S) of scene light (default: the aim's level
                       with --auto, otherwise 0, the level the spike's print is aimed at)
      --save-luminance write <name>.luminance.npy beside each output: the decode's Rec. 2020 luminance
                       before Exposure, float32, top row first, the tone base field's guide
      --scene-out FILE write the decode as the film's render receives it: scene-linear light in linear Rec. 2020
                       primaries (D65 white), middle gray 0.18, unclipped, at the decode's size (--scale sets it;
                       --long-edge resizes only the picture). With --scene-in, FILE's array as the render read it
      --scene-in FILE  render FILE's array in place of the decode. It must have the decode's size, and is rounded
                       to half floats as the decode is held. The render's base fields (Auto's tone step, Highlights
                       and Shadows, halation) are made from it; --auto's aim still comes from the raw's own decode
      --print-out FILE write the render's result before the resize and the encode: display-linear light in linear
                       Rec. 2020 primaries (D65 white), the space the picture is converted to sRGB from, 1 the
                       display's white, no transfer curve and no clipping
                       Each array (with --stock and one raw file) is NumPy .npy 1.0, little-endian float32, C order,
                       shape (height, width, 3), top row first: the render's half floats, widened
      --nr X           color noise reduction 0...1 (default: 0.5)
      --luma-nr X      luminance noise reduction 0...1 (default: keyed to each frame's ISO)
      --lens SETTINGS  distortion=on|off,distortion-amount=0...200 and the Defringe keys below
                       vignette=-100...100,vignette-midpoint=0...100
                       (with --stock; default: distortion on at 100, Defringe off, vignetting 0, midpoint 50)
      --defringe SETTINGS
                       defringe-purple=N,defringe-purple-hue=LO:HI,defringe-green=N,defringe-green-hue=LO:HI
                       repair fringes on the --lens-stage hook (amount 0...20, hue 0...100)
      --lens-stage file-curve | PATH.json
                       correct the scene before the film render, from the file or four radial tables
      --lens-scale N   override the lens stage framing scale
      --no-lens        disable the decoder's lens corrections
      --no-warmup      skip the untimed warm-up develop of the first file
      --decoder NAME   apple (default), Apple's RAW 8; raw9, Apple's RAW 9, the learned
                       demosaic and denoise the app uses for the a7 IV's Bayer modes (--luma-nr on
                       RAW 9's own scale, --nr ignored; files without it are refused); or inhouse:
                       the project's own decoder for a7 IV
                       lossless L and uncompressed files, full frame and APS-C, at any ISO (its
                       route stops at DecoderChoice.inHouseISOLimit), with its own noise reduction (--nr and
                       --luma-nr on Apple's scale) and the file's distortion correction where
                       the camera was set to correct it, as Apple's (--no-lens turns it off);
                       other files are refused (docs/decoder.md)
      --measure-anchor read gray-card raws instead of developing: where the card lands after
                       the pins, and the ExposureAnchor.decodedMidTone it implies

    cull: each frame's fate from its preview scores, one line a frame, then the counts
      FOLDER           score the IFD0 preview of every raw under FOLDER, a card, with Vision;
                       Ctrl-C stops the pass and says how many frames it scored
      --scores FILE    the frames' scores as CullScoreFile JSON
                       (Tests/ArgentCoreTests/Fixtures/titos-scores.json)
      --soft-focus-below Q
                       a face quality below Q is soft focus (default: \(CullSettings().softFocusBelow))
      --eyes-closed-below Q
                       a face quality below Q is eyes closed (default: \(CullSettings().eyesClosedBelow))
      --keep-eyes-closed
                       copy frames with closed eyes (default: leave them on the card)
      --burst-gap S    frames up to S seconds apart are one burst (default: \(CullSettings().burstGap))
      --same-moment-within D
                       a frame within feature-print distance D of its burst's keeper is
                       the same moment (default: \(CullSettings().sameMomentWithin))
    """)
    exit(2)
}

/// `--mask`'s value as a mask, or `nil` where it does not read as one.
func parseMask(_ text: String) -> Mask? {
    let parts = text.split(separator: ":")
    guard parts.count == 2 else { return nil }
    let shape = parts[0].split(separator: ",").map(String.init), numbers = shape.dropFirst().compactMap(Float.init)
    let component: MaskShape
    switch shape.first {
    case "linear" where numbers.count == 4:
        component = .linear(.init(full: MaskPoint(x: numbers[0], y: numbers[1]), zero: MaskPoint(x: numbers[2], y: numbers[3])))
    case "radial" where numbers.count == 6:
        component = .radial(.init(center: MaskPoint(x: numbers[0], y: numbers[1]), semiAxisA: numbers[2], semiAxisB: numbers[3],
                                  angle: numbers[4], feather: numbers[5]))
    default: return nil
    }
    var adjustments = ManualAdjustments.identity, amount: Float = 1
    for item in parts[1].split(separator: ",") {
        let pair = item.split(separator: "=")
        guard pair.count == 2, let value = Float(pair[1]) else { return nil }
        if pair[0] == "amount" { amount = value; continue }
        guard let control = ManualAdjustments.Control(rawValue: String(pair[0])),
              let set = try? adjustments.setting(control, to: value) else { return nil }
        adjustments = set
    }
    return Mask(components: [MaskComponent(shape: component)], amount: amount, adjustments: adjustments)
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--out":
            guard let value = iterator.next() else { usage() }
            options.outputDirectory = URL(fileURLWithPath: value)
        case "--lut":
            guard let value = iterator.next() else { usage() }
            options.lutPath = URL(fileURLWithPath: value)
        case "--stock":
            guard let value = iterator.next() else { usage() }
            options.stockPath = URL(fileURLWithPath: value)
        case "--rated-at":
            guard let value = iterator.next(), let iso = Float(value), iso > 0 else { usage() }
            options.settings.ratedAt = iso
        case "--lab-balance":
            guard let value = iterator.next() else { usage() }
            let parts = value.split(separator: ",").compactMap { Float($0) }
            guard parts.count == 3 else { usage() }
            options.settings.labBalance = SIMD3<Float>(parts[0], parts[1], parts[2])
        case "--halation":
            options.settings.halation = true
        case "--sharpen":
            options.settings.sharpen = true
        case "--grain":
            guard let value = iterator.next().flatMap(Float.init), value >= 0 else { usage() }
            options.settings.grain = value
            options.settings.grainSeed = 1
        case "--print-exposure":
            guard let value = iterator.next(), let stops = Float(value) else { usage() }
            options.settings.printExposure = stops
        case "--scale":
            guard let value = iterator.next(), let scale = Float(value), scale > 0, scale <= 1 else { usage() }
            options.scale = scale
        case "--long-edge":
            guard let value = iterator.next(), let n = Int(value), n >= 1 else { usage() }
            options.longEdge = n
        case "--repeat":
            guard let value = iterator.next(), let n = Int(value), n >= 1 else { usage() }
            options.repeats = n
        case "--heic":
            options.heic = true
        case "--tiff":
            options.tiff = true
        case "--auto":
            options.auto = true
        case "--exposure-ev", "--contrast", "--highlights", "--shadows", "--whites", "--blacks":
            let name = argument == "--exposure-ev" ? "exposure" : String(argument.dropFirst(2))
            guard let control = ManualAdjustments.Control(rawValue: name),
                  let value = iterator.next().flatMap(Float.init) else { usage() }
            options.light[control] = value
        case let flag where Presence.Control(flag: flag) != nil:
            guard let control = Presence.Control(flag: flag), let value = iterator.next().flatMap(Float.init) else { usage() }
            options.presence[control] = value
        case "--manual-version":
            guard let value = iterator.next() else { usage() }
            options.manualVersion = value
        case "--mask":
            guard let value = iterator.next(), let mask = parseMask(value) else { usage() }
            options.masks.append(mask)
        case "--reference-stops":
            guard let value = iterator.next().flatMap(Float.init), value.isFinite else { usage() }
            options.referenceStops = value
        case "--save-luminance":
            options.saveLuminance = true
        case "--scene-out":
            guard let value = iterator.next() else { usage() }
            options.sceneOut = URL(fileURLWithPath: value)
        case "--scene-in":
            guard let value = iterator.next() else { usage() }
            options.sceneIn = URL(fileURLWithPath: value)
        case "--print-out":
            guard let value = iterator.next() else { usage() }
            options.printOut = URL(fileURLWithPath: value)
        case "--nr":
            guard let value = iterator.next(), let nr = Float(value), nr >= 0, nr <= 1 else { usage() }
            options.noiseReduction = nr
        case "--luma-nr":
            guard let value = iterator.next(), let nr = Float(value), nr >= 0, nr <= 1 else { usage() }
            options.lumaNoiseReduction = nr
        case "--lens":
            guard let value = iterator.next(), let lens = try? LensSettings(arguments: value) else { usage() }
            options.lens = lens
        case "--defringe":
            guard let value = iterator.next(), let lens = try? LensSettings(arguments: value) else { usage() }
            options.defringe = lens.defringe
        case "--lens-stage":
            guard let value = iterator.next() else { usage() }
            options.lensStage = value
        case "--lens-scale":
            guard let value = iterator.next().flatMap(Double.init), value.isFinite, value > 0 else { usage() }
            options.lensScale = value
        case "--no-lens":
            options.lensCorrection = false
        case "--no-warmup":
            options.skipWarmup = true
        case "--measure-anchor":
            options.measureAnchor = true
        case "--decoder":
            switch iterator.next() {
            case "apple": (options.inHouse, options.learned) = (false, false)
            case "raw9": (options.inHouse, options.learned) = (false, true)
            case "inhouse": (options.inHouse, options.learned) = (true, false)
            default: usage()
            }
        case "-h", "--help":
            usage()
        default:
            options.inputs.append(URL(fileURLWithPath: argument))
        }
    }
    if arguments.contains("--lens") {
        if options.stockPath == nil || !options.lensCorrection { usage() }
        if options.lensStage != nil && options.sceneIn == nil { usage() }
    }
    if options.inputs.isEmpty { usage() }
    if options.lutPath != nil && options.stockPath != nil { usage() }
    // The Light controls and Auto belong to the film chain; Auto sets the rating and lab balance.
    if options.stockPath == nil && (options.auto || !options.light.isEmpty || !options.presence.isEmpty || options.referenceStops != nil
                                    || !options.masks.isEmpty) { usage() }
    if options.stockPath == nil && options.hasArrays { usage() }
    if options.auto && (options.settings.ratedAt != nil || options.settings.labBalance != .zero) { usage() }
    if options.heic && options.tiff { usage() }
    if options.lensScale != nil && options.lensStage == nil { usage() }
    if options.defringe != nil && options.lensStage == nil { usage() }
    return options
}

/// The Light values as one edit, validated as the app validates them.
func adjustments(_ light: [ManualAdjustments.Control: Float]) throws -> ManualAdjustments {
    try light.reduce(ManualAdjustments.identity) { try $0.setting($1.key, to: $1.value) }
}

/// `texture`'s Rec. 2020 luminance as a float32 `.npy`, top row first: the texture runs from the
/// picture's bottom.
func writeLuminance(_ texture: MTLTexture, to url: URL) throws {
    let width = texture.width, height = texture.height
    let pixels = ExposureAnalyzer.pixels(of: texture)
    var values = [Float](repeating: 0, count: width * height)
    for row in 0..<height {
        let source = (height - 1 - row) * width * 4
        for column in 0..<width {
            let i = source + column * 4
            values[row * width + column] = ManualRenderSettings.luminance(
                SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])))
        }
    }
    var data = npyHeader(shape: [height, width])
    values.withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: url)
}

struct ArrayError: Error, CustomStringConvertible {
    let description: String
}

/// The header's dictionary for little-endian float32 in C order, as `numpy.save` writes it.
func npyDictionary(shape: [Int]) -> String {
    "{'descr': '<f4', 'fortran_order': False, 'shape': (\(shape.map(String.init).joined(separator: ", "))), }"
}

let npyMagic = Data([0x93] + Array("NUMPY".utf8) + [1, 0])

/// A `.npy` 1.0 file's bytes up to its data, for float32 in C order.
func npyHeader(shape: [Int]) -> Data {
    var header = npyDictionary(shape: shape)
    header += String(repeating: " ", count: 63 - (10 + header.utf8.count) % 64) + "\n"
    var data = npyMagic
    withUnsafeBytes(of: UInt16(header.utf8.count).littleEndian) { data.append(contentsOf: $0) }
    data.append(contentsOf: Array(header.utf8))
    return data
}

/// The rows the arrays move at a time, a few megabytes, so a frame's array, 393 MB at 33 MP, is never held whole.
let bandRows = 64

/// `texture`'s RGB as a (height, width, 3) float32 `.npy`, top row first: the texture runs from the picture's bottom.
func writeRGB(_ texture: MTLTexture, to url: URL) throws {
    let width = texture.width, height = texture.height
    guard FileManager.default.createFile(atPath: url.path, contents: npyHeader(shape: [height, width, 3])) else {
        throw ArrayError(description: "could not write \(url.path)")
    }
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.seekToEnd()
    var pixels = [Float16](repeating: 0, count: bandRows * width * 4), values = [Float](repeating: 0, count: bandRows * width * 3)
    for top in stride(from: 0, to: height, by: bandRows) {
        let rows = min(bandRows, height - top)
        pixels.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, height - top - rows, width, rows), mipmapLevel: 0)
        }
        for row in 0..<rows {
            let source = (rows - 1 - row) * width * 4, target = row * width * 3
            for column in 0..<width {
                for channel in 0..<3 { values[target + column * 3 + channel] = Float(pixels[source + column * 4 + channel]) }
            }
        }
        try values.withUnsafeBytes { try file.write(contentsOf: UnsafeRawBufferPointer(rebasing: $0.prefix(rows * width * 12))) }
    }
}

/// The array `writeRGB` writes, read from `url` over `texture`'s RGB in half floats; its alpha stays. Refuses any other
/// type, order or size.
func readRGB(_ url: URL, into texture: MTLTexture) throws {
    let width = texture.width, height = texture.height
    let data = try Data(contentsOf: url, options: .alwaysMapped)
    let wanted = npyDictionary(shape: [height, width, 3])
    guard data.count >= 10, data.prefix(8) == npyMagic else {
        throw ArrayError(description: "\(url.path) is not a NumPy .npy 1.0 file; the render wants \(wanted)")
    }
    let start = 10 + (Int(data[8]) | Int(data[9]) << 8)
    let header = String(decoding: data.prefix(start).dropFirst(10), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard header == wanted else {
        throw ArrayError(description: "\(url.path) holds \(header); the render wants \(wanted)")
    }
    guard data.count == start + width * height * 12 else {
        throw ArrayError(description: "\(url.path) has \(data.count - start) bytes of pixels, not \(width * height * 12)")
    }
    var pixels = [Float16](repeating: 0, count: bandRows * width * 4)
    data.withUnsafeBytes { bytes in
        for top in stride(from: 0, to: height, by: bandRows) {
            let rows = min(bandRows, height - top), region = MTLRegionMake2D(0, height - top - rows, width, rows)
            pixels.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: region, mipmapLevel: 0) }
            for row in 0..<rows {
                let source = start + (top + row) * width * 12, target = (rows - 1 - row) * width * 4
                for column in 0..<width {
                    for channel in 0..<3 {
                        pixels[target + column * 4 + channel] = Float16(
                            bytes.loadUnaligned(fromByteOffset: source + (column * 3 + channel) * 4, as: Float.self))
                    }
                }
            }
            pixels.withUnsafeBytes { texture.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        }
    }
}

func collectRawFiles(_ inputs: [URL]) -> [URL] {
    let fileManager = FileManager.default
    var files: [URL] = []
    for input in inputs {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: input.path, isDirectory: &isDirectory) else {
            FileHandle.standardError.write("skipping missing path \(input.path)\n".data(using: .utf8)!)
            continue
        }
        if isDirectory.boolValue {
            let contents = (try? fileManager.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)) ?? []
            files += contents.filter { $0.pathExtension.lowercased() == "arw" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            files.append(input)
        }
    }
    return files
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let middle = sorted.count / 2
    return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}

func ms(_ seconds: Double) -> String { String(format: "%7.1f", seconds * 1000) }

/// The decoder pins that are the same for every frame, one line per group. The ISO-keyed
/// ones, gain and luminance noise reduction, print per file through `describeFrame`.
func describe(_ pins: DecodePins) -> String {
    let onOff = { (flag: Bool) in flag ? "on" : "off" }
    let moire = pins.moireReduction.map { String($0) } ?? "unsupported"
    return """
    pins     version \(pins.version), decoder \(pins.decoderVersion), \
    anchor \(String(format: "%.3f", pins.anchorDecodedMidTone)) v\(pins.anchorVersion)
    pins     baseline \(pins.baselineExposure), shadow bias \(pins.shadowBias), sharpness \(pins.sharpness), \
    boost \(pins.boost), boost shadow \(pins.boostShadow), gamut mapping \(onOff(pins.gamutMapping)), \
    highlight recovery \(onOff(pins.highlightRecovery)), extended dynamic range \(pins.extendedDynamicRange)
    pins     neutral x \(pins.neutralChromaticity.x) y \(pins.neutralChromaticity.y), moire \(moire), \
    contrast \(pins.contrast), detail \(pins.detail.map { String($0) } ?? "unsupported")
    pins     color nr \(pins.colorNoiseReduction.map { String($0) } ?? "unsupported"), lens corrections \(onOff(pins.lensCorrection)), \
    scale \(pins.scale), draft \(onOff(pins.draftMode))
    """
}

/// The pins that follow each frame: its ISO and its raw mode.
func describeFrame(_ pins: DecodePins) -> String {
    var line = String(format: "gain %+.2f stops, luma nr %.2f, mode %@", pins.exposureGainStops,
                      pins.luminanceNoiseReduction, pins.rawMode ?? "unprofiled")
    if pins.modeExposureStops != 0 { line += String(format: " %+.2f stops", pins.modeExposureStops) }
    if pins.trimColumns > 0 || pins.trimRows > 0 { line += ", trimmed \(pins.trimColumns) columns and \(pins.trimRows) rows" }
    return line
}

func describe(_ readback: DecodeReadback) -> String {
    String(format: "as shot %.0f K tint %.1f, neutral reads back %.0f K tint %.1f",
           readback.asShotTemperature, readback.asShotTint, readback.neutralTemperature, readback.neutralTint)
}

func lens(_ arguments: [String]) -> Never {
    guard arguments.count == 1 else { usage() }
    let url = URL(fileURLWithPath: arguments[0])
    do {
        let metadata = try LensMetadata.read(from: url)
        let corrections = SonyLensCorrection.read(from: url) ?? SonyLensCorrection()
        // JSONSerialization prints a Double at 17 digits (5.5999999999999996); a decimal prints as read.
        func number(_ value: Double) -> NSDecimalNumber { NSDecimalNumber(string: "\(value)") }
        let focus: Any
        switch metadata.focus {
        case .unknown: focus = "unknown"
        case .metres(let distance): focus = ["metres": number(distance)]
        case .infinity: focus = "infinity"
        }
        let record: [String: Any] = [
            "lensModel": metadata.lensModel as Any? ?? NSNull(),
            "lensSpecification": metadata.lensSpecification?.map(number) as Any? ?? NSNull(),
            "lensID": metadata.lensID as Any? ?? NSNull(),
            "focalLength": metadata.focalLength.map(number) as Any? ?? NSNull(),
            "fNumber": metadata.fNumber.map(number) as Any? ?? NSNull(),
            "focus": focus,
            "focusPositionRaw": metadata.focusPositionRaw as Any? ?? NSNull(),
            "crop": metadata.crop.rawValue,
            "corrections": [
                "distortion": ["setting": corrections.distortionSetting as Any? ?? NSNull(),
                               "state": corrections.distortionState.rawValue,
                               "knots": corrections.distortion?.knots as Any? ?? NSNull()],
                "lateralColour": ["setting": corrections.lateralColourSetting as Any? ?? NSNull(),
                                  "state": corrections.lateralColourState.rawValue,
                                  "knots": ["red": corrections.red?.knots as Any? ?? NSNull(),
                                            "blue": corrections.blue?.knots as Any? ?? NSNull()]],
                "shading": ["setting": corrections.shadingSetting as Any? ?? NSNull(),
                            "state": corrections.shadingState.rawValue,
                            "knots": corrections.shading?.knots as Any? ?? NSNull()],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("source error: \(error)\n".utf8))
        exit(1)
    }
}

if CommandLine.arguments.dropFirst().first == "lens" { lens(Array(CommandLine.arguments.dropFirst(2))) }
if CommandLine.arguments.dropFirst().first == "cull" { cull(Array(CommandLine.arguments.dropFirst(2))) }
if CommandLine.arguments.dropFirst().first == "copy" { copyKeepers(Array(CommandLine.arguments.dropFirst(2))) }
let options = parse(CommandLine.arguments)
let light: ManualAdjustments
do {
    light = try adjustments(options.light).settingMasks(try MaskSet(masks: options.masks)).settingPresence(try Presence(options.presence)).settingLens(options.lens)
} catch {
    FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(2)
}
guard light.isIdentity || ManualRenderSettings.supports(version: options.manualVersion) else {
    let message = "error: manual compiler \(options.manualVersion) is not supported by this build "
        + "(current \(ManualRenderSettings.currentVersion))\n"
    FileHandle.standardError.write(message.data(using: .utf8)!)
    exit(2)
}
if !options.lens.isDefault { print("lens     \(options.lens.arguments)") }
let files = collectRawFiles(options.inputs)
guard !files.isEmpty else {
    print("no .ARW files found")
    exit(1)
}
guard !options.hasArrays || files.count == 1 else {
    FileHandle.standardError.write("error: --scene-out, --scene-in and --print-out take one raw file, not \(files.count)\n".data(using: .utf8)!)
    exit(2)
}

/// Gray-card raws, shot filling the frame at exposure compensation 0: decode each with the
/// production pins, read the central fifth, and say what the anchor should be.
func measureAnchor(_ files: [URL]) throws -> Never {
    let gpu = try GPU()
    let decoder = AppleRawDecoder(gpu: gpu)
    var options = DecodeOptions()
    options.scale = 0.25
    print("anchor   decodedMidTone \(ExposureAnchor.decodedMidTone) today; a card should read \(ExposureAnchor.filmMidGray)")
    print("file                 ISO  shutter  f-stop  comp   mode           card Y   spread  off by    implies")
    var errors: [Double] = []
    for file in files {
        let exif = (CGImageSourceCreateWithURL(file as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] })?[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let iso = AppleRawDecoder.isoSpeed(exif: exif) ?? 0
        let shutter = (exif[kCGImagePropertyExifExposureTime as String] as? Double).map { $0 >= 1 ? String(format: "%.1fs", $0) : "1/\(Int((1 / $0).rounded()))" } ?? "?"
        let aperture = (exif[kCGImagePropertyExifFNumber as String] as? Double).map { String(format: "f/%.1f", $0) } ?? "?"
        let bias = exif[kCGImagePropertyExifExposureBiasValue as String] as? Double ?? .nan
        let frame = try decoder.decode(file, options: options)
        let reading = GrayCard.read(frame.texture)
        let name = file.lastPathComponent.padding(toLength: 20, withPad: " ", startingAt: 0)
        let mode = (frame.pins?.rawMode ?? "unprofiled").padding(toLength: 14, withPad: " ", startingAt: 0)
        var flags: [String] = []
        if bias != 0 { flags.append("exposure compensation is not 0") }
        if reading.spread > GrayCard.maximumSpread { flags.append("uneven card, spread \(String(format: "%.2f", reading.spread))") }
        print(String(format: "%@ %5.0f  %-7@  %-6@  %+.1f   %@ %.4f   %.3f   %+.3f EV  %.4f%@", name, iso, shutter, aperture, bias, mode,
                     reading.luminance, reading.spread, reading.anchorErrorStops, reading.impliedDecodedMidTone,
                     flags.isEmpty ? "" : "   (\(flags.joined(separator: "; ")), not counted)"))
        if flags.isEmpty { errors.append(reading.anchorErrorStops) }
    }
    guard !errors.isEmpty else {
        print("no usable frames: shoot the card filling the frame, evenly lit, at exposure compensation 0")
        exit(1)
    }
    let error = median(errors)
    print(String(format: "\nmedian   anchor off by %+.3f EV over %d frames: set ExposureAnchor.decodedMidTone to %.4f", error, errors.count,
                 Double(ExposureAnchor.decodedMidTone) * exp2(error)))
    exit(0)
}

if options.measureAnchor {
    do { try measureAnchor(files) } catch { print("error: \(error)"); exit(1) }
}

do {
    let gpu = try GPU()
    let decoder: RawDecoder = options.inHouse ? try InHouseDecoder(gpu: gpu) : AppleRawDecoder(gpu: gpu)
    let pipeline: DevelopPipeline
    let lookDescription: String
    var note: String?
    var film: Stock?
    if let stockPath = options.stockPath {
        let loadStart = ContinuousClock.now
        let stock = try Stock.load(from: stockPath)
        film = stock
        let loadMilliseconds = Int((ContinuousClock.now - loadStart).milliseconds)
        pipeline = try DevelopPipeline(gpu: gpu, decoder: decoder, stock: stock, settings: options.settings)
        lookDescription = "\(stock.displayName), negative \(stock.negative.size)^3, print \(stock.print.size)^3, "
            + "loaded in \(loadMilliseconds) ms"
        if stock.status == "approximation" {
            note = "stock status is \"approximation\": uses proxy data and is not fitted to scans"
        } else if stock.status != "fitted" && stock.status != "digital" {
            note = "stock status is \"\(stock.status)\": it exercises the pipeline and is not a look"
        }
    } else {
        let lut: LUT3D
        if let lutPath = options.lutPath {
            lut = try LUT3D.parseCube(String(contentsOf: lutPath, encoding: .utf8))
        } else {
            lut = LUT3D.neutralPrint()
        }
        pipeline = try DevelopPipeline(gpu: gpu, decoder: decoder, lut: lut)
        lookDescription = "\(lut.size)^3, \(options.lutPath?.lastPathComponent ?? "built-in neutral print")"
    }
    try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)

    var decodeOptions = DecodeOptions()
    decodeOptions.scale = options.scale
    decodeOptions.colorNoiseReduction = options.noiseReduction
    if options.learned {
        decodeOptions.appleDecoder = .learned
        decodeOptions.learnedLuminanceNoiseReduction = options.lumaNoiseReduction
    } else {
        decodeOptions.luminanceNoiseReduction = options.lumaNoiseReduction
    }
    decodeOptions.lensCorrection = options.lensCorrection && options.lensStage == nil
    let format: OutputFormat = options.heic ? .heic(quality: 0.9) : options.tiff ? .tiff16 : .jpeg(quality: 0.92)

    /// The frame's render settings: the spike's own, or with `--auto` the app's automatic ones
    /// from its sheet measurement, and the Light values about the reference; with what Auto chose.
    func frameSettings(_ file: URL) throws -> (settings: DevelopSettings, auto: String?) {
        var settings = options.settings
        guard let film else { return (settings, nil) }
        var level: Float = 0
        var autoLine: String?
        if options.auto {
            // As FilmPreviews measures a new frame: the lens-off sheet decode, the header's noise model, faces.
            var sheet = DecodeOptions()
            sheet.maxLongSide = FilmPreviews.previewLongSide
            sheet.lensCorrection = false
            sheet.appleDecoder = decodeOptions.appleDecoder
            let analysis = ExposureAnalyzer.measure(try decoder.decode(file, options: sheet), workingSpace: gpu.workingColorSpace,
                                                    info: try? ARWFrameInfo.read(from: file)).analysis
            let aim = AutoPrint.aim(analysis)
            let automatic = RollControls().settings(for: film, aim: aim)
            settings.ratedAt = automatic.ratedAt
            settings.labBalance = automatic.labBalance
            settings.tone = automatic.tone
            level = aim.level
            autoLine = String(format: "aim level %+.3f stops, cast %+.3f,%+.3f,%+.3f", aim.level, aim.cast.x, aim.cast.y, aim.cast.z)
        }
        settings.manual = try ManualRenderSettings(adjustments: light, referenceStops: options.referenceStops ?? level,
                                                   version: options.manualVersion)
        return (settings, autoLine)
    }

    print("device   \(gpu.device.name)")
    print("\(options.stockPath == nil ? "lut     " : "stock   ") \(lookDescription)")
    if options.stockPath != nil {
        let s = options.settings
        print("develop  rated at \(s.ratedAt.map { String($0) } ?? "box speed"), "
              + (options.auto ? "Auto aim and lab balance per frame" : "lab balance \(s.labBalance.x),\(s.labBalance.y),\(s.labBalance.z)")
              + ", print exposure \(s.printExposure)")
        let values = ManualAdjustments.Control.allCases.map { "\($0.rawValue) \(light.value(for: $0))" }.joined(separator: ", ")
        print("light    \(light.isIdentity ? "none, the automatic render" : values + ", compiler \(options.manualVersion)"), "
              + "reference \(options.referenceStops.map { String(format: "%+.3f stops", $0) } ?? (options.auto ? "the aim's level" : "0 stops"))")
        if !light.presence.isIdentity {
            let presence = Presence.Control.allCases.map { "\($0.rawValue) \(light.presence.value(for: $0))" }.joined(separator: ", ")
            print("presence \(presence), constants \(light.presence.version)")
        }
    }
    if let note { print("note     \(note)") }
    print("scale    \(options.scale)\(options.longEdge.map { ", long edge \($0) px" } ?? "")")
    if options.inHouse {
        print("decoder  in-house \(InHouseDecoder.version): its own noise reduction on Apple's scale")
    } else if options.learned {
        print("decoder  Apple's RAW 9: its learned demosaic and denoise, in extended linear sRGB converted to the working space")
    }
    print("decoder  nr \(options.noiseReduction), luma nr \(options.lumaNoiseReduction.map { String($0) } ?? "keyed to ISO"), "
          + "lens corrections off")
    print("files    \(files.count)")

    // The pins are the same for every file apart from the ISO-keyed values, so they print
    // once, after the warm-up when there is one and otherwise after the first develop. The
    // ISO-keyed values print per file.
    var printedPins = false
    func printPinsOnce(_ t: StageTimings) {
        guard !printedPins, let pins = t.pins else { return }
        printedPins = true
        print(describe(pins))
        if options.lensStage == nil, let lens = t.lens {
            print("lens stage  \(lens.isIdentity ? "skipped  " : "distortion ")\(lens.status.distortion.description)")
        }
    }

    let lensStage = try options.lensStage.map { _ in try LensStage(gpu: gpu) }

    // The arrays' own times, by flag, kept out of the stage timings.
    var arrayTimes: [String: [Double]] = [:]
    func timed(_ flag: String, _ body: () throws -> Void) throws {
        let start = ContinuousClock.now
        try body()
        arrayTimes[flag, default: []].append((ContinuousClock.now - start).seconds)
    }
    func beforeRender(_ file: URL) throws -> ((MTLTexture) throws -> Void)? {
        var correction = ResolvedLensCorrection.identity
        if let source = options.lensStage {
            var sizeOptions = decodeOptions
            sizeOptions.maxLongSide = 64
            guard let picture = try decoder.decode(file, options: sizeOptions).picture else {
                throw ArrayError(description: "the decode did not report its full-size picture")
            }
            if source == "file-curve" {
                correction = LensResolver.resolve(SonyLensCorrection.read(from: file), picture: picture, settings: options.lens)
            } else {
                let data = try Data(contentsOf: URL(fileURLWithPath: source))
                guard let rows = try JSONSerialization.jsonObject(with: data) as? [String: [Double]],
                      Set(rows.keys) == Set(["red", "green", "blue", "gain"]) else {
                    throw ArrayError(description: "lens JSON requires exactly red, green, blue and gain knot arrays")
                }
                correction = try ResolvedLensCorrection(red: RadialTable(knots: rows["red"]!),
                                                       green: RadialTable(knots: rows["green"]!),
                                                       blue: RadialTable(knots: rows["blue"]!), gain: RadialTable(knots: rows["gain"]!),
                                                       status: .init(distortion: .file, lateralColour: .file, vignetting: .file),
                                                       width: picture.width, height: picture.height)
                if !options.lens.distortion.isOn || options.lens.distortion.amount == 0 {
                    correction = .identity
                } else if options.lens.distortion.amount != 100 {
                    let tables = try ["red", "green", "blue"].map { channel in
                        let knots = rows[channel]!
                        return try LensAmount.scaled(RadialTable(knots: knots), scale: correction.scale,
                                                     amount: options.lens.distortion.amount, picture: picture).table
                    }
                    correction = try ResolvedLensCorrection(red: tables[0], green: tables[1], blue: tables[2],
                                                           gain: RadialTable(knots: rows["gain"]!),
                                                           status: .init(distortion: .file, lateralColour: .file, vignetting: .file),
                                                           width: picture.width, height: picture.height)
                }
            }
            if let scale = options.lensScale { correction = try correction.reframed(scale: scale) }
        }
        guard options.sceneIn != nil || options.sceneOut != nil || lensStage != nil else { return nil }
        let resolved = correction.defringing(DefringeParameters(options.defringe ?? options.lens.defringe))
        return { texture in
            if let url = options.sceneIn { try timed("--scene-in") { try readRGB(url, into: texture) } }
            if let lensStage {
                let input = LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "spike", scale: options.scale)
                let start = ContinuousClock.now
                let corrected = try lensStage.correct(input, with: resolved)
                let milliseconds = (ContinuousClock.now - start).milliseconds
                if resolved.defringe != nil { print(String(format: "defringe  %.3f ms", milliseconds)) }
                if resolved.isIdentity && resolved.defringe == nil { print("lens stage  skipped") }
                else {
                    print(String(format: "lens stage  distortion %@  scale %.9g  %.3f ms",
                                 options.lensStage!, resolved.scale, milliseconds))
                    // DevelopPipeline's hook accepts a texture, so hand the corrected pixels back through it.
                    guard let buffer = gpu.queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
                    guard let blit = buffer.makeBlitCommandEncoder() else { throw GPUError.noEncoder }
                    blit.copy(from: corrected.texture, to: texture)
                    blit.endEncoding()
                    buffer.commit()
                    withExtendedLifetime(corrected) { buffer.waitUntilCompleted() }
                    if let error = buffer.error { throw error }
                }
            }
            if let url = options.sceneOut { try timed("--scene-out") { try writeRGB(texture, to: url) } }
        }
    }
    let afterRender = options.printOut.map { url in
        { (texture: MTLTexture) in try timed("--print-out") { try writeRGB(texture, to: url) } }
    }

    if !options.skipWarmup, let first = files.first {
        let warm = options.outputDirectory.appendingPathComponent("warmup.\(format.fileExtension)")
        let hook = options.lensStage == nil ? nil : try beforeRender(first)
        let t = try pipeline.develop(first, to: warm, options: decodeOptions, format: format, longEdge: options.longEdge,
                                     settings: try frameSettings(first).settings, beforeRender: hook)
        try? FileManager.default.removeItem(at: warm)
        print("decoder  \(t.decoderVersion)")
        print(String(format: "warm-up  %.0f ms (shader compile and decoder start, not counted)", t.total * 1000))
        printPinsOnce(t)
    }

    print("")
    print("file             size         decode     lut  lut-gpu  encode    total   (ms)")
    var totals: [Double] = []
    var decodes: [Double] = []
    for file in files {
        var runs: [StageTimings] = []
        let output = options.outputDirectory
            .appendingPathComponent(file.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(format.fileExtension)
        let frame = try frameSettings(file)
        let beforeRender = try beforeRender(file)
        for _ in 0..<options.repeats {
            runs.append(try pipeline.develop(file, to: output, options: decodeOptions, format: format,
                                             longEdge: options.longEdge, settings: frame.settings,
                                             beforeRender: beforeRender, afterRender: afterRender))
        }
        printPinsOnce(runs[0])
        let decode = median(runs.map(\.decode))
        let lutTime = median(runs.map(\.lut))
        let lutGPU = median(runs.map(\.lutGPU))
        let encode = median(runs.map(\.encode))
        let total = median(runs.map(\.total))
        totals.append(total)
        decodes.append(decode)
        let name = file.lastPathComponent.padding(toLength: 16, withPad: " ", startingAt: 0)
        let size = "\(runs[0].width)x\(runs[0].height)".padding(toLength: 12, withPad: " ", startingAt: 0)
        print("\(name) \(size)\(ms(decode)) \(ms(lutTime)) \(ms(lutGPU)) \(ms(encode)) \(ms(total))")
        if let pins = runs[0].pins {
            print("  pins:    \(describeFrame(pins))")
        }
        if let readback = runs[0].readback {
            print("  neutral: \(describe(readback))")
        }
        if let auto = frame.auto {
            print("  auto:    \(auto)")
        }
        if !arrayTimes.isEmpty {
            let times = ["--scene-in", "--scene-out", "--print-out"].compactMap { flag in
                arrayTimes[flag].map { "\(flag) \(String(format: "%.0f", median($0) * 1000)) ms" }
            }
            print("  arrays:  (\(runs[0].height), \(runs[0].width), 3), " + times.joined(separator: ", "))
        }
        if options.saveLuminance {
            let luminance = output.deletingPathExtension().appendingPathExtension("luminance.npy")
            try writeLuminance(try decoder.decode(file, options: decodeOptions).texture, to: luminance)
            print("  guide:   \(luminance.lastPathComponent)")
        }
    }
    print("")
    print(String(format: "median total %.1f ms over %d files, median decode %.1f ms",
                 median(totals) * 1000, files.count, median(decodes) * 1000))
    print("output   \(options.outputDirectory.path)")
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
