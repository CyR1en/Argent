"""Texture and Clarity: what Lightroom does, candidate methods, their fit and their scores (Presence program, F1).

    python -I fit_texture_clarity.py measure        Lightroom's renders: gratings, steps, colour, noise, law, combos
    python -I fit_texture_clarity.py fit            fit every candidate's constants in Lightroom's own terms
    python -I fit_texture_clarity.py score          score the candidates through Argent's film, both stocks
    python -I fit_texture_clarity.py all            the three in order

Everything is measured on log2 luminance g. Lightroom's exports are 16-bit ProPhoto (D50), read as linear Y; the charts
are rebuilt bit for bit by `presence_charts`. A slider's change is the render at a value less the render at 0, never
against the chart's own values, since the DNG charts take Lightroom's raw tone curve. Results go to the evidence folder
(`OUT`), as JSON beside `report.md`.
"""
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import presence_charts  # noqa: E402
import probe  # noqa: E402

MAIN = Path("/Users/cyr1en/Developer/Argent")
DATA = MAIN / "references" / "lightroom-probe"
SPIKE = MAIN / ".build" / "release" / "argent-spike"
STOCKS = MAIN / "build" / "stocks"
PROBE_RAW = MAIN / "samples" / "ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW"
EVIDENCE = Path("/Users/cyr1en/Documents/ArgentResearch/presence-20261111.noindex")
OUT = EVIDENCE / "fit" / "texture-clarity"
LAYOUTS = EVIDENCE / "probe" / "chart-layouts"
PROPHOTO_Y = np.array([0.2880402, 0.7118741, 0.0000857])
GAMMA = 461 / 256
SLIDERS = ("clarity", "texture")
CHART_VALUES = (-100, -50, -25, 25, 50, 100)
RAW_VALUES = (-100, -75, -50, -25, -10, 10, 25, 50, 75, 100)
GRATING_CHARTS = ("p-grating-m4", "p-grating-m2", "p-grating-0", "p-grating-p1.5", "p-grating-0-half")


# MARK: Reading

def export_path(job, slider=None, value=None, name=None):
    folder = DATA / f"exports-{job}"
    if name:
        return folder / f"{job}_{name}.tif"
    return folder / (f"{job}_00_base.tif" if slider is None else f"{job}_{slider}_{value:+d}.tif")


def _strip(path):
    """(offset, height, width, samples) of an uncompressed single-strip 16-bit little-endian TIFF, as Lightroom
    writes its exports."""
    with open(path, "rb") as f:
        head = f.read(8)
        if head[:2] != b"II":
            raise SystemExit(f"{path}: expected a little-endian TIFF")
        f.seek(int.from_bytes(head[4:8], "little"))
        n = int.from_bytes(f.read(2), "little")
        entries = np.frombuffer(f.read(12 * n), dtype=np.dtype([("tag", "<u2"), ("type", "<u2"), ("count", "<u4"),
                                                                ("value", "<u4")]))
    tags = {int(t["tag"]): (int(t["type"]), int(t["count"]), int(t["value"])) for t in entries}
    value = lambda t: tags[t][2] & 0xFFFF if tags[t][0] == 3 else tags[t][2]  # noqa: E731
    if value(259) != 1 or tags[273][1] != 1:
        raise SystemExit(f"{path}: expected one uncompressed strip")
    return tags[273][2], value(257), value(256), value(277)


def read_rgb(path, rows=None):
    """Linear ProPhoto RGB (D50) of a Lightroom export, float32, optionally only `rows` (a slice)."""
    offset, h, w, spp = _strip(path)
    m = np.memmap(path, dtype="<u2", mode="r", offset=offset, shape=(h, w, spp))
    part = m[rows] if rows is not None else m
    out = np.power(part[..., :3].astype(np.float32) / np.float32(65535), np.float32(GAMMA))
    del m
    return out


def read_y(path, rows=None):
    """Linear luminance Y (D50, white 1) of a Lightroom export, float32, read in bands to keep memory low."""
    offset, h, w, spp = _strip(path)
    m = np.memmap(path, dtype="<u2", mode="r", offset=offset, shape=(h, w, spp))
    lo, hi = (0, h) if rows is None else (rows.start or 0, rows.stop or h)
    out = np.empty((hi - lo, w), np.float32)
    weights = PROPHOTO_Y.astype(np.float32)
    for a in range(lo, hi, 512):
        b = min(hi, a + 512)
        out[a - lo:b - lo] = np.power(m[a:b, :, :3].astype(np.float32) / np.float32(65535), np.float32(GAMMA)) @ weights
    del m
    return out


def log2y(Y):
    """g = log2 Y with exact black kept as NaN, so log fits leave it out."""
    with np.errstate(divide="ignore"):
        g = np.log2(Y.astype(np.float32))
    g[Y <= 0] = np.nan
    return g


def layout(chart):
    return json.loads((LAYOUTS / f"{chart}.json").read_text())


# MARK: Gratings

def fundamental(profile, period, x0, x):
    """The complex amplitude of `profile` at the grating's own frequency, phase 0 on the chart's sinusoid
    sin(2 pi (x - x0 + 0.5) / P): least squares on a constant, the fundamental and the harmonics the pixels hold."""
    t = 2 * np.pi * (x - x0 + 0.5) / period
    columns = [np.ones_like(t)]
    for h in range(1, 4):
        if h > 1 and period / h <= 2.0:
            break
        columns += [np.sin(h * t), np.cos(h * t)]
    A = np.stack(columns, axis=1)
    ok = np.isfinite(profile)
    c, *_ = np.linalg.lstsq(A[ok], profile[ok], rcond=1e-9)
    cos = c[2] if len(c) > 2 else 0.0
    return complex(c[1], cos)


def grating_cells(chart):
    """The grating regions of a chart's layout, each with the rows and columns its fundamental is read on: the band's
    central quarter of rows, away from the bands of other amplitude above and below, and the cell less 1/6 of its width
    (at least one pixel) on each side."""
    cells = []
    for r in layout(chart)["regions"]:
        if r["kind"] not in ("grating", "luminance grating"):
            continue
        x0, y0, x1, y1 = r["box"]
        band = y1 - y0
        trim = max(1, (x1 - x0) // 6)
        cells.append({"period": float(r["periodPx"]), "amplitude": float(r.get("amplitudeStops", 0.2)),
                      "mean": float(r.get("meanStops", 0.0)), "ground": r.get("ground"), "x0": r["x0"],
                      "rows": (y0 + 3 * band // 8, y1 - 3 * band // 8), "cols": (x0 + trim, x1 - trim),
                      "box": r["box"]})
    return cells


def cell_amplitudes(g, cells):
    """Complex fundamental of every cell of a log2-luminance image, and whether the cell holds exact black."""
    out, clipped = [], []
    for c in cells:
        rows = g[c["rows"][0]:c["rows"][1], c["cols"][0]:c["cols"][1]]
        clipped.append(bool(np.isnan(rows).any()))
        profile = np.nanmean(rows, axis=0) if not np.isnan(rows).all() else np.full(rows.shape[1], np.nan)
        x = np.arange(c["cols"][0], c["cols"][1], dtype=np.float64)
        out.append(fundamental(profile.astype(np.float64), c["period"], c["x0"], x))
    return np.array(out), np.array(clipped)


def measure_gratings():
    """Lightroom's gain and phase on every grating cell of every grating chart, per slider and value."""
    table = {}
    for chart in GRATING_CHARTS:
        cells = grating_cells(chart)
        C0, clip0 = cell_amplitudes(log2y(read_y(export_path(chart))), cells)
        rows = {"cells": [{k: c[k] for k in ("period", "amplitude", "mean")} for c in cells],
                "base": [[z.real, z.imag] for z in C0]}
        for slider in SLIDERS:
            for v in CHART_VALUES:
                Cv, clip = cell_amplitudes(log2y(read_y(export_path(chart, slider, v))), cells)
                ratio = Cv / C0
                rows[f"{slider}{v:+d}"] = {"gain": np.abs(ratio).round(5).tolist(),
                                           "phase": np.degrees(np.angle(ratio)).round(3).tolist(),
                                           "clipped": (clip | clip0).tolist()}
        table[chart] = rows
    return table


# MARK: Step edges

STEP_OFFSETS = (-512, -256, -128, -64, -32, -16, -8, -4, -2, -1, 0, 1, 3, 7, 15, 31, 63, 127, 255, 511)


def bar_profiles(g, chart):
    """Each bar's row-mean log2 luminance over its central half of rows, with the bar's layout entry."""
    out = []
    for r in layout(chart)["regions"]:
        if r["kind"] != "bar":
            continue
        x0, y0, x1, y1 = r["box"]
        q = (y1 - y0) // 4
        out.append((r, np.nanmean(g[y0 + q:y1 - q, x0:x1], axis=0).astype(np.float64)))
    return out


def measure_steps(chart="p-steps"):
    """Lightroom's change across each bar's rising and falling edges, folded so offset 0 is the first pixel on the
    high side and negative offsets lie on the low side; both edges averaged."""
    base = bar_profiles(log2y(read_y(export_path(chart))), chart)
    table = {"bars": [{k: r[k] for k in ("ground", "groundStops", "stepStops", "highColumns")} for r, _ in base],
             "offsets": list(STEP_OFFSETS)}
    for slider in SLIDERS:
        for v in CHART_VALUES:
            prof = bar_profiles(log2y(read_y(export_path(chart, slider, v))), chart)
            rows = []
            for (r, p0), (_, pv) in zip(base, prof):
                d = pv - p0
                a, b = r["highColumns"]
                a -= r["box"][0]
                b -= r["box"][0]
                rising = np.array([d[a + o] for o in STEP_OFFSETS])
                falling = np.array([d[b - 1 - o] for o in STEP_OFFSETS])
                rows.append({"profile": ((rising + falling) / 2).round(5).tolist(),
                             "lowFar": float(np.mean(d[:a // 4])), "highMid": float(np.mean(d[a + (b - a) // 3:b - (b - a) // 3])),
                             "full": d.astype(np.float32)})
            table[f"{slider}{v:+d}"] = rows
    return table


# MARK: Candidates. Each makes a detail signal D in stops from linear luminance Y; the stage is g' = g + k(v) D.

def _area(Y, fh, fw):
    """Exact area average of Y into fh x fw cells, in linear light, as `ToneBaseField`'s guide pass."""
    h, w = Y.shape
    if h % fh == 0 and w % fw == 0:
        return Y.reshape(fh, h // fh, fw, w // fw).mean(axis=(1, 3), dtype=np.float64)
    return probe.area_matrix(h, fh) @ Y.astype(np.float64) @ probe.area_matrix(w, fw).T


def field_shape(shape, long_side):
    h, w = shape
    F = min(long_side, max(h, w))
    return (probe.rounded(h * F / w), F) if w >= h else (F, probe.rounded(w * F / h))


def guided_coefficients(Y, long_side, radius_fraction, epsilon, share=0.5):
    """The self-guided filter's (a, b) of log2 luminance on a field `long_side` pixels long, the field made by area
    averages in linear light, then boxed at `share` of the radius: `ToneBaseField`'s math with free constants."""
    fh, fw = field_shape(Y.shape, long_side)
    g = np.clip(np.log2(np.sqrt(_area(Y, fh, fw) ** 2 + 1e-12)), -40, 40)
    r = max(1, probe.rounded(radius_fraction * max(fh, fw)))
    mu = probe.box(g, r)
    var = np.maximum(probe.box(g * g, r) - mu * mu, 0)
    a = var / (var + epsilon)
    rc = max(1, probe.rounded(r * share))
    return probe.box(a, rc), probe.box(mu - a * mu, rc)


def guided_detail(Y, long_side, radius_fraction, epsilon, share=0.5, g=None):
    """D = g - (a g + b), (a, b) bilinear from the field, g the pixel's own log2 luminance."""
    a, b = guided_coefficients(Y, long_side, radius_fraction, epsilon, share)
    g = np.log2(np.maximum(Y, 2.0 ** -40)) if g is None else g
    return (g - probe.ToneBase.sample(a, Y.shape) * g - probe.ToneBase.sample(b, Y.shape)).astype(np.float32)


# MARK: Colour

def lab_of(rgb):
    """CIELAB (D50) of linear ProPhoto RGB."""
    import presence_stats
    return presence_stats.lab(rgb.astype(np.float64))


def measure_colour(chart="p-colour-texture"):
    """Per ground and period: the luminance grating's gain (log2 Y), the mean change of C*ab and hue over the
    luminance grating, and the chroma grating's gain (its fundamental along the ground's own a*b* direction)."""
    regions = [r for r in layout(chart)["regions"] if r["kind"].endswith("grating")]
    lab0 = lab_of(read_rgb(export_path(chart)))
    out = {}
    for slider in SLIDERS:
        for v in (-100, 100):
            lab = lab_of(read_rgb(export_path(chart, slider, v)))
            rows = []
            for r in regions:
                x0, y0, x1, y1 = r["box"]
                q, t = (y1 - y0) // 4, (x1 - x0) // 6
                win = (slice(y0 + q, y1 - q), slice(x0 + t, x1 - t))
                a0, av = lab0[win], lab[win]
                C0, Cv = np.hypot(a0[..., 1], a0[..., 2]), np.hypot(av[..., 1], av[..., 2])
                h0 = np.degrees(np.arctan2(a0[..., 2].mean(), a0[..., 1].mean()))
                hv = np.degrees(np.arctan2(av[..., 2].mean(), av[..., 1].mean()))
                x = np.arange(x0 + t, x1 - t, dtype=np.float64)
                if r["kind"] == "chroma grating":
                    # The swing's a*b* direction is read off the base render, its first principal axis.
                    da0 = a0[..., 1:].mean(axis=0) - a0[..., 1:].mean(axis=(0, 1))
                    axis = np.linalg.svd(da0, full_matrices=False)[2][0]
                    p0, pv = da0 @ axis, (av[..., 1:].mean(axis=0) - av[..., 1:].mean(axis=(0, 1))) @ axis
                    gain = abs(fundamental(pv, r["periodPx"], r["x0"], x)) / abs(fundamental(p0, r["periodPx"], r["x0"], x))
                else:
                    g0, gv = np.log2(probe.luminance(a0[..., 0])).mean(axis=0), np.log2(probe.luminance(av[..., 0])).mean(axis=0)
                    gain = abs(fundamental(gv, r["periodPx"], r["x0"], x)) / abs(fundamental(g0, r["periodPx"], r["x0"], x))
                rows.append({"kind": r["kind"], "ground": r["ground"], "period": r["periodPx"], "gain": float(gain),
                             "dC": float((Cv - C0).mean()), "dL": float((av[..., 0] - a0[..., 0]).mean()),
                             "dh": float((hv - h0 + 180) % 360 - 180), "C0": float(C0.mean())})
            out[f"{slider}{v:+d}"] = rows
            del lab
    return out


# MARK: The Laplacian pyramid (Burt and Adelson's 5-tap kernel, edges clamped)

K5 = np.array([1, 4, 6, 4, 1], np.float32) / 16


def _blur5(x):
    for axis in (0, 1):
        p = np.pad(x, [(2, 2) if a == axis else (0, 0) for a in (0, 1)], mode="edge")
        n = x.shape[axis]
        x = sum(K5[i] * np.take(p, np.arange(i, i + n), axis=axis) for i in range(5))
    return x


def _down(x):
    return _blur5(x)[::2, ::2]


def _up(x, shape):
    y = np.zeros(shape, np.float32)
    y[::2, ::2] = x[:(shape[0] + 1) // 2, :(shape[1] + 1) // 2]
    return 4 * _blur5(y)


def pyramid(g, levels):
    """Laplacian levels 0..levels-1 and the Gaussian residual."""
    out, cur = [], g.astype(np.float32)
    for _ in range(levels):
        nxt = _down(cur)
        out.append(cur - _up(nxt, cur.shape))
        cur = nxt
    return out, cur


def collapse(laplacians, residual):
    cur = residual
    for L in reversed(laplacians):
        cur = L + _up(cur, L.shape)
    return cur


def level_period(level):
    """The period, in the level's full-resolution pixels, at the centre of Laplacian level `level`'s band."""
    return 2.0 ** (level + 1.5)


def gated_pyramid_detail(g, long_side, top_fraction, epsilon, gate_from=2, window=2, fine_weight=1.0):
    """Clarity's positive detail as a band-gated pyramid: every Laplacian level whose band centre lies under
    `top_fraction` of the frame's long side, each scaled by eps / (E + eps), E the level's local mean of L^2 over a
    (2 window + 1)^2 box of its own samples; levels under `gate_from` pass ungated, times `fine_weight`. Coarser levels
    and the residual are left out, so the band's top edge is a share of the frame."""
    top = max(1, int(np.floor(np.log2(top_fraction * long_side) - 1.5)) + 1)
    levels, residual = pyramid(g, top)
    for i, L in enumerate(levels):
        if i < gate_from:
            levels[i] = L * np.float32(fine_weight)
        else:
            E = probe.box(L.astype(np.float64) ** 2, window)
            levels[i] = (L * (epsilon / (E + epsilon))).astype(np.float32)
    return collapse(levels, np.zeros_like(residual))


def gaussian_highpass_detail(g, sigma):
    """g less its Gaussian blur of `sigma` pixels (three box passes, as a GPU would make it)."""
    r = max(1, int(round(np.sqrt(12 * sigma ** 2 / 3 + 1) / 2 - 0.5)))
    b = g.astype(np.float64)
    for _ in range(3):
        b = probe.box(b, r)
    return (g - b).astype(np.float32)


# MARK: Photographs at the scorecard's resolution

PHOTOS = ("p-raw", "p-photo-hazy", "p-photo-sky", "p-photo-skin", "p-photo-saturated", "p-photo-foliage",
          "p-photo-texture", "p-photo-iso", "p-photo-night", "p-photo-flat", "p-photo-contrast")
PHOTO_VALUES = (-100, -50, 50, 100)


def photo_blocks(job):
    """Lightroom's renders of a photograph as 4 x 4 block means of linear luminance (the scorecard's samples):
    {"base": Y0, "clarity+100": Y, ...}, cached in the scratch folder."""
    path = OUT / "scratch" / f"blocks-{job}.npz"
    if path.exists():
        return dict(np.load(path))
    out = {"base": probe.block_mean(read_y(export_path(job)))}
    for slider in SLIDERS:
        for v in (RAW_VALUES if job == "p-raw" else PHOTO_VALUES):
            out[f"{slider}{v:+d}"] = probe.block_mean(read_y(export_path(job, slider, v)))
    path.parent.mkdir(parents=True, exist_ok=True)
    np.savez(path, **out)
    return out


# MARK: Candidates as data. A side is one sign of one slider: how D is made, the tone weight m over the base's
# print L*, and the strength k at |value| 25, 50, 75 and 100 (straight between, 0 at 0).

LSTAR_KNOTS = tuple(range(0, 101, 10))


def side(detail, weight=None, law=(0.25, 0.5, 0.75, 1.0), **params):
    return {"detail": detail, "params": params, "weight": list(weight or [1.0] * len(LSTAR_KNOTS)),
            "law": list(law)}


def strength(s, value):
    """k(v): the side's law, piecewise linear in |v| through 0."""
    return float(np.interp(abs(value), (0, 25, 50, 75, 100), (0.0, *s["law"])))


def weight_at(s, lstar):
    return np.interp(lstar, LSTAR_KNOTS, s["weight"]).astype(np.float32)


def make_detail(s, Y, g, scale=1.0):
    """(D, base) in stops for a side, from linear luminance Y and g = log2 Y at the render's own size; `scale` is the
    render's size over the frame's, which pixel-fixed constants (Texture's) follow."""
    p, long_side = s["params"], max(Y.shape)
    if s["detail"] == "guided":
        a, b = guided_coefficients(Y, p["field"], p["radius"], p["epsilon"], p.get("share", 0.5))
        base = probe.ToneBase.sample(a, Y.shape).astype(np.float32) * g + probe.ToneBase.sample(b, Y.shape).astype(np.float32)
        return g - base, base
    if s["detail"] == "gaussian":
        D = gaussian_highpass_detail(g, p["sigma"] * long_side)
        return D, g - D
    if s["detail"] == "gaussian_px":
        D = gaussian_highpass_detail(g, p["sigma_px"] * scale)
        return D, g - D
    if s["detail"] == "band":
        return texture_band(Y, g, p, scale)
    if s["detail"] == "pyramid":
        D = gated_pyramid_detail(g, long_side, p["top"], p["epsilon"], p.get("gate_from", 2), p.get("window", 2))
        return D, g - D
    raise ValueError(s["detail"])


def texture_band(Y, g, p, scale=1.0):
    """Texture's band: a guided filter whose coefficients come from a field `p['field_scale']` of the frame's full
    size (capped at the render's), radius `p['radius_px']` frame pixels, knee `p['epsilon']`; D = g - (a g + b)."""
    long_side = max(Y.shape)
    F = min(long_side, max(16, int(round(long_side / scale * p["field_scale"]))))
    a, b = guided_coefficients(Y, F, p["radius_px"] * scale / long_side, p["epsilon"], p.get("share", 0.5))
    base = probe.ToneBase.sample(a, Y.shape).astype(np.float32) * g + probe.ToneBase.sample(b, Y.shape).astype(np.float32)
    return g - base, base


CANDIDATES = {}


def candidate(name, slider, positive, negative, note):
    CANDIDATES[name] = {"name": name, "slider": slider, "positive": positive, "negative": negative, "note": note}


# MARK: Through Argent's film

import scene_io  # noqa: E402

FLAGS = ("--auto", "--tiff", "--no-lens", "--long-edge", 1752)
SCORE_JOBS = ("p-raw", "p-photo-sky", "p-photo-texture", "p-photo-iso")
SCORE_STOCKS = ("kodak-portra-400", "kodak-ektar-100")
REC2020_Y = presence_charts.REC2020_Y.astype(np.float32)
PRINT_Y = scene_io.REC2020_TO_XYZ_D50[1].astype(np.float32)


def raw_of(job):
    if job == "p-raw":
        return PROBE_RAW
    manifest = json.loads((EVIDENCE / "probe" / "manifest.json").read_text())
    return Path(next(j["source"] for j in manifest["jobs"] if j.get("name") == job))


def print_lstar(p, block=probe.BLOCK):
    """Block L* (4 x 4 means of D50 Y, white 1) of a print array, the scorecard's samples."""
    return probe.lstar(probe.block_mean(p @ PRINT_Y, block).astype(np.float64))


class FilmFrame:
    """One photograph on one stock: Argent's scene, its base print, the print's transfer from scene stops to L*,
    and Lightroom's renders of the same frame, all on the scorecard's 4 x 4 blocks."""

    def __init__(self, job, stock, flags=FLAGS, scale=None, crop=None):
        self.job, self.stock, self.flags = job, stock, tuple(flags) + (("--scale", scale) if scale else ())
        self.crop = crop
        # A quarter-size render is compared pixel for pixel with the full render's 4 x 4 blocks.
        self.block = probe.BLOCK if scale is None else max(1, int(round(probe.BLOCK * scale)))
        self.raw, self.stock_dir = raw_of(job), STOCKS / stock
        self.scene = scene_io.scene_of(self.raw, self.stock_dir, *self.flags, binary=SPIKE)
        self.Y = self.scene @ REC2020_Y
        self.g = np.log2(np.maximum(self.Y, 2.0 ** -20)).astype(np.float32)
        p0 = scene_io.print_of(self.raw, self.stock_dir, self.scene, *self.flags, binary=SPIKE)
        self.L0 = print_lstar(p0, self.block)
        if crop:
            self.L0c = probe.lstar((p0[crop] @ PRINT_Y).astype(np.float64))
            self.xc = np.log2(np.maximum(self.Y[crop].astype(np.float64), 2.0 ** -20) / 0.18)
        del p0
        Yb = probe.block_mean(self.Y, self.block).astype(np.float64)
        self.x = np.log2(np.maximum(Yb, 2.0 ** -20) / 0.18)
        ok = (self.L0 > 0.3) & (self.L0 < 99.0)
        self.T = probe.Transfer(self.x[ok], self.L0[ok])
        self.lr = None
        if scale is None:
            blocks = photo_blocks(job)
            self.lr = {k: probe.lstar(v.astype(np.float64)) for k, v in blocks.items()}
            lr0 = self.lr["base"]
            self.valid = (self.L0 > 0.5) & (self.L0 < 99.5) & (lr0 > 0.5) & (lr0 < 99.5)
            if crop:
                self.lrc = {"base": probe.lstar(read_y(export_path(job), rows=crop[0])[:, crop[1]].astype(np.float64))}
                self.validc = (self.L0c > 0.5) & (self.L0c < 99.5) & (self.lrc["base"] > 0.5) & (self.lrc["base"] < 99.5)

    def delta(self, s, value, detail=None, scale=1.0):
        """The stage's gain in stops at the render's size for side `s` at `value`: k(v) m(L*_base) D."""
        D, base = detail if detail is not None else make_detail(s, self.Y, self.g, scale)
        Lb = self.T(np.log2(np.maximum(np.exp2(base), 2.0 ** -20) / 0.18))
        return (strength(s, value) * weight_at(s, Lb) * D).astype(np.float32)

    def render(self, delta):
        """Block L* of the print of the scene times 2^delta, and with a crop also the crop's full-size L*."""
        p = scene_io.print_of(self.raw, self.stock_dir, self.scene * np.exp2(delta)[..., None], *self.flags,
                              binary=SPIKE)
        blocks = print_lstar(p, self.block)
        return (blocks, probe.lstar((p[self.crop] @ PRINT_Y).astype(np.float64))) if self.crop else blocks

    def lr_crop_change(self, key):
        if key not in self.lrc:
            self.lrc[key] = probe.lstar(read_y(export_path(self.job, *split_key(key)), rows=self.crop[0])[:, self.crop[1]]
                                        .astype(np.float64))
        return self.lrc[key] - self.lrc["base"]

    def lr_change(self, key):
        return self.lr[key] - self.lr["base"]

    def floor(self, key):
        """The score a perfect stage would get: Lightroom's change carried to scene stops through Lightroom's own
        transfer for this frame, then printed through Argent's, against Lightroom's change. It is what remains when
        the two base renders differ in tone."""
        ok = (self.lr["base"] > 0.3) & (self.lr["base"] < 99.0)
        T_lr = probe.Transfer(self.x[ok], self.lr["base"][ok])
        dx = T_lr.inverse(np.clip(self.lr[key], 0.0, 100.0)) - T_lr.inverse(self.lr["base"])
        oracle = self.T(self.x + dx) - self.T(self.x)
        return oracle - self.lr_change(key)


def split_key(key):
    slider = key.rstrip("+-0123456789")
    return slider, int(key[len(slider):])


def central_crop(shape, size=2048):
    h, w = shape
    return (slice((h - size) // 2, (h + size) // 2), slice((w - size) // 2, (w + size) // 2))


def scores(dA, dLR, valid):
    """Per-block RMSE of Argent's change against Lightroom's (L*), the share of Lightroom's change explained, and the
    size of Lightroom's change (rms L*)."""
    d, t = (dA - dLR)[valid], dLR[valid]
    return {"rmse": float(np.sqrt(np.mean(d ** 2))), "r2": float(1 - np.sum(d ** 2) / np.sum((t - t.mean()) ** 2)),
            "lr_rms": float(np.sqrt(np.mean(t ** 2))), "mean_error": float(d.mean())}


# MARK: Fitting a side's tone weight and law through the film's transfer

def _hat(L):
    L = np.clip(L, LSTAR_KNOTS[0], LSTAR_KNOTS[-1])
    step = LSTAR_KNOTS[1] - LSTAR_KNOTS[0]
    i = np.minimum((L // step).astype(int), len(LSTAR_KNOTS) - 2)
    t = (L - np.array(LSTAR_KNOTS)[i]) / step
    P = np.zeros((L.size, len(LSTAR_KNOTS)))
    P[np.arange(L.size), i] = 1 - t
    P[np.arange(L.size), i + 1] += t
    return P


def fit_rows(frame, s, slider, sign, every=5):
    """Samples for fitting one side on one frame and stock: the base's L*, the frame's x, D and Lightroom's change at
    each value of that sign. On the scorecard's blocks, or on the frame's full-size crop when it has one (Texture,
    whose band the blocks average away). A fixed subsample of valid samples."""
    D, base = make_detail(s, frame.Y, frame.g)
    if frame.crop:
        Ds, x, valid = D[frame.crop].astype(np.float64), frame.xc, frame.validc
        Lb = frame.T(base[frame.crop].astype(np.float64) - np.log2(0.18))
        change = frame.lr_crop_change
    else:
        Ds, x, valid = probe.block_mean(D).astype(np.float64), frame.x, frame.valid
        Lb = frame.T(np.log2(np.maximum(probe.block_mean(np.exp2(base)).astype(np.float64), 2.0 ** -20) / 0.18))
        change = frame.lr_change
    del D, base
    idx = np.flatnonzero(valid.ravel())[::every]
    rows = []
    for key in frame.lr:
        if not key.startswith(slider) or np.sign(int(key[len(slider):])) != sign:
            continue
        rows.append({"job": frame.job, "stock": frame.stock, "value": int(key[len(slider):]),
                     "x": x.ravel()[idx], "D": Ds.ravel()[idx], "Lb": Lb.ravel()[idx],
                     "y": change(key).ravel()[idx], "T": frame.T})
    return rows


def fit_side(rows, iterations=10):
    """Least squares for the tone weight m (on LSTAR_KNOTS, scaled to a mean of 1) and one strength per value:
    Lightroom's change against T(x + k m D) - T(x), solved by repeated secant linearisation of the frame's T."""
    m = np.ones(len(LSTAR_KNOTS))
    values = sorted({r["value"] for r in rows})
    k = {v: np.sign(v) * abs(v) / 100 for v in values}
    for _ in range(iterations):
        for r in rows:
            d = k[r["value"]] * (_hat(r["Lb"]) @ m) * r["D"]
            sec = np.where(np.abs(d) > 1e-4, (r["T"](r["x"] + d) - r["T"](r["x"])) / np.where(np.abs(d) > 1e-4, d, 1),
                           r["T"].slope(r["x"]))
            r["S"] = sec
        for v in values:
            x = np.concatenate([r["S"] * (_hat(r["Lb"]) @ m) * r["D"] for r in rows if r["value"] == v])
            y = np.concatenate([r["y"] for r in rows if r["value"] == v])
            k[v] = float(x @ y / (x @ x))
        XtX, Xty = np.zeros((len(m), len(m))), np.zeros(len(m))
        for r in rows:
            X = (k[r["value"]] * r["S"] * r["D"])[:, None] * _hat(r["Lb"])
            XtX += X.T @ X
            Xty += X.T @ r["y"]
        # A second-difference penalty keeps the end knots, where few blocks fall, on the trend of their neighbours.
        P = np.diff(np.eye(len(m)), 2, axis=0)
        lam = 1e-2 * np.trace(XtX) / len(m)
        m = np.linalg.solve(XtX + lam * (P.T @ P) + 1e-6 * lam * np.eye(len(m)), Xty)
        # m is scaled to a mean of 1 over the blocks fitted, so k is the average strength.
        scale = float(np.mean(np.concatenate([_hat(r["Lb"]) @ m for r in rows])))
        m = m / scale
        k = {v: kv * scale for v, kv in k.items()}
    per_frame = {}
    for r in rows:
        x = r["S"] * (_hat(r["Lb"]) @ m) * r["D"]
        per_frame[(r["job"], r["stock"], r["value"])] = float(x @ r["y"] / (x @ x))
    return m, k, per_frame


def law_from(k, per_frame):
    """k at |v| = 25, 50, 75, 100: the pooled strength at 100 times the median over frames of each frame's own
    k(v) / k(100), since the frames that hold the in-between values (the probe raw) adapt to their own strength."""
    sign = int(np.sign(next(iter(k))))
    top = 100 * sign
    ratios = {}
    for (job, stock, v), kv in per_frame.items():
        ratios.setdefault(abs(v), []).append(kv / per_frame[(job, stock, top)])
    a = np.array(sorted(ratios), float)
    b = np.array([np.median(ratios[int(t)]) for t in a])
    return [float(k[top] * np.interp(t, np.r_[0, a], np.r_[0, b])) for t in (25, 50, 75, 100)]


# MARK: The candidates' shapes (their spatial constants, chosen in Lightroom's terms: see the report)

candidate("clarity-guided", "clarity",
          side("guided", field=1024, radius=0.08, epsilon=1.0), side("guided", field=1024, radius=0.02, epsilon=1.0),
          "Recommended. Two guided-filter bases on 1024-pixel fields of linear luminance (ToneBaseField's math), one per sign.")
candidate("clarity-shared-field", "clarity",
          side("guided", field=1024, radius=0.015, epsilon=0.7), side("guided", field=1024, radius=0.015, epsilon=0.7),
          "Both signs read the existing Highlights and Shadows field (0.015, 0.7 stops squared).")
candidate("clarity-gaussian", "clarity",
          side("gaussian", sigma=0.03), side("gaussian", sigma=0.014),
          "Runner-up. A Gaussian high-pass of log2 luminance per sign, not edge-aware.")


candidate("texture-guided-band", "texture",
          side("band", field_scale=0.5, radius_px=20, epsilon=0.25), side("band", field_scale=0.5, radius_px=20, epsilon=0.25),
          "Recommended. A guided filter of log2 luminance, coefficients on a field at half the frame's resolution, "
          "radius 20 frame pixels; the same D for both signs.")
candidate("texture-gaussian", "texture",
          side("gaussian_px", sigma_px=10), side("gaussian_px", sigma_px=10),
          "Runner-up. A Gaussian high-pass of log2 luminance, sigma 10 frame pixels, not edge-aware.")


def fitted_path():
    return OUT / "constants.json"


def load_constants():
    return json.loads(fitted_path().read_text()) if fitted_path().exists() else {"candidates": {}}


def run_fit(slider, names=None, crop=False):
    """Fit every candidate of `slider`: tone weight and law per side, through each frame's film transfer, pooled over
    SCORE_JOBS on both stocks. Writes the constants into constants.json."""
    names = names or [n for n, c in CANDIDATES.items() if c["slider"] == slider]
    rows = {(n, sign): [] for n in names for sign in (1, -1)}
    for job in SCORE_JOBS:
        for stock in SCORE_STOCKS:
            frame = FilmFrame(job, stock, crop=central_crop((4672, 7008)) if crop else None)
            for n in names:
                for sign, key in ((1, "positive"), (-1, "negative")):
                    rows[(n, sign)] += fit_rows(frame, CANDIDATES[n][key], slider, sign)
            print(f"  rows {job} {stock}", flush=True)
            del frame
    constants = load_constants()
    for n in names:
        c = json.loads(json.dumps(CANDIDATES[n]))
        for sign, key in ((1, "positive"), (-1, "negative")):
            m, k, per_frame = fit_side(rows[(n, sign)])
            c[key]["weight"] = [round(float(v), 4) for v in m]
            c[key]["law"] = [round(v, 4) for v in law_from(k, per_frame)]
            c[key]["perValue"] = {str(v): round(kv, 4) for v, kv in sorted(k.items())}
            c[key]["perFrame"] = {f"{j} {st} {v:+d}": round(kv, 4) for (j, st, v), kv in sorted(per_frame.items())}
        c["fittedOn"] = {"jobs": list(SCORE_JOBS), "stocks": list(SCORE_STOCKS), "flags": [str(f) for f in FLAGS]}
        constants["candidates"][n] = c
        print(n, json.dumps({k: c[k]["law"] for k in ("positive", "negative")}), flush=True)
    fitted_path().write_text(json.dumps(constants, indent=1))
    return constants


def run_score(slider, names=None, values=(-100, -50, 50, 100), jobs=SCORE_JOBS, stocks=SCORE_STOCKS, flags=FLAGS,
              label="film", crop=False):
    """Render every fitted candidate of `slider` through Argent's film and score its print change against
    Lightroom's, per frame, stock and value. Writes scores-<slider>-<label>.json and returns the rows."""
    constants = load_constants()["candidates"]
    names = names or [n for n, c in constants.items() if c["slider"] == slider]
    out = []
    for job in jobs:
        for stock in stocks:
            frame = FilmFrame(job, stock, flags, crop=central_crop((4672, 7008)) if crop else None)
            for n in names:
                c = constants[n]
                details = {key: make_detail(c[key], frame.Y, frame.g) for key in ("positive", "negative")}
                for v in values:
                    key = "positive" if v > 0 else "negative"
                    lr_key = f"{slider}{v:+d}"
                    delta = frame.delta(c[key], v, details[key])
                    rendered = frame.render(delta)
                    dA = (rendered[0] if frame.crop else rendered) - frame.L0
                    row = {"candidate": n, "job": job, "stock": stock, "value": v,
                           **scores(dA, frame.lr_change(lr_key), frame.valid),
                           "floor": float(np.sqrt(np.mean(frame.floor(lr_key)[frame.valid] ** 2)))}
                    if frame.crop:
                        crop = scores(rendered[1] - frame.L0c, frame.lr_crop_change(lr_key), frame.validc)
                        row.update({f"crop_{m}": x for m, x in crop.items()})
                    out.append(row)
                    print(f"  {n:22s} {job:16s} {stock:17s} {v:+4d} rmse {row['rmse']:5.2f} r2 {row['r2']:+.3f} "
                          f"lr {row['lr_rms']:5.2f} floor {row['floor']:4.2f}", flush=True)
                del details
            del frame
    (OUT / f"scores-{slider}-{label}.json").write_text(json.dumps(out, indent=0))
    return out


def summarise(rows):
    """Mean of each score over frames and stocks, per candidate and value, and over all values."""
    table = {}
    for r in rows:
        for key in ((r["candidate"], r["value"]), (r["candidate"], "all"), (r["candidate"], r["stock"])):
            table.setdefault(key, []).append(r)
    metrics = [m for m in ("rmse", "r2", "lr_rms", "floor", "crop_rmse", "crop_r2", "crop_lr_rms") if m in rows[0]]
    return {f"{n} {v}": {m: round(float(np.mean([x[m] for x in rs])), 3) for m in metrics}
            | {"runs": len(rs)} for (n, v), rs in table.items()}


# MARK: Preview scale, the tone step's leak and placement on the print

def run_scale(name, job="p-raw", stock="kodak-portra-400", values=(-100, 100), scale=0.25):
    """The stage at `scale` against full size: rms over the preview's pixels of (preview's L* change) less (the full
    render's change on its 4 x 4 blocks, the same grid), in L*."""
    c = load_constants()["candidates"][name]
    full = FilmFrame(job, stock)
    changes = {v: full.render(full.delta(c["positive" if v > 0 else "negative"], v)) - full.L0 for v in values}
    del full
    small = FilmFrame(job, stock, scale=scale)
    out = {}
    for v in values:
        d = small.render(small.delta(c["positive" if v > 0 else "negative"], v, scale=scale)) - small.L0
        h, w = min(d.shape[0], changes[v].shape[0]), min(d.shape[1], changes[v].shape[1])
        diff = d[:h, :w] - changes[v][:h, :w]
        out[str(v)] = {"rms": float(np.sqrt(np.mean(diff ** 2))), "p99": float(np.percentile(np.abs(diff), 99)),
                       "change_rms": float(np.sqrt(np.mean(changes[v] ** 2)))}
    return out


def leak_estimate(name, job="p-raw", stock="kodak-portra-400", value=100, slope=2.86):
    """What feeding the staged scene to Auto's tone step costs, inferred: the change of the tone base field
    (0.015, 0.7 on a 1024 field) between the scene and the staged scene, times the 2.86 L* per stop of base the
    doubled-scene check measured (README, 'The render as arrays'). Returns rms and p99 in L* over blocks."""
    c = load_constants()["candidates"][name]
    frame = FilmFrame(job, stock)
    Y1 = frame.Y * np.exp2(frame.delta(c["positive" if value > 0 else "negative"], value))
    bases = []
    for Y in (frame.Y, Y1):
        tb = probe.ToneBase(probe.block_mean(Y).astype(np.float64))
        g = np.log2(np.maximum(probe.block_mean(Y).astype(np.float64), 2.0 ** -20))
        bases.append(tb.base(g, probe.RADIUS_FRACTION, probe.EPSILON))
    d = slope * (bases[1] - bases[0])
    return {"rms": float(np.sqrt(np.mean(d[frame.valid] ** 2))), "p99": float(np.percentile(np.abs(d[frame.valid]), 99))}


def run_print_side(name, slider, jobs=SCORE_JOBS, stocks=SCORE_STOCKS, values=(-100, -50, 50, 100)):
    """The same detail made from the base print's luminance and applied to the print (after the film), its weight
    and law refitted there (the print's own L* curve is its transfer), scored like the scene stage."""
    c = load_constants()["candidates"][name]
    rows, prints = {1: [], -1: []}, []
    for job in jobs:
        for stock in stocks:
            frame = FilmFrame(job, stock)
            p0 = scene_io.print_of(frame.raw, frame.stock_dir, frame.scene, *frame.flags, binary=SPIKE)
            Yp = (p0 @ PRINT_Y).astype(np.float32)
            del p0, frame.scene
            gp = np.log2(np.maximum(Yp, 2.0 ** -20)).astype(np.float32)
            frame.Y, frame.g = Yp, gp
            frame.x = np.log2(np.maximum(probe.block_mean(Yp).astype(np.float64), 2.0 ** -20) / 0.18)
            frame.T = PrintCurve()
            for sign, key in ((1, "positive"), (-1, "negative")):
                rows[sign] += [r for r in fit_rows(frame, c[key], slider, sign) if r["value"] in values]
            prints.append(frame)
    fitted = {}
    for sign, key in ((1, "positive"), (-1, "negative")):
        m, k, per_frame = fit_side(rows[sign])
        fitted[key] = dict(c[key], weight=list(m), law=law_from(k, per_frame))
    out = []
    for frame in prints:
        for v in values:
            s = fitted["positive" if v > 0 else "negative"]
            Yv = frame.Y * np.exp2(frame.delta(s, v))
            dA = probe.lstar(probe.block_mean(Yv).astype(np.float64)) - probe.lstar(probe.block_mean(frame.Y).astype(np.float64))
            out.append({"candidate": name + " on the print", "job": frame.job, "stock": frame.stock, "value": v,
                        **scores(dA, frame.lr_change(f"{slider}{v:+d}"), frame.valid), "floor": 0.0})
    return out, fitted


class PrintCurve:
    """The print's own transfer from log2 of its luminance over 0.18 to L*, exact."""

    def __call__(self, x):
        return probe.lstar(0.18 * np.exp2(np.asarray(x, dtype=np.float64)))

    def slope(self, x):
        return (self(np.asarray(x) + 1e-3) - self(np.asarray(x) - 1e-3)) / 2e-3


# MARK: The command line

def run_measure():
    """Lightroom's renders, measured: the grating table, the step profiles (folded), the colour chart."""
    steps = {}
    for chart in ("p-steps", "p-steps-half"):
        t = measure_steps(chart)
        steps[chart] = {k: ([{x: y for x, y in r.items() if x != "full"} for r in v] if isinstance(v, list) and v and
                            isinstance(v[0], dict) and "profile" in v[0] else v) for k, v in t.items()}
    out = {"gratings": measure_gratings(), "steps": steps, "colour": measure_colour()}
    (OUT / "measure.json").write_text(json.dumps(out))
    return out


def print_summary(rows):
    for key, v in sorted(summarise(rows).items()):
        print(f"{key:40s} " + "  ".join(f"{m} {x:.3f}" if isinstance(x, float) else f"{m} {x}" for m, x in v.items()))


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "score"
    OUT.mkdir(parents=True, exist_ok=True)
    if command in ("measure", "all"):
        run_measure()
        print("measured:", OUT / "measure.json")
    if command in ("fit", "all"):
        run_fit("clarity")
        run_fit("texture", crop=True)
    if command in ("score", "all"):
        print_summary(run_score("clarity"))
        print_summary(run_score("texture", crop=True))


if __name__ == "__main__":
    main()
