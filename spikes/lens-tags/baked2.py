"""Noise over level by radius on flat blocks: a baked radial gain g multiplies the shot term by g."""
import os
import sys
import numpy as np
import rawpy
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from register import crop_tags
path = sys.argv[1]
(ox, oy), (w, h) = crop_tags(path)
with rawpy.imread(path) as raw:
    m = raw.raw_image.astype(np.float64)[oy:oy + h, ox:ox + w]
    black = raw.black_level_per_channel[0]
g1 = m[0::2, 1::2] - black
g2 = m[1::2, 0::2] - black
H, W = m.shape
qy, qx = np.mgrid[0:H // 2, 0:W // 2]
rq = np.hypot(2 * qx + 0.5 - (W - 1) / 2, 2 * qy + 0.5 - (H - 1) / 2) / np.hypot(W / 2, H / 2)
B = 12
hb, wb = g1.shape[0] // B, g1.shape[1] // B
def blk(a): return a[:hb * B, :wb * B].reshape(hb, B, wb, B)
noise = blk(g1 - g2).var((1, 3)) / 2
lvl = blk(0.5 * (g1 + g2)).mean((1, 3))
# texture: variance of g1 after removing a plane, against the noise
b1 = blk(g1)
yy, xx = np.mgrid[0:B, 0:B]
A = np.stack([np.ones(B * B), xx.ravel(), yy.ravel()], 1)
coef = np.linalg.lstsq(A, b1.transpose(0, 2, 1, 3).reshape(hb, wb, B * B).reshape(-1, B * B).T, rcond=None)[0]
resid = b1.transpose(0, 2, 1, 3).reshape(-1, B * B) - (A @ coef).T
tex = resid.var(1).reshape(hb, wb)
rb = blk(rq).mean((1, 3))
flat = (tex < 1.15 * noise) & (lvl > 300) & (lvl < 12000)
ratio = noise / lvl
print('flat blocks', flat.sum(), 'of', flat.size)
for lo in np.arange(0.0, 1.0, 0.1):
    k = flat & (rb >= lo) & (rb < lo + 0.1)
    if k.sum() >= 5:
        print('r %.1f-%.1f  noise/level median %.3f  (n %4d, level median %5.0f)  read-corrected %.3f' % (lo, lo + 0.1, np.median(ratio[k]), k.sum(), np.median(lvl[k]), np.median((noise[k] - 4.0) / lvl[k])))
