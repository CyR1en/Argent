"""Smoothness of the raw code histogram by ring: a digital gain applied to integer samples would leave a comb."""
import os
import sys
import numpy as np
import rawpy
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from register import crop_tags
path = sys.argv[1]
(ox, oy), (w, h) = crop_tags(path)
with rawpy.imread(path) as raw:
    m = raw.raw_image.astype(np.int64)[oy:oy + h, ox:ox + w]
H, W = m.shape
yy, xx = np.mgrid[0:H, 0:W]
rr = np.hypot(xx - (W - 1) / 2, yy - (H - 1) / 2) / np.hypot(W / 2, H / 2)
for lo, hi in [(0, 0.3), (0.3, 0.5), (0.5, 0.7), (0.7, 0.85), (0.85, 1.01)]:
    v = m[(rr >= lo) & (rr < hi)]
    lo_c, hi_c = 600, 2600
    c = np.bincount(v[(v >= lo_c) & (v < hi_c)] - lo_c, minlength=hi_c - lo_c).astype(float)
    k = np.ones(15) / 15
    smooth = np.convolve(c, k, mode='same')
    ok = slice(10, -10)
    rel = (c[ok] - smooth[ok]) / np.sqrt(np.maximum(smooth[ok], 1))
    spec = np.abs(np.fft.rfft(c[ok] / smooth[ok] - 1))
    peak = np.argmax(spec[5:]) + 5
    print('r %.2f-%.2f: samples %8d, counts per code %6.0f, excess scatter %.2f (1 = Poisson), strongest period %.2f codes (power %.1f x median)'
          % (lo, hi, c.sum(), c.mean(), rel.std(), len(rel) / peak, spec[peak] / np.median(spec[5:])))
