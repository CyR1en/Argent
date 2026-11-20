import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
import Vision
@testable import ArgentCore

/// Snap to Object's times, and its selections on real pictures for the plan's check of 30 objects from the owner's rolls
/// (docs/remove-plan.md, section 5, package G: usable on 25 or more, or the switch ships off). Not regressions. Off unless
/// ARGENT_MEASURE=1, one test at a time:
///
///     ARGENT_MEASURE=1 swift test --filter ObjectSelectorMeasureTests/aClickAndARefinement
///     ARGENT_MEASURE=1 ARGENT_SNAP_SET=<prompts.txt> swift test --filter ObjectSelectorMeasureTests/aSetOfPrompts
///
/// `aSetOfPrompts` reads ARGENT_SNAP_SET, a text file with a prompt a line, beside the pictures it names (anything ImageIO
/// reads; a name has no space in it):
///
///     # The picture, what was done, and where: fractions of the picture from its top left, or pixels of the file when over 1.
///     DSC01234.jpg click 0.42 0.61
///     DSC01234.jpg click 0.42 0.61 not 0.50 0.70
///     DSC01234.jpg stroke 40 0.38 0.62 0.45 0.70
///
/// A click may be followed by `not` and the places of its Option-clicks. A stroke is its brush's width, in pixels of the file or
/// as a fraction of its longer side, then the places it passes through. A picture longer than the mask input picture
/// (`MaskInputPicture.longSide`) is reduced to it, since that is what the app gives the selector.
///
/// It writes into ARGENT_SNAP_OUT, or a folder `snap` beside the set: for each prompt `<line>-<picture>-<what>.png`, the picture
/// with the selection tinted and outlined in magenta, the prompt in yellow (a ring where Vision was pointed, the edge of a
/// stroke's paint) and Option-clicks in cyan; and `timings.txt`, a line a selection. A stroke is selected twice, as the app
/// reads it (at the middle of its paint) and as the request's scribble buffer (`-scribble.png`), so the two can be compared.
@Suite(.serialized) struct ObjectSelectorMeasureTests {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { environment["ARGENT_MEASURE"] == "1" }

    static func milliseconds<T>(_ body: () async throws -> T) async rethrows -> (time: Double, value: T) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try await body()
        return (Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6, value)
    }

    static func summary(_ times: [Double]) -> String {
        let sorted = times.sorted()
        return String(format: "median %.1f ms, %.1f to %.1f", sorted[sorted.count / 2], sorted[0], sorted[sorted.count - 1])
    }

    static func load() -> String {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? String(format: "%.1f", loads[0]) : "unknown"
    }

    /// A click and a refinement against the masking plan's 55 ms and 15 ms (reported there, R2), on the drawn shapes at the
    /// size of the picture the app is given: Vision's request by itself, then the selector, which adds the wait for its turn,
    /// the mask's conversion and, for a stroke, the search for the middle of its paint.
    @Test(.enabled(if: ObjectSelectorMeasureTests.enabled))
    func aClickAndARefinement() async throws {
        guard await SnapModel.isReady() else {
            print("MEASURE snap: Vision's segmentation model is not ready on this Mac; nothing was timed")
            return
        }
        let scene = SnapScene.shapes(width: 2560, height: 1707)
        let disc = try ObjectSelector.visionPoint(x: SnapScene.discCentre.x, y: SnapScene.discCentre.y)
        let square = try ObjectSelector.visionPoint(x: SnapScene.squareCentre.x, y: SnapScene.squareCentre.y)
        let rounds = 20
        #if DEBUG
        let build = "debug build"
        #else
        let build = "release build"
        #endif

        let first = try await Self.milliseconds { try await GenerateIterativeSegmentationRequest(seedPoint: disc).perform(on: scene.image, orientation: .up) }
        var clicks: [Double] = [], refinements: [Double] = []
        for _ in 0..<rounds {
            let request = GenerateIterativeSegmentationRequest(seedPoint: disc)
            clicks.append(try await Self.milliseconds { try await request.perform(on: scene.image, orientation: .up) }.time)
            try request.addExcludedPoint(square)
            refinements.append(try await Self.milliseconds { try await request.perform(on: scene.image, orientation: .up) }.time)
        }
        print(String(format: "MEASURE snap on %dx%d, load %@: the first request in the process %.0f ms", scene.width, scene.height, Self.load(), first.time))
        print("MEASURE snap Vision alone, \(rounds) rounds: a click \(Self.summary(clicks)) (masking plan: 55 ms)")
        print("MEASURE snap Vision alone, \(rounds) rounds: a refinement \(Self.summary(refinements)) (masking plan: 15 ms)")

        let stroke = scene.stroke([(0.22, 0.25), (0.29, 0.31)], brush: 43)
        let click = ObjectSelector.Prompt.point(x: SnapScene.discCentre.x, y: SnapScene.discCentre.y)
        let runs: [(String, ObjectSelector, ObjectSelector.Prompt, [(x: Float, y: Float)])] = [
            ("a click", ObjectSelector(), click, []),
            ("a click with an Option-click", ObjectSelector(), click, [SnapScene.squareCentre]),
            ("a stroke, at the middle of its paint", ObjectSelector(), stroke, []),
            ("a stroke, as a scribble buffer", ObjectSelector(strokes: .scribble), stroke, []),
        ]
        for (name, selector, prompt, excluded) in runs {
            var times: [Double] = []
            for _ in 0..<rounds {
                times.append(try await Self.milliseconds { try await selector.select(prompt, excluded: excluded, in: scene.image) }.time)
            }
            print("MEASURE snap the selector (\(build)), \(rounds) rounds: \(name) \(Self.summary(times))")
        }
        guard case .scribble(let width, let height, let coverage) = stroke else { return }
        var search: [Double] = []
        for _ in 0..<rounds { search.append(await Self.milliseconds { ObjectSelector.middles(width: width, height: height, paint: coverage) }.time) }
        print("MEASURE snap the selector (\(build)), \(rounds) rounds: the middle of a stroke's paint alone \(Self.summary(search))")

        // The mask's conversion alone, on a mask like Vision's of the disc, and inside it the selection's own check that it
        // holds something (`RemovalPipeline.Selection.init`).
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, scene.width, scene.height, kCVPixelFormatType_OneComponent16Half, nil, &made)
        let mask = try #require(made)
        CVPixelBufferLockBaseAddress(mask, [])
        let base = try #require(CVPixelBufferGetBaseAddress(mask)), rowBytes = CVPixelBufferGetBytesPerRow(mask)
        for y in 0..<scene.height {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float16.self)
            for x in 0..<scene.width { row[x] = scene.labels[y * scene.width + x] == UInt8(SnapScene.disc) ? 1 : 0 }
        }
        CVPixelBufferUnlockBaseAddress(mask, [])
        var conversion: [Double] = [], check: [Double] = []
        for _ in 0..<rounds {
            let converted = try await Self.milliseconds { try ObjectSelector.selection(from: mask, width: scene.width, height: scene.height) }
            conversion.append(converted.time)
            let coverage = converted.value.coverage
            check.append(try await Self.milliseconds { try RemovalPipeline.Selection(width: scene.width, height: scene.height, coverage: coverage) }.time)
        }
        print("MEASURE snap the selector (\(build)), \(rounds) rounds: the mask as a selection alone \(Self.summary(conversion))")
        print("MEASURE snap the selector (\(build)), \(rounds) rounds: of that, the selection's own check that it holds something \(Self.summary(check))")

        // That check reads the plane until it meets the selection, so it costs most for an object low in the picture.
        var low = [UInt8](repeating: 0, count: scene.width * scene.height)
        low[low.count - 1] = 255
        var lowest: [Double] = []
        for _ in 0..<5 {
            lowest.append(try await Self.milliseconds { try RemovalPipeline.Selection(width: scene.width, height: scene.height, coverage: low) }.time)
        }
        print("MEASURE snap the selector (\(build)), 5 rounds: that check for a selection in the picture's last row \(Self.summary(lowest))")
    }

    /// The prompts of ARGENT_SNAP_SET, each as an overlay and a line of timing.
    @Test(.enabled(if: ObjectSelectorMeasureTests.enabled && ObjectSelectorMeasureTests.environment["ARGENT_SNAP_SET"] != nil))
    func aSetOfPrompts() async throws {
        let set = URL(fileURLWithPath: try #require(Self.environment["ARGENT_SNAP_SET"]))
        let folder = set.deletingLastPathComponent()
        let out = Self.environment["ARGENT_SNAP_OUT"].map { URL(fileURLWithPath: $0) } ?? folder.appendingPathComponent("snap")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let availability = await ObjectSelector().availability()
        guard availability == .ready else {
            print("MEASURE snap: Snap to Object is \(availability) on this Mac; nothing was selected")
            return
        }

        var report: [String] = []
        func say(_ line: String) {
            report.append(line)
            print("MEASURE snap \(line)")
        }
        var pictures: [String: Photo] = [:]
        var warmed = false
        let lines = try String(contentsOf: set, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        for (index, text) in lines.enumerated() {
            let words = text.split(separator: " ").map(String.init)
            guard let name = words.first, !name.hasPrefix("#") else { continue }
            let number = String(format: "%02d", index + 1)
            do {
                if pictures[name] == nil { pictures[name] = try Photo(folder.appendingPathComponent(name)) }
                let photo = try #require(pictures[name])
                let asked = try Asked(words.dropFirst(), in: photo)
                if !warmed {
                    // The model's load is the first request's, once a process, and not any prompt's.
                    let warm = await Self.milliseconds { try? await ObjectSelector().select(.point(x: 0.5, y: 0.5), in: photo.image) }
                    say(String(format: "the first request in the process, on %@ (%dx%d): %.0f ms, load %@", name, photo.width, photo.height, warm.time, Self.load()))
                    warmed = true
                }
                let stem = "\(number)-\(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent)-\(asked.kind)"
                var readings: [(suffix: String, what: String, selector: ObjectSelector)] = [("", asked.kind, ObjectSelector())]
                if asked.kind == "stroke" { readings.append(("-scribble", "stroke as a scribble buffer", ObjectSelector(strokes: .scribble))) }
                for reading in readings {
                    let line = "\(number) \(name) \(reading.what)"
                    do {
                        let made = try await Self.milliseconds { try await reading.selector.select(asked.prompt, excluded: asked.excluded, in: photo.image) }
                        let selected = made.value.coverage.reduce(0) { $0 + ($1 >= 128 ? 1 : 0) }
                        let file = "\(stem)\(reading.suffix).png"
                        try photo.overlay(made.value, asked: asked, middles: reading.suffix.isEmpty).write(to: out.appendingPathComponent(file))
                        say(String(format: "%@: %.1f ms, %d px, %.2f %% of the picture, %@", line, made.time, selected,
                                   100 * Double(selected) / Double(photo.width * photo.height), file))
                    } catch let failure as ObjectSelector.Failure {
                        say("\(line): \(failure)")
                    }
                }
            } catch {
                say("\(number) \(text): could not be run: \(error)")
                Issue.record("line \(index + 1) of \(set.lastPathComponent) could not be run: \(error)")
            }
        }
        try (report.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("timings.txt"), atomically: true, encoding: .utf8)
        print("MEASURE snap wrote \(out.path)")
    }

    // MARK: a picture of the set

    /// A picture as the app would give it to the selector: upright, no longer than the mask input picture, 8-bit sRGB.
    struct Photo {
        let image: CGImage
        let width: Int
        let height: Int
        /// The file's own size, upright, which is what a place given in pixels counts in.
        let fileWidth: Double
        let fileHeight: Double
        private let bytes: [UInt8]

        init(_ url: URL) throws {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: MaskInputPicture.longSide]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let reduced = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Double,
                  let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Double else {
                throw MaskError.invalid("\(url.lastPathComponent) can be read")
            }
            let picture = try AppleSegmentation.Picture(reduced)
            image = picture.image
            width = picture.width
            height = picture.height
            bytes = picture.bytes
            // Orientations 5 to 8 are a file stored on its side.
            let onItsSide = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
            fileWidth = onItsSide ? pixelHeight : pixelWidth
            fileHeight = onItsSide ? pixelWidth : pixelHeight
        }

        /// The picture with `selection` tinted and outlined, and what was asked drawn over it.
        func overlay(_ selection: RemovalPipeline.Selection, asked: Asked, middles: Bool) -> Overlay {
            var pixels = bytes
            func paint(_ x: Int, _ y: Int, _ colour: (UInt8, UInt8, UInt8), mix: Int = 100) {
                guard x >= 0, y >= 0, x < width, y < height else { return }
                let i = (y * width + x) * 4
                for (channel, value) in [colour.0, colour.1, colour.2].enumerated() {
                    pixels[i + channel] = UInt8((Int(pixels[i + channel]) * (100 - mix) + Int(value) * mix) / 100)
                }
            }
            /// Whether `plane` is on at a pixel and off at one beside it.
            func isEdge(_ plane: [UInt8], _ x: Int, _ y: Int) -> Bool {
                guard plane[y * width + x] >= 128 else { return false }
                return x == 0 || y == 0 || x == width - 1 || y == height - 1 || plane[y * width + x - 1] < 128
                    || plane[y * width + x + 1] < 128 || plane[(y - 1) * width + x] < 128 || plane[(y + 1) * width + x] < 128
            }
            func ring(_ place: (x: Float, y: Float), _ colour: (UInt8, UInt8, UInt8)) {
                let radius = max(8, Double(max(width, height)) / 160)
                let (cx, cy) = (Double(place.x) * Double(width), Double(place.y) * Double(height))
                for y in Int(cy - radius - 3)...Int(cy + radius + 3) {
                    for x in Int(cx - radius - 3)...Int(cx + radius + 3) {
                        let distance = ((Double(x) + 0.5 - cx) * (Double(x) + 0.5 - cx) + (Double(y) + 0.5 - cy) * (Double(y) + 0.5 - cy)).squareRoot()
                        if abs(distance - radius) <= 1.5 { paint(x, y, colour) } else if abs(distance - radius) <= 3 { paint(x, y, (0, 0, 0)) }
                    }
                }
            }
            let magenta: (UInt8, UInt8, UInt8) = (255, 0, 255), yellow: (UInt8, UInt8, UInt8) = (255, 220, 0), cyan: (UInt8, UInt8, UInt8) = (0, 220, 255)
            for y in 0..<height {
                for x in 0..<width where selection.coverage[y * width + x] >= 128 {
                    paint(x, y, magenta, mix: isEdge(selection.coverage, x, y) ? 100 : 45)
                }
            }
            switch asked.prompt {
            case .point(let x, let y):
                ring((x, y), yellow)
            case .scribble(_, _, let coverage):
                for y in 0..<height {
                    for x in 0..<width where isEdge(coverage, x, y) {
                        for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] { paint(x + dx, y + dy, yellow) }
                    }
                }
                if middles {
                    for middle in ObjectSelector.middles(width: width, height: height, paint: coverage) { ring(middle, yellow) }
                }
            }
            for place in asked.excluded { ring(place, cyan) }
            return Overlay(width: width, height: height, pixels: pixels)
        }
    }

    struct Overlay {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        func write(to url: URL) throws {
            guard let provider = CGDataProvider(data: Data(pixels) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                                      decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                throw MaskError.invalid("\(url.lastPathComponent) can be written")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw MaskError.invalid("\(url.lastPathComponent) can be written") }
        }
    }

    // MARK: a line of the set

    /// What a line asks for, in the selector's terms.
    struct Asked {
        let kind: String
        let prompt: ObjectSelector.Prompt
        let excluded: [(x: Float, y: Float)]

        init(_ words: ArraySlice<String>, in photo: Photo) throws {
            let parts = words.split(separator: "not", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first, let kind = first.first else { throw MaskError.invalid("a line says what was done") }
            func numbers(_ words: ArraySlice<String>) throws -> [Double] {
                try words.map {
                    guard let value = Double($0), value.isFinite, value >= 0 else { throw MaskError.invalid("\"\($0)\" is a number") }
                    return value
                }
            }
            /// Pairs as places: fractions as they are, pixels of the file over the file's size.
            func places(_ values: [Double]) throws -> [(x: Double, y: Double)] {
                guard values.count >= 2, values.count % 2 == 0 else { throw MaskError.invalid("places are pairs of numbers") }
                return stride(from: 0, to: values.count, by: 2).map {
                    (values[$0] > 1 ? values[$0] / photo.fileWidth : values[$0], values[$0 + 1] > 1 ? values[$0 + 1] / photo.fileHeight : values[$0 + 1])
                }
            }
            let given = try numbers(first.dropFirst())
            switch kind {
            case "click":
                let place = try places(given)
                guard place.count == 1 else { throw MaskError.invalid("a click is one place") }
                prompt = .point(x: Float(place[0].x), y: Float(place[0].y))
            case "stroke":
                guard let brush = given.first, brush > 0 else { throw MaskError.invalid("a stroke begins with its brush's width") }
                let longer = Double(max(photo.width, photo.height))
                let width = brush > 1 ? brush * longer / max(photo.fileWidth, photo.fileHeight) : brush * longer
                prompt = .scribble(width: photo.width, height: photo.height,
                                   coverage: SnapScene.paint(width: photo.width, height: photo.height, try places(Array(given.dropFirst())), brush: width))
            default:
                throw MaskError.invalid("\"\(kind)\" is click or stroke")
            }
            self.kind = kind
            excluded = parts.count > 1 ? try places(try numbers(parts[1])).map { (Float($0.x), Float($0.y)) } : []
        }
    }
}
