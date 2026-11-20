"""Is a radial gain baked into the raw? Per ring of the crop: the share of empty codes among raw values
in a busy range, and the shot-noise slope from green-pair differences (var(G1 - G2)/2 against level).

Usage: baked.py ARW
"""
import os
import sys
import numpy as np
import rawpy
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from register import crop_tags


def main():
    path = sys.argv[1]
    (ox, oy), (w, h) = crop_tags(path)
    with rawpy.imread(path) as raw:
        m = raw.raw_image.astype(np.int32)[oy:oy + h, ox:ox + w]
        black = raw.black_level_per_channel[0]
    H, W = m.shape
    yy, xx = np.mgrid[0:H, 0:W]
    rr = np.hypot(xx - (W - 1) / 2, yy - (H - 1) / 2) / np.hypot(W / 2, H / 2)
    # Green sites of an RGGB crop: (0, 1) and (1, 0) in each quad.
    g1 = m[0::2, 1::2].astype(np.float64) - black
    g2 = m[1::2, 0::2].astype(np.float64) - black
    rq = rr[0::2, 0::2]
    print('ring   empty codes in [black+200, black+1200) at green sites   shot slope (var/level), read (DN^2)')
    for lo, hi in [(0, 0.2), (0.2, 0.4), (0.4, 0.6), (0.6, 0.75), (0.75, 0.85), (0.85, 0.92), (0.92, 1.01)]:
        sel = (rq >= lo) & (rq < hi)
        vals = np.concatenate([g1[sel], g2[sel]]).astype(int)
        band = vals[(vals >= 200) & (vals < 1200)]
        counts = np.bincount(band - 200, minlength=1000)
        empty = (counts == 0).mean()
        # Noise: 8x8-quad blocks of the pair difference, binned by level.
        d = (g1 - g2)
        lvl = 0.5 * (g1 + g2)
        B = 8
        hb, wb = d.shape[0] // B, d.shape[1] // B
        def blk(a):
            return a[:hb * B, :wb * B].reshape(hb, B, wb, B)
        dv = blk(d).var((1, 3)) / 2
        lv = blk(lvl).mean((1, 3))
        rb = blk(rq).mean((1, 3))
        sb = (rb >= lo) & (rb < hi) & (lv > 50) & (lv < 6000)
        # Lowest tenth of variance per level bin, as SensorNoise does, then a line.
        bins = np.geomspace(50, 6000, 18)
        xs, ys = [], []
        for i in range(len(bins) - 1):
            k = sb & (lv >= bins[i]) & (lv < bins[i + 1])
            if k.sum() >= 30:
                v = np.sort(dv[k])[: max(3, k.sum() // 10)]
                xs.append(lv[k].mean())
                ys.append(v.mean())
        xs, ys = np.array(xs), np.array(ys)
        if len(xs) >= 3:
            A = np.stack([xs, np.ones_like(xs)], 1)
            slope, read = np.linalg.lstsq(A, ys, rcond=None)[0]
        else:
            slope = read = float('nan')
        print('%.2f-%.2f   %.3f of %d codes (n %7d)                         %.4f, %.1f  (bins %d)'
              % (lo, hi, empty, 1000, band.size, slope, read, len(xs)))


if __name__ == '__main__':
    main()
