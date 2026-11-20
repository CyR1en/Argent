"""Does the channel registration recover a known radial scale? Resample our R plane by r -> r (1 + e)
(e = 2 px at the corner) and measure R-G before and after."""
import os
import sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from register import ours, ncc_shift
from vignette import bilinear
a = ours(sys.argv[1])
H, W = a.shape[1:]
c = np.array([(W - 1) / 2, (H - 1) / 2]); rmax = np.hypot(W / 2, H / 2)
e = 2.0 / rmax
yy, xx = np.mgrid[0:H, 0:W].astype(np.float64)
# The feature at p moves to p (1 + e): out(q) = in(c + (q - c) / (1 + e)).
moved = bilinear(a[0], c[0] + (xx - c[0]) / (1 + e), c[1] + (yy - c[1]) / (1 + e)).astype(np.float32)
side, reach = 96, 12
margin = side // 2 + reach + 4
res = []
for cy in np.linspace(margin, H - margin, 21).astype(int):
    for cx in np.linspace(margin, W - margin, 31).astype(int):
        r = np.hypot(cx - c[0], cy - c[1]); ux, uy = (cx - c[0]) / max(r, 1), (cy - c[1]) / max(r, 1)
        d0 = ncc_shift(a[1], a[0], cx, cy, side, reach)
        d1 = ncc_shift(a[1], moved, cx, cy, side, reach)
        s0 = ncc_shift(a[0], moved, cx, cy, side, reach)
        res.append((r / rmax, d0[0] * ux + d0[1] * uy, d1[0] * ux + d1[1] * uy, s0[0] * ux + s0[1] * uy, d0[2]))
res = np.array(res)
print('ring  applied  measured change of R-G  R against its own unmoved plane')
for lo in np.arange(0, 1, 0.1):
    m = (res[:, 0] >= lo) & (res[:, 0] < lo + 0.1) & (res[:, 4] > 0.5)
    if m.sum():
        print('%.2f  %+.3f   %+.3f                  %+.3f  (n %d)' % (lo + 0.05, 2.0 * (lo + 0.05), np.median(res[m, 2] - res[m, 1]), np.median(res[m, 3]), m.sum()))
