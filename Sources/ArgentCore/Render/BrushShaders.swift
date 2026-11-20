extension ShaderSource {
    /// The brush's canvas kernels and the bake of a mask that reads a raster. Compiled after `maskCoverage`'s text, in a library of its
    /// own the first time a mask has a brush (`MaskFieldCache`), so a frame without one compiles nothing of it and its gradient kernels
    /// keep their library (plan section 4, rule 4).
    ///
    /// A canvas is `r16Float` at the slice's size, row 0 the picture's bottom, so a slice texel reads the canvas texel at its own `gid`.
    /// The tick (a stroke in progress) and the replay (strokes from the recipe) share `brush_dab`, `brush_half` and `brush_compose`, and
    /// round at the same places, so the two give the same bits: a stroke's shape is the largest dab value at a texel, rounded to half,
    /// which no split into ticks can change, and each stroke is composed onto the canvas once, from the same half floats.
    static let brushCanvas = """
    // One dab, as BrushDabGPU in Swift: centre in MaskSpace, its radius and where its edge starts, and its stroke for a replay.
    struct BrushDabGPU {
        float2 center;
        float outer;
        float inner;
        uint stroke;
        uint pad;
    };

    struct BrushStrokeGPU {
        float flow;
        uint erase;
    };

    struct BrushCanvasParams {
        float2 texelToPoint;    // MaskSpace long sides a canvas texel covers on each axis
        uint width;
        uint height;
        uint originX;           // a tick's region, in texture texels (row 0 the picture's bottom)
        uint originY;
        uint tile;              // a replay's tile side, in texels
        uint tilesX;
        uint freshCount;        // unused: a tick's lists are binned by tile
        uint tailCount;
        float flow;             // a tick's stroke
        uint erase;
        uint hasBase;           // a replay continues a canvas rather than starting from 0
        uint pad;
    };

    // Where a texel's centre is in MaskSpace: row 0 is the picture's bottom, as mask_bake has it.
    static inline float2 brush_point(uint2 px, constant BrushCanvasParams &p) {
        return (float2(float(px.x), float(p.height - 1u - px.y)) + 0.5f) * p.texelToPoint;
    }

    static inline float brush_dab(float2 q, BrushDabGPU d) {
        float2 v = q - d.center;
        float dist = sqrt(dot(v, v));
        if (dist >= d.outer) return 0.0f;
        if (dist <= d.inner) return 1.0f;
        float x = (dist - d.inner) / (d.outer - d.inner);
        return 1.0f - x * x * (3.0f - 2.0f * x);
    }

    static inline float brush_half(float v) { return float(half(v)); }

    // A stroke of shape s laid on c: paint c + flow s (1 - c), erase c (1 - flow s), rounded to the canvas.
    static inline float brush_compose(float c, float s, float flow, uint erase) {
        float a = flow * s;
        return brush_half(erase != 0u ? c * (1.0f - a) : c + a * (1.0f - c));
    }

    // A stroke in progress, over the region its new dabs and its old and new tails touch. `stroke` holds the shape of the dabs made
    // certain so far; `live` is base with the stroke laid on it as if it ended now, its tail included. Each texel reads only the dabs
    // binned to its tile, so a long Shift-click line's tail costs what its dabs cover.
    kernel void brush_tick(texture2d<float, access::read> base [[texture(0)]],
                           texture2d<float, access::read_write> stroke [[texture(1)]],
                           texture2d<float, access::write> live [[texture(2)]],
                           constant BrushCanvasParams &p [[buffer(0)]],
                           device const BrushDabGPU *fresh [[buffer(1)]],
                           device const BrushDabGPU *tail [[buffer(2)]],
                           device const uint *freshOffsets [[buffer(3)]],
                           device const uint *freshList [[buffer(4)]],
                           device const uint *tailOffsets [[buffer(5)]],
                           device const uint *tailList [[buffer(6)]],
                           uint2 gid [[thread_position_in_grid]]) {
        uint2 px = uint2(p.originX, p.originY) + gid;
        if (px.x >= p.width || px.y >= p.height) return;
        float2 q = brush_point(px, p);
        uint tile = (px.y / p.tile) * p.tilesX + px.x / p.tile;
        float held = stroke.read(px).r;
        float made = held;
        for (uint k = freshOffsets[tile]; k < freshOffsets[tile + 1u]; k++) made = max(made, brush_dab(q, fresh[freshList[k]]));
        made = brush_half(made);
        if (made != held) stroke.write(float4(made, 0.0f, 0.0f, 0.0f), px);
        float shown = made;
        for (uint k = tailOffsets[tile]; k < tailOffsets[tile + 1u]; k++) shown = max(shown, brush_dab(q, tail[tailList[k]]));
        live.write(float4(brush_compose(base.read(px).r, brush_half(shown), p.flow, p.erase), 0.0f, 0.0f, 0.0f), px);
    }

    // Strokes from the recipe, from 0 or onto a canvas: each texel walks its tile's dabs in stroke order, keeping one stroke's shape
    // and laying it down when the next stroke starts.
    kernel void brush_replay(texture2d<float, access::read> base [[texture(0)]],
                             texture2d<float, access::write> canvas [[texture(1)]],
                             constant BrushCanvasParams &p [[buffer(0)]],
                             device const BrushDabGPU *dabs [[buffer(1)]],
                             device const BrushStrokeGPU *strokes [[buffer(2)]],
                             device const uint *offsets [[buffer(3)]],
                             device const uint *list [[buffer(4)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        float2 q = brush_point(gid, p);
        uint tile = (gid.y / p.tile) * p.tilesX + gid.x / p.tile;
        float c = p.hasBase != 0u ? base.read(gid).r : 0.0f;
        float s = 0.0f;
        uint current = 0xffffffffu;
        for (uint k = offsets[tile]; k < offsets[tile + 1u]; k++) {
            BrushDabGPU d = dabs[list[k]];
            if (d.stroke != current) {
                if (current != 0xffffffffu) c = brush_compose(c, brush_half(s), strokes[current].flow, strokes[current].erase);
                s = 0.0f;
                current = d.stroke;
            }
            s = max(s, brush_dab(q, d));
        }
        if (current != 0xffffffffu) c = brush_compose(c, brush_half(s), strokes[current].flow, strokes[current].erase);
        canvas.write(float4(c, 0.0f, 0.0f, 0.0f), gid);
    }

    // A component's value is analytic (kind 0 linear, 1 radial), a raster read at the texel (2), or a constant held in `start` (3, a
    // brush with no stroke). A raster's invert is complement, as a radial's. Written out in each kernel below, since an array of
    // textures cannot be handed to a function.
    // mask_bake for a mask with rasters: the same composition, left to right from 0, the raster read at the slice texel's own gid.
    kernel void mask_bake_raster(texture2d_array<float, access::read_write> slices [[texture(0)]],
                                 array<texture2d<float, access::read>, 16> rasters [[texture(1)]],
                                 constant MaskBakeParams &p [[buffer(0)]],
                                 constant MaskBakeComponent *components [[buffer(1)]],
                                 constant uint *rasterOf [[buffer(2)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        float2 q = (float2(float(gid.x), float(p.fieldHeight - 1u - gid.y)) + 0.5f) * p.texelToPoint;
        float c = 0.0f;
        for (uint i = 0u; i < p.count; i++) {
            float v;
            if (components[i].kind < 2u) {
                v = mask_component(components[i], q);
            } else {
                v = components[i].kind == 2u ? rasters[rasterOf[i]].read(gid).r : components[i].start;
                if (components[i].complement != 0u) v = 1.0f - v;
            }
            c = components[i].operation == 0u ? c + v - c * v : c * (1.0f - v);
        }
        float4 texel = slices.read(gid, p.slice);
        texel[p.channel] = clamp(c, 0.0f, 1.0f);
        slices.write(texel, gid, p.slice);
    }

    struct MaskOverlayParams {
        float2 texelToPoint;
        uint fieldHeight;
        uint count;
        uint originX;           // the region, from the picture's top
        uint originY;
        uint width;
        uint height;
    };

    // A mask's coverage for the overlay, top row first, over a region: what mask_bake_raster writes, at the same texels.
    kernel void mask_overlay(texture2d<float, access::write> overlay [[texture(0)]],
                             array<texture2d<float, access::read>, 16> rasters [[texture(1)]],
                             constant MaskOverlayParams &p [[buffer(0)]],
                             constant MaskBakeComponent *components [[buffer(1)]],
                             constant uint *rasterOf [[buffer(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
        uint2 top = uint2(p.originX, p.originY) + gid;
        if (top.x >= p.width || top.y >= p.height) return;
        uint2 texel = uint2(top.x, p.fieldHeight - 1u - top.y);
        float2 q = (float2(float(texel.x), float(p.fieldHeight - 1u - texel.y)) + 0.5f) * p.texelToPoint;
        float c = 0.0f;
        for (uint i = 0u; i < p.count; i++) {
            float v;
            if (components[i].kind < 2u) {
                v = mask_component(components[i], q);
            } else {
                v = components[i].kind == 2u ? rasters[rasterOf[i]].read(texel).r : components[i].start;
                if (components[i].complement != 0u) v = 1.0f - v;
            }
            c = components[i].operation == 0u ? c + v - c * v : c * (1.0f - v);
        }
        overlay.write(float4(clamp(c, 0.0f, 1.0f)), top);
    }
    """
}
