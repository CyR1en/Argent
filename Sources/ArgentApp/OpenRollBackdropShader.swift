import ArgentCore
import CoreGraphics
import Metal

/// What one frame of the Open roll page's backdrop is drawn from.
struct OpenRollBackdropFrame: Equatable {
    /// The field in points.
    var size: CGSize
    /// The column of words, in points from the field's top left; nil for no clear zone.
    var column: CGRect?
    /// The drop zone round the page's centre, in the same coordinates; nil for none, which draws
    /// neither the bands of a drop nor the front of a read.
    var heroZone: CGRect?
    /// The theme: its text is the ink, its primary bottom the accent, and whether it is dark picks the strength.
    var palette: ThemePalette
    var motion: OpenRollBackdropMotion
}

/// Draws the Latent image: a fixed lattice of cells, each lit or not by comparing its coverage
/// with an ordered threshold, into a texture with one texel per cell. The texture is premultiplied
/// alpha over nothing, for Core Animation to composite over the page.
///
/// The source is compiled at run time, as the core's shaders are, so the package builds without a
/// Metal toolchain step.
@MainActor final class OpenRollBackdropRenderer {
    /// A cell's side in points.
    nonisolated static let cell: CGFloat = 2
    /// The texture's format: the colours go in sRGB-encoded and stay so, and the compositor blends
    /// the encoded values as SwiftUI's opacity does.
    nonisolated static let pixelFormat: MTLPixelFormat = .bgra8Unorm
    /// How far the column's rect is grown on every side before it is kept clear, in points.
    nonisolated static let columnMargin: CGFloat = 10
    /// The widest falloff of the clear zone, in points, and the narrowest a narrow field takes it to.
    nonisolated static let widestFalloff: CGFloat = 110
    nonisolated static let narrowestFalloff: CGFloat = 48
    /// A lit cell's opacity on a dark palette and on a light one.
    nonisolated static let darkStrength: Float = 0.17
    nonisolated static let lightStrength: Float = 0.14

    let device: MTLDevice
    /// The size of the uniforms the fragment function reads, as the compiled pipeline reports it.
    let shaderUniformsSize: Int
    /// Where each uniform starts, by its name in the source, as the compiled pipeline reports it.
    let shaderUniformOffsets: [String: Int]
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    /// The cells that cover `size`: its sides divided by the cell and rounded up, at least 1 by 1.
    nonisolated static func cells(for size: CGSize) -> (width: Int, height: Int) {
        func count(_ side: CGFloat) -> Int {
            guard side.isFinite, side > 0 else { return 1 }
            return max(1, Int((side / cell).rounded(.up)))
        }
        return (count(size.width), count(size.height))
    }

    /// Compiles the source and makes the pipeline.
    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw GPUError.noCommandQueue }
        self.queue = queue
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let vertex = library.makeFunction(name: Self.vertexName) else { throw GPUError.shaderFunctionMissing(Self.vertexName) }
        guard let fragment = library.makeFunction(name: Self.fragmentName) else {
            throw GPUError.shaderFunctionMissing(Self.fragmentName)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Open roll backdrop"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = false
        let (pipeline, reflection) = try device.makeRenderPipelineState(descriptor: descriptor, options: .bindingInfo)
        self.pipeline = pipeline
        let binding = reflection?.fragmentBindings
            .first { $0.type == .buffer && $0.index == Self.uniformsIndex } as? MTLBufferBinding
        shaderUniformsSize = binding?.bufferDataSize ?? 0
        shaderUniformOffsets = Dictionary(uniqueKeysWithValues: (binding?.bufferStructType?.members ?? []).map { ($0.name, $0.offset) })
    }

    /// Encodes one frame into `texture`, which is cells wide and high in `pixelFormat`, and returns
    /// the command buffer, not yet committed, so that a caller can present a drawable with it.
    func draw(_ frame: OpenRollBackdropFrame, to texture: MTLTexture) -> MTLCommandBuffer? {
        guard let buffer = queue.makeCommandBuffer() else { return nil }
        buffer.label = "Open roll backdrop"
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var uniforms = Self.uniforms(for: frame)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: Self.uniformsIndex)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return buffer
    }

    /// The clear zone's falloff in points: 110, but narrower where the room between the grown
    /// column and the nearer side of the field is short, so that a narrow window still shows grain.
    nonisolated static func falloff(column: CGRect, width: CGFloat) -> CGFloat {
        let room = min(column.minX, width - column.maxX)
        return min(widestFalloff, max(narrowestFalloff, 0.6 * room))
    }

    /// What the fragment function reads, mirrored field for field by `OpenRollBackdropUniforms` in
    /// the source. Every member is a float or a vector of 2 or 4, which are laid out alike in Swift
    /// and Metal; the sizes are compared in the tests.
    struct Uniforms {
        /// The field in points.
        var size: SIMD2<Float>
        /// A cell's side in points.
        var cellPoints: Float
        /// The field's clock in seconds.
        var time: Float
        /// The grown column's rect, x, y, width and height.
        var column: SIMD4<Float>
        /// The drop zone's rect, x, y, width and height.
        var hero: SIMD4<Float>
        /// The pointer's x and y, its presence and its dwell.
        var pointer: SIMD4<Float>
        /// The ink's components, sRGB-encoded, and the lit cell's strength.
        var ink: SIMD4<Float>
        /// The accent's components, sRGB-encoded; the fourth is unused.
        var accent: SIMD4<Float>
        /// The clear zone's falloff in points; 0 for no clear zone.
        var columnFalloff: Float
        /// How far the bands have gathered for a drop, 0 without a drop zone.
        var drop: Float
        /// How far the front of a read has come up, 0 without a drop zone.
        var read: Float
        /// The intro's eased progress.
        var intro: Float
        /// The trail newest first: x, y, age in seconds, and 1 for a sample or 0 for an empty slot.
        var trail: InlineArray<20, SIMD4<Float>>
    }

    nonisolated static func uniforms(for frame: OpenRollBackdropFrame) -> Uniforms {
        let motion = frame.motion, palette = frame.palette
        func rect(_ r: CGRect) -> SIMD4<Float> {
            SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height))
        }
        func color(_ hex: UInt32, _ fourth: Float) -> SIMD4<Float> {
            SIMD4(Float((hex >> 16) & 0xff) / 255, Float((hex >> 8) & 0xff) / 255, Float(hex & 0xff) / 255, fourth)
        }
        let column = frame.column.map { $0.insetBy(dx: -columnMargin, dy: -columnMargin) }
        let hasHero = frame.heroZone != nil
        var trail = InlineArray<20, SIMD4<Float>>(repeating: .zero)
        for (index, sample) in motion.trail.prefix(trail.count).enumerated() {
            trail[index] = SIMD4(Float(sample.position.x), Float(sample.position.y), Float(sample.age), 1)
        }
        return Uniforms(
            size: SIMD2(Float(frame.size.width), Float(frame.size.height)),
            cellPoints: Float(cell),
            time: Float(motion.time),
            column: column.map(rect) ?? .zero,
            hero: frame.heroZone.map(rect) ?? .zero,
            pointer: SIMD4(Float(motion.pointer.x), Float(motion.pointer.y), Float(motion.presence), Float(motion.dwell)),
            ink: color(palette.text, palette.isDark ? darkStrength : lightStrength),
            accent: color(palette.primaryBottom, 0),
            columnFalloff: column.map { Float(falloff(column: $0, width: frame.size.width)) } ?? 0,
            drop: hasHero ? Float(motion.drop) : 0,
            read: hasHero ? Float(motion.read) : 0,
            intro: Float(motion.intro),
            trail: trail)
    }

    nonisolated static let uniformsIndex = 0
    nonisolated static let vertexName = "open_roll_backdrop_vertex"
    nonisolated static let fragmentName = "open_roll_backdrop_fragment"

    /// The Latent image, ported from the approved WebGL mock with its constants. GLSL's `mod` is
    /// written out, since Metal's `fmod` truncates toward zero, and the mock's reversed
    /// `smoothstep(360, 20, hd)` is written as one minus the forward one, which Metal defines.
    nonisolated static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct OpenRollBackdropUniforms {
        float2 size;
        float cellPoints;
        float time;
        float4 column;
        float4 hero;
        float4 pointer;
        float4 ink;
        float4 accent;
        float columnFalloff;
        float drop;
        float read;
        float intro;
        float4 trail[\(OpenRollBackdropMotion.trailCapacity)];
    };

    struct OpenRollBackdropVertex {
        float4 position [[position]];
    };

    // One triangle that covers the target, made from the vertex id.
    vertex OpenRollBackdropVertex open_roll_backdrop_vertex(uint id [[vertex_id]]) {
        float2 corner = float2(float((id << 1) & 2), float(id & 2));
        OpenRollBackdropVertex out;
        out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    static inline float glsl_mod(float a, float b) { return a - b * floor(a / b); }
    static inline float2 glsl_mod(float2 a, float b) { return a - b * floor(a / b); }

    static inline float hash(float2 p) {
        float3 q = fract(float3(p.xyx) * 0.1031);
        q += dot(q, q.yzx + 33.33);
        return fract((q.x + q.y) * q.z);
    }

    static inline float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p), u = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash(i), hash(i + float2(1.0, 0.0)), u.x),
                   mix(hash(i + float2(0.0, 1.0)), hash(i + float2(1.0, 1.0)), u.x), u.y);
    }

    static inline float fbm(float2 p) {
        float s = 0.0, a = 0.5;
        for (int i = 0; i < 4; i++) {
            s += a * vnoise(p);
            p = p * 2.02 + float2(17.1, 9.2);
            a *= 0.5;
        }
        return s / 0.9375;
    }

    static inline float clouds(float2 p, float t, float sc) {
        float2 q = p / sc;
        float2 w = float2(fbm(q + float2(t * 0.020, 3.1)), fbm(q + float2(5.2, 1.3 - t * 0.016)));
        return fbm(q + 1.9 * w + float2(-t * 0.010, t * 0.007));
    }

    static inline float bayer2(float2 a) {
        a = glsl_mod(floor(a), 2.0);
        return fract(a.x * 0.5 + a.y * 0.75);
    }
    static inline float bayer4(float2 a) { return bayer2(0.5 * a) * 0.25 + bayer2(a); }
    static inline float bayer8(float2 a) { return bayer4(0.5 * a) * 0.25 + bayer2(a); }

    // The signed distance from p to the rect r (x, y, width, height) with its corners rounded by rad.
    static inline float sdBox(float2 p, float4 r, float rad) {
        float2 c = r.xy + r.zw * 0.5;
        float2 q = abs(p - c) - r.zw * 0.5 + rad;
        return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - rad;
    }

    fragment float4 open_roll_backdrop_fragment(OpenRollBackdropVertex in [[stage_in]],
                                                constant OpenRollBackdropUniforms& u [[buffer(\(uniformsIndex))]]) {
        float2 cell = floor(in.position.xy);
        float2 p = (cell + 0.5) * u.cellPoints;
        float t = u.time;

        // The column of words stays clear.
        float calm = 1.0, calmT = 1.0;
        if (u.columnFalloff > 0.0) {
            float calmD = sdBox(p, u.column, 20.0);
            calm = smoothstep(0.0, u.columnFalloff, calmD);
            calmT = smoothstep(0.0, 44.0, calmD);
        }

        // The pointer's light: a pool where it is, wider while it rests, and the fading trail behind it.
        float2 dp = p - u.pointer.xy;
        float r0 = 56.0 + 44.0 * u.pointer.w;
        float e = u.pointer.z * exp(-dot(dp, dp) / (r0 * r0));
        for (int i = 0; i < \(OpenRollBackdropMotion.trailCapacity); i++) {
            float4 s = u.trail[i];
            if (s.w < 0.5) continue;
            float rs = 48.0 + s.z * 38.0;
            float2 d = p - s.xy;
            e += 0.42 * exp(-dot(d, d) / (rs * rs)) * exp(-s.z * 1.5);
        }
        float el = (1.0 - exp(-1.25 * e)) * mix(0.16, 1.0, calm);

        // A drop over the window gathers bands in to the zone; a read sends one front out from it.
        float hd = sdBox(p, u.hero, 16.0);
        float gather = u.drop * calmT * (1.0 - smoothstep(20.0, 360.0, hd)) * (0.15 + 0.15 * sin(hd * 0.085 + t * 4.2));
        float fq = (hd - glsl_mod(t * 190.0, 980.0)) / 48.0;
        float sweep = u.read * calmT * exp(-fq * fq) * 0.24;

        float2 uv = p / u.size - 0.5;
        float vig = smoothstep(0.2, 0.8, length(uv * float2(1.0, 1.12)));
        float a = clamp(el * 1.5, 0.0, 1.0);
        float c = clouds(p, t, 340.0);
        float cov = (0.012 + 0.035 * vig + smoothstep(0.40, 0.70, c) * (0.30 + 0.10 * vig)) * calm + el * 0.5 + gather + sweep;
        cov *= u.intro;
        float thr = bayer8(cell);
        if (cov < thr * 0.985 + 0.002) return float4(0.0);
        float alpha = u.ink.w * (1.0 + 0.5 * a);
        return float4(mix(u.ink.rgb, u.accent.rgb, a * 0.8) * alpha, alpha);
    }
    """
}
