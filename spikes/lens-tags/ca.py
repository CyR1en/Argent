"""The raw's own lateral colour against the file's CA curve.

Usage: ca.py ARW ca_knots(32, comma) [corrected.jpg]
Registers our bilinear R and B planes against our G plane (high-passed, normalized) on a grid and
prints the radial shift by ring beside what the file's curve predicts if the correction for channel c
reads it at r (1 + k_c(r) 2^-21): the lens put c's image at r / (1 + k 2^-21), a shift of about
-r k 2^-21. With a JPEG, also the camera's applied correction (JPEG c minus ours c, less the green).
"""
import os
import sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from register import ours, corrected, ncc_shift
from fit import interp


def main():
    arw = sys.argv[1]
    k = [float(v) for v in sys.argv[2].split(',')]
    kr, kb = k[:len(k) // 2], k[len(k) // 2:]
    a = ours(arw)
    H, W = a.shape[1:]
    c = np.array([(W - 1) / 2, (H - 1) / 2])
    rmax = np.hypot(W / 2, H / 2)
    side, reach = 96, 12
    margin = side // 2 + reach + 4
    xs = np.linspace(margin, W - margin, 41).astype(int)
    ys = np.linspace(margin, H - margin, 27).astype(int)
    rows = []
    for cy in ys:
        for cx in xs:
            r = np.hypot(cx - c[0], cy - c[1])
            ux, uy = (cx - c[0]) / max(r, 1), (cy - c[1]) / max(r, 1)
            out = [r / rmax]
            for ch in (0, 2):
                dx, dy, q = ncc_shift(a[1], a[ch], cx, cy, side, reach)
                out += [dx * ux + dy * uy, q]
            rows.append(out)
    rows = np.array(rows)
    print('ring   raw R-G radial (n)   predicted +r kR 2^-21   raw B-G radial (n)   predicted +r kB 2^-21')
    for lo in np.arange(0, 1.0, 0.1):
        m = (rows[:, 0] >= lo) & (rows[:, 0] < lo + 0.1)
        mid = lo + 0.05
        pr = mid * rmax * interp(kr, (len(kr) - 1) * mid, 'linear') / 2 ** 21
        pb = mid * rmax * interp(kb, (len(kb) - 1) * mid, 'linear') / 2 ** 21
        mr, mb = m & (rows[:, 2] > 0.5), m & (rows[:, 4] > 0.5)
        if mr.sum() + mb.sum() == 0:
            continue
        print('%.2f   %+.3f (%3d)          %+.3f                  %+.3f (%3d)          %+.3f'
              % (mid, np.median(rows[mr, 1]) if mr.sum() else np.nan, mr.sum(), pr,
                 np.median(rows[mb, 3]) if mb.sum() else np.nan, mb.sum(), pb))


if __name__ == '__main__':
    main()
