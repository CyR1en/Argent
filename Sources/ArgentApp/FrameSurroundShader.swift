import ArgentCore
import CoreGraphics
import Metal

/// Everything needed to draw one frame of the single-frame view's context-aware ambient surround.
struct FrameSurroundDrawState: Equatable {
    /// The Metal view's own bounds in points (may extend past `workspaceSize` on the trailing edge
    /// while the Adjust inspector slides in or out).
    var viewSize: CGSize
    /// The visible workspace size in points, used for the outer perimeter falloff.
    var workspaceSize: CGSize
    /// The open photograph's rectangle in top-left workspace points (`FrameGeometry.picture`).
    var photoRect: CGRect?
    /// The outgoing photograph's rectangle during a crossfade, so aspect changes never stretch.
    var previousPhotoRect: CGRect?
    /// The active theme palette (`photoSurround` is the neutral base, `isDark` sets polarity).
    var palette: ThemePalette
    /// Output colour space matching the window (`WindowChrome`).
    var outputSpace: OutputSpace
    /// User-tuned ambient intensity (`0...1`).
    var intensity: Float
    /// Crossfade factor from previous sample (`0`) to current sample (`1`).
    var blend: Float
    var hasCurrent: Bool
    var hasPrevious: Bool
}

/// Per-host GPU texture set holding two pre-blurred ambient fields (`previous` and `current`)
/// so crossfading between frames runs purely in the composite fragment pass with zero per-tick
/// blur cost.
@MainActor final class FrameSurroundTextureSet {
    struct FieldSlot {
        var near: MTLTexture
        var broad: MTLTexture
        var width: Int
        var height: Int
    }

    private(set) var current: FieldSlot?
    private(set) var previous: FieldSlot?
    private var scratch: MTLTexture?

    func clear() {
        current = nil
        previous = nil
    }

    func prepareScratch(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        if scratch == nil || scratch?.width != width || scratch?.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
            )
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            scratch = device.makeTexture(descriptor: desc)
            scratch?.label = "Frame surround blur scratch"
        }
        return scratch
    }

    /// Promotes `current` to `previous` (if `keepPrevious`), then returns a target slot sized to
    /// `(width, height)` for the incoming blurred field, reusing existing textures when possible.
    func nextTargetSlot(device: MTLDevice, width: Int, height: Int, keepPrevious: Bool) -> FieldSlot? {
        let reusable: FieldSlot?
        if keepPrevious {
            reusable = previous
            previous = current
            current = nil
        } else {
            reusable = current ?? previous
            previous = nil
            current = nil
        }

        if let reusable, reusable.width == width, reusable.height == height {
            current = reusable
            return reusable
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let near = device.makeTexture(descriptor: desc),
              let broad = device.makeTexture(descriptor: desc)
        else { return nil }
        near.label = "Frame surround near field"
        broad.label = "Frame surround broad field"
        let slot = FieldSlot(near: near, broad: broad, width: width, height: height)
        current = slot
        return slot
    }
}

/// Runtime-compiled Metal renderer for the frame view's context-aware ambient surround:
/// 1. Two-scale separable Gaussian blur in linear float16 (`near` σ=4.2 + `broad` σ≈15.0)
///    encoded only when a new sampled frame arrives.
/// 2. Composite fragment pass: edge-continuous UV sampling aligned to `FrameGeometry.picture`,
///    smooth near→broad blend to prevent clamp stripes, theme-polarity luminance anchoring &
///    chroma restraint, perimeter falloff toward `ThemePalette.photoSurround`, and Interleaved
///    Gradient Noise anti-banding dither. The subtle grounding shadow is drawn by `FramePicture`
///    itself so it stays spring-locked to the photograph during pinch/zoom animations.
@MainActor final class FrameSurroundRenderer {
    nonisolated static let pixelFormat: MTLPixelFormat = .bgra8Unorm
    /// Maximum drawable side in pixels: 1× points up to this cap keeps VRAM tiny and gradients
    /// silky smooth under linear magnification even on 6K displays.
    nonisolated static let maxDrawableSide = 1600
    /// Near-field Gaussian sigma on the 48-texel sample grid.
    nonisolated static let nearSigma: Float = 4.2
    nonisolated static let nearRadius: Float = 10
    /// Additional sigma applied to the near field so total broad sigma ≈ sqrt(4.2² + 14.4²) ≈ 15.0.
    nonisolated static let broadSigma: Float = 14.4
    nonisolated static let broadRadius: Float = 20

    let device: MTLDevice
    let shaderUniformsSize: Int
    let shaderUniformOffsets: [String: Int]

    private let queue: MTLCommandQueue
    private let blurPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let fallbackTexture: MTLTexture

    /// Drawable dimensions for a view of `size` in points: 1× points, clamped to `1...maxDrawableSide`.
    nonisolated static func drawableSize(for size: CGSize) -> (width: Int, height: Int) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return (1, 1) }
        let longest = max(size.width, size.height)
        let scale = longest > CGFloat(maxDrawableSide) ? CGFloat(maxDrawableSide) / longest : 1
        let width = max(1, Int((size.width * scale).rounded(.up)))
        let height = max(1, Int((size.height * scale).rounded(.up)))
        return (width, height)
    }

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw GPUError.noCommandQueue }
        self.queue = queue

        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let vertex = library.makeFunction(name: Self.vertexName) else {
            throw GPUError.shaderFunctionMissing(Self.vertexName)
        }
        guard let blurFrag = library.makeFunction(name: Self.blurFragmentName) else {
            throw GPUError.shaderFunctionMissing(Self.blurFragmentName)
        }
        guard let compFrag = library.makeFunction(name: Self.compositeFragmentName) else {
            throw GPUError.shaderFunctionMissing(Self.compositeFragmentName)
        }

        let blurDesc = MTLRenderPipelineDescriptor()
        blurDesc.label = "Frame surround separable blur"
        blurDesc.vertexFunction = vertex
        blurDesc.fragmentFunction = blurFrag
        blurDesc.colorAttachments[0].pixelFormat = .rgba16Float
        blurDesc.colorAttachments[0].isBlendingEnabled = false
        blurPipeline = try device.makeRenderPipelineState(descriptor: blurDesc)

        let compDesc = MTLRenderPipelineDescriptor()
        compDesc.label = "Frame surround composite"
        compDesc.vertexFunction = vertex
        compDesc.fragmentFunction = compFrag
        compDesc.colorAttachments[0].pixelFormat = Self.pixelFormat
        compDesc.colorAttachments[0].isBlendingEnabled = false
        let (pipeline, reflection) = try device.makeRenderPipelineState(descriptor: compDesc, options: .bindingInfo)
        compositePipeline = pipeline

        let binding = reflection?.fragmentBindings
            .first { $0.type == .buffer && $0.index == Self.uniformsIndex } as? MTLBufferBinding
        shaderUniformsSize = binding?.bufferDataSize ?? 0
        shaderUniformOffsets = Dictionary(
            uniqueKeysWithValues: (binding?.bufferStructType?.members ?? []).map { ($0.name, $0.offset) }
        )

        let fbDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false
        )
        fbDesc.usage = [.shaderRead]
        fbDesc.storageMode = .shared
        guard let fallback = device.makeTexture(descriptor: fbDesc) else {
            throw GPUError.textureAllocation
        }
        fallback.label = "Frame surround fallback"
        var zeros: [UInt16] = [0, 0, 0, 0]
        fallback.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zeros, bytesPerRow: 8)
        fallbackTexture = fallback
    }

    /// Uploads `sample` and encodes its two-scale linear Gaussian blur into `textures`, returning
    /// the uncommitted command buffer (or appends to an existing `buffer` if supplied).
    @discardableResult
    func uploadAndBlur(
        _ sample: FrameSurroundSample,
        into textures: FrameSurroundTextureSet,
        keepPrevious: Bool,
        on existingBuffer: MTLCommandBuffer? = nil
    ) -> MTLCommandBuffer? {
        guard sample.width > 0, sample.height > 0,
              sample.bytes.count >= sample.width * sample.height * 4
        else { return nil }

        // Allocate an immutable per-upload shared texture (at most 48×32×4 ≈ 6 KiB) so rapid
        // back-to-back async uploads never overwrite CPU-visible memory while an earlier GPU blur
        // command buffer is still reading it.
        let rawDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: sample.width, height: sample.height, mipmapped: false
        )
        rawDesc.usage = [.shaderRead]
        rawDesc.storageMode = .shared
        guard let raw = device.makeTexture(descriptor: rawDesc),
              let buffer = existingBuffer ?? queue.makeCommandBuffer(),
              let scratch = textures.prepareScratch(device: device, width: sample.width, height: sample.height),
              let slot = textures.nextTargetSlot(device: device, width: sample.width, height: sample.height, keepPrevious: keepPrevious)
        else { return nil }
        raw.label = "Frame surround raw sample"

        sample.bytes.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            raw.replace(
                region: MTLRegionMake2D(0, 0, sample.width, sample.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: sample.width * 4
            )
        }

        if existingBuffer == nil { buffer.label = "Frame surround blur" }

        let invW = 1.0 / Float(sample.width)
        let invH = 1.0 / Float(sample.height)
        let decodeMode: Float = sample.space == .adobeRGB ? 2.0 : 1.0

        // Pass 1: raw (encoded) -> scratch (linear H blur, near sigma)
        encodeBlurPass(
            buffer: buffer, source: raw, target: scratch,
            uniforms: BlurUniforms(direction: SIMD2(invW, 0), sigma: Self.nearSigma, radius: Self.nearRadius, decodeMode: decodeMode)
        )
        // Pass 2: scratch -> slot.near (linear V blur, near sigma)
        encodeBlurPass(
            buffer: buffer, source: scratch, target: slot.near,
            uniforms: BlurUniforms(direction: SIMD2(0, invH), sigma: Self.nearSigma, radius: Self.nearRadius, decodeMode: 0)
        )
        // Pass 3: slot.near -> scratch (linear H blur, broad sigma)
        encodeBlurPass(
            buffer: buffer, source: slot.near, target: scratch,
            uniforms: BlurUniforms(direction: SIMD2(invW, 0), sigma: Self.broadSigma, radius: Self.broadRadius, decodeMode: 0)
        )
        // Pass 4: scratch -> slot.broad (linear V blur, broad sigma)
        encodeBlurPass(
            buffer: buffer, source: scratch, target: slot.broad,
            uniforms: BlurUniforms(direction: SIMD2(0, invH), sigma: Self.broadSigma, radius: Self.broadRadius, decodeMode: 0)
        )
        return buffer
    }

    /// Encodes the full ambient surround composite into `target` (e.g. a `CAMetalDrawable.texture`).
    func draw(
        _ state: FrameSurroundDrawState,
        textures: FrameSurroundTextureSet,
        to target: MTLTexture,
        on existingBuffer: MTLCommandBuffer? = nil
    ) -> MTLCommandBuffer? {
        guard let buffer = existingBuffer ?? queue.makeCommandBuffer() else { return nil }
        if existingBuffer == nil { buffer.label = "Frame surround composite" }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var uniforms = Self.uniforms(for: state)
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: Self.uniformsIndex)
        encoder.setFragmentTexture(textures.current?.near ?? fallbackTexture, index: 0)
        encoder.setFragmentTexture(textures.current?.broad ?? fallbackTexture, index: 1)
        encoder.setFragmentTexture(textures.previous?.near ?? fallbackTexture, index: 2)
        encoder.setFragmentTexture(textures.previous?.broad ?? fallbackTexture, index: 3)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return buffer
    }

    private func encodeBlurPass(buffer: MTLCommandBuffer, source: MTLTexture, target: MTLTexture, uniforms: BlurUniforms) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var copy = uniforms
        encoder.setRenderPipelineState(blurPipeline)
        encoder.setFragmentBytes(&copy, length: MemoryLayout<BlurUniforms>.size, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: Uniforms

    private struct BlurUniforms {
        var direction: SIMD2<Float>
        var sigma: Float
        var radius: Float
        var decodeMode: Float
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
    }

    /// Mirrored field-for-field by `FrameSurroundUniforms` in the Metal source and verified by
    /// `FrameSurroundShaderTests`.
    struct Uniforms {
        var viewSize: SIMD2<Float>
        var workspaceSize: SIMD2<Float>
        var photoRect: SIMD4<Float>
        var prevPhotoRect: SIMD4<Float>
        var baseColor: SIMD4<Float>
        var intensity: Float
        var blend: Float
        var hasCurrent: Float
        var hasPrevious: Float
        var transferMode: Float
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
    }

    nonisolated static func uniforms(for state: FrameSurroundDrawState) -> Uniforms {
        func rectVec(_ r: CGRect?) -> SIMD4<Float> {
            guard let r, r.width > 0, r.height > 0 else { return .zero }
            return SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height))
        }
        let hex = state.palette.photoSurround
        let base = SIMD4<Float>(
            Float((hex >> 16) & 0xff) / 255,
            Float((hex >> 8) & 0xff) / 255,
            Float(hex & 0xff) / 255,
            state.palette.isDark ? 1 : 0
        )
        let wsWidth = state.workspaceSize.width > 0 ? state.workspaceSize.width : state.viewSize.width
        let wsHeight = state.workspaceSize.height > 0 ? state.workspaceSize.height : state.viewSize.height
        let hasValidPhoto = state.photoRect.map { $0.width > 0 && $0.height > 0 } ?? false
        let currRect = rectVec(state.photoRect)
        let prevRect = rectVec(state.previousPhotoRect ?? state.photoRect)
        return Uniforms(
            viewSize: SIMD2(Float(max(1, state.viewSize.width)), Float(max(1, state.viewSize.height))),
            workspaceSize: SIMD2(Float(max(1, wsWidth)), Float(max(1, wsHeight))),
            photoRect: currRect,
            prevPhotoRect: prevRect,
            baseColor: base,
            intensity: min(max(state.intensity, 0), 1),
            blend: min(max(state.blend, 0), 1),
            hasCurrent: (state.hasCurrent && hasValidPhoto) ? 1 : 0,
            hasPrevious: (state.hasPrevious && hasValidPhoto) ? 1 : 0,
            transferMode: state.outputSpace == .adobeRGB ? 1 : 0
        )
    }

    nonisolated static let uniformsIndex = 0
    nonisolated static let vertexName = "frame_surround_vertex"
    nonisolated static let blurFragmentName = "frame_surround_blur_fragment"
    nonisolated static let compositeFragmentName = "frame_surround_fragment"

    nonisolated static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct FrameSurroundVertex {
        float4 position [[position]];
        float2 uv;
    };

    struct FrameSurroundBlurUniforms {
        float2 direction;
        float sigma;
        float radius;
        float decodeMode;
        float pad0;
        float pad1;
        float pad2;
    };

    struct FrameSurroundUniforms {
        float2 viewSize;
        float2 workspaceSize;
        float4 photoRect;
        float4 prevPhotoRect;
        float4 baseColor;
        float intensity;
        float blend;
        float hasCurrent;
        float hasPrevious;
        float transferMode;
        float pad0;
        float pad1;
        float pad2;
    };

    // Fullscreen triangle covering the render target; uv = (0,0) at top-left, (1,1) at bottom-right.
    vertex FrameSurroundVertex frame_surround_vertex(uint id [[vertex_id]]) {
        float2 corner = float2(float((id << 1) & 2), float(id & 2));
        FrameSurroundVertex out;
        out.position = float4(corner.x * 2.0 - 1.0, 1.0 - corner.y * 2.0, 0.0, 1.0);
        out.uv = corner;
        return out;
    }

    static inline float srgbToLinear(float c) {
        c = max(c, 0.0);
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
    }

    static inline float3 srgbToLinear(float3 c) {
        return float3(srgbToLinear(c.x), srgbToLinear(c.y), srgbToLinear(c.z));
    }

    static inline float linearToSrgb(float c) {
        c = clamp(c, 0.0, 1.0);
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
    }

    static inline float3 linearToSrgb(float3 c) {
        return float3(linearToSrgb(c.x), linearToSrgb(c.y), linearToSrgb(c.z));
    }

    static inline float3 decodeToLinear(float3 c, float mode) {
        if (mode > 1.5) return pow(max(c, float3(0.0)), float3(2.19921875));
        if (mode > 0.5) return srgbToLinear(c);
        return c;
    }

    static inline float3 encodeFromLinear(float3 c, float transferMode) {
        if (transferMode > 0.5) return pow(clamp(c, float3(0.0), float3(1.0)), float3(1.0 / 2.19921875));
        return linearToSrgb(c);
    }

    fragment float4 frame_surround_blur_fragment(
        FrameSurroundVertex in [[stage_in]],
        constant FrameSurroundBlurUniforms& u [[buffer(0)]],
        texture2d<float, access::sample> src [[texture(0)]]
    ) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        int rad = int(u.radius);
        float invTwoSigmaSq = 0.5 / max(u.sigma * u.sigma, 0.0001);
        float3 accum = float3(0.0);
        float weightSum = 0.0;
        for (int k = -rad; k <= rad; k++) {
            float fk = float(k);
            float w = exp(-fk * fk * invTwoSigmaSq);
            float2 coord = clamp(in.uv + u.direction * fk, float2(0.0), float2(1.0));
            float3 sampleRgb = decodeToLinear(src.sample(linearClamp, coord).rgb, u.decodeMode);
            accum += sampleRgb * w;
            weightSum += w;
        }
        return float4(accum / max(weightSum, 0.0001), 1.0);
    }

    static inline float3 sampleAmbientField(
        float2 p,
        float4 rect,
        float invDiag,
        texture2d<float, access::sample> nearTex,
        texture2d<float, access::sample> broadTex,
        thread float& outDistNorm
    ) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        float2 uv = (p - rect.xy) / max(rect.zw, float2(1.0));
        float2 clampedPt = clamp(p, rect.xy, rect.xy + rect.zw);
        float distNorm = length(p - clampedPt) * invDiag;
        outDistNorm = distNorm;

        // Softly inset from photo border so corner vignetting doesn't bleed dark streaks.
        float2 cu = clamp(uv, float2(0.05), float2(0.95));
        float3 nearRgb = nearTex.sample(linearClamp, cu).rgb;

        // Pull broad sample gently toward centre as distance grows, preventing clamp stripes.
        float pull = smoothstep(0.0, 0.55, distNorm) * 0.35;
        float2 bu = mix(cu, float2(0.5), pull);
        float3 broadRgb = broadTex.sample(linearClamp, bu).rgb;

        float broadMix = smoothstep(0.02, 0.42, distNorm);
        return mix(nearRgb, broadRgb, broadMix);
    }

    fragment float4 frame_surround_fragment(
        FrameSurroundVertex in [[stage_in]],
        constant FrameSurroundUniforms& u [[buffer(\(uniformsIndex))]],
        texture2d<float, access::sample> currNear [[texture(0)]],
        texture2d<float, access::sample> currBroad [[texture(1)]],
        texture2d<float, access::sample> prevNear [[texture(2)]],
        texture2d<float, access::sample> prevBroad [[texture(3)]]
    ) {
        float3 baseLin = srgbToLinear(u.baseColor.rgb);
        bool isDark = u.baseColor.w > 0.5;

        if (u.hasCurrent < 0.5 || u.intensity <= 0.001) {
            return float4(encodeFromLinear(baseLin, u.transferMode), 1.0);
        }

        float2 p = in.uv * u.viewSize;
        float invDiag = 1.0 / max(length(u.workspaceSize), 1.0);

        float distCurr = 0.0;
        float3 rgb = sampleAmbientField(p, u.photoRect, invDiag, currNear, currBroad, distCurr);
        float distNorm = distCurr;

        if (u.hasPrevious > 0.5 && u.blend < 0.999) {
            float distPrev = 0.0;
            float3 prevRgb = sampleAmbientField(p, u.prevPhotoRect, invDiag, prevNear, prevBroad, distPrev);
            rgb = mix(prevRgb, rgb, u.blend);
            distNorm = mix(distPrev, distCurr, u.blend);
        }

        // Theme-polarity luminance anchoring & chroma restraint in linear RGB.
        const float3 lumaW = float3(0.2126, 0.7152, 0.0722);
        float baseY = dot(baseLin, lumaW);
        float yLin = dot(rgb, lumaW);

        float satFactor = isDark ? 0.72 : 0.48;
        float3 diff = (rgb - float3(yLin)) * satFactor;
        float chroma = length(diff);
        float maxChroma = isDark ? 0.14 : 0.11;
        if (chroma > maxChroma) {
            diff *= (maxChroma + (chroma - maxChroma) * 0.22) / chroma;
        }

        float yNorm = pow(clamp(yLin, 0.0, 1.0), 0.72);
        float targetY;
        if (isDark) {
            // Mid-luminance dark themes (e.g. Middle gray Dark at 0x777777, baseY ≈ 0.184) smoothly
            // transition toward the gentler relative range so bright frames never blow out near-white,
            // while true dark-gallery bases (baseY <= 0.06) keep the full dark curve unchanged.
            float midBlend = smoothstep(0.06, 0.16, baseY);
            float nearLift = 1.0 + mix(0.28, 0.10, midBlend) * (1.0 - smoothstep(0.0, 0.22, distNorm));
            float lowY = max(0.007, baseY * mix(0.62, 0.76, midBlend));
            float baseHighY = mix(baseY * 2.6 + 0.065, min(0.86, baseY * 1.24 + 0.06), midBlend);
            float highY = baseHighY * nearLift;
            targetY = mix(lowY, highY, yNorm);
        } else {
            float lowY = baseY * 0.76;
            float highY = min(0.86, baseY * 1.24 + 0.06);
            targetY = mix(lowY, highY, yNorm);
        }

        float chromaScale = isDark ? (0.48 + 0.64 * min(1.0, targetY / 0.06)) : 0.78;
        float3 ambient = max(float3(0.0), float3(targetY) + diff * chromaScale);

        // Gentle atmospheric falloff toward workspace perimeter; overscan clamps cleanly.
        float2 normWs = clamp(p / max(u.workspaceSize, float2(1.0)), float2(0.0), float2(1.0)) * 2.0 - 1.0;
        float edgeVignette = smoothstep(0.38, 1.40, length(float2(normWs.x * 0.9, normWs.y)));
        float distFalloff = smoothstep(0.0, 0.75, distNorm);
        float k = clamp(u.intensity * (1.0 - 0.30 * distFalloff - 0.18 * edgeVignette), 0.0, 1.0);

        float3 color = mix(baseLin, ambient, k);

        // Interleaved Gradient Noise anti-banding dither (±0.5 LSB) before 8-bit quantization.
        float ign = fract(52.9829189 * fract(dot(floor(in.position.xy), float2(0.06711056, 0.00583715)))) - 0.5;
        float3 encoded = encodeFromLinear(color, u.transferMode) + float3(ign / 255.0);
        return float4(clamp(encoded, float3(0.0), float3(1.0)), 1.0);
    }
    """
}
