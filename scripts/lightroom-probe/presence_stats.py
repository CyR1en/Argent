"""What a Lightroom export says it applied, and the numbers that show a Presence control moved it.

    python -I presence_stats.py EXPORT.tif [...]     the settings and statistics of each export, one JSON line each

Each export carries the develop settings Lightroom rendered it with in its XMP (crs: attributes, with the Look
as a nested element), so `settings` proves a key took. `measure` gives one statistic per control, each of which
the control should move one way:

    texture     fine detail: rms of log2 luminance less its 5-pixel box mean, on the central crop
    clarity     local contrast: rms of log2 luminance less its 65-pixel box mean, on the central crop
    dehaze      the dark channel: mean L* of the smallest of R, G and B (4 x 4 blocks), the usual measure of haze
                (He, Sun and Tang 2009), which removing haze lowers. The spread of L* was tried first: on the
                haze-free p-steps chart it falls at both +100 and -100, so it cannot show a direction.
    vibrance    mean CIELAB chroma C*ab (D50) over the frame
    saturation  the same chroma

Beside them, `black` and `white` count the pixels with a channel at code 0 or at 65535: what the export clipped,
which a fit in log units or in chroma should leave out.

They are sanity numbers, not models: a fit agent should measure what it needs from the pixels.
"""
import hashlib
import json
import re
import struct
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import probe  # noqa: E402

# Linear ProPhoto RGB to XYZ, D50, and the D50 white.
PROPHOTO_XYZ = np.array([[0.7976749, 0.1351917, 0.0313534],
                         [0.2880402, 0.7118741, 0.0000857],
                         [0.0000000, 0.0000000, 0.8252100]])
D50 = np.array([0.96422, 1.0, 0.82521])
STATISTIC = {"texture": "fine", "clarity": "local", "dehaze": "dark", "vibrance": "chroma", "saturation": "chroma"}
CROP = 2048


def xmp(path):
    """The XMP packet of a TIFF (tag 700), as text."""
    with open(path, "rb") as f:
        head = f.read(16)
        e = "<" if head[:2] == b"II" else ">"
        f.seek(struct.unpack(e + "I", head[4:8])[0])
        n = struct.unpack(e + "H", f.read(2))[0]
        for _ in range(n):
            tag, kind, count, value = struct.unpack(e + "HHI4s", f.read(12))
            if tag == 700:
                f.seek(struct.unpack(e + "I", value)[0])
                return f.read(count).decode("utf-8", "replace")
    return ""


def settings(path):
    """The crs: settings an export was rendered with, the Look's name (None without one), and its sizes."""
    text = xmp(path)
    look = re.search(r"<crs:Look>.*?crs:Name=\"([^\"]*)\"", text, re.S)
    outer = re.sub(r"<crs:Look>.*?</crs:Look>", "", text, flags=re.S)
    values = dict(re.findall(r"crs:(\w+)=\"([^\"]*)\"", outer))
    return values, (look.group(1) if look else None)


def box(a, r):
    """Mean over a (2r+1)-pixel square, edges clamped, by summed-area table."""
    p = np.pad(a, r + 1, mode="edge").astype(np.float64)
    s = p.cumsum(0).cumsum(1)
    k = 2 * r + 1
    out = s[k:, k:] - s[:-k, k:] - s[k:, :-k] + s[:-k, :-k]
    return (out / (k * k))[:a.shape[0], :a.shape[1]]


def lab(rgb):
    """CIELAB (D50) of linear ProPhoto RGB, shape (..., 3)."""
    xyz = rgb @ PROPHOTO_XYZ.T / D50
    f = np.where(xyz > (6 / 29) ** 3, np.cbrt(np.maximum(xyz, 0)), xyz / (3 * (6 / 29) ** 2) + 4 / 29)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], axis=-1)


def linear(path):
    """A Lightroom export in linear ProPhoto RGB, float32, and a digest of its pixels (two renders with the same
    digest are the same picture, whatever their metadata)."""
    img, icc = probe.read_tiff(path)
    gamma = probe.icc_gamma(icc) if icc else None
    if gamma is None:
        raise SystemExit(f"{path}: expected ProPhoto RGB with a pure-gamma profile")
    digest = hashlib.md5(img.tobytes()).hexdigest()
    return np.power(img, np.float32(gamma)), digest


def measure(path, base=None):
    """The statistics of one export, and its CIELAB blocks. Given the base's blocks, also the mean absolute change
    from the base: dL (L*), dC (C*ab) and dE (CIE76)."""
    rgb, digest = linear(path)
    h, w, _ = rgb.shape
    black = int(np.count_nonzero(rgb.min(axis=-1) <= 0))
    white = int(np.count_nonzero(rgb.max(axis=-1) >= 1))
    c = min(CROP, h, w)
    y0, x0 = (h - c) // 2, (w - c) // 2
    crop = np.log2(np.maximum(rgb[y0:y0 + c, x0:x0 + c] @ probe.PROPHOTO_Y.astype(np.float32), 2.0 ** -16))
    fine = float(np.sqrt(np.mean((crop - box(crop, 2)) ** 2)))
    local = float(np.sqrt(np.mean((crop - box(crop, 32)) ** 2)))
    del crop
    k = probe.BLOCK
    hh, ww = h // k * k, w // k * k
    blocks = rgb[:hh, :ww].reshape(hh // k, k, ww // k, k, 3).mean(axis=(1, 3))
    del rgb
    L = lab(blocks.astype(np.float64))
    chroma = np.hypot(L[..., 1], L[..., 2])
    dark = float(probe.lstar(blocks.min(axis=-1).astype(np.float64)).mean())
    out = {"fine": fine, "local": local, "spread": float(L[..., 0].std()), "lightness": float(L[..., 0].mean()),
           "chroma": float(chroma.mean()), "dark": dark, "black": black, "white": white, "size": [w, h], "pixels": digest}
    if base is not None and base.shape == L.shape:
        out["dL"] = float(np.abs(L[..., 0] - base[..., 0]).mean())
        out["dC"] = float(np.abs(chroma - np.hypot(base[..., 1], base[..., 2])).mean())
        out["dE"] = float(np.linalg.norm(L - base, axis=-1).mean())
    return out, L


def main():
    for path in sys.argv[1:]:
        values, look = settings(path)
        keys = ["ProcessVersion", "CameraProfile", "Texture", "Clarity2012", "Dehaze", "Vibrance", "Saturation",
                "Exposure2012", "Contrast2012", "Highlights2012", "Shadows2012"]
        print(json.dumps({"path": path, "look": look, **{k: values.get(k) for k in keys}, **measure(path)[0]}))


if __name__ == "__main__":
    main()
