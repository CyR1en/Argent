import AppKit
import ArgentCore
@testable import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// Pins on the photograph (task M): where each mask's pin sits and that nothing but its shape moves it, when they show, which press is
/// theirs against a tool, a handle and the frame view's pan, and that an Option-drag on one is the Amount row's own gesture: the print
/// alone while it moves, the edit once at its release, one undo step.
@MainActor @Suite(.serialized) struct MaskPinTests {
    // MARK: Placement

    private static let linear = MaskShape.linear(.init(full: MaskPoint(x: 0.2, y: 0.5), zero: MaskPoint(x: 0.2, y: 0.6)))
    private static let radial = MaskShape.radial(.init(center: MaskPoint(x: 0.25, y: 0.4), semiAxisA: 0.1, semiAxisB: 0.08, feather: 50))

    private static func stroke(_ points: [MaskPoint], erase: Bool = false) throws -> BrushStroke {
        BrushStroke(erase: erase, radius: 0.02, points: try PackedPoints.pack(points))
    }

    private static func picture() throws -> MaskFrame {
        try MaskFrame(orientation: 1, width: 6000, height: 4000, decoder: .apple, lensCorrection: false)
    }

    private static func brush() throws -> MaskShape {
        // An erase first, which a brush can begin with: the pin is where painting began.
        .brush(BrushPaint(frame: try picture(), strokes: [try stroke([MaskPoint(x: 0.9, y: 0.6)], erase: true),
                                                          try stroke([MaskPoint(x: 0.75, y: 0.5), MaskPoint(x: 0.8, y: 0.52)]),
                                                          try stroke([MaskPoint(x: 0.1, y: 0.1)])]))
    }

    private static func noSeed(_ selection: SmartSelection) -> MaskSeedPinPoint { .unknown }

    @Test func eachKindHasItsPlace() throws {
        func anchor(_ shape: MaskShape, seed: ((SmartSelection) -> MaskSeedPinPoint)? = nil) -> MaskPinPlacement.Answer {
            MaskPinPlacement.anchor(of: shape, seed: seed ?? Self.noSeed)
        }
        // A linear's middle, where its middle handle moves it; a radial's centre.
        #expect(anchor(Self.linear) == .anchor(.space(MaskPoint(x: 0.2, y: 0.55))))
        #expect(anchor(Self.radial) == .anchor(.space(MaskPoint(x: 0.25, y: 0.4))))
        // A brush's first painting stroke's first point, quantized as stored.
        guard case .anchor(.space(let first)) = anchor(try Self.brush()) else { Issue.record("no brush pin"); return }
        #expect(abs(first.x - 0.75) < 1e-4 && abs(first.y - 0.5) < 1e-4)
        // Only erasing: where the first stroke began, still.
        let erased = MaskShape.brush(BrushPaint(frame: try Self.picture(), strokes: [try Self.stroke([MaskPoint(x: 0.3, y: 0.3)], erase: true)]))
        guard case .anchor(.space(let only)) = anchor(erased) else { Issue.record("no pin for an erasing brush"); return }
        #expect(abs(only.x - 0.3) < 1e-4)
        #expect(anchor(.brush(BrushPaint(frame: try Self.picture()))) == .none)
        // A selection: its seed's point, nowhere until it is made, and waiting while its seed is read.
        let raster = try MaskRaster(width: 16, height: 16, plane: [UInt8](repeating: 255, count: 256)).ref
        let sky = MaskShape.smart(SmartSelection(kind: .sky, raster: raster, frame: try Self.picture()))
        #expect(anchor(sky) == .pending)
        #expect(anchor(sky) { _ in .found(CGPoint(x: 0.4, y: 0.2)) } == .anchor(.fractions(CGPoint(x: 0.4, y: 0.2))))
        #expect(anchor(sky) { _ in .nothing } == .none)
        #expect(anchor(.smart(SmartSelection(kind: .sky))) == .none)
    }

    /// A mask's pin is its first component's, so a component added after never moves it, and a selection still being read holds it back
    /// rather than lend it to a later component and jump when it lands.
    @Test func aMaskOfSeveralTakesItsFirstAndAddingDoesNotMoveIt() throws {
        let one = Mask(components: [MaskComponent(shape: Self.radial)])
        var more = one
        more.components.append(MaskComponent(operation: .subtract, shape: Self.linear))
        more.components.append(MaskComponent(operation: .add, shape: try Self.brush()))
        let a = try #require(MaskPinPlacement.anchor(of: one, seed: Self.noSeed))
        let b = try #require(MaskPinPlacement.anchor(of: more, seed: Self.noSeed))
        #expect(a.anchor == b.anchor && a.component == 0 && b.component == 0)
        // A brush not painted yet, then a gradient: the gradient's.
        let unpainted = Mask(components: [MaskComponent(shape: .brush(BrushPaint(frame: try Self.picture()))), MaskComponent(shape: Self.linear)])
        #expect(MaskPinPlacement.anchor(of: unpainted, seed: Self.noSeed)?.component == 1)
        // A selection waiting for its seed, then a gradient: nothing yet.
        let raster = try MaskRaster(width: 16, height: 16, plane: [UInt8](repeating: 255, count: 256)).ref
        let waiting = Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: raster, frame: try Self.picture()))),
                                        MaskComponent(shape: Self.linear)])
        #expect(MaskPinPlacement.anchor(of: waiting, seed: Self.noSeed) == nil)
        #expect(waiting.pinnedSelection?.kind == .sky)
        #expect(one.pinnedSelection == nil)
    }

    /// What a slider moves is not where a pin is: Amount, the Light values, on and off, a radial's Feather, a selection's Feather and
    /// Invert leave every pin where it was.
    @Test func noSliderMovesAPin() throws {
        let raster = try MaskRaster(width: 16, height: 16, plane: [UInt8](repeating: 255, count: 256)).ref
        let selection = SmartSelection(kind: .subject, raster: raster, frame: try Self.picture())
        let seed: (SmartSelection) -> MaskSeedPinPoint = { _ in .found(CGPoint(x: 0.6, y: 0.4)) }
        for shape in [Self.linear, Self.radial, try Self.brush(), .smart(selection)] {
            let mask = Mask(components: [MaskComponent(shape: shape)])
            let before = MaskPinPlacement.anchor(of: mask, seed: seed)
            var moved = mask
            moved.amount = 1.7
            moved.adjustments = try ManualAdjustments(exposureEV: -1.2, highlights: -40)
            moved.isEnabled = false
            moved.components[0].invert = true
            switch shape {
            case .radial(var g): g.feather = 90; moved.components[0].shape = .radial(g)
            case .smart(var s): s.feather = 80; moved.components[0].shape = .smart(s)
            default: break
            }
            let after = MaskPinPlacement.anchor(of: moved, seed: seed)
            #expect(after != nil && after?.anchor == before?.anchor && after?.component == before?.component, "\(MaskSummary.title(of: shape))")
        }
    }

    // MARK: A selection's point

    private static func seed(_ width: Int, _ height: Int, _ selected: (Int, Int) -> Bool) throws -> MaskRaster {
        try MaskRaster(width: width, height: height, plane: (0..<(width * height)).map { selected($0 % width, $0 / width) ? 255 : 0 })
    }

    /// The value of `seed` at fractions `p`, as the overlay stretches it.
    private static func value(_ seed: MaskRaster, at p: CGPoint) -> UInt8 {
        seed.plane[min(seed.height - 1, Int(p.y * CGFloat(seed.height))) * seed.width + min(seed.width - 1, Int(p.x * CGFloat(seed.width)))]
    }

    @Test func aSelectionsPinStandsDeepInsideIt() throws {
        // The top half of the picture, as a sky: the middle of the band, clear of the frame's top edge.
        let sky = try Self.seed(96, 64) { _, y in y < 32 }
        let p = try #require(MaskSeedPin.point(of: sky, complement: false, width: 6000, height: 4000))
        #expect(abs(p.x - 0.5) < 0.06 && p.y > 0.2 && p.y < 0.3, "\(p)")
        // A ring open on one side, whose centroid is outside it: the pin is on the ring.
        let ring = try Self.seed(120, 80) { x, y in
            let d = hypot(Double(x) - 60, (Double(y) - 40) * 1.5)
            return d > 22 && d < 34 && x < 80
        }
        let q = try #require(MaskSeedPin.point(of: ring, complement: false, width: 6000, height: 4000))
        #expect(Self.value(ring, at: q) == 255, "\(q)")
        // Background: inside what it selects, the complement of its seed.
        let subject = try Self.seed(96, 64) { x, y in abs(x - 48) < 30 && abs(y - 32) < 24 }
        let r = try #require(MaskSeedPin.point(of: subject, complement: true, width: 6000, height: 4000))
        #expect(Self.value(subject, at: r) == 0, "\(r)")
        // A selection of nothing has no pin; a faint one, its most selected place.
        #expect(MaskSeedPin.point(of: try Self.seed(32, 32) { _, _ in false }, complement: false, width: 6000, height: 4000) == nil)
        let faint = try MaskRaster(width: 32, height: 32, plane: (0..<1024).map { $0 == 32 * 20 + 5 ? 40 : 0 })
        let f = try #require(MaskSeedPin.point(of: faint, complement: false, width: 3000, height: 3000))
        #expect(abs(f.x - 5.5 / 32) < 0.04 && abs(f.y - 20.5 / 32) < 0.04, "\(f)")
    }

    /// The seed is read over the picture's shape, as the coverage engine stretches it: a square seed over a portrait picture.
    @Test func aSeedIsReadOverThePicturesShape() throws {
        let left = try Self.seed(64, 64) { x, _ in x < 16 }
        let p = try #require(MaskSeedPin.point(of: left, complement: false, width: 4000, height: 6000))
        #expect(p.x < 0.25 && abs(p.y - 0.5) < 0.1, "\(p)")
        #expect(Self.value(left, at: p) == 255)
    }

    @Test func theDistanceTransformIsExact() {
        // One selected cell in the middle of five by five: distance 1 to the next cell; at the edge, 1 to the surround.
        var inside = [Bool](repeating: false, count: 25)
        inside[12] = true
        #expect(MaskSeedPin.squaredDistances(inside, width: 5, height: 5)[12] == 1)
        let all = MaskSeedPin.squaredDistances([Bool](repeating: true, count: 25), width: 5, height: 5)
        #expect(all[12] == 9 && all[0] == 1 && all[6] == 4)
    }

    /// A seed's point is found once, off the main actor, and kept by the raster's name.
    @Test func theStoreFindsEachPointOnce() async throws {
        let store = MaskPinSeeds()
        let seed = try Self.seed(96, 64) { _, y in y < 32 }
        let reads = Counter()
        store.load = { _ in reads.add(); return seed }
        let selection = SmartSelection(kind: .sky, raster: seed.ref, frame: try Self.picture())
        #expect(store.point(for: selection) == .unknown)
        store.want([selection, selection])
        store.want([selection])
        await store.settle()
        guard case .found(let p) = store.point(for: selection) else { Issue.record("no point"); return }
        #expect(p.y < 0.3 && store.readCount == 1 && reads.count == 1)
        // Feather is not part of what names it.
        var feathered = selection
        feathered.feather = 60
        #expect(store.point(for: feathered) == .found(p))
        #expect(store.point(for: SmartSelection(kind: .sky)) == .nothing)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }

    // MARK: Visibility

    @Test func theyShowInAutoModeAndNotOtherwise() {
        let on = MaskPinVisibility.Inputs(isMasksTabShown: true, hasMasks: true, isPointerInArea: true)
        #expect(MaskPinVisibility.isShown(on) && MaskPinVisibility.isLive(on))
        var away = on
        away.isPointerInArea = false
        #expect(!MaskPinVisibility.isShown(away) && MaskPinVisibility.isLive(away))
        away.isPinPressed = true
        #expect(MaskPinVisibility.isShown(away), "a pin's own drag keeps them up wherever the pointer goes")
        let off: [WritableKeyPath<MaskPinVisibility.Inputs, Bool>: Bool] = [\.isMasksTabShown: false, \.hasMasks: false, \.isHidden: true,
                                                                          \.standsDown: true, \.isArmed: true, \.isPlacing: true]
        for (path, value) in off {
            var inputs = on
            inputs[keyPath: path] = value
            #expect(!MaskPinVisibility.isShown(inputs) && !MaskPinVisibility.isLive(inputs), "\(path)")
        }
    }

    // MARK: Hits

    @Test func aPointTakesTheNearestPinWithinReach() {
        let area = CGSize(width: 1188, height: 756)
        let a = UUID(), b = UUID(), c = UUID()
        let pins = [MaskPin(id: a, point: CGPoint(x: 100, y: 100), component: 0), MaskPin(id: b, point: CGPoint(x: 116, y: 100), component: 0),
                    MaskPin(id: c, point: CGPoint(x: 400, y: 300), component: 0)]
        #expect(MaskPinModel.hovered(at: CGPoint(x: 104, y: 100), in: pins, area: area) == a)
        #expect(MaskPinModel.hovered(at: CGPoint(x: 111, y: 100), in: pins, area: area) == b)
        #expect(MaskPinModel.hovered(at: CGPoint(x: 400, y: 300 + MaskPinModel.hitRadius), in: pins, area: area) == c)
        #expect(MaskPinModel.hovered(at: CGPoint(x: 400, y: 300 + MaskPinModel.hitRadius + 1), in: pins, area: area) == nil)
        // Off the area, nothing: it is under the dock or beyond the workspace.
        let off = [MaskPin(id: a, point: CGPoint(x: 100, y: 760), component: 0)]
        #expect(MaskPinModel.hovered(at: CGPoint(x: 100, y: 758), in: off, area: area) == nil)
    }

    /// Pins on one another, as a duplicated mask's: the one on top for hovering, and each click the next in the list.
    @Test func aClickOnPinsOnOneAnotherTakesEachInTurn() {
        let area = CGSize(width: 1188, height: 756), at = CGPoint(x: 300, y: 300)
        let ids = [UUID(), UUID(), UUID()]
        func pins(selected: Int?) -> [MaskPin] {
            ids.enumerated().map { MaskPin(id: $1, point: at, component: 0, isSelected: $0 == selected) }
        }
        #expect(MaskPinModel.pressed(at: at, in: pins(selected: nil), area: area) == ids[2])
        #expect(MaskPinModel.pressed(at: at, in: pins(selected: 0), area: area) == ids[1])
        #expect(MaskPinModel.pressed(at: at, in: pins(selected: 2), area: area) == ids[0])
        #expect(MaskPinModel.hovered(at: at, in: pins(selected: 0), area: area) == ids[0], "the selected one is drawn on top")
        #expect(MaskPinModel.drawingOrder(pins(selected: 0)).last?.id == ids[0])
    }

    /// One per point, as scrubbing the Amount's number, whole numbers, 0 to 200, left and right.
    @Test func anOptionDragScrubsTheAmountAsItsNumberDoes() {
        #expect(MaskPinModel.amount(from: 1, dragged: 30) == 1.3)
        #expect(MaskPinModel.amount(from: 1, dragged: -45.7) == 0.55)
        #expect(MaskPinModel.amount(from: 1, dragged: 500) == 2)
        #expect(MaskPinModel.amount(from: 0.2, dragged: -500) == 0)
        #expect(MaskPinModel.tag(1.3) == "Amount 130")
    }

    // MARK: On a frame

    private func header(_ url: URL) throws {
        func u16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255)] }
        func u32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(n >> (8 * $0) & 255) } }
        var b: [UInt8] = [0x49, 0x49] + u16(42) + u32(8)
        b += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(26) + u32(0)
        b += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(100) + u16(0) + u32(0)
        try Data(b).write(to: url, options: .atomic)
    }

    /// An open frame with four masks on the Masks tab, a canvas over it and the pointer over the area: a Linear, a Radial, a Brush and a
    /// Sky, in that order, the Sky's seed the top half of the picture.
    @MainActor private final class Bench {
        let model: RollModel, frame: Frame, folder: URL, canvas: MaskCanvasView
        var geometry = FrameGeometry(area: CGSize(width: 1188, height: 756), picture: CGRect(x: 27, y: 0, width: 1134, height: 756), displayScale: 2)
        var now: CFTimeInterval = 100

        init(model: RollModel, frame: Frame, folder: URL) {
            self.model = model
            self.frame = frame
            self.folder = folder
            canvas = MaskCanvasView(editor: model.maskEditor)
            model.maskEditor.canvas = canvas
            canvas.geometry = { [unowned self] in self.geometry }
            model.maskEditor.clock = { [unowned self] in self.now }
        }

        var editor: MaskEditor { model.maskEditor }
        var masks: [Mask] { model.masks(for: frame) }
        var undo: UndoManager { model.manualUndoManager! }
        var pins: [MaskPin] { editor.pins(on: frame, geometry: geometry) }
        func pin(_ index: Int) -> MaskPin? { pins.first { $0.id == masks[index].id } }

        func event(_ phase: MaskCanvasEvent.Phase, _ point: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
            editor.canvasEvent(MaskCanvasEvent(phase: phase, fractions: geometry.normalized(point), point: point, modifiers: modifiers, clickCount: 1))
        }

        /// The pointer, as the canvas's tracking leaves it: on `point` in the area, or off it.
        func pointer(_ point: CGPoint?) { canvas.pointerMoved(to: point) }

        /// A press, drags by `delta` in `steps`, and the release, as one group of the undo manager, as one event loop's turn is.
        func drag(_ from: CGPoint, by delta: CGPoint, steps: Int = 4, modifiers: NSEvent.ModifierFlags = []) {
            undo.beginUndoGrouping()
            press(from, by: delta, steps: steps, modifiers: modifiers)
            undo.endUndoGrouping()
        }

        /// The same with no group: for a press that must register nothing at all.
        func press(_ from: CGPoint, by delta: CGPoint, steps: Int = 4, modifiers: NSEvent.ModifierFlags = []) {
            event(.press, from, modifiers: modifiers)
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                now += 1
                event(.drag, CGPoint(x: from.x + delta.x * t, y: from.y + delta.y * t), modifiers: modifiers)
            }
            event(.release, CGPoint(x: from.x + delta.x, y: from.y + delta.y), modifiers: modifiers)
        }

        /// A step of the model's, as one group.
        func step(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }

        func click(_ at: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
            event(.press, at, modifiers: modifiers)
            event(.release, at, modifiers: modifiers)
        }

        func finish() {
            canvas.teardown()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private static let away = CGPoint(x: 600, y: 700)

    nonisolated private static let skySeed: MaskRaster = try! MaskRaster(width: 96, height: 64, plane: (0..<(96 * 64)).map { $0 / 96 < 32 ? 255 : 0 })

    private func withBench(_ body: (Bench) async throws -> Void) async throws {
        let shown = UserDefaults.standard.object(forKey: "manualInspectorShown"), tab = UserDefaults.standard.object(forKey: AdjustInspectorTab.storageKey)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-mask-pins-\(UUID().uuidString)")
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
        let picture = try Self.picture()
        let masks = [Mask(components: [MaskComponent(shape: Self.linear)]), Mask(components: [MaskComponent(shape: Self.radial)]),
                     Mask(components: [MaskComponent(shape: try Self.brush())]),
                     Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: Self.skySeed.ref, frame: picture)))])]
        let adjustments = try ManualAdjustments(exposureEV: 0.5).settingMasks(try MaskSet(masks: masks))
        model.manualEdits[frame.url] = ManualEdit(adjustments: adjustments, baseline: pin)
        model.manualUndoManager = UndoManager()
        model.manualUndoManager?.groupsByEvent = false
        model.adjustTab = .masks
        model.isAdjustmentsShown = true
        let bench = Bench(model: model, frame: frame, folder: folder)
        bench.editor.pinSeeds.load = { _ in Self.skySeed }
        bench.editor.pinSeeds.want(bench.masks.compactMap(\.pinnedSelection))
        await bench.editor.pinSeeds.settle()
        // On the picture, away from every pin.
        bench.pointer(Self.away)
        defer {
            bench.finish()
            UserDefaults.standard.set(shown, forKey: "manualInspectorShown")
            UserDefaults.standard.set(tab, forKey: AdjustInspectorTab.storageKey)
        }
        try await body(bench)
    }

    @Test func everyMaskHasItsPinWhereItsShapeSays() async throws {
        try await withBench { bench in
            let shown = bench.editor.shownPins(on: bench.frame, geometry: bench.geometry)
            #expect(shown.count == 4 && shown.allSatisfy { !$0.isSelected && $0.isEnabled })
            let g = bench.geometry
            #expect(bench.pin(0)?.point == g.point(for: MaskPoint(x: 0.2, y: 0.55)))
            #expect(bench.pin(1)?.point == g.point(for: MaskPoint(x: 0.25, y: 0.4)))
            let brush = try #require(bench.pin(2)?.point)
            #expect(abs(brush.x - g.point(for: MaskPoint(x: 0.75, y: 0.5)).x) < 0.1)
            // The Sky's, in the middle of the top half.
            let sky = try #require(bench.pin(3)?.point)
            #expect(abs(sky.x - g.center.x) < 0.06 * g.picture.width && sky.y > 0.2 * g.picture.height && sky.y < 0.3 * g.picture.height)
            // A zoom puts them where the picture is now.
            bench.geometry.picture = CGRect(x: -1158, y: -790, width: 3504, height: 2336)
            #expect(bench.pin(1)?.point == bench.geometry.point(for: MaskPoint(x: 0.25, y: 0.4)))
            #expect(bench.editor.followsPointer, "pins want the pointer with no tool and nothing selected")
        }
    }

    /// Lightroom's Auto: up while the pointer is over the area, and not over the inspector or the dock, nor while a tool is in hand, a
    /// handle moves, the masks stand down, or after H.
    @Test func theyShowOnlyWhenTheyMeanSomething() async throws {
        try await withBench { bench in
            @MainActor func shown() -> Int { bench.editor.shownPins(on: bench.frame, geometry: bench.geometry).count }
            #expect(shown() == 4)
            bench.pointer(nil)
            #expect(shown() == 0 && !bench.editor.isPointerInArea)
            bench.pointer(Self.away)
            bench.editor.arm(.brush)
            #expect(shown() == 0 && bench.editor.pin(at: bench.pin(1)!.point, pressing: true) == nil)
            bench.editor.reset()
            bench.pointer(Self.away)
            bench.model.isComparing = true
            #expect(shown() == 0)
            bench.model.isComparing = false
            bench.editor.togglePins()
            #expect(shown() == 0 && !bench.editor.followsPointer && bench.editor.arePinsHidden)
            #expect(!bench.editor.canvasTakesPress(at: bench.pin(1)!.point, command: false))
            bench.editor.togglePins()
            // The canvas follows the pointer again, from where it is.
            bench.pointer(Self.away)
            #expect(shown() == 4)
            bench.model.adjustTab = .light
            #expect(shown() == 0 && !bench.editor.followsPointer)
        }
    }

    @Test func aClickSelectsItsMaskAndNothingElseChanges() async throws {
        try await withBench { bench in
            let edit = bench.model.manualEdits[bench.frame.url]
            let at = try #require(bench.pin(2)?.point)
            #expect(bench.editor.canvasTakesPress(at: at, command: false) && bench.canvas.hitTest(at, modifiers: []) === bench.canvas)
            #expect(!bench.editor.canvasTakesPress(at: at, command: true), "Command-drag pans, on a pin too")
            bench.click(at)
            #expect(bench.editor.selection == MaskEditor.Selection(mask: bench.masks[2].id, component: nil))
            #expect(bench.model.manualEdits[bench.frame.url] == edit && !bench.undo.canUndo)
            #expect(bench.pin(2)?.isSelected == true)
            // Another's, and the selection follows; a press and a drag on a brush's pin moves nothing.
            bench.press(try #require(bench.pin(3)?.point), by: CGPoint(x: 40, y: 10))
            #expect(bench.editor.selection?.mask == bench.masks[3].id)
            #expect(bench.model.manualEdits[bench.frame.url] == edit && !bench.undo.canUndo && bench.editor.press == nil)
        }
    }

    /// A right-click on a pin selects its mask, as a click does, and its menu is that mask's (`PhotographMenu.mask`), named for it; the
    /// edit is as it was. Every kind of pin, the Sky's found on its seed among them.
    @Test func aRightClickSelectsItsMaskAndOpensItsMenu() async throws {
        try await withBench { bench in
            let edit = bench.model.manualEdits[bench.frame.url]
            for index in bench.masks.indices.reversed() {
                let at = try #require(bench.pin(index)?.point)
                let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: bench.canvas.convert(at, to: nil), modifierFlags: [],
                                                            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                #expect(bench.canvas.hitTest(at, modifiers: [], menuClick: true) === bench.canvas)
                let menu = try #require(bench.canvas.menu(for: event))
                #expect(bench.editor.selection == MaskEditor.Selection(mask: bench.masks[index].id, component: nil))
                #expect(menu.items.first?.title == bench.model.maskName(bench.masks[index].id, for: bench.frame))
                #expect(menu.items.map(\.title).last == "Delete Mask")
                #expect(bench.pin(index)?.isSelected == true)
            }
            #expect(bench.model.manualEdits[bench.frame.url] == edit && !bench.undo.canUndo && bench.editor.press == nil)
            // Away from the pins, the photograph's own; the selection stays.
            let elsewhere = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: bench.canvas.convert(Self.away, to: nil), modifierFlags: [],
                                                            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            #expect(bench.canvas.menu(for: elsewhere)?.items.first?.title == "Flag" && bench.editor.selection?.mask == bench.masks[0].id)
        }
    }

    /// Elsewhere the press is the frame view's, which pans and closes as it did; with a tool in hand it is the tool's, so a pin never takes
    /// a stroke's or a gradient's drawing.
    @Test func aPinTakesNoPressThatIsNotItsOwn() async throws {
        try await withBench { bench in
            #expect(!bench.editor.canvasTakesPress(at: CGPoint(x: 600, y: 700), command: false))
            #expect(bench.canvas.hitTest(CGPoint(x: 600, y: 700), modifiers: []) == nil)
            let at = try #require(bench.pin(1)?.point)
            bench.editor.arm(.linear)
            bench.drag(at, by: CGPoint(x: 0, y: 120))
            #expect(bench.masks.count == 5 && bench.editor.selection?.mask == bench.masks[4].id, "the drag drew a new linear")
            bench.editor.arm(.brush)
            #expect(bench.editor.canvasTakesPress(at: at, command: false) && bench.editor.pin(at: at, pressing: true) == nil)
            bench.event(.press, at)
            #expect(bench.editor.selection?.mask != bench.masks[1].id)
            bench.editor.cancelPress()
        }
    }

    /// Hovering a pin shows its mask's overlay as hovering its row does, and going off lets it go.
    @Test func hoveringAPinShowsItsMasksOverlay() async throws {
        try await withBench { bench in
            let at = try #require(bench.pin(1)?.point)
            #expect(bench.model.overlayComponents(for: bench.frame) == nil)
            bench.pointer(CGPoint(x: at.x + 5, y: at.y - 5))
            #expect(bench.editor.hover == .mask(bench.masks[1].id) && bench.pin(1)?.isHovered == true)
            #expect(bench.model.overlayComponents(for: bench.frame) == bench.masks[1].components)
            bench.pointer(Self.away)
            #expect(bench.editor.hover == nil && bench.model.overlayComponents(for: bench.frame) == nil)
            // A row's hover is the row's: a pin does not take it away.
            bench.editor.hover = .mask(bench.masks[0].id)
            bench.pointer(nil)
            #expect(bench.editor.hover == .mask(bench.masks[0].id))
        }
    }

    /// The Amount row's own gesture: the print alone while it moves, with a value tag and the overlay stepped aside, the edit once at its
    /// release, as one "Adjust Mask" step that Undo takes back; and no pin moves meanwhile.
    @Test func anOptionDragOnAPinIsTheAmountRowsGesture() async throws {
        try await withBench { bench in
            let id = bench.masks[1].id, at = try #require(bench.pin(1)?.point), before = bench.model.manualEdits[bench.frame.url]
            let pinsBefore = bench.pins.map(\.point)
            bench.undo.beginUndoGrouping()
            bench.event(.press, at, modifiers: .option)
            #expect(bench.editor.selection?.mask == id)
            bench.event(.drag, CGPoint(x: at.x + 2, y: at.y + 30), modifiers: .option)
            #expect(!bench.editor.isAdjusting, "under the drag threshold, and up and down mean nothing")
            bench.event(.drag, CGPoint(x: at.x + 30, y: at.y), modifiers: .option)
            #expect(bench.editor.isAdjusting && bench.model.manualEdits[bench.frame.url] == before)
            #expect(bench.model.printedEdit(for: bench.frame)?.adjustments.masks.masks.first { $0.id == id }?.amount == 1.3)
            #expect(bench.editor.pinAmountTag(on: bench.frame, geometry: bench.geometry)?.text == "Amount 130")
            #expect(bench.model.overlayComponents(for: bench.frame) == nil, "it steps aside as for the slider")
            #expect(bench.editor.shownPins(on: bench.frame, geometry: bench.geometry).count == 4)
            bench.event(.drag, CGPoint(x: at.x + 50, y: at.y), modifiers: .option)
            #expect(bench.pins.map(\.point) == pinsBefore)
            bench.event(.release, CGPoint(x: at.x + 50, y: at.y), modifiers: .option)
            bench.undo.endUndoGrouping()
            #expect(bench.model.mask(id, for: bench.frame)?.amount == 1.5 && bench.editor.printedValues == nil && !bench.editor.isAdjusting)
            #expect(bench.model.printedEdit(for: bench.frame) == bench.model.manualEdits[bench.frame.url])
            #expect(bench.undo.undoActionName == "Adjust Mask" && bench.editor.press == nil)
            #expect(bench.pins.map(\.point) == pinsBefore)
            bench.undo.undo()
            #expect(bench.model.manualEdits[bench.frame.url] == before)
            // A click with Option and no drag selects, and makes no step.
            bench.undo.removeAllActions()
            bench.click(try #require(bench.pin(2)?.point), modifiers: .option)
            #expect(bench.editor.selection?.mask == bench.masks[2].id && !bench.undo.canUndo)
        }
    }

    /// The print takes a pin's Amount at most every `flushInterval`, as a moving gradient's shape: the tag shows each step at once, the
    /// print the newest at the end of the interval, and the release takes the last whatever the time.
    @Test func anOptionDragReachesThePrintAt30HzAndItsTagAtOnce() async throws {
        try await withBench { bench in
            let id = bench.masks[1].id, at = try #require(bench.pin(1)?.point)
            @MainActor func printed() -> Float? { bench.model.printedEdit(for: bench.frame)?.adjustments.masks.masks.first { $0.id == id }?.amount }
            bench.undo.beginUndoGrouping()
            bench.event(.press, at, modifiers: .option)
            bench.event(.drag, CGPoint(x: at.x + 10, y: at.y), modifiers: .option)
            #expect(printed() == 1.1 && bench.editor.pinAmountTag(on: bench.frame, geometry: bench.geometry)?.text == "Amount 110")
            bench.now += MaskEditor.flushInterval / 2
            bench.event(.drag, CGPoint(x: at.x + 20, y: at.y), modifiers: .option)
            #expect(printed() == 1.1 && bench.editor.pinAmountTag(on: bench.frame, geometry: bench.geometry)?.text == "Amount 120")
            bench.now += MaskEditor.flushInterval / 2 + 0.001
            bench.event(.drag, CGPoint(x: at.x + 30, y: at.y), modifiers: .option)
            #expect(printed() == 1.3)
            bench.event(.drag, CGPoint(x: at.x + 35, y: at.y), modifiers: .option)
            bench.event(.release, CGPoint(x: at.x + 35, y: at.y), modifiers: .option)
            bench.undo.endUndoGrouping()
            #expect(bench.model.mask(id, for: bench.frame)?.amount == 1.35 && bench.editor.pinDragAmount == nil && bench.editor.printedValues == nil)
        }
    }

    @Test func escapeInAnOptionDragPutsTheAmountBack() async throws {
        try await withBench { bench in
            let id = bench.masks[2].id, at = try #require(bench.pin(2)?.point), before = bench.model.manualEdits[bench.frame.url]
            bench.event(.press, at, modifiers: .option)
            bench.event(.drag, CGPoint(x: at.x - 60, y: at.y), modifiers: .option)
            #expect(bench.model.printedEdit(for: bench.frame)?.adjustments.masks.masks.first { $0.id == id }?.amount == 0.4)
            #expect(bench.editor.escape())
            #expect(bench.model.manualEdits[bench.frame.url] == before && bench.editor.printedValues == nil && !bench.editor.isAdjusting)
            #expect(!bench.undo.canUndo && bench.editor.selection?.mask == id && bench.editor.press == nil)
        }
    }

    /// The selected gradient's pin stands on its handle that moves it whole: one target there. A drag moves the gradient, Option-drag its
    /// Amount; an unselected gradient's pin selects it and moves it in the same press.
    @Test func aGradientsPinIsTheHandleThatMovesItWhole() async throws {
        try await withBench { bench in
            let linear = bench.masks[0].id
            let at = try #require(bench.pin(0)?.point)
            bench.drag(at, by: CGPoint(x: 0, y: -40))
            #expect(bench.editor.selection?.mask == linear && bench.undo.undoActionName == "Adjust Gradient")
            guard case .linear(let moved) = bench.masks[0].components[0].shape else { Issue.record("not linear"); return }
            #expect(abs(moved.full.y - (0.5 - Float(40 / bench.geometry.longSide))) < 1e-4)
            let pin = try #require(bench.pin(0))
            #expect(pin.isSelected && pin.isOnHandle)
            let middle = try #require(MaskHandleModel.handles(of: bench.masks[0].components[0].shape, in: bench.geometry).first { $0.handle == .middle })
            #expect(hypot(middle.point.x - pin.point.x, middle.point.y - pin.point.y) < 1e-6)
            // Option there is the Amount's.
            bench.drag(pin.point, by: CGPoint(x: -25, y: 0), modifiers: .option)
            #expect(bench.model.mask(linear, for: bench.frame)?.amount == 0.75 && bench.undo.undoActionName == "Adjust Mask")
            #expect(bench.masks[0].components[0].shape == .linear(moved))
            // The other handles stay the handles', and are no pin.
            let full = try #require(MaskHandleModel.handles(of: bench.masks[0].components[0].shape, in: bench.geometry).first { $0.handle == .full })
            bench.drag(full.point, by: CGPoint(x: 20, y: 0), modifiers: .option)
            #expect(bench.undo.undoActionName == "Adjust Gradient" && bench.model.mask(linear, for: bench.frame)?.amount == 0.75)
            // While a handle moves, the pins step aside.
            let zero = try #require(MaskHandleModel.handles(of: bench.masks[0].components[0].shape, in: bench.geometry).first { $0.handle == .zero })
            bench.undo.beginUndoGrouping()
            bench.event(.press, zero.point)
            bench.event(.drag, CGPoint(x: zero.point.x + 30, y: zero.point.y))
            #expect(bench.editor.shownPins(on: bench.frame, geometry: bench.geometry).isEmpty)
            bench.event(.release, CGPoint(x: zero.point.x + 30, y: zero.point.y))
            bench.undo.endUndoGrouping()
            #expect(bench.editor.shownPins(on: bench.frame, geometry: bench.geometry).count == 4)
        }
    }

    /// A component added later leaves the pin where it was; a duplicate's sits on its original's, and clicks reach each in turn.
    @Test func addingAComponentOrDuplicatingKeepsThePinsPlaces() async throws {
        try await withBench { bench in
            let radial = bench.masks[1].id, at = try #require(bench.pin(1)?.point)
            bench.undo.beginUndoGrouping()
            bench.model.beginManualGesture(for: bench.frame)
            #expect(bench.model.appendMaskComponent(MaskComponent(operation: .subtract, shape: Self.linear), to: radial, for: bench.frame))
            bench.model.endManualGesture(for: bench.frame, actionName: "Subtract Linear")
            bench.undo.endUndoGrouping()
            #expect(bench.model.mask(radial, for: bench.frame)?.components.count == 2 && bench.pin(1)?.point == at)
            bench.step { bench.model.duplicateMask(radial, for: bench.frame) }
            let copy = bench.masks[2].id
            #expect(bench.editor.selection?.mask == copy && bench.pin(2)?.point == at)
            bench.click(at)
            #expect(bench.editor.selection?.mask == radial)
            bench.click(at)
            #expect(bench.editor.selection?.mask == copy)
        }
    }

    /// Through the canvas view, as AppKit sends a press: on a pin whose mask is not selected yet, the press selects it and its drag still
    /// reaches the editor. The selection's change asks the canvas whether a press is under way, and one told none let the drag go
    /// (found in the running app: an Option-drag on an unselected pin changed nothing).
    @Test func aPressOnAnUnselectedPinKeepsItsDragThroughTheCanvas() async throws {
        try await withBench { bench in
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { bench.canvas.removeFromSuperview(); window.close() }
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1300, height: 900))
            bench.canvas.frame = NSRect(origin: CGPoint(x: 60, y: 40), size: bench.geometry.area)
            window.contentView?.addSubview(bench.canvas)
            @MainActor func send(_ type: NSEvent.EventType, _ point: CGPoint, _ flags: NSEvent.ModifierFlags) throws {
                let event = try #require(NSEvent.mouseEvent(with: type, location: bench.canvas.convert(point, to: nil), modifierFlags: flags,
                                                            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
                switch type {
                case .leftMouseDown: bench.canvas.mouseDown(with: event)
                case .leftMouseDragged: bench.canvas.mouseDragged(with: event)
                default: bench.canvas.mouseUp(with: event)
                }
            }
            // Option on the Linear's pin, not selected: its Amount.
            let linear = bench.masks[0].id, at = try #require(bench.pin(0)?.point)
            bench.undo.beginUndoGrouping()
            try send(.leftMouseDown, at, .option)
            #expect(bench.editor.selection?.mask == linear && bench.editor.press != nil)
            for step in 1...4 { bench.now += 1; try send(.leftMouseDragged, CGPoint(x: at.x + CGFloat(step) * 10, y: at.y), .option) }
            #expect(bench.editor.isAdjusting && bench.editor.printedValues?.amount == 1.4 && bench.editor.pinDragAmount == 1.4)
            try send(.leftMouseUp, CGPoint(x: at.x + 40, y: at.y), .option)
            bench.undo.endUndoGrouping()
            #expect(bench.model.mask(linear, for: bench.frame)?.amount == 1.4 && bench.undo.undoActionName == "Adjust Mask")
            // A plain drag on the Radial's pin, not selected: it moves, as from its centre handle.
            let radial = bench.masks[1].id, from = try #require(bench.pin(1)?.point)
            bench.undo.beginUndoGrouping()
            try send(.leftMouseDown, from, [])
            for step in 1...4 { bench.now += 1; try send(.leftMouseDragged, CGPoint(x: from.x, y: from.y + CGFloat(step) * 10), []) }
            try send(.leftMouseUp, CGPoint(x: from.x, y: from.y + 40), [])
            bench.undo.endUndoGrouping()
            guard case .radial(let g) = bench.model.mask(radial, for: bench.frame)?.components[0].shape else { Issue.record("not radial"); return }
            #expect(abs(g.center.y - (0.4 + Float(40 / bench.geometry.longSide))) < 1e-4 && bench.undo.undoActionName == "Adjust Gradient")
            #expect(bench.editor.selection?.mask == radial)
        }
    }

    /// A mask turned off keeps its pin, dimmed, and a click still selects it.
    @Test func aMaskTurnedOffKeepsItsPin() async throws {
        try await withBench { bench in
            bench.step { bench.model.setMaskEnabled(false, mask: bench.masks[3].id, for: bench.frame) }
            let pin = try #require(bench.pin(3))
            #expect(!pin.isEnabled)
            bench.click(pin.point)
            #expect(bench.editor.selection?.mask == bench.masks[3].id)
        }
    }
}


extension MaskPinTests {
    @Test func pinsFollowTheShownGeometry() async throws {
        let shown = UserDefaults.standard.object(forKey: "manualInspectorShown"), tab = UserDefaults.standard.object(forKey: AdjustInspectorTab.storageKey)
        defer {
            UserDefaults.standard.set(shown, forKey: "manualInspectorShown")
            UserDefaults.standard.set(tab, forKey: AdjustInspectorTab.storageKey)
        }
        try await AutoDecisionStateTests.withRoll { fixture in
            let model = fixture.model(), gate = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            let frames = try #require(model.roll?.frames), frame = frames[0]
            gate.openAll(frames)
            _ = try #require(await model.settledDecision())
            await model.prepareManualAdjustments(for: frame)
            model.recordVisibleAutomatic(for: frame, stock: model.stockIndex, aim: model.printAim(for: frame), settings: model.settings(for: frame, stock: model.stockIndex))
            let madeOn = try LensGeometry(table: RadialTable(knots: [1, 0.99, 0.96]), scale: 1)
            let shapes = [Self.linear.stamped(madeOn), Self.radial.stamped(madeOn), try Self.brush().stamped(madeOn)]
            let masks = shapes.map { Mask(components: [.init(shape: $0)]) }
            model.setManualAdjustments(try ManualAdjustments(exposureEV: 0.5).settingMasks(MaskSet(masks: masks)), for: frame)
            model.selection = frame.id
            model.openFrame()
            model.adjustTab = .masks
            model.isAdjustmentsShown = true
            let bench = Bench(model: model, frame: frame, folder: fixture.folder)
            defer { bench.canvas.teardown() }
            _ = try #require(model.films).key(frame, lens: .default)
            bench.editor.filmShown(for: frame, settings: DevelopSettings(), renderedIn: 0)
            let lens = try #require(bench.editor.lens(on: frame))
            for (mask, pin) in zip(masks, bench.pins) {
                let anchor = try #require(MaskPinPlacement.anchor(of: mask, seed: Self.noSeed)).anchor.point(in: bench.geometry)
                let remap = try #require(lens.toPicture(mask.components[0].shape))
                let expected = bench.geometry.point(for: remap.point(bench.geometry.maskPoint(anchor)))
                #expect(hypot(pin.point.x - expected.x, pin.point.y - expected.y) < 1e-6)
                #expect(hypot(pin.point.x - anchor.x, pin.point.y - anchor.y) > 0.1)
            }
            #expect(bench.pins.count == masks.count)
            #expect(bench.editor.lens(on: frames[1]) == nil)
            #expect(model.masks(for: frame) == masks)
        }
    }
}
