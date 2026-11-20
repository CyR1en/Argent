"""The fine-detail gap's engineering metrics (docs/fine-detail-plan.md, section 4).

Works on the arms `FineDetailMeasureTests/arms` writes: one directory per frame holding `meta.json`
and RGBA half floats in linear Rec. 2020, rows as the frame texture lays them out:

    r9.f16    Argent's RAW 9 decode at full size, lens correction off
    r8.f16    RAW 8 under Argent's pins, the same
    lrd.f16   Lightroom's -Enhanced-RD.dng through Core Image with every control off, when there is one

`prepare` registers LRD to R9 by phase correlation and fits it to R9's colour, writing `lrdfit.f16`
on R9's grid, and composes `r9r8c.f16`, R9's luminance under R8's fine chroma (an evaluation arm).
`measure` scores every arm on one set of 256-pixel blocks chosen on R8: the textured quarter and the
flattest tenth. `blocks` picks the blind test's three crops a frame. `summary` gives medians over a
set and the pre-registered gap lines.

    python metrics.py prepare <frame-dir>
    python metrics.py measure <frame-dir>
    python metrics.py blocks <frame-dir>
    python metrics.py summary <set-dir>...
"""
import json
import sys
import zlib
from pathlib import Path

import numpy as np

B = 256
BANDS = [(0.1, 0.2), (0.2, 0.3), (0.3, 0.4), (0.4, 0.5)]
FINE_CHROMA = (0.3, 0.71)
REC2020_Y = np.array([0.2627, 0.6780, 0.0593])
ARMS = ["r9", "r8", "r9r8c", "lrdfit"]


# --- frames -------------------------------------------------------------------------------------

def meta(d):
    return json.loads((d / "meta.json").read_text())


def load(d, arm):
    """An arm's RGB as float32, or None when the frame has no such arm."""
    m = meta(d)["arms"].get(arm)
    if m is None or not (d / f"{arm}.f16").exists():
        return None
    a = np.fromfile(d / f"{arm}.f16", dtype=np.float16).reshape(m["height"], m["width"], 4)
    return a[..., :3].astype(np.float32)


def save(d, arm, rgb, note):
    h, w, _ = rgb.shape
    out = np.ones((h, w, 4), dtype=np.float16)
    out[..., :3] = rgb.astype(np.float16)
    out.tofile(d / f"{arm}.f16")
    m = meta(d)
    m["arms"][arm] = {"width": w, "height": h, "note": note}
    (d / "meta.json").write_text(json.dumps(m, indent=1))


def luminance(rgb):
    return rgb @ REC2020_Y.astype(np.float32)


# --- prepare --------------------------------------------------------------------------------------

def phase_shift(ref, mov):
    """The (dy, dx) that moves `mov` onto `ref`, to a tenth of a pixel or so: phase correlation with
    a parabola through the peak."""
    win = np.outer(np.hanning(ref.shape[0]), np.hanning(ref.shape[1]))
    fa = np.fft.fft2((ref - ref.mean()) * win)
    fb = np.fft.fft2((mov - mov.mean()) * win)
    r = fa * np.conj(fb)
    c = np.fft.ifft2(r / np.maximum(np.abs(r), 1e-12)).real
    py, px = np.unravel_index(np.argmax(c), c.shape)
    def sub(m1, c0, p1):
        den = m1 - 2 * c0 + p1
        return 0.0 if abs(den) < 1e-12 else 0.5 * (m1 - p1) / den
    h, w = c.shape
    dy = py + sub(c[(py - 1) % h, px], c[py, px], c[(py + 1) % h, px])
    dx = px + sub(c[py, (px - 1) % w], c[py, px], c[py, (px + 1) % w])
    dy = dy - h if dy > h / 2 else dy
    dx = dx - w if dx > w / 2 else dx
    return float(dy), float(dx), float(c.max())


def fourier_shift(rgb, dy, dx):
    """`rgb` moved by a sub-pixel (dy, dx) without the blur of an interpolating filter."""
    h, w, _ = rgb.shape
    ky = np.fft.fftfreq(h)[:, None]
    kx = np.fft.fftfreq(w)[None, :]
    phase = np.exp(-2j * np.pi * (ky * dy + kx * dx))
    return np.stack([np.fft.ifft2(np.fft.fft2(rgb[..., k]) * phase).real for k in range(3)], axis=-1).astype(np.float32)


def block_means(rgb, s=32):
    h, w, _ = rgb.shape
    h, w = h // s * s, w // s * s
    return rgb[:h, :w].reshape(h // s, s, w // s, s, 3).mean(axis=(1, 3)).reshape(-1, 3)


def fit_matrix(src, dst):
    """The 3x3 matrix taking `src` block colours to `dst`'s, by least squares reweighted toward a
    Huber loss, so a few odd blocks cannot pull it."""
    weights = np.ones(len(src))
    m = np.eye(3)
    for _ in range(10):
        sw = np.sqrt(weights)[:, None]
        m = np.linalg.lstsq(src * sw, dst * sw, rcond=None)[0].T
        resid = np.linalg.norm(src @ m.T - dst, axis=1) / np.maximum(np.linalg.norm(dst, axis=1), 1e-6)
        k = 1.345 * max(np.median(resid), 1e-4)
        weights = np.where(resid <= k, 1.0, k / resid)
    return m


def prepare(d):
    r9, r8 = load(d, "r9"), load(d, "r8")
    report = {}
    # A raw RAW 9 does not take (lossless M and S) has R8 alone: LRD, if any, is fitted to R8.
    if r9 is None:
        report["r9"] = "not offered; LRD fitted to R8"
        r9 = r8
    else:
        report["r9r8c"] = compose(d, r9, r8)
    report |= fit_lrd(d, r9, r8)
    (d / "prepare.json").write_text(json.dumps(report, indent=1))
    return report


def gaussian(a, sigma=2.0):
    """A separable Gaussian blur, edges repeated: a whole-frame FFT in complex128 would take 0.5 GB a
    plane."""
    r = int(np.ceil(3 * sigma))
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2).astype(np.float32); k /= k.sum()
    p = np.pad(a.astype(np.float32), r, mode="edge")
    rows = sum(k[i] * p[:, i:i + a.shape[1]] for i in range(2 * r + 1))
    return sum(k[i] * rows[i:i + a.shape[0], :] for i in range(2 * r + 1))


def compose(d, r9, r8):
    # R9's luminance under R8's fine chroma: log chroma split at a 2-pixel Gaussian.
    y9 = luminance(r9)
    def logchroma(rgb):
        g = np.maximum(rgb[..., 1], 1e-5)
        return np.log(np.maximum(rgb[..., 0], 1e-5) / g), np.log(np.maximum(rgb[..., 2], 1e-5) / g)
    blur = gaussian
    rg9, bg9 = logchroma(r9); rg8, bg8 = logchroma(r8)
    rg = blur(rg9) + (rg8 - blur(rg8)); bg = blur(bg9) + (bg8 - blur(bg8))
    # Rebuild RGB with R9's luminance: G from Y given the two ratios.
    r_over_g, b_over_g = np.exp(rg), np.exp(bg)
    g = y9 / (REC2020_Y[0] * r_over_g + REC2020_Y[1] + REC2020_Y[2] * b_over_g)
    mix = np.stack([g * r_over_g, g, g * b_over_g], axis=-1)
    clean = (r9[..., 0] > 1e-5) & (r9[..., 1] > 1e-5) & (r9[..., 2] > 1e-5)
    mix[~clean] = r9[~clean]
    save(d, "r9r8c", mix, "R9 luminance under R8's chroma above a 2-pixel Gaussian")
    return "written"


def fit_lrd(d, r9, r8):
    report = {}
    lrd = load(d, "lrd")
    if lrd is not None:
        # Step 0: is it Adobe's demosaic, or Core Image demosaicing a mosaic kept in the DNG? A decode
        # identical to RAW 8's in its fine band would be the latter.
        h = min(r9.shape[0], lrd.shape[0]); w = min(r9.shape[1], lrd.shape[1])
        cy, cx, n = h // 2, w // 2, min(2048, h // 2 * 2, w // 2 * 2)
        ref = luminance(r9[cy - n // 2:cy + n // 2, cx - n // 2:cx + n // 2])
        dy0 = dx0 = 0.0
        # Sizes can differ by a default crop; search the integer offset on the whole luminance first.
        if lrd.shape[:2] != r9.shape[:2]:
            hh, ww = max(r9.shape[0], lrd.shape[0]), max(r9.shape[1], lrd.shape[1])
            pa = np.zeros((hh, ww), np.float32); pb = np.zeros((hh, ww), np.float32)
            pa[:r9.shape[0], :r9.shape[1]] = luminance(r9); pb[:lrd.shape[0], :lrd.shape[1]] = luminance(lrd)
            dy0, dx0, _ = phase_shift(pa, pb)
            dy0, dx0 = round(dy0), round(dx0)
        oy, ox = int(-dy0), int(-dx0)  # lrd pixel (y + oy, x + ox) lies at r9 pixel (y, x)
        canvas = np.zeros_like(r9)
        ys, xs = slice(max(0, -oy), min(r9.shape[0], lrd.shape[0] - oy)), slice(max(0, -ox), min(r9.shape[1], lrd.shape[1] - ox))
        canvas[ys, xs] = lrd[ys.start + oy:ys.stop + oy, xs.start + ox:xs.stop + ox]
        # The parabola through the correlation peak undershoots a sub-pixel move, so the estimate is
        # refined on the centre moved by what is found so far (three rounds recover 0.3 px to 0.01).
        mov = canvas[cy - n // 2:cy + n // 2, cx - n // 2:cx + n // 2]
        dy = dx = 0.0
        for _ in range(3):
            ddy, ddx, peak = phase_shift(ref, luminance(fourier_shift(mov, dy, dx) if dy or dx else mov))
            dy, dx = dy + ddy, dx + ddx
        if abs(dy) > 0.05 or abs(dx) > 0.05:
            canvas = fourier_shift(canvas, dy, dx)
        covered = np.zeros(r9.shape[:2], bool); covered[ys, xs] = True
        src, dst = block_means(np.where(covered[..., None], canvas, np.nan)), block_means(r9)
        y = dst @ REC2020_Y
        use = np.isfinite(src).all(axis=1) & (y > 0.01) & (dst.max(axis=1) < 3.0) & (src.max(axis=1) < 3.0)
        m = fit_matrix(src[use], dst[use])
        fitted = (canvas @ m.T).astype(np.float32)
        fitted[~covered] = r9[~covered]
        save(d, "lrdfit", fitted, "LRD registered to R9 and fitted to its colour")
        de = delta_e2000(lab(src[use] @ m.T), lab(dst[use]))
        # Fine detail of LRD less R8's, against R9's less R8's: near 0 means Core Image demosaiced a
        # mosaic kept in the DNG much as RAW 8 does, rather than reading Adobe's linear data.
        centre = (slice(cy - n // 2, cy + n // 2), slice(cx - n // 2, cx + n // 2))
        def fine(a):
            y = np.log(np.maximum(luminance(a[centre]), 1e-4))
            return y - gaussian(y, 1.5)
        f8 = fine(r8)
        same_as_r8 = float(np.sqrt(np.mean((fine(fitted) - f8) ** 2) / max(np.mean((fine(r9) - f8) ** 2), 1e-12)))
        report["lrd"] = {"integerOffset": [oy, ox], "subpixel": [dy, dx], "peak": peak, "matrix": m.tolist(),
                         "fitBlocks": int(use.sum()), "fitDE2000Median": float(np.median(de)),
                         "fineDifferenceToR8OverR9s": same_as_r8, "coveredShare": float(covered.mean())}
    return report


# --- colour --------------------------------------------------------------------------------------

REC2020_TO_XYZ = np.array([[0.6370, 0.1446, 0.1689], [0.2627, 0.6780, 0.0593], [0.0000, 0.0281, 1.0610]])
WHITE = REC2020_TO_XYZ.sum(axis=1)


def lab(rgb):
    xyz = (rgb @ REC2020_TO_XYZ.T) / WHITE
    f = np.where(xyz > (6 / 29) ** 3, np.cbrt(np.maximum(xyz, 0)), xyz / (3 * (6 / 29) ** 2) + 4 / 29)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], axis=-1)


def delta_e2000(lab1, lab2):
    L1, a1, b1 = np.moveaxis(lab1, -1, 0); L2, a2, b2 = np.moveaxis(lab2, -1, 0)
    C1, C2 = np.hypot(a1, b1), np.hypot(a2, b2)
    Cm = (C1 + C2) / 2
    G = 0.5 * (1 - np.sqrt(Cm ** 7 / (Cm ** 7 + 25 ** 7)))
    a1p, a2p = (1 + G) * a1, (1 + G) * a2
    C1p, C2p = np.hypot(a1p, b1), np.hypot(a2p, b2)
    h1p, h2p = np.degrees(np.arctan2(b1, a1p)) % 360, np.degrees(np.arctan2(b2, a2p)) % 360
    dL, dC = L2 - L1, C2p - C1p
    dh = h2p - h1p
    dh = np.where(C1p * C2p == 0, 0, np.where(dh > 180, dh - 360, np.where(dh < -180, dh + 360, dh)))
    dH = 2 * np.sqrt(C1p * C2p) * np.sin(np.radians(dh / 2))
    Lm, Cmp = (L1 + L2) / 2, (C1p + C2p) / 2
    hs = h1p + h2p
    hm = np.where(C1p * C2p == 0, hs, np.where(np.abs(h1p - h2p) > 180, np.where(hs < 360, hs + 360, hs - 360) / 2, hs / 2))
    T = 1 - 0.17 * np.cos(np.radians(hm - 30)) + 0.24 * np.cos(np.radians(2 * hm)) + 0.32 * np.cos(np.radians(3 * hm + 6)) - 0.20 * np.cos(np.radians(4 * hm - 63))
    SL = 1 + 0.015 * (Lm - 50) ** 2 / np.sqrt(20 + (Lm - 50) ** 2)
    SC, SH = 1 + 0.045 * Cmp, 1 + 0.015 * Cmp * T
    RT = -2 * np.sqrt(Cmp ** 7 / (Cmp ** 7 + 25 ** 7)) * np.sin(np.radians(60 * np.exp(-((hm - 275) / 25) ** 2)))
    return np.sqrt((dL / SL) ** 2 + (dC / SC) ** 2 + (dH / SH) ** 2 + RT * (dC / SC) * (dH / SH))


# --- spectra -------------------------------------------------------------------------------------

_fy = np.fft.fftfreq(B)[:, None]
_fx = np.fft.fftfreq(B)[None, :]
_r = np.sqrt(_fx ** 2 + _fy ** 2)
_win = np.outer(np.hanning(B), np.hanning(B)).astype(np.float32)
_band = [(_r >= lo) & (_r < hi) for lo, hi in BANDS]
_fine_chroma = (_r >= FINE_CHROMA[0]) & (_r < FINE_CHROMA[1])
# The zipper index: power on the axis Nyquist lines (either frequency at 0.47 or more) over the
# 0.4-0.5 radial band.
_nyquist_lines = np.maximum(np.abs(_fx), np.abs(_fy)) >= 0.47
_nyquist_band = (_r >= 0.4) & (_r < 0.5)


def spectra(rgb):
    """Band powers of one block: luminance contrast, log chroma, and the zipper lines."""
    y = luminance(rgb)
    p = np.abs(np.fft.fft2((y / max(float(y.mean()), 1e-6) - 1) * _win)) ** 2
    g = np.maximum(rgb[..., 1], 1e-4)
    chroma = 0.0
    for k in (0, 2):
        q = np.log(np.maximum(rgb[..., k], 1e-4) / g)
        chroma = chroma + np.abs(np.fft.fft2((q - q.mean()) * _win)) ** 2
    return {"lum": [float(p[m].sum()) for m in _band], "chroma": float(chroma[_fine_chroma].sum()),
            "zipper": float(p[_nyquist_lines].sum()), "nyquist": float(p[_nyquist_band].sum()),
            "mid": float(p[(_r >= 0.1) & (_r < 0.2)].sum())}


def candidate_blocks(r8):
    """Every 256-pixel block of R8 that is lit, unclipped and not black, with its 0.1-0.2 power."""
    h, w, _ = r8.shape
    out = []
    for by in range(0, h - B + 1, B):
        for bx in range(0, w - B + 1, B):
            a = r8[by:by + B, bx:bx + B]
            y = luminance(a)
            if not (0.02 < y.mean() < 1.5) or a.max() > 4.0 or a.min() < -0.05:
                continue
            out.append((by, bx, spectra(a)["mid"]))
    return out


def measure(d):
    r8 = load(d, "r8")
    blocks = candidate_blocks(r8)
    order = np.argsort([b[2] for b in blocks])
    texture = [blocks[i][:2] for i in order[int(len(order) * 0.75):]]
    flat = [blocks[i][:2] for i in order[:max(1, int(len(order) * 0.10))]]
    r9 = load(d, "r9")
    out = {"iso": meta(d).get("iso"), "size": list(r8.shape[:2]), "texture": len(texture), "flat": len(flat), "arms": {},
           "colourReference": "r9" if r9 is not None else "r8"}
    if r9 is None:
        r9 = r8
    for arm in ARMS:
        a = r8 if arm == "r8" else load(d, arm)
        if a is None:
            continue
        res = {}
        for label, chosen in (("texture", texture), ("flat", flat)):
            lum = np.zeros(len(BANDS)); chroma = zipper = nyq = 0.0
            for by, bx in chosen:
                s = spectra(a[by:by + B, bx:bx + B])
                lum += s["lum"]; chroma += s["chroma"]; zipper += s["zipper"]; nyq += s["nyquist"]
            n = len(chosen)
            res[label] = {"lum": (lum / n).tolist(), "chroma": chroma / n, "zipper": zipper / n, "nyquist": nyq / n}
        # Mid-tone colour against R9 on 16-pixel blocks.
        m16, r16 = block_means(a, 16), block_means(r9, 16)
        y = r16 @ REC2020_Y
        mid = (y > 0.05) & (y < 0.5) & (r16.max(axis=1) < 3.0)
        # A frame without R9 has no colour reference for R8 itself.
        own = arm == "r8" and out["colourReference"] == "r8"
        res["midtoneDE2000ToR9"] = float(np.median(delta_e2000(lab(m16[mid]), lab(r16[mid])))) if mid.any() and not own else None
        res["levelStopsToR9"] = float(np.log2(np.median(m16[mid] @ REC2020_Y) / np.median(y[mid]))) if mid.any() and not own else None
        out["arms"][arm] = res
    (d / "metrics.json").write_text(json.dumps(out, indent=1))
    return out


# --- blind-test blocks ---------------------------------------------------------------------------

def blocks(d):
    """Three crops a frame, by the pre-registered rule: the block with the most fine luminance (on
    R8), the block with the most fine chroma in any arm, and one random textured block (seeded by the
    frame's name). Coordinates are in R9's frame, rows as the arms lay them out."""
    r8 = load(d, "r8")
    arms = {arm: (r8 if arm == "r8" else load(d, arm)) for arm in ARMS}
    arms = {k: v for k, v in arms.items() if v is not None}
    cands = candidate_blocks(r8)
    fine_lum = [(sum(spectra(r8[by:by + B, bx:bx + B])["lum"][2:]), by, bx) for by, bx, _ in cands]
    fine_lum.sort(reverse=True)
    first = fine_lum[0][1:]
    chroma = [(max(spectra(a[by:by + B, bx:bx + B])["chroma"] for a in arms.values()), by, bx) for by, bx, _ in cands
              if (by, bx) != first]
    chroma.sort(reverse=True)
    second = chroma[0][1:]
    order = np.argsort([c[2] for c in cands])
    textured = [cands[i][:2] for i in order[int(len(order) * 0.75):] if cands[i][:2] not in (first, second)]
    rng = np.random.default_rng(zlib.crc32(d.name.encode()))
    third = textured[int(rng.integers(len(textured)))]
    out = [{"rule": "fine luminance", "y": first[0], "x": first[1], "size": B},
           {"rule": "fine chroma", "y": second[0], "x": second[1], "size": B},
           {"rule": "random textured", "y": int(third[0]), "x": int(third[1]), "size": B}]
    (d / "blocks.json").write_text(json.dumps(out, indent=1))
    return out


# --- summary -------------------------------------------------------------------------------------

def summary(sets):
    frames = [json.loads(p.read_text()) | {"name": p.parent.name} for s in sets for p in sorted(Path(s).glob("*/metrics.json"))]
    lines = [f"{len(frames)} frames: " + ", ".join(f["name"] for f in frames)]
    def ratio(arm, base, key, label="texture", amplitude=True):
        vals = []
        for f in frames:
            if arm not in f["arms"] or base not in f["arms"]:
                continue
            a, b = np.array(f["arms"][arm][label][key]), np.array(f["arms"][base][label][key])
            vals.append(np.sqrt(a / b) if amplitude else a / b)
        return np.array(vals)
    def share(arm, f, i):
        return f["arms"][arm]["flat"]["lum"][i] / f["arms"][arm]["texture"]["lum"][i]
    def fine_chroma_above_floor(arm, f):
        return max(f["arms"][arm]["texture"]["chroma"] - f["arms"][arm]["flat"]["chroma"], 1e-9)
    present = [a for a in ARMS if any(a in f["arms"] for f in frames)]
    for arm in present:
        if arm == "r8":
            continue
        lum = ratio(arm, "r8", "lum")
        if len(lum):
            lines.append(f"{arm} / r8 textured luminance amplitude, bands {BANDS}: median {np.round(np.median(lum, axis=0), 3).tolist()}")
    for arm in present:
        fs = [f for f in frames if arm in f["arms"]]
        noise = np.median([[share(arm, f, i) for i in range(len(BANDS))] for f in fs], axis=0)
        fc = np.median([np.sqrt(fine_chroma_above_floor(arm, f) / fine_chroma_above_floor("r8", f)) for f in fs])
        zip_ = np.median([f["arms"][arm]["texture"]["zipper"] / f["arms"][arm]["texture"]["nyquist"] for f in fs])
        de = [f["arms"][arm]["midtoneDE2000ToR9"] for f in fs if f["arms"][arm]["midtoneDE2000ToR9"] is not None]
        lv = [f["arms"][arm]["levelStopsToR9"] for f in fs if f["arms"][arm]["levelStopsToR9"] is not None]
        colour = (f"mid-tone dE2000 to r9 median {np.median(de):.3f} max {max(de):.3f}; level to r9 median {np.median(lv):+.4f} stops"
                  if de else "no colour reference")
        lines.append(f"{arm} ({len(fs)} frames): noise share {np.round(noise, 4).tolist()}; fine chroma above the floor / r8 {fc:.3f}; "
                     f"zipper index {zip_:.4f}; {colour}")
    # The pre-registered gap lines (section 4), LRD against R9 at the median frame.
    both = [f for f in frames if "lrdfit" in f["arms"]]
    if both:
        fc = np.median([np.sqrt(fine_chroma_above_floor("lrdfit", f) / fine_chroma_above_floor("r9", f)) for f in both])
        det = np.median([np.sqrt(sum(f["arms"]["lrdfit"]["texture"]["lum"][1:3]) / sum(f["arms"]["r9"]["texture"]["lum"][1:3])) for f in both])
        ns = np.median([sum(f["arms"]["lrdfit"]["flat"]["lum"][1:3]) / sum(f["arms"]["lrdfit"]["texture"]["lum"][1:3])
                        / (sum(f["arms"]["r9"]["flat"]["lum"][1:3]) / sum(f["arms"]["r9"]["texture"]["lum"][1:3])) for f in both])
        lines.append(f"LRD / R9 at the median of {len(both)} frames: fine chroma {fc:.3f} (false-colour gap if <= 0.67); "
                     f"0.2-0.4 amplitude {det:.3f} with noise share {ns:.3f} of R9's (detail gap if >= 1.05 and <= 1.25)")
        lines.append(f"  false-colour gap: {'yes' if fc <= 0.67 else 'no'}; detail gap: {'yes' if det >= 1.05 and ns <= 1.25 else 'no'}; "
                     f"R9 at least 1.5x LRD's fine chroma (candidate A's own decision on no visible gap): {'yes' if fc <= 1 / 1.5 else 'no'}")
    print("\n".join(lines))
    return lines


if __name__ == "__main__":
    command, args = sys.argv[1], [Path(a) for a in sys.argv[2:]]
    if command == "summary":
        summary(args)
    else:
        for d in args:
            result = {"prepare": prepare, "measure": measure, "blocks": blocks}[command](d)
            print(d.name, command, json.dumps(result)[:300])
