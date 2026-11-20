#!/usr/bin/env python3
# Argent spike, decoder-costs. Measurement prototype, not shipped code.
#
# compare.py checks that the harness times a working demosaic, not a broken one: it
# compares the Hamilton-Adams output (costs --dump) with Apple's decode of the same file,
# pinned with lens correction and noise reduction off, written by the decoder probes as
# float32 RGBA with an 8-byte width, height header. Colour pipelines differ (white balance,
# matrix, output primaries), so a 3 by 3 matrix is fitted on block means first; what is
# left is tone and detail.
#
#   ../../.venv/bin/python compare.py out/L.demosaic.rgba16f 7028 4688 12 8 apple-L.f32 out/compare.png

import struct
import sys
import zlib

import numpy as np


def load_half(path, width, height):
    return np.fromfile(path, dtype="<f2").reshape(height, width, 4)[..., :3].astype(np.float64)


def load_apple(path):
    raw = open(path, "rb").read()
    w, h = np.frombuffer(raw[:8], dtype=np.int32)
    return np.frombuffer(raw[8:], dtype=np.float32).reshape(h, w, 4)[..., :3].astype(np.float64)


def blocks(a, k):
    h, w = (a.shape[0] // k) * k, (a.shape[1] // k) * k
    return a[:h, :w].reshape(h // k, k, w // k, k, -1).mean(axis=(1, 3))


def luma(a):
    return a @ np.array([0.25, 0.5, 0.25])


def highpass(y):
    pad = np.pad(y, 2, mode="edge")
    box = sum(pad[j:j + y.shape[0], i:i + y.shape[1]] for j in range(5) for i in range(5)) / 25
    return y - box


def png(path, img):
    h, w, _ = img.shape
    rows = b"".join(b"\x00" + img[y].tobytes() for y in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def main(ours_path, width, height, crop_x, crop_y, apple_path, png_path):
    apple = load_apple(apple_path)
    ours_full = load_half(ours_path, int(width), int(height))
    h, w, _ = apple.shape
    print(f"ours {ours_full.shape[1]}x{ours_full.shape[0]}, finite {np.isfinite(ours_full).mean() * 100:.4f} percent; apple {w}x{h}")

    # Find the crop offset that lines the two up, around the camera's crop origin.
    ya = luma(apple)[1000:1512, 2000:2512]
    best = None
    for dy in range(-6, 7):
        for dx in range(-6, 7):
            ox, oy = int(crop_x) + dx, int(crop_y) + dy
            yo = luma(ours_full[oy + 1000:oy + 1512, ox + 2000:ox + 2512])
            c = np.corrcoef(highpass(ya).ravel(), highpass(yo).ravel())[0, 1]
            if best is None or c > best[0]:
                best = (c, ox, oy)
    _, ox, oy = best
    ours = ours_full[oy:oy + h, ox:ox + w]
    print(f"aligned at crop origin ({ox}, {oy}), camera says ({crop_x}, {crop_y})")

    # Fit apple ~ ours @ M on 16 px block means of well-exposed blocks.
    bo, ba = blocks(ours, 16).reshape(-1, 3), blocks(apple, 16).reshape(-1, 3)
    keep = (ba.min(axis=1) > 0.01) & (ba.max(axis=1) < 0.9) & (bo.min(axis=1) > 0.0)
    m, *_ = np.linalg.lstsq(bo[keep], ba[keep], rcond=None)
    fitted = ours @ m
    fb = blocks(fitted, 16).reshape(-1, 3)
    rel = np.abs(np.log2(np.maximum(fb[keep], 1e-6) / np.maximum(ba[keep], 1e-6)))
    print(f"after a 3x3 fit on {keep.sum()} blocks: block-mean error median {np.median(rel):.3f} stops, 95th percentile {np.percentile(rel, 95):.3f}")

    # Detail: correlation of the luma high-pass in the centre, full resolution.
    yc = slice(h // 2 - 1024, h // 2 + 1024), slice(w // 2 - 1536, w // 2 + 1536)
    ha, ho = highpass(luma(apple[yc])), highpass(luma(fitted[yc]))
    c = np.corrcoef(ha.ravel(), ho.ravel())[0, 1]
    print(f"luma high-pass correlation, central 3072x2048: {c:.3f}; high-pass RMS ours / apple {ho.std() / ha.std():.2f}")

    # A side-by-side crop for the eye: apple left, ours right, same exposure and gamma.
    y0, x0 = h // 2 - 150, w // 2 - 200
    pair = np.concatenate([apple[y0:y0 + 300, x0:x0 + 400], fitted[y0:y0 + 300, x0:x0 + 400]], axis=1)
    pair = np.clip(pair / np.percentile(pair, 99), 0, 1) ** (1 / 2.2)
    png(png_path, np.ascontiguousarray((pair * 255).astype(np.uint8)))
    print(f"wrote {png_path}")


if __name__ == "__main__":
    main(*sys.argv[1:8])
