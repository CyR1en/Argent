"""S3OD-sod (DINOv3-B/16 encoder, DPT head, three masks and a predicted IoU each), written for inference and for Core AI conversion. Needs only torch.

Weights: Hugging Face `okupyn/s3od-sod` at 3752fc7f..., `s3od.pt` (`weights_only=True`, a plain state_dict). The graph is the pinned
`KupynOrest/s3od` `model.py` over transformers' `DINOv3ViTModel`, changed only in these ways (each one checked against V3's reference by check_port.py):
  1. The encoder stops after block 10: S3OD reads the hidden states at [2, 5, 8, 11] of transformers' tuple, whose element 0 is the embeddings, so block 11 and
     the final LayerNorm feed nothing. Their weights are not loaded. `mask_token` is dead too.
  2. The rotary tables depend only on the input size: computed once in float32 as transformers computes them, then cast, and kept as constants.
  3. BatchNorm at inference is the fixed affine x * scale + shift (scale = weight / sqrt(var + eps), shift = bias - mean * scale); folded at load, in float32.
  4. The head's last `F.interpolate(..., size=(1024, 1024), antialias=True)` is an identity at this shape (the transposed convolution before it has already reached 1024) and is dropped.
  5. fp16: `stream_scale` s folds a constant into every weight that writes DINOv3's residual stream (patch embedding, cls and register tokens, each block's o_proj and
     down_proj), every LayerNorm that reads it gets eps * s^2 and runs in float32, and the DPT head's four `projects` convolutions take 1/s, so the tensors leaving the
     encoder are the original ones. `fold_q_scale` folds the attention scale 1/sqrt(64) into q_proj. All exact re-parametrisations in float32 when s is a power of two.
Output: `masks` (1, 3, H, W) float16 = sigmoid of the three logits; `iou` (1, 3) float32 = sigmoid of the three predicted IoUs, whose head runs in float32 because its argmax is a selection.
Input: (1, 3, H, W), ImageNet-normalised ((x/255 - mean)/std), H and W multiples of 16.
"""
import math
import torch
import torch.nn as nn
import torch.nn.functional as F

DIM, HEADS, HD, MLP, NREG, PATCH, THETA, EPS = 768, 12, 64, 3072, 4, 16, 100.0, 1e-5
LAST_BLOCK, TAPS = 10, (1, 4, 7, 10)   # the blocks whose output the head reads: hidden_states[2, 5, 8, 11]
OUT = (256, 512, 1024, 1024)
FEATURES = 256


def rotate_half(x):
    x1, x2 = x[..., : x.shape[-1] // 2], x[..., x.shape[-1] // 2:]
    return torch.cat((-x2, x1), dim=-1)


def rope_tables(gh, gw):
    """cos, sin of shape (gh*gw, HD), float32: transformers' DINOv3ViTRopePositionEmbedding in eval mode (no shift, jitter or rescale)."""
    ch = torch.arange(0.5, gh, dtype=torch.float32) / gh
    cw = torch.arange(0.5, gw, dtype=torch.float32) / gw
    coords = torch.stack(torch.meshgrid(ch, cw, indexing="ij"), dim=-1).flatten(0, 1)
    coords = 2.0 * coords - 1.0
    inv_freq = 1 / THETA ** torch.arange(0, 1, 4 / HD, dtype=torch.float32)
    angles = (2 * math.pi * coords[:, :, None] * inv_freq[None, None, :]).flatten(1, 2).tile(2)
    return torch.cos(angles), torch.sin(angles)


class StreamNorm(nn.LayerNorm):
    """LayerNorm computed in float32 whatever the input dtype (the stream's squares overflow fp16)."""
    def forward(self, x):
        return F.layer_norm(x.float(), self.normalized_shape, self.weight.float(), self.bias.float(), self.eps).to(x.dtype)


class Attention(nn.Module):
    def __init__(self, sdpa_scale=None, attn_dtype=None):
        super().__init__()
        self.sdpa_scale, self.attn_dtype = sdpa_scale, attn_dtype
        self.k_proj = nn.Linear(DIM, DIM, bias=False)
        self.v_proj = nn.Linear(DIM, DIM, bias=True)
        self.q_proj = nn.Linear(DIM, DIM, bias=True)
        self.o_proj = nn.Linear(DIM, DIM, bias=True)

    def forward(self, x, cos, sin):
        b, n, _ = x.shape
        q = self.q_proj(x).view(b, n, HEADS, HD).transpose(1, 2)
        k = self.k_proj(x).view(b, n, HEADS, HD).transpose(1, 2)
        v = self.v_proj(x).view(b, n, HEADS, HD).transpose(1, 2)
        npatch = cos.shape[-2]
        npre = n - npatch                       # cls + registers
        qp, qx = q.split((npre, npatch), dim=-2)
        kp, kx = k.split((npre, npatch), dim=-2)
        qx = qx * cos + rotate_half(qx) * sin   # rotary on patch tokens only
        kx = kx * cos + rotate_half(kx) * sin
        q = torch.cat((qp, qx), dim=-2)
        k = torch.cat((kp, kx), dim=-2)
        ad = self.attn_dtype
        if ad is not None:   # the q.k logits reach 135,578 (DSC04073, block 8 or so): past fp16 whatever scale is folded where, so q, k, v go to float32 for this one op
            q, k, v = q.to(ad), k.to(ad), v.to(ad)
        o = F.scaled_dot_product_attention(q, k, v, scale=self.sdpa_scale).to(x.dtype)
        return self.o_proj(o.transpose(1, 2).reshape(b, n, DIM))


class LayerScale(nn.Module):
    def __init__(self):
        super().__init__()
        self.lambda1 = nn.Parameter(torch.ones(DIM))

    def forward(self, x):
        return x * self.lambda1


class Mlp(nn.Module):
    def __init__(self):
        super().__init__()
        self.up_proj = nn.Linear(DIM, MLP)
        self.down_proj = nn.Linear(MLP, DIM)

    def forward(self, x):
        return self.down_proj(F.gelu(self.up_proj(x)))


class Layer(nn.Module):
    def __init__(self, eps, sdpa_scale, attn_dtype=None):
        super().__init__()
        self.norm1 = StreamNorm(DIM, eps=eps)
        self.attention = Attention(sdpa_scale, attn_dtype)
        self.layer_scale1 = LayerScale()
        self.norm2 = StreamNorm(DIM, eps=eps)
        self.mlp = Mlp()
        self.layer_scale2 = LayerScale()

    def forward(self, x, cos, sin):
        x = x + self.layer_scale1(self.attention(self.norm1(x), cos, sin))
        x = x + self.layer_scale2(self.mlp(self.norm2(x)))
        return x


class FixedBN(nn.Module):
    """BatchNorm2d at inference: x * scale + shift, the constants made in float32 from the checkpoint at load."""
    def __init__(self, c):
        super().__init__()
        self.register_buffer("scale", torch.ones(1, c, 1, 1))
        self.register_buffer("shift", torch.zeros(1, c, 1, 1))

    def set_from(self, weight, bias, mean, var, eps=1e-5):
        s = weight / torch.sqrt(var + eps)
        self.scale.copy_(s.reshape(1, -1, 1, 1))
        self.shift.copy_((bias - mean * s).reshape(1, -1, 1, 1))

    def forward(self, x):
        return x * self.scale + self.shift


class Rcu(nn.Module):
    def __init__(self, c):
        super().__init__()
        self.conv1, self.bn1 = nn.Conv2d(c, c, 3, padding=1), FixedBN(c)
        self.conv2, self.bn2 = nn.Conv2d(c, c, 3, padding=1), FixedBN(c)

    def forward(self, x):
        o = self.bn1(self.conv1(F.relu(x)))
        o = self.bn2(self.conv2(F.relu(o)))
        return o + x


class Fusion(nn.Module):
    def __init__(self, c):
        super().__init__()
        self.out_conv = nn.Conv2d(c, c, 1)
        self.resConfUnit1, self.resConfUnit2 = Rcu(c), Rcu(c)

    def forward(self, a, b, size):
        o = a if b is None else a + self.resConfUnit1(b)
        o = F.interpolate(self.resConfUnit2(o), size=size, mode="bilinear", align_corners=False)
        return self.out_conv(o)


class S3odSod(nn.Module):
    def __init__(self, height=1024, width=1024, stream_scale=1.0, fold_q_scale=False, tail_dtype=torch.float32, attn_dtype=None, out_dtype=torch.float16):
        super().__init__()
        assert height % PATCH == 0 and width % PATCH == 0
        self.gh, self.gw, self.H, self.W = height // PATCH, width // PATCH, height, width
        self.stream_scale, self.fold_q_scale, self.tail_dtype, self.out_dtype = float(stream_scale), bool(fold_q_scale), tail_dtype, out_dtype
        eps, sdpa = EPS * self.stream_scale ** 2, (1.0 if fold_q_scale else None)
        self.cls_token = nn.Parameter(torch.zeros(1, 1, DIM))
        self.register_tokens = nn.Parameter(torch.zeros(1, NREG, DIM))
        self.patch_embeddings = nn.Conv2d(3, DIM, kernel_size=PATCH, stride=PATCH)
        self.layers = nn.ModuleList([Layer(eps, sdpa, attn_dtype) for _ in range(LAST_BLOCK + 1)])
        cos, sin = rope_tables(self.gh, self.gw)
        self.register_buffer("rope_cos", cos, persistent=False)
        self.register_buffer("rope_sin", sin, persistent=False)
        self.projects = nn.ModuleList([nn.Conv2d(DIM, c, 1) for c in OUT])
        self.resize0 = nn.ConvTranspose2d(OUT[0], OUT[0], 4, stride=4)
        self.resize1 = nn.ConvTranspose2d(OUT[1], OUT[1], 2, stride=2)
        self.resize3 = nn.Conv2d(OUT[3], OUT[3], 3, stride=2, padding=1)
        self.layer1_rn, self.layer2_rn = nn.Conv2d(OUT[0], FEATURES, 3, padding=1, bias=False), nn.Conv2d(OUT[1], FEATURES, 3, padding=1, bias=False)
        self.layer3_rn, self.layer4_rn = nn.Conv2d(OUT[2], FEATURES, 3, padding=1, bias=False), nn.Conv2d(OUT[3], FEATURES, 3, padding=1, bias=False)
        self.refine = nn.ModuleList([Fusion(FEATURES) for _ in range(4)])   # refinenet1..4
        self.iou1, self.iou2 = nn.Linear(FEATURES, 64), nn.Linear(64, 3)
        self.output_conv1 = nn.Conv2d(FEATURES, FEATURES // 2, 3, padding=1)
        self.up_t, self.up_c = nn.ConvTranspose2d(FEATURES // 2, 64, 4, stride=2, padding=1), nn.Conv2d(64, 64, 3, padding=1)
        self.mask_a = nn.ModuleList([nn.Conv2d(64, 32, 3, padding=1) for _ in range(3)])
        self.mask_b = nn.ModuleList([nn.Conv2d(32, 1, 1) for _ in range(3)])

    # ---- weights ------------------------------------------------------------------------------------------------------------
    def load_weights(self, state_dict):
        sd, s = dict(state_dict), self.stream_scale
        own = {}
        def scaled(name, k):
            own[name] = sd[k] * s
        def plain(name, k):
            own[name] = sd[k]
        def conv(name, k):
            plain(name + ".weight", k + ".weight")
            if k + ".bias" in sd: plain(name + ".bias", k + ".bias")
        scaled("cls_token", "encoder.embeddings.cls_token"); scaled("register_tokens", "encoder.embeddings.register_tokens")
        scaled("patch_embeddings.weight", "encoder.embeddings.patch_embeddings.weight"); scaled("patch_embeddings.bias", "encoder.embeddings.patch_embeddings.bias")
        for i in range(LAST_BLOCK + 1):
            e, n = f"encoder.layer.{i}.", f"layers.{i}."
            for m in ("norm1", "norm2"):
                plain(f"{n}{m}.weight", f"{e}{m}.weight"); plain(f"{n}{m}.bias", f"{e}{m}.bias")
            plain(f"{n}attention.k_proj.weight", f"{e}attention.k_proj.weight")
            conv(f"{n}attention.v_proj", f"{e}attention.v_proj")
            q_w, q_b = sd[f"{e}attention.q_proj.weight"], sd[f"{e}attention.q_proj.bias"]
            f = (HD ** -0.5) if self.fold_q_scale else 1.0
            own[f"{n}attention.q_proj.weight"], own[f"{n}attention.q_proj.bias"] = q_w * f, q_b * f
            scaled(f"{n}attention.o_proj.weight", f"{e}attention.o_proj.weight"); scaled(f"{n}attention.o_proj.bias", f"{e}attention.o_proj.bias")
            plain(f"{n}layer_scale1.lambda1", f"{e}layer_scale1.lambda1"); plain(f"{n}layer_scale2.lambda1", f"{e}layer_scale2.lambda1")
            conv(f"{n}mlp.up_proj", f"{e}mlp.up_proj")
            scaled(f"{n}mlp.down_proj.weight", f"{e}mlp.down_proj.weight"); scaled(f"{n}mlp.down_proj.bias", f"{e}mlp.down_proj.bias")
        h = "seg_head."
        for i in range(4):
            own[f"projects.{i}.weight"], own[f"projects.{i}.bias"] = sd[f"{h}projects.{i}.weight"] / s, sd[f"{h}projects.{i}.bias"]
        conv("resize0", h + "resize_layers.0"); conv("resize1", h + "resize_layers.1"); conv("resize3", h + "resize_layers.3")
        for i in (1, 2, 3, 4):
            conv(f"layer{i}_rn", f"{h}scratch.layer{i}_rn")
        bns = []
        for i in range(4):
            f = f"{h}scratch.refinenet{i + 1}."
            conv(f"refine.{i}.out_conv", f + "out_conv")
            for u in ("resConfUnit1", "resConfUnit2"):
                for c in ("conv1", "conv2"):
                    conv(f"refine.{i}.{u}.{c}", f"{f}{u}.{c}")
                for b in ("bn1", "bn2"):
                    bns.append((f"refine.{i}.{u}.{b}", f"{f}{u}.{b}"))
        conv("iou1", h + "classifier_head.2"); conv("iou2", h + "classifier_head.4")
        conv("output_conv1", h + "mask_head.output_conv1")
        conv("up_t", h + "mask_head.upsample_2x.0"); conv("up_c", h + "mask_head.upsample_2x.2")
        for i in range(3):
            conv(f"mask_a.{i}", f"{h}mask_head.mask_heads.{i}.0"); conv(f"mask_b.{i}", f"{h}mask_head.mask_heads.{i}.2")
        missing, unexpected = self.load_state_dict(own, strict=False)
        missing = [k for k in missing if not k.startswith("rope_") and not k.endswith(("scale", "shift"))]
        if missing or unexpected:
            raise ValueError(f"weights do not fit: missing {missing}, unexpected {unexpected}")
        for name, k in bns:
            self.get_submodule(name).set_from(sd[k + ".weight"], sd[k + ".bias"], sd[k + ".running_mean"], sd[k + ".running_var"])
        used = {"encoder.embeddings.cls_token", "encoder.embeddings.register_tokens", "encoder.embeddings.patch_embeddings.weight", "encoder.embeddings.patch_embeddings.bias"}
        dead = [k for k in sd if not (k.startswith(("encoder.layer.", "seg_head.")) or k in used)]
        dead_layers = {k for k in sd if k.startswith(f"encoder.layer.{LAST_BLOCK + 1}.")}
        dead_expected = {"encoder.embeddings.mask_token", "encoder.norm.bias", "encoder.norm.weight"}
        if set(dead) != dead_expected:
            raise ValueError(f"checkpoint keys not used, unexpected: {sorted(set(dead) ^ dead_expected)}")
        if len(dead_layers) != 17:
            raise ValueError(f"expected to drop block {LAST_BLOCK + 1}'s 17 tensors, found {len(dead_layers)}")
        return self

    def to_inference_dtype(self, dt):
        """fp16 graph with its IoU head in float32 (an argmax is taken over it)."""
        self.to(dt)
        self.iou1.float(); self.iou2.float()
        return self

    # ---- graph --------------------------------------------------------------------------------------------------------------
    def encoder_taps(self, image, probe=None):
        dt = self.patch_embeddings.weight.dtype
        x = self.patch_embeddings(image.to(dt)).flatten(2).transpose(1, 2)
        b = x.shape[0]
        x = torch.cat([self.cls_token.expand(b, -1, -1), self.register_tokens.expand(b, -1, -1), x], dim=1)
        cos, sin = self.rope_cos.to(dt), self.rope_sin.to(dt)
        taps = []
        for i, layer in enumerate(self.layers):
            x = layer(x, cos, sin)
            if probe is not None: probe(f"stream.{i}", x)
            if i in TAPS:
                taps.append(x[:, 1 + NREG:].transpose(1, 2).reshape(b, DIM, self.gh, self.gw))
        return taps

    def forward(self, image, probe=None):
        t = self.encoder_taps(image, probe)
        a = [self.projects[i](t[i]) for i in range(4)]
        a[0], a[1], a[3] = self.resize0(a[0]), self.resize1(a[1]), self.resize3(a[3])
        r1, r2, r3, r4 = self.layer1_rn(a[0]), self.layer2_rn(a[1]), self.layer3_rn(a[2]), self.layer4_rn(a[3])
        if probe is not None:
            for n, v in (("projects0", a[0]), ("projects1", a[1]), ("projects2", a[2]), ("projects3", a[3]), ("r1", r1), ("r2", r2), ("r3", r3), ("r4", r4)): probe(n, v)
        p4 = self.refine[3](r4, None, r3.shape[2:])
        p3 = self.refine[2](p4, r3, r2.shape[2:])
        p2 = self.refine[1](p3, r2, r1.shape[2:])
        p1 = self.refine[0](p2, r1, (r1.shape[2] * 2, r1.shape[3] * 2))
        if probe is not None:
            for n, v in (("p4", p4), ("p3", p3), ("p2", p2), ("p1", p1)): probe(n, v)
        td = self.tail_dtype
        iou = self.iou2(F.relu(self.iou1(p1.to(torch.float32).mean(dim=(2, 3)))))
        feat = F.relu(self.up_c(F.relu(self.up_t(self.output_conv1(p1)))))
        masks = torch.cat([self.mask_b[i](F.relu(self.mask_a[i](feat))) for i in range(3)], dim=1)
        if probe is not None: probe("logits", masks); probe("iou_logits", iou)
        return torch.sigmoid(masks.to(td)).to(self.out_dtype), torch.sigmoid(iou)
