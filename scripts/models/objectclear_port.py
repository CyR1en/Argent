"""ObjectClear's networks, written for inference and for Core AI conversion. Needs only torch.

Weights: the `ObjectClear` folder of the model's Hugging Face repository (fp16 safetensors; convert-objectclear.zsh pins each by SHA-256). The modules are named
as the checkpoints name their tensors, so each loads its file with `strict=True`. The graphs are diffusers 0.43's `AutoencoderKL` and `UNet2DConditionModel` (SDXL
inpainting, 9 input channels), transformers' CLIP ViT-L/14 and ObjectClear's `PostfuseModule` at c052d91, changed only in these ways:
  1. No text encoder ships: the prompt is fixed, so its states are a file (`TextStates` here computes them once, in the recipe).
  2. The UNet returns, beside the noise, the cross-attention the pipeline reads at its last step: the softmax of
     `down_blocks.1.attentions.0.transformer_blocks.0.attn2` at the prompt's token 5 ("object"), the mean over that layer's 10 heads, 1 x 1 x h/2 x w/2. That one
     layer computes its attention as softmax(q k^T / 8) v (the pipeline's own `AttnProcessor` at that step); every other layer is scaled_dot_product_attention.
  3. One row a call. With guidance above 1 the caller runs the UNet twice (zeros for both text inputs the second time), so the graph is the same for both settings.
  4. Nearest-neighbour upsampling is repeat-by-two, cropped to the skip connection's size (identical to F.interpolate(size=..., mode="nearest") here, and it stays
     on the GPU: Core AI sends `interpolate` nearest to the CPU, apple/coreai-models `_patch_nearest_upsample`).
  5. The sinusoidal embeddings of the timestep and the six size numbers are computed in float32, as diffusers computes them, whatever the weights' precision.
  6. `norm_dtype`: where given, every GroupNorm and LayerNorm computes in that precision (float32) and returns the stream's. No graph is built with it: plain half
     precision passed every check, though the VAE's GroupNorms see values up to 3,229 (objectclear_parity.py port --ranges, and its stress mode). It is the
     remedy that is ready if a picture ever proves otherwise (objectclear_convert.py --norm float32), and it has not been run through Core AI.
  7. Layers that multiply one shared input by their own matrices are one matrix each kind (`UNet.merge`): the 140 key and value projections of the prompt's
     states, the 17 projections of the time embedding, each self-attention's three. MPSGraph's compiler makes this very merge by itself, joining the matrices
     two at a time and copying the growing result each time: 220 to 270 s for this UNet, measured, at the first call of every process when the size is symbolic
     (once, at the first load, when it is fixed). Merged here the compiler finds nothing to join, and that call takes 5 to 8 s. The numbers are the same ones;
     only the order of a few additions inside a multiply can differ.
Inputs and outputs are float32 at the graph's edge whatever the precision inside, so a caller never handles half floats.
"""
import math
import torch
import torch.nn as nn
import torch.nn.functional as F

FUSE_INDEX = 5                      # the token "object" of "remove the instance of object" (pipeline_objectclear.py:1605, 1809)
ATTENTION_LAYER = "down_blocks.1.attentions.0.transformer_blocks.0.attn2"
PROMPT = "remove the instance of object"
# CLIP's tokens for PROMPT, padded to 77: start, five words, end, then padding (the end token for the first tokenizer, "!" = 0 for the second).
# Checked against the two tokenizers of the weights (goldens' manifest.json).
TOKENS_1 = [49406, 9709, 518, 34572, 539, 14115, 49407] + [49407] * 70
TOKENS_2 = [49406, 9709, 518, 34572, 539, 14115, 49407] + [0] * 70
CLIP_MEAN = (0.48145466, 0.4578275, 0.40821073)
CLIP_STD = (0.26862954, 0.26130258, 0.27577711)
VAE_SCALING = 0.13025


class GroupNorm(nn.GroupNorm):
    norm_dtype = None
    def forward(self, x):
        if self.norm_dtype is None: return super().forward(x)
        d = self.norm_dtype
        return F.group_norm(x.to(d), self.num_groups, self.weight.to(d), self.bias.to(d), self.eps).to(x.dtype)


class LayerNorm(nn.LayerNorm):
    norm_dtype = None
    def forward(self, x):
        if self.norm_dtype is None: return super().forward(x)
        d = self.norm_dtype
        return F.layer_norm(x.to(d), self.normalized_shape, self.weight.to(d), self.bias.to(d), self.eps).to(x.dtype)


def set_norm_dtype(module, dtype):
    for m in module.modules():
        if isinstance(m, (GroupNorm, LayerNorm)): m.norm_dtype = dtype
    return module


def upsample2(x, height=None, width=None):
    """Nearest by two; then the first `height` rows and `width` columns, where the skip connection it meets is one short (an odd size halved and doubled)."""
    x = x.repeat_interleave(2, dim=-1).repeat_interleave(2, dim=-2)
    if height is None: return x
    fixed = isinstance(height, int) and isinstance(width, int) and isinstance(x.shape[-2], int) and isinstance(x.shape[-1], int)
    if fixed and height == x.shape[-2] and width == x.shape[-1]: return x      # with symbolic sizes the crop is always made: whether it is needed depends on the size
    return x[:, :, :height, :width]


class Resnet(nn.Module):
    def __init__(self, cin, cout, temb=None, eps=1e-5):
        super().__init__()
        self.norm1 = GroupNorm(32, cin, eps=eps); self.conv1 = nn.Conv2d(cin, cout, 3, padding=1)
        if temb: self.time_emb_proj = nn.Linear(temb, cout)
        self.norm2 = GroupNorm(32, cout, eps=eps); self.conv2 = nn.Conv2d(cout, cout, 3, padding=1)
        if cin != cout: self.conv_shortcut = nn.Conv2d(cin, cout, 1)
        self.has_shortcut = cin != cout

    def forward(self, x, time=None):
        """`time` is this block's projection of silu(time embedding), 1 x cout, which the UNet makes for all its blocks at once (point 7)."""
        h = self.conv1(F.silu(self.norm1(x)))
        if time is not None: h = h + time[:, :, None, None]
        h = self.conv2(F.silu(self.norm2(h)))
        return (self.conv_shortcut(x) if self.has_shortcut else x) + h


# ---- the VAE ---------------------------------------------------------------------------------------------------------------------------------
class VaeAttention(nn.Module):
    """One head over every position, with a residual (diffusers' Attention as AutoencoderKL's mid block makes it)."""
    def __init__(self, c):
        super().__init__()
        self.group_norm = GroupNorm(32, c, eps=1e-6)
        self.to_q = nn.Linear(c, c); self.to_k = nn.Linear(c, c); self.to_v = nn.Linear(c, c); self.to_out = nn.ModuleList([nn.Linear(c, c)])

    def forward(self, x):
        b, c, h, w = x.shape
        y = self.group_norm(x).flatten(2).transpose(1, 2)
        o = F.scaled_dot_product_attention(self.to_q(y)[:, None], self.to_k(y)[:, None], self.to_v(y)[:, None])[:, 0]
        return x + self.to_out[0](o).transpose(1, 2).reshape(b, c, h, w)


class VaeMid(nn.Module):
    def __init__(self, c):
        super().__init__()
        self.resnets = nn.ModuleList([Resnet(c, c, eps=1e-6), Resnet(c, c, eps=1e-6)]); self.attentions = nn.ModuleList([VaeAttention(c)])
    def forward(self, x):
        return self.resnets[1](self.attentions[0](self.resnets[0](x)))


class Conv(nn.Module):
    """A module whose one member is `conv`, as the checkpoints name their down- and upsamplers."""
    def __init__(self, c, stride=1, padding=1):
        super().__init__(); self.conv = nn.Conv2d(c, c, 3, stride=stride, padding=padding)


class VaeDown(nn.Module):
    def __init__(self, cin, cout, down):
        super().__init__()
        self.resnets = nn.ModuleList([Resnet(cin, cout, eps=1e-6), Resnet(cout, cout, eps=1e-6)])
        if down: self.downsamplers = nn.ModuleList([Conv(cout, stride=2, padding=0)])
        self.down = down
    def forward(self, x):
        for r in self.resnets: x = r(x)
        if self.down: x = self.downsamplers[0].conv(F.pad(x, (0, 1, 0, 1)))
        return x


class VaeUp(nn.Module):
    def __init__(self, cin, cout, up):
        super().__init__()
        self.resnets = nn.ModuleList([Resnet(cin if i == 0 else cout, cout, eps=1e-6) for i in range(3)])
        if up: self.upsamplers = nn.ModuleList([Conv(cout)])
        self.up = up
    def forward(self, x):
        for r in self.resnets: x = r(x)
        if self.up: x = self.upsamplers[0].conv(upsample2(x))
        return x


class _Encoder(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv_in = nn.Conv2d(3, 128, 3, padding=1)
        self.down_blocks = nn.ModuleList([VaeDown(128, 128, True), VaeDown(128, 256, True), VaeDown(256, 512, True), VaeDown(512, 512, False)])
        self.mid_block = VaeMid(512); self.conv_norm_out = GroupNorm(32, 512, eps=1e-6); self.conv_out = nn.Conv2d(512, 8, 3, padding=1)
    def forward(self, x):
        x = self.conv_in(x)
        for b in self.down_blocks: x = b(x)
        return self.conv_out(F.silu(self.conv_norm_out(self.mid_block(x))))


class _Decoder(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv_in = nn.Conv2d(4, 512, 3, padding=1); self.mid_block = VaeMid(512)
        self.up_blocks = nn.ModuleList([VaeUp(512, 512, True), VaeUp(512, 512, True), VaeUp(512, 256, True), VaeUp(256, 128, False)])
        self.conv_norm_out = GroupNorm(32, 128, eps=1e-6); self.conv_out = nn.Conv2d(128, 3, 3, padding=1)
    def forward(self, x):
        x = self.mid_block(self.conv_in(x))
        for b in self.up_blocks: x = b(x)
        return self.conv_out(F.silu(self.conv_norm_out(x)))


# `assign=True` everywhere a checkpoint is loaded: the module takes the file's tensors as they are instead of copying them into its own, which for the
# UNet is 5 GB less at the peak.
def _load(module, state, prefixes):
    own = {k: v for k, v in state.items() if k.startswith(prefixes)}
    module.load_state_dict(own, strict=True, assign=True); return module


class VaeEncoder(nn.Module):
    """picture 1 x 3 x H x W in [-1, 1] -> moments 1 x 8 x H/8 x W/8: the latent's mean, then its log variance, unscaled (the caller samples and multiplies by 0.13025)."""
    def __init__(self):
        super().__init__(); self.encoder = _Encoder(); self.quant_conv = nn.Conv2d(8, 8, 1)
    def load_weights(self, state): return _load(self, state, ("encoder.", "quant_conv."))
    def forward(self, picture):
        return self.quant_conv(self.encoder(picture.to(self.quant_conv.weight.dtype))).float()


class VaeDecoder(nn.Module):
    """latents 1 x 4 x h x w, already divided by 0.13025 -> picture 1 x 3 x 8h x 8w, about [-1, 1], not clamped."""
    def __init__(self):
        super().__init__(); self.decoder = _Decoder(); self.post_quant_conv = nn.Conv2d(4, 4, 1)
    def load_weights(self, state): return _load(self, state, ("decoder.", "post_quant_conv."))
    def forward(self, latents):
        return self.decoder(self.post_quant_conv(latents.to(self.post_quant_conv.weight.dtype))).float()


# ---- CLIP: the image encoder, and the text encoders the recipe runs once -----------------------------------------------------------------------
class ClipAttention(nn.Module):
    def __init__(self, dim, heads):
        super().__init__(); self.heads = heads
        self.k_proj = nn.Linear(dim, dim); self.v_proj = nn.Linear(dim, dim); self.q_proj = nn.Linear(dim, dim); self.out_proj = nn.Linear(dim, dim)
    def forward(self, x, causal=False):
        b, n, c = x.shape; split = lambda t: t.view(b, n, self.heads, c // self.heads).transpose(1, 2)
        o = F.scaled_dot_product_attention(split(self.q_proj(x)), split(self.k_proj(x)), split(self.v_proj(x)), is_causal=causal)
        return self.out_proj(o.transpose(1, 2).reshape(b, n, c))


class ClipMlp(nn.Module):
    def __init__(self, dim, hidden, quick):
        super().__init__(); self.fc1 = nn.Linear(dim, hidden); self.fc2 = nn.Linear(hidden, dim); self.quick = quick
    def forward(self, x):
        x = self.fc1(x)
        return self.fc2(x * torch.sigmoid(1.702 * x) if self.quick else F.gelu(x))


class ClipLayer(nn.Module):
    def __init__(self, dim, heads, quick=True):
        super().__init__()
        self.self_attn = ClipAttention(dim, heads); self.layer_norm1 = LayerNorm(dim); self.mlp = ClipMlp(dim, dim * 4, quick); self.layer_norm2 = LayerNorm(dim)
    def forward(self, x, causal=False):
        x = x + self.self_attn(self.layer_norm1(x), causal)
        return x + self.mlp(self.layer_norm2(x))


class _Layers(nn.Module):
    def __init__(self, n, dim, heads, quick=True):
        super().__init__(); self.layers = nn.ModuleList([ClipLayer(dim, heads, quick) for _ in range(n)])


class _VisionEmbeddings(nn.Module):
    def __init__(self):
        super().__init__()
        self.class_embedding = nn.Parameter(torch.zeros(1024)); self.patch_embedding = nn.Conv2d(3, 1024, 14, stride=14, bias=False)
        self.position_embedding = nn.Embedding(257, 1024)
    def forward(self, x):
        p = self.patch_embedding(x).flatten(2).transpose(1, 2)
        return torch.cat([self.class_embedding.expand(p.shape[0], 1, -1), p], 1) + self.position_embedding.weight[None]


class _Vision(nn.Module):
    def __init__(self):
        super().__init__()
        self.embeddings = _VisionEmbeddings(); self.pre_layrnorm = LayerNorm(1024); self.encoder = _Layers(24, 1024, 16); self.post_layernorm = LayerNorm(1024)
    def forward(self, x):
        x = self.pre_layrnorm(self.embeddings(x))
        for layer in self.encoder.layers: x = layer(x)
        return self.post_layernorm(x[:, 0])


class _FuseMlp(nn.Module):
    def __init__(self, cin, cout, residual):
        super().__init__(); self.layernorm = LayerNorm(cin); self.fc1 = nn.Linear(cin, cout); self.fc2 = nn.Linear(cout, cout); self.residual = residual
    def forward(self, x):
        y = self.fc2(F.gelu(self.fc1(self.layernorm(x))))
        return x + y if self.residual else y


class _Postfuse(nn.Module):
    def __init__(self):
        super().__init__(); self.mlp1 = _FuseMlp(768, 2048, False); self.mlp2 = _FuseMlp(2048, 2048, True); self.layer_norm = LayerNorm(2048)
    def forward(self, x): return self.layer_norm(self.mlp2(self.mlp1(x)))


class ObjectEncoder(nn.Module):
    """object 1 x 3 x 224 x 224 in [-1, 1] (the picture where the mask is set, zero elsewhere, already resized: `image_encoder_resized` of the goldens)
    -> fused 1 x 2048: the row that replaces row FUSE_INDEX of the fixed text states. CLIP's normalisation is inside; `embeds` (1 x 768) is the second output."""
    def __init__(self):
        super().__init__()
        self.vision_model = _Vision(); self.visual_projection = nn.Linear(1024, 768, bias=False); self.postfuse = _Postfuse()
        self.register_buffer("mean", torch.tensor(CLIP_MEAN).view(1, 3, 1, 1), persistent=False); self.register_buffer("std", torch.tensor(CLIP_STD).view(1, 3, 1, 1), persistent=False)

    def load_weights(self, clip_state, postfuse_state):
        """The first is the whole CLIP checkpoint, whose text half is not used; the second the fusion module's."""
        vision = {k: v for k, v in clip_state.items() if k.startswith(("vision_model.", "visual_projection."))}
        self.load_state_dict({**vision, **{"postfuse." + k: v for k, v in postfuse_state.items()}}, strict=True, assign=True)
        return self

    def forward(self, object):
        x = ((object.float() - self.mean.float()) / self.std.float()).to(self.visual_projection.weight.dtype)
        embeds = self.visual_projection(self.vision_model(x))
        return self.postfuse(embeds).float(), embeds.float()


class _TextEmbeddings(nn.Module):
    def __init__(self, dim):
        super().__init__(); self.token_embedding = nn.Embedding(49408, dim); self.position_embedding = nn.Embedding(77, dim)
        self.register_buffer("position_ids", torch.arange(77)[None])
    def forward(self, ids): return self.token_embedding(ids) + self.position_embedding.weight[None]


class _Text(nn.Module):
    def __init__(self, dim, layers, heads, quick):
        super().__init__(); self.embeddings = _TextEmbeddings(dim); self.encoder = _Layers(layers, dim, heads, quick); self.final_layer_norm = LayerNorm(dim)
    def forward(self, ids):
        """The penultimate layer's output (what SDXL conditions on), and the last layer's after the final norm."""
        x = self.embeddings(ids)
        for layer in self.encoder.layers[:-1]: x = layer(x, causal=True)
        return x, self.final_layer_norm(self.encoder.layers[-1](x, causal=True))


class TextStates(nn.Module):
    """The fixed prompt's states, as SDXL's `encode_prompt` makes them: the two text encoders' penultimate layers side by side (1 x 77 x 2048) and the
    second encoder's projected end-of-text state (1 x 1280). Run once by the recipe, in float32; never converted."""
    def __init__(self):
        super().__init__()
        self.one = nn.ModuleDict({"text_model": _Text(768, 12, 12, True)})
        self.two = nn.ModuleDict({"text_model": _Text(1280, 32, 20, False), "text_projection": nn.Linear(1280, 1280, bias=False)})
    def load_weights(self, state_1, state_2):
        self.one.load_state_dict(state_1, strict=True, assign=True); self.two.load_state_dict(state_2, strict=True, assign=True); return self
    def forward(self):
        a, _ = self.one["text_model"](torch.tensor([TOKENS_1])); b, last = self.two["text_model"](torch.tensor([TOKENS_2]))
        end = TOKENS_2.index(49407)
        return torch.cat([a, b], -1), self.two["text_projection"](last[:, end])


# ---- the UNet ------------------------------------------------------------------------------------------------------------------------------------
class Attention(nn.Module):
    """Self-attention (`context` None) or cross-attention over the prompt's states. Built with the checkpoint's four layers; `merge` then folds the three
    projections that share an input (point 7): to_q, to_k and to_v into one `to_qkv` for self-attention; for cross-attention to_k and to_v leave the module,
    and `forward` is given this layer's keys and values, which the UNet projects for every layer at once."""
    def __init__(self, dim, heads, context=None, tap=False):
        super().__init__(); self.heads, self.tap, self.cross = heads, tap, context is not None
        self.to_q = nn.Linear(dim, dim, bias=False); self.to_k = nn.Linear(context or dim, dim, bias=False); self.to_v = nn.Linear(context or dim, dim, bias=False)
        self.to_out = nn.ModuleList([nn.Linear(dim, dim)])

    def merge(self):
        if not self.cross:
            self.to_qkv = nn.Linear(self.to_q.in_features, 3 * self.to_q.out_features, bias=False)
            self.to_qkv.weight = nn.Parameter(torch.cat([self.to_q.weight, self.to_k.weight, self.to_v.weight], 0), requires_grad=False)
            del self.to_q
        kv = (self.to_k.weight, self.to_v.weight); del self.to_k, self.to_v
        return kv

    def forward(self, x, k=None, v=None):
        b, n, c = x.shape; hd = c // self.heads
        if self.cross: q = self.to_q(x)
        else: q, k, v = self.to_qkv(x).chunk(3, dim=-1)
        q = q.view(b, n, self.heads, hd).transpose(1, 2); k = k.view(b, -1, self.heads, hd).transpose(1, 2); v = v.view(b, -1, self.heads, hd).transpose(1, 2)
        seen = None
        if self.tap:
            probs = torch.softmax(q @ k.transpose(-1, -2) * hd ** -0.5, dim=-1); o = probs @ v
            seen = probs[:, :, :, FUSE_INDEX].float().mean(1)        # b x tokens: this token's share of each position's attention, the mean over the heads
        else:
            o = F.scaled_dot_product_attention(q, k, v)
        return self.to_out[0](o.transpose(1, 2).reshape(b, n, c)), seen


class _Geglu(nn.Module):
    def __init__(self, dim):
        super().__init__(); self.proj = nn.Linear(dim, dim * 8)
    def forward(self, x):
        a, gate = self.proj(x).chunk(2, dim=-1); return a * F.gelu(gate)


class _FeedForward(nn.Module):
    def __init__(self, dim):
        super().__init__(); self.net = nn.ModuleList([_Geglu(dim), nn.Identity(), nn.Linear(dim * 4, dim)])
    def forward(self, x): return self.net[2](self.net[0](x))


class TransformerBlock(nn.Module):
    def __init__(self, dim, heads, tap=False):
        super().__init__()
        self.norm1 = LayerNorm(dim); self.attn1 = Attention(dim, heads); self.norm2 = LayerNorm(dim); self.attn2 = Attention(dim, heads, 2048, tap)
        self.norm3 = LayerNorm(dim); self.ff = _FeedForward(dim)
    def forward(self, x, keys, values):
        """`keys` and `values` hold every cross-attention layer's projection of the prompt's states; this block takes its own (`slot`, set by UNet.merge)."""
        x = x + self.attn1(self.norm1(x))[0]
        y, seen = self.attn2(self.norm2(x), keys[self.slot], values[self.slot]); x = x + y
        return x + self.ff(self.norm3(x)), seen


class Transformer(nn.Module):
    def __init__(self, dim, heads, depth, tap=False):
        super().__init__()
        self.norm = GroupNorm(32, dim, eps=1e-6); self.proj_in = nn.Linear(dim, dim)
        self.transformer_blocks = nn.ModuleList([TransformerBlock(dim, heads, tap and i == 0) for i in range(depth)]); self.proj_out = nn.Linear(dim, dim)
    def forward(self, x, keys, values):
        b, c, h, w = x.shape
        y = self.proj_in(self.norm(x).permute(0, 2, 3, 1).reshape(b, h * w, c)); seen = None
        for i, block in enumerate(self.transformer_blocks):
            y, s = block(y, keys, values)
            if s is not None: seen = s.reshape(b, 1, h, w)
        return x + self.proj_out(y).reshape(b, h, w, c).permute(0, 3, 1, 2), seen


class _Embedding(nn.Module):
    def __init__(self, cin):
        super().__init__(); self.linear_1 = nn.Linear(cin, 1280); self.linear_2 = nn.Linear(1280, 1280)
    def forward(self, x): return self.linear_2(F.silu(self.linear_1(x)))


class _Down(nn.Module):
    def __init__(self, cin, cout, heads=None, depth=0, down=True, tap=False):
        super().__init__()
        self.resnets = nn.ModuleList([Resnet(cin, cout, 1280), Resnet(cout, cout, 1280)])
        if depth: self.attentions = nn.ModuleList([Transformer(cout, heads, depth, tap), Transformer(cout, heads, depth)])
        if down: self.downsamplers = nn.ModuleList([Conv(cout, stride=2, padding=1)])
        self.depth, self.down = depth, down


class _Mid(nn.Module):
    def __init__(self):
        super().__init__(); self.resnets = nn.ModuleList([Resnet(1280, 1280, 1280), Resnet(1280, 1280, 1280)]); self.attentions = nn.ModuleList([Transformer(1280, 20, 10)])


class _Up(nn.Module):
    def __init__(self, cins, cout, heads=None, depth=0, up=True):
        super().__init__()
        self.resnets = nn.ModuleList([Resnet(c, cout, 1280) for c in cins])
        if depth: self.attentions = nn.ModuleList([Transformer(cout, heads, depth) for _ in cins])
        if up: self.upsamplers = nn.ModuleList([Conv(cout)])
        self.depth, self.up = depth, up


def sinusoid(values, dim, frequencies):
    """diffusers' Timesteps(dim, flip_sin_to_cos=True, downscale_freq_shift=0): cosines then sines of value * 10000^(-i / (dim / 2)), in float32."""
    a = values.float()[:, None] * frequencies[None]
    return torch.cat([torch.cos(a), torch.sin(a)], dim=-1)


class UNet(nn.Module):
    """sample 1 x 9 x h x w (latents / sqrt(sigma^2 + 1), the mask, the masked picture's latents), timestep (1,), states 1 x 77 x 2048, pooled 1 x 1280,
    time_ids 1 x 6 -> noise 1 x 4 x h x w and attention 1 x 1 x h/2 x w/2 (point 2 above). h and w are even."""
    def __init__(self):
        super().__init__()
        self.conv_in = nn.Conv2d(9, 320, 3, padding=1); self.time_embedding = _Embedding(320); self.add_embedding = _Embedding(2816)
        self.down_blocks = nn.ModuleList([_Down(320, 320), _Down(320, 640, 10, 2, tap=True), _Down(640, 1280, 20, 10, down=False)])
        self.mid_block = _Mid()
        self.up_blocks = nn.ModuleList([_Up([2560, 2560, 1920], 1280, 20, 10), _Up([1920, 1280, 960], 640, 10, 2), _Up([960, 640, 640], 320, up=False)])
        self.conv_norm_out = GroupNorm(32, 320, eps=1e-5); self.conv_out = nn.Conv2d(320, 4, 3, padding=1)
        self.register_buffer("f320", torch.exp(-math.log(10000) * torch.arange(160, dtype=torch.float32) / 160), persistent=False)
        self.register_buffer("f256", torch.exp(-math.log(10000) * torch.arange(128, dtype=torch.float32) / 128), persistent=False)

    def load_weights(self, state):
        self.load_state_dict(state, strict=True, assign=True); return self.merge()

    def merge(self):
        """Point 7. Every layer that multiplies one shared input by its own matrix becomes a slice of one matrix: the 70 cross-attention layers' keys and values
        of the prompt's states (`context_proj`: the keys, then the values), the 17 residual blocks' projections of the time embedding (`time_proj`), and each
        self-attention's three projections. The same numbers, computed in one multiply each; the checkpoint's own layers are then gone."""
        blocks = [m for m in self.modules() if isinstance(m, TransformerBlock)]; keys, values = [], []
        for slot, block in enumerate(blocks):
            block.slot = slot; block.attn1.merge(); k, v = block.attn2.merge(); keys.append(k); values.append(v)
        self.context_sizes = [k.shape[0] for k in keys]
        def linear(weights, biases=None):
            m = nn.Linear(weights[0].shape[1], sum(w.shape[0] for w in weights), bias=biases is not None)
            m.weight = nn.Parameter(torch.cat(list(weights), 0), requires_grad=False)
            if biases is not None: m.bias = nn.Parameter(torch.cat(list(biases), 0), requires_grad=False)
            return m
        self.context_proj = linear(keys + values)
        resnets = [m for m in self.modules() if isinstance(m, Resnet)]
        self.time_sizes = [r.time_emb_proj.out_features for r in resnets]
        self.time_proj = linear([r.time_emb_proj.weight for r in resnets], [r.time_emb_proj.bias for r in resnets])
        for slot, r in enumerate(resnets):
            r.slot = slot; del r.time_emb_proj
        return self

    def forward(self, sample, timestep, states, pooled, time_ids):
        dt = self.conv_in.weight.dtype
        emb = self.time_embedding(sinusoid(timestep.reshape(1), 320, self.f320.float()).to(dt))
        sizes = sinusoid(time_ids.reshape(-1), 256, self.f256.float()).reshape(1, -1)
        emb = emb + self.add_embedding(torch.cat([pooled.float(), sizes], dim=-1).to(dt))
        times = self.time_proj(F.silu(emb)).split(self.time_sizes, dim=-1)
        projected = self.context_proj(states.to(dt)).split(self.context_sizes + self.context_sizes, dim=-1)
        keys, values = projected[:len(self.context_sizes)], projected[len(self.context_sizes):]
        x = self.conv_in(sample.to(dt)); skips = [x]; attention = None
        for block in self.down_blocks:
            for i, resnet in enumerate(block.resnets):
                x = resnet(x, times[resnet.slot])
                if block.depth:
                    x, seen = block.attentions[i](x, keys, values)
                    if seen is not None: attention = seen
                skips.append(x)
            if block.down:
                x = block.downsamplers[0].conv(x); skips.append(x)
        mid = self.mid_block
        x = mid.resnets[0](x, times[mid.resnets[0].slot]); x, _ = mid.attentions[0](x, keys, values); x = mid.resnets[1](x, times[mid.resnets[1].slot])
        for block in self.up_blocks:
            for i, resnet in enumerate(block.resnets):
                x = resnet(torch.cat([x, skips.pop()], dim=1), times[resnet.slot])
                if block.depth: x, _ = block.attentions[i](x, keys, values)
            if block.up:
                x = block.upsamplers[0].conv(upsample2(x, skips[-1].shape[-2], skips[-1].shape[-1]))
        return self.conv_out(F.silu(self.conv_norm_out(x))).float(), attention
