import AppKit
import ArgentCore
@testable import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// The brush's settings and their keys, pure.
@Suite struct MaskBrushSettingsTests {
    @Test func sizeStepsComeBackWhereTheyBeganAndTheSmallestStillGrows() {
        var brush = MaskBrushSettings.standard
        #expect(brush.size == 6 && brush.feather == 50 && brush.flow == 100 && !brush.erase)
        brush = brush.larger()
        #expect(abs(brush.size - 7.5) < 1e-4)
        brush = brush.smaller()
        #expect(abs(brush.size - 6) < 1e-4)
        var small = MaskBrushSettings(size: 0.2, feather: 0, flow: 50)
        small = small.larger()
        #expect(abs(small.size - 0.3) < 1e-4)
        small = small.smaller().smaller()
        #expect(abs(small.size - 0.2) < 1e-4)
        var large = MaskBrushSettings(size: 39, feather: 0, flow: 50)
        large = large.larger()
        #expect(large.size == 40)
        #expect(large.radius == 0.2 && MaskBrushSettings(size: 0.2, feather: 0, flow: 1).radius == 0.001)
    }

    @Test func featherStepsByATenthAndStopsAtItsEnds() {
        let brush = MaskBrushSettings.standard
        #expect(brush.feathered(by: 1).feather == 60 && brush.feathered(by: -1).feather == 40)
        #expect(brush.feathered(by: 9).feather == 100 && brush.feathered(by: -9).feather == 0)
    }

    @Test func aDigitIsLightroomsFlow() {
        let brush = MaskBrushSettings.standard
        #expect((1...9).map { brush.flow(digit: $0).flow } == [10, 20, 30, 40, 50, 60, 70, 80, 90])
        #expect(brush.flow(digit: 0).flow == 100)
    }

    /// Option at the press turns the panel's choice over for that stroke, as Lightroom's eraser key does.
    @Test func optionErasesAndUnerasesTheOnePress() {
        var brush = MaskBrushSettings(size: 4, feather: 25, flow: 30)
        let painted = brush.engine(option: false)
        #expect(!painted.erase && painted.radius == 0.02 && painted.feather == 0.25 && abs(painted.flow - 0.3) < 1e-6)
        #expect(brush.engine(option: true).erase)
        brush.erase = true
        #expect(brush.engine(option: false).erase && !brush.engine(option: true).erase)
    }

    @Test func itKeepsAcrossLaunchesButErase() throws {
        let defaults = ScratchDefaults()
        #expect(MaskBrushSettings(defaults: defaults) == .standard)
        MaskBrushSettings(size: 12.5, feather: 10, flow: 30, erase: true, followEdges: true).save(to: defaults)
        #expect(MaskBrushSettings(defaults: defaults) == MaskBrushSettings(size: 12.5, feather: 10, flow: 30, followEdges: true))
        #expect(MaskBrushSettings(defaults: defaults).engine(option: false).followEdges)
        // A value from elsewhere is held inside its range.
        defaults.set(900, forKey: MaskBrushSettings.sizeKey)
        defaults.set(-4, forKey: MaskBrushSettings.flowKey)
        #expect(MaskBrushSettings(defaults: defaults).size == 40 && MaskBrushSettings(defaults: defaults).flow == 1)
    }

    /// The panel's three are a group of their own, so . and , stay among them, in this order.
    @Test func theBrushsSlidersAreTheirOwnGroup() {
        let specs = [AdjustmentSliderSpec.brushSize, .brushFeather, .brushFlow]
        #expect(specs.map(\.group) == [.brush, .brush, .brush])
        #expect(specs.map(\.order) == [0, 1, 2])
        #expect(specs.map(\.title) == ["Size", "Feather", "Flow"])
        #expect(specs.allSatisfy { $0.polarity == .unipolar && $0.clipping == nil })
        #expect(AdjustmentSliderSpec.brushSize.range == MaskBrushSettings.sizeRange && AdjustmentSliderSpec.brushSize.formatted(6) == "6.0")
        #expect(AdjustmentSliderSpec.brushFlow.range.lowerBound == 1)
    }
}

/// The canvas a stroke paints, on a GPU of the test's own, for a 7008 by 4672 picture.
private final class TestCanvasSource: MaskBrushCanvasSource {
    let gpu: GPU
    let picture: MaskSpace
    let frame: MaskFrame
    var isReady = true
    /// Where a brush's Follow edges strokes' shapes are read when its canvas must be laid: the library's, as the previews give theirs.
    var seeds: (any MaskSeedProvider)?

    init() throws {
        gpu = try GPU(maxIdlePoolBytes: 64 << 20)
        picture = try MaskSpace(width: 7008, height: 4672)
        frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .apple, lensCorrection: true)
    }

    private(set) var pictureLensSettings: [LensSettings] = []
    func brushPicture(for frame: Frame, lens: LensSettings) -> (picture: MaskSpace, frame: MaskFrame)? {
        pictureLensSettings.append(lens)
        return isReady ? (picture, self.frame) : nil
    }

    /// The decode a Follow edges stroke reads, at the slice's size: pale sky over the picture's top half, dark below it.
    lazy var decode: LinearFrame? = {
        let size = MaskFieldSize(picture: picture)
        guard let texture = try? gpu.makeTexture(width: size.width, height: size.height) else { return nil }
        var values = [Float16](repeating: 1, count: size.width * size.height * 4)
        for row in 0..<size.height {
            // Row 0 is the picture's bottom, so the texture's upper rows are the picture's top half.
            let rgb: SIMD3<Float> = row >= size.height / 2 ? SIMD3(0.55, 0.66, 0.88) : SIMD3(0.03, 0.022, 0.016)
            for x in 0..<size.width {
                let i = (row * size.width + x) * 4
                values[i] = Float16(rgb.x); values[i + 1] = Float16(rgb.y); values[i + 2] = Float16(rgb.z)
            }
        }
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, size.width, size.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: size.width * 8)
        }
        return LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "brush-test", scale: 1, picture: picture)
    }()

    /// Calls of `wantFrameDecode`: a press with no decode held asks for one.
    private(set) var heldDecodes = 0
    func wantFrameDecode(_ frame: Frame, lens: LensSettings, pixels: Int) { heldDecodes += 1 }

    func brushStrokeSession(frame: Frame, lens: LensSettings, picture: MaskSpace, mask: Mask, component: Int, settings: BrushSettings,
                            constraint: StrokeSampler.Constraint) throws -> BrushStrokeSession {
        // The previews' own rule (`FilmPreviews.brushStrokeSession`).
        let needed = BrushStrokeSession.needsRefinement(mask: mask, settings: settings)
        let refinement = needed ? decode.map { gpu.maskRefiner.session(for: $0, picture: picture, seeds: seeds) } : nil
        return try BrushStrokeSession(gpu: gpu, picture: picture, mask: mask, component: component, settings: settings, constraint: constraint,
                                      refinement: refinement)
    }
}

/// A stroke's life on an open frame, through the canvas's events as the pointer gives them: one stroke one undo step, the first
/// making the mask, its undo leaving the brush in hand, Option, Shift, a Subtract brush on a gradient, the print and the overlay.
@MainActor @Suite(.serialized) struct MaskBrushStrokeTests {
    private func header(_ url: URL) throws {
        func u16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255)] }
        func u32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(n >> (8 * $0) & 255) } }
        var b: [UInt8] = [0x49, 0x49] + u16(42) + u32(8)
        b += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(26) + u32(0)
        b += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(100) + u16(0) + u32(0)
        try Data(b).write(to: url, options: .atomic)
    }

    /// An open frame with an edit, ready to adjust, a canvas over it, a GPU for the brush and a clock the test turns.
    @MainActor private final class Bench {
        let model: RollModel, frame: Frame, folder: URL, canvas: MaskCanvasView, source: TestCanvasSource, defaults: UserDefaults
        var geometry = FrameGeometry(area: CGSize(width: 1188, height: 756), picture: CGRect(x: 27, y: 0, width: 1134, height: 756), displayScale: 2)
        var now: CFTimeInterval = 100

        init(model: RollModel, frame: Frame, folder: URL, source: TestCanvasSource, defaults: UserDefaults) {
            self.model = model; self.frame = frame; self.folder = folder; self.source = source; self.defaults = defaults
            canvas = MaskCanvasView(editor: model.maskEditor)
            model.maskEditor.canvas = canvas
            canvas.geometry = { [unowned self] in self.geometry }
            model.maskEditor.clock = { [unowned self] in self.now }
            model.maskEditor.brush.clock = { [unowned self] in self.now }
            model.maskEditor.brush.source = source
            model.maskEditor.brush.settings = .standard
            // Events and expectations take turns: the lane runs on the caller's thread.
            model.maskEditor.brush.runsInline = true
        }

        var editor: MaskEditor { model.maskEditor }
        var brush: MaskBrush { model.maskEditor.brush }
        var masks: [Mask] { model.masks(for: frame) }
        var undo: UndoManager { model.manualUndoManager! }

        func event(_ phase: MaskCanvasEvent.Phase, _ point: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
            editor.canvasEvent(MaskCanvasEvent(phase: phase, fractions: geometry.normalized(point), point: point, modifiers: modifiers,
                                               clickCount: 1, time: now))
        }

        /// One stroke as one event loop's turns are, each step a thirtieth of a second apart, as one group of the undo manager.
        func stroke(_ from: CGPoint, _ to: CGPoint, steps: Int = 6, modifiers: NSEvent.ModifierFlags = []) {
            undo.beginUndoGrouping()
            event(.press, from, modifiers: modifiers)
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                now += 1.0 / 30
                event(.drag, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), modifiers: modifiers)
            }
            event(.release, to, modifiers: modifiers)
            undo.endUndoGrouping()
        }

        func click(_ at: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
            undo.beginUndoGrouping()
            event(.press, at, modifiers: modifiers)
            event(.release, at, modifiers: modifiers)
            undo.endUndoGrouping()
        }

        func step(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }

        /// The brush strokes of `mask`'s `component`.
        func strokes(_ mask: Int = 0, component: Int = 0) -> [BrushStroke] {
            guard masks.indices.contains(mask), masks[mask].components.indices.contains(component),
                  case .brush(let paint) = masks[mask].components[component].shape else { return [] }
            return paint.strokes
        }

        func finish() {
            canvas.teardown()
            model.maskEditor.brush.settings = .standard
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func withBench(_ body: (Bench) throws -> Void) async throws {
        let shown = UserDefaults.standard.object(forKey: "manualInspectorShown"), tab = UserDefaults.standard.object(forKey: AdjustInspectorTab.storageKey)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-brush-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try header(folder.appendingPathComponent("DSC1.ARW"))
        try header(folder.appendingPathComponent("DSC2.ARW"))
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        await model.open(folder)
        if let restore = model.manualRestoreTask { await restore.value }
        let frame = try #require(model.roll?.frames.first)
        model.selection = frame.id
        model.openFrame()
        let verified = try SourceDigests.shared.digest(of: frame.url)
        model.manualReadySources[frame.url] = verified
        model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 0.3, validWeight: 1), source: verified.source), for: frame)
        let pin = AutomaticBaseline(sourceSHA256: verified.sha256, stockID: "test", stockDigest: "digest",
            controls: .init(), aim: PrintAim(level: -0.65, cast: .zero), analysisVersion: ExposureAnalysis.currentVersion,
            baseRender: Recipe.Render(settings: DevelopSettings(), grain: .off))
        model.manualEdits[frame.url] = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.5), baseline: pin)
        model.manualUndoManager = UndoManager()
        model.manualUndoManager?.groupsByEvent = false
        model.adjustTab = .masks
        model.isAdjustmentsShown = true
        let bench = Bench(model: model, frame: frame, folder: folder, source: try TestCanvasSource(),
                          defaults: ScratchDefaults())
        defer {
            bench.finish()
            UserDefaults.standard.set(shown, forKey: "manualInspectorShown")
            UserDefaults.standard.set(tab, forKey: AdjustInspectorTab.storageKey)
        }
        try body(bench)
    }

    private static let a = CGPoint(x: 400, y: 300), b = CGPoint(x: 700, y: 420)

    /// The first stroke makes the mask, with no OK: named, selected, one undo step, Paint Mask; the brush stays in hand on it.
    @Test func theFirstStrokeMakesTheMaskAsOneStep() async throws {
        try await withBench { bench in
            bench.model.armBrush()
            #expect(bench.editor.tool == .brush && bench.editor.pendingOperation == nil)
            #expect(bench.model.brushPendingRow(on: bench.frame) == .mask("Brush 1"))
            #expect(bench.masks.isEmpty)
            bench.stroke(Self.a, Self.b)
            #expect(bench.masks.count == 1)
            let mask = try #require(bench.masks.first)
            #expect(bench.model.maskName(mask.id, for: bench.frame) == "Brush 1")
            #expect(bench.strokes().count == 1)
            let stroke = try #require(bench.strokes().first)
            #expect(!stroke.erase && stroke.radius == 0.03 && stroke.feather == 0.5 && stroke.flow == 1)
            #expect(stroke.points.points.first == StrokeSampler.quantized(bench.geometry.maskPoint(Self.a)))
            #expect(stroke.points.points.last == StrokeSampler.quantized(bench.geometry.maskPoint(Self.b)))
            #expect(bench.undo.undoActionName == "Paint Mask")
            #expect(bench.editor.tool == .brush && bench.editor.selection?.mask == mask.id)
            #expect(bench.brush.target(on: bench.frame, model: bench.model) == MaskEditor.Selection(mask: mask.id, component: 0))
            #expect(bench.model.brushPendingRow(on: bench.frame) == nil)
            #expect(bench.editor.justPlaced && !bench.brush.isPainting && bench.editor.printed == nil)
            // The brush's frame is the picture it was painted on.
            guard case .brush(let paint) = mask.components[0].shape else { Issue.record("not a brush"); return }
            #expect(paint.frame == bench.source.frame)
        }
    }

    /// A Follow edges stroke (A) is one undo step whose stroke keeps its measured shape, stored in the library before the edit names it;
    /// it stays off the pale half its centre never crossed, where a plain stroke covers it; its undo leaves the brush in hand.
    @Test func aFollowEdgesStrokeKeepsWhatItMeasured() async throws {
        try await withBench { bench in
            bench.model.armBrush()
            bench.model.perform(.followEdges)
            #expect(bench.brush.settings.followEdges)
            // Along the dark lower half of the picture, the brush reaching across the middle into the pale one.
            let from = CGPoint(x: 300, y: 460), to = CGPoint(x: 800, y: 460)
            bench.brush.settings.size = 30
            bench.stroke(from, to)
            #expect(bench.undo.undoActionName == "Paint Mask")
            let stroke = try #require(bench.strokes().first)
            let measured = try #require(stroke.measured)
            #expect(stroke.followEdges)
            let store = bench.model.maskSeedStore
            #expect(store.contains(measured.raster.id) && (try? store.load(measured.raster)) != nil)
            #expect(bench.model.manualAdjustments(for: bench.frame).masks.rasters == [measured.raster])
            #expect(MaskSet.schema(of: bench.masks) == 3)
            #expect(bench.model.maskSeedIssue(for: bench.frame) == nil)
            // Its shape reaches no pale texel: coverage over the picture's top half is 0, and below it the stroke's.
            let raster = try store.load(measured.raster), field = measured.field
            let middle = field.height - field.height / 2
            var pale = 0, dark = 0
            // The same stroke plain covers the pale half well above the middle.
            let plain = BrushField([BrushStroke(radius: stroke.radius, feather: stroke.feather, flow: stroke.flow, points: stroke.points)])
            let start = try #require(stroke.points.points.first)
            let above = field.point(column: Int(start.x * Float(field.width) / field.extent.x), yTop: middle - 60)
            #expect(plain.value(at: SIMD2(above.x, above.y)) > 0.5)
            for row in 0..<raster.height {
                for column in 0..<raster.width where raster.plane[row * raster.width + column] > 0 {
                    if measured.y + row < middle - 2 { pale += 1 } else { dark += 1 }
                }
            }
            #expect(pale == 0 && dark > 1000, "pale \(pale) dark \(dark)")
            // The overlay at rest reads the same shape from the library: red in the dark half under the stroke, none in the pale half.
            let shown = MaskSeedCoverage(store: store).raster(of: try #require(bench.masks.first).components, width: 300, height: 200)
            let column = Int(start.x * 300)
            #expect(shown[(200 / 2 - 15) * 300 + column] == 0 && shown[(200 / 2 + 30) * 300 + column] > 200,
                    "\(shown[(200 / 2 - 15) * 300 + column]) \(shown[(200 / 2 + 30) * 300 + column])")
            // A, again: plain from the next stroke on.
            bench.model.perform(.followEdges)
            #expect(!bench.brush.settings.followEdges)
            bench.undo.undo()
            #expect(bench.masks.isEmpty && bench.editor.tool == .brush)
        }
    }

    /// A mask whose brushes hold the point cap takes no stroke (E's session refuses at the press): nothing is painted and no step
    /// is made, and the row says so, quietly, as an empty selection's does (task H; G left it unsaid).
    @Test func aFullBrushPaintsNothingAndItsRowSaysSo() async throws {
        try await withBench { bench in
            bench.model.armBrush()
            bench.stroke(Self.a, Self.b)
            let mask = try #require(bench.masks.first)
            #expect(bench.model.smartStatus(of: mask, for: bench.frame) == nil)
            // Filled to the cap, as many strokes would leave it.
            guard case .brush(var paint) = mask.components[0].shape else { Issue.record("not a brush"); return }
            let points = (0..<MaskSet.maximumBrushPoints).map { MaskPoint(x: 0.1 + Float($0 % 128) * 0.005, y: 0.1 + Float($0 / 128) * 0.004) }
            paint.strokes = [BrushStroke(radius: 0.01, points: try PackedPoints.pack(points))]
            var filled = mask
            filled.components[0].shape = .brush(paint)
            let set = try bench.model.manualAdjustments(for: bench.frame).masks.replacing(filled)
            let adjustments = bench.model.manualAdjustments(for: bench.frame).settingMasks(set)
            bench.model.manualEdits[bench.frame.url]?.adjustments = adjustments
            let full = try #require(bench.masks.first)
            #expect(SmartRowStatus.brushIsFull(full) && !SmartRowStatus.brushIsFull(mask))
            let status = try #require(bench.model.smartStatus(of: full, for: bench.frame))
            #expect(status == .brushFull && status.text == "The brush is full" && status.actions.isEmpty && !status.hasActionLine)
            #expect(status.detail?.contains("16,384") == true)
            // Outside an undo group, as no event of the app's would open one for nothing: the press registers no step.
            let refused = bench.brush.counts.refused, step = bench.undo.undoActionName
            bench.event(.press, Self.b)
            bench.event(.drag, Self.a)
            bench.event(.release, Self.a)
            #expect(bench.brush.counts.refused == refused + 1 && bench.brush.lastRefusal?.contains("points at most") == true)
            #expect(bench.masks.first == full && bench.undo.undoActionName == step && !bench.brush.isPainting)
        }
    }

    /// Unlike Lightroom: undoing the first stroke takes the mask away and leaves the brush in hand with its row pending, and the next
    /// stroke makes the mask again (plan section 5).
    @Test func undoingTheFirstStrokeKeepsTheBrushInHandWithItsPendingRow() async throws {
        try await withBench { bench in
            bench.model.armBrush()
            bench.stroke(Self.a, Self.b)
            bench.undo.undo()
            #expect(bench.masks.isEmpty)
            #expect(bench.editor.tool == .brush && bench.editor.selection == nil)
            #expect(bench.model.brushPendingRow(on: bench.frame) == .mask("Brush 1"))
            // Redo brings the mask and its brush back.
            bench.undo.redo()
            #expect(bench.masks.count == 1 && bench.strokes().count == 1 && bench.editor.tool == .brush)
            #expect(bench.model.brushPendingRow(on: bench.frame) == nil)
            bench.undo.undo()
            bench.stroke(Self.b, Self.a)
            #expect(bench.masks.count == 1 && bench.strokes().count == 1)
            #expect(bench.model.maskName(bench.masks[0].id, for: bench.frame) == "Brush 1")
        }
    }

    /// Strokes go on into the brush the first made, one undo step each; K takes up a new mask.
    @Test func eachStrokeIsOneStepIntoTheSameBrush() async throws {
        try await withBench { bench in
            bench.model.armBrush()
            bench.stroke(Self.a, Self.b)
            bench.stroke(Self.b, CGPoint(x: 700, y: 200))
            bench.stroke(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 600))
            #expect(bench.masks.count == 1 && bench.strokes().count == 3)
            bench.undo.undo()
            #expect(bench.strokes().count == 2 && bench.editor.tool == .brush)
            bench.undo.undo()
            #expect(bench.strokes().count == 1)
            bench.model.perform(.newMask(.brush))
            #expect(bench.model.brushPendingRow(on: bench.frame) == .mask("Brush 2") && bench.editor.selection == nil)
            bench.stroke(Self.a, Self.b)
            #expect(bench.masks.count == 2 && bench.model.maskName(bench.masks[1].id, for: bench.frame) == "Brush 2")
            #expect(bench.strokes(0).count == 1 && bench.strokes(1).count == 1)
        }
    }

    /// As in the app, the ticks on the stroke's own queue: the release waits for them and lands the stroke as one step in its own turn,
    /// with the overlay's last picture up; what the lane answers after it is for a stroke that has gone, and changes nothing.
    @Test func onItsOwnLaneAStrokeStillLandsOnItsRelease() async throws {
        try await withBench { bench in
            bench.brush.runsInline = false
            bench.model.armBrush()
            bench.stroke(Self.a, Self.b, steps: 12)
            #expect(bench.strokes().count == 1 && bench.undo.undoActionName == "Paint Mask")
            #expect(!bench.brush.isPainting && bench.editor.printed == nil && !bench.editor.overlay.isLive)
            let image = try #require(bench.editor.overlay.image)
            #expect(image.width == 2048)
            let points = try #require(bench.strokes().first?.points.points)
            #expect(points.first == StrokeSampler.quantized(bench.geometry.maskPoint(Self.a)))
            #expect(points.last == StrokeSampler.quantized(bench.geometry.maskPoint(Self.b)))
            // Escape during one waits for the lane too, and leaves nothing.
            bench.event(.press, Self.b)
            bench.now += 0.1
            bench.event(.drag, Self.a)
            #expect(bench.editor.escape())
            #expect(bench.strokes().count == 1 && !bench.brush.isPainting)
        }
    }

    /// N on a selected brush mask takes up the brush again, for a new mask like it.
    @Test func newLikeABrushIsABrush() async throws {
        try await withBench { bench in
            bench.model.armBrush()
            bench.stroke(Self.a, Self.b)
            #expect(bench.editor.escape() && bench.editor.tool == nil)
            bench.editor.selection = MaskEditor.Selection(mask: bench.masks[0].id, component: nil)
            bench.model.perform(.newLikeSelected)
            #expect(bench.editor.tool == .brush && bench.model.brushPendingRow(on: bench.frame) == .mask("Brush 2"))
        }
    }

    /// Option at the press erases that stroke, from this brush only; the panel's Erase does it for every stroke.
    @Test func optionAtThePressErases() async throws {
        try await withBench { bench in
            bench.model.armBrush()
            bench.stroke(Self.a, Self.b)
            bench.stroke(Self.a, Self.b, modifiers: .option)
            #expect(bench.strokes().map(\.erase) == [false, true])
            #expect(bench.undo.undoActionName == "Erase from Mask")
            bench.brush.settings.erase = true
            bench.stroke(Self.a, Self.b)
            bench.stroke(Self.a, Self.b, modifiers: .option)
            #expect(bench.strokes().map(\.erase) == [false, true, true, false])
        }
    }

    /// Shift-click after a stroke draws a straight line from where it ended to the click; a Shift-drag holds to an axis.
    @Test func shiftClickDrawsALineFromTheLastStroke() async throws {
        try await withBench { bench in
            bench.model.armBrush()
            bench.stroke(Self.a, Self.b)
            let end = try #require(bench.strokes().last?.points.points.last)
            let far = CGPoint(x: 1000, y: 650)
            bench.click(far, modifiers: .shift)
            #expect(bench.strokes().count == 2)
            let line = try #require(bench.strokes().last?.points.points)
            #expect(line.first == end && line.last == StrokeSampler.quantized(bench.geometry.maskPoint(far)))
            // Every point on the chord between them.
            let target = bench.geometry.maskPoint(far)
            for point in line {
                let cross = (point.x - end.x) * (target.y - end.y) - (point.y - end.y) * (target.x - end.x)
                #expect(abs(cross) < 1e-4)
            }
            #expect(bench.undo.undoActionName == "Paint Mask")
            // A Shift press that moves is a drag held to an axis, from where it was pressed.
            bench.stroke(CGPoint(x: 300, y: 500), CGPoint(x: 600, y: 540), modifiers: .shift)
            let held = try #require(bench.strokes().last?.points.points)
            #expect(held.count >= 2 && Set(held.map(\.y)).count == 1)
            #expect(held.first == StrokeSampler.quantized(bench.geometry.maskPoint(CGPoint(x: 300, y: 500))))
        }
    }

    @Test func aShiftDragWithNoStrokeBeforeHoldsToAnAxis() async throws {
        try await withBench { bench in
            bench.model.armBrush()
            bench.stroke(CGPoint(x: 400, y: 100), CGPoint(x: 430, y: 500), modifiers: .shift)
            let points = try #require(bench.strokes().first?.points.points)
            #expect(points.count >= 2 && Set(points.map(\.x)).count == 1)
        }
    }

    /// The repair the plan is for: a Subtract brush into a mask that has a shape already, as a component; undoing its first stroke
    /// leaves the brush in hand, pending for that mask.
    @Test func aSubtractBrushRepairsAGradientMask() async throws {
        try await withBench { bench in
            bench.editor.arm(.linear)
            bench.step { #expect(bench.model.placeArmedGradient()) }
            let gradient = try #require(bench.masks.first)
            #expect(bench.editor.selection?.mask == gradient.id)
            bench.model.perform(.subtractBrush)
            #expect(bench.editor.tool == .brush && bench.editor.pendingOperation == .subtract)
            #expect(bench.model.brushPendingRow(on: bench.frame) == .component(.subtract))
            // Across the gradient's upper part, where it covers most.
            let from = CGPoint(x: 400, y: 80), to = CGPoint(x: 700, y: 140)
            bench.stroke(from, to)
            let mask = try #require(bench.masks.first)
            #expect(bench.masks.count == 1 && mask.components.count == 2)
            #expect(mask.components[1].operation == .subtract && bench.strokes(0, component: 1).count == 1)
            #expect(bench.editor.selection == MaskEditor.Selection(mask: mask.id, component: 1))
            #expect(bench.undo.undoActionName == "Paint Mask")
            // Its coverage falls where it was painted: the gradient's Full end, minus the stroke.
            let middle = bench.geometry.maskPoint(CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2))
            #expect(try MaskCoverage.reference(mask, at: middle) < 0.01)
            #expect(try MaskCoverage.reference(gradient, at: middle) > 0.5)
            bench.undo.undo()
            #expect(bench.masks.first?.components.count == 1 && bench.editor.tool == .brush)
            #expect(bench.editor.selection?.mask == gradient.id)
            #expect(bench.model.brushPendingRow(on: bench.frame) == .component(.subtract))
            // ⌥K on the brush component it made goes on painting that one.
            bench.undo.redo()
            bench.editor.selection = MaskEditor.Selection(mask: gradient.id, component: 1)
            bench.model.perform(.subtractBrush)
            #expect(bench.brush.target(on: bench.frame, model: bench.model) == MaskEditor.Selection(mask: gradient.id, component: 1))
            bench.stroke(Self.b, Self.a)
            #expect(bench.masks.first?.components.count == 2 && bench.strokes(0, component: 1).count == 2)
        }
    }

    /// The Masks tab holds still while a stroke makes its mask or component, and changes when the stroke lands (task H): the pending
    /// row stays, named as the mask now is, and neither the new row nor the panel is built mid-stroke; a stroke into a brush that was
    /// there makes nothing.
    @Test func theTabWaitsForAStrokeThatMakesItsMaskToLand() async throws {
        try await withBench { bench in
            bench.model.armBrush()
            bench.undo.beginUndoGrouping()
            bench.event(.press, Self.a)
            bench.now += 1.0 / 30
            bench.event(.drag, Self.b)
            let made = try #require(bench.masks.first)
            #expect(bench.brush.making?.target == MaskEditor.Selection(mask: made.id, component: 0) && bench.brush.making?.before == nil)
            #expect(bench.model.brushPendingRow(on: bench.frame) == .mask("Brush 1"))
            #expect(bench.model.maskName(made.id, for: bench.frame) == "Brush 1")
            bench.event(.release, Self.b)
            bench.undo.endUndoGrouping()
            #expect(bench.brush.making == nil && bench.model.brushPendingRow(on: bench.frame) == nil)
            // A Subtract brush on it: the component is held back from the tab's mask until its stroke lands.
            bench.model.perform(.subtractBrush)
            bench.undo.beginUndoGrouping()
            bench.event(.press, Self.b)
            bench.now += 1.0 / 30
            bench.event(.drag, Self.a)
            let mask = try #require(bench.masks.first)
            #expect(mask.components.count == 2 && bench.brush.making?.target == MaskEditor.Selection(mask: mask.id, component: 1))
            #expect(bench.brush.shown(mask).components == [mask.components[0]])
            #expect(bench.model.brushPendingRow(on: bench.frame) == .component(.subtract))
            bench.event(.release, Self.a)
            bench.undo.endUndoGrouping()
            let landed = try #require(bench.masks.first)
            #expect(bench.brush.making == nil && bench.brush.shown(landed).components.count == 2)
            // Into the brush it made: nothing is made, nothing held.
            bench.undo.beginUndoGrouping()
            bench.event(.press, Self.a)
            #expect(bench.brush.isPainting && bench.brush.making == nil)
            bench.event(.release, Self.a)
            bench.undo.endUndoGrouping()
        }
    }

    /// While the pointer moves, the stroke reaches the print about every 33 ms through `printed`, and the edit only on the release;
    /// the overlay is the stroke's own, live, and after the release the mask's at rest from the same canvas.
    @Test func theStrokeReachesThePrintAtMost30TimesASecondAndTheEditOnItsRelease() async throws {
        try await withBench { bench in
            bench.model.armBrush()
            bench.stroke(Self.a, Self.b)
            let begun = bench.model.manualEdits[bench.frame.url]
            bench.undo.beginUndoGrouping()
            bench.event(.press, Self.b)
            #expect(bench.brush.isPainting && bench.editor.isPlacing && bench.editor.overlay.isLive)
            let firstFlush = try #require(bench.editor.printed)
            #expect(firstFlush.mask == bench.masks[0].id && firstFlush.component == 0)
            let published = bench.editor.overlay.publishCount
            // Eight events in a clock that does not move: neither the print nor the overlay goes again.
            for step in 1...8 { bench.event(.drag, CGPoint(x: Self.b.x - CGFloat(10 * step), y: Self.b.y)) }
            #expect(bench.editor.printed == firstFlush && bench.editor.overlay.publishCount == published)
            #expect(bench.model.manualEdits[bench.frame.url] == begun)
            bench.now += 2 * MaskEditor.flushInterval
            bench.event(.drag, CGPoint(x: Self.b.x - 100, y: Self.b.y - 30))
            let flushed = try #require(bench.editor.printed)
            #expect(flushed != firstFlush && bench.editor.overlay.publishCount == published + 1)
            // The print's edit holds the stroke so far; the edit itself has not moved.
            guard case .brush(let printed)? = bench.model.printedEdit(for: bench.frame)?.adjustments.masks.masks.first?.components.first?.shape
            else { Issue.record("not printed"); return }
            #expect(printed.strokes.count == 2 && bench.model.manualEdits[bench.frame.url] == begun)
            bench.event(.release, CGPoint(x: Self.b.x - 100, y: Self.b.y - 30))
            bench.undo.endUndoGrouping()
            #expect(bench.strokes().count == 2 && bench.editor.printed == nil && !bench.editor.overlay.isLive)
            #expect(bench.model.printedEdit(for: bench.frame) == bench.model.manualEdits[bench.frame.url])
            // The overlay at rest is the last live picture, kept for the mask as it now is.
            let image = try #require(bench.editor.overlay.image)
            #expect(image.width == 2048 && image.height == 1365)
            let request = MaskOverlayRequest(components: bench.masks[0].components, picture: bench.geometry.picture.size,
                                             longSide: MaskOverlayRequest.settledLongSide)
            bench.editor.overlay.want(request)
            #expect(bench.editor.overlay.image === image)
        }
    }

    /// A slow print does not space the stroke's flushes (J): a print of 60 ms is recorded for the stroke's report, and the next drag
    /// past `flushInterval` still reaches the print, which renders one film at a time and takes the newest flush when it can.
    @Test func aSlowPrintStillTakesTheStrokeAtItsPace() async throws {
        try await withBench { bench in
            bench.model.armBrush()
            bench.undo.beginUndoGrouping()
            defer { bench.undo.endUndoGrouping() }
            bench.event(.press, Self.a)
            bench.editor.filmShown(for: bench.frame, settings: DevelopSettings(), renderedIn: 0.06)
            #expect(bench.editor.printSeconds == 0.06)
            let first = bench.editor.printed
            bench.now += 0.01
            bench.event(.drag, Self.b)
            #expect(bench.editor.printed == first, "within one flush interval")
            bench.now += MaskEditor.flushInterval
            bench.event(.drag, CGPoint(x: 800, y: 500))
            #expect(bench.editor.printed != first)
            bench.event(.release, CGPoint(x: 800, y: 500))
        }
    }

    @Test func escapeInAStrokeLeavesNothingAndTheBrushInHand() async throws {
        try await withBench { bench in
            bench.model.armBrush()
            let before = bench.model.manualEdits[bench.frame.url]
            bench.event(.press, Self.a)
            bench.now += 0.1
            bench.event(.drag, Self.b)
            #expect(bench.masks.count == 1 && bench.brush.isPainting)
            #expect(bench.editor.escape())
            #expect(bench.masks.isEmpty && !bench.brush.isPainting && bench.editor.tool == .brush)
            #expect(bench.model.manualEdits[bench.frame.url] == before && !bench.undo.canUndo)
            #expect(bench.editor.printed == nil && !bench.editor.overlay.isLive && bench.brush.counts.cancelled == 1)
            // The next rung puts the brush down.
            #expect(bench.editor.escape())
            #expect(bench.editor.tool == nil)
        }
    }

    /// An Undo that arrives during a stroke lets the stroke go, as a gradient's drag does, and undoes the step before it.
    @Test func undoDuringAStrokeLetsTheStrokeGo() async throws {
        try await withBench { bench in
            bench.model.armBrush()
            bench.stroke(Self.a, Self.b)
            bench.event(.press, Self.b)
            bench.now += 0.1
            bench.event(.drag, Self.a)
            bench.undo.undo()
            #expect(!bench.brush.isPainting && bench.masks.isEmpty && bench.editor.tool == .brush)
            bench.event(.release, Self.a)
            #expect(bench.masks.isEmpty)
        }
    }

    /// A step that arrives during a stroke (Invert's key, a row's switch, Duplicate) ends the stroke first, as its own step, and
    /// then changes the mask the stroke left: it never writes a copy of the mask read before the stroke landed, which would take
    /// the stroke away again under a step that says only what the key did.
    @Test func aStepDuringAStrokeKeepsTheStroke() async throws {
        try await withBench { bench in
            bench.model.armBrush()
            bench.stroke(Self.a, Self.b)
            let id = try #require(bench.masks.first?.id)
            let steps: [(name: String, step: () -> Void, holds: (Mask) -> Bool)] = [
                ("Invert Mask", { bench.model.invertSelectedComponent(for: bench.frame) }, { $0.components[0].invert }),
                ("Turn Mask Off", { bench.model.setMaskEnabled(false, mask: id, for: bench.frame) }, { !$0.isEnabled }),
            ]
            for (index, entry) in steps.enumerated() {
                bench.undo.beginUndoGrouping()
                bench.event(.press, Self.b)
                bench.now += 0.1
                bench.event(.drag, Self.a)
                #expect(bench.brush.isPainting && bench.strokes().count == index + 1, "the edit takes a stroke on its release")
                bench.undo.endUndoGrouping()
                bench.step(entry.step)
                #expect(!bench.brush.isPainting && bench.strokes().count == index + 2, "\(entry.name) kept the stroke")
                #expect(entry.holds(try #require(bench.masks.first)) && bench.undo.undoActionName == entry.name)
                bench.event(.release, Self.a)
                #expect(bench.strokes().count == index + 2)
            }
            // Duplicate copies the mask with the stroke that was under way.
            #expect(bench.editor.tool == .brush)
            bench.undo.beginUndoGrouping()
            bench.event(.press, Self.a)
            bench.now += 0.1
            bench.event(.drag, Self.b)
            bench.undo.endUndoGrouping()
            bench.step { bench.model.duplicateMask(id, for: bench.frame) }
            #expect(bench.masks.count == 2 && bench.strokes(0).count == 4 && bench.strokes(1) == bench.strokes(0))
            #expect(bench.editor.selection?.mask == bench.masks[1].id && bench.undo.undoActionName == "Duplicate Mask")
        }
    }

    /// A mask turned off is painted like any other: a plain stroke into its brush, which holds a Follow edges stroke, lays the
    /// brush's canvas from the stroke's stored shape once nothing keeps it (a relaunch, a develop's trim), and lands.
    @Test func aMaskTurnedOffTakesAStrokeBesideItsFollowEdgesStrokes() async throws {
        try await withBench { bench in
            bench.source.seeds = StoredMaskSeeds(store: bench.model.maskSeedStore)
            bench.model.armBrush()
            bench.model.perform(.followEdges)
            bench.brush.settings.size = 30
            bench.stroke(CGPoint(x: 300, y: 460), CGPoint(x: 800, y: 460))
            bench.model.perform(.followEdges)
            let id = try #require(bench.masks.first?.id)
            #expect(bench.strokes().first?.measured != nil && !bench.brush.settings.followEdges)
            bench.step { bench.model.setMaskEnabled(false, mask: id, for: bench.frame) }
            #expect(bench.masks.first?.isEnabled == false && bench.editor.tool == .brush)
            // Nothing keeps the brush's canvas, as after a relaunch.
            bench.source.gpu.maskFields.removeAll()
            bench.stroke(Self.a, Self.b)
            #expect(bench.brush.lastRefusal == nil)
            #expect(bench.strokes().count == 2 && bench.undo.undoActionName == "Paint Mask")
        }
    }

    /// A frame whose picture is not ready yet takes no stroke and leaves nothing, the brush still in hand.
    @Test func aFrameNotReadyTakesNoStroke() async throws {
        try await withBench { bench in
            bench.model.armBrush()
            bench.source.isReady = false
            let before = bench.model.manualEdits[bench.frame.url]
            bench.stroke(Self.a, Self.b)
            #expect(bench.masks.isEmpty && bench.model.manualEdits[bench.frame.url] == before)
            #expect(bench.brush.counts.refused == 1 && bench.brush.lastRefusal != nil && bench.editor.tool == .brush)
            // The refused press asks for the frame's decode again, for the next press (a frame seen earlier shows its film with none held).
            #expect(bench.source.heldDecodes == 1)
            bench.source.isReady = true
            bench.stroke(Self.a, Self.b)
            #expect(bench.masks.count == 1)
        }
    }

    /// Choosing another mask puts the brush down, as Lightroom's does; choosing a part of its own mask does not.
    @Test func anotherMaskChosenPutsTheBrushDown() async throws {
        try await withBench { bench in
            bench.editor.arm(.linear)
            bench.step { #expect(bench.model.placeArmedGradient()) }
            bench.model.armBrush()
            bench.stroke(Self.a, Self.b)
            let gradient = bench.masks[0].id, brush = bench.masks[1].id
            bench.editor.selection = MaskEditor.Selection(mask: brush, component: 0)
            #expect(bench.editor.tool == .brush)
            bench.editor.selection = MaskEditor.Selection(mask: gradient, component: nil)
            #expect(bench.editor.tool == nil)
        }
    }

    /// ] [ ⇧] ⇧[ and the digits act on the brush in hand, asked of the live tool; without it a digit is not Flow's.
    @Test func theKeysStepTheBrushInHandOnly() async throws {
        try await withBench { bench in
            bench.model.perform(.largerBrush)
            bench.model.digitPressed(3)
            #expect(bench.brush.settings == .standard)
            bench.model.armBrush()
            let stock = bench.model.stockIndex
            bench.model.perform(.largerBrush)
            bench.model.perform(.moreFeather)
            bench.model.perform(.flow(digit: 3))
            #expect(abs(bench.brush.settings.size - 7.5) < 1e-4 && bench.brush.settings.feather == 60 && bench.brush.settings.flow == 30)
            // A Stock item's digit that beat the menu's refresh sets Flow too, and no stock.
            bench.model.digitPressed(0)
            #expect(bench.brush.settings.flow == 100 && bench.model.stockIndex == stock)
            bench.model.perform(.smallerBrush)
            bench.model.perform(.lessFeather)
            #expect(abs(bench.brush.settings.size - 6) < 1e-4 && bench.brush.settings.feather == 50)
            // The ring follows: size and feather in the picture's points.
            bench.canvas.mouseMoved(with: try #require(NSEvent.mouseEvent(with: .mouseMoved, location: Self.a, modifierFlags: [], timestamp: 0,
                                                                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
            if bench.canvas.ring.isShown {
                let radii = try #require(bench.canvas.ring.radii)
                #expect(abs(radii.outer - 0.03 * 1134) < 0.01 && abs(radii.inner - 0.015 * 1134) < 0.01)
            }
        }
    }
}

/// The overlay while a stroke paints it, pure: requests wait, the stroke's pictures go up, and the last is kept for the mask at rest.
@MainActor @Suite struct MaskOverlayLiveTests {
    private static func picture(_ value: UInt8) -> CGImage {
        MaskOverlayStore.image(of: [UInt8](repeating: value, count: 64 * 32), width: 64, height: 32)!
    }

    @Test func aStrokeHoldsTheOverlayAndItsLastPictureIsKept() async {
        let store = MaskOverlayStore(clock: { 0 })
        let shape = MaskComponent(shape: .radial(.init(center: MaskPoint(x: 0.5, y: 0.3), semiAxisA: 0.2, semiAxisB: 0.1)))
        let before = MaskOverlayRequest(components: [shape], picture: CGSize(width: 600, height: 400), longSide: 64)
        let live = Self.picture(100)
        store.showLive(live)
        #expect(store.isLive && store.image === live)
        // What the rule asks for meanwhile waits for the stroke.
        store.want(before)
        await store.settle()
        #expect(store.image === live && store.rasterCount == 0)
        let last = Self.picture(200)
        let after = MaskOverlayRequest(components: [shape, shape], picture: CGSize(width: 600, height: 400), longSide: 64)
        store.endLive(keeping: last, for: after)
        #expect(!store.isLive && store.image === last)
        store.want(after)
        #expect(store.image === last)
    }

    @Test func aCancelledStrokeGivesTheOverlayBackToTheRule() async {
        let store = MaskOverlayStore(clock: { 0 })
        store.showLive(Self.picture(100))
        store.endLive(keeping: nil, for: nil)
        #expect(!store.isLive && store.image == nil)
    }

    /// The overlay at rest and the list's thumbnails read a brush's strokes as its canvas holds them.
    @Test func theReferenceReadsABrush() throws {
        let stroke = BrushStroke(radius: 0.05, feather: 0, flow: 1,
                                 points: try PackedPoints.pack([MaskPoint(x: 0.25, y: 0.3), MaskPoint(x: 0.5, y: 0.3)]))
        let frame = try MaskFrame(orientation: 1, width: 600, height: 400, decoder: .apple, lensCorrection: true)
        let brush = MaskComponent(shape: .brush(BrushPaint(frame: frame, strokes: [stroke])))
        let raster = MaskCoverageReference().raster(of: [brush], width: 120, height: 80)
        #expect(raster[Int(0.3 * 120) * 120 + Int(0.375 * 120)] > 250)
        #expect(raster[70 * 120 + 110] == 0)
    }
}


#if DEBUG
extension MaskBrushStrokeTests {
    private func withGeometryBench(_ body: (Bench, MaskLens, LensGeometry) throws -> Void) async throws {
        let shown = UserDefaults.standard.object(forKey: "manualInspectorShown"), tab = UserDefaults.standard.object(forKey: AdjustInspectorTab.storageKey)
        defer {
            UserDefaults.standard.set(shown, forKey: "manualInspectorShown")
            UserDefaults.standard.set(tab, forKey: AdjustInspectorTab.storageKey)
        }
        try await AutoDecisionStateTests.withRoll { fixture in
            let raw = fixture.raw(0).resolvingSymlinksInPath()
            try cloneLensGeometrySample(to: raw)
            let model = fixture.model(), gate = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            let frames = try #require(model.roll?.frames), frame = frames[0]
            gate.openAll(frames)
            _ = try #require(await model.settledDecision())
            await model.prepareManualAdjustments(for: frame)
            model.recordVisibleAutomatic(for: frame, stock: model.stockIndex, aim: model.printAim(for: frame), settings: model.settings(for: frame, stock: model.stockIndex))
            model.setManualAdjustments(try ManualAdjustments(exposureEV: 0.5, lens: LensSettings(arguments: "distortion=off")), for: frame)
            model.selection = frame.id
            model.openFrame()
            model.adjustTab = .masks
            model.isAdjustmentsShown = true
            model.manualUndoManager = UndoManager()
            model.manualUndoManager?.groupsByEvent = false
            let source = try TestCanvasSource()
            source.seeds = StoredMaskSeeds(store: model.maskSeedStore)
            let defaults = ScratchDefaults()
            let bench = Bench(model: model, frame: frame, folder: fixture.folder, source: source, defaults: defaults)
            defer { bench.canvas.teardown() }
            _ = try #require(model.films).key(frame, lens: model.lensSettings(for: frame))
            bench.editor.filmShown(for: frame, settings: model.printSettings(for: frame, stock: model.stockIndex), renderedIn: 0)
            let lens = try #require(bench.editor.lens(on: frame))
            try #require(lens.picture != lens.legacy)
            let madeOn = try LensGeometry(table: RadialTable(knots: [1, 0.99, 0.96]), scale: 1)
            try body(bench, lens, madeOn)
        }
    }

    @Test(.enabled(if: hasLensGeometrySample)) func aBrushOnAnotherFrameUsesThatFramesSettings() async throws {
        try await withGeometryBench { bench, _, _ in
            let model = bench.model, editor = bench.editor
            let other = try #require(model.roll?.frames.first { $0.url != bench.frame.url })
            model.manualReadySources[other.url] = try SourceDigests.shared.digest(of: other.url)
            model.recordVisibleAutomatic(for: other, stock: model.stockIndex, aim: model.printAim(for: other),
                                         settings: model.settings(for: other, stock: model.stockIndex))
            model.selection = other.id
            model.openFrame()
            editor.pictureShown(for: bench.frame, settings: model.printSettings(for: bench.frame, stock: model.stockIndex))
            try #require(editor.lens(on: bench.frame) != nil && editor.lens(on: other) == nil)
            try #require(model.canAdjust(other))
            model.armBrush()
            bench.event(.press, Self.a)
            #expect(bench.source.pictureLensSettings.last == model.lensSettings(for: other))
            #expect(bench.brush.stroke?.frame.url == other.url)
            bench.brush.cancel()
        }
    }

    @Test(.enabled(if: hasLensGeometrySample)) func aPressMovesAnExistingBrushInsideTheStrokesUndoStep() async throws {
        try await withGeometryBench { bench, lens, madeOn in
            let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: false, geometry: madeOn)
            let shape = MaskShape.brush(.init(frame: frame, strokes: [.init(radius: 0.02, points: try .pack([.init(x: 0.18, y: 0.18)]))]))
            let mask = Mask(components: [.init(shape: shape)])
            let values = try bench.model.manualAdjustments(for: bench.frame).settingMasks(MaskSet(masks: [mask]))
            bench.model.manualEdits[bench.frame.url]?.adjustments = values
            bench.editor.selection = .init(mask: mask.id, component: 0)
            bench.model.armBrush(adding: .add)
            let before = bench.model.manualEdits[bench.frame.url]
            let expected = shape.moved(in: lens) { m, _ in m }
            bench.click(Self.a)
            #expect(bench.brush.lastRefusal == nil)
            guard case .brush(let moved) = bench.masks[0].components[0].shape,
                  case .brush(let originalMoved) = expected,
                  case .brush(let original) = shape else { Issue.record("brush"); return }
            #expect(moved.frame.geometry == lens.picture)
            #expect(moved.strokes.count == 2 && moved.strokes[0] == originalMoved.strokes[0])
            #expect(moved.strokes[0].points != original.strokes[0].points)
            #expect(moved.strokes.last?.points.points == [StrokeSampler.quantized(bench.geometry.maskPoint(Self.a))])
            bench.undo.undo()
            #expect(bench.model.manualEdits[bench.frame.url] == before && !bench.undo.canUndo)
        }
    }

    @Test(.enabled(if: hasLensGeometrySample)) func aPressRefusesABrushWhoseMeasuredShapeCannotMove() async throws {
        try await withGeometryBench { bench, _, madeOn in
            let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: false, geometry: madeOn)
            let raster = try MaskRaster(width: 16, height: 16, plane: [UInt8](repeating: 255, count: 256))
            let measured = try MeasuredStroke(raster: raster.ref, x: 300, y: 200, pictureWidth: 7008, pictureHeight: 4672)
            let stroke = BrushStroke(followEdges: true, radius: 0.02, points: try .pack([.init(x: 0.18, y: 0.18)]), measured: measured)
            let mask = Mask(components: [.init(shape: .brush(.init(frame: frame, strokes: [stroke])))])
            let values = try bench.model.manualAdjustments(for: bench.frame).settingMasks(MaskSet(masks: [mask]))
            bench.model.manualEdits[bench.frame.url]?.adjustments = values
            bench.editor.selection = .init(mask: mask.id, component: 0)
            bench.model.armBrush(adding: .add)
            let before = bench.model.manualEdits[bench.frame.url]
            bench.undo.removeAllActions()
            bench.event(.press, Self.a)
            bench.event(.release, Self.a)
            #expect(bench.brush.lastRefusal == "this brush’s measured shapes cannot be read")
            #expect(!bench.brush.isPainting && !bench.undo.canUndo)
            #expect(bench.model.manualEdits[bench.frame.url] == before)
            #expect(bench.model.manualGestures[bench.frame.url] == nil)
        }
    }
}

#endif
