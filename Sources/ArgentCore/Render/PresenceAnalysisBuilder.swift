import Foundation
import Metal

/// Makes a decode's analysis parts on the GPU, for `PresenceAnalyses`. Each is made from the frame's untouched light before Exposure,
/// at the size its constants give against the full-size picture (`LinearFrame.maskPicture`), so the frame view's and the develop's agree.
///
/// | Part | Made by | Size | Format |
/// | --- | --- | --- | --- |
/// | Clarity, both sides | one guide pass, then `ToneBaseField`'s boxes with `clarity.positiveField` and `.negativeField` | 1024 long, or the decode's | rg32Float, two |
/// | Texture's band | `ToneBaseField`'s math with `texture.field(decodeLongSide:fullLongSide:)`, built in bands of rows | half the full-size frame, or the decode's | rg32Float |
/// | Dehaze | the frame area-averaged in linear light, the minimum channel, the airlight, the eroded dark channel, `t_raw`, a guided filter under log2 luminance | 1024 long, or the decode's | rg32Float, and three floats |
///
/// Working sets are held to what `PresenceAnalyses.developBytes` counts: `textureWorkingSetBudget` for the band, four field-sized
/// textures for Clarity, `hazeWorkingBytesPerTexel` for Dehaze. Each build runs in a command buffer of its own and waits for it; Dehaze's
/// waits once more in the middle, for the airlight, which the CPU takes from the field's light before the transmission can be made.
final class PresenceAnalysisBuilder: PresenceAnalysisBuilding, @unchecked Sendable {
    /// `fit_dehaze.py`'s floors, kept in its code: the luminance under the guide's log, and each channel of the airlight.
    static let hazeGuideFloor: Float = 1e-6
    static let airlightFloor: Double = 1e-4

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let lock = NSLock()
    private var compiled: Kernels?
    private var last: Build?

    init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
    }

    /// How one part was built, for the measure suites and the tests.
    struct Build: Equatable {
        var bands = 1
        var bandRows = 0
        /// The working textures' and buffers' bytes, as Metal allocated them (`allocatedSize`), all held until the build's last
        /// command buffer has run.
        var workingBytes = 0
        var keptBytes = 0
        var gpuSeconds = 0.0
        /// Dehaze's: the CPU's wait for the field's light and its eroded least channel, from encoding to completion, and the airlight's
        /// quantile and median after it.
        var airlightWaitSeconds = 0.0
        var airlightSeconds = 0.0
    }

    var lastBuild: Build? { lock.withLock { last } }

    private func record(_ build: Build) { lock.withLock { last = build } }

    /// The analysis's kernels, in a library of their own after the tone base's, whose kernels and helpers they use: compiled the first
    /// time a frame has Texture, Clarity or Dehaze set, so a roll without them compiles nothing.
    private struct Kernels {
        let toneBase: ToneBaseField.Kernels
        let bandGuide: MTLComputePipelineState
        let bandColumns: MTLComputePipelineState
        let hazeArea: MTLComputePipelineState
        let hazeDarkRows: MTLComputePipelineState
        let hazeErodeColumns: MTLComputePipelineState
        let hazeTerms: MTLComputePipelineState
        let hazeBox: MTLComputePipelineState

        init(device: MTLDevice) throws {
            let library = try device.makeLibrary(source: [ShaderSource.toneBase, ShaderSource.presenceAnalysis].joined(separator: "\n"),
                                                 options: nil)
            func pipeline(_ name: String) throws -> MTLComputePipelineState {
                guard let function = library.makeFunction(name: name) else { throw GPUError.shaderFunctionMissing(name) }
                return try device.makeComputePipelineState(function: function)
            }
            toneBase = try ToneBaseField.Kernels(library: library, device: device)
            bandGuide = try pipeline("presence_band_guide")
            bandColumns = try pipeline("presence_band_columns")
            hazeArea = try pipeline("presence_haze_area")
            hazeDarkRows = try pipeline("presence_haze_dark_rows")
            hazeErodeColumns = try pipeline("presence_haze_erode_columns")
            hazeTerms = try pipeline("presence_haze_terms")
            hazeBox = try pipeline("presence_haze_box")
        }
    }

    private func kernels() throws -> Kernels {
        try lock.withLock {
            if let compiled { return compiled }
            let made = try Kernels(device: device)
            compiled = made
            return made
        }
    }

    // MARK: Clarity

    func clarity(of frame: LinearFrame, constants: PresenceConstants) throws -> PresenceAnalysis.ClarityFields {
        let made = try kernels()
        let positive = constants.clarity.positiveField, negative = constants.clarity.negativeField
        let size = positive.fieldSize(width: frame.width, height: frame.height)
        precondition(negative.fieldSize(width: frame.width, height: frame.height) == size, "Clarity's two fields share one guide")
        let guide = try texture(size.width, size.height), scratch = try texture(size.width, size.height)
        let fields = PresenceAnalysis.ClarityFields(positive: try texture(size.width, size.height, label: "Presence Clarity, positive"),
                                                    negative: try texture(size.width, size.height, label: "Presence Clarity, negative"))
        let seconds = try run { encoder in
            made.toneBase.encodeGuide(encoder, frame: frame.texture, into: guide)
            made.toneBase.encodeBoxes(encoder, parameters: positive, guide: guide, scratch: scratch, output: fields.positive)
            made.toneBase.encodeBoxes(encoder, parameters: negative, guide: guide, scratch: scratch, output: fields.negative)
        }
        record(Build(workingBytes: Self.bytes(guide, scratch),
                     keptBytes: Self.bytes(fields.positive, fields.negative), gpuSeconds: seconds))
        return fields
    }

    // MARK: Texture

    func texture(of frame: LinearFrame, constants: PresenceConstants) throws -> PresenceAnalysis.TextureBand {
        try texture(of: frame, constants: constants, bandRows: nil)
    }

    /// Texture's band, `bandRows` field rows at a time (rounded up to whole segments), or as many as keep its two working textures
    /// under `PresenceAnalyses.textureWorkingSetBudget`. A band of the field's height is the unbanded build.
    func texture(of frame: LinearFrame, constants: PresenceConstants, bandRows requested: Int?) throws -> PresenceAnalysis.TextureBand {
        let made = try kernels()
        let picture = try frame.maskPicture
        let field = constants.texture.field(decodeLongSide: max(frame.width, frame.height),
                                            fullLongSide: max(picture.width, picture.height))
        let size = field.fieldSize(width: frame.width, height: frame.height)
        let params = ToneBaseField.Params(field, fieldLong: max(size.width, size.height))
        let segment = Int(params.segment)
        let rows = requested.map { max(1, ($0 + segment - 1) / segment) * segment }
            ?? bandRows(fieldWidth: size.width, fieldHeight: size.height, params: params, budget: PresenceAnalyses.textureWorkingSetBudget)
        let bands = RowBands(fieldHeight: size.height, params: params, rows: rows)
        let output = try texture(size.width, size.height, label: "Presence Texture band")
        let first = try texture(size.width, bands.textureRows), second = try texture(size.width, bands.textureRows)
        func span(held: Int, outOrigin: Int, rows: Range<Int>) -> Band {
            Band(fieldWidth: UInt32(size.width), fieldHeight: UInt32(size.height), inOrigin: UInt32(held), outOrigin: UInt32(outOrigin),
                 first: UInt32(rows.lowerBound), stop: UInt32(rows.upperBound))
        }
        func columns(_ encoder: MTLComputeCommandEncoder, _ stage: UInt32, _ input: MTLTexture, _ output: MTLTexture, _ span: Band) {
            var params = params, pass = ToneBaseField.Pass(columns: 1, stage: stage), span = span
            encoder.setComputePipelineState(made.bandColumns)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<ToneBaseField.Params>.stride, index: 0)
            encoder.setBytes(&pass, length: MemoryLayout<ToneBaseField.Pass>.stride, index: 1)
            encoder.setBytes(&span, length: MemoryLayout<Band>.stride, index: 2)
            encoder.dispatchPixels(made.bandColumns, width: size.width, height: Int(span.stop - span.first + params.segment - 1) / segment)
        }
        let seconds = try run { encoder in
            for band in bands.all {
                var guide = span(held: 0, outOrigin: band.held.lowerBound, rows: 0..<0)
                encoder.setComputePipelineState(made.bandGuide)
                encoder.setTexture(frame.texture, index: 0)
                encoder.setTexture(first, index: 1)
                encoder.setBytes(&guide, length: MemoryLayout<Band>.stride, index: 0)
                encoder.dispatchPixels(made.bandGuide, width: size.width, height: band.held.count)
                made.toneBase.encodeBox(encoder, params, ToneBaseField.Pass(columns: 0, stage: 0), input: first, output: second)
                columns(encoder, 0, second, first, span(held: band.held.lowerBound, outOrigin: band.held.lowerBound, rows: band.coefficients))
                made.toneBase.encodeBox(encoder, params, ToneBaseField.Pass(columns: 0, stage: 1), input: first, output: second)
                columns(encoder, 1, second, output, span(held: band.held.lowerBound, outOrigin: 0, rows: band.rows))
            }
        }
        record(Build(bands: bands.all.count, bandRows: rows, workingBytes: Self.bytes(first, second), keptBytes: output.allocatedSize,
                     gpuSeconds: seconds))
        return PresenceAnalysis.TextureBand(coefficients: output, field: field)
    }

    /// Mirrors `PresenceBand`.
    private struct Band {
        var fieldWidth: UInt32
        var fieldHeight: UInt32
        var inOrigin: UInt32
        var outOrigin: UInt32
        var first: UInt32
        var stop: UInt32
    }

    /// A field built a band of rows at a time. Each band's column passes start from a segment's start in field rows, as the whole
    /// field's do, so the rows a band writes are the whole field's to the bit; its working textures hold every row those passes read.
    struct RowBands {
        let fieldHeight: Int
        let params: ToneBaseField.Params
        /// The field rows a band writes, a whole number of segments.
        let rows: Int

        struct Band {
            /// The field rows the band writes.
            let rows: Range<Int>
            /// The rows the guide's column pass writes, from the segment holding the first row the coefficients' boxes read.
            let coefficients: Range<Int>
            /// The rows the working textures hold, from their first: every row the guide's column pass reads.
            let held: Range<Int>
        }

        /// The rows a band's working textures hold beyond the rows it writes: before them, the segment back to where the guide's column
        /// pass starts and the guide's radius before that; after them, the coefficients' radius and the guide's.
        static func margin(_ params: ToneBaseField.Params) -> Int {
            Int(params.segment) + 2 * Int(params.radius) + Int(params.coefficientRadius)
        }

        var textureRows: Int { min(fieldHeight, rows + Self.margin(params)) }

        var all: [Band] {
            let segment = Int(params.segment), radius = Int(params.radius), coefficientRadius = Int(params.coefficientRadius)
            return stride(from: 0, to: fieldHeight, by: rows).map { start in
                let end = min(fieldHeight, start + rows)
                let first = max(0, start - coefficientRadius) / segment * segment
                let stop = min(fieldHeight, end + coefficientRadius)
                return Band(rows: start..<end, coefficients: first..<stop,
                            held: max(0, first - radius)..<min(fieldHeight, stop + radius))
            }
        }
    }

    /// The most field rows a band may write, a whole number of segments and at least one, with its two working textures, as Metal
    /// sizes them, under `budget`.
    private func bandRows(fieldWidth: Int, fieldHeight: Int, params: ToneBaseField.Params, budget: Int) -> Int {
        let segment = Int(params.segment), margin = RowBands.margin(params)
        func bytes(_ rows: Int) -> Int {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: fieldWidth,
                                                                      height: min(fieldHeight, rows + margin), mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            return 2 * device.heapTextureSizeAndAlign(descriptor: descriptor).size
        }
        var rows = max(segment, (budget / (2 * fieldWidth * 8) - margin) / segment * segment)
        while rows > segment && bytes(rows) > budget { rows -= segment }
        return rows
    }

    // MARK: Dehaze

    func haze(of frame: LinearFrame, constants: PresenceConstants) throws -> PresenceAnalysis.HazeEstimate {
        try hazeField(of: frame, constants: constants).estimate
    }

    /// Mirrors `PresenceHaze`.
    private struct Haze {
        var airlight: SIMD4<Float>
        var luma: SIMD4<Float>
        var width: UInt32
        var height: UInt32
        var radius: Int32
        var omega: Float
        var guideFloor: Float
    }

    /// Mirrors `PresenceHazeBox`.
    private struct HazeBox {
        var radius: Int32
        var epsilon: Float
        var columns: UInt32
    }

    /// Dehaze's estimate, and the eroded normalised dark channel it came from, row by row in a buffer the CPU reads (for the tests).
    func hazeField(of frame: LinearFrame, constants: PresenceConstants) throws
        -> (estimate: PresenceAnalysis.HazeEstimate, dark: MTLBuffer) {
        let made = try kernels()
        let dehaze = constants.dehaze
        let size = dehaze.guide.fieldSize(width: frame.width, height: frame.height)
        let count = size.width * size.height, long = max(size.width, size.height)
        let light = try buffer(count * MemoryLayout<SIMD4<Float>>.stride)
        let least = try buffer(count * MemoryLayout<Float>.stride), dark = try buffer(count * MemoryLayout<Float>.stride)
        var haze = Haze(airlight: SIMD4(repeating: 1), luma: SIMD4(Rec2020.luma, 0), width: UInt32(size.width),
                        height: UInt32(size.height), radius: Self.radius(dehaze.airlightRadius, long), omega: dehaze.omega,
                        guideFloor: Self.hazeGuideFloor)
        func eroded(_ encoder: MTLComputeCommandEncoder) {
            dispatch(encoder, made.hazeDarkRows, buffers: [light, least], &haze, width: size.width, height: size.height)
            dispatch(encoder, made.hazeErodeColumns, buffers: [least, dark], &haze, width: size.width, height: size.height)
        }

        let waited = ContinuousClock.now
        let fieldSeconds = try run { encoder in
            encoder.setTexture(frame.texture, index: 0)
            dispatch(encoder, made.hazeArea, buffers: [light], &haze, width: size.width, height: size.height)
            eroded(encoder)
        }
        let quantiled = ContinuousClock.now
        let colours = light.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let minima = dark.contents().bindMemory(to: Float.self, capacity: count)
        // The filter's pass writes the least channel again, so until then its buffer can hold the pixels the airlight chooses, which on
        // a field of one colour are all of them, in memory the build already counts.
        let chosen = UnsafeMutableBufferPointer(start: least.contents().bindMemory(to: UInt32.self, capacity: count), count: count)
        let airlight = Self.airlight(count: count, dark: { Double(minima[$0]) },
                                     colour: { SIMD3<Double>(SIMD3<Float>(colours[$0].x, colours[$0].y, colours[$0].z)) },
                                     chosen: chosen, constants: dehaze)
        let done = ContinuousClock.now

        haze.airlight = SIMD4(SIMD3<Float>(airlight), 1)
        haze.radius = Self.radius(dehaze.darkRadius, long)
        let params = ToneBaseField.Params(dehaze.guide, fieldLong: long)
        let terms = try texture(size.width, size.height), scratch = try texture(size.width, size.height)
        let moments = try texture(size.width, size.height, format: .rgba32Float)
        let transmission = try texture(size.width, size.height, label: "Presence Dehaze transmission")
        let filterSeconds = try run { encoder in
            eroded(encoder)
            encoder.setTexture(terms, index: 0)
            dispatch(encoder, made.hazeTerms, buffers: [light, dark], &haze, width: size.width, height: size.height)
            for (columns, input, output) in [(UInt32(0), terms, moments), (1, moments, terms)] {
                var box = HazeBox(radius: Int32(params.radius), epsilon: params.epsilon, columns: columns)
                encoder.setComputePipelineState(made.hazeBox)
                encoder.setTexture(input, index: 0)
                encoder.setTexture(output, index: 1)
                encoder.setBytes(&box, length: MemoryLayout<HazeBox>.stride, index: 0)
                encoder.dispatchPixels(made.hazeBox, width: size.width, height: size.height)
            }
            made.toneBase.encodeBox(encoder, params, ToneBaseField.Pass(columns: 0, stage: 1), input: terms, output: scratch)
            made.toneBase.encodeBox(encoder, params, ToneBaseField.Pass(columns: 1, stage: 1), input: scratch, output: transmission)
        }
        record(Build(workingBytes: Self.bytes(light, least, dark, terms, scratch, moments),
                     keptBytes: transmission.allocatedSize, gpuSeconds: fieldSeconds + filterSeconds,
                     airlightWaitSeconds: Self.seconds(quantiled - waited), airlightSeconds: Self.seconds(done - quantiled)))
        return (PresenceAnalysis.HazeEstimate(transmission: transmission, airlight: SIMD3<Float>(airlight)), dark)
    }

    /// A radius given as a share of the field's long side, in field pixels: `fit_dehaze.py`'s `max(0, rounded(share n))`.
    static func radius(_ share: Float, _ fieldLong: Int) -> Int32 { Int32(max(0, (share * Float(fieldLong)).rounded())) }

    /// The airlight, as `fit_dehaze.py`'s `Field` takes it from the field's light and its eroded least channel: the median colour of the
    /// pixels whose channel is at least its `airlightQuantile` quantile, keeping the brightest `1 - airlightBrightShare` of those when
    /// the share is above 0, each channel at least `airlightFloor`.
    ///
    /// The pixels chosen are kept as indices in `chosen`, which has room for every pixel of the field, and their medians and lightness
    /// quantile are selected in place, so what the airlight allocates does not grow with how many it chooses: only the field's quantile,
    /// its top `1 - airlightQuantile` of `count` values.
    static func airlight(count: Int, dark: (Int) -> Double, colour: (Int) -> SIMD3<Double>, chosen: UnsafeMutableBufferPointer<UInt32>,
                         constants: PresenceConstants.Dehaze) -> SIMD3<Double> {
        precondition(chosen.count >= count, "the airlight needs room for every pixel of the field")
        let threshold = quantile(count: count, Double(constants.airlightQuantile), dark)
        var taken = 0
        for pixel in 0..<count where dark(pixel) >= threshold {
            chosen[taken] = UInt32(pixel)
            taken += 1
        }
        if constants.airlightBrightShare > 0 {
            let luma = SIMD3<Double>(Rec2020.luma)
            func lightness(_ pixel: UInt32) -> Double { (colour(Int(pixel)) * luma).sum() }
            let bright = quantile(of: UnsafeMutableBufferPointer(rebasing: chosen[..<taken]), Double(constants.airlightBrightShare),
                                  by: lightness)
            var kept = 0
            for index in 0..<taken where lightness(chosen[index]) >= bright {
                chosen[kept] = chosen[index]
                kept += 1
            }
            taken = kept
        }
        let pixels = UnsafeMutableBufferPointer(rebasing: chosen[..<taken])
        func median(_ channel: Int) -> Double {
            func value(_ pixel: UInt32) -> Double { colour(Int(pixel))[channel] }
            let middle = taken / 2, upper = select(middle, of: pixels, by: value)
            return taken % 2 == 1 ? upper : (pixels[..<middle].reduce(-Double.infinity) { max($0, value($1)) } + upper) / 2
        }
        return pointwiseMax(SIMD3(median(0), median(1), median(2)), SIMD3(repeating: airlightFloor))
    }

    /// NumPy's `quantile(values, q)` by its default linear method, from the largest `count - floor(h)` values alone, `h = q (count - 1)`,
    /// kept in a heap as they pass: the airlight's reads the top 0.1 % of the field.
    static func quantile(count: Int, _ q: Double, _ value: (Int) -> Double) -> Double {
        linear(count: count, q) { below in
            var largest = Largest(capacity: count - below)
            for i in 0..<count { largest.offer(value(i)) }
            let top = largest.values.sorted()
            return (top[0], top.count > 1 ? top[1] : top[0])
        }
    }

    /// The same quantile of the keys of `pixels`, its two values selected in place.
    static func quantile(of pixels: UnsafeMutableBufferPointer<UInt32>, _ q: Double, by key: (UInt32) -> Double) -> Double {
        linear(count: pixels.count, q) { below in
            let low = select(below, of: pixels, by: key), above = pixels[(below + 1)...]
            return (low, above.isEmpty ? low : above.reduce(Double.infinity) { min($0, key($1)) })
        }
    }

    /// NumPy's linear method at `h = q (count - 1)`, between the `floor(h)`th smallest value and the next, which `neighbours` gives
    /// from `floor(h)`.
    private static func linear(count: Int, _ q: Double, neighbours: (Int) -> (low: Double, high: Double)) -> Double {
        let h = q * Double(count - 1), below = Int(h.rounded(.down)), t = h - Double(below)
        let (low, high) = neighbours(below)
        let span = high - low
        // NumPy's lerp, which takes the far end when t is past a half.
        return t >= 0.5 ? high - span * (1 - t) : low + span * t
    }

    /// Moves the pixel whose key is the `k`th smallest (from 0) to `k`, those with no larger keys before it and those with no smaller
    /// after, and returns its key. A quickselect whose three-way partition ends at once on a run of equal keys, as a clipped sky's are.
    static func select(_ k: Int, of pixels: UnsafeMutableBufferPointer<UInt32>, by key: (UInt32) -> Double) -> Double {
        var lower = 0, upper = pixels.count
        // Pivots drawn from a fixed pseudo-random sequence, so keys already in order, as a gradient's rows are, do not make it quadratic,
        // and a field takes the same steps every time.
        var sequence: UInt64 = 0x9E37_79B9_7F4A_7C15
        while true {
            sequence = sequence &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let pivot = key(pixels[lower + Int(sequence >> 33) % (upper - lower)])
            var less = lower, index = lower, more = upper
            while index < more {
                let value = key(pixels[index])
                if value < pivot {
                    pixels.swapAt(less, index)
                    less += 1
                    index += 1
                } else if value > pivot {
                    more -= 1
                    pixels.swapAt(index, more)
                } else {
                    index += 1
                }
            }
            if k < less { upper = less } else if k >= more { lower = more } else { return pivot }
        }
    }

    /// The `capacity` largest values offered, in a heap with the least of them on top.
    struct Largest {
        let capacity: Int
        private(set) var values: [Double] = []

        init(capacity: Int) {
            self.capacity = capacity
            values.reserveCapacity(capacity)
        }

        mutating func offer(_ value: Double) {
            if values.count < capacity {
                values.append(value)
                var child = values.count - 1
                while child > 0, values[(child - 1) / 2] > values[child] {
                    values.swapAt(child, (child - 1) / 2)
                    child = (child - 1) / 2
                }
            } else if value > values[0] {
                values[0] = value
                var parent = 0
                while true {
                    let left = 2 * parent + 1, right = left + 1
                    var least = parent
                    if left < values.count, values[left] < values[least] { least = left }
                    if right < values.count, values[right] < values[least] { least = right }
                    if least == parent { break }
                    values.swapAt(parent, least)
                    parent = least
                }
            }
        }
    }

    /// Dehaze's estimate on the CPU, in double sums as `ToneBaseField.reference`: the tests' reference, and the airlight's.
    static func hazeReference(pixels: [SIMD3<Float>], width: Int, height: Int, constants: PresenceConstants) throws
        -> (width: Int, height: Int, coefficients: [SIMD2<Float>], airlight: SIMD3<Float>) {
        let steps = hazeSteps(pixels: pixels, width: width, height: height, constants: constants.dehaze)
        return (steps.width, steps.height, steps.coefficients.map { SIMD2<Float>($0) }, SIMD3<Float>(steps.airlight))
    }

    /// `fit_dehaze.py`'s `Field`, step for step, with what each step made.
    struct HazeSteps {
        let width: Int
        let height: Int
        let airlight: SIMD3<Double>
        /// The normalised dark channel, eroded.
        let dark: [Double]
        let coefficients: [SIMD2<Double>]
    }

    static func hazeSteps(pixels: [SIMD3<Float>], width: Int, height: Int, constants: PresenceConstants.Dehaze) -> HazeSteps {
        precondition(pixels.count == width * height, "pixels must be width by height")
        let (fw, fh) = constants.guide.fieldSize(width: width, height: height)
        let count = fw * fh, long = max(fw, fh)
        let light = areaAverage(pixels, width: width, height: height, to: fw, fh).map { $0.clamped(lowerBound: SIMD3(repeating: -65504),
                                                                                                         upperBound: SIMD3(repeating: 65504)) }
        let least = erode(light.map { $0.min() }, width: fw, height: fh, radius: Int(radius(constants.airlightRadius, long)))
        var chosen = [UInt32](repeating: 0, count: count)
        let airlight = chosen.withUnsafeMutableBufferPointer {
            Self.airlight(count: count, dark: { least[$0] }, colour: { light[$0] }, chosen: $0, constants: constants)
        }
        let dark = erode(light.map { ($0 / airlight).min() }, width: fw, height: fh, radius: Int(radius(constants.darkRadius, long)))
        let t = dark.map { 1 - Double(constants.omega) * $0 }
        let luma = SIMD3<Double>(Rec2020.luma)
        let g = light.map { log2(max(($0 * luma).sum(), Double(hazeGuideFloor))) }
        let r = constants.guide.radius(fieldLong: long), coefficientRadius = constants.guide.coefficientRadius(fieldLong: long)
        func box(_ values: [Double], _ radius: Int) -> [Double] { ToneBaseField.box(values, width: fw, height: fh, radius: radius) }
        let meanG = box(g, r), meanT = box(t, r), squares = box(g.map { $0 * $0 }, r), products = box(zip(g, t).map(*), r)
        let epsilon = Double(constants.guide.epsilon)
        var a = [Double](repeating: 0, count: count), b = a
        for i in 0..<count {
            let variance = max(squares[i] - meanG[i] * meanG[i], 0)
            a[i] = (products[i] - meanG[i] * meanT[i]) / (variance + epsilon)
            b[i] = meanT[i] - a[i] * meanG[i]
        }
        let boxedA = box(a, coefficientRadius), boxedB = box(b, coefficientRadius)
        return HazeSteps(width: fw, height: fh, airlight: airlight, dark: dark,
                         coefficients: (0..<count).map { SIMD2(boxedA[$0], boxedB[$0]) })
    }

    /// `pixels` area-averaged into `ow` by `oh` cells as `presence_haze_area` does it, at whole-number positions in units of
    /// 1 / (frame side * field side), so every weight is exact.
    static func areaAverage(_ pixels: [SIMD3<Float>], width: Int, height: Int, to ow: Int, _ oh: Int) -> [SIMD3<Double>] {
        var out = [SIMD3<Double>](repeating: .zero, count: ow * oh)
        for oy in 0..<oh {
            let y0 = oy * height, y1 = y0 + height
            for ox in 0..<ow {
                let x0 = ox * width, x1 = x0 + width
                var sum = SIMD3<Double>.zero
                for y in (y0 / oh)..<min((y1 + oh - 1) / oh, height) {
                    let wy = Double(min((y + 1) * oh, y1) - max(y * oh, y0))
                    var row = SIMD3<Double>.zero
                    for x in (x0 / ow)..<min((x1 + ow - 1) / ow, width) {
                        row += Double(min((x + 1) * ow, x1) - max(x * ow, x0)) * SIMD3<Double>(pixels[y * width + x])
                    }
                    sum += wy * row
                }
                out[oy * ow + ox] = sum / (Double(width) * Double(height))
            }
        }
        return out
    }

    /// A window past the field repeats its edge pixel, as `fit_dehaze.py`'s `erode`.
    static func erode(_ values: [Double], width: Int, height: Int, radius: Int) -> [Double] {
        func least(_ at: (Int) -> Double) -> Double {
            var least = at(-radius)
            for d in -radius...radius { least = min(least, at(d)) }
            return least
        }
        var across = values
        for y in 0..<height {
            for x in 0..<width { across[y * width + x] = least { values[y * width + min(max(x + $0, 0), width - 1)] } }
        }
        var out = across
        for y in 0..<height {
            for x in 0..<width { out[y * width + x] = least { across[min(max(y + $0, 0), height - 1) * width + x] } }
        }
        return out
    }

    // MARK: Running

    private func texture(_ width: Int, _ height: Int, format: MTLPixelFormat = .rg32Float, label: String? = nil) throws -> MTLTexture {
        let made = try GPU.makeTexture(device: device, width: width, height: height, usage: [.shaderRead, .shaderWrite],
                                       pixelFormat: format)
        made.label = label
        return made
    }

    private func buffer(_ length: Int) throws -> MTLBuffer {
        guard let made = device.makeBuffer(length: length, options: .storageModeShared) else { throw GPUError.textureAllocation }
        return made
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, buffers: [MTLBuffer],
                          _ haze: inout Haze, width: Int, height: Int) {
        encoder.setComputePipelineState(pipeline)
        for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
        encoder.setBytes(&haze, length: MemoryLayout<Haze>.stride, index: buffers.count)
        encoder.dispatchPixels(pipeline, width: width, height: height)
    }

    /// Encodes `encode` in a command buffer of its own and waits for it, giving its GPU time: every pass in one serial encoder, so
    /// Metal orders each read after the write before it.
    private func run(_ encode: (MTLComputeCommandEncoder) -> Void) throws -> Double {
        guard let commandBuffer = queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        encode(encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
        return commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
    }

    private static func bytes(_ resources: any MTLResource...) -> Int { resources.reduce(0) { $0 + $1.allocatedSize } }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
