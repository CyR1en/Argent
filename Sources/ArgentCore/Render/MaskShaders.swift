extension ShaderSource {
    /// The masks' coverage bake (`MaskFieldCache`). A library of its own, compiled the first time a frame with masks bakes, so a
    /// frame with none pays nothing and `GPU.shaderLibrary()` keeps its text (plan section 4, rule 4). It holds no profile constant:
    /// `MaskProgram` turns a mask into `MaskBakeComponent`s with their (a, b) and step already chosen, so the tables have one copy.
    static let maskCoverage = """
    #include <metal_stdlib>
    using namespace metal;

    // One component, as MaskProgram compiled it. Swift's MaskBakeComponent has this layout.
    //   linear: t = dot(q - origin, axisU), 0 at Full, 1 at Zero. An inverted one has its Full and Zero swapped already.
    //   radial: n = length of (dot(q - origin, axisU), dot(q - origin, axisV)), 1 on the drawn outline.
    // Either way x = clamp((t or n - start) * scale, 0, 1) on the profile's (a, b). Intersect arrives as subtract of the inverse.
    struct MaskBakeComponent {
        uint kind;              // 0 linear, 1 radial
        uint operation;         // 0 add, 1 subtract
        float2 origin;
        float2 axisU;
        float2 axisV;
        float start;
        float scale;
        float smootherShare;    // radial: 1 smootherstep, 0 smoothstep (Feather 0), between them under Feather 5
        uint complement;        // radial: an inverted one is 1 - v
    };

    struct MaskBakeParams {
        float2 texelToPoint;    // MaskSpace long sides a slice texel covers on each axis
        uint fieldHeight;
        uint count;
        uint slice;
        uint channel;
    };

    struct MaskMoveParams {
        uint sourceSlice;
        uint sourceChannel;
        uint targetSlice;
        uint targetChannel;
    };

    static inline float mask_component(constant MaskBakeComponent &k, float2 q) {
        float2 d = q - k.origin;
        if (k.kind == 0u) {
            float x = clamp((dot(d, k.axisU) - k.start) * k.scale, 0.0f, 1.0f);
            return 0.5f + 0.5f * cos(3.14159265f * x);
        }
        float n = length(float2(dot(d, k.axisU), dot(d, k.axisV)));
        float x = clamp((n - k.start) * k.scale, 0.0f, 1.0f);
        float smooth = x * x * (3.0f - 2.0f * x);
        float smoother = x * x * x * (x * (x * 6.0f - 15.0f) + 10.0f);
        float v = 1.0f - (smooth + (smoother - smooth) * k.smootherShare);
        return k.complement != 0u ? 1.0f - v : v;
    }

    // Left to right from c = 0: add c + v - c v, subtract c (1 - v).
    static inline float mask_compose(constant MaskBakeComponent *components, uint count, float2 q) {
        float c = 0.0f;
        for (uint i = 0u; i < count; i++) {
            float v = mask_component(components[i], q);
            c = components[i].operation == 0u ? c + v - c * v : c * (1.0f - v);
        }
        return clamp(c, 0.0f, 1.0f);
    }

    // Writes one channel of one slice and keeps the others, so changing one mask leaves the three that share its slice alone.
    // Row 0 is the picture's bottom: the flip from MaskSpace's y happens here, once.
    kernel void mask_bake(texture2d_array<float, access::read_write> slices [[texture(0)]],
                          constant MaskBakeParams &p [[buffer(0)]],
                          constant MaskBakeComponent *components [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
        float2 q = (float2(float(gid.x), float(p.fieldHeight - 1u - gid.y)) + 0.5f) * p.texelToPoint;
        float4 texel = slices.read(gid, p.slice);
        texel[p.channel] = mask_compose(components, p.count, q);
        slices.write(texel, gid, p.slice);
    }

    // A field already baked, into another slot of another array: half floats read and written back unchanged.
    kernel void mask_move(texture2d_array<float, access::read> source [[texture(0)]],
                          texture2d_array<float, access::read_write> target [[texture(1)]],
                          constant MaskMoveParams &p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        float4 texel = target.read(gid, p.targetSlice);
        texel[p.targetChannel] = source.read(gid, p.sourceSlice)[p.sourceChannel];
        target.write(texel, gid, p.targetSlice);
    }

    // The same within one array, which Metal cannot bind twice.
    kernel void mask_move_within(texture2d_array<float, access::read_write> target [[texture(0)]],
                                 constant MaskMoveParams &p [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        float value = target.read(gid, p.sourceSlice)[p.sourceChannel];
        float4 texel = target.read(gid, p.targetSlice);
        texel[p.targetChannel] = value;
        target.write(texel, gid, p.targetSlice);
    }

    // A new array's contents are undefined, and a slice's other channels are read back by mask_bake.
    kernel void mask_clear(texture2d_array<float, access::write> slices [[texture(0)]],
                           constant uint &slice [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        slices.write(float4(0.0f), gid, slice);
    }
    """
    static let maskRemapPoint = """
    static inline float2 mask_remap_uv(float2 uv, float2 extent, device const float *ratio) {
        float x = min(length((uv - 0.5f) * extent) / (0.5f * length(extent)), 1.0f) * 960.0f;
        uint i = min(uint(x), 959u);
        return 0.5f + (uv - 0.5f) * mix(ratio[i], ratio[i + 1u], x - float(i));
    }
    """

    static let maskBakeMapped = maskRemapPoint + "\n" + """
    kernel void mask_bake_mapped(texture2d_array<float, access::read_write> slices [[texture(0)]],
                                array<texture2d<float, access::sample>, 16> rasters [[texture(1)]],
                                constant MaskBakeParams &p [[buffer(0)]],
                                constant MaskBakeComponent *components [[buffer(1)]],
                                constant uint *rasterOf [[buffer(2)]],
                                constant uint *remapOf [[buffer(3)]],
                                device const float *ratios [[buffer(4)]],
                                uint2 gid [[thread_position_in_grid]]) {
        constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 extent = p.texelToPoint * float2(slices.get_width(), slices.get_height());
        float2 uv = (float2(gid) + 0.5f) / float2(slices.get_width(), slices.get_height());
        float2 q = (float2(float(gid.x), float(p.fieldHeight - 1u - gid.y)) + 0.5f) * p.texelToPoint;
        float c = 0.0f;
        for (uint i = 0u; i < p.count; i++) {
            float2 at = uv, qi = q;
            if (remapOf[i] != 0u) {
                at = mask_remap_uv(uv, extent, ratios + (remapOf[i] - 1u) * 961u);
                qi = float2(at.x, 1.0f - at.y) * extent;
            }
            float v;
            if (components[i].kind < 2u) {
                v = mask_component(components[i], qi);
            } else {
                v = components[i].kind == 2u ? (remapOf[i] != 0u ? rasters[rasterOf[i]].sample(linearClamp, at).r
                                                                               : rasters[rasterOf[i]].read(gid).r) : components[i].start;
                if (components[i].complement != 0u) v = 1.0f - v;
            }
            c = components[i].operation == 0u ? c + v - c * v : c * (1.0f - v);
        }
        float4 texel = slices.read(gid, p.slice);
        texel[p.channel] = clamp(c, 0.0f, 1.0f);
        slices.write(texel, gid, p.slice);
    }
    """

    static let maskResample = """
    kernel void mask_resample(texture2d<float, access::sample> source [[texture(0)]],
                             texture2d<float, access::write> target [[texture(1)]],
                             constant float2 &extent [[buffer(0)]],
                             device const float *ratio [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = (float2(gid) + 0.5f) / float2(target.get_width(), target.get_height());
        target.write(source.sample(linearClamp, mask_remap_uv(uv, extent, ratio)), gid);
    }
    """
}
