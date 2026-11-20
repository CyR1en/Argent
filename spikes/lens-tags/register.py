"""Displacement field between a raw decode (ours, uncorrected) and a corrected rendering of the same frame.

Usage: python -I register.py ARW CORRECTED.(jpg|npy) OUT.npz [grid_x grid_y patch reach]

ours: a bilinear demosaic of the raw's DefaultCrop, per channel, linear camera RGB, gamma 1/2.2.
corrected: the camera's embedded JPEG (or a float array of Apple's decode, rows top-down).
For each grid point and channel, the shift (dx, dy) such that corrected[p + d] matches ours[p],
by normalized cross-correlation of high-passed patches, refined by a parabola.
"""
import os
import sys
import numpy as np
import rawpy
from PIL import Image


def crop_tags(path):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from tags import TIFF
    t = TIFF(path)
    ifd0, _ = t.ifd(t.first)
    for off in t.values(ifd0[0x014A]):
        sub, _ = t.ifd(off)
        if 0xC61F in sub:
            return t.values(sub[0xC61F]), t.values(sub[0xC620])
    raise SystemExit('no crop')


def ours(path):
    (ox, oy), (w, h) = crop_tags(path)
    with rawpy.imread(path) as raw:
        m = raw.raw_image.astype(np.float32)
        pattern = raw.raw_pattern  # colour index per 2x2 position
        colors = raw.color_desc
        black = np.array(raw.black_level_per_channel, np.float32)
        white = float(raw.white_level)
    # rawpy's raw_image is the stored area; crop with a 2-px margin for interpolation.
    m = m[oy - 2:oy + h + 2, ox - 2:ox + w + 2]
    H, W = m.shape
    yy, xx = np.mgrid[0:H, 0:W]
    idx = pattern[(yy + oy - 2) % 2, (xx + ox - 2) % 2]
    names = [chr(c) for c in colors]
    out = np.zeros((3, H, W), np.float32)
    for c, name in enumerate('RGB'):
        mask = np.zeros((H, W), bool)
        for k, n in enumerate(names):
            if n == name:
                mask |= idx == k
        v = np.where(mask, (m - black[idx]) / (white - black[idx]), 0).astype(np.float32)
        wgt = mask.astype(np.float32)
        # Bilinear: 3x3 weighted mean of samples of this colour.
        k1 = np.array([0.5, 1.0, 0.5], np.float32)
        def sep(a):
            b = a * k1[1]
            b[:, 1:] += a[:, :-1] * k1[0]
            b[:, :-1] += a[:, 1:] * k1[2]
            c = b * k1[1]
            c[1:, :] += b[:-1, :] * k1[0]
            c[:-1, :] += b[1:, :] * k1[2]
            return c
        out[c] = sep(v) / np.maximum(sep(wgt), 1e-6)
    out = out[:, 2:-2, 2:-2]
    gains = np.array([2.48, 1.0, 1.63], np.float32)[:, None, None]
    return np.clip(out * gains * 2.0, 0, None) ** (1 / 2.2)


def corrected(path):
    if path.endswith('.npy'):
        a = np.load(path).astype(np.float32)
        return np.clip(a, 0, None).transpose(2, 0, 1)[:3] ** (1 / 2.2)
    im = np.asarray(Image.open(path).convert('RGB'), np.float32) / 255.0
    return im.transpose(2, 0, 1)


def highpass(p):
    q = p.copy()
    q[1:-1, 1:-1] = p[1:-1, 1:-1] - 0.25 * (p[:-2, 1:-1] + p[2:, 1:-1] + p[1:-1, :-2] + p[1:-1, 2:])
    q[0, :] = q[-1, :] = 0
    q[:, 0] = q[:, -1] = 0
    return q


def ncc_shift(ref, img, cx, cy, side, reach):
    """Shift d with img[p + d] ~ ref[p] around (cx, cy)."""
    x0, y0 = cx - side // 2, cy - side // 2
    a = highpass(ref[y0:y0 + side, x0:x0 + side])
    a = (a - a.mean())
    a /= np.sqrt((a * a).sum()) + 1e-12
    big = highpass(img[y0 - reach:y0 + side + reach, x0 - reach:x0 + side + reach])
    n = side + 2 * reach
    # Correlation via FFT, then normalize by the local energy of big.
    fa = np.fft.rfft2(a, (n, n))
    fb = np.fft.rfft2(big, (n, n))
    corr = np.fft.irfft2(np.conj(fa) * fb, (n, n))[:2 * reach + 1, :2 * reach + 1]
    sq = np.cumsum(np.cumsum(np.pad(big * big, ((1, 0), (1, 0))), 0), 1)
    sm = np.cumsum(np.cumsum(np.pad(big, ((1, 0), (1, 0))), 0), 1)
    def window(s):
        return s[side:side + 2 * reach + 1, side:side + 2 * reach + 1] - s[:2 * reach + 1, side:side + 2 * reach + 1] \
            - s[side:side + 2 * reach + 1, :2 * reach + 1] + s[:2 * reach + 1, :2 * reach + 1]
    energy = window(sq) - window(sm) ** 2 / (side * side)
    score = corr / np.sqrt(np.maximum(energy, 1e-12))
    j, i = np.unravel_index(np.argmax(score), score.shape)
    best = score[j, i]
    def vertex(a, b, c):
        d = a - 2 * b + c
        return 0 if abs(d) < 1e-12 else 0.5 * (a - c) / d
    fx = i - reach + (vertex(score[j, i - 1], best, score[j, i + 1]) if 0 < i < 2 * reach else 0)
    fy = j - reach + (vertex(score[j - 1, i], best, score[j + 1, i]) if 0 < j < 2 * reach else 0)
    return fx, fy, best


def main():
    arw, cor, out = sys.argv[1:4]
    gx, gy, side, reach = (int(v) for v in (sys.argv[4:8] if len(sys.argv) > 4 else (21, 14, 96, 24)))
    a = corrected(arw) if arw.endswith('.npy') else ours(arw)
    b = corrected(cor)
    assert a.shape == b.shape, (a.shape, b.shape)
    H, W = a.shape[1:]
    margin = side // 2 + reach + 4
    xs = np.linspace(margin, W - margin, gx).astype(int)
    ys = np.linspace(margin, H - margin, gy).astype(int)
    res = np.zeros((gy, gx, 3, 3))
    for j, cy in enumerate(ys):
        for i, cx in enumerate(xs):
            for c in range(3):
                res[j, i, c] = ncc_shift(a[c], b[c], cx, cy, side, reach)
    np.savez(out, xs=xs, ys=ys, res=res, W=W, H=H)
    print('saved', out, 'median corr', np.median(res[..., 2]))


if __name__ == '__main__':
    main()
