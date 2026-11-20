import CoreGraphics
import CoreVideo
import Foundation
import Testing
import Vision
@testable import ArgentCore

/// A picture drawn for the selector's tests: plain shapes of clearly different colour on a ground with texture and noise, so each
/// has edges a segmenter can find, and which shape every pixel belongs to. Nothing sits at the picture's centre or mirrors
/// another shape, so a prompt read with an axis flipped lands on the ground.
struct SnapScene: Sendable {
    let width: Int
    let height: Int
    let image: CGImage
    /// Each pixel's shape, by its place in the scene's list from 1, and 0 for the ground.
    let labels: [UInt8]

    /// A shape's colour, red, green and blue, with the channel that carries its noise.
    typealias Paint = (red: Double, green: Double, blue: Double, noisy: Int)

    /// `shapes` painted in order, a later one over an earlier, each given a pixel's place as fractions of the picture and in
    /// pixels at a width of 1200, the size the selector's measurements were made at.
    init(width: Int = 1200, height: Int = 800, shapes: [(inside: @Sendable (_ fx: Double, _ fy: Double, _ px: Double, _ py: Double) -> Bool, paint: Paint)]) {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var labels = [UInt8](repeating: 0, count: width * height)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let unit = 1200 / Double(width)
        for y in 0..<height {
            for x in 0..<width {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let noise = Double(state >> 40) / Double(1 << 24) - 0.5
                let px = (Double(x) + 0.5) * unit, py = (Double(y) + 0.5) * unit
                let tone = 0.5 + 0.12 * sin(px / 23) * cos(py / 31) + 0.08 * noise
                var colour = [150 * tone + 40, 140 * tone + 40, 110 * tone + 40]
                for (index, shape) in shapes.enumerated() where shape.inside((Double(x) + 0.5) / Double(width), (Double(y) + 0.5) / Double(height), px, py) {
                    colour = [shape.paint.red, shape.paint.green, shape.paint.blue]
                    colour[shape.paint.noisy] += 20 * noise
                    labels[y * width + x] = UInt8(index + 1)
                }
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = UInt8(min(max(colour[channel], 0), 255)) }
            }
        }
        self.width = width
        self.height = height
        self.labels = labels
        image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// A red disc up left and a blue square down right, far apart.
    static func shapes(width: Int = 1200, height: Int = 800) -> SnapScene {
        SnapScene(width: width, height: height, shapes: [
            ({ _, _, px, py in (px - 300) * (px - 300) + (py - 224) * (py - 224) < 110 * 110 }, (205, 40, 45, 0)),
            ({ _, _, px, py in abs(px - 864) < 100 && abs(py - 544) < 100 }, (30, 70, 200, 2)),
        ])
    }
    static let disc = 1, square = 2
    static let discCentre: (x: Float, y: Float) = (0.25, 0.28), squareCentre: (x: Float, y: Float) = (0.72, 0.68)

    /// A figure of three parts that touch, right of centre: dark legs, a blue body on them, a pale head on that. A click on the
    /// body selects all three (measured), which is what gives an excluded point something to keep out.
    static func figure() -> SnapScene {
        SnapScene(shapes: [
            ({ fx, fy, _, _ in abs(fx - 0.6) < 0.035 && fy > 0.55 && fy < 0.85 }, (40, 40, 55, 2)),
            ({ fx, fy, _, _ in abs(fx - 0.6) < 0.05 && fy > 0.3 && fy <= 0.55 }, (40, 90, 195, 2)),
            ({ _, _, px, py in (px - 720) * (px - 720) + (py - 192) * (py - 192) < 55 * 55 }, (225, 170, 140, 0)),
        ])
    }
    static let legs = 1, body = 2, head = 3
    static let legsCentre: (x: Float, y: Float) = (0.6, 0.7), bodyCentre: (x: Float, y: Float) = (0.6, 0.42)

    static let twoShapes = shapes()
    static let oneFigure = figure()

    /// A stroke through `points`, fractions of the picture from its top left, with a round brush `brush` pixels wide.
    func stroke(_ points: [(x: Double, y: Double)], brush: Double) -> ObjectSelector.Prompt {
        .scribble(width: width, height: height, coverage: Self.paint(width: width, height: height, points, brush: brush))
    }

    static func paint(width: Int, height: Int, _ points: [(x: Double, y: Double)], brush: Double) -> [UInt8] {
        var coverage = [UInt8](repeating: 0, count: width * height)
        let ends = points.count == 1 ? [points[0], points[0]] : points
        for (a, b) in zip(ends, ends.dropFirst()) {
            let (ax, ay, bx, by) = (a.x * Double(width), a.y * Double(height), b.x * Double(width), b.y * Double(height))
            let xs = max(0, Int(min(ax, bx) - brush))...min(width - 1, Int(max(ax, bx) + brush))
            let ys = max(0, Int(min(ay, by) - brush))...min(height - 1, Int(max(ay, by) + brush))
            let (vx, vy) = (bx - ax, by - ay)
            let length = vx * vx + vy * vy
            for y in ys {
                for x in xs {
                    let (px, py) = (Double(x) + 0.5, Double(y) + 0.5)
                    let along = length == 0 ? 0 : min(max(((px - ax) * vx + (py - ay) * vy) / length, 0), 1)
                    let (dx, dy) = (px - (ax + along * vx), py - (ay + along * vy))
                    if dx * dx + dy * dy <= brush * brush / 4 { coverage[y * width + x] = 255 }
                }
            }
        }
        return coverage
    }

    /// Of a shape's pixels, the share `selection` holds.
    func share(of shape: Int, in selection: RemovalPipeline.Selection) -> Double {
        var inside = 0, held = 0
        for i in 0..<labels.count where labels[i] == UInt8(shape) {
            inside += 1
            if selection.coverage[i] >= 128 { held += 1 }
        }
        return Double(held) / Double(max(inside, 1))
    }

    /// How well `selection` is the shapes named and nothing else: the pixels in both over the pixels in either.
    func overlap(of selection: RemovalPipeline.Selection, with shapes: Int...) -> Double {
        var both = 0, either = 0
        for i in 0..<labels.count {
            let isShape = shapes.contains(Int(labels[i])), isSelected = selection.coverage[i] >= 128
            if isShape && isSelected { both += 1 }
            if isShape || isSelected { either += 1 }
        }
        return Double(both) / Double(max(either, 1))
    }
}

/// What the selector does without the model: a prompt in Vision's terms, a stroke read at the middle of its paint, Vision's mask
/// as a selection, and strokes combined (docs/remove-plan.md, section 4.6).
@Suite struct ObjectSelectorTests {
    private static func isPaint(_ point: (x: Float, y: Float), _ coverage: [UInt8], _ width: Int, _ height: Int) -> Bool {
        coverage[min(height - 1, Int(point.y * Float(height))) * width + min(width - 1, Int(point.x * Float(width)))] >= 128
    }

    private static func buffer<T>(_ format: OSType, width: Int, height: Int, _ values: [T]) -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format, nil, &made)
        let buffer = made!
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!, rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = (base + y * rowBytes).assumingMemoryBound(to: T.self)
            for x in 0..<width { row[x] = values[y * width + x] }
        }
        return buffer
    }

    // MARK: a prompt in Vision's terms

    @Test func aPromptCountsDownFromTheTopAndVisionUpFromTheBottom() throws {
        let asked = try ObjectSelector.asked(.point(x: 0.25, y: 0.28), excluded: [(x: 0.72, y: 0.68)], reading: .middle)
        guard case .point(let seed) = asked.seed else {
            Issue.record("a click is a seed point")
            return
        }
        #expect(abs(seed.x - 0.25) < 1e-6 && abs(seed.y - 0.72) < 1e-6)
        #expect(asked.included.isEmpty && asked.excluded.count == 1)
        #expect(abs(asked.excluded[0].x - 0.72) < 1e-6 && abs(asked.excluded[0].y - 0.32) < 1e-6)

        let outside = try ObjectSelector.visionPoint(x: -0.2, y: 1.4)
        #expect(outside.x == 0 && outside.y == 0, "a place just outside the picture is its nearest edge")
        #expect(throws: RemovalError.self) { try ObjectSelector.visionPoint(x: .nan, y: 0.5) }
        #expect(throws: RemovalError.self) { try ObjectSelector.asked(.point(x: 0.5, y: 0.5), excluded: [(x: .infinity, y: 0)], reading: .middle) }
    }

    @Test func aStrokeIsReadHalfWayAlongItsPaint() throws {
        let (width, height) = (1200, 800)
        // A straight stroke: its middle.
        let straight = SnapScene.paint(width: width, height: height, [(0.2, 0.3), (0.6, 0.5)], brush: 24)
        let middle = ObjectSelector.middles(width: width, height: height, paint: straight)
        #expect(middle.count == 1)
        #expect(abs(middle[0].x - 0.4) < 0.02 && abs(middle[0].y - 0.4) < 0.02, "\(middle)")
        #expect(Self.isPaint(middle[0], straight, width, height))

        // A stroke that turns a corner: half-way along it, 380 of its 760 pixels, which is on the paint; the paint's centre of
        // mass, near (0.27, 0.57), is not.
        let bent = SnapScene.paint(width: width, height: height, [(0.2, 0.2), (0.2, 0.7), (0.5, 0.7)], brush: 20)
        let corner = ObjectSelector.middles(width: width, height: height, paint: bent)
        #expect(corner.count == 1 && Self.isPaint(corner[0], bent, width, height))
        #expect(abs(corner[0].x - 0.2) < 0.05 && abs(corner[0].y - 0.675) < 0.06, "\(corner)")

        // A line one pixel thin: still one piece, and its point is on the line itself.
        var thin = [UInt8](repeating: 0, count: width * height)
        for x in 100..<700 { thin[400 * width + x] = 255 }
        let hair = ObjectSelector.middles(width: width, height: height, paint: thin)
        #expect(hair.count == 1 && Self.isPaint(hair[0], thin, width, height))
        #expect(abs(hair[0].x - 400.0 / 1200) < 0.01 && hair[0].y == 400.5 / 800, "\(hair)")

        // Two pieces of paint: a middle each, the larger piece first.
        var two = SnapScene.paint(width: width, height: height, [(0.7, 0.2), (0.7, 0.3)], brush: 20)
        for (i, value) in straight.enumerated() where value >= 128 { two[i] = 255 }
        let both = ObjectSelector.middles(width: width, height: height, paint: two)
        #expect(both.count == 2)
        #expect(abs(both[0].x - 0.4) < 0.02 && abs(both[1].x - 0.7) < 0.02 && abs(both[1].y - 0.25) < 0.02, "\(both)")
        let asked = try ObjectSelector.asked(.scribble(width: width, height: height, coverage: two), excluded: [], reading: .middle)
        #expect(asked.included.count == 1, "the second piece is a point that is the object's too")

        // Spray is read at its largest pieces only.
        var spray = [UInt8](repeating: 0, count: width * height)
        for dab in 0..<12 {
            let more = SnapScene.paint(width: width, height: height, [(0.05 + 0.075 * Double(dab), 0.5)], brush: Double(10 + 2 * dab))
            for (i, value) in more.enumerated() where value >= 128 { spray[i] = 255 }
        }
        let dabs = ObjectSelector.middles(width: width, height: height, paint: spray)
        #expect(dabs.count == ObjectSelector.pieceLimit)
        #expect(abs(dabs[0].x - (0.05 + 0.075 * 11)) < 0.02, "the widest dab first: \(dabs)")
    }

    @Test func aStrokeWithNoPaintSelectsNothingAndAMalformedOneIsRefusedBeforeAnyRequest() async throws {
        let empty = ObjectSelector.Prompt.scribble(width: 4, height: 2, coverage: [UInt8](repeating: 0, count: 8))
        for reading in [ObjectSelector.StrokeReading.middle, .scribble] {
            #expect(throws: ObjectSelector.Failure.nothingSelected) { try ObjectSelector.asked(empty, excluded: [], reading: reading) }
            #expect(throws: RemovalError.self) {
                try ObjectSelector.asked(.scribble(width: 4, height: 2, coverage: [255]), excluded: [], reading: reading)
            }
        }
        // Through the selector these are known before the model is asked for, so they hold on a Mac without it.
        let picture = SnapScene.twoShapes.image
        await #expect(throws: ObjectSelector.Failure.nothingSelected) { try await ObjectSelector().select(empty, in: picture) }
        await #expect(throws: ObjectSelector.Failure.nothingSelected) {
            try await ObjectSelector().select(.point(x: 0.5, y: 0.5), subtracting: true, from: nil, in: picture)
        }
    }

    @Test func theScribbleBufferIsThePaintAtItsOwnSizeTopRowFirst() throws {
        let coverage: [UInt8] = [0, 200, 0, 0, 0,
                                 0, 0, 127, 128, 0,
                                 255, 0, 0, 0, 9]
        let asked = try ObjectSelector.asked(.scribble(width: 5, height: 3, coverage: coverage), excluded: [], reading: .scribble)
        let paint: [UInt8] = [0, 255, 0, 0, 0, 0, 0, 0, 255, 0, 255, 0, 0, 0, 0]
        #expect(asked == ObjectSelector.Asked(seed: .scribble(width: 5, height: 3, paint: paint)))

        let buffer = try ObjectSelector.scribbleBuffer(width: 5, height: 3, paint: paint)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8)
        #expect(CVPixelBufferGetWidth(buffer) == 5 && CVPixelBufferGetHeight(buffer) == 3)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!, rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let read = (0..<15).map { (base + ($0 / 5) * rowBytes + $0 % 5).load(as: UInt8.self) }
        #expect(read == paint)
    }

    // MARK: Vision's mask as a selection

    @Test func aMaskBecomesASelectionWhereItIsOneHalfOrMore() throws {
        // What Vision returns: half floats that run a little under 0 and over 1.
        let values: [Float16] = [0, 0.49, 0.5, 1.03,
                                 -0.03, .nan, 0.75, 0.499]
        let wanted: [UInt8] = [0, 0, 255, 255, 0, 0, 255, 0]
        let half = Self.buffer(kCVPixelFormatType_OneComponent16Half, width: 4, height: 2, values)
        let same = try ObjectSelector.selection(from: half, width: 4, height: 2)
        #expect(same.width == 4 && same.height == 2 && same.coverage == wanted)

        // A mask smaller than the picture is stretched over it.
        let stretched = try ObjectSelector.selection(from: half, width: 8, height: 4)
        var twice = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { twice[i] = wanted[(i / 16) * 4 + (i % 8) / 2] }
        #expect(stretched.coverage == twice)

        let float = Self.buffer(kCVPixelFormatType_OneComponent32Float, width: 4, height: 2, values.map { Float($0) })
        #expect(try ObjectSelector.selection(from: float, width: 4, height: 2).coverage == wanted)
        let bytes = Self.buffer(kCVPixelFormatType_OneComponent8, width: 4, height: 2, [0, 127, 128, 255, 0, 0, 200, 1] as [UInt8])
        #expect(try ObjectSelector.selection(from: bytes, width: 4, height: 2).coverage == wanted)
    }

    @Test func nothingSelectedIsNotAFailureOfTheRequest() throws {
        let blank = Self.buffer(kCVPixelFormatType_OneComponent16Half, width: 4, height: 2, [Float16](repeating: 0.04, count: 8))
        #expect(throws: ObjectSelector.Failure.nothingSelected) { try ObjectSelector.selection(from: blank, width: 4, height: 2) }
        let colour = Self.buffer(kCVPixelFormatType_32BGRA, width: 4, height: 2, [UInt32](repeating: .max, count: 8))
        do {
            _ = try ObjectSelector.selection(from: colour, width: 4, height: 2)
            Issue.record("a mask in an unknown format was read")
        } catch let failure as ObjectSelector.Failure {
            guard case .request = failure else {
                Issue.record("an unreadable mask is the request's failure, not \(failure)")
                return
            }
        }
        #expect(ObjectSelector.Failure.nothingSelected != .request("Nothing is selected."))
        #expect(ObjectSelector.Failure.notReady(.downloading) != .notReady(.unavailable("offline")))
    }

    // MARK: more strokes

    @Test func aStrokeAddsWhatItFindsAndAnOptionStrokeRemovesItAndNothingElseMoves() throws {
        func selection(_ rows: [String], scale: Int = 1) throws -> RemovalPipeline.Selection {
            let marks = rows.map { Array($0) }
            let width = marks[0].count * scale, height = marks.count * scale
            var coverage = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width where marks[y / scale][x / scale] == "#" { coverage[y * width + x] = 255 }
            }
            return try RemovalPipeline.Selection(width: width, height: height, coverage: coverage)
        }
        let held = try selection(["##..",
                                  "##..",
                                  "...."])
        let found = try selection([".##.",
                                   "....",
                                   "...#"])
        #expect(try ObjectSelector.combined(held, with: found, subtracting: false) == selection(["###.",
                                                                                                 "##..",
                                                                                                 "...#"]))
        #expect(try ObjectSelector.combined(held, with: found, subtracting: true) == selection(["#...",
                                                                                                "##..",
                                                                                                "...."]))
        #expect(throws: ObjectSelector.Failure.nothingSelected) { try ObjectSelector.combined(held, with: held, subtracting: true) }

        // A painted selection at another size is stretched to the picture's, which is the size of what the request found.
        let large = try selection([".##.", "....", "...#"], scale: 2)
        let joined = try ObjectSelector.combined(held, with: large, subtracting: false)
        #expect(joined == (try selection(["###.", "##..", "...#"], scale: 2)))
    }

    // MARK: the plan's rules

    /// The plan's proof for this package (section 5, G): no request here is given a compute device, which killed the masking
    /// research's process. The word may stand in a comment that says so, and nowhere in the code.
    @Test func noRequestIsGivenAComputeDevice() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ArgentCore/Removal/ObjectSelector.swift")
        let lines = try String(contentsOf: source, encoding: .utf8).split(separator: "\n")
        #expect(lines.contains { $0.contains("GenerateIterativeSegmentationRequest(") }, "this is the file that makes the request")
        let code = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        #expect(!code.contains { $0.localizedCaseInsensitiveContains("computeDevice") })
        #expect(lines.contains { $0.contains("compute device") }, "and it says why")
    }

    /// Where the model is not ready the selector says so, and a selection is refused with what it said before any request runs:
    /// the Remove tab then keeps what was painted. This Mac has the model, so here it only shows that the answer is `ready`.
    @Test func availabilityAnswersAndASelectionIsRefusedWhereTheModelIsNotReady() async throws {
        let selector = ObjectSelector()
        let availability = await selector.availability()
        guard availability != .ready else { return }
        do {
            _ = try await selector.select(.point(x: 0.25, y: 0.28), in: SnapScene.twoShapes.image)
            Issue.record("a selection was made though the model is \(availability)")
        } catch let failure as ObjectSelector.Failure {
            guard case .notReady = failure else {
                Issue.record("\(failure)")
                return
            }
        }
    }
}

/// Whether Vision's model for the request is on this Mac, asked once for every suite that needs it.
enum SnapModel {
    static func isReady() async -> Bool { await ObjectSelector().availability() == .ready }
}

/// The selections themselves, on drawn pictures, by the model macOS has on this Mac (docs/remove-plan.md, section 4.6). Skipped,
/// and said to be, where the model is not ready; `ObjectSelectorTests` then shows that a selection is refused.
///
/// Every overlap asked for here is far under what was measured on 2026-11-16 (0.99 and more for a whole shape, under 0.001 for
/// one left out), since the model is an asset Apple can refresh.
@Suite(.enabled("Vision's segmentation model is not ready on this Mac, so Snap to Object's selections are not run here",
                { await SnapModel.isReady() }))
struct ObjectSelectorModelTests {
    private let selector = ObjectSelector()
    private var scene: SnapScene { SnapScene.twoShapes }

    /// The disc is up and to the left, so a prompt read with either axis flipped is on the ground and selects no disc.
    @Test func aClickInsideAShapeSelectsThatShapeAndLittleElse() async throws {
        let disc = try await selector.select(.point(x: SnapScene.discCentre.x, y: SnapScene.discCentre.y), in: scene.image)
        #expect(disc.width == scene.width && disc.height == scene.height, "at the picture's size")
        #expect(scene.overlap(of: disc, with: SnapScene.disc) >= 0.9)
        #expect(scene.share(of: SnapScene.square, in: disc) <= 0.01)

        let square = try await selector.select(.point(x: SnapScene.squareCentre.x, y: SnapScene.squareCentre.y), in: scene.image)
        #expect(scene.overlap(of: square, with: SnapScene.square) >= 0.9)
        #expect(scene.share(of: SnapScene.disc, in: square) <= 0.01)
    }

    @Test func aClickOnTheGroundDoesNotSelectAShape() async throws {
        for ground in [(x: Float(0.5), y: Float(0.15)), (x: 0.9, y: 0.1), (x: 0.25, y: 0.72)] {
            do {
                let selection = try await selector.select(.point(x: ground.x, y: ground.y), in: scene.image)
                #expect(scene.share(of: SnapScene.disc, in: selection) <= 0.01, "\(ground)")
                #expect(scene.share(of: SnapScene.square, in: selection) <= 0.01, "\(ground)")
            } catch ObjectSelector.Failure.nothingSelected {
                // Nothing there is as good an answer.
            }
        }
    }

    /// The case the snap is for (plan section 3): paint over a small part of an object must select all of it. The first stroke
    /// covers a sixteenth of the disc; the second runs past it on both sides.
    @Test func aStrokeAcrossPartOfAShapeSelectsTheWholeShape() async throws {
        let short = scene.stroke([(0.22, 0.25), (0.29, 0.31)], brush: 20)
        let selection = try await selector.select(short, in: scene.image)
        #expect(scene.overlap(of: selection, with: SnapScene.disc) >= 0.9)
        #expect(scene.share(of: SnapScene.square, in: selection) <= 0.01)

        let past = scene.stroke([(0.12, 0.28), (0.38, 0.28)], brush: 20)
        #expect(scene.overlap(of: try await selector.select(past, in: scene.image), with: SnapScene.disc) >= 0.9)
    }

    /// The other reading of a stroke, the request's scribble buffer, on what it reads well: paint over much of the shape. The
    /// disc is off-centre, so a buffer read bottom row first would paint the ground.
    @Test func paintOverAShapeGivenAsAScribbleBufferSelectsIt() async throws {
        let paint = scene.stroke([(0.22, 0.25), (0.29, 0.31)], brush: 60)
        let selection = try await ObjectSelector(strokes: .scribble).select(paint, in: scene.image)
        #expect(scene.overlap(of: selection, with: SnapScene.disc) >= 0.9)
        #expect(scene.share(of: SnapScene.square, in: selection) <= 0.01)
    }

    /// The figure's parts touch and a click on its body takes its legs too: that is the joined selection an Option-click is for.
    @Test func anExcludedPointOnASecondShapeKeepsItOut() async throws {
        let figure = SnapScene.oneFigure
        let body = ObjectSelector.Prompt.point(x: SnapScene.bodyCentre.x, y: SnapScene.bodyCentre.y)
        let joined = try await selector.select(body, in: figure.image)
        #expect(figure.share(of: SnapScene.body, in: joined) >= 0.9)
        #expect(figure.share(of: SnapScene.legs, in: joined) >= 0.9, "the click alone takes the legs with the body")

        let apart = try await selector.select(body, excluded: [SnapScene.legsCentre], in: figure.image)
        #expect(figure.share(of: SnapScene.body, in: apart) >= 0.9)
        #expect(figure.share(of: SnapScene.legs, in: apart) <= 0.05)
    }

    @Test func moreStrokesAddAndAnOptionStrokeSubtracts() async throws {
        let onDisc = scene.stroke([(0.22, 0.25), (0.29, 0.31)], brush: 20)
        let onSquare = scene.stroke([(0.68, 0.64), (0.76, 0.72)], brush: 20)
        let first = try await selector.select(onDisc, subtracting: false, from: nil, in: scene.image)
        #expect(scene.overlap(of: first, with: SnapScene.disc) >= 0.9)

        let both = try await selector.select(onSquare, subtracting: false, from: first, in: scene.image)
        #expect(scene.overlap(of: both, with: SnapScene.disc, SnapScene.square) >= 0.9)

        let less = try await selector.select(onDisc, subtracting: true, from: both, in: scene.image)
        #expect(scene.overlap(of: less, with: SnapScene.square) >= 0.9)
        #expect(scene.share(of: SnapScene.disc, in: less) <= 0.01)
    }

    /// What a request refines is the process's, so two selections that ran into each other would each answer from the other's
    /// picture (measured: 5,282 pixels of a 38,000-pixel disc). Each of these has a point to refine with; they take turns.
    @Test func selectionsMadeAtOnceKeepToTheirOwnPictures() async throws {
        let (shapes, figure) = (SnapScene.twoShapes, SnapScene.oneFigure)
        let selector = selector
        try await withThrowingTaskGroup(of: (Bool, RemovalPipeline.Selection).self) { group in
            for index in 0..<8 {
                group.addTask {
                    index % 2 == 0
                        ? (true, try await selector.select(.point(x: SnapScene.discCentre.x, y: SnapScene.discCentre.y),
                                                           excluded: [SnapScene.squareCentre], in: shapes.image))
                        : (false, try await selector.select(.point(x: SnapScene.bodyCentre.x, y: SnapScene.bodyCentre.y),
                                                            excluded: [SnapScene.legsCentre], in: figure.image))
                }
            }
            for try await (isShapes, selection) in group {
                if isShapes {
                    #expect(shapes.overlap(of: selection, with: SnapScene.disc) >= 0.9)
                } else {
                    #expect(figure.share(of: SnapScene.body, in: selection) >= 0.9)
                    #expect(figure.share(of: SnapScene.legs, in: selection) <= 0.05)
                }
            }
        }
    }
}
