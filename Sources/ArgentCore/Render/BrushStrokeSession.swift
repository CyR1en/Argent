import Foundation
import Metal

/// One stroke being painted on one brush component of one mask, from the press to the release: what the painting UI drives.
///
/// The UI feeds it `MaskSpace` points (`FrameGeometry.maskPoint`) as the pointer moves; each `add` lays the dabs the point makes certain
/// on the component's canvas at once, a tick, and keeps a live canvas of the stroke as if it ended there, its last segment included. The
/// overlay reads the mask's coverage from it (`overlay(into:bytesPerRow:)`, only what changed), and the print follows through
/// `printSnapshot()`: the mask with the stroke so far, for the model's throttled flush, whose canvas a render then reads rather than
/// laying the stroke again. `end()` gives the stroke for the recipe, one undo step, and hands its canvas to the field cache, so the bake
/// after it lays nothing; `cancel()` leaves nothing. A stroke in progress never enters the recipe or the cache's kept canvases.
///
/// The live canvas equals a replay of the recipe's strokes with this one as if it ended now, bit for bit, at every tick: a stroke's
/// shape is the largest of its dabs' values, rounded once, and the stroke is laid on the canvas from the same half floats either way.
///
/// With Follow edges (`BrushSettings.followEdges`) each dab's value is weighted by the colour test on the decode the frame view shows
/// (`FollowEdgesModel`), so the overlay and the print follow the colour-tested stroke while it is painted. `end()` then measures it: that
/// shape refined to the picture's edges, kept as the stroke's `MeasuredStroke` (`measurement` holds its raster for the store), and laid on
/// the live canvas in place of the colour-tested one, which then equals a replay of the recipe's strokes with the measured one, bit for bit.
///
/// Not thread-safe: one thread, the UI's, drives it. Its GPU work goes on the cache's queue and is waited for, so what `add` returns is
/// on the canvas.
public final class BrushStrokeSession {
    /// The field the canvas covers: 2048 texels on the picture's long side, as the slice's.
    public let size: MaskFieldSize
    /// The mask as it was when the stroke began, and the brush component painted.
    public let mask: Mask
    public let component: Int
    public let version: String

    private let cache: MaskFieldCache
    private let pipelines: BrushPipelines
    private var sampler: StrokeSampler
    private let profile: BrushDabProfile
    private let committed: [BrushStroke]
    private let base: BrushCanvas
    /// The shape of the dabs made certain so far: the largest dab value at each texel, in half float.
    let shape: MTLTexture
    /// `base` with the stroke laid on it as if it ended now.
    let live: MTLTexture
    /// Where the provisional tail last lay, to be redrawn when it moves.
    private var tailRegion: BrushRegion?
    /// What changed since the overlay last read, from the picture's top.
    private var damage: BrushRegion?
    private var overlayTexture: MTLTexture?
    /// The mask compiled with this component a raster that reads the live canvas: a marker stroke stands in for the one in progress,
    /// so even a brush with no stroke yet compiles to a raster.
    private let overlayProgram: MaskProgram
    private let marker: BrushStroke
    /// The decode's refinement, for a mask that holds a smart selection.
    private let refinement: MaskRefinementSession?
    /// The textures of the program's rasters, this component's the live canvas and the others' from the cache, fetched at first use.
    private var overlayTextures: [MTLTexture]?
    /// Canvases handed to the print, newest last; at most two stay registered.
    private var snapshots: [BrushCanvas] = []
    private var finished = false

    /// What the last tick cost: from `add` called to its canvas written (wall), and the GPU's own time.
    public private(set) var lastTickSeconds: Double = 0
    public private(set) var lastTickGPUSeconds: Double = 0

    /// Follow edges: the colour test's library, the decode's guide frame it reads, the refinement that measures as the stroke ends, and
    /// the slice texel the first dab's colour is sampled at.
    public var followEdges: Bool { sampler.settings.followEdges }
    private let picture: MaskSpace
    private let follow: FollowEdgesPipelines?
    private let guide: MTLTexture?
    private let perDab: Bool
    private var firstSample: SIMD2<Int32>?
    /// Every texel a tick has redrawn, from the picture's top.
    private var touched: BrushRegion?
    /// What a Follow edges stroke measured as it ended: the raster to store before the edit names it, and what it cost.
    public private(set) var measurement: FollowEdgesMeasurement?
    /// The release's measurement and laying, wall time.
    public private(set) var measureSeconds: Double = 0

    /// Begins a stroke on `mask.components[component]`, which must be a brush (with no stroke yet, for a new brush). Its committed
    /// strokes' canvas comes from the cache, laid now if nothing holds it. Refuses a component that is not a brush, settings out of
    /// range, a mask whose other shapes cannot bake, and a mask at its point cap. A mask that holds a smart selection, as Sky with a
    /// Subtract brush, needs `refinement`, the decode the frame view shows refined (`MaskRefiner.session`), for its overlay; without one
    /// it refuses at the press. So does a Follow edges stroke, whose colour test and measurement read that decode, and a brush whose
    /// Follow edges strokes' canvas must be laid reads their shapes through it. `perDab` is `FollowEdgesModel.perDab` but in a measurement.
    public init(cache: MaskFieldCache, picture: MaskSpace, mask: Mask, component: Int, settings: BrushSettings,
                constraint: StrokeSampler.Constraint = .none, version: String = MaskSet.currentVersion,
                refinement: MaskRefinementSession? = nil, perDab: Bool = FollowEdgesModel.perDab) throws {
        guard mask.components.indices.contains(component), case .brush(let paint) = mask.components[component].shape else {
            throw MaskError.invalid("a stroke is painted on a brush component")
        }
        guard MaskSet.supports(version: version) else { throw MaskError.unsupportedVersion(version) }
        sampler = try StrokeSampler(settings: settings, constraint: constraint, pointBudget: MaskSet.maximumBrushPoints - mask.brushPointCount)
        self.size = MaskFieldSize(picture: picture)
        self.mask = mask
        self.component = component
        self.version = version
        self.cache = cache
        committed = paint.strokes
        profile = BrushDabProfile(radius: settings.radius, feather: settings.feather)
        marker = BrushStroke(radius: MaskSpace.brushRadiusRange.lowerBound, points: try PackedPoints.pack([MaskPoint(x: -1, y: -1)]))
        var probe = mask
        probe.components[component].shape = .brush(BrushPaint(frame: paint.frame, strokes: paint.strokes + [marker]))
        overlayProgram = try MaskProgram(probe.coverage)
        if overlayProgram.isRefined {
            guard let refinement, refinement.fieldSize == MaskFieldSize(picture: picture) else { throw MaskCoverageError.unbakedShape("smart") }
        }
        self.refinement = refinement
        self.picture = picture
        self.perDab = perDab
        if settings.followEdges {
            guard let refinement, refinement.fieldSize == size else { throw MaskError.invalid("Follow edges reads the frame's decode, which is not ready") }
            follow = try cache.followLibrary()
            guide = try refinement.guideFrame()
        } else {
            follow = nil
            guide = nil
        }
        pipelines = try cache.brushLibrary()
        base = try cache.canvas(for: BrushCanvasKey(size: size, version: version, strokes: paint.strokes), shapes: refinement?.shapes)
        shape = try BrushCanvas.makeTexture(device: cache.device, size: size, label: "Brush stroke shape")
        live = try BrushCanvas.makeTexture(device: cache.device, size: size, label: "Brush stroke live")
        try run { commandBuffer in
            guard let blit = commandBuffer.makeBlitCommandEncoder() else { throw GPUError.noEncoder }
            blit.copy(from: base.texture, to: live)
            blit.endEncoding()
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
            // The shape starts at 0: a replay with no stroke writes 0 everywhere.
            try BrushReplay.encode([], onto: nil, into: shape, size: size, encoder: encoder, pipelines: pipelines, device: cache.device)
            encoder.endEncoding()
        }
    }

    /// Whether a stroke with `settings` on a brush of `mask` needs `init`'s `refinement`: a Follow edges stroke reads the decode; a
    /// smart selection in the mask is refined for the overlay; and a brush of the mask that holds Follow edges strokes reads their
    /// measured shapes through it, whenever its canvas must be laid. Whether the mask is on does not come into it: a mask turned off
    /// is painted like any other, though no render reads it (`Mask.readsMeasuredStroke`), so its canvas is the likeliest to be gone.
    public static func needsRefinement(mask: Mask, settings: BrushSettings) -> Bool {
        settings.followEdges || mask.components.contains { component in
            switch component.shape {
            case .smart: return true
            case .brush(let paint): return paint.strokes.contains(where: \.followEdges)
            case .linear, .radial: return false
            }
        }
    }

    /// Begins on the GPU's own field cache.
    public convenience init(gpu: GPU, picture: MaskSpace, mask: Mask, component: Int, settings: BrushSettings,
                            constraint: StrokeSampler.Constraint = .none, version: String = MaskSet.currentVersion,
                            refinement: MaskRefinementSession? = nil, perDab: Bool = FollowEdgesModel.perDab) throws {
        try self.init(cache: gpu.maskFields, picture: picture, mask: mask, component: component, settings: settings,
                      constraint: constraint, version: version, refinement: refinement, perDab: perDab)
    }

    deinit {
        for snapshot in snapshots { cache.unregister(live: snapshot) }
    }

    /// The settings the stroke paints with.
    public var settings: BrushSettings { sampler.settings }
    /// Whether the mask's point cap stopped the stroke: past it no point is kept, so the UI should say the brush is full.
    public var isFull: Bool { sampler.isFull }
    /// The stroke as the recipe would keep it if it ended now, or `nil` before the first point.
    public var stroke: BrushStroke? { sampler.stroke }

    /// The mask with `stroke` added to its brush.
    public func mask(with stroke: BrushStroke) -> Mask {
        var mask = self.mask
        guard case .brush(var paint) = mask.components[component].shape else { return mask }
        paint.strokes.append(stroke)
        mask.components[component].shape = .brush(paint)
        return mask
    }

    /// Takes the pointer's next point, the first being the press, and lays what it makes certain. Returns the texels it changed, from the
    /// picture's top, or `nil` when it changed none (a point too near the last, or past the cap).
    @discardableResult
    public func add(_ point: MaskPoint) throws -> BrushRegion? {
        precondition(!finished, "a stroke that ended takes no point")
        let started = Date()
        let fresh = sampler.add(point)
        return try tick(fresh: fresh, tail: sampler.tail, started: started)
    }

    /// The mask with the stroke so far, for the model's throttled flush to the print (at most every 1/30 s, `manual-development.md`'s
    /// flush rule). Its canvas is a copy of the live one, registered with the cache until two newer ones replace it, so a render of a
    /// set holding this mask lays nothing. `nil` before the first point.
    public func printSnapshot() throws -> Mask? {
        precondition(!finished, "a stroke that ended has no snapshot")
        guard let stroke = sampler.stroke else { return nil }
        let key = BrushCanvasKey(size: size, version: version, strokes: committed + [stroke])
        if let newest = snapshots.last, newest.key == key { return mask(with: stroke) }
        // Two stay registered, so a render asked for the one before still finds it. The third's texture is reused only when nothing
        // else holds its canvas: no render is reading it.
        var texture: MTLTexture?
        if snapshots.count >= 2 {
            var oldest = snapshots.removeFirst()
            cache.unregister(live: oldest)
            if isKnownUniquelyReferenced(&oldest) { texture = oldest.texture }
        }
        let target = try texture ?? BrushCanvas.makeTexture(device: cache.device, size: size, label: "Brush stroke snapshot")
        try run { commandBuffer in
            guard let blit = commandBuffer.makeBlitCommandEncoder() else { throw GPUError.noEncoder }
            blit.copy(from: live, to: target)
            blit.endEncoding()
        }
        let canvas = BrushCanvas(key: key, texture: target)
        snapshots.append(canvas)
        cache.register(live: canvas)
        return mask(with: stroke)
    }

    /// Ends the stroke: lays its last dabs, hands its canvas to the field cache, and returns the stroke for the recipe, one undo step
    /// (`mask(with:)` is the mask with it). `nil`, and nothing kept, when the stroke has no point. A Follow edges stroke is measured here
    /// (`FollowEdgesMeasurement`): the stroke returned keeps its `MeasuredStroke`, `measurement` holds the raster it names, which the
    /// caller stores before the edit names it, and the live canvas is laid again from that shape.
    public func end() throws -> BrushStroke? {
        precondition(!finished, "a stroke ends once")
        defer { release() }
        let started = Date()
        guard let (dabs, painted) = sampler.end() else { return nil }
        // The tail the last tick showed is what end lays, so this changes nothing, and leaves the live canvas the stroke's own.
        _ = try tick(fresh: dabs, tail: [], started: started)
        var stroke = painted
        if followEdges, let guide, let refinement {
            let measuring = Date()
            // A stroke whose dabs all missed the slice has no texel: it measures one corner, which is 0.
            let region = touched ?? BrushRegion(x: 0, y: 0, width: 1, height: 1)
            let measured = try FollowEdgesMeasurement.measure(shape: shape, region: region, guideFrame: guide, picture: picture,
                                                              refiner: refinement.refiner)
            stroke.measured = measured.measured
            measurement = measured
            // The measured shape in place of the colour-tested one, over every texel either reached, from the same base: what a replay's
            // run of this one measured stroke lays there (`FollowEdgesReplay`), and outside it the live canvas is the base already.
            let inputs = try FollowEdgesReplay.inputs([stroke], size: size, shapes: MaskSeeds([measured.raster]))
            guard case .measured(let table, let bytes)? = inputs.segments.first else { preconditionFailure("one measured stroke") }
            let area = region.union(FollowEdgesReplay.region(of: measured.measured, size: size))
            try run { commandBuffer in
                guard let encoder = commandBuffer.makeComputeCommandEncoder(), let follow else { throw GPUError.noEncoder }
                try FollowEdgesReplay.lay(table, shapes: bytes, onto: base.texture, into: live, size: size, region: area, encoder: encoder,
                                          follow: follow, placeholder: pipelines.placeholder, device: cache.device)
                encoder.endEncoding()
            }
            damage = area.union(damage)
            measureSeconds = Date().timeIntervalSince(measuring)
        }
        cache.keep(BrushCanvas(key: BrushCanvasKey(size: size, version: version, strokes: committed + [stroke]), texture: live))
        return stroke
    }

    /// Ends the stroke with nothing kept: Esc, or the frame changed under it.
    public func cancel() {
        guard !finished else { return }
        release()
    }

    private func release() {
        finished = true
        for snapshot in snapshots { cache.unregister(live: snapshot) }
        snapshots = []
    }

    // MARK: the overlay

    /// The mask's coverage with the stroke as it stands, 0 to 255, top row first, `size.width` by `size.height` texels: what the print
    /// reads at the slice's texels. Writes into `bytes` the region that changed since the last call, everything on the first, and returns
    /// it, or `nil` when nothing changed. An overlay bitmap of the canvas's size takes it as is.
    public func overlay(into bytes: UnsafeMutableRawPointer, bytesPerRow: Int) throws -> BrushRegion? {
        let region: BrushRegion
        if overlayTexture == nil {
            region = BrushRegion(x: 0, y: 0, width: size.width, height: size.height)
        } else if let damage {
            region = damage
        } else {
            return nil
        }
        damage = nil
        let texture = try overlayTexture ?? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: size.width, height: size.height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            guard let made = cache.device.makeTexture(descriptor: descriptor) else { throw GPUError.textureAllocation }
            made.label = "Brush overlay"
            overlayTexture = made
            return made
        }()
        let (program, textures) = try overlayInputs()
        var params = MaskOverlayParams(texelToPoint: size.texelToPoint, fieldHeight: UInt32(size.height), count: UInt32(program.components.count),
                                       originX: UInt32(region.x), originY: UInt32(region.y), width: UInt32(size.width), height: UInt32(size.height))
        try run { commandBuffer in
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
            encoder.setComputePipelineState(pipelines.overlay)
            encoder.setTexture(texture, index: 0)
            pipelines.bindRasters(textures, to: encoder)
            encoder.setBytes(&params, length: MemoryLayout<MaskOverlayParams>.stride, index: 0)
            program.components.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
            program.rasterOf.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 2) }
            encoder.dispatchPixels(pipelines.overlay, width: region.width, height: region.height)
            encoder.endEncoding()
        }
        texture.getBytes(bytes.advanced(by: region.y * bytesPerRow + region.x), bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(region.x, region.y, region.width, region.height), mipmapLevel: 0)
        return region
    }

    private func overlayInputs() throws -> (MaskProgram, [MTLTexture]) {
        if let overlayTextures { return (overlayProgram, overlayTextures) }
        let mine = MaskRasterSource.brush(committed + [marker])
        let textures = try overlayProgram.rasters.map { source -> MTLTexture in
            guard source != mine else { return live }
            switch source {
            case .brush(let strokes):
                return try cache.canvas(for: BrushCanvasKey(size: size, version: version, strokes: strokes), shapes: refinement?.shapes).texture
            case .refined(let selection):
                guard let refinement else { throw MaskCoverageError.unbakedShape("smart") }
                return try refinement.field(for: selection)
            }
        }
        overlayTextures = textures
        return (overlayProgram, textures)
    }

    // MARK: the tick

    /// Lays `fresh` on the stroke's shape and redraws the live canvas over every texel `fresh`, `tail` or the last tail touch.
    private func tick(fresh: [BrushDab], tail: [BrushDab], started: Date) throws -> BrushRegion? {
        let newTail = BrushRegion.touched(by: tail, radius: profile.outer, size: size)
        let reached = [BrushRegion.touched(by: fresh, radius: profile.outer, size: size), newTail, tailRegion].compactMap { $0 }
        guard let first = reached.first else { return nil }
        let changed = reached.dropFirst().reduce(first) { $0.union($1) }
        tailRegion = newTail
        var params = BrushCanvasParams(size: size)
        params.originX = UInt32(changed.x)
        params.originY = UInt32(size.height - changed.y - changed.height)
        params.tile = UInt32(BrushReplay.tile)
        params.freshCount = UInt32(fresh.count)
        params.tailCount = UInt32(tail.count)
        params.flow = sampler.settings.flow
        params.erase = sampler.settings.erase ? 1 : 0
        let freshBins = BrushReplay.bin(fresh.map { BrushRegion.touched(by: $0, radius: profile.outer, size: size) }, size: size)
        let tailBins = BrushReplay.bin(tail.map { BrushRegion.touched(by: $0, radius: profile.outer, size: size) }, size: size)
        params.tilesX = UInt32(freshBins.tilesX)
        let device = cache.device
        // Follow edges: each dab's colour first, sampled about the texel its centre lies in (or the first dab's, for every dab).
        var colours: MTLBuffer?
        if follow != nil {
            if firstSample == nil, let first = fresh.first ?? tail.first { firstSample = FollowEdges.sampleTexel(first, size: size) }
            // One colour more than the dabs: the tail's colours are bound where the fresh ones end, and with no tail (every release)
            // that offset must still lie inside the buffer, which Metal's validation checks though the kernel reads nothing there.
            guard let made = device.makeBuffer(length: (fresh.count + tail.count + 1) * MemoryLayout<SIMD4<Float>>.stride,
                                               options: .storageModeShared) else { throw GPUError.textureAllocation }
            colours = made
        }
        let gpuSeconds = try run { commandBuffer in
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
            if let follow, let guide, let colours {
                let samples = (fresh + tail).map { perDab ? FollowEdges.sampleTexel($0, size: size) : firstSample! }
                var followParams = FollowParamsGPU(size: size, count: samples.count)
                if !samples.isEmpty {
                    encoder.setComputePipelineState(follow.colours)
                    encoder.setTexture(guide, index: 0)
                    encoder.setBytes(&followParams, length: MemoryLayout<FollowParamsGPU>.stride, index: 0)
                    try BrushReplay.bind(samples, index: 1, encoder: encoder, device: device)
                    encoder.setBuffer(colours, offset: 0, index: 2)
                    let width = min(samples.count, follow.colours.threadExecutionWidth)
                    encoder.dispatchThreads(MTLSize(width: samples.count, height: 1, depth: 1),
                                            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
                }
                encoder.setComputePipelineState(follow.tick)
                encoder.setTexture(guide, index: 3)
                encoder.setBytes(&followParams, length: MemoryLayout<FollowParamsGPU>.stride, index: 7)
                encoder.setBuffer(colours, offset: 0, index: 8)
                encoder.setBuffer(colours, offset: fresh.count * MemoryLayout<SIMD4<Float>>.stride, index: 9)
            } else {
                encoder.setComputePipelineState(pipelines.tick)
            }
            encoder.setTexture(base.texture, index: 0)
            encoder.setTexture(shape, index: 1)
            encoder.setTexture(live, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<BrushCanvasParams>.stride, index: 0)
            try BrushReplay.bind(gpu(fresh), index: 1, encoder: encoder, device: device)
            try BrushReplay.bind(gpu(tail), index: 2, encoder: encoder, device: device)
            try BrushReplay.bind(freshBins.offsets, index: 3, encoder: encoder, device: device)
            try BrushReplay.bind(freshBins.list, index: 4, encoder: encoder, device: device)
            try BrushReplay.bind(tailBins.offsets, index: 5, encoder: encoder, device: device)
            try BrushReplay.bind(tailBins.list, index: 6, encoder: encoder, device: device)
            encoder.dispatchPixels(follow?.tick ?? pipelines.tick, width: changed.width, height: changed.height)
            encoder.endEncoding()
        }
        damage = changed.union(damage)
        touched = changed.union(touched)
        lastTickGPUSeconds = gpuSeconds
        lastTickSeconds = Date().timeIntervalSince(started)
        return changed
    }

    private func gpu(_ dabs: [BrushDab]) -> [BrushDabGPU] {
        dabs.map { BrushDabGPU(center: SIMD2($0.x, $0.y), outer: profile.outer, inner: profile.inner, stroke: 0) }
    }

    /// Encodes with `body`, commits on the cache's queue and waits; returns the GPU's time.
    @discardableResult
    private func run(_ body: (MTLCommandBuffer) throws -> Void) throws -> Double {
        guard let commandBuffer = cache.queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        try body(commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
        return commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
    }
}
