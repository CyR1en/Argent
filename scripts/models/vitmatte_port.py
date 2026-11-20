"""Y2: ViTMatte-S as a plain torch graph for one fixed tile, modelled on V4's s3od_port.py: torch only, no transformers.
Fixed 1 x 4 x T x T input (3 normalised RGB channels, mean .5, std .5; the trimap in [0, 1]), output "alpha" 1 x 1 x T x T. Position and relative-position tables and BatchNorm are constants made at load from the checkpoint, in fp32."""
import math
import torch
import torch.nn as nn
import torch.nn.functional as F

WINDOW_BLOCKS = {0, 1, 3, 4, 6, 7, 9, 10}
RES_BLOCKS = {2, 5, 8, 11}
WINDOW = 14
CONV = [48, 96, 192]
FUSION = [256, 128, 64, 32]


class BN(nn.Module):
    def __init__(self, ch):
        super().__init__()
        self.register_buffer('w', torch.ones(ch)); self.register_buffer('b', torch.zeros(ch)); self.register_buffer('m', torch.zeros(ch)); self.register_buffer('v', torch.ones(ch))

    def load(self, sd, p):
        eps = 1e-5
        self.w.copy_(sd[p + 'weight'] / torch.sqrt(sd[p + 'running_var'] + eps)); self.b.copy_(sd[p + 'bias'] - sd[p + 'weight'] * sd[p + 'running_mean'] / torch.sqrt(sd[p + 'running_var'] + eps))

    def forward(self, x):
        return x * self.w.reshape(1, -1, 1, 1) + self.b.reshape(1, -1, 1, 1)


class CBR(nn.Module):
    def __init__(self, a, b, stride):
        super().__init__(); self.conv = nn.Conv2d(a, b, 3, stride=stride, padding=1, bias=False); self.bn = BN(b)

    def forward(self, x):
        return F.relu(self.bn(self.conv(x)))


class LN2d(nn.Module):
    def __init__(self, ch):
        super().__init__(); self.weight = nn.Parameter(torch.ones(ch)); self.bias = nn.Parameter(torch.zeros(ch)); self.eps = 1e-6

    def forward(self, x):
        u = x.mean(1, keepdim=True); s = (x - u).pow(2).mean(1, keepdim=True); x = (x - u) / torch.sqrt(s + self.eps)
        return self.weight.reshape(1, -1, 1, 1) * x + self.bias.reshape(1, -1, 1, 1)


class Res(nn.Module):
    def __init__(self, d, b):
        super().__init__()
        self.conv1 = nn.Conv2d(d, b, 1, bias=False); self.norm1 = LN2d(b); self.conv2 = nn.Conv2d(b, b, 3, padding=1, bias=False); self.norm2 = LN2d(b); self.conv3 = nn.Conv2d(b, d, 1, bias=False); self.norm3 = LN2d(d)

    def forward(self, x):
        y = F.gelu(self.norm1(self.conv1(x))); y = F.gelu(self.norm2(self.conv2(y))); return x + self.norm3(self.conv3(y))


def resized_rel(rel, n):
    need = 2 * n - 1
    if rel.shape[0] == need: return rel
    return F.interpolate(rel.reshape(1, rel.shape[0], -1).permute(0, 2, 1), size=need, mode='linear').reshape(-1, need).permute(1, 0)


class Attention(nn.Module):
    def __init__(self, dim, heads):
        super().__init__(); self.heads = heads; self.scale = (dim // heads) ** -0.5; self.qkv = nn.Linear(dim, dim * 3, bias=True); self.proj = nn.Linear(dim, dim)
        self.register_buffer('rel_h', None, persistent=False); self.register_buffer('rel_w', None, persistent=False)

    def set_rel(self, rel_h, rel_w, n):
        # q, k arange 0..n-1: relative index = q - k + n - 1, a fixed table of shape (n, n, head_dim).
        rh, rw = resized_rel(rel_h, n), resized_rel(rel_w, n)
        idx = (torch.arange(n)[:, None] - torch.arange(n)[None, :]) + (n - 1)
        self.rel_h = rh[idx].permute(0, 2, 1); self.rel_w = rw[idx].permute(0, 2, 1)  # (n, head_dim, n)

    def forward(self, x):
        B, H, W, C = x.shape; n = H * W; H2 = self.heads
        qkv = self.qkv(x).reshape(B, n, 3, H2, -1).permute(2, 0, 3, 1, 4).reshape(3, B * H2, n, -1)
        q, k, v = qkv[0], qkv[1], qkv[2]
        a = (q * self.scale) @ k.transpose(-2, -1)
        rq = q.reshape(B * H2, H, W, -1)
        rh = rq @ self.rel_h                                   # (BH, H, W, K_h)
        rw = (rq.permute(0, 2, 1, 3) @ self.rel_w).permute(0, 2, 1, 3)   # (BH, H, W, K_w)
        a = (a.reshape(B * H2, H, W, H, W) + rh.reshape(B * H2, H, W, H, 1) + rw.reshape(B * H2, H, W, 1, W)).reshape(B * H2, n, n)
        a = a.softmax(-1)
        y = (a @ v).reshape(B, H2, H, W, -1).permute(0, 2, 3, 1, 4).reshape(B, H, W, -1)
        return self.proj(y)


class Layer(nn.Module):
    def __init__(self, dim, heads, index):
        super().__init__(); self.win = WINDOW if index in WINDOW_BLOCKS else 0
        self.norm1 = nn.LayerNorm(dim, eps=1e-6); self.attention = Attention(dim, heads); self.norm2 = nn.LayerNorm(dim, eps=1e-6)
        self.fc1 = nn.Linear(dim, dim * 4); self.fc2 = nn.Linear(dim * 4, dim)
        self.res = Res(dim, dim // 2) if index in RES_BLOCKS else None

    def forward(self, x):
        h = x; x = self.norm1(x); H, W = x.shape[1], x.shape[2]
        if self.win:
            ph, pw = (-H) % self.win, (-W) % self.win
            if ph or pw: x = F.pad(x, (0, 0, 0, pw, 0, ph))
            HH, WW = H + ph, W + pw; nh, nw = HH // self.win, WW // self.win
            x = x.reshape(1, nh, self.win, nw, self.win, -1).permute(0, 1, 3, 2, 4, 5).reshape(nh * nw, self.win, self.win, -1)
            x = self.attention(x)
            x = x.reshape(1, nh, nw, self.win, self.win, -1).permute(0, 1, 3, 2, 4, 5).reshape(1, HH, WW, -1)[:, :H, :W, :]
        else:
            x = self.attention(x)
        x = h + x
        x = x + self.fc2(F.gelu(self.fc1(self.norm2(x))))
        if self.res is not None: x = self.res(x.permute(0, 3, 1, 2)).permute(0, 2, 3, 1)
        return x


class VitMatteS(nn.Module):
    def __init__(self, tile=1024, dim=384, heads=6, depth=12, pretrain=224):
        super().__init__(); self.tile = tile; self.tokens = tile // 16; self.pretrain = pretrain // 16
        self.proj = nn.Conv2d(4, dim, 16, 16)
        self.register_buffer('pos', torch.zeros(1, self.tokens, self.tokens, dim), persistent=False)
        self.layers = nn.ModuleList(Layer(dim, heads, i) for i in range(depth))
        self.cs = nn.ModuleList([CBR(4, CONV[0], 2), CBR(CONV[0], CONV[1], 2), CBR(CONV[1], CONV[2], 2)])
        chans = [4] + CONV; f = [dim] + FUSION
        self.fuse = nn.ModuleList(CBR(f[i] + chans[-(i + 1)], f[i + 1], 1) for i in range(len(FUSION)))
        self.head1 = nn.Conv2d(FUSION[-1], 16, 3, padding=1); self.headbn = BN(16); self.head2 = nn.Conv2d(16, 1, 1)

    def load_weights(self, sd):
        sd = {k: v.float() for k, v in sd.items() if 'num_batches_tracked' not in k}
        used = set(); get = lambda k: (used.add(k), sd[k])[1]
        pos = get('backbone.embeddings.position_embeddings')[:, 1:]; n = int(math.sqrt(pos.shape[1]))
        self.pos = F.interpolate(pos.reshape(1, n, n, -1).permute(0, 3, 1, 2), size=(self.tokens, self.tokens), mode='bicubic', align_corners=False).permute(0, 2, 3, 1)
        self.proj.weight.data.copy_(get('backbone.embeddings.projection.weight')); self.proj.bias.data.copy_(get('backbone.embeddings.projection.bias'))
        for i, l in enumerate(self.layers):
            p = f'backbone.encoder.layer.{i}.'
            for a, b in ((l.norm1, 'norm1'), (l.norm2, 'norm2')): a.weight.data.copy_(get(p + b + '.weight')); a.bias.data.copy_(get(p + b + '.bias'))
            for a, b in ((l.attention.qkv, 'attention.qkv'), (l.attention.proj, 'attention.proj'), (l.fc1, 'mlp.fc1'), (l.fc2, 'mlp.fc2')): a.weight.data.copy_(get(p + b + '.weight')); a.bias.data.copy_(get(p + b + '.bias'))
            l.attention.set_rel(get(p + 'attention.rel_pos_h'), get(p + 'attention.rel_pos_w'), l.win or self.tokens)
            if l.res is not None:
                r = p + 'residual.'
                for name in ('conv1', 'conv2', 'conv3'): getattr(l.res, name).weight.data.copy_(get(r + name + '.weight'))
                for name in ('norm1', 'norm2', 'norm3'): getattr(l.res, name).weight.data.copy_(get(r + name + '.weight')); getattr(l.res, name).bias.data.copy_(get(r + name + '.bias'))
        def cbr(c, p):
            c.conv.weight.data.copy_(get(p + 'conv.weight'))
            for k in ('weight', 'bias', 'running_mean', 'running_var'): used.add(p + 'batch_norm.' + k)
            c.bn.load(sd, p + 'batch_norm.')
        for i, c in enumerate(self.cs): cbr(c, f'decoder.convstream.convs.{i}.')
        for i, c in enumerate(self.fuse): cbr(c, f'decoder.fusion_blocks.{i}.conv.')
        self.head1.weight.data.copy_(get('decoder.matting_head.matting_convs.0.weight')); self.head1.bias.data.copy_(get('decoder.matting_head.matting_convs.0.bias'))
        for k in ('weight', 'bias', 'running_mean', 'running_var'): used.add('decoder.matting_head.matting_convs.1.' + k)
        self.headbn.load(sd, 'decoder.matting_head.matting_convs.1.')
        self.head2.weight.data.copy_(get('decoder.matting_head.matting_convs.3.weight')); self.head2.bias.data.copy_(get('decoder.matting_head.matting_convs.3.bias'))
        left = set(sd) - used
        assert not left, f'unused weights: {sorted(left)[:12]}'
        return self

    def to_inference_dtype(self, dt):
        for n, b in list(self.named_buffers()): 
            pass
        return self.to(dt)

    def forward(self, image):
        x = self.proj(image).permute(0, 2, 3, 1) + self.pos
        for l in self.layers: x = l(x)
        x = x.permute(0, 3, 1, 2)
        ds = [image]; y = image
        for c in self.cs: y = c(y); ds.append(y)
        for i, c in enumerate(self.fuse):
            x = c(torch.cat([ds[-(i + 1)], F.interpolate(x, scale_factor=2.0, mode='bilinear', align_corners=False)], 1))
        return torch.sigmoid(self.head2(F.relu(self.headbn(self.head1(x)))))
