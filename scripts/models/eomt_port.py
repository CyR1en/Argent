"""EoMT-DINOv3-L/16, ADE20K-150 semantic head, written for inference and for Core AI conversion. Needs only torch and safetensors.

Weights: Hugging Face `tue-mps/eomt-dinov3-ade-semantic-large-512` (key names are kept, so `load_file` fits `load_state_dict`).
The graph is Hugging Face's `EomtDinov3ForUniversalSegmentation` (transformers 5.22.1) with these changes, and only these:
  1. The masked-attention branch of the last four blocks is dropped. In that code it runs only when `attn_mask_probs[i] > 0`, and the checkpoint stores
     [-1, -1, -1, -1], so at inference the attention mask is None and the branch is dead. `load_weights` refuses a checkpoint where it is not.
     (A data-dependent `if` on a buffer cannot be traced by torch.export, which is why it is removed rather than left in.)
  2. The rotary tables depend only on the input size, so they are computed once in fp32 (as Hugging Face computes them, then cast) and kept as constants.
  3. `grid_size` is the fixed (H/16, W/16) of the input the model is built for. Nothing else in the graph depends on the input size.
  4. The semantic map is made inside the graph: softmax(class logits)[..., :-1] contracted with sigmoid(mask logits), normalised over the 150 classes,
     as S4 / R4 made it in PyTorch (`sc / sc.sum(1).clamp_min(1e-6)`). The last contraction and the normalisation run in float32 even in an fp16 model.
  5. fp16 (the reason this file differs from Hugging Face's in anything but form): DINOv3's residual stream carries a massive activation of about 132,000 from
     block 0 on (block 0's MLP output is 44,682 before layer scale and 132,118 after), twice fp16's 65,504, so a plain fp16 conversion returns NaN everywhere.
     `stream_scale` s folds a constant factor into every weight that writes to the stream (patch embedding, cls and register tokens, the queries, each block's
     o_proj and down_proj), so the stream is s times the original; every LayerNorm that reads it gets eps * s^2, which makes it exactly the original LayerNorm,
     and it is computed in float32. `fold_q_scale` folds the attention scale 1/sqrt(64) into q_proj so no intermediate holds an unscaled q.k. Both are exact
     re-parametrisations (checked in float32 against the unscaled graph, max difference printed by check_scaled.py).
Output, `outputs="full"`: (1, 150, H/4, W/4) class probabilities (sum over classes = 1).
Output, `outputs="compact"` (what ships): (1, 3, H/4, W/4) float16, channel 0 = the summed probability of the water classes (`water_ids`), channel 1 = the sky class, channel 2 = the
index of the most probable class (0..149, exact in fp16). 0.4 MB instead of 39 MB a call at 1024 x 1024, which also removes the runtime's per-call output buffer growth (measured).
Input: (1, 3, H, W), ImageNet-normalised ((x/255 - mean)/std), H and W multiples of 16.
"""
import math
import torch
import torch.nn as nn
import torch.nn.functional as F

DIM, DEPTH, HEADS, MLP, NQ, NREG, NBLOCKS, NCLS, PATCH, THETA, EPS = 1024, 24, 16, 4096, 100, 4, 4, 150, 16, 100.0, 1e-5


def rotate_half(x):
    x1, x2 = x[..., : x.shape[-1] // 2], x[..., x.shape[-1] // 2:]
    return torch.cat((-x2, x1), dim=-1)


def rope_tables(gh, gw, head_dim=DIM // HEADS, theta=THETA):
    """cos, sin of shape (gh*gw, head_dim), float32: HF's EomtDinov3RotaryEmbedding.forward in eval mode (no shift, jitter or rescale)."""
    ch = torch.arange(0.5, gh, dtype=torch.float32) / gh
    cw = torch.arange(0.5, gw, dtype=torch.float32) / gw
    coords = torch.stack(torch.meshgrid(ch, cw, indexing="ij"), dim=-1).flatten(0, 1)
    coords = 2.0 * coords - 1.0
    inv_freq = 1 / theta ** torch.arange(0, 1, 4 / head_dim, dtype=torch.float32)
    angles = (2 * math.pi * coords[:, :, None] * inv_freq[None, None, :]).flatten(1, 2).tile(2)
    return torch.cos(angles), torch.sin(angles)


class StreamNorm(nn.LayerNorm):
    """LayerNorm computed in float32 whatever the input dtype (the stream holds values whose squares overflow fp16)."""
    def forward(self, x):
        return F.layer_norm(x.float(), self.normalized_shape, self.weight.float(), self.bias.float(), self.eps).to(x.dtype)


class Attention(nn.Module):
    def __init__(self, sdpa_scale=None):
        super().__init__()
        self.sdpa_scale = sdpa_scale
        self.k_proj = nn.Linear(DIM, DIM, bias=False)
        self.v_proj = nn.Linear(DIM, DIM, bias=True)
        self.q_proj = nn.Linear(DIM, DIM, bias=True)
        self.o_proj = nn.Linear(DIM, DIM, bias=True)

    def forward(self, x, cos, sin):
        b, n, _ = x.shape
        hd = DIM // HEADS
        q = self.q_proj(x).view(b, n, HEADS, hd).transpose(1, 2)
        k = self.k_proj(x).view(b, n, HEADS, hd).transpose(1, 2)
        v = self.v_proj(x).view(b, n, HEADS, hd).transpose(1, 2)
        npatch = cos.shape[-2]
        npre = n - npatch                       # cls + registers (+ the 100 queries in the last four blocks)
        qp, qx = q.split((npre, npatch), dim=-2)
        kp, kx = k.split((npre, npatch), dim=-2)
        qx = qx * cos + rotate_half(qx) * sin   # rotary on patch tokens only
        kx = kx * cos + rotate_half(kx) * sin
        q = torch.cat((qp, qx), dim=-2)
        k = torch.cat((kp, kx), dim=-2)
        o = F.scaled_dot_product_attention(q, k, v, scale=self.sdpa_scale)
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
    def __init__(self, eps=EPS, sdpa_scale=None):
        super().__init__()
        self.norm1 = StreamNorm(DIM, eps=eps)
        self.attention = Attention(sdpa_scale)
        self.layer_scale1 = LayerScale()
        self.norm2 = StreamNorm(DIM, eps=eps)
        self.mlp = Mlp()
        self.layer_scale2 = LayerScale()

    def forward(self, x, cos, sin):
        x = x + self.layer_scale1(self.attention(self.norm1(x), cos, sin))
        x = x + self.layer_scale2(self.mlp(self.norm2(x)))
        return x


class Embeddings(nn.Module):
    def __init__(self):
        super().__init__()
        self.cls_token = nn.Parameter(torch.zeros(1, 1, DIM))
        self.register_tokens = nn.Parameter(torch.zeros(1, NREG, DIM))
        self.patch_embeddings = nn.Conv2d(3, DIM, kernel_size=PATCH, stride=PATCH)


class LayerNorm2d(nn.LayerNorm):
    def __init__(self, c, eps=1e-6):
        super().__init__(c, eps=eps)

    def forward(self, x):
        return F.layer_norm(x.permute(0, 2, 3, 1), self.normalized_shape, self.weight, self.bias, self.eps).permute(0, 3, 1, 2)


class ScaleLayer(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.ConvTranspose2d(DIM, DIM, kernel_size=2, stride=2)
        self.conv2 = nn.Conv2d(DIM, DIM, kernel_size=3, padding=1, groups=DIM, bias=False)
        self.layernorm2d = LayerNorm2d(DIM)

    def forward(self, x):
        return self.layernorm2d(self.conv2(F.gelu(self.conv1(x))))


class ScaleBlock(nn.Module):
    def __init__(self):
        super().__init__()
        self.block = nn.ModuleList([ScaleLayer(), ScaleLayer()])

    def forward(self, x):
        for b in self.block:
            x = b(x)
        return x


class MaskHead(nn.Module):
    def __init__(self):
        super().__init__()
        self.fc1, self.fc2, self.fc3 = nn.Linear(DIM, DIM), nn.Linear(DIM, DIM), nn.Linear(DIM, DIM)

    def forward(self, x):
        return self.fc3(F.gelu(self.fc2(F.gelu(self.fc1(x)))))


class EomtL(nn.Module):
    def __init__(self, height, width, tail_dtype=torch.float32, stream_scale=1.0, fold_q_scale=False, outputs="full", water_ids=(21, 26, 60, 128, 113, 109, 104), sky_id=2):
        super().__init__()
        assert height % PATCH == 0 and width % PATCH == 0
        self.gh, self.gw = height // PATCH, width // PATCH
        self.tail_dtype = tail_dtype
        self.stream_scale, self.fold_q_scale = float(stream_scale), bool(fold_q_scale)
        self.outputs, self.water_ids, self.sky_id = outputs, list(water_ids), int(sky_id)
        eps = EPS * self.stream_scale ** 2
        sdpa_scale = 1.0 if fold_q_scale else None
        self.embeddings = Embeddings()
        self.layernorm = StreamNorm(DIM, eps=eps)
        self.query = nn.Embedding(NQ, DIM)
        self.layers = nn.ModuleList([Layer(eps, sdpa_scale) for _ in range(DEPTH)])
        self.upscale_block = ScaleBlock()
        self.mask_head = MaskHead()
        self.class_predictor = nn.Linear(DIM, NCLS + 1)
        cos, sin = rope_tables(self.gh, self.gw)
        self.register_buffer("rope_cos", cos, persistent=False)
        self.register_buffer("rope_sin", sin, persistent=False)

    def load_weights(self, tensors):
        probs = tensors["attn_mask_probs"]
        if not bool((probs <= 0).all()):
            raise ValueError(f"attn_mask_probs {probs.tolist()}: the masked-attention branch is live, and this port drops it")
        sd = {k: v.clone() for k, v in tensors.items() if k not in ("attn_mask_probs", "criterion.empty_weight")}
        sc = self.stream_scale
        if sc != 1.0:
            for k in sd:
                if (k.startswith("embeddings.patch_embeddings.") or k in ("embeddings.cls_token", "embeddings.register_tokens", "query.weight")
                        or (k.startswith("layers.") and (".attention.o_proj." in k or ".mlp.down_proj." in k))):
                    sd[k] = sd[k] * sc
        if self.fold_q_scale:
            for k in sd:
                if k.startswith("layers.") and ".attention.q_proj." in k:
                    sd[k] = sd[k] * ((DIM // HEADS) ** -0.5)
        missing, unexpected = self.load_state_dict(sd, strict=False)
        missing = [k for k in missing if not k.startswith("rope_")]
        if missing or unexpected:
            raise ValueError(f"weights do not fit: missing {missing}, unexpected {unexpected}")
        return self

    def forward(self, image):
        dt = self.embeddings.patch_embeddings.weight.dtype
        x = self.embeddings.patch_embeddings(image.to(dt)).flatten(2).transpose(1, 2)
        b = x.shape[0]
        x = torch.cat([self.embeddings.cls_token.expand(b, -1, -1), self.embeddings.register_tokens.expand(b, -1, -1), x], dim=1)
        cos, sin = self.rope_cos.to(dt), self.rope_sin.to(dt)
        for i, layer in enumerate(self.layers):
            if i == DEPTH - NBLOCKS:
                x = torch.cat([self.query.weight[None].expand(b, -1, -1), x], dim=1)
            x = layer(x, cos, sin)
        x = self.layernorm(x)
        q = x[:, :NQ]
        cls_logits = self.class_predictor(q)                                              # (b, 100, 151)
        p = x[:, NQ + 1 + NREG:].transpose(1, 2).reshape(b, DIM, self.gh, self.gw)
        p = self.upscale_block(p)                                                         # (b, 1024, 4gh, 4gw)
        qm = self.mask_head(q)                                                            # (b, 100, 1024)
        h4, w4 = p.shape[-2], p.shape[-1]
        mask_logits = torch.matmul(qm, p.reshape(b, DIM, h4 * w4))                       # (b, 100, h4*w4)
        td = self.tail_dtype
        cp = torch.softmax(cls_logits.to(td), dim=-1)[..., :-1]                           # (b, 100, 150)
        mp = torch.sigmoid(mask_logits.to(td))                                            # (b, 100, h4*w4)
        sem = torch.matmul(cp.transpose(1, 2), mp)                                        # (b, 150, h4*w4)
        sem = sem / sem.sum(dim=1, keepdim=True).clamp_min(1e-6)
        sem = sem.reshape(b, NCLS, h4, w4)
        if self.outputs == "full":
            return sem
        water = sem[:, self.water_ids].sum(dim=1)
        sky = sem[:, self.sky_id]
        cls = sem.argmax(dim=1).to(sem.dtype)
        return torch.stack([water, sky, cls], dim=1).to(torch.float16)
