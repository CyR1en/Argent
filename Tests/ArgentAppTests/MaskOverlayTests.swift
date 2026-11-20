import ArgentCore
@testable import ArgentRoll
import CoreGraphics
import Foundation
import Testing
@testable import ArgentApp

/// A field that counts how often it is asked, and can hold a raster back.
private final class CountingField: MaskCoverageField, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[MaskComponent]] = []
    var count: Int { lock.withLock { calls.count } }
    var last: [MaskComponent]? { lock.withLock { calls.last } }

    func raster(of components: [MaskComponent], width: Int, height: Int) -> [UInt8] {
        lock.withLock { calls.append(components) }
        return [UInt8](repeating: 128, count: width * height)
    }
}

/// The overlay: when it shows by the plan's rule, what fills it, and that a slider never asks for a new raster.
@MainActor @Suite(.serialized) struct MaskOverlayTests {
    private static func linear(_ zero: Float = 0.4) -> [MaskComponent] {
        [MaskComponent(shape: .linear(.init(full: MaskPoint(x: 0.5, y: 0), zero: MaskPoint(x: 0.5, y: zero))))]
    }

    private static let radial = MaskComponent(shape: .radial(.init(center: MaskPoint(x: 0.5, y: 0.33), semiAxisA: 0.25, semiAxisB: 0.2, feather: 20)))

    private static func request(_ components: [MaskComponent], long: Int = 32) -> MaskOverlayRequest {
        MaskOverlayRequest(components: components, picture: CGSize(width: 1134, height: 756), longSide: long)
    }

    // MARK: The rule

    /// Plan section 5, row by row: red on creating and handle-dragging, hidden while a slider moves, shown while
    /// hovering a row, toggled with O; and nothing at all under what stands down.
    @Test func theVisibilityTable() {
        typealias I = MaskOverlayVisibility.Inputs
        let table: [(String, I, MaskOverlayVisibility.Shown)] = [
            ("nothing going on", I(), .nothing),
            ("a selection at rest", I(hasSelection: true), .nothing),
            ("just drawn", I(hasSelection: true, justPlaced: true), .selection),
            ("being drawn", I(isPlacing: true, hasSelection: true), .selection),
            ("a handle moving", I(isPlacing: true, hasSelection: true, justPlaced: true), .selection),
            ("the checkbox", I(hasSelection: true, isOn: true), .selection),
            ("the checkbox with no selection", I(isOn: true), .nothing),
            ("hovering a row", I(isHovering: true), .hovered),
            ("hovering beats the checkbox's mask", I(isHovering: true, hasSelection: true, isOn: true), .hovered),
            ("hovering with the checkbox off", I(isHovering: true, hasSelection: true), .hovered),
            ("a slider moving, just drawn", I(isAdjusting: true, hasSelection: true, justPlaced: true), .nothing),
            ("a slider moving, checkbox on", I(isAdjusting: true, hasSelection: true, isOn: true), .nothing),
            ("a slider moving, pointer on a row", I(isAdjusting: true, isHovering: true, hasSelection: true), .nothing),
            ("placing beats hovering", I(isPlacing: true, isHovering: true, hasSelection: true), .selection),
            ("standing down, just drawn", I(standsDown: true, hasSelection: true, justPlaced: true), .nothing),
            ("standing down, checkbox on", I(standsDown: true, hasSelection: true, isOn: true), .nothing),
            ("standing down, hovering", I(standsDown: true, isHovering: true), .nothing),
            ("standing down, placing", I(standsDown: true, isPlacing: true, hasSelection: true), .nothing),
        ]
        for (name, inputs, shown) in table {
            #expect(MaskOverlayVisibility.shown(inputs) == shown, "\(name)")
        }
    }

    @Test func oTogglesWhatIsUpAndTheCheckboxKeepsItUp() {
        let editor = MaskEditor(defaults: privateDefaults())
        #expect(!editor.isOverlayOn)
        editor.toggleOverlay()
        #expect(editor.isOverlayOn)
        editor.toggleOverlay()
        #expect(!editor.isOverlayOn)
        // Just drawn, O hides it, and does not turn it on.
        editor.didPlace(MaskEditor.Selection(mask: UUID(), component: nil))
        #expect(editor.justPlaced)
        editor.toggleOverlay()
        #expect(!editor.justPlaced && !editor.isOverlayOn)
        // The checkbox: on stays on through a slider; off hides what is up.
        editor.didPlace(MaskEditor.Selection(mask: UUID(), component: nil))
        editor.setOverlay(on: true)
        editor.sliderBegan()
        #expect(editor.isAdjusting && editor.isOverlayOn && !editor.justPlaced)
        editor.sliderEnded()
        #expect(!editor.isAdjusting && editor.isOverlayOn)
        editor.setOverlay(on: false)
        #expect(!editor.isOverlayOn)
    }

    /// What a gradient's drawing left up does not come back once a slider has moved: its effect is what is
    /// being judged. Only the checkbox brings the red back after a slider.
    @Test func aSliderTakesAwayTheRedForGoodUnlessTheCheckboxHoldsIt() {
        let editor = MaskEditor(defaults: privateDefaults())
        editor.didPlace(MaskEditor.Selection(mask: UUID(), component: nil))
        editor.sliderBegan()
        editor.sliderEnded()
        #expect(!editor.justPlaced)
        editor.shapeRowBegan()
        #expect(editor.isPlacing && !editor.justPlaced)
        editor.shapeRowEnded()
        #expect(!editor.isPlacing && editor.justPlaced)
    }

    private func privateDefaults() -> UserDefaults { ScratchDefaults() }

    @Test func theColourCyclesAndIsKept() {
        let defaults = privateDefaults()
        let editor = MaskEditor(defaults: defaults)
        #expect(editor.overlayColour == .red)
        var seen: [MaskOverlayColour] = []
        for _ in MaskOverlayColour.allCases {
            editor.nextOverlayColour()
            seen.append(editor.overlayColour)
        }
        #expect(seen == [.green, .white, .black, .red])
        editor.overlayColour = .white
        #expect(MaskEditor(defaults: defaults).overlayColour == .white)
        defaults.set("mauve", forKey: MaskOverlayColour.storageKey)
        #expect(MaskEditor(defaults: defaults).overlayColour == .red)
        #expect(MaskOverlayColour.opacity == 0.5)
        // Increase Contrast and Reduce Transparency: firmer, and the picture still reads through it.
        #expect(MaskOverlayColour.firmOpacity > MaskOverlayColour.opacity && MaskOverlayColour.firmOpacity < 0.8)
    }

    // MARK: Filling it

    /// What the red shows is the engine's reference, pixel centre by pixel centre, top row first in `MaskSpace`.
    @Test func theRasterIsTheCoverageEnginesReference() throws {
        let inverted = MaskComponent(shape: Self.radial.shape, invert: true)
        let subtract = MaskComponent(operation: .subtract, shape: .linear(.init(full: MaskPoint(x: 0, y: 0), zero: MaskPoint(x: 1, y: 0))))
        let intersect = MaskComponent(operation: .intersect, shape: Self.radial.shape)
        let linear = Self.linear()
        for components in [linear, [Self.radial], [inverted], linear + [subtract], linear + [intersect], [Self.radial] + linear.map { MaskComponent(operation: .add, shape: $0.shape, invert: true) }] {
            let width = 48, height = 32, bytes = MaskCoverageReference().raster(of: components, width: width, height: height)
            let space = try MaskSpace(width: width, height: height), mask = Mask(components: components)
            #expect(bytes.count == width * height)
            for (x, y) in [(0, 0), (24, 2), (24, 15), (47, 31), (10, 28), (31, 7)] {
                let expected = try MaskCoverage.reference(mask, at: space.point(column: x, yTop: y))
                #expect(abs(Float(bytes[y * width + x]) / 255 - expected) <= 1.0 / 255, "\(x),\(y)")
            }
        }
    }

    /// A portrait picture's raster runs down its long side.
    @Test func aPortraitRasterIsLongSidesToo() throws {
        let bytes = MaskCoverageReference().raster(of: Self.linear(1), width: 32, height: 48)
        #expect(bytes.count == 32 * 48)
        // Falling down the picture, and flat across it.
        #expect(bytes[16] > bytes[47 * 32 + 16] && bytes[0] == bytes[31])
    }

    /// Phase 2's shapes select nothing on the overlay until they can be read, and do not stop what can.
    @Test func whatCannotBeReadYetSelectsNothing() {
        let smart = MaskComponent(shape: .smart(SmartSelection(kind: .sky)))
        #expect(MaskCoverageReference().raster(of: [smart], width: 8, height: 8).allSatisfy { $0 == 0 })
        let after = MaskCoverageReference().raster(of: [smart, MaskComponent(operation: .subtract, shape: Self.radial.shape)], width: 8, height: 8)
        #expect(after == MaskCoverageReference().raster(of: [Self.radial], width: 8, height: 8))
    }

    @Test func thePictureIsAlphaOnly() throws {
        let width = 5, height = 3, coverage = (0..<15).map { UInt8($0 * 10) }
        let image = try #require(MaskOverlayStore.image(of: coverage, width: width, height: height))
        // `makeImage()` of an alpha-only context hands back a mask (P0-S2), which is what a template `Image` tints.
        #expect(image.isMask && image.bitsPerPixel == 8 && image.width == 5 && image.height == 3)
        let data = try #require(image.dataProvider?.data as Data?)
        for y in 0..<height {
            for x in 0..<width { #expect(data[y * image.bytesPerRow + x] == coverage[y * width + x]) }
        }
        #expect(MaskOverlayStore.image(of: [1, 2], width: 5, height: 3) == nil)
    }

    @Test func aRequestIsTheShapesAndAFixedSize() {
        let wide = MaskOverlayRequest(components: Self.linear(), picture: CGSize(width: 1134, height: 756), longSide: 512)
        #expect(wide.width == 512 && wide.height == 341)
        let tall = MaskOverlayRequest(components: Self.linear(), picture: CGSize(width: 756, height: 1134), longSide: 512)
        #expect(tall.width == 341 && tall.height == 512)
        // A zoom's rectangle is a point off 3:2, and asks for the same raster.
        let zoomed = MaskOverlayRequest(components: Self.linear(), picture: CGSize(width: 3504, height: 2337), longSide: 512)
        #expect(zoomed == wide)
    }

    // MARK: The store

    @Test func theCadenceIsEverySecondRefresh() {
        #expect(MaskOverlayStore.publishInterval(refreshesPerSecond: 120) == 2.0 / 120)
        #expect(MaskOverlayStore.publishInterval(refreshesPerSecond: 60) == 2.0 / 60)
        #expect(MaskOverlayStore.publishInterval(refreshesPerSecond: 0) == 2)
    }

    /// A moving gradient asks far faster than rasters are made: only the newest goes on, and the last asked is
    /// what ends up shown.
    @Test func newRequestsReplaceOldOnesAndTheLastOneWins() async throws {
        let field = CountingField(), store = MaskOverlayStore(field: field)
        for step in 1...200 { store.want(Self.request(Self.linear(0.1 + Float(step) / 1000))) }
        await store.settle()
        #expect(field.count < 200)
        #expect(field.last == Self.linear(0.3))
        #expect(store.image != nil)
        #expect(store.publishCount <= field.count)
    }

    /// Published at most every second refresh, however quickly rasters come.
    @Test func thePublishingKeepsToTheCadence() async throws {
        let field = CountingField()
        let store = MaskOverlayStore(field: field)
        store.refreshesPerSecond = 20 // 100 ms apart, measurable under any load
        store.want(Self.request(Self.linear(0.1)))
        await store.settle()
        let first = ContinuousClock.now
        store.want(Self.request(Self.linear(0.2)))
        await store.settle()
        #expect(store.publishCount == 2)
        #expect(ContinuousClock.now - first >= .milliseconds(90))
    }

    @Test func nothingWantedTakesThePictureAwayAndWhatIsLateStaysAway() async throws {
        let field = CountingField(), store = MaskOverlayStore(field: field)
        store.want(Self.request(Self.linear()))
        await store.settle()
        #expect(store.image != nil)
        store.want(nil)
        #expect(store.image == nil)
        // A raster in hand when the overlay goes must not bring it back.
        store.want(Self.request(Self.linear(0.5)))
        store.want(nil)
        await store.settle()
        #expect(store.image == nil)
    }

    /// Hovering back to a settled mask makes no new raster.
    @Test func aSettledRasterIsKeptForTheNextHover() async throws {
        let field = CountingField(), store = MaskOverlayStore(field: field)
        let one = Self.request(Self.linear(0.2), long: MaskOverlayRequest.settledLongSide)
        let two = Self.request(Self.linear(0.3), long: MaskOverlayRequest.settledLongSide)
        store.want(one)
        await store.settle()
        store.want(two)
        await store.settle()
        #expect(field.count == 2)
        store.want(one)
        #expect(store.image != nil && field.count == 2)
        // A draft is not kept: it would push out what hovering comes back to.
        store.want(Self.request(Self.linear(0.2), long: MaskOverlayRequest.draftLongSide))
        await store.settle()
        store.want(one)
        #expect(field.count == 3)
    }

    @Test func aThumbnailIsMadeOnceForItsShapes() throws {
        let field = CountingField(), store = MaskOverlayStore(field: field)
        let wide = try #require(store.thumbnail(of: Self.linear(), portrait: false))
        #expect(wide.width == 72 && wide.height == 48 && field.count == 1)
        _ = store.thumbnail(of: Self.linear(), portrait: false)
        #expect(field.count == 1)
        _ = store.thumbnail(of: Self.linear(0.2), portrait: false)
        #expect(field.count == 2)
        let tall = try #require(store.thumbnail(of: Self.linear(0.3), portrait: true))
        #expect(tall.width == 48 && tall.height == 72)
    }

    /// The same shapes on a landscape and a portrait frame (masks copied across, a raw replaced by one turned the other way) are two
    /// pictures, each of its own shape and each kept.
    @Test func aThumbnailIsOfItsPicturesShape() throws {
        let field = CountingField(), store = MaskOverlayStore(field: field)
        let wide = try #require(store.thumbnail(of: Self.linear(), portrait: false))
        let tall = try #require(store.thumbnail(of: Self.linear(), portrait: true))
        #expect(wide.width == 72 && wide.height == 48 && tall.width == 48 && tall.height == 72 && field.count == 2)
        #expect(store.thumbnail(of: Self.linear(), portrait: false)?.width == 72 && store.thumbnail(of: Self.linear(), portrait: true)?.width == 48)
        #expect(field.count == 2)
    }

    /// A thumbnail that reads the library (a seed, a stroke's measured shape) is made off the main actor, since a row's body asks:
    /// nothing at the first ask, made once however often it is asked meanwhile, and the picture once it lands.
    @Test func aThumbnailThatReadsTheLibraryArrives() async throws {
        let field = CountingField(), store = MaskOverlayStore(field: field)
        let seed = try MaskRaster(width: 32, height: 32, plane: [UInt8](repeating: 200, count: 32 * 32))
        let smart = [MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: seed.ref)))]
        #expect(MaskOverlayStore.readsLibrary(smart) && !MaskOverlayStore.readsLibrary(Self.linear()))
        #expect(!MaskOverlayStore.readsLibrary([MaskComponent(shape: .smart(SmartSelection(kind: .sky)))]), "a selection not made reads nothing")
        #expect(store.thumbnail(of: smart, portrait: false) == nil && store.thumbnailsArrived == 0)
        #expect(store.thumbnail(of: smart, portrait: false) == nil)
        await store.settle()
        #expect(store.thumbnailsArrived == 1 && field.count == 1)
        let made = try #require(store.thumbnail(of: smart, portrait: false))
        #expect(made.width == 72 && made.height == 48 && field.count == 1 && store.thumbnailsArrived == 1)
    }

    // MARK: A slider never rebuilds coverage

    /// The request holds nothing but shapes, so moving a slider, Amount or the switch asks for the same raster.
    @Test func aSlidersMoveAsksForTheSameRaster() throws {
        let plain = Mask(components: Self.linear())
        var moved = plain
        moved.adjustments = try ManualAdjustments(exposureEV: -0.6, shadows: 25)
        moved.amount = 1.5
        moved.isEnabled = false
        #expect(moved.coverage == plain.coverage)
        #expect(Self.request(moved.components) == Self.request(plain.components))
    }
}


/// The overlay's sharp raster at a settled zoom (`MaskOverlayStore`'s sharp path): read only once the picture has held still, the last request
/// wins, and it is only ever shown for the request it was read for.
@MainActor @Suite(.serialized) struct MaskOverlaySharpTests {
    private final class RegionField: MaskCoverageField, @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [MaskOverlaySharpRequest] = []
        var answers = true
        var count: Int { lock.withLock { requests.count } }
        var last: MaskOverlaySharpRequest? { lock.withLock { requests.last } }

        func raster(of components: [MaskComponent], width: Int, height: Int) -> [UInt8] { [UInt8](repeating: 128, count: width * height) }

        func sharpRaster(of request: MaskOverlaySharpRequest) -> RegionCoverage? {
            lock.withLock { requests.append(request) }
            guard answers else { return nil }
            return RegionCoverage(values: [UInt8](repeating: 200, count: 12), width: 4, height: 3, fractions: request.fractions)
        }
    }

    private static let frame = Frame(id: 0, url: URL(fileURLWithPath: "/tmp/sharp.ARW"), info: ARWFrameInfo())

    private static func request(at x: CGFloat, components: [MaskComponent] = linear) -> MaskOverlaySharpRequest {
        MaskOverlaySharpRequest(components: components, perPixel: false, version: MaskSet.currentVersion, frame: frame,
                                fractions: CGRect(x: x, y: 0.2, width: 0.3, height: 0.3), decode: MaskOverlayDecode(pixels: 3000, refined: true))
    }

    private static let linear = [MaskComponent(shape: .linear(.init(full: MaskPoint(x: 0.5, y: 0), zero: MaskPoint(x: 0.5, y: 0.4))))]

    @Test func aPictureAtRestGetsItsRasterAndASettingPictureOnlyMovesTheDeadline() async throws {
        let field = RegionField(), store = MaskOverlayStore(field: field)
        store.sharpSettleInterval = 0.05
        for step in 0..<40 { store.wantSharp(Self.request(at: 0.1 + CGFloat(step) / 400)) }
        #expect(field.count == 0)
        await store.settle()
        #expect(field.count == 1, "a pan's every step ends in one read")
        #expect(field.last == Self.request(at: 0.1 + 39.0 / 400))
        #expect(store.sharp?.request == Self.request(at: 0.1 + 39.0 / 400))
        #expect(store.sharpCount == 1 && store.sharpSeconds >= 0)
    }

    @Test func aRequestThatMovesOnGoesDownAtOnceAndNewOnesAreReadInTurn() async throws {
        let field = RegionField(), store = MaskOverlayStore(field: field)
        store.sharpSettleInterval = 0
        store.wantSharp(Self.request(at: 0.1))
        await store.settle()
        #expect(store.sharp != nil)
        store.wantSharp(Self.request(at: 0.2))
        #expect(store.sharp == nil, "the coarse raster takes over at the first step")
        await store.settle()
        #expect(store.sharp?.request == Self.request(at: 0.2))
    }

    @Test func nothingWantedLetsGoAndAFieldThatCannotAnswerIsNotAskedAgain() async throws {
        let field = RegionField(), store = MaskOverlayStore(field: field)
        store.sharpSettleInterval = 0
        store.wantSharp(Self.request(at: 0.1))
        await store.settle()
        store.wantSharp(nil)
        #expect(store.sharp == nil && !store.isSharpWaiting)

        field.answers = false
        store.wantSharp(Self.request(at: 0.4))
        await store.settle()
        let asked = field.count
        // Asking again with the same request and no change reads nothing: a decode's arrival makes a new request.
        store.wantSharp(Self.request(at: 0.4))
        await store.settle()
        #expect(field.count == asked && store.sharp == nil)
    }

    /// A scaled decode refining changes the request and not the place: what is up stays until the new decode's read lands, so the red does not blink.
    @Test func aNewDecodeReplacesTheRasterWithoutTakingItDown() async throws {
        let field = RegionField(), store = MaskOverlayStore(field: field)
        store.sharpSettleInterval = 0
        var refined = Self.request(at: 0.1)
        refined.decode.refined = false
        store.wantSharp(refined)
        await store.settle()
        #expect(store.sharp?.request == refined)
        var after = refined
        after.decode.refined = true
        store.wantSharp(after)
        #expect(store.sharp?.request == refined, "the old raster stays up while the new one is read")
        await store.settle()
        #expect(store.sharp?.request == after && field.count == 2)
    }

    @Test func theSameShapeOverAnotherDecodeIsAnotherRequest() throws {
        var a = Self.request(at: 0.1), b = a
        b.decode.refined = false
        #expect(a != b)
        a = Self.request(at: 0.1)
        var c = a
        c.perPixel = true
        #expect(a != c, "a change of tier is a change of what the print reads")
    }

    @Test func nothingIsSharpOverAFitOrAMovingPicture() {
        let geometry = FrameGeometry(area: CGSize(width: 1188, height: 756), picture: CGRect(x: 27, y: 0, width: 1134, height: 756), displayScale: 2)
        // What a settled zoom shows: the whole picture at fit, a part of it zoomed.
        #expect(geometry.visibleFractions == CGRect(x: 0, y: 0, width: 1, height: 1))
        var zoomed = geometry
        zoomed.picture = CGRect(x: -100, y: -50, width: 2268, height: 1512)
        let shown = zoomed.visibleFractions!
        #expect(abs(shown.minX - 100.0 / 2268) < 1e-9 && abs(shown.width - 1188.0 / 2268) < 1e-9 && abs(shown.height - 756.0 / 1512) < 1e-9)
    }
}

#if DEBUG
extension MaskOverlayTests {
    @Test(.enabled(if: hasLensGeometrySample)) func changingTheLensRasterisesAgainInsteadOfPublishingTheKeptRaster() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-overlay-lens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("frame.ARW")
        try cloneLensGeometrySample(to: raw)
        let frame = Frame(id: 0, url: raw, info: try ARWFrameInfo.read(from: raw))
        let films = try FilmPreviews(stocks: [])
        _ = films.key(frame, lens: .default)
        let file = try #require(films.lensCorrection(for: frame, settings: .default))
        let field = MaskSeedCoverage()
        field.refined = films
        let store = MaskOverlayStore(field: field)
        let components = [MaskComponent(shape: .radial(.init(center: .init(x: 0.85, y: 0.12), semiAxisA: 0.08,
                                                           semiAxisB: 0.05, feather: 10, geometry: file.geometry)))]
        let before = MaskOverlayRequest(components: components, picture: CGSize(width: 1200, height: 800), longSide: 1024,
                                        frame: frame, lens: MaskEditor.PictureLens(frame: frame.url, lens: MaskLens(file, extent: .init(x: 1, y: 2.0 / 3)), settings: .default))
        store.want(before)
        await store.settle()
        let old = try #require(store.image)
        store.want(nil)
        _ = films.key(frame, lens: .default)
        var after = before
        let off = try LensSettings(arguments: "distortion=off")
        after.lens = MaskEditor.PictureLens(frame: frame.url, lens: MaskLens(try #require(films.lensCorrection(for: frame, settings: off)),
                                                                           extent: .init(x: 1, y: 2.0 / 3)), settings: off)
        // Resolving another setting after the request must not change what it rasters.
        _ = films.lensCorrection(for: frame, settings: .default)
        #expect(after != before && Set([before, after]).count == 2)
        store.want(after)
        await store.settle()
        let new = try #require(store.image)
        #expect(store.rasterCount == 2 && new !== old)
        #expect((new.dataProvider?.data as Data?) != (old.dataProvider?.data as Data?))
        store.want(nil)
        store.want(after)
        await store.settle()
        #expect(store.rasterCount == 2 && store.image === new)
    }
}
#endif
