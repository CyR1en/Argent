"""What brightening the camera's JPEG applies by radius, against the uncorrected raw.

Usage: vignette.py ARW JPEG distortion_knots(comma) s_units vignette_knots(comma)
Our raw decode (register.ours, before its gamma) is warped with the camera's distortion model so it
lines up with the JPEG; both are reduced to 32-px block means of a luminance proxy. The JPEG's
tone curve T is fitted from blocks within 0.25 of the half diagonal, where the file's vignetting
curve is under a tenth of its corner value, as binned medians of JPEG Y against raw Y (log-log, then
a monotone fit). Each block's implied gain is T^-1(JPEG Y) / raw Y; the median by ring is printed
beside candidate unit conventions for the file's curve.
"""
import os
import sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from register import ours
from fit import interp
from PIL import Image


def srgb_to_linear(v):
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


def bilinear(img, x, y):
    H, W = img.shape
    x = np.clip(x, 0, W - 1.001)
    y = np.clip(y, 0, H - 1.001)
    x0, y0 = np.floor(x).astype(int), np.floor(y).astype(int)
    fx, fy = x - x0, y - y0
    return (img[y0, x0] * (1 - fx) * (1 - fy) + img[y0, x0 + 1] * fx * (1 - fy)
            + img[y0 + 1, x0] * (1 - fx) * fy + img[y0 + 1, x0 + 1] * fx * fy)


def main():
    arw, jpg = sys.argv[1:3]
    dk = [float(v) for v in sys.argv[3].split(',')]
    s = 1 + float(sys.argv[4]) / 16384
    vk = [float(v) for v in sys.argv[5].split(',')]
    a = ours(arw) ** 2.2  # back to linear, gains applied
    Y = 0.25 * a[0] + 0.65 * a[1] + 0.10 * a[2]
    H, W = Y.shape
    j = srgb_to_linear(np.asarray(Image.open(jpg).convert('RGB'), np.float32) / 255.0)
    Yj = 0.2126 * j[..., 0] + 0.7152 * j[..., 1] + 0.0722 * j[..., 2]
    c = np.array([(W - 1) / 2, (H - 1) / 2])
    rmax = np.hypot(W / 2, H / 2)
    # Warp ours into the JPEG's geometry, row band by row band.
    warped = np.zeros_like(Y)
    xs = np.arange(W, dtype=np.float64)
    for y0 in range(0, H, 256):
        yy, xx = np.mgrid[y0:min(H, y0 + 256), 0:W].astype(np.float64)
        vx, vy = xx - c[0], yy - c[1]
        r = np.hypot(vx, vy)
        g = 1 + interp(dk, (len(dk) - 1) * r / rmax, 'linear') / 16384
        warped[y0:y0 + 256] = bilinear(Y, c[0] + vx * g / s, c[1] + vy * g / s)
    B = 32
    hb, wb = H // B, W // B
    def blocks(img):
        return img[:hb * B, :wb * B].reshape(hb, B, wb, B).mean((1, 3))
    rb, jb = blocks(warped), blocks(Yj)
    jmax = blocks(Yj ** 8) ** (1 / 8)  # near-clipped blocks out
    by, bx = np.mgrid[0:hb, 0:wb]
    rr = np.hypot((bx + 0.5) * B - 0.5 - c[0], (by + 0.5) * B - 0.5 - c[1]) / rmax
    ok = (rb > 0.003) & (jb > 0.002) & (jmax < 0.9)
    centre = ok & (rr < 0.25)
    # Tone curve: binned medians in log space, centre blocks only.
    lx, ly = np.log2(rb[centre]), np.log2(jb[centre])
    edges = np.quantile(lx, np.linspace(0, 1, 25))
    mx = np.array([np.median(lx[(lx >= edges[i]) & (lx <= edges[i + 1])]) for i in range(24)])
    my = np.array([np.median(ly[(lx >= edges[i]) & (lx <= edges[i + 1])]) for i in range(24)])
    my = np.maximum.accumulate(my)
    print('tone curve (log2 raw -> log2 jpeg):', ' '.join('%.2f>%.2f' % (p, q) for p, q in zip(mx[::3], my[::3])))
    inside = ok & (np.log2(jb) > my[0]) & (np.log2(jb) < my[-1])
    implied = np.log2(jb[inside])
    raw_needed = np.interp(implied, my + np.arange(24) * 1e-6, mx)  # T^-1
    gain_stops = raw_needed - np.log2(rb[inside])
    r_in = rr[inside]
    print('ring  implied gain (stops, median, n)   file curve v   v*2^-14  v*2^-13  log2(1+v*2^-14)  log2(1+v*2^-13)')
    for lo in np.arange(0, 1.0, 0.05):
        m = (r_in >= lo) & (r_in < lo + 0.05)
        if m.sum() < 5:
            continue
        v = interp(vk, (len(vk) - 1) * (lo + 0.025), 'linear')
        print('%.2f  %+.3f (n %4d)                 %7.0f       %.3f    %.3f    %.3f            %.3f'
              % (lo + 0.025, np.median(gain_stops[m]), m.sum(), v, v / 16384, v / 8192, np.log2(1 + v / 16384), np.log2(1 + v / 8192)))


if __name__ == '__main__':
    main()
