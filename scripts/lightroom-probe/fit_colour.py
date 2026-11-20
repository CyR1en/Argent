"""Saturation and Vibrance against Lightroom's renders: the measurements, the candidates, the fit and the scores.

    python -I fit_colour.py tables        read the colour grids' and p-combo's exports into patch tables (data/)
    python -I fit_colour.py saturation    Lightroom's Saturation on the grids, the candidates, their fit and scores
    python -I fit_colour.py vibrance      the same for Vibrance
    python -I fit_colour.py compose       Vibrance with Saturation, Contrast, Exposure and Dehaze
    python -I fit_colour.py film [--quick] through Argent's film: placement, stocks, photographs, scale
    python -I fit_colour.py all           every step, then constants.json

The validation (V3), written under OUT (validate/colour):

    python -I fit_colour.py reproduce       F3's Vibrance film headline from an empty scratch, run by run
    python -I fit_colour.py lightroom-terms round 3's grids: Vibrance between its knots, both sliders beside Exposure
    python -I fit_colour.py fit-pass        round 1's frames on six stocks over the strength grid ([--part=i/n])
    python -I fit_colour.py strength        each stock's Vibrance strength and the stock property that predicts it
    python -I fit_colour.py insample-pass   round 1's frames at the fitted strengths
    python -I fit_colour.py heldout-pass    the twenty held-out frames on six stocks
    python -I fit_colour.py port-pass       half-float outputs against the prototype's, for the bars' margin
    python -I fit_colour.py level           where V-A's lightness weight falls on the print against Lightroom's level
    python -I fit_colour.py heldout [--fresh]  the held-out scores (from the kept runs, or rendered again)
    python -I fit_colour.py bars            bars.json
    python -I fit_colour.py spike-bars --binary PATH [--slider S]  a Swift build against the bars
    python -I fit_colour.py validate        every step above but spike-bars, in order

F3's steps read F3's results from FIT (fit/colour) and write under OUT. Patch tables are small and kept;
full-size arrays live only in OUT/scratch while a step runs.
"""
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import probe  # noqa: E402
import scene_io  # noqa: E402

MAIN = Path("/Users/cyr1en/Developer/Argent")
REFS = MAIN / "references" / "lightroom-probe"
EVIDENCE = Path("/Users/cyr1en/Documents/ArgentResearch/presence-20261111.noindex")
# F3's fit is read from FIT and never written; the validation (V3) writes under OUT.
FIT = EVIDENCE / "fit" / "colour"
OUT = EVIDENCE / "validate" / "colour"
DATA = OUT / "data"
SCRATCH = OUT / "scratch"
LAYOUTS = EVIDENCE / "probe" / "chart-layouts"
SPIKE = MAIN / ".build" / "release" / "argent-spike"
STOCKS = MAIN / "build" / "stocks"
PROBE_RAW = MAIN / "samples" / "ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW"

# MARK: Colour spaces

PROPHOTO_TO_XYZ = np.array([[0.7976749, 0.1351917, 0.0313534],
                            [0.2880402, 0.7118741, 0.0000857],
                            [0.0000000, 0.0000000, 0.8252100]])
D50 = np.array([0.96422, 1.0, 0.82521])
D65 = np.array([0.95047, 1.0, 1.08883])
BRADFORD = np.array([[0.8951, 0.2664, -0.1614], [-0.7502, 1.7135, 0.0367], [0.0389, -0.0685, 1.0296]])


def bradford(src, dst):
    s, t = BRADFORD @ src, BRADFORD @ dst
    return np.linalg.inv(BRADFORD) @ np.diag(t / s) @ BRADFORD


D50_TO_D65 = bradford(D50, D65)
REC2020_TO_XYZ65 = np.array([[0.636958, 0.144617, 0.168881],
                             [0.262700, 0.677998, 0.059302],
                             [0.000000, 0.028073, 1.060985]])
REC2020_TO_XYZ50 = bradford(D65, D50) @ REC2020_TO_XYZ65
PROPHOTO_TO_REC2020 = np.linalg.inv(REC2020_TO_XYZ50) @ PROPHOTO_TO_XYZ
REC2020_TO_PROPHOTO = np.linalg.inv(PROPHOTO_TO_REC2020)
REC2020_Y = REC2020_TO_XYZ65[1]
PROPHOTO_Y = PROPHOTO_TO_XYZ[1]

# Oklab (Ottosson). M1 takes XYZ D65 to LMS; its rows are scaled so that the D65 white maps to (1, 1, 1) exactly,
# as the literature note's normalised matrix does, so a grey has a and b of exactly zero.
OK_M1 = np.array([[0.8189330101, 0.3618667424, -0.1288597137],
                  [0.0329845436, 0.9293118715, 0.0361456387],
                  [0.0482003018, 0.2643662691, 0.6338517070]])
OK_M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                  [1.9779984951, -2.4285922050, 0.4505937099],
                  [0.0259040371, 0.7827717662, -0.8086757660]])
OK_M2_INV = np.linalg.inv(OK_M2)


def _ok_lms(rgb_to_xyz65):
    m = OK_M1 @ rgb_to_xyz65
    return m / m.sum(axis=1, keepdims=True)


LMS_FROM = {"rec2020": _ok_lms(REC2020_TO_XYZ65), "prophoto": _ok_lms(D50_TO_D65 @ PROPHOTO_TO_XYZ)}
LMS_TO = {k: np.linalg.inv(v) for k, v in LMS_FROM.items()}


def oklab(rgb, space):
    """Oklab of linear RGB in `space` ("rec2020" D65, or "prophoto" D50 adapted to D65 by Bradford)."""
    lms = np.asarray(rgb, np.float64) @ LMS_FROM[space].T
    return np.cbrt(lms) @ OK_M2.T


def oklab_to_rgb(lab, space):
    return (np.asarray(lab, np.float64) @ OK_M2_INV.T) ** 3 @ LMS_TO[space].T


def lab_of_xyz(xyz, white=D50):
    """CIELAB of XYZ with `white` at Y = 1."""
    t = np.asarray(xyz, np.float64) / white
    f = np.where(t > (6 / 29) ** 3, np.cbrt(np.maximum(t, 0)), t / (3 * (6 / 29) ** 2) + 4 / 29)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], axis=-1)


def lab_prophoto(rgb):
    """CIELAB (D50) of linear ProPhoto RGB: the space every comparison with Lightroom is made in."""
    return lab_of_xyz(np.asarray(rgb, np.float64) @ PROPHOTO_TO_XYZ.T)


def lch(lab):
    lab = np.asarray(lab)
    return lab[..., 0], np.hypot(lab[..., 1], lab[..., 2]), np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360


def hue_diff(h1, h0):
    """h1 - h0 in degrees, wrapped into [-180, 180)."""
    return (np.asarray(h1) - np.asarray(h0) + 180) % 360 - 180


def melissa(linear):
    """The sRGB curve on linear values (Lightroom's "Melissa RGB" when the primaries are ProPhoto's)."""
    x = np.maximum(linear, 0)
    return np.where(x <= 0.0031308, 12.92 * x, 1.055 * np.power(x, 1 / 2.4) - 0.055)


def melissa_inv(encoded):
    x = np.maximum(encoded, 0)
    return np.where(x <= 0.04045, x / 12.92, np.power((x + 0.055) / 1.055, 2.4))


# MARK: Lightroom's exports as patch tables

def export_linear(path):
    """A Lightroom export as linear ProPhoto RGB, float32 (pure gamma 461/256 undone)."""
    img, icc = probe.read_tiff(path)
    gamma = probe.icc_gamma(icc)
    return np.power(img, np.float32(gamma))


def regions(chart):
    return json.loads((LAYOUTS / f"{chart}.json").read_text())["regions"]


INSET = 8
RAMP_BIN = 8


def sample_regions(img, regs):
    """Each patch's mean over its interior (INSET pixels in from each edge) and its spread; each ramp's column
    profile, averaged over its interior rows and RAMP_BIN columns."""
    patches, spread, ramps = [], [], []
    for r in regs:
        x0, y0, x1, y1 = r["box"]
        inset = INSET if r["kind"] == "patch" else 0
        a = img[y0 + INSET:y1 - INSET, x0 + inset:x1 - inset]
        if r["kind"] == "patch":
            m = a.reshape(-1, 3).astype(np.float64)
            patches.append(m.mean(0))
            spread.append(m.std(0))
        elif r["kind"] in ("hue ramp", "chroma ramp"):
            col = a.astype(np.float64).mean(0)
            n = col.shape[0] // RAMP_BIN * RAMP_BIN
            ramps.append(col[:n].reshape(-1, RAMP_BIN, 3).mean(1))
    return np.array(patches), np.array(spread), np.array(ramps)


GRIDS = {"dng": "p-colour-grid", "tif": "p-colour-grid-tif"}


def grid_table(which, refresh=False):
    """The colour grid's patches and ramps in every render of `which` ("dng" or "tif", or a later round's job of the
    same chart such as "r-colour-grid"), linear ProPhoto RGB. Returns (meta, renders): meta holds each patch's group
    and nominal L*, C*, h and its chart value (linear Rec. 2020); renders maps "base", "saturation:+100", "ex+1:sat+50"
    and so on to {"patch": (n, 3), "spread": (n, 3), "ramp": (r, m, 3)}."""
    job = GRIDS.get(which, which)
    cache = DATA / f"grid-{which}.npz"
    regs = regions("p-colour-grid")
    patches = [r for r in regs if r["kind"] == "patch"]
    meta = {"group": np.array([r["group"] for r in patches]),
            "L": np.array([r.get("nominal", {}).get("L", r["lch"][0]) for r in patches], float),
            "C": np.array([r.get("nominal", {}).get("C", r["lch"][1]) for r in patches], float),
            "h": np.array([r.get("nominal", {}).get("h", r["lch"][2]) for r in patches], float),
            "frac": np.array([r.get("nominal", {}).get("fractionOfEdge", np.nan) for r in patches], float),
            "chart": np.array([r["rgb"] for r in patches], float),
            "ramps": [{k: v for k, v in r.items() if k != "box"} for r in regs if "ramp" in r["kind"]]}
    if cache.exists() and not refresh:
        z = np.load(cache)
        renders = {}
        for key in z.files:
            name, part = key.rsplit("|", 1)
            renders.setdefault(name, {})[part] = z[key]
        return meta, renders
    folder = REFS / f"exports-{job}"
    renders = {}
    for path in sorted(folder.glob("*.tif")):
        name = "base" if path.stem.endswith("_00_base") else path.stem[len(job) + 1:].replace("_", ":")
        p, s, r = sample_regions(export_linear(path), regs)
        renders[name] = {"patch": p, "spread": s, "ramp": r}
    DATA.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(cache, **{f"{n}|{k}": v for n, d in renders.items() for k, v in d.items()})
    return meta, renders


def combo_table(refresh=False):
    """p-combo's colour patches (24 hues at L* 50, half and 0.95 of the edge) and its neutral ramp in every render."""
    cache = DATA / "combo.npz"
    regs = regions("p-combo")
    patches = [r for r in regs if r["kind"] == "patch"]
    meta = {"L": np.array([r["nominal"]["L"] for r in patches]), "C": np.array([r["nominal"]["C"] for r in patches]),
            "h": np.array([r["nominal"]["h"] for r in patches]),
            "frac": np.array([r["nominal"]["fractionOfEdge"] for r in patches]),
            "chart": np.array([r["rgb"] for r in patches])}
    ramp = next(r for r in regs if r["kind"] == "ramp")
    meta["rampChart"] = probe_ramp_values(ramp)
    if cache.exists() and not refresh:
        z = np.load(cache)
        renders = {}
        for key in z.files:
            name, part = key.rsplit("|", 1)
            renders.setdefault(name, {})[part] = z[key]
        return meta, renders
    renders = {}
    for path in sorted((REFS / "exports-p-combo").glob("*.tif")):
        name = "base" if path.stem.endswith("_00_base") else path.stem[len("p-combo_"):]
        img = export_linear(path)
        x0, y0, x1, y1 = ramp["box"]
        row = img[y0 + INSET:y1 - INSET, x0:x1].astype(np.float64).mean(0)
        n = row.shape[0] // RAMP_BIN * RAMP_BIN
        renders[name] = {"patch": sample_regions(img, patches)[0], "ramp": row[:n].reshape(-1, RAMP_BIN, 3).mean(1)}
    np.savez_compressed(cache, **{f"{n}|{k}": v for n, d in renders.items() for k, v in d.items()})
    return meta, renders


def probe_ramp_values(ramp):
    """p-combo's neutral ramp as the chart holds it, per RAMP_BIN columns: 2^(-12 (1 - (x + 0.5) / width))."""
    x0, _, x1, _ = ramp["box"]
    x = np.arange(x0, x1) - x0
    v = 2.0 ** (-12 * (1 - (x + 0.5) / (x1 - x0)))
    n = v.shape[0] // RAMP_BIN * RAMP_BIN
    return v[:n].reshape(-1, RAMP_BIN).mean(1)


def usable(rgb):
    """Patches whose every channel is inside the export's range with a margin, so no channel was clipped."""
    return (rgb.min(-1) > 0.003) & (rgb.max(-1) < 0.99)


# MARK: Lightroom's tone curve

class Tone:
    """Lightroom's raw tone curve for the DNG charts, from scene luminance to output luminance, both linear:
    measured on p-colour-grid's neutral patches (chart value against base render), interpolated in log-log and
    extended along the end segments."""

    def __init__(self, chart_luminance=None, render_luminance=None):
        if chart_luminance is None:
            meta, renders = grid_table("dng")
            n = meta["group"] == "neutral"
            chart_luminance, render_luminance = meta["chart"][n] @ REC2020_Y, renders["base"]["patch"][n] @ PROPHOTO_Y
        with np.errstate(divide="ignore"):
            x, y = np.log2(chart_luminance), np.log2(render_luminance)
        keep = np.isfinite(x) & np.isfinite(y)
        x, y = x[keep], y[keep]
        order = np.argsort(x)
        x, y = x[order], np.maximum.accumulate(y[order])
        strict = np.concatenate([[True], np.diff(y) > 1e-9])
        self.x, self.y = x[strict], y[strict]

    @staticmethod
    def _interp(v, xs, ys):
        lv = np.log2(np.maximum(v, 1e-12))
        out = np.interp(lv, xs, ys)
        lo = (ys[1] - ys[0]) / (xs[1] - xs[0])
        hi = (ys[-1] - ys[-2]) / (xs[-1] - xs[-2])
        out = np.where(lv < xs[0], ys[0] + lo * (lv - xs[0]), out)
        out = np.where(lv > xs[-1], ys[-1] + hi * (lv - xs[-1]), out)
        return np.where(v > 0, 2.0 ** out, 0.0)

    def __call__(self, v):
        return self._interp(v, self.x, self.y)

    def inverse(self, v):
        return self._interp(v, self.y, self.x)


def rgbtone(c, f):
    """The DNG SDK's RefBaselineRGBTone with curve f: the largest and smallest channel through f, the middle one put
    back at its old share of the way between them, so HSV hue holds."""
    c = np.asarray(c, np.float64)
    order = np.argsort(c, axis=-1)
    s = np.take_along_axis(c, order, -1)
    lo, mid, hi = s[..., 0], s[..., 1], s[..., 2]
    flo, fhi = f(lo), f(hi)
    span = hi - lo
    share = np.where(span > 0, (mid - lo) / np.where(span > 0, span, 1), 0)
    out = np.empty_like(s)
    np.put_along_axis(out, order, np.stack([flo, flo + (fhi - flo) * share, fhi], -1), -1)
    return out


# MARK: Saturation candidates
# Each acts on linear RGB whose white is (1, 1, 1) and returns linear RGB; slider s is in [-1, 1]; s = 0 returns its
# input unchanged (the same array).

# Lightroom's grey is ProPhoto's luminance (measured: fitted weights 0.2904, 0.7089, 0.0007). Written in linear Rec.
# 2020 coordinates (D65, Bradford) it is this row; a luma blend is linear, so the two give the same colours.
LR_LUMA = {"prophoto": PROPHOTO_Y / PROPHOTO_Y.sum(),
           "rec2020": (PROPHOTO_Y @ REC2020_TO_PROPHOTO) / (PROPHOTO_Y @ REC2020_TO_PROPHOTO).sum()}


def gain(s):
    """Lightroom's Saturation gain on the deviation from grey: 1 + s on both sides (measured 0.500, 0.750, 1.251,
    1.503, 2.006 at -50, -25, +25, +50, +100)."""
    return 1.0 + s


def luma_blend(c, k, weights):
    """c' = Y + k (c - Y): an additive mix with the grey of equal luminance, k per pixel or one number."""
    Y = c @ weights
    return Y[..., None] + np.asarray(k)[..., None] * (c - Y[..., None])


def cone_share(c, weights):
    """How far along the blend line from its grey a colour sits, as a share of the way to the first channel that
    reaches zero: (Y - min) / Y, 0 for a grey and 1 on the cone of non-negative channels."""
    Y = c @ weights
    return np.where(Y > 0, (Y - c.min(-1)) / np.where(Y > 0, Y, 1), 0.0)


def knee(x, k, t):
    """The literature note's roll-off (section 2.7): y = k x up to x0 = t / k, then a rational curve that reaches the
    boundary y = 1 at x = 1 with a positive slope. k <= 1 is linear. Works on arrays of x and k."""
    x, k = np.broadcast_arrays(np.asarray(x, np.float64), np.asarray(k, np.float64))
    x0 = np.where(k > 1, t / np.maximum(k, 1e-9), np.inf)
    u = np.clip((x - x0) / np.where(np.isfinite(x0), 1 - x0, 1), 0, None)
    a = k * (1 - x0) / (1 - t)
    rolled = t + (1 - t) * a * u / (1 + (a - 1) * u)
    return np.where(x <= x0, k * x, np.minimum(rolled, 1.0))


def sat_lightroom(c, s, weights):
    """Lightroom's law as measured: the luma blend with k = 1 + s, channels clipped at zero."""
    if s == 0:
        return c
    return np.maximum(luma_blend(c, gain(s), weights), 0.0)


def sat_luma_knee(c, s, weights, t=0.7):
    """The same blend, rolled off toward the cone of non-negative channels along the blend line instead of clipped."""
    if s == 0:
        return c
    k = gain(s)
    if k <= 1:
        return luma_blend(c, k, weights)
    x = cone_share(c, weights)
    y = knee(x, k, t)
    return luma_blend(c, np.where(x > 1e-9, y / np.maximum(x, 1e-9), k), weights)


_SIGMA = {}


def sigma_max(space):
    """Oklab's cone of non-negative channels in `space`: every tenth of a degree of Oklab hue, the C / L where a ray
    from grey first leaves it (the boundary is a ray, since scaling RGB scales L, a and b alike). Leaving is not
    monotone along a ray (far out, cubing negative LMS can make every channel positive again), so the first exit is
    found by stepping out, then refined by bisection. Cached."""
    if space not in _SIGMA:
        h = np.radians(SIGMA_HUES)
        steps = np.arange(1, 801) * 0.005
        first = np.full(h.size, steps[-1])
        for i in range(0, h.size, 400):
            hh = h[i:i + 400, None]
            lab = np.stack(np.broadcast_arrays(np.ones((1, steps.size)), steps[None] * np.cos(hh), steps[None] * np.sin(hh)), -1)
            outside = oklab_to_rgb(lab, space).min(-1) < 0
            first[i:i + 400] = np.where(outside.any(1), steps[np.argmax(outside, 1)], steps[-1])
        lo, hi = first - 0.005, first
        for _ in range(30):
            mid = (lo + hi) / 2
            rgb = oklab_to_rgb(np.stack([np.ones(h.size), mid * np.cos(h), mid * np.sin(h)], -1), space)
            inside = rgb.min(-1) >= 0
            lo, hi = np.where(inside, mid, lo), np.where(inside, hi, mid)
        _SIGMA[space] = lo
    return _SIGMA[space]


SIGMA_HUES = np.arange(3601) / 10


def sat_oklab_knee(c, s, space, t=0.7, k=None):
    """The literature note's recommendation: Oklab chroma times k at constant Oklab L and hue, rolled off toward the
    cone. `k` may be given per pixel (Vibrance) instead of from s."""
    if s == 0 and k is None:
        return c
    k = gain(s) if k is None else k
    lab = oklab(c, space)
    L, C = lab[..., 0], np.hypot(lab[..., 1], lab[..., 2])
    h = np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360
    edge = np.interp(h, SIGMA_HUES, sigma_max(space)) * np.maximum(L, 1e-9)
    x = np.where(edge > 0, C / edge, 0)
    # A colour the interpolated table puts on or past the boundary is left where it is.
    y = np.where(x < 1, knee(np.minimum(x, 1), k, t), x)
    scale = np.where((C > 1e-7) & (L > 0), y * edge / np.maximum(C, 1e-12), 1.0)
    out = oklab_to_rgb(np.stack([L, lab[..., 1] * scale, lab[..., 2] * scale], -1), space)
    return np.where(((C > 1e-7) & (L > 0))[..., None], out, c)


# MARK: Saturation measured on the grids

SAT_VALUES = [-100, -50, -25, 25, 50, 100]


def pre_curve(which, rgb, tone, meta=None):
    """Lightroom's values before its tone curve: for the DNG grid the chart's own values in ProPhoto when `meta` is
    given, otherwise the render's values through the inverse curve (hue-preserving, as the SDK applies it)."""
    if meta is not None and which == "dng":
        return meta["chart"] @ REC2020_TO_PROPHOTO.T
    return rgbtone(rgb, tone.inverse)


def fit_weights(c, g, curve=lambda v: v, inverse=lambda v: v):
    """Luma weights w >= 0 summing to 1 with g = inverse(w . curve(c)), least squares weighted by 1 / g (the
    literature note's test A)."""
    X, y = curve(c), curve(g)
    w = 1 / np.maximum(y, 1e-4)
    A = np.stack([X[:, 0] - X[:, 2], X[:, 1] - X[:, 2]], 1)
    sol, *_ = np.linalg.lstsq(A * w[:, None], (y - X[:, 2]) * w, rcond=None)
    weights = np.array([sol[0], sol[1], 1 - sol.sum()])
    return weights, inverse(np.maximum(X @ weights, 1e-12))


def rms(e):
    return float(np.sqrt(np.mean(np.square(e))))


def p95(e):
    return float(np.percentile(np.abs(e), 95))


def saturation_minus_100(tone):
    """Test A: where -100 puts each colour, by hypothesis and by fitted weights, in each space."""
    out = {}
    for which in GRIDS:
        meta, R = grid_table(which)
        b, g = R["base"]["patch"], R["saturation:-100"]["patch"]
        ok = usable(b) & (g.max(-1) < 0.99) & (meta["group"] != "neutral")
        grey = g.mean(-1)[ok]
        spread = (g.max(-1) - g.min(-1))[ok] / np.maximum(grey, 1e-9)
        L = probe.lstar(grey)
        rows = {"channelSpreadMax": float(spread.max()), "count": int(ok.sum())}
        spaces = {"after the curve": b[ok], "before the curve (inverse curve)": pre_curve(which, b, tone)[ok]}
        if which == "dng":
            spaces["before the curve (chart values)"] = pre_curve(which, b, tone, meta)[ok]
        for space, c in spaces.items():
            back = (lambda v: v) if space == "after the curve" else tone
            hyp = {"ProPhoto Y": c @ PROPHOTO_Y, "max (HSV)": c.max(-1), "(max+min)/2 (HSL)": (c.max(-1) + c.min(-1)) / 2,
                   "mean of channels": c.mean(-1), "Oklab L": oklab(c, "prophoto")[:, 0] ** 3,
                   "luma of sRGB-encoded (Melissa)": melissa_inv(melissa(c) @ PROPHOTO_Y)}
            res = {name: {"rmsL": rms(probe.lstar(back(v)) - L), "p95L": p95(probe.lstar(back(v)) - L),
                          "meanL": float(np.mean(probe.lstar(back(v)) - L))} for name, v in hyp.items()}
            g_pre = grey if space == "after the curve" else tone.inverse(grey)
            for label, enc, dec in [("fitted, linear", lambda v: v, lambda v: v), ("fitted, Melissa", melissa, melissa_inv)]:
                w, pred = fit_weights(c, g_pre, enc, dec)
                e = probe.lstar(back(pred)) - L
                res[label] = {"weights": [round(float(v), 4) for v in w], "rmsL": rms(e), "p95L": p95(e)}
            rows[space] = res
        out[which] = rows
    return out


def deviation_ratio(c0, cs, measure):
    """The ratio of a saturation measure between two renders of the same patches."""
    def m(c):
        if measure == "linear deviation |c - Y| / Y":
            Y = c @ PROPHOTO_Y
            return np.linalg.norm(c - Y[:, None], axis=1) / Y
        if measure == "Oklab C":
            o = oklab(c, "prophoto")
            return np.hypot(o[:, 1], o[:, 2])
        if measure == "CIELAB C*":
            return lch(lab_prophoto(c))[1]
        if measure == "HSV s (linear)":
            return (c.max(1) - c.min(1)) / c.max(1)
        if measure == "HSV s (Melissa)":
            e = melissa(c)
            return (e.max(1) - e.min(1)) / e.max(1)
        raise KeyError(measure)
    return m(cs) / m(c0)


MEASURES = ["linear deviation |c - Y| / Y", "Oklab C", "CIELAB C*", "HSV s (linear)", "HSV s (Melissa)"]


def saturation_gain(tone):
    """Test B: the ratio of each saturation measure between a value and the base, on grid patches at a third of the
    edge or less, before and after the curve. The flattest measure across patches is Lightroom's."""
    out = {}
    for which in GRIDS:
        meta, R = grid_table(which)
        b = R["base"]["patch"]
        sel = (meta["group"] == "grid") & (meta["frac"] <= 0.375) & usable(b)
        res = {}
        for space in ("before the curve", "after the curve"):
            f = (lambda c: c) if space == "after the curve" else (lambda c: rgbtone(c, tone.inverse))
            c0 = f(b[sel])
            res[space] = {}
            for v in SAT_VALUES[1:]:
                cs = f(R[f"saturation:{v:+d}"]["patch"][sel])
                res[space][v] = {m: {"median": float(np.median(r)), "cv": float(r.std() / r.mean())}
                                 for m in MEASURES for r in [deviation_ratio(c0, cs, m)]}
        out[which] = {"count": int(sel.sum()), **res}
    return out


def per_patch_gain(c0, cs):
    """k with cs - Ys = k (c0 - Y0) by least squares, both in linear ProPhoto, and the share of the deviation k does
    not explain (zero when the colour moved on its own line through grey)."""
    d0 = c0 - (c0 @ PROPHOTO_Y)[..., None]
    ds = cs - (cs @ PROPHOTO_Y)[..., None]
    k = (ds * d0).sum(-1) / np.maximum((d0 * d0).sum(-1), 1e-20)
    resid = np.linalg.norm(ds - k[..., None] * d0, axis=-1) / np.maximum(np.linalg.norm(d0, axis=-1), 1e-12)
    return k, resid


def uv_prime(c):
    X = c @ PROPHOTO_TO_XYZ.T
    d = X[..., 0] + 15 * X[..., 1] + 3 * X[..., 2]
    return np.stack([4 * X[..., 0] / d, 9 * X[..., 1] / d], -1)


def off_line(c0, cs):
    """Distance in u'v' of cs from the straight line through the white and c0: zero for an additive mix with grey."""
    w = uv_prime(np.ones(3))
    u0, us = uv_prime(c0) - w, uv_prime(cs) - w
    d = u0 / np.linalg.norm(u0, axis=-1, keepdims=True)
    return np.abs(us[..., 0] * d[..., 1] - us[..., 1] * d[..., 0])


def saturation_shape(tone):
    """By step of the gamut edge: Lightroom's k (before the curve), what k leaves unexplained, the distance from the
    line through white, the share of patches with a clipped channel, and the hue and lightness shifts in the output."""
    out = {}
    for which in GRIDS:
        meta, R = grid_table(which)
        b = R["base"]["patch"]
        pre0 = rgbtone(b, tone.inverse)
        lab0 = lab_prophoto(b)
        L0, C0, h0 = lch(lab0)
        ok0 = oklab(b, "prophoto")
        res = {}
        for v in SAT_VALUES:
            r = R[f"saturation:{v:+d}"]["patch"]
            k, resid = per_patch_gain(pre0, rgbtone(r, tone.inverse))
            Ls_, Cs, hs = lch(lab_prophoto(r))
            oks = oklab(r, "prophoto")
            dh_ok = hue_diff(np.degrees(np.arctan2(oks[:, 2], oks[:, 1])), np.degrees(np.arctan2(ok0[:, 2], ok0[:, 1])))
            rows = {}
            for frac in np.arange(1, 9) / 8:
                sel = (meta["group"] == "grid") & np.isclose(meta["frac"], frac) & usable(b)
                clipped = (r.min(-1) < 0.0005) | (r.max(-1) > 0.9995)
                inside = sel & ~clipped
                hue_sel = inside & (C0 > 10)
                rows[float(frac)] = {
                    "k": float(np.median(k[sel])), "k10": float(np.percentile(k[sel], 10)),
                    "k90": float(np.percentile(k[sel], 90)),
                    "unexplained": float(np.median(resid[sel])), "clipped": float(clipped[sel].mean()),
                    "offLineP95": float(np.percentile(off_line(b[inside], r[inside]), 95)) if inside.any() and v != -100 else 0.0,
                    "dhLabP95": p95(hue_diff(hs, h0)[hue_sel]) if hue_sel.any() and v != -100 else None,
                    "dhOklabP95": p95(dh_ok[hue_sel]) if hue_sel.any() and v != -100 else None,
                    "dLP95": p95((Ls_ - L0)[inside]) if inside.any() else None,
                    "dLMedian": float(np.median((Ls_ - L0)[inside])) if inside.any() else None,
                    "count": int(sel.sum())}
            res[v] = rows
        out[which] = res
    return out


def saturation_ramps(tone):
    """Test C on the chroma ramps at L* 55: k against the colour's linear deviation, and where the smallest output
    channel reaches zero."""
    meta, R = grid_table("tif")
    out = {}
    for i, ramp in enumerate(meta["ramps"]):
        if ramp["kind"] != "chroma ramp":
            continue
        b, r = R["base"]["ramp"][i], R["saturation:+100"]["ramp"][i]
        pre0, pres = rgbtone(b, tone.inverse), rgbtone(r, tone.inverse)
        Y0, Ys = pre0 @ PROPHOTO_Y, pres @ PROPHOTO_Y
        dev = np.linalg.norm(pre0 - Y0[:, None], axis=1) / Y0
        k = np.linalg.norm(pres - Ys[:, None], axis=1) / np.maximum(np.linalg.norm(pre0 - Y0[:, None], axis=1), 1e-12)
        zero = np.nonzero(r.min(1) < 1e-4)[0]
        first = int(zero[0]) if len(zero) else None
        full = (dev > 0.05) & (r.min(1) > 0.01) & (r.max(1) < 0.99)
        out[ramp["h"]] = {
            "kBeforeClip": float(np.median(k[full])) if full.any() else None,
            "kBeforeClipSpread": float(np.percentile(k[full], 90) - np.percentile(k[full], 10)) if full.any() else None,
            "firstZeroAt": None if first is None else round(first / len(r), 3),
            "shareOfBaseLeftAtZero": None if first is None else float(cone_share(pre0[first:first + 1], PROPHOTO_Y)[0]),
            "kAtEnd": float(k[-1]), "lumaRiseAtEnd": float(Ys[-1] / Y0[-1]),
            "zeroChannelShare": float((r.min(1) < 1e-4).mean())}
    return out


def saturation_locality(tone):
    """Test G: k on the hue ramps (smooth, every hue) against k on the patches (uniform squares), at +50 and +100,
    unclipped only. A gap above the patches' own spread would say the slider looks at its surroundings."""
    meta, R = grid_table("tif")
    out = {}
    for v in (50, 100):
        b, r = R["base"]["patch"], R[f"saturation:+{v}"]["patch"]
        sel = usable(b) & usable(r) & (meta["group"] == "grid")
        kp, _ = per_patch_gain(rgbtone(b[sel], tone.inverse), rgbtone(r[sel], tone.inverse))
        kr = []
        for i, ramp in enumerate(meta["ramps"]):
            rb, rr = R["base"]["ramp"][i], R[f"saturation:+{v}"]["ramp"][i]
            m = usable(rb) & usable(rr)
            k, _ = per_patch_gain(rgbtone(rb[m], tone.inverse), rgbtone(rr[m], tone.inverse))
            dev = np.linalg.norm(rgbtone(rb[m], tone.inverse) - (rgbtone(rb[m], tone.inverse) @ PROPHOTO_Y)[:, None], axis=1)
            kr.append(k[dev > 0.01])
        kr = np.concatenate(kr)
        out[v] = {"patchMedian": float(np.median(kp)), "patchIQR": float(np.subtract(*np.percentile(kp, [75, 25]))),
                  "rampMedian": float(np.median(kr)), "rampIQR": float(np.subtract(*np.percentile(kr, [75, 25])))}
    return out


def saturation_extremes(tone):
    """Near black and white (Q3): the gamut-edge patches at L* 3, 6, 92 and 96 and the primaries at +100 and -100."""
    out = {}
    for which in GRIDS:
        meta, R = grid_table(which)
        b = R["base"]["patch"]
        rows = {}
        for L in (3.0, 6.0, 92.0, 96.0):
            sel = (meta["group"] == "extreme") & (meta["L"] == L)
            row = {}
            for v in (-100, 100):
                r = R[f"saturation:{v:+d}"]["patch"][sel]
                k, _ = per_patch_gain(rgbtone(b[sel], tone.inverse), rgbtone(r, tone.inverse))
                L0, C0, _ = lch(lab_prophoto(b[sel]))
                L1, C1, _ = lch(lab_prophoto(r))
                row[v] = {"kMedian": float(np.median(k)), "C0": float(np.median(C0)), "C": float(np.median(C1)),
                          "dLMedian": float(np.median(L1 - L0)), "dLMax": float(np.max(np.abs(L1 - L0))),
                          "anyChannelAtZero": float((r.min(1) < 1e-4).mean()), "anyChannelAtWhite": float((r.max(1) > 0.9995).mean())}
            rows[L] = row
        out[which] = rows
    return out


# MARK: Scores in Lightroom's terms

def lr_terms(candidate, which, value, place, tone, slider="saturation"):
    """A candidate against Lightroom on the colour grid. "before the curve": Lightroom's base taken back through its
    curve, the candidate applied, and the curve put back; "after the curve": the candidate on the base render itself.
    Compared with Lightroom's render at the same value, in CIELAB (D50), on patches no render clipped.
    Returns dE76 (mean, p95), the chroma-ratio error (median |log2|, as percent), the hue error (p95 degrees, C* > 10)
    and the lightness error (p95 L*), with the same numbers for leaving the base unchanged."""
    meta, R = grid_table(which)
    b, r = R["base"]["patch"], R[f"{slider}:{value:+d}"]["patch"]
    s = value / 100
    if place == "before the curve":
        pred = rgbtone(np.maximum(candidate(rgbtone(b, tone.inverse), s), 0), tone)
    else:
        pred = candidate(b, s)
    pred = np.clip(pred, 0, 1)
    sel = usable(b) & (meta["group"] != "neutral")
    lb, lr_, lp = lab_prophoto(b[sel]), lab_prophoto(r[sel]), lab_prophoto(pred[sel])
    return {**change_errors(lb, lr_, lb, lp), "null": change_errors(lb, lr_, lb, lb)["dE"]}


def change_errors(lab0_ref, lab_ref, lab0, lab, chroma_floor=5.0, hue_floor=10.0, keep=None):
    """How far one change (lab0 -> lab) is from a reference change (lab0_ref -> lab_ref), each from its own base:
    dE76 of the two change vectors, chroma ratio error (percent, median and p90 of |log2| ratio), hue change error
    (degrees, p95, where both bases have C* above hue_floor) and lightness change error (L*, p95). `keep`, when given,
    limits the chroma and hue measures to those entries (the clip rule); dE and lightness use every entry."""
    L0r, C0r, h0r = lch(lab0_ref)
    L1r, C1r, h1r = lch(lab_ref)
    L0, C0, h0 = lch(lab0)
    L1, C1, h1 = lch(lab)
    dvec = (lab - lab0) - (lab_ref - lab0_ref)
    dE = np.linalg.norm(dvec, axis=-1)
    both = (C0r > chroma_floor) & (C0 > chroma_floor)
    left_out, sel = 0, slice(None)
    if keep is not None:
        left_out = int(np.count_nonzero(both & ~keep))
        both, sel = both & keep, keep
    with np.errstate(divide="ignore", invalid="ignore"):
        lr = np.abs(np.log2(np.maximum(C1, 1e-6) / C0) - np.log2(np.maximum(C1r, 1e-6) / C0r))[both]
    hb = (C0r > hue_floor) & (C0 > hue_floor) & (True if keep is None else keep)
    dh = hue_diff(hue_diff(h1, h0), hue_diff(h1r, h0r))[hb]
    dL = ((L1 - L0) - (L1r - L0r))
    with np.errstate(divide="ignore", invalid="ignore"):
        signed = (np.log2(np.maximum(C1, 1e-6) / C0) - np.log2(np.maximum(C1r, 1e-6) / C0r))[both]
        ref_ratio = np.log2(np.maximum(C1r, 1e-6) / C0r)[both]
    pct = lambda v: float(100 * (2 ** v - 1))
    own = lambda a, b: float(np.percentile(np.abs(hue_diff(a, b)[hb]), 95)) if hb.any() else None
    return {"hueShiftP95": {"argent": own(h1, h0), "lightroom": own(h1r, h0r)},
            "dE": {"mean": float(dE.mean()), "p95": float(np.percentile(dE, 95))},
            "chromaRatio%": {"median": pct(np.median(lr)) if lr.size else None,
                             "p90": pct(np.percentile(lr, 90)) if lr.size else None,
                             "bias": pct(np.median(signed)) if signed.size else None,
                             "reference": float(2 ** np.median(ref_ratio)) if ref_ratio.size else None},
            "hueP95": float(np.percentile(np.abs(dh), 95)) if dh.size else None,
            "lightnessP95": float(np.percentile(np.abs(dL), 95)),
            "dC": {"argent": float(np.mean((C1 - C0)[sel])), "lightroom": float(np.mean((C1r - C0r)[sel]))},
            "count": int(dE.size), "chromaCount": int(lr.size), "clippedLeftOut": left_out}


SAT_CANDIDATES = {
    "luma blend, clip (Lightroom's law)": lambda c, s: sat_lightroom(c, s, LR_LUMA["prophoto"]),
    "luma blend, knee t=0.7": lambda c, s: sat_luma_knee(c, s, LR_LUMA["prophoto"], 0.7),
    "Oklab chroma, knee t=0.7": lambda c, s: sat_oklab_knee(c, s, "prophoto", 0.7),
}


def saturation_lr_scores(tone):
    out = {}
    for name, cand in SAT_CANDIDATES.items():
        for place in ("before the curve", "after the curve"):
            for which in GRIDS:
                for v in SAT_VALUES:
                    out.setdefault(name, {}).setdefault(place, {}).setdefault(which, {})[v] = lr_terms(cand, which, v, place, tone)
    return out


# MARK: Vibrance candidates
# Every Vibrance candidate reads the pixel's saturation x, its Oklab hue h and its lightness l = log2(Y / 0.18) in linear
# ProPhoto (Lightroom's working space; a scene in Rec. 2020 goes there by one 3 x 3 matrix and back), and turns them
# into a gain with `vib_gain`. They differ in what the gain multiplies.

def bump(h, centre, width):
    """A raised cosine in hue: 1 at `centre`, 0 from `width` degrees away, smooth in between."""
    d = np.abs(hue_diff(h, centre))
    return np.where(d < width, 0.5 * (1 + np.cos(np.pi * d / np.maximum(width, 1e-9))), 0.0)


def ok_hue(c, space="prophoto"):
    o = oklab(c, space)
    return np.degrees(np.arctan2(o[..., 2], o[..., 1])) % 360


def lightness_stops(c):
    return np.log2(np.maximum(c @ PROPHOTO_Y, 1e-9) / 0.18)


def vib_gain(x, h, l, s, P):
    """The gain on saturation x for slider s in (-1, 1]. Positive: 1 + (a1 s + a2 s^2) exp(-x / (x0 + x0v (1 - s)))
    (1 - d B(h; hc, hw)) exp(-((l - l0) / sigma)^2 / 2): a fall-off with saturation that is steeper at larger values, a
    dip over skin hues and a weight on lightness.
    Negative: 1 - t (1 + kappa (1 - t)) (1 - c x^q), t = -s, with no hue or lightness weight (measured), so -100
    leaves c x^q of each colour's saturation."""
    x = np.clip(x, 0, 1)
    if s > 0:
        q = P["pos"]
        amp = q["a1"] * s + q["a2"] * s * s
        fall = np.exp(-x / max(q["x0"] + q["x0v"] * (1 - s), 0.02))
        return 1 + amp * fall * (1 - q["d"] * bump(h, q["hc"], q["hw"])) * np.exp(-0.5 * ((l - q["l0"]) / q["sigma"]) ** 2)
    q = P["neg"]
    t = -s
    return 1 - t * (1 + q["kappa"] * (1 - t)) * (1 - q["c"] * x ** q["q"])


def vib_value(x, l, s, P):
    """log2 of HSV value's scale: sign(s) (b1 |s| + b2 s^2) x^alpha (1 - x)^beta exp(-((l - lv) / sv)^2 / 2)."""
    q = P["pos" if s > 0 else "neg"]
    t = abs(s)
    return np.sign(s) * (q["b1"] * t + q["b2"] * t * t) * np.clip(x, 0, 1) ** q["alpha"] * np.clip(1 - x, 0, 1) ** q["beta"] \
        * np.exp(-0.5 * ((l - q["lv"]) / q["sv"]) ** 2)


def to_prophoto(c, space):
    return c if space == "prophoto" else c @ REC2020_TO_PROPHOTO.T


def from_prophoto(c, space):
    return c if space == "prophoto" else c @ PROPHOTO_TO_REC2020.T


def hsv_split(c):
    hi, lo = c.max(-1), c.min(-1)
    S = np.where(hi > 0, (hi - lo) / np.where(hi > 0, hi, 1), 0)
    share = np.where((hi > lo)[..., None], (c - lo[..., None]) / np.where(hi > lo, hi - lo, 1)[..., None], 0)
    return hi, S, share


def vib_hsv(c, s, P, space="prophoto", m=1.0):
    """V-A, Lightroom's structure: HSV saturation times the gain and HSV value times its own scale, in linear ProPhoto,
    each channel kept at its share of the way from the smallest to the largest (HSV hue held). m is the strength
    (`strengthen`)."""
    if s == 0:
        return c
    return next(vib_hsv_strengths(c, s, P, (m,), space))


def strengthen(g, s, P, m):
    """The gain at strength m from the gain at strength 1, as F3's mapping defines m: the positive side's amplitude
    (a1, a2) times m, the negative side's c (what -100 leaves) over m."""
    if m == 1:
        return g
    if s > 0:
        return 1 + m * (g - 1)
    t = -s
    T = t * (1 + P["neg"]["kappa"] * (1 - t))
    return 1 - T + (g - 1 + T) / m


def vib_hsv_strengths(c, s, P, ms, space="prophoto"):
    """V-A at each strength in `ms`, one at a time, from one pass over the parts that do not depend on the strength."""
    p = to_prophoto(c, space)
    V, S, share = hsv_split(np.maximum(p, 0))
    h, l = ok_hue(p), lightness_stops(p)
    g = vib_gain(S, h, l, s, P)
    V1 = V * 2.0 ** vib_value(S, l, s, P)
    for m in ms:
        S1 = np.clip(knee(S, strengthen(g, s, P, m), P["sknee"]), 0, 1)
        lo = V1 * (1 - S1)
        out = lo[..., None] + (V1 - lo)[..., None] * share
        yield from_prophoto(np.where((V > 0)[..., None], out, p), space)


def vib_luma(c, s, P, space="prophoto"):
    """V-B: the same gain as a luma blend about Lightroom's grey (luminance held), clipped at zero like Saturation."""
    if s == 0:
        return c
    p = to_prophoto(c, space)
    V, S, _ = hsv_split(np.maximum(p, 0))
    k = vib_gain(S, ok_hue(p), lightness_stops(p), s, P)
    return from_prophoto(np.maximum(luma_blend(p, k, LR_LUMA["prophoto"]), 0), space)


def vib_oklab(c, s, P, space="prophoto"):
    """V-C, the literature note's method: Oklab chroma times the gain at constant Oklab L and hue, with x = (C / L) /
    S_ref, rolled off toward the cone of non-negative channels by the knee (t = 0.7)."""
    if s == 0:
        return c
    p = to_prophoto(c, space)
    lab = oklab(p, "prophoto")
    C = np.hypot(lab[..., 1], lab[..., 2])
    x = np.clip(C / np.maximum(lab[..., 0], 1e-9) / P["sref"], 0, 1)
    k = vib_gain(x, ok_hue(p), lightness_stops(p), s, P)
    return from_prophoto(sat_oklab_knee(p, 0, "prophoto", 0.7, k=k), space)


VIB_MODELS = {"hsv": vib_hsv, "luma": vib_luma, "oklab": vib_oklab}
VIB_START = {
    "pos": {"a1": 1.0, "a2": 1.5, "x0": 0.3, "x0v": 0.3, "d": 0.5, "hc": 35.0, "hw": 50.0, "l0": -1.0, "sigma": 2.5,
            "b1": 0.15, "b2": 0.0, "alpha": 0.5, "beta": 0.5, "lv": -1.5, "sv": 1.5},
    "neg": {"c": 0.6, "q": 1.2, "kappa": 0.3, "b1": 0.5, "b2": 0.2, "alpha": 0.5, "beta": 0.8, "lv": -1.5, "sv": 1.5},
    "sref": 0.6,
    "sknee": 0.8,
}
VIB_BOUNDS = {"a1": (-1, 6), "a2": (-3, 6), "x0": (0.03, 3), "x0v": (-1, 3), "d": (0, 1), "hc": (-30, 90), "hw": (10, 120), "l0": (-6, 4),
              "sigma": (0.5, 8), "b1": (-2, 3), "b2": (-2, 3), "alpha": (0.05, 4), "beta": (0, 6), "lv": (-6, 4),
              "sv": (0.5, 8), "c": (0.01, 3), "q": (0.2, 4), "kappa": (-1, 3), "sref": (0.1, 3), "sknee": (0.3, 0.99)}
# Which constants each candidate fits on each side; the rest stay at their start (the value terms exist only in V-A).
VIB_FREE = {
    "hsv": {"pos": ["a1", "a2", "x0", "x0v", "d", "hc", "hw", "l0", "sigma", "b1", "b2", "alpha", "beta", "lv", "sv"],
            "neg": ["c", "q", "kappa", "b1", "b2", "alpha", "beta", "lv", "sv"]},
    "luma": {"pos": ["a1", "a2", "x0", "x0v", "d", "hc", "hw", "l0", "sigma"], "neg": ["c", "q", "kappa"]},
    "oklab": {"pos": ["a1", "a2", "x0", "x0v", "d", "hc", "hw", "l0", "sigma", "sref"], "neg": ["c", "q", "kappa"]},
}


def vib_fit_data(which, tone, values, ramp_step=4):
    """Lightroom's Vibrance on one grid, before the curve: the base colours and the colours at each value, for usable
    patches and every `ramp_step`-th ramp sample."""
    meta, R = grid_table(which)
    rows = {}
    for v in values:
        b, r = R["base"]["patch"], R[f"vibrance:{v:+d}"]["patch"]
        ok = usable(b) & usable(r) & (meta["group"] != "neutral")
        c0, c1 = [rgbtone(b[ok], tone.inverse)], [rgbtone(r[ok], tone.inverse)]
        for i in range(len(meta["ramps"])):
            rb, rr = R["base"]["ramp"][i][::ramp_step], R[f"vibrance:{v:+d}"]["ramp"][i][::ramp_step]
            m = usable(rb) & usable(rr)
            c0.append(rgbtone(rb[m], tone.inverse))
            c1.append(rgbtone(rr[m], tone.inverse))
        rows[v] = (np.concatenate(c0), np.concatenate(c1))
    return rows


TOP = ("sref", "sknee")


def _assign(P, keys, x, side):
    Q = {"pos": dict(P["pos"]), "neg": dict(P["neg"]), **{k: P[k] for k in TOP}}
    for k, v in zip(keys, x):
        lo, hi = VIB_BOUNDS[k]
        v = float(np.clip(v, lo, hi))
        if k in TOP:
            Q[k] = v
        else:
            Q[side][k] = v
    return Q


def vib_residual(P, model, rows):
    fn = VIB_MODELS[model]
    res = []
    for v, (c0, c1) in rows.items():
        res.append((lab_prophoto(np.maximum(fn(c0, v / 100, P), 0)) - lab_prophoto(c1)).ravel())
    return np.concatenate(res)


def levenberg_marquardt(f, x0, lower, upper, iterations=80, step=1e-4):
    """Minimises |f(x)|^2 inside the box [lower, upper] with a numerical Jacobian; returns x and the rms residual."""
    x = np.clip(np.array(x0, float), lower, upper)
    r = f(x)
    lam = 1e-2
    for _ in range(iterations):
        J = np.empty((r.size, x.size))
        for j in range(x.size):
            dx = step * max(1.0, abs(x[j]))
            sign = 1.0 if x[j] + dx <= upper[j] else -1.0
            J[:, j] = (f(np.where(np.arange(x.size) == j, x + sign * dx, x)) - r) / (sign * dx)
        A, g = J.T @ J, J.T @ r
        improved = False
        for _ in range(16):
            trial = np.clip(x + np.linalg.solve(A + lam * np.diag(np.diag(A) + 1e-9), -g), lower, upper)
            r_new = f(trial)
            if r_new @ r_new < r @ r:
                moved = np.abs(trial - x).max()
                x, r, lam, improved = trial, r_new, max(lam / 3, 1e-9), True
                break
            lam *= 4
        if not improved or moved < 1e-8:
            break
    return x, float(np.sqrt(np.mean(r ** 2)))


GAIN_KEYS = {"pos": ["a1", "a2", "x0", "x0v", "d", "hc", "hw", "l0", "sigma", "sknee"], "neg": ["c", "q", "kappa"]}
VALUE_KEYS = ["b1", "b2", "alpha", "beta", "lv", "sv"]


def _hsv_residual(P, rows, part):
    """V-A's two observables, separately: HSV saturation after the gain (absolute), or log2 of the value's scale."""
    res = []
    for v, (c0, c1) in rows.items():
        V0, S0, _ = hsv_split(c0)
        V1, S1, _ = hsv_split(c1)
        h, l = ok_hue(c0), lightness_stops(c0)
        if part == "gain":
            res.append(np.clip(knee(S0, vib_gain(S0, h, l, v / 100, P), P["sknee"]), 0, 1) - S1)
        else:
            res.append(vib_value(S0, l, v / 100, P) - np.log2(np.maximum(V1, 1e-9) / np.maximum(V0, 1e-9)))
    return np.concatenate(res)


def fit_vibrance(model, rows_pos, rows_neg):
    """Each side's constants by least squares. V-A fits its gain on HSV saturation and its value term on log2 of HSV
    value, each alone (they act on separate coordinates); V-B and V-C fit on CIELAB of the colours before the curve.
    Returns the constants and the rms residual in CIELAB per component."""
    P = json.loads(json.dumps(VIB_START))
    report = {}
    for side, rows in (("pos", rows_pos), ("neg", rows_neg)):
        stages = [(GAIN_KEYS[side], "gain"), (VALUE_KEYS, "value")] if model == "hsv" else [(VIB_FREE[model][side], "lab")]
        for keys, part in stages:
            x0 = np.array([P[k] if k in TOP else P[side][k] for k in keys], float)
            lower, upper = (np.array([VIB_BOUNDS[k][i] for k in keys], float) for i in (0, 1))
            f = (lambda x: vib_residual(_assign(P, keys, x, side), model, rows)) if part == "lab" else \
                (lambda x, part=part: _hsv_residual(_assign(P, keys, x, side), rows, part))
            x, _ = levenberg_marquardt(f, x0, lower, upper)
            P = _assign(P, keys, x, side)
        report[side] = float(np.sqrt(np.mean(vib_residual(P, model, rows) ** 2)))
    return P, report


# MARK: Through Argent's film

FLAGS = ("--auto", "--tiff", "--no-lens", "--long-edge", 1752)
QUARTER = ("--auto", "--tiff", "--no-lens", "--scale", 0.25)
FILM_SOURCES = ["p-raw", "p-photo-saturated", "p-photo-sky", "p-photo-foliage", "p-photo-skin"]
SCORE_STOCKS = ["kodak-portra-400", "kodak-ektar-100"]
ALL_STOCKS = sorted(p.name for p in STOCKS.iterdir() if (p / "stock.json").exists())
RAW_VALUES = [-100, -75, -50, -25, -10, 10, 25, 50, 75, 100]
PHOTO_VALUES = [-100, -50, 50, 100]
SRGB_FROM_REC2020 = np.linalg.solve(np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]]),
                                    REC2020_TO_XYZ65)


MANIFESTS = [EVIDENCE / "probe" / "manifest.json", EVIDENCE / "probe" / "round2" / "manifest.json",
             EVIDENCE / "probe" / "round3" / "manifest.json"]
_SOURCES = {}


def source_raw(job):
    """The raw a job rendered, from whichever round's manifest holds the job."""
    if job == "p-raw":
        return PROBE_RAW
    if not _SOURCES:
        for path in MANIFESTS:
            _SOURCES.update({j["name"]: Path(j["source"]) for j in json.loads(path.read_text())["jobs"]})
    return _SOURCES[job]


def block4(a, k=4):
    h, w = a.shape[0] // k * k, a.shape[1] // k * k
    out = np.empty((h // k, w // k, 3), np.float32)
    for y in range(0, h, 512):
        band = np.asarray(a[y:min(y + 512, h), :w], np.float64)
        out[y // k:(y + band.shape[0]) // k] = band.reshape(band.shape[0] // k, k, w // k, k, 3).mean(axis=(1, 3))
    return out


def chunked(fn, a, rows=384):
    """fn applied to `a` a band of rows at a time, into a new float32 array (keeps float64 temporaries small)."""
    out = np.empty(a.shape, np.float32)
    for y in range(0, a.shape[0], rows):
        out[y:y + rows] = fn(np.asarray(a[y:y + rows], np.float64))
    return out


NO_AUTO = ("--tiff", "--no-lens", "--long-edge", 1752)


def flag_tag(flags):
    """A short name for a flag set, for the cache: f is the scorecard's, q the quarter-size decode."""
    flags = tuple(flags)
    if flags == FLAGS:
        return "f"
    if flags == QUARTER:
        return "q"
    rest = [str(f).lstrip("-").replace(".", "p") for f in flags if f not in ("--tiff", "--no-lens", "--long-edge", 1752)]
    return "x" + "_".join(rest)


def quarter(flags):
    return "--scale" in tuple(flags)


def scene(job, flags=FLAGS):
    """The scene argent-spike's film render receives for `job`'s raw: the same for every stock and every Light flag
    (it is the decode), so only its size matters. Cached in scratch and memory-mapped."""
    base = QUARTER if quarter(flags) else FLAGS
    path = SCRATCH / f"scene-{job}-{flag_tag(base)}.npy"
    if not path.exists():
        SCRATCH.mkdir(parents=True, exist_ok=True)
        np.save(path, scene_io.scene_of(source_raw(job), STOCKS / SCORE_STOCKS[0], *base, binary=SPIKE))
    return np.load(path, mmap_mode="r")


def base_print(job, stock, flags=FLAGS):
    """The print of the untouched scene with `flags`, cached in scratch and memory-mapped."""
    path = SCRATCH / f"print-{job}-{stock}-{flag_tag(flags)}.npy"
    if not path.exists():
        np.save(path, scene_io.print_of(source_raw(job), STOCKS / stock, np.asarray(scene(job, flags)), *flags, binary=SPIKE))
    return np.load(path, mmap_mode="r")


def print_stats(p, k=4):
    """Blocks of a print in XYZ (D50), and the share of its pixels outside the display's range."""
    out_rec, out_srgb = 0, 0
    for y in range(0, p.shape[0], 512):
        band = np.asarray(p[y:y + 512], np.float32)
        out_rec += int(np.count_nonzero((band.min(-1) < 0) | (band.max(-1) > 1)))
        srgb = band @ SRGB_FROM_REC2020.T.astype(np.float32)
        out_srgb += int(np.count_nonzero((srgb.min(-1) < -1e-4) | (srgb.max(-1) > 1 + 1e-4)))
    n = p.shape[0] * p.shape[1]
    blocks = block4(p, k) if k > 1 else np.asarray(p, np.float32)
    return {"xyz": scene_io.print_xyz(blocks), "outRec2020": out_rec / n, "outSRGB": out_srgb / n}


def base_field_shift(before, after, k=32):
    """How far a stage moves what the render's base fields read: log2 Rec. 2020 luminance averaged over k x k pixels
    (the tone base field is a guided filter about 100 pixels wide at full size), p50 and p99 of the absolute change
    in stops."""
    def field(a):
        y = np.empty((a.shape[0] // k, a.shape[1] // k), np.float64)
        for r in range(0, a.shape[0] // k * k, 512):
            band = np.asarray(a[r:r + 512], np.float32) @ REC2020_Y.astype(np.float32)
            band = np.log2(np.maximum(band[:band.shape[0] // k * k, :a.shape[1] // k * k], 1e-6))
            y[r // k:(r + band.shape[0]) // k] = band.reshape(band.shape[0] // k, k, -1, k).mean(axis=(1, 3))
        return y
    d = np.abs(field(after) - field(before))
    return {"lumaShiftP50": float(np.median(d)), "lumaShiftP99": float(np.percentile(d, 99))}


def argent(job, stock, key, stage=None, place="scene", flags=FLAGS):
    """Argent's print of `job` on `stock` with `stage` applied on the scene or on the print, as XYZ blocks (4 x 4, or
    the quarter decode's own pixels) and clipping shares, cached under `key`. With no stage, the base. For a scene
    stage, also how far it moves what the spike's base fields read (`base_field_shift`)."""
    path = SCRATCH / "prints" / f"{job}-{stock}-{flag_tag(flags)}-{key}.npz"
    if path.exists():
        z = np.load(path)
        return {k: (z[k] if z[k].ndim else float(z[k])) for k in z.files}
    path.parent.mkdir(parents=True, exist_ok=True)
    k = 1 if quarter(flags) else 4
    extra = {}
    if stage is None:
        res = print_stats(base_print(job, stock, flags), k)
    elif place == "scene":
        sc = scene(job, flags)
        staged = chunked(stage, sc)
        extra = base_field_shift(sc, staged)
        p = scene_io.print_of(source_raw(job), STOCKS / stock, staged, *flags, binary=SPIKE)
        del staged
        res = print_stats(p, k)
        del p
    else:
        res = print_stats(chunked(stage, base_print(job, stock, flags)), k)
    res.update(extra)
    np.savez(path, **res)
    return res


def lightroom(job, name):
    """A Lightroom export as XYZ (D50) blocks, cached in scratch."""
    return lightroom_blocks(job, name)["xyz"]


def _rgb_from(primaries, white_xyz):
    """XYZ to linear RGB with these xy primaries, scaled so that `white_xyz` maps to (1, 1, 1) exactly."""
    P = np.array([[x / y, 1, (1 - x - y) / y] for x, y in primaries]).T
    return np.linalg.inv(P * np.linalg.solve(P, white_xyz))


SRGB_XY = [(0.64, 0.33), (0.30, 0.60), (0.15, 0.06)]
P3_XY = [(0.680, 0.320), (0.265, 0.690), (0.150, 0.060)]
_LR_XYZ65 = D50_TO_D65 @ PROPHOTO_TO_XYZ
# Each source's own white goes to the display's white exactly, so a white pixel never reads as out of gamut.
GAMUTS = {"lightroom": {"sRGB": _rgb_from(SRGB_XY, _LR_XYZ65 @ np.ones(3)) @ _LR_XYZ65,
                        "P3": _rgb_from(P3_XY, _LR_XYZ65 @ np.ones(3)) @ _LR_XYZ65},
          "argent": {"sRGB": _rgb_from(SRGB_XY, REC2020_TO_XYZ65 @ np.ones(3)) @ REC2020_TO_XYZ65,
                     "P3": _rgb_from(P3_XY, REC2020_TO_XYZ65 @ np.ones(3)) @ REC2020_TO_XYZ65}}
GAMUT_TOLERANCE = 1e-4


def gamut_counts(band, source):
    """Pixels of a band (linear RGB, Lightroom's ProPhoto or Argent's Rec. 2020) with a channel below zero (a colour
    the display cannot show) or above one (brighter than its white), in sRGB and Display P3."""
    out = {}
    for name, M in GAMUTS[source].items():
        rgb = band @ M.T.astype(np.float32)
        neg, over = rgb.min(-1) < -GAMUT_TOLERANCE, rgb.max(-1) > 1 + GAMUT_TOLERANCE
        out[f"{name}Neg"], out[f"{name}Over"], out[f"{name}Out"] = (int(np.count_nonzero(x)) for x in (neg, over, neg | over))
    return out


def lightroom_blocks(job, name):
    """A Lightroom export as XYZ (D50) 4 x 4 blocks, how many of each block's 16 pixels have a channel at code 0 or
    65535 (a colour pushed past ProPhoto or a crushed black or white), and its pixel shares outside sRGB and Display
    P3. One read of the TIFF, cached in scratch."""
    path = SCRATCH / "lr" / f"{job}-{name}.npz"
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        img, icc = probe.read_tiff(REFS / f"exports-{job}" / f"{job}_{name}.tif")
        clipped = ((img == 0) | (img == 1)).any(-1)
        h, w = clipped.shape[0] // 4 * 4, clipped.shape[1] // 4 * 4
        clip = clipped[:h, :w].reshape(h // 4, 4, w // 4, 4).sum(axis=(1, 3)).astype(np.uint8)
        del clipped
        np.power(img, np.float32(probe.icc_gamma(icc)), out=img)
        counts = {}
        for y in range(0, img.shape[0], 512):
            for k, v in gamut_counts(img[y:y + 512], "lightroom").items():
                counts[k] = counts.get(k, 0) + v
        n = img.shape[0] * img.shape[1]
        np.savez(path, xyz=block4(img) @ PROPHOTO_TO_XYZ.T.astype(np.float32), clip=clip,
                 **{k: v / n for k, v in counts.items()})
        del img
    z = np.load(path)
    return {k: (z[k] if z[k].ndim else float(z[k])) for k in z.files}


def lr_name(slider, value):
    return f"{slider}_{value:+d}"


def oracle(lab_a0, lab_l0, lab_l1):
    """Lightroom's own change of each block (lightness added, chroma scaled, hue turned) put on Argent's base: what a
    perfect method would print, given that the two bases differ."""
    L0, C0, h0 = lch(lab_a0)
    Ll0, Cl0, hl0 = lch(lab_l0)
    Ll1, Cl1, hl1 = lch(lab_l1)
    C = np.where(Cl0 > 1, C0 * Cl1 / np.maximum(Cl0, 1e-9), np.maximum(C0 + Cl1 - Cl0, 0))
    h = np.radians(h0 + hue_diff(hl1, hl0))
    return np.stack([L0 + Ll1 - Ll0, C * np.cos(h), C * np.sin(h)], -1)


def film_score(job, stock, slider, value, res, base):
    """Argent's change (base -> res) against Lightroom's (its base -> its render at `value`), on blocks both bases
    hold between L* 3 and 97, with the floor from `oracle`."""
    l0, l1 = lab_of_xyz(lightroom(job, "00_base")), lab_of_xyz(lightroom(job, lr_name(slider, value)))
    a0, a1 = lab_of_xyz(base["xyz"]), lab_of_xyz(res["xyz"])
    m = (l0[..., 0] > 3) & (l0[..., 0] < 97) & (a0[..., 0] > 3) & (a0[..., 0] < 97)
    e = change_errors(l0[m], l1[m], a0[m], a1[m])
    floor = change_errors(l0[m], l1[m], a0[m], oracle(a0[m], l0[m], l1[m]))
    C1 = lch(a1[m])[1]
    out = {**e, "floorDE": floor["dE"], "outRec2020": res["outRec2020"], "outSRGB": res["outSRGB"],
           "baseOutSRGB": base["outSRGB"], "greyC": {"mean": float(C1.mean()), "p95": float(np.percentile(C1, 95))},
           "lrGreyC": float(lch(l1[m])[1].mean())}
    for k in ("lumaShiftP50", "lumaShiftP99"):
        if k in res:
            out[k] = res[k]
    return out


SAT_FILM = {
    "blend": ("luma blend, clip (Lightroom's law)", lambda c, s: sat_lightroom(c, s, LR_LUMA["rec2020"])),
    "blendknee": ("luma blend, knee t=0.7", lambda c, s: sat_luma_knee(c, s, LR_LUMA["rec2020"], 0.7)),
    "oklab": ("Oklab chroma, knee t=0.7", lambda c, s: sat_oklab_knee(c, s, "rec2020", 0.7)),
}


def film_runs(slider, candidates, places, sources, stocks, values):
    """Every candidate in every place on every source and stock at every value: {cand: {place: {source: {stock:
    {value: score}}}}}. `values(job)` gives the values Lightroom rendered for that source."""
    out = {}
    for key, (label, fn) in candidates.items():
        for place in places:
            for job in sources:
                for stock in stocks:
                    base = argent(job, stock, "base")
                    for v in values(job):
                        res = argent(job, stock, f"{slider}-{key}-{place}-{v:+d}", lambda c, s=v / 100: fn(c, s), place)
                        out.setdefault(key, {}).setdefault(place, {}).setdefault(job, {}).setdefault(stock, {})[v] = \
                            film_score(job, stock, slider, v, res, base)
                    print(f"  {slider} {key} {place} {job} {stock} done", flush=True)
    return out


def mixed(runs, key, positive="scene", negative="print"):
    """A design that puts the stage on the scene for positive values and on the print for negative ones, scored from
    the two places' runs."""
    out = {}
    for job, stocks in runs[key][positive].items():
        for stock, vals in stocks.items():
            for v in vals:
                out.setdefault(job, {}).setdefault(stock, {})[v] = runs[key][positive if v > 0 else negative][job][stock][v]
    return out


def summarise(runs_by_place, values):
    """Means over sources and stocks, per value: dE of the change (mean, p95 averaged), its floor, chroma ratio error,
    hue and lightness error, the strength (Argent's mean change of C* over Lightroom's), the grey left at -100, the
    print's share outside sRGB, and the scene's luminance shift."""
    rows = {}
    for v in values:
        cells = [vals[v] for stocks in runs_by_place.values() for vals in stocks.values() if v in vals]
        if not cells:
            continue
        mean = lambda f: float(np.mean([f(c) for c in cells if f(c) is not None]))
        rows[v] = {"runs": len(cells),
                   "dE": mean(lambda c: c["dE"]["mean"]), "dEp95": mean(lambda c: c["dE"]["p95"]),
                   "floor": mean(lambda c: c["floorDE"]["mean"]),
                   "ratio%": mean(lambda c: c["chromaRatio%"]["median"]) if v != -100 else None,
                   "ratioBias%": mean(lambda c: c["chromaRatio%"]["bias"]) if v != -100 else None,
                   "lrRatio": mean(lambda c: c["chromaRatio%"]["reference"]) if v != -100 else None,
                   "hueP95": mean(lambda c: c["hueP95"]) if v != -100 else None,
                   "LP95": mean(lambda c: c["lightnessP95"]),
                   "strength": mean(lambda c: c["dC"]["argent"] / c["dC"]["lightroom"] if abs(c["dC"]["lightroom"]) > 0.05 else None),
                   "greyC": mean(lambda c: c["greyC"]["mean"]), "greyCp95": mean(lambda c: c["greyC"]["p95"]),
                   "outSRGB": mean(lambda c: c["outSRGB"]), "baseOutSRGB": mean(lambda c: c["baseOutSRGB"]),
                   "lumaShiftP99": mean(lambda c: c.get("lumaShiftP99"))}
    return rows


def print_summary(title, rows):
    print(title)
    print("    value runs   dE  dEp95 floor ratio% bias% LRratio hueP95  LP95 strength greyC greyCp95 outSRGB(base) lumaP99")
    f = lambda x, w=6, d=2: f"{x:{w}.{d}f}" if x is not None and np.isfinite(x) else " " * (w - 1) + "-"
    for v, r in rows.items():
        print(f"    {v:+5d} {r['runs']:4d} {f(r['dE'])} {f(r['dEp95'])} {f(r['floor'])} {f(r['ratio%'])} {f(r['ratioBias%'])} {f(r['lrRatio'])} {f(r['hueP95'])} "
              f"{f(r['LP95'])} {f(r['strength'])} {f(r['greyC'])} {f(r['greyCp95'])} {f(r['outSRGB'], 7, 4)}({f(r['baseOutSRGB'], 6, 4)}) "
              f"{f(r['lumaShiftP99'], 7, 4)}")


def values_for(job):
    return RAW_VALUES if job == "p-raw" else PHOTO_VALUES


def saturation_film(quick=False):
    sources = FILM_SOURCES[:2] if quick else FILM_SOURCES
    runs = film_runs("saturation", SAT_FILM, ("scene", "print"), sources, SCORE_STOCKS, values_for)
    summary = {}
    for key, (label, _) in SAT_FILM.items():
        for place in ("scene", "print"):
            summary[f"{label} | {place}"] = summarise(runs[key][place], RAW_VALUES)
        summary[f"{label} | mixed (scene +, print -)"] = summarise(mixed(runs, key), RAW_VALUES)
    write_json("saturation-film.json", {"runs": runs, "summary": summary})
    for title, rows in summary.items():
        print_summary(title, rows)
    return runs, summary


# The pass bars proposed for the Swift build, fixed from the prototype's scores through the film (report.md, section 8):
# per value, the bar and, beside it, the prototype's own mean over 10 runs (5 frames x Portra 400 and Ektar 100).
PASS_BARS = {
    "both": {
        "identity": "slider 0 renders the same bytes as no stage (a literal bypass)",
        "reproduce": "the Swift build's print against this prototype's print of the same raw, stock, flags and value, "
                     "4 x 4 blocks in CIELAB D50, on p-raw and p-photo-saturated, Portra 400 and Ektar 100, at -100, "
                     "-50, +50 and +100",
        "fidelity": "fit_colour.film_score against Lightroom, mean over the 10 runs of section 3.3 / 5.3",
    },
    "saturation": {
        "stage": "S-A, luma blend with Lightroom's luminance, k = 1 + s, on the print",
        "reproduceDE": {"mean": 0.3, "p99": 1.0},
        "chromaRatioError%": {"-50": [9.0, 7.2], "+50": [11.0, 8.6], "+100": [25.0, 22.1]},
        "hueP95": {"-50": [7.0, 5.3], "+50": [8.5, 6.8], "+100": [13.0, 11.6]},
        "lightnessP95": {"-50": [0.6, 0.39], "+50": [0.7, 0.44], "+100": [1.5, 1.21]},
        "greyAtMinus100C": [0.1, 0.02],
    },
    "vibrance": {
        "stage": "V-A with the fitted constants (m = 1), on the print, after Saturation",
        "reproduceDE": {"mean": 0.5, "p99": 2.0},
        "chromaRatioError%": {"-50": [16.0, 13.4], "+50": [12.0, 9.4], "+100": [38.0, 35.2]},
        "hueP95": {"-50": [5.0, 3.2], "+50": [3.0, 1.3], "+100": [6.0, 4.2]},
        "lightnessP95": {"-100": [9.5, 8.5], "-50": [4.5, 3.98], "+50": [1.5, 1.10], "+100": [3.5, 3.07]},
    },
}

VIB_VALUES = [-100, -50, -25, 25, 50, 100]
VIB_LABELS = {"hsv": "V-A HSV saturation and value (Lightroom's structure)",
              "luma": "V-B luma blend with the fitted gain (lightness held)",
              "oklab": "V-C Oklab chroma, C/L fall-off, knee (literature)"}


def vibrance_constants(refresh=False):
    """Each candidate's constants, fitted on the TIFF grid before the curve (the DNG grid is held out), cached."""
    path = DATA / "vibrance-constants.json"
    if not refresh:
        for kept in (path, FIT / "data" / "vibrance-constants.json"):
            if kept.exists():
                return json.loads(kept.read_text())
    tone = Tone()
    pos, neg = vib_fit_data("tif", tone, [25, 50, 100]), vib_fit_data("tif", tone, [-25, -50, -100])
    out = {}
    for model in VIB_MODELS:
        P, rep = fit_vibrance(model, pos, neg)
        out[model] = {"constants": P, "fitRms": rep}
    path.write_text(json.dumps(out, indent=1))
    return out


def vibrance_describe(tone, P):
    """Test D and E in Lightroom's own numbers, from the chroma ramps and the patches: the gain on HSV saturation at
    each value, the hue profile of the +100 gain relative to the hues outside 0-100 (CIELAB), the lightness rows, and
    what -100 leaves."""
    meta, R = grid_table("tif")
    b = R["base"]["patch"]
    V0, S0, _ = hsv_split(rgbtone(b, tone.inverse))
    ramps = [i for i, r in enumerate(meta["ramps"]) if r["kind"] == "chroma ramp" and not 0 <= r["h"] <= 100]
    out = {"gainBySaturation": {}, "valueBySaturation": {}}
    bins = np.array([0.0, 0.05, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9])
    for v in VIB_VALUES:
        xs, gs, ls = [], [], []
        for i in ramps:
            rb, rr = R["base"]["ramp"][i], R[f"vibrance:{v:+d}"]["ramp"][i]
            m = usable(rb) & usable(rr)
            a0, s0, _ = hsv_split(rgbtone(rb[m], tone.inverse))
            a1, s1, _ = hsv_split(rgbtone(rr[m], tone.inverse))
            k = s0 > 0.005
            xs.append(s0[k]); gs.append(s1[k] / s0[k]); ls.append(np.log2(a1[k] / a0[k]))
        x, g, lv = (np.concatenate(a) for a in (xs, gs, ls))
        idx = np.digitize(x, bins) - 1
        out["gainBySaturation"][v] = {float(bins[j]): float(np.median(g[idx == j])) for j in range(len(bins)) if (idx == j).sum() > 3}
        out["valueBySaturation"][v] = {float(bins[j]): float(np.median(lv[idx == j])) for j in range(len(bins)) if (idx == j).sum() > 3}
    ref = out["gainBySaturation"]
    profile = {}
    for v in (100, 50):
        r = R[f"vibrance:+{v}"]["patch"]
        V1, S1, _ = hsv_split(rgbtone(r, tone.inverse))
        keys = np.array(sorted(ref[v]))
        expect = np.interp(S0, keys, [ref[v][k] for k in keys])
        rel = (S1 / np.maximum(S0, 1e-9) - 1) / (expect - 1)
        ok = usable(b) & usable(r) & np.isin(meta["group"], ["grid", "skin"]) & (S0 > 0.03) & np.isin(meta["L"], [35.0, 50.0, 65.0])
        hb = np.round(meta["h"] / 7.5) * 7.5 % 360
        profile[v] = {float(h): float(np.median(rel[ok & (hb == h)])) for h in np.unique(hb[ok])}
        rows = {}
        for L in (20.0, 35.0, 50.0, 65.0, 80.0):
            m = usable(b) & usable(r) & (meta["group"] == "grid") & (meta["L"] == L) & (S0 > 0.03) & ~((meta["h"] >= 0) & (meta["h"] <= 100))
            rows[L] = float(np.median(rel[m]))
        out[f"lightnessRows+{v}"] = rows
    out["hueProfile"] = profile
    r = R["vibrance:-100"]["patch"]
    _, S1, _ = hsv_split(rgbtone(r, tone.inverse))
    L0, C0, _ = lch(lab_prophoto(b))
    L1, C1, _ = lch(lab_prophoto(r))
    ok = usable(b) & usable(r) & np.isin(meta["group"], ["grid", "skin"])
    out["minus100"] = {"chromaKeptByStep": {float(f): float(np.median((C1 / C0)[ok & np.isclose(meta["frac"], f)])) for f in np.arange(1, 9) / 8},
                       "dLMean": float(np.mean((L1 - L0)[ok])), "dLp5": float(np.percentile((L1 - L0)[ok], 5)),
                       "dLp95": float(np.percentile((L1 - L0)[ok], 95))}
    return out


def vibrance_skin(tone, constants):
    """Q7 on the patches: each candidate's error against Lightroom on the skin grid (CIELAB hue 20-80, every 2.5
    degrees), before the curve, at each value."""
    out = {}
    for model, fn in VIB_MODELS.items():
        P = constants[model]["constants"]
        for which in GRIDS:
            meta, R = grid_table(which)
            for v in VIB_VALUES:
                b, r = R["base"]["patch"], R[f"vibrance:{v:+d}"]["patch"]
                ok = usable(b) & usable(r) & (meta["group"] == "skin")
                c0, c1 = rgbtone(b[ok], tone.inverse), rgbtone(r[ok], tone.inverse)
                pred = np.maximum(fn(c0, v / 100, P), 0)
                e = change_errors(lab_prophoto(c0), lab_prophoto(c1), lab_prophoto(c0), lab_prophoto(pred))
                out.setdefault(model, {}).setdefault(which, {})[v] = e
    return out


def vibrance_pre_scores(tone, constants):
    """Every candidate before the curve on both grids, every usable patch: the method's own error."""
    out = {}
    for model, fn in VIB_MODELS.items():
        P = constants[model]["constants"]
        for which in GRIDS:
            meta, R = grid_table(which)
            for v in VIB_VALUES:
                b, r = R["base"]["patch"], R[f"vibrance:{v:+d}"]["patch"]
                ok = usable(b) & usable(r) & (meta["group"] != "neutral")
                c0, c1 = rgbtone(b[ok], tone.inverse), rgbtone(r[ok], tone.inverse)
                pred = np.maximum(fn(c0, v / 100, P), 0)
                out.setdefault(model, {}).setdefault(which, {})[v] = {
                    **change_errors(lab_prophoto(c0), lab_prophoto(c1), lab_prophoto(c0), lab_prophoto(pred)),
                    "null": change_errors(lab_prophoto(c0), lab_prophoto(c1), lab_prophoto(c0), lab_prophoto(c0))["dE"]}
    return out


def saturation_pre_scores(tone):
    """Saturation's candidates scored the same way, before the curve."""
    out = {}
    for name, fn in SAT_CANDIDATES.items():
        for which in GRIDS:
            meta, R = grid_table(which)
            for v in SAT_VALUES:
                b, r = R["base"]["patch"], R[f"saturation:{v:+d}"]["patch"]
                # A channel the export clipped at zero is Lightroom's own clip, which the candidate models; one clipped
                # at white cannot be taken back through the curve.
                ok = usable(b) & (r.max(-1) < 0.99) & (meta["group"] != "neutral")
                c0, c1 = rgbtone(b[ok], tone.inverse), rgbtone(r[ok], tone.inverse)
                pred = np.maximum(fn(c0, v / 100), 0)
                e = change_errors(lab_prophoto(c0), lab_prophoto(c1), lab_prophoto(c0), lab_prophoto(pred))
                out.setdefault(name, {}).setdefault(which, {})[v] = e
    return out


def vibrance_step():
    tone = Tone()
    constants = vibrance_constants(refresh=True)
    result = {"constants": constants, "describe": vibrance_describe(tone, constants["hsv"]["constants"]),
              "pre": vibrance_pre_scores(tone, constants), "skin": vibrance_skin(tone, constants),
              "lrTerms": {model: {place: {which: {v: lr_terms(lambda c, s, fn=VIB_MODELS[model], P=constants[model]["constants"]: fn(c, s, P),
                                                              which, v, place, tone, "vibrance") for v in VIB_VALUES}
                                          for which in GRIDS} for place in ("before the curve", "after the curve")}
                          for model in VIB_MODELS}}
    write_json("vibrance-lightroom.json", result)
    print("Vibrance constants and fit rms (CIELAB per component, TIFF grid):")
    for model, d in constants.items():
        print(f"  {model}: {d['fitRms']}  {json.dumps(d['constants'])}")
    d = result["describe"]
    print("Gain on HSV saturation (ramps, hues outside 0-100):")
    for v, row in d["gainBySaturation"].items():
        print(f"  {v:+4d} " + " ".join(f"{k:.2f}:{x:.3f}" for k, x in row.items()))
    print("log2 value scale by saturation:")
    for v, row in d["valueBySaturation"].items():
        print(f"  {v:+4d} " + " ".join(f"{k:.2f}:{x:+.3f}" for k, x in row.items()))
    for v, row in d["hueProfile"].items():
        print(f"Hue profile +{v} (CIELAB h: relative gain): " + " ".join(f"{h:g}:{x:.2f}" for h, x in row.items()))
    print("Lightness rows +100:", d["lightnessRows+100"], " +50:", d["lightnessRows+50"])
    print("-100:", d["minus100"])
    for title, block in (("before the curve, all patches", result["pre"]), ("skin patches", result["skin"])):
        print(f"Vibrance candidates, {title}: dE mean/p95, ratio % median, hue p95, L p95")
        for model, grids in block.items():
            for which, vals in grids.items():
                print(f"  {model:5s} {which} " + " | ".join(
                    f"{v:+d}: {e['dE']['mean']:.2f}/{e['dE']['p95']:.2f} r{e['chromaRatio%']['median'] or 0:.1f} h{e['hueP95'] or 0:.1f} L{e['lightnessP95']:.2f}"
                    for v, e in vals.items()))
    return result


VIB_FILM_KEYS = ("hsv", "luma", "oklab")


def vibrance_film(quick=False):
    constants = vibrance_constants()
    cands = {k: (VIB_LABELS[k], lambda c, s, k=k: VIB_MODELS[k](c, s, constants[k]["constants"], "rec2020")) for k in VIB_FILM_KEYS}
    sources = FILM_SOURCES[:2] if quick else FILM_SOURCES
    runs = film_runs("vibrance", cands, ("scene", "print"), sources, SCORE_STOCKS, values_for)
    summary = {}
    for key, (label, _) in cands.items():
        for place in ("scene", "print"):
            summary[f"{label} | {place}"] = summarise(runs[key][place], RAW_VALUES)
        summary[f"{label} | mixed (scene +, print -)"] = summarise(mixed(runs, key), RAW_VALUES)
    write_json("vibrance-film.json", {"runs": runs, "summary": summary})
    for title, rows in summary.items():
        print_summary(title, rows)
    return runs, summary


# MARK: Composition

def combo_pre(R, meta, name):
    """p-combo's colour patches in render `name`, taken back through that render's own tone curve (read from its
    neutral ramp), and the curve."""
    tone = Tone(meta["rampChart"], R[name]["ramp"] @ PROPHOTO_Y)
    return rgbtone(R[name]["patch"], tone.inverse), tone


def compose_lightroom(constants):
    """Q4 in Lightroom's own terms, on p-combo's 48 colour patches (L* 50, half and 0.95 of the edge), each render
    read back through its own curve: Saturation's gain beside Exposure, Contrast and Dehaze (1.5 if it acts on
    linear values before the curve and after Dehaze), and Vibrance with Saturation in each order and as one gain."""
    meta, R = combo_table()
    P = constants["hsv"]["constants"]
    pre = {name: combo_pre(R, meta, name)[0] for name in R}

    def both(*names):
        m = np.ones(len(meta["h"]), bool)
        for n in names:
            m &= usable(R[n]["patch"])
        return m
    out = {}
    gains = {}
    for partner in ("base", "ex+1", "co+50", "deh+50"):
        combo = "sat+50" if partner == "base" else (f"{partner}_sat+50" if partner == "deh+50" else f"sat+50_{partner}")
        if combo not in pre:
            continue
        ok_all = both(partner, combo)
        k, unexplained = per_patch_gain(pre[partner][ok_all], pre[combo][ok_all])
        gains[partner] = {"patches": int(ok_all.sum()), "kMedian": float(np.median(k)), "kP10": float(np.percentile(k, 10)), "kP90": float(np.percentile(k, 90)),
                          "unexplainedP95": float(np.percentile(unexplained, 95))}
    out["saturationGainBeside"] = gains
    vib = {}
    for partner in ("base", "ex+1", "co+50"):
        combo = "vib+50" if partner == "base" else f"vib+50_{partner}"
        ok_all = both(partner, combo)
        pred = np.maximum(vib_hsv(pre[partner][ok_all], 0.5, P), 0)
        e = np.linalg.norm(lab_prophoto(pred) - lab_prophoto(pre[combo][ok_all]), axis=1)
        vib[partner] = {"patches": int(ok_all.sum()), "dEMean": float(e.mean()), "dEP95": float(np.percentile(e, 95))}
    out["vibranceModelBeside"] = vib
    pairs = {}
    for v, s in ((50, 50), (-50, -50), (50, -50), (-50, 50)):
        combo = f"vib{v:+d}_sat{s:+d}"
        ok_all = both("base", combo, f"sat{s:+d}", f"vib{v:+d}")
        c0, target = pre["base"][ok_all], lab_prophoto(pre[combo][ok_all])
        orders = {
            "Saturation, then Vibrance": vib_hsv(np.maximum(sat_lightroom(c0, s / 100, LR_LUMA["prophoto"]), 0), v / 100, P),
            "Vibrance, then Saturation": sat_lightroom(np.maximum(vib_hsv(c0, v / 100, P), 0), s / 100, LR_LUMA["prophoto"]),
        }
        # One gain: Vibrance's saturation scale and Saturation's k multiply on HSV saturation, Vibrance's value scale kept.
        V0, S0, share = hsv_split(c0)
        hsv1 = vib_hsv(c0, v / 100, P)
        V1, S1, _ = hsv_split(np.maximum(hsv1, 0))
        satk, _ = per_patch_gain(c0, np.maximum(sat_lightroom(c0, s / 100, LR_LUMA["prophoto"]), 0))
        res = {"patches": int(ok_all.sum())}
        for name, pred in orders.items():
            e = np.linalg.norm(lab_prophoto(np.maximum(pred, 0)) - target, axis=1)
            res[name] = {"dEMean": float(e.mean()), "dEP95": float(np.percentile(e, 95))}
        singles = {"Vibrance alone": vib_hsv(c0, v / 100, P), "Saturation alone": sat_lightroom(c0, s / 100, LR_LUMA["prophoto"])}
        for name, pred in singles.items():
            e = np.linalg.norm(lab_prophoto(np.maximum(pred, 0)) - target, axis=1)
            res[name] = {"dEMean": float(e.mean())}
        k_combo, _ = per_patch_gain(c0, pre[combo][ok_all])
        k_s, _ = per_patch_gain(c0, pre[f"sat{s:+d}"][ok_all])
        k_v, _ = per_patch_gain(c0, pre[f"vib{v:+d}"][ok_all])
        res["deviationGain"] = {"combo": float(np.median(k_combo)), "product": float(np.median(k_s * k_v)),
                                "sum": float(np.median(k_s + k_v - 1)),
                                "productError": float(np.median(np.abs(k_combo - k_s * k_v))),
                                "sumError": float(np.median(np.abs(k_combo - (k_s + k_v - 1))))}
        pairs[combo] = res
    out["vibranceWithSaturation"] = pairs
    return out


# MARK: Placement, composition, the base fields, scale and cost through the film

def recommended(constants=None):
    """The recommended stage per slider, in Rec. 2020 (the scene's and the print's primaries), with its cache key."""
    constants = constants or vibrance_constants()
    P = constants["hsv"]["constants"]
    return {"saturation": ("blend", lambda c, s: sat_lightroom(c, s, LR_LUMA["rec2020"])),
            "vibrance": ("hsv", lambda c, s: vib_hsv(c, s, P, "rec2020"))}


def placement_stocks(jobs=("p-raw", "p-photo-saturated")):
    """Q5 on all six stocks at -100 and +100, both places, for the recommended stages."""
    out = {}
    for slider, (key, fn) in recommended().items():
        for job in jobs:
            for stock in ALL_STOCKS:
                base = argent(job, stock, "base")
                for v in (-100, 100):
                    for place in ("scene", "print"):
                        res = argent(job, stock, f"{slider}-{key}-{place}-{v:+d}", lambda c, s=v / 100: fn(c, s), place)
                        out.setdefault(slider, {}).setdefault(stock, {}).setdefault(job, {}).setdefault(place, {})[v] = \
                            film_score(job, stock, slider, v, res, base)
                print(f"  placement {slider} {job} {stock} done", flush=True)
    return out


LIGHT = {"co+50": ("--contrast", 50), "ex+1": ("--exposure-ev", 1)}


def compose_film(stock="kodak-portra-400", job="p-raw-combos"):
    """Q4 through the film on the probe raw: each colour stage on top of Contrast +50 or Exposure +1 (change from the
    Light-only render, Lightroom's against Argent's), and Vibrance with Saturation in both orders (change from the
    base). The stage acts on the scene before the spike's Light tables, as --scene-in allows."""
    rec = recommended()
    sat, vib = rec["saturation"][1], rec["vibrance"][1]
    raw_job = "p-raw"
    out = {}
    for light, flag in LIGHT.items():
        flags = FLAGS + flag
        lbase = argent(raw_job, stock, "base", flags=flags)
        for slider, short in (("saturation", "sat"), ("vibrance", "vib")):
            key, fn = rec[slider]
            res = argent(raw_job, stock, f"{slider}-{key}-scene-+50", lambda c: fn(c, 0.5), "scene", flags)
            l0, l1 = lab_of_xyz(lightroom(job, light)), lab_of_xyz(lightroom(job, f"{short}+50_{light}"))
            a0, a1 = lab_of_xyz(lbase["xyz"]), lab_of_xyz(res["xyz"])
            m = (l0[..., 0] > 3) & (l0[..., 0] < 97) & (a0[..., 0] > 3) & (a0[..., 0] < 97)
            single = film_score(raw_job, stock, slider, 50, argent(raw_job, stock, f"{slider}-{key}-scene-+50", lambda c: fn(c, 0.5), "scene"),
                                argent(raw_job, stock, "base"))
            e = change_errors(l0[m], l1[m], a0[m], a1[m])
            out[f"{short}+50 on {light}"] = {"combo": e, "single": single}
    base = argent(raw_job, stock, "base")
    l0 = lab_of_xyz(lightroom(job, "00_base"))
    a0 = lab_of_xyz(base["xyz"])
    for v, s_ in ((50, 50), (-50, -50), (50, -50), (-50, 50)):
        l1 = lab_of_xyz(lightroom(job, f"vib{v:+d}_sat{s_:+d}"))
        m = (l0[..., 0] > 3) & (l0[..., 0] < 97) & (a0[..., 0] > 3) & (a0[..., 0] < 97)
        row = {}
        for order, fn in (("Saturation, then Vibrance", lambda c: vib(np.maximum(sat(c, s_ / 100), 0), v / 100)),
                          ("Vibrance, then Saturation", lambda c: sat(np.maximum(vib(c, v / 100), 0), s_ / 100))):
            tag = "sv" if order.startswith("Sat") else "vs"
            res = argent(raw_job, stock, f"pair-{tag}-{v:+d}-{s_:+d}", fn, "scene")
            row[order] = change_errors(l0[m], l1[m], a0[m], lab_of_xyz(res["xyz"])[m])
        out[f"vib{v:+d}_sat{s_:+d}"] = row
    return out


def auto_cost(stock="kodak-portra-400", jobs=("p-raw", "p-photo-skin")):
    """Fact 2: the spike makes every base field from the scene it is given, the real stage would not. The same stage
    scored with --auto (Auto's tone step reads the changed scene) and without it (no tone step), each against its own
    base: the difference is what the base fields' reading of the stage costs or adds."""
    out = {}
    for slider, (key, fn) in recommended().items():
        for job in jobs:
            for v in (-100, 100):
                row = {}
                for name, flags in (("auto", FLAGS), ("no auto", NO_AUTO)):
                    base = argent(job, stock, "base", flags=flags)
                    res = argent(job, stock, f"{slider}-{key}-scene-{v:+d}", lambda c, s=v / 100: fn(c, s), "scene", flags)
                    row[name] = film_score(job, stock, slider, v, res, base)
                    a0, a1 = lab_of_xyz(base["xyz"]), lab_of_xyz(res["xyz"])
                    row[name]["meanDL"] = float(np.mean(a1[..., 0] - a0[..., 0]))
                out.setdefault(slider, {}).setdefault(job, {})[v] = row
    return out


def scale_test(stock="kodak-portra-400", jobs=("p-raw", "p-photo-saturated")):
    """Item 5: the stage on the quarter-size decode (the preview's) against the full-size one, each against its own
    base. The change maps are compared block for block (the full print's 4 x 4 blocks, the quarter print's pixels)."""
    out = {}
    for slider, (key, fn) in recommended().items():
        for job in jobs:
            for v in (-100, -50, 50, 100):
                full0, quarter0 = argent(job, stock, "base"), argent(job, stock, "base", flags=QUARTER)
                full1 = argent(job, stock, f"{slider}-{key}-scene-{v:+d}", lambda c, s=v / 100: fn(c, s), "scene")
                quarter1 = argent(job, stock, f"{slider}-{key}-scene-{v:+d}", lambda c, s=v / 100: fn(c, s), "scene", QUARTER)
                f0, f1 = lab_of_xyz(full0["xyz"]), lab_of_xyz(full1["xyz"])
                q0, q1 = lab_of_xyz(quarter0["xyz"]), lab_of_xyz(quarter1["xyz"])
                h, w = min(f0.shape[0], q0.shape[0]), min(f0.shape[1], q0.shape[1])
                d = np.linalg.norm((f1 - f0)[:h, :w] - (q1 - q0)[:h, :w], axis=-1)
                out.setdefault(slider, {}).setdefault(job, {})[v] = {
                    "changeDE": {"mean": float(d.mean()), "p95": float(np.percentile(d, 95))},
                    "meanDC": {"full": float(np.mean(lch(f1)[1] - lch(f0)[1])), "quarter": float(np.mean(lch(q1)[1] - lch(q0)[1]))},
                    "basesDE": float(np.linalg.norm(f0[:h, :w] - q0[:h, :w], axis=-1).mean())}
    return out


def cost_timing():
    """Item 6: the stages' arithmetic timed in numpy on one million pixels (CPU, float64), as a ceiling, beside an
    operation count for the GPU estimate."""
    rng = np.random.default_rng(1)
    c = rng.uniform(0.001, 2.0, (1000, 1000, 3))
    out = {}
    for slider, (key, fn) in recommended().items():
        times = []
        for _ in range(3):
            t = time.perf_counter()
            fn(c, 0.5)
            times.append(time.perf_counter() - t)
        out[slider] = {"numpyMsPerMegapixel": 1000 * min(times), "numpyMsAt33MP": 33 * 1000 * min(times)}
    return out


def skin_film(job="p-photo-skin"):
    """Q7 through the film: each Vibrance candidate on the scene, scored only on blocks whose Lightroom base is in skin
    hues (CIELAB h 20 to 80, C* above 10: the squirrel's fur), against Lightroom's change there."""
    constants = vibrance_constants()
    out = {}
    l0 = lab_of_xyz(lightroom(job, "00_base"))
    L0, C0, h0 = lch(l0)
    for stock in SCORE_STOCKS:
        base = argent(job, stock, "base")
        a0 = lab_of_xyz(base["xyz"])
        m = (h0 >= 20) & (h0 <= 80) & (C0 > 10) & (L0 > 3) & (L0 < 97) & (a0[..., 0] > 3)
        for key in VIB_FILM_KEYS:
            for v in PHOTO_VALUES:
                res = argent(job, stock, f"vibrance-{key}-scene-{v:+d}",
                             lambda c, s=v / 100, k=key: VIB_MODELS[k](c, s, constants[k]["constants"], "rec2020"), "scene")
                l1, a1 = lab_of_xyz(lightroom(job, lr_name("vibrance", v))), lab_of_xyz(res["xyz"])
                e = change_errors(l0[m], l1[m], a0[m], a1[m])
                e["blocks"] = int(m.sum())
                out.setdefault(stock, {}).setdefault(key, {})[v] = e
    return out


GAMMAS = (1.0, 1.3, 1.6, 2.0)


def mapped_gain(jobs=("p-raw", "p-photo-saturated"), values=(-50, 50, 100)):
    """Q6: Saturation on the scene with its gain mapped, k' = (1 + s)^gamma, so the film's compression of a scene gain is
    made up: the median chroma-ratio bias against Lightroom for each gamma, stock and value. The gamma whose bias is
    nearest zero is that stock's mapping; one gamma for every stock means one set of constants serves."""
    out = {}
    for stock in SCORE_STOCKS:
        for job in jobs:
            base = argent(job, stock, "base")
            for g in GAMMAS:
                for v in values:
                    key = "saturation-blend-scene" if g == 1.0 else f"saturation-gamma{g:g}-scene"
                    res = argent(job, stock, f"{key}-{v:+d}", lambda c, s=v / 100, g=g: np.maximum(
                        luma_blend(c, (1 + s) ** g, LR_LUMA["rec2020"]), 0), "scene")
                    e = film_score(job, stock, "saturation", v, res, base)
                    out.setdefault(stock, {}).setdefault(g, {}).setdefault(v, []).append(e)
    summary = {stock: {g: {v: {"bias%": float(np.mean([e["chromaRatio%"]["bias"] for e in es])),
                               "ratio%": float(np.mean([e["chromaRatio%"]["median"] for e in es])),
                               "hueP95": float(np.mean([e["hueP95"] for e in es])),
                               "LP95": float(np.mean([e["lightnessP95"] for e in es]))}
                           for v, es in vals.items()} for g, vals in gs.items()} for stock, gs in out.items()}
    return summary


def print_neutral(job, stock, gains, tag):
    """The mid-tone cast of the print of a grey scene, grey = Lightroom's luminance times `gains`: each display-linear
    channel over the mean's luminance, on blocks between L* 30 and 70, and the print's mean C* there."""
    w = LR_LUMA["rec2020"]
    res = argent(job, stock, f"neutral-{tag}", lambda c: (c @ w)[..., None] * np.asarray(gains), "scene")
    rgb = res["xyz"] @ np.linalg.inv(REC2020_TO_XYZ50).T.astype(np.float32)
    lab = lab_of_xyz(res["xyz"])
    m = (lab[..., 0] > 30) & (lab[..., 0] < 70)
    mean = rgb[m].mean(0)
    return mean / (mean @ REC2020_Y), float(lch(lab[m])[1].mean())


def neutral_target(job, stock, iterations=3, gamma=1.5):
    """The scene colour this frame prints as neutral on `stock`, as gains on Lightroom's grey (luminance kept): found by
    printing a grey scene and moving its gains against the print's cast, damped by the film's contrast (gamma).
    The app would compute it once per frame from its own balance; here it costs `iterations` renders."""
    gains = np.ones(3)
    history = []
    for i in range(iterations):
        ratio, chroma = print_neutral(job, stock, gains, f"{i}")
        history.append(chroma)
        gains = gains * ratio ** (-1 / gamma)
        gains = gains / (gains @ LR_LUMA["rec2020"])
    ratio, chroma = print_neutral(job, stock, gains, f"{iterations}")
    history.append(chroma)
    return gains, history


def sat_neutral(c, s, gains):
    """Saturation's blend toward the colour that prints neutral: c' = Y g + (1 + s)(c - Y g), channels clipped at zero."""
    if s == 0:
        return c
    Y = (c @ LR_LUMA["rec2020"])[..., None] * gains
    return np.maximum(Y + (1 + s) * (c - Y), 0.0)


def neutral_design(values=(-100, -50, 50, 100)):
    """The scene design with the grey moved to the print's neutral, scored like the other Saturation runs."""
    out, targets = {}, {}
    for stock in SCORE_STOCKS:
        for job in FILM_SOURCES:
            gains, history = neutral_target(job, stock)
            targets.setdefault(stock, {})[job] = {"gains": gains.round(4).tolist(), "greyCByIteration": history}
            base = argent(job, stock, "base")
            for v in values:
                res = argent(job, stock, f"saturation-neutral-scene-{v:+d}", lambda c, s=v / 100, g=gains: sat_neutral(c, s, g), "scene")
                out.setdefault(job, {}).setdefault(stock, {})[v] = film_score(job, stock, "saturation", v, res, base)
            print(f"  neutral {job} {stock} gains {gains.round(3)} grey C* {[round(h, 2) for h in history]}", flush=True)
    return {"targets": targets, "summary": summarise(out, list(values)), "runs": out}


VIB_MULTS = (1.0, 1.4, 1.8)


def vibrance_print_mapping(jobs=("p-raw", "p-photo-saturated"), values=(-50, 50, 100)):
    """Q6 for Vibrance on the print: the print's colours are more saturated than Lightroom's before its curve, so the
    fitted gain under-delivers there. V-A with its positive amplitude (a1, a2) times m, or its -100 law's c over m:
    the chroma-ratio bias against Lightroom per stock. The m nearest zero bias is that stock's mapping."""
    P0 = vibrance_constants()["hsv"]["constants"]
    out = {}
    for stock in SCORE_STOCKS:
        for job in jobs:
            base = argent(job, stock, "base")
            for m in VIB_MULTS:
                P = json.loads(json.dumps(P0))
                P["pos"]["a1"] *= m
                P["pos"]["a2"] *= m
                P["neg"]["c"] /= m
                for v in values:
                    key = f"vibrance-hsv-print-{v:+d}" if m == 1.0 else f"vibrance-hsvx{m:g}-print-{v:+d}"
                    res = argent(job, stock, key, lambda c, s=v / 100, P=P: vib_hsv(c, s, P, "rec2020"), "print")
                    e = film_score(job, stock, "vibrance", v, res, base)
                    out.setdefault(stock, {}).setdefault(m, {}).setdefault(v, []).append(e)
    return {stock: {m: {v: {"bias%": float(np.mean([e["chromaRatio%"]["bias"] for e in es])),
                            "ratio%": float(np.mean([e["chromaRatio%"]["median"] for e in es])),
                            "hueP95": float(np.mean([e["hueP95"] for e in es])),
                            "LP95": float(np.mean([e["lightnessP95"] for e in es]))}
                        for v, es in vals.items()} for m, vals in ms.items()} for stock, ms in out.items()}


def mapping_step():
    result = {"vibrancePrint": vibrance_print_mapping()}
    write_json("vibrance-mapping.json", result)
    print("V-A on the print with amplitude times m (and -100's c over m): bias % / ratio % / hue p95 / L p95, mean of p-raw and p-photo-saturated")
    for stock, ms in result["vibrancePrint"].items():
        for m, vals in ms.items():
            print(f"  {stock:18s} m {float(m):.1f} " + " | ".join(f"{v:+d}: {d['bias%']:+.1f} / {d['ratio%']:.1f} / {d['hueP95']:.1f} / {d['LP95']:.2f}" for v, d in vals.items()))
    return result


def film_extras_step():
    result = {"placement": placement_stocks(), "compose": compose_film(), "autoCost": auto_cost(), "scale": scale_test(),
              "cost": cost_timing(), "composeLightroom": compose_lightroom(vibrance_constants()), "skin": skin_film(),
              "mappedGain": mapped_gain(), "neutral": neutral_design()}
    write_json("film-extras.json", result)
    print_extras(result)
    return result


def print_extras(r):
    print("Placement on six stocks (p-raw, p-photo-saturated): grey C* mean/p95 at -100; at +100 Argent hue shift p95 "
          "(Lightroom's), hue error p95, outside sRGB (base), strength, ratio error %")
    for slider, stocks in r["placement"].items():
        for stock, jobs in stocks.items():
            for job, places in jobs.items():
                for place, vals in places.items():
                    m, p_ = vals[-100], vals[100]
                    print(f"  {slider[:3]} {stock:18s} {job:18s} {place:6s} grey {m['greyC']['mean']:5.2f}/{m['greyC']['p95']:5.2f} | "
                          f"+100 dh {p_['hueShiftP95']['argent']:5.1f} ({p_['hueShiftP95']['lightroom']:5.1f}) err {p_['hueP95']:5.1f} "
                          f"out {p_['outSRGB']:.3f} ({p_['baseOutSRGB']:.3f}) strength {p_['dC']['argent'] / p_['dC']['lightroom']:.2f} "
                          f"ratio {p_['chromaRatio%']['median']:.1f} bias {p_['chromaRatio%']['bias']:+.1f}")
    print("Composition through the film (p-raw, Portra 400): dE mean, ratio %, hue p95, L p95; combo against single")
    for name, row in r["compose"].items():
        for k, e in row.items():
            print(f"  {name:22s} {k:28s} dE {e['dE']['mean']:5.2f}  ratio {e['chromaRatio%']['median']:5.1f}  hue {e['hueP95']:5.1f}  L {e['lightnessP95']:5.2f}")
    print("Base fields (auto against no auto): dE mean, L p95, ratio %, Argent mean dL, scene luminance shift p99 (32 px)")
    for slider, jobs in r["autoCost"].items():
        for job, vals in jobs.items():
            for v, row in vals.items():
                print(f"  {slider[:3]} {job:14s} {v:+4d} " + " | ".join(
                    f"{n}: dE {e['dE']['mean']:.2f} L {e['lightnessP95']:.2f} ratio {e['chromaRatio%']['median'] if e['chromaRatio%']['median'] is not None else float('nan'):.1f} "
                    f"dL {e['meanDL']:+.2f} shift {e.get('lumaShiftP99', float('nan')):.3f}" for n, e in row.items()))
    print("Scale (quarter against full): change dE mean/p95, mean dC* full/quarter, bases dE")
    for slider, jobs in r["scale"].items():
        for job, vals in jobs.items():
            for v, d in vals.items():
                print(f"  {slider[:3]} {job:18s} {v:+4d} change dE {d['changeDE']['mean']:.2f}/{d['changeDE']['p95']:.2f}  "
                      f"dC {d['meanDC']['full']:+.2f}/{d['meanDC']['quarter']:+.2f}  bases {d['basesDE']:.2f}")
    print("Cost:", r["cost"])
    print("Saturation on the scene with k' = (1 + s)^gamma: chroma-ratio bias % / ratio error % / hue p95 / L p95, mean of p-raw and p-photo-saturated")
    for stock, gs in r["mappedGain"].items():
        for g, vals in gs.items():
            print(f"  {stock:18s} gamma {float(g):.1f} " + " | ".join(f"{v:+d}: {d['bias%']:+.1f} / {d['ratio%']:.1f} / {d['hueP95']:.1f} / {d['LP95']:.2f}" for v, d in vals.items()))
    print_summary("Saturation on the scene, blended toward the print's neutral", r["neutral"]["summary"])
    print("Skin through the film (p-photo-skin fur): dE mean, ratio % median, bias %, hue p95, L p95, mean dC* Argent/Lightroom")
    for stock, keys in r["skin"].items():
        for key, vals in keys.items():
            print(f"  {stock:18s} {key:5s} " + " | ".join(
                f"{v:+d}: dE {e['dE']['mean']:.2f} r {e['chromaRatio%']['median']:.1f} b {e['chromaRatio%']['bias']:+.1f} h {e['hueP95']:.1f} "
                f"L {e['lightnessP95']:.2f} dC {e['dC']['argent']:+.2f}/{e['dC']['lightroom']:+.2f}" for v, e in vals.items()))
    print("Composition in Lightroom's terms:", json.dumps(r["composeLightroom"]))


def constants_step():
    """constants.json: every fitted constant, where it came from, and the pass bars, from the steps' saved results."""
    sat = json.loads(next(p for p in (OUT / "saturation-lightroom.json", FIT / "saturation-lightroom.json") if p.exists()).read_text())
    vib = vibrance_constants()
    tone = Tone()
    w = sat["minus100"]["dng"]["before the curve (chart values)"]["fitted, linear"]["weights"]
    gains = {v: d["linear deviation |c - Y| / Y"]["median"] for v, d in sat["gain"]["tif"]["before the curve"].items()}
    out = {
        "made": time.strftime("%Y-%m-%d %H:%M"),
        "script": "scripts/lightroom-probe/fit_colour.py (branch f3/colour-fit)",
        "rerun": ".venv/bin/python -I scripts/lightroom-probe/fit_colour.py all",
        "data": {"grids": ["exports-p-colour-grid (DNG)", "exports-p-colour-grid-tif"], "combos": "exports-p-combo, exports-p-raw-combos",
                 "film": FILM_SOURCES, "stocks": ALL_STOCKS, "spike": str(SPIKE)},
        "saturation": {
            "method": "luma blend c' = Y + k (c - Y) on linear light before the tone curve (Argent: on the scene, before "
                      "the Negative LUT); Y is Lightroom's grey, ProPhoto luminance; channels clipped at zero",
            "k": "1 + s, s = slider / 100, both signs",
            "lumaProPhoto": LR_LUMA["prophoto"].round(7).tolist(),
            "lumaRec2020": LR_LUMA["rec2020"].round(7).tolist(),
            "lumaFittedOnDngGreys": w,
            "kMeasuredByValue": gains,
            "fittedBy": "saturation_minus_100 and saturation_gain on the grids",
        },
        "vibrance": {
            "method": "V-A: in linear ProPhoto before the tone curve, HSV saturation S times vib_gain (knee toward S = 1 at "
                      "sknee) and HSV value times 2^vib_value, each channel kept at its share between the smallest and the "
                      "largest; x = S, h = Oklab hue, l = log2(Y / 0.18); applied after Saturation",
            "constants": {k: v["constants"] for k, v in vib.items()},
            "fitRmsLabPerComponent": {k: v["fitRms"] for k, v in vib.items()},
            "fittedBy": "fit_vibrance on the TIFF grid before the curve (patches and every 4th ramp sample), DNG held out",
        },
        "toneCurve": {"log2Chart": tone.x.round(5).tolist(), "log2Render": tone.y.round(5).tolist(),
                      "note": "Lightroom's raw tone curve for p-colour-grid (DNG), from its neutrals; used to take renders back "
                              "before the curve"},
        "composition": "Saturation first, then Vibrance on its result (p-combo, measured)",
        "passBars": PASS_BARS,
    }
    write_json("constants.json", out)
    return out


def write_json(name, obj):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / name).write_text(json.dumps(obj, indent=1, default=lambda o: o.tolist() if hasattr(o, "tolist") else str(o)))


def saturation_step():
    tone = Tone()
    result = {"minus100": saturation_minus_100(tone), "gain": saturation_gain(tone), "shape": saturation_shape(tone),
              "ramps": saturation_ramps(tone), "locality": saturation_locality(tone),
              "extremes": saturation_extremes(tone), "lrTerms": saturation_lr_scores(tone), "pre": saturation_pre_scores(tone)}
    write_json("saturation-lightroom.json", result)
    print_saturation(result)
    print("Saturation candidates before the curve (the method's own error): dE mean/p95, ratio % median, hue p95, L p95")
    for name, grids in result["pre"].items():
        for which, vals in grids.items():
            print(f"  {name[:28]:28s} {which} " + " | ".join(
                f"{v:+d}: {e['dE']['mean']:.2f}/{e['dE']['p95']:.2f}" + (f" r{e['chromaRatio%']['median']:.1f} h{e['hueP95']:.1f}" if v != -100 else "")
                + f" L{e['lightnessP95']:.2f}" for v, e in vals.items()))
    return result


def print_saturation(res):
    print("Test A, Saturation -100: rms / p95 L* of each hypothesis for the grey")
    for which, rows in res["minus100"].items():
        print(f"  {which}: {rows['count']} patches, largest channel spread of a grey {rows['channelSpreadMax']:.1e}")
        for space, hyps in rows.items():
            if not isinstance(hyps, dict):
                continue
            print(f"    {space}")
            for name, v in hyps.items():
                w = f" w={v['weights']}" if "weights" in v else ""
                print(f"      {name:34s} {v['rmsL']:6.3f} / {v['p95L']:6.3f}{w}")
    print("Test B, gain by measure (median, cv) on patches at <= 3/8 of the edge")
    for which, rows in res["gain"].items():
        for space in ("before the curve", "after the curve"):
            print(f"  {which} {space}")
            for v, ms in rows[space].items():
                print(f"    {v:+4d} " + "  ".join(f"{m[:14]:14s} {d['median']:.3f} ({d['cv']:.3f})" for m, d in ms.items()))
    print("Shape by step of the edge (TIF, then DNG): k median [p10, p90], unexplained, clipped share, off-line p95, dh CIELAB / Oklab p95, dL* median / p95")
    for which, rows in res["shape"].items():
        for v in (100, 50, -50, -100):
            for frac, d in rows[v].items():
                print(f"  {which} {v:+4d} {frac:.3f} k {d['k']:.3f} [{d['k10']:.3f}, {d['k90']:.3f}] unexpl {d['unexplained']:.3f} "
                      f"clip {d['clipped']:.2f} off {d['offLineP95']:.4f} dh {d['dhLabP95']} / {d['dhOklabP95']} dL {d['dLMedian']} / {d['dLP95']}")
    print("Test C, chroma ramps at +100 (TIF):")
    for h, d in res["ramps"].items():
        print(f"  h {h:5.1f} " + " ".join(f"{k}={v:.3f}" if isinstance(v, float) else f"{k}={v}" for k, v in d.items()))
    print("Test G, k on patches against ramps:", res["locality"])
    print("Extremes:")
    for which, rows in res["extremes"].items():
        for L, row in rows.items():
            print(f"  {which} L*{L:4.0f} " + " | ".join(f"{v:+d}: " + " ".join(f"{k}={x:.2f}" for k, x in d.items()) for v, d in row.items()))
    print("Lightroom terms: dE76 mean/p95, chroma ratio % median/p90, hue p95, L* p95  (null dE mean)")
    for name, places in res["lrTerms"].items():
        for place, grids in places.items():
            for which, vals in grids.items():
                for v, d in vals.items():
                    print(f"  {name[:28]:28s} {place[:10]:10s} {which} {v:+4d}  dE {d['dE']['mean']:5.2f}/{d['dE']['p95']:5.2f}  "
                          f"ratio {d['chromaRatio%']['median']}/{d['chromaRatio%']['p90']}  hue {d['hueP95']}  L {d['lightnessP95']:.2f}  (null {d['null']['mean']:.2f})")


# MARK: Validation (V3): F3's methods, constants unchanged, on new frames

REPRO_METRICS = {"ratio%": lambda e: e["chromaRatio%"]["median"], "bias%": lambda e: e["chromaRatio%"]["bias"],
                 "hueP95": lambda e: e["hueP95"], "LP95": lambda e: e["lightnessP95"], "dE": lambda e: e["dE"]["mean"],
                 "outSRGB": lambda e: e["outSRGB"]}


def reproduce_step():
    """F3's Vibrance film headline, V-A on the print on its five frames and two stocks, rerun with F3's own code path
    (scene out and back in, its cache keys) from an empty scratch, and compared run by run with F3's saved scores."""
    P = vibrance_constants()["hsv"]["constants"]
    cand = {"hsv": (VIB_LABELS["hsv"], lambda c, s: vib_hsv(c, s, P, "rec2020"))}
    runs = film_runs("vibrance", cand, ("print",), FILM_SOURCES, SCORE_STOCKS, lambda job: PHOTO_VALUES)["hsv"]["print"]
    f3 = json.loads((FIT / "vibrance-film.json").read_text())
    f3_runs = f3["runs"]["hsv"]["print"]
    diff = {name: 0.0 for name in REPRO_METRICS}
    for job, stocks in runs.items():
        for stock, vals in stocks.items():
            for v, e in vals.items():
                old = f3_runs[job][stock][str(v)]
                for name, get in REPRO_METRICS.items():
                    a, b = get(e), get(old)
                    if a is not None and b is not None:
                        diff[name] = max(diff[name], abs(a - b))
    ours = summarise(runs, PHOTO_VALUES)
    theirs = {int(k): v for k, v in f3["summary"][f"{VIB_LABELS['hsv']} | print"].items() if int(k) in PHOTO_VALUES}
    write_json("reproduce-vibrance.json", {"runs": runs, "summary": ours, "f3Summary": theirs, "largestRunDifference": diff})
    print_summary("V-A on the print, rerun from an empty scratch", ours)
    print_summary("V-A on the print, F3's saved scores", theirs)
    print("Largest difference of any run from F3's:", {k: f"{v:.2e}" for k, v in diff.items()})
    return diff


# The twenty photographs round 3 rendered for this test, in its manifest's order, fixed before any score was made:
# all of round 2's frames, which no Saturation or Vibrance fit has seen.
HELD_OUT = ["r-photo-horizon", "r-photo-mirror-lights", "r-photo-magenta-night", "r-photo-hall", "r-photo-fog-woods",
            "r-photo-dog-snow", "r-photo-gull-flight", "r-photo-disco", "r-photo-flower", "r-photo-birches",
            "r-photo-dog-woods", "r-photo-chickadee", "r-photo-tower", "r-photo-concrete", "r-photo-gulls",
            "r-photo-wave", "r-photo-chandeliers", "r-photo-holly", "r-photo-wave-shore", "r-photo-bird-branches"]
HELD_VALUES = {"saturation": (-100, 100), "vibrance": (-100, 50, 100)}
FIT_VALUES = (-100, -50, 50, 100)
RUNS = OUT / "runs"

# A variant is (slider, value, method, strength). Each method maps a band of the print (float64, linear Rec. 2020)
# and a list of strengths to one staged band per strength; Saturation has no strength and takes m = 1.
METHODS = {
    "S-A": lambda c, s, ms, P: [sat_lightroom(c, s, LR_LUMA["rec2020"]) for _ in ms],
    # The port's likeliest slip: Rec. 2020's own luminance row in place of Lightroom's grey.
    "S-A Rec. 2020 Y": lambda c, s, ms, P: [sat_lightroom(c, s, REC2020_Y / REC2020_Y.sum()) for _ in ms],
    "V-A": lambda c, s, ms, P: vib_hsv_strengths(c, s, P, ms, "rec2020"),
}


# A port holds its images in half floats (the render's print is half floats, widened): the same stages with their
# output rounded to half floats. float32 arithmetic in place of float64 is not simulated; its rounding (about 6e-8
# relative) is four orders below half floats' (about 5e-4).
METHODS["S-A half"] = lambda c, s, ms, P: [x.astype(np.float16) for x in METHODS["S-A"](c, s, ms, P)]
METHODS["V-A half"] = lambda c, s, ms, P: [x.astype(np.float16) for x in METHODS["V-A"](c, s, ms, P)]
PORT = OUT / "port"


def port_check(job, stock, P, strengths):
    """What a port's half floats do on one frame: for S-A at +-100 and V-A at -100, +50, +100 (the stock's strength),
    the block dE76 between the prototype's print and the half-float one (mean, p99), and every lean score of each."""
    path = PORT / f"{job}-{stock}.json"
    if path.exists():
        return json.loads(path.read_text())
    lr = {name: lightroom_blocks(job, name) for name in ["00_base"] + [lr_name(s, v) for s in HELD_VALUES for v in HELD_VALUES[s]]}
    p = render_print(job, stock)
    base = staged_stats(p, [], P, base=True)["base"]
    out = {}
    for slider, values in HELD_VALUES.items():
        for v in values:
            m = strength_of(stock, v, strengths) if slider == "vibrance" else 1.0
            method = "V-A" if slider == "vibrance" else "S-A"
            proto, half = (slider, v, method, m), (slider, v, method + " half", m)
            stats = staged_stats(p, [proto, half], P, gamut=False)
            a, b = (lab_of_xyz(stats[variant_key(x)]["xyz"]) for x in (proto, half))
            d = np.linalg.norm(a - b, axis=-1)
            scores = {name: score_change(lr["00_base"], lr[lr_name(slider, v)], base, stats[variant_key(x)], lean=True)["clip"]
                      for name, x in (("prototype", proto), ("half", half))}
            out[variant_key(proto)] = {"blockDE": {"mean": float(d.mean()), "p99": float(np.percentile(d, 99)), "max": float(d.max())},
                                       **scores}
    del p
    PORT.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(out, indent=0))
    print(f"  port check {job} {stock} done", flush=True)
    return out


def variant_key(v):
    slider, value, method, m = v
    return f"{slider}{value:+d} {method} m{m:g}"


def render_print(job, stock, flags=FLAGS, binary=SPIKE, extra=()):
    """argent-spike's print of `job`'s raw on `stock`, straight from the render (--print-out), in memory."""
    SCRATCH.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=SCRATCH) as folder:
        path = Path(folder) / "print.npy"
        probe.spike(source_raw(job), folder, STOCKS / stock, *flags, *map(str, extra), "--print-out", path, binary=binary)
        return np.load(path)


def staged_stats(p, variants, P, rows=96, base=False, gamut=True):
    """Every variant's stage on print `p`, a band of rows at a time, and with `base` the untouched print as "base": for
    each, its 4 x 4 block means in XYZ (D50) and, with `gamut`, its pixel shares outside Rec. 2020 (F3's), sRGB
    (F3's) and sRGB and Display P3 split into below zero and above white (`gamut_counts`). The staged bands are
    rounded to float32 as F3's are."""
    assert p.shape[0] % 4 == 0 and p.shape[1] % 4 == 0 and rows % 4 == 0
    groups = {}
    for slider, value, method, m in variants:
        groups.setdefault((slider, value, method), []).append(m)
    h, w = p.shape[0] // 4, p.shape[1] // 4
    blocks, counts = {}, {}
    srgb_f3 = SRGB_FROM_REC2020.T.astype(np.float32)

    def add(key, y, out):
        out = out.astype(np.float32)
        b = blocks.setdefault(key, np.empty((h, w, 3), np.float32))
        b[y // 4:(y + out.shape[0]) // 4] = np.asarray(out, np.float64).reshape(out.shape[0] // 4, 4, w, 4, 3).mean(axis=(1, 3))
        if not gamut:
            return
        c = counts.setdefault(key, {})
        srgb = out @ srgb_f3
        for k, v in {"outRec2020": int(np.count_nonzero((out.min(-1) < 0) | (out.max(-1) > 1))),
                     "outSRGB": int(np.count_nonzero((srgb.min(-1) < -1e-4) | (srgb.max(-1) > 1 + 1e-4))),
                     **gamut_counts(out, "argent")}.items():
            c[k] = c.get(k, 0) + v

    for y in range(0, p.shape[0], rows):
        band = np.asarray(p[y:y + rows], np.float64)
        if base:
            add("base", y, band)
        for (slider, value, method), ms in groups.items():
            for m, out in zip(ms, METHODS[method](band, value / 100, ms, P)):
                add(variant_key((slider, value, method, m)), y, out)
    n = p.shape[0] * p.shape[1]
    return {k: {"xyz": scene_io.print_xyz(b), **{name: v / n for name, v in counts.get(k, {}).items()}}
            for k, b in blocks.items()}


XYZ50_TO_REC2020 = np.linalg.inv(scene_io.REC2020_TO_XYZ_D50)
GAMUT_KEYS = ("outRec2020", "outSRGB", "sRGBNeg", "sRGBOver", "sRGBOut", "P3Neg", "P3Over", "P3Out")


def score_change(l0, l1, base, res, lean=False):
    """Argent's change (base -> res) against Lightroom's (l0 -> l1) on the 4 x 4 blocks both bases hold between L* 3
    and 97, three ways:
    - "all": F3's protocol, every such block;
    - "clip": the clip rule, Lightroom's blocks with a clipped pixel in its base or its render left out of the chroma
      and hue measures (dE and lightness keep every block);
    - "inside": the clip rule and only blocks whose Lightroom render lies inside Rec. 2020, the container a print stage
      keeps (S-A clips there at zero).
    Also the grey left (C*), each print's and Lightroom's shares outside the display gamuts, and the clip rule's
    chroma bias by Lightroom's base hue (60-degree sectors of CIELAB D50). `lean` keeps only "clip", for the
    strength grid."""
    L0, L1, a0, a1 = (lab_of_xyz(x["xyz"]) for x in (l0, l1, base, res))
    m = (L0[..., 0] > 3) & (L0[..., 0] < 97) & (a0[..., 0] > 3) & (a0[..., 0] < 97)
    unclipped = ((l0["clip"] == 0) & (l1["clip"] == 0))[m]
    if lean:
        return {"clip": change_errors(L0[m], L1[m], a0[m], a1[m], keep=unclipped), "lean": True}
    inside = ((l1["xyz"] @ XYZ50_TO_REC2020.T.astype(np.float32)).min(-1) >= -GAMUT_TOLERANCE)[m]
    args = (L0[m], L1[m], a0[m], a1[m])
    out = {"all": change_errors(*args), "clip": change_errors(*args, keep=unclipped),
           "inside": change_errors(*args, keep=unclipped & inside),
           "blocks": int(m.sum()), "clippedBlocks": int((~unclipped).sum()), "outsideRec2020Blocks": int((~inside).sum())}
    _, C0r, h0r = lch(args[0])
    _, C1r, _ = lch(args[1])
    _, C0, _ = lch(args[2])
    _, C1, _ = lch(args[3])
    out["greyC"] = {"mean": float(C1.mean()), "p95": float(np.percentile(C1, 95))}
    out["lrGreyC"] = float(C1r.mean())
    chroma = (C0r > 5) & (C0 > 5) & unclipped
    with np.errstate(divide="ignore", invalid="ignore"):
        signed = np.log2(np.maximum(C1, 1e-6) / C0) - np.log2(np.maximum(C1r, 1e-6) / C0r)
    sector = (h0r // 60).astype(int)
    out["byHue"] = {int(60 * k): {"bias%": float(100 * (2 ** np.median(signed[chroma & (sector == k)]) - 1)),
                                  "count": int(np.count_nonzero(chroma & (sector == k)))}
                    for k in range(6) if np.count_nonzero(chroma & (sector == k)) >= 100}
    out["argentGamut"] = {k: res[k] for k in GAMUT_KEYS}
    out["argentBaseGamut"] = {k: base[k] for k in GAMUT_KEYS}
    out["lightroomGamut"] = {k: l1[k] for k in GAMUT_KEYS if k in l1}
    out["lightroomBaseGamut"] = {k: l0[k] for k in GAMUT_KEYS if k in l0}
    return out


def registration(l0, base, reach=3):
    """The block shift that best lays Argent's base on Lightroom's, from the correlation of their log-luminance
    gradients, and the correlation at no shift: a check that the two frames lie pixel on pixel (same orientation,
    no crop)."""
    def grad(x):
        y = np.log2(np.maximum(x["xyz"][..., 1].astype(np.float64), 1e-4))
        return np.hypot(np.diff(y, axis=0)[:, :-1], np.diff(y, axis=1)[:-1])
    if l0["xyz"].shape != base["xyz"].shape:
        return {"shape": [list(l0["xyz"].shape), list(base["xyz"].shape)], "shift": None, "correlation": None}
    a, b = grad(l0), grad(base)
    best, scores = None, {}
    for dy in range(-reach, reach + 1):
        for dx in range(-reach, reach + 1):
            x = a[reach + dy:a.shape[0] - reach + dy, reach + dx:a.shape[1] - reach + dx]
            y = b[reach:b.shape[0] - reach, reach:b.shape[1] - reach]
            scores[(dy, dx)] = float(np.corrcoef(x.ravel(), y.ravel())[0, 1])
    best = max(scores, key=scores.get)
    return {"shift": list(best), "correlation": scores[best], "correlationAtZero": scores[(0, 0)]}


def frame_runs(job, stock, variants, P, flags=FLAGS, lr=None, full=lambda v: True):
    """The score of every variant on `job` printed on `stock`, kept as one JSON per frame and stock under RUNS. Only
    variants not yet kept are rendered, so a rerun costs nothing and an added variant costs one render. A variant
    `full` rejects gets the lean score and no gamut counts. The stages run one group (slider, value, method) at a
    time, so only that group's blocks are held."""
    path = RUNS / f"{job}-{stock}-{flag_tag(flags)}.json"
    done = json.loads(path.read_text()) if path.exists() else {}
    todo = [v for v in variants if variant_key(v) not in done]
    if not todo:
        return done
    lr = lr if lr is not None else {}

    def get(name):
        if name not in lr:
            lr[name] = lightroom_blocks(job, name)
        return lr[name]
    t = time.time()
    p = render_print(job, stock, flags)
    base = staged_stats(p, [], P, base=True)["base"]
    done["base"] = {k: base[k] for k in GAMUT_KEYS}
    done["registration"] = registration(get("00_base"), base)
    done["baseMeasures"] = base_measures(get("00_base"), base)
    groups = {}
    for v in todo:
        groups.setdefault((v[0], v[1], v[2], bool(full(v))), []).append(v)
    for (slider, value, _, whole), group in groups.items():
        stats = staged_stats(p, group, P, gamut=whole)
        for v in group:
            done[variant_key(v)] = score_change(get("00_base"), get(lr_name(slider, value)), base, stats[variant_key(v)],
                                                lean=not whole)
        del stats
    del p
    RUNS.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(done, indent=0))
    print(f"  {job} {stock}: {len(todo)} variants in {time.time() - t:.0f} s", flush=True)
    return done


def base_measures(l0, base):
    """How Argent's base print differs from Lightroom's base render, block for block, as candidates for the property
    that sets Vibrance's strength: the median ratio of CIELAB C*, of HSV saturation (linear, Argent's print and
    Lightroom's export both display-referred), and the spread of L* (interquartile range, Argent's over Lightroom's),
    on blocks both hold between L* 3 and 97 with C* above 5 and nothing clipped."""
    L0, a0 = lab_of_xyz(l0["xyz"]), lab_of_xyz(base["xyz"])
    m = (L0[..., 0] > 3) & (L0[..., 0] < 97) & (a0[..., 0] > 3) & (a0[..., 0] < 97) & (l0["clip"] == 0)
    Cr, Ca = lch(L0)[1], lch(a0)[1]
    chroma = m & (Cr > 5) & (Ca > 5)
    hsv_s = lambda rgb: (rgb.max(-1) - rgb.min(-1)) / np.maximum(rgb.max(-1), 1e-9)
    to_pro = np.linalg.inv(PROPHOTO_TO_XYZ).astype(np.float32).T
    Sr, Sa = hsv_s(np.maximum(l0["xyz"] @ to_pro, 0)), hsv_s(np.maximum(base["xyz"] @ to_pro, 0))
    iqr = lambda x: float(np.subtract(*np.percentile(x, [75, 25])))
    return {"chromaRatio": float(np.median(Ca[chroma] / Cr[chroma])), "hsvSRatio": float(np.median(Sa[chroma] / Sr[chroma])),
            "argentHsvS": float(np.median(Sa[chroma])), "lightroomHsvS": float(np.median(Sr[chroma])),
            "argentC": float(np.mean(Ca[m])), "lightroomC": float(np.mean(Cr[m])),
            "lightnessSpreadRatio": iqr(a0[..., 0][m]) / iqr(L0[..., 0][m]), "chromaBlocks": int(chroma.sum())}


# MARK: Round 3's open questions, in Lightroom's terms

BETWEEN = (-100, -75, -50, -25, -10, 10, 25, 50, 75, 100)
KNOTS = (-100, -50, -25, 25, 50, 100)


def golden(f, lo, hi, iterations=60):
    """The minimum of f, unimodal on [lo, hi], by golden-section search."""
    g = (5 ** 0.5 - 1) / 2
    a, b = lo, hi
    c, d = b - g * (b - a), a + g * (b - a)
    fc, fd = f(c), f(d)
    for _ in range(iterations):
        if fc < fd:
            b, d, fd = d, c, fc
            c = b - g * (b - a)
            fc = f(c)
        else:
            a, c, fc = c, d, fd
            d = a + g * (b - a)
            fd = f(d)
    return (a + b) / 2


def vibrance_between_knots(P, tone):
    """F3's request 3: V-A, constants unchanged, on the TIFF grid at every value from -100 to +100, all from one session
    (r-colour-grid-tif), before the curve. Per value: V-A's error in Lightroom's terms on the patches (as F3's section 5
    table), and mu and nu on patches and every 4th ramp sample: mu multiplies the gain's departure from 1
    (g = 1 + mu (g_V-A - 1)) and is fitted to Lightroom's HSV saturation, nu multiplies the value term (log2 of HSV
    value) by least squares. mu = nu = 1 where the fitted law passes through the value; F3 fitted it at the knots
    (+-25, +-50, +-100), so +-10 and +-75 test it."""
    meta, R = grid_table("r-colour-grid-tif")
    rows = vib_fit_data("r-colour-grid-tif", tone, BETWEEN)
    out = {}
    for v in BETWEEN:
        s = v / 100
        b, r = R["base"]["patch"], R[f"vibrance:{v:+d}"]["patch"]
        ok = usable(b) & usable(r) & (meta["group"] != "neutral")
        c0, c1 = rgbtone(b[ok], tone.inverse), rgbtone(r[ok], tone.inverse)
        e = change_errors(lab_prophoto(c0), lab_prophoto(c1), lab_prophoto(c0), lab_prophoto(np.maximum(vib_hsv(c0, s, P), 0)))
        skin = (meta["group"] == "skin")[ok]
        es = change_errors(*(lab_prophoto(x[skin]) for x in (c0, c1, c0, np.maximum(vib_hsv(c0, s, P), 0))))
        a0, a1 = rows[v]
        V0, S0, _ = hsv_split(a0)
        V1, S1, _ = hsv_split(a1)
        h, l = ok_hue(a0), lightness_stops(a0)
        g = vib_gain(S0, h, l, s, P)
        miss = lambda mu: rms(np.clip(knee(S0, 1 + mu * (g - 1), P["sknee"]), 0, 1) - S1)
        mu = golden(miss, 0.2, 4.0)
        vv, meas = vib_value(S0, l, s, P), np.log2(np.maximum(V1, 1e-9) / np.maximum(V0, 1e-9))
        nu = float(vv @ meas / (vv @ vv))
        if s > 0:
            amp = P["pos"]["a1"] * s + P["pos"]["a2"] * s * s
        else:
            amp = -s * (1 + P["neg"]["kappa"] * (1 + s))
        out[v] = {"knot": v in KNOTS, "mu": mu, "nu": nu, "sRms": {"fitted law": miss(1.0), "best mu": miss(mu)},
                  "amplitude": {"law": amp, "lightroom": mu * amp}, "samples": int(len(S0)),
                  "dE": e["dE"], "ratio%": e["chromaRatio%"]["median"], "bias%": e["chromaRatio%"]["bias"],
                  "hueP95": e["hueP95"], "LP95": e["lightnessP95"], "patches": int(ok.sum()),
                  "skin": {"dE": es["dE"], "patches": int(skin.sum())}}
    # The positive amplitude's shape: Lightroom's measured amplitudes against F3's a1 s + a2 s^2 and against
    # a1 s + a3 s^3, each fitted by least squares on all five positive values.
    sv = np.array([v / 100 for v in BETWEEN if v > 0])
    A = np.array([out[v]["amplitude"]["lightroom"] for v in BETWEEN if v > 0])
    shapes = {}
    for name, X in (("a1 s + a2 s^2", np.stack([sv, sv ** 2], 1)), ("a1 s + a3 s^3", np.stack([sv, sv ** 3], 1))):
        coef, *_ = np.linalg.lstsq(X, A, rcond=None)
        shapes[name] = {"coefficients": coef.round(4).tolist(), "relativeMiss": ((X @ coef) / A - 1).round(4).tolist()}
    shapes["F3's a1 s + a2 s^2"] = {"coefficients": [P["pos"]["a1"], P["pos"]["a2"]],
                                   "relativeMiss": ((P["pos"]["a1"] * sv + P["pos"]["a2"] * sv ** 2) / A - 1).round(4).tolist()}
    out["positiveAmplitudeShape"] = {"s": sv.tolist(), "lightroom": A.round(4).tolist(), **shapes}
    return out


def own_tone(meta, render):
    """A DNG grid render's own tone curve, from its unclipped neutral patches (chart luminance against the render's)."""
    n = (meta["group"] == "neutral") & usable(render["patch"])
    return Tone(meta["chart"][n] @ REC2020_Y, render["patch"][n] @ PROPHOTO_Y)


def in_curve(tone, rgb):
    """Patches whose every channel lies inside the range the curve was measured on, so taking them back through it
    interpolates and never extrapolates."""
    return (np.log2(np.maximum(rgb.min(-1), 1e-12)) >= tone.y[0]) & (np.log2(np.maximum(rgb.max(-1), 1e-12)) <= tone.y[-1])


def exposure_pairs(P):
    """F3's requests 1 and 2 on r-colour-grid (the DNG grid; each render taken back through its own curve, read from
    its neutrals, so every render is chart-referred):
    - whether Exposure is a gain before the curve: each Exposure render's neutrals against the base curve at 2^e times
      the chart;
    - Saturation +50 beside Exposure +-1: k on the deviation from Lightroom's grey and the share k leaves unexplained,
      with the render taken back hue-preserving (as the SDK's curve acts) and per channel, by lightness row;
    - Vibrance +-100 beside Exposure +-1: the level its lightness weights read. Against Vibrance alone, the pair's
      gain departure (+100) or value term (-100) changes by w(l + delta) / w(l) if the weight reads l + delta; delta
      is fitted (0: the scene's level before Exposure; e: the level after it). Also V-A's whole error with l read
      either way."""
    meta, R = grid_table("r-colour-grid")
    T = {name: own_tone(meta, d) for name, d in R.items()}
    pre = {name: rgbtone(d["patch"], T[name].inverse) for name, d in R.items()}
    n, colour = meta["group"] == "neutral", meta["group"] != "neutral"
    y = meta["chart"][n] @ REC2020_Y
    out = {"exposureAsGain": {}, "saturation": {}, "vibrance": {}}
    for e in (1, -1):
        inside = (2.0 ** e * y > 2 ** T["base"].x[0]) & (2.0 ** e * y < 2 ** T["base"].x[-1])
        d = probe.lstar(R[f"ex{e:+d}"]["patch"][n] @ PROPHOTO_Y) - probe.lstar(T["base"](2.0 ** e * y))
        both = colour & usable(R["base"]["patch"]) & usable(R[f"ex{e:+d}"]["patch"])
        out["exposureAsGain"][e] = {"maxDL": float(np.abs(d[inside]).max()), "rmsDL": rms(d[inside]), "neutrals": int(inside.sum()),
                                    "chartReferredMatch": float(np.median(np.linalg.norm(pre[f"ex{e:+d}"] - pre["base"], axis=1)[both]
                                                                          / np.linalg.norm(pre["base"], axis=1)[both]))}

    def sat_k(c0, c1, ok):
        k, unexplained = per_patch_gain(c0[ok], c1[ok])
        rows = {float(L): float(np.median(k[meta["L"][ok] == L])) for L in np.unique(meta["L"][ok]) if (meta["L"][ok] == L).sum() >= 10}
        return {"k": float(np.median(k)), "k10": float(np.percentile(k, 10)), "k90": float(np.percentile(k, 90)),
                "unexplainedP95": float(np.percentile(unexplained, 95)),
                "offLineP95": float(np.percentile(off_line(c0[ok], c1[ok]), 95)), "byLightness": rows, "patches": int(ok.sum())}
    for e in (0, 1, -1):
        e0, e1 = ("base", "saturation:+50") if e == 0 else (f"ex{e:+d}", f"ex{e:+d}:sat+50")
        ok = usable(R["base"]["patch"]) & usable(R[e0]["patch"]) & usable(R[e1]["patch"]) & (meta["group"] == "grid")
        measured = ok & in_curve(T[e0], R[e0]["patch"]) & in_curve(T[e1], R[e1]["patch"])
        out["saturation"][e] = {"hue-preserving curve": sat_k(pre[e0], pre[e1], ok),
                                "hue-preserving, inside the measured curve": sat_k(pre[e0], pre[e1], measured),
                                "per-channel curve": sat_k(T[e0].inverse(R[e0]["patch"]), T[e1].inverse(R[e1]["patch"]), ok)}

    w = lambda l, c, sd: np.exp(-0.5 * ((l - c) / sd) ** 2)
    for v in (100, -100):
        s = v / 100
        side = "pos" if v > 0 else "neg"
        alone = ("base", f"vibrance:{v:+d}")
        for e in (1, -1):
            pair = (f"ex{e:+d}", f"ex{e:+d}:vib{v:+d}")
            ok = colour & np.all([usable(R[k]["patch"]) & in_curve(T[k], R[k]["patch"]) for k in alone + pair], axis=0)
            (Va0, Sa0, _), (Va1, Sa1, _) = (hsv_split(pre[k][ok]) for k in alone)
            (Vp0, Sp0, _), (Vp1, Sp1, _) = (hsv_split(pre[k][ok]) for k in pair)
            l = lightness_stops(pre["base"][ok])
            if v > 0:
                ga, gp = Sa1 / np.maximum(Sa0, 1e-9), Sp1 / np.maximum(Sp0, 1e-9)
                sel = (ga - 1 > 0.2) & (gp - 1 > 0.05) & (Sa1 < 0.8) & (Sp1 < 0.8)
                ratio, centre, sd = (gp - 1)[sel] / (ga - 1)[sel], P["pos"]["l0"], P["pos"]["sigma"]
                measure = "gain departure"
            else:
                va, vp = np.log2(Va1 / Va0), np.log2(Vp1 / Vp0)
                sel = (va < -0.15) & (vp < -0.05)
                ratio, centre, sd = vp[sel] / va[sel], P[side]["lv"], P[side]["sv"]
                measure = "value term"
            ls = l[sel]
            miss = lambda dl: rms(np.log(np.maximum(ratio, 1e-6)) - np.log(w(ls + dl, centre, sd) / w(ls, centre, sd)))
            delta = golden(miss, -3.0, 3.0)
            whole = {}
            for name, scale in (("scene level", 1.0), ("output level", 2.0 ** e)):
                pred = vib_hsv(scale * pre[pair[0]][ok], s, P) / scale
                whole[name] = float(np.linalg.norm(lab_prophoto(np.maximum(pred, 0)) - lab_prophoto(pre[pair[1]][ok]), axis=1).mean())
            alone_dE = float(np.linalg.norm(lab_prophoto(np.maximum(vib_hsv(pre["base"][ok], s, P), 0)) - lab_prophoto(pre[alone[1]][ok]), axis=1).mean())
            out["vibrance"][f"{v:+d} beside {e:+d}"] = {
                "measure": measure, "patches": int(sel.sum()), "delta": delta, "medianRatio": float(np.median(ratio)),
                "miss": {"scene level (delta 0)": miss(0.0), "output level (delta e)": miss(float(e)), "best delta": miss(delta)},
                "V-A dE": {**whole, "Vibrance alone": alone_dE}}
    return out


def lightroom_terms_step():
    P = vibrance_constants()["hsv"]["constants"]
    for which in GRIDS:
        grid_table(which, refresh=not (DATA / f"grid-{which}.npz").exists())
    tone = Tone()
    result = {"betweenKnots": vibrance_between_knots(P, tone), "exposure": exposure_pairs(P)}
    write_json("round3-lightroom-terms.json", result)
    print("Vibrance between the knots (r-colour-grid-tif, before the curve): V-A dE mean/p95, ratio %, bias %, L p95; "
          "mu (gain), nu (value term); amplitude law -> Lightroom's")
    for v, d in result["betweenKnots"].items():
        if v == "positiveAmplitudeShape":
            print("  positive amplitude shape:", json.dumps(d))
            continue
        print(f"  {v:+4d}{'*' if d['knot'] else ' '} dE {d['dE']['mean']:.2f}/{d['dE']['p95']:.2f} ratio {d['ratio%']:5.1f} "
              f"bias {d['bias%']:+6.1f} L {d['LP95']:.2f} | mu {d['mu']:.3f} nu {d['nu']:.3f} | S rms {d['sRms']['fitted law']:.4f} "
              f"-> {d['sRms']['best mu']:.4f} | amplitude {d['amplitude']['law']:.3f} -> {d['amplitude']['lightroom']:.3f} | "
              f"skin patches dE {d['skin']['dE']['mean']:.2f}/{d['skin']['dE']['p95']:.2f} ({d['skin']['patches']})")
    x = result["exposure"]
    print("Exposure as a gain before the curve:", json.dumps(x["exposureAsGain"]))
    for e, d in x["saturation"].items():
        for how, r in d.items():
            print(f"  Saturation +50 beside Exposure {e:+d}, {how}: k {r['k']:.3f} [{r['k10']:.3f}, {r['k90']:.3f}] "
                  f"unexplained p95 {r['unexplainedP95']:.3f} off line p95 {r['offLineP95']:.4f} ({r['patches']} patches) "
                  f"by L*: " + " ".join(f"{L:g}:{k:.3f}" for L, k in r["byLightness"].items()))
    for name, d in x["vibrance"].items():
        print(f"  Vibrance {name}: {d['measure']}, {d['patches']} patches, median ratio {d['medianRatio']:.3f}, delta {d['delta']:+.2f} | "
              + " | ".join(f"{k} {m:.4f}" for k, m in d["miss"].items()) + " | V-A dE " + " ".join(f"{k} {m:.2f}" for k, m in d["V-A dE"].items()))
    return result


M_POS = (1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 3.5, 4.0, 5.0)
M_NEG = (0.8, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0, 2.5)


def strength_grid(values, top=None):
    return [("vibrance", v, "V-A", m) for v in values for m in (M_POS if v > 0 else M_NEG) if top is None or m <= top]


def fit_variants(stock):
    """Round 1's frames: S-A as F3 scored it, and V-A over the strength grid, at the four values every frame has."""
    return [("saturation", v, "S-A", 1.0) for v in FIT_VALUES] + strength_grid(FIT_VALUES)


def load_runs(frames, stocks=ALL_STOCKS, flags=FLAGS):
    """{frame: {stock: {variant key: score}}} for every kept frame and stock."""
    out = {}
    for job in frames:
        for stock in stocks:
            path = RUNS / f"{job}-{stock}-{flag_tag(flags)}.json"
            if path.exists():
                out.setdefault(job, {})[stock] = json.loads(path.read_text())
    return out


def zero_crossing(ms, ys):
    """The strength where y (a chroma bias, monotone in m: it rises with m above zero and falls below) crosses zero,
    interpolated linearly in log m between the grid points that bracket it; None when the grid does not bracket it."""
    ms, ys = np.log(np.asarray(ms, float)), np.asarray(ys, float)
    for i in range(len(ms) - 1):
        if (ys[i] <= 0 <= ys[i + 1] or ys[i] >= 0 >= ys[i + 1]) and ys[i] != ys[i + 1]:
            return float(np.exp(ms[i] + (ms[i + 1] - ms[i]) * ys[i] / (ys[i] - ys[i + 1])))
    return None


def grid_minimum(ms, ys):
    """The strength that minimises y over the grid, refined by a parabola in log m through the lowest grid point and
    its neighbours; the grid's end when the lowest point is there."""
    x, y = np.log(np.asarray(ms, float)), np.asarray(ys, float)
    i = int(np.argmin(y))
    if i in (0, len(x) - 1):
        return float(ms[i])
    a, b, c = np.polyfit(x[i - 1:i + 2], y[i - 1:i + 2], 2)
    return float(np.exp(np.clip(-b / (2 * a), x[i - 1], x[i + 1]))) if a > 0 else float(ms[i])


def grid_curve(runs, frames, stock, value, field="bias", grid=None):
    """Over the strength grid at one value: the clip rule's chroma bias (or ratio error), mean over `frames`, on
    `grid` or else on the grid points every frame holds."""
    if grid is None:
        grid = [m for m in (M_POS if value > 0 else M_NEG)
                if all(variant_key(("vibrance", value, "V-A", m)) in runs[job][stock] for job in frames)]
    get = lambda job, m: runs[job][stock][variant_key(("vibrance", value, "V-A", m))]["clip"]["chromaRatio%"]
    key = "bias" if field == "bias" else "median"
    return grid, [float(np.mean([get(job, m)[key] for job in frames])) for m in grid]


def strength_fit(runs, frames):
    """Vibrance's strength per stock on `frames`, per sign (m+ from +50 and +100, m- from -50 and -100):
    - "m+" and "m-", the strength used: the m that minimises the mean chroma-ratio error (clip rule) of the sign's two
      values, the measure the bars hold;
    - "zeroBias+" and "zeroBias-", the criterion fixed before the run: where the mean of the two values' chroma bias
      crosses zero (None when no m on the grid reaches it);
    - per value, the m of zero bias and of least ratio error, and the spread of the per-frame strengths, to tell a real
      difference between the signs from frame noise."""
    out = {}
    for stock in ALL_STOCKS:
        row = {"byValue": {}, "byFrame": {}}
        for v in FIT_VALUES:
            grid, bias = grid_curve(runs, frames, stock, v)
            _, ratio = grid_curve(runs, frames, stock, v, "ratio")
            row["byValue"][v] = {"zeroBias": zero_crossing(grid, bias), "leastRatio": grid_minimum(grid, ratio),
                                 "biasAtM1": bias[grid.index(1.0)], "ratioAtM1": ratio[grid.index(1.0)], "bias": bias, "ratio": ratio}
        for sign, values in (("+", (50, 100)), ("-", (-50, -100))):
            grid = sorted(set.intersection(*(set(grid_curve(runs, frames, stock, v)[0]) for v in values)))
            curve = lambda js, field: np.mean([grid_curve(runs, js, stock, v, field, grid)[1] for v in values], axis=0)
            row[f"m{sign}"] = grid_minimum(grid, curve(frames, "ratio"))
            row[f"zeroBias{sign}"] = zero_crossing(grid, curve(frames, "bias"))
            per = [grid_minimum(grid, curve([job], "ratio")) for job in frames]
            row["byFrame"][sign] = dict(zip(frames, per))
            row[f"m{sign}Spread"] = float(np.std(per))
        out[stock] = row
    return out


STOCK_PROPERTIES = ("chromaRatio", "hsvSRatio", "argentHsvS", "lightnessSpreadRatio")


def strength_rule(fit, runs, frames):
    """Which measurable property of a stock predicts its strength: each property of `base_measures`, averaged over
    `frames`, against m+ and m- across the six stocks, as a straight line; its correlation and its leave-one-out
    error (each stock's m predicted from the other five)."""
    props = {stock: {p: float(np.mean([runs[job][stock]["baseMeasures"][p] for job in frames])) for p in STOCK_PROPERTIES}
             for stock in ALL_STOCKS}
    out = {"properties": props, "fits": {}}
    for target in ("m+", "m-"):
        y = np.array([fit[s][target] for s in ALL_STOCKS], float)
        for p in STOCK_PROPERTIES:
            x = np.array([props[s][p] for s in ALL_STOCKS])
            slope, icept = np.polyfit(x, y, 1)
            loo = []
            for i in range(len(x)):
                k = np.arange(len(x)) != i
                a, b = np.polyfit(x[k], y[k], 1)
                loo.append(a * x[i] + b - y[i])
            out["fits"].setdefault(target, {})[p] = {"slope": float(slope), "intercept": float(icept),
                                                     "r": float(np.corrcoef(x, y)[0, 1]), "looRms": rms(loo),
                                                     "looMax": float(np.max(np.abs(loo))), "spreadOfM": float(np.std(y))}
    return out


def strength_step():
    runs = load_runs(FILM_SOURCES)
    fit = strength_fit(runs, FILM_SOURCES)
    rule = strength_rule(fit, runs, FILM_SOURCES)
    write_json("strength-fit.json", {"fit": fit, "rule": rule, "frames": FILM_SOURCES, "grid": {"+": M_POS, "-": M_NEG}})
    print("Vibrance strength per stock on round 1's frames (clip rule): m where the mean chroma bias crosses zero")
    print(f"  {'stock':20s} least ratio error at -100 -50 +50 +100 | zero bias at -100 -50 +50 +100 | m- (sd) m+ (sd) | zero bias m- m+ | bias at m=1")
    f = lambda x: f"{x:5.2f}" if x is not None else "    -"
    for stock, r in fit.items():
        bv = r["byValue"]
        print(f"  {stock:20s} " + " ".join(f(bv[v]["leastRatio"]) for v in FIT_VALUES) + " | " + " ".join(f(bv[v]["zeroBias"]) for v in FIT_VALUES)
              + f" | {f(r['m-'])} ({r['m-Spread']:.2f}) {f(r['m+'])} ({r['m+Spread']:.2f}) | {f(r['zeroBias-'])} {f(r['zeroBias+'])} | "
              + " ".join(f"{bv[v]['biasAtM1']:+6.1f}" for v in FIT_VALUES))
    print("Stock properties (mean over round 1's frames) and how well each predicts m:")
    for stock, p in rule["properties"].items():
        print(f"  {stock:20s} " + " ".join(f"{k} {v:.3f}" for k, v in p.items()))
    for target, fits in rule["fits"].items():
        for p, d in fits.items():
            print(f"  {target} from {p:22s} r {d['r']:+.3f}  slope {d['slope']:+.3f} intercept {d['intercept']:+.3f}  "
                  f"leave-one-out rms {d['looRms']:.3f} max {d['looMax']:.3f}  (spread of m {d['spreadOfM']:.3f})")
    return fit, rule


def fitted_strengths():
    """Each stock's Vibrance strength for each sign, from round 1's frames (strength-fit.json), to two decimals as a
    build would carry it: "+" and "-" (least ratio error, used), "zeroBias+" and "zeroBias-" (None where unreached)."""
    fit = json.loads((OUT / "strength-fit.json").read_text())["fit"]
    r = lambda x: None if x is None else round(x, 2)
    return {stock: {k: r(fit[stock][f]) for k, f in (("+", "m+"), ("-", "m-"), ("zeroBias+", "zeroBias+"), ("zeroBias-", "zeroBias-"))}
            for stock in fit}


def strength_of(stock, value, strengths=None):
    strengths = strengths or fitted_strengths()
    return strengths[stock]["+" if value > 0 else "-"]


def heldout_variants(stock):
    """The held-out frames: S-A at the values round 3 rendered (with Rec. 2020's own luminance row beside it on the two
    scorer stocks, a slip the bars must catch), and V-A at its values at m = 1, at the stock's fitted strength, and
    over the strength grid (lean), to see which strength the new frames would ask for."""
    strengths = fitted_strengths()
    v = [("saturation", x, "S-A", 1.0) for x in HELD_VALUES["saturation"]]
    if stock in SCORE_STOCKS:
        v += [("saturation", x, "S-A Rec. 2020 Y", 1.0) for x in HELD_VALUES["saturation"]]
    v += strength_grid(HELD_VALUES["vibrance"], top=3.5)
    v += [("vibrance", x, "V-A", strength_of(stock, x, strengths)) for x in HELD_VALUES["vibrance"]]
    v += [("vibrance", x, "V-A", zb) for x in HELD_VALUES["vibrance"]
          for zb in [strengths[stock]["zeroBias+" if x > 0 else "zeroBias-"]] if zb is not None]
    return list(dict.fromkeys(v))


def insample_variants(stock):
    """Round 1's frames at the stock's fitted strength, for the in-sample column beside the held-out one."""
    strengths = fitted_strengths()
    return fit_variants(stock) + [("vibrance", x, "V-A", strength_of(stock, x, strengths)) for x in FIT_VALUES]


def full_for(stock):
    """Every measure for S-A, for V-A at m = 1 and at the stock's fitted strengths; the lean score for the grid."""
    fitted = set(fitted_strengths()[stock].values()) - {None} if (OUT / "strength-fit.json").exists() else set()
    return lambda v: v[2] != "V-A" or v[3] == 1.0 or v[3] in fitted


MIN_CHROMA_BLOCKS = 1000


def metrics(score, rule="clip"):
    """One run's numbers under `rule` ("all", F3's protocol, or "clip"). Chroma, hue and strength enter only when at
    least MIN_CHROMA_BLOCKS blocks hold chroma in both bases (a near-grey frame has too few to measure a ratio)."""
    e = score[rule]
    enough = e["chromaCount"] >= MIN_CHROMA_BLOCKS
    dC = e["dC"]
    return {"ratio%": e["chromaRatio%"]["median"] if enough else None,
            "bias%": e["chromaRatio%"]["bias"] if enough else None,
            "hueP95": e["hueP95"] if enough else None, "LP95": e["lightnessP95"], "dE": e["dE"]["mean"],
            "strength": dC["argent"] / dC["lightroom"] if enough and abs(dC["lightroom"]) > 0.05 else None,
            "greyC": score["greyC"]["mean"] if "greyC" in score else None,
            "chromaBlocks": e["chromaCount"], "leftOut": e["clippedLeftOut"]}


METRIC_NAMES = ("ratio%", "bias%", "hueP95", "LP95", "dE", "strength", "greyC")


def mean_metrics(runs, frames, stocks, variant_of, rule="clip"):
    """The mean of each metric over frames and stocks (None entries left out), with how many runs entered each, the
    blocks the clip rule left out, and the per-run values. `variant_of(stock)` gives the variant to read."""
    cells = [(job, stock, metrics(runs[job][stock][variant_key(variant_of(stock))], rule))
             for job in frames for stock in stocks if job in runs and stock in runs[job]
             and variant_key(variant_of(stock)) in runs[job][stock]]
    out = {"runs": len(cells)}
    for k in METRIC_NAMES:
        vals = [c[k] for _, _, c in cells if c[k] is not None]
        out[k] = float(np.mean(vals)) if vals else None
        out[f"{k}Runs"] = len(vals)
    out["leftOut"] = int(sum(c["leftOut"] for _, _, c in cells))
    out["chromaBlocks"] = int(sum(c["chromaBlocks"] for _, _, c in cells))
    out["perRun"] = {f"{job}|{stock}": c for job, stock, c in cells}
    return out


def f3_reported(slider, value):
    """F3's own print-placement mean (10 runs) at `value`, from its saved summary, or None where it has none."""
    name, label = (("saturation-film.json", "luma blend, clip (Lightroom's law) | print") if slider == "saturation"
                   else ("vibrance-film.json", f"{VIB_LABELS['hsv']} | print"))
    row = json.loads((FIT / name).read_text())["summary"][label].get(str(value))
    if row is None:
        return None
    return {"ratio%": row["ratio%"], "bias%": row["ratioBias%"], "hueP95": row["hueP95"], "LP95": row["LP95"],
            "dE": row["dE"], "strength": row["strength"], "greyC": row["greyC"], "runs": row["runs"]}


def frame_properties(job):
    """What a frame is like, from Lightroom's base (round 3's manifest statistics) and its runs."""
    for path in MANIFESTS:
        for e in json.loads(path.read_text())["exports"]:
            if e["job"] == job and e["label"] == "00_base":
                return {k: e["stats"][k] for k in ("lightness", "chroma", "spread")}
    return {}


def heldout_summary(held, ins, strengths):
    """Steps 2, 3, 5 and 6 from the kept runs: the held-out means beside the in-sample ones, both protocols."""
    out = {"frames": HELD_OUT, "strengths": strengths, "registration": {}, "methods": {}, "strength": {},
           "ranking": {}, "gamut": {}}
    for job in HELD_OUT:
        out["registration"][job] = held[job][SCORE_STOCKS[0]]["registration"]
    for slider, method in (("saturation", "S-A"), ("vibrance", "V-A")):
        for v in HELD_VALUES[slider]:
            row = {}
            for rule in ("clip", "all"):
                variant = lambda st: (slider, v, method, 1.0)
                row[f"heldout {rule}"] = mean_metrics(held, HELD_OUT, SCORE_STOCKS, variant, rule)
                row[f"insample {rule}"] = mean_metrics(ins, FILM_SOURCES, SCORE_STOCKS, variant, rule)
            row["F3 reported"] = f3_reported(slider, v)
            out["methods"].setdefault(slider, {})[v] = row
    for stock in ALL_STOCKS:
        rows = {}
        for v in HELD_VALUES["vibrance"]:
            m = strength_of(stock, v, strengths)
            zb = strengths[stock]["zeroBias+" if v > 0 else "zeroBias-"]
            rows[v] = {"m": m, "zeroBiasM": zb,
                       "heldout m=1": mean_metrics(held, HELD_OUT, [stock], lambda st: ("vibrance", v, "V-A", 1.0)),
                       "heldout fitted": mean_metrics(held, HELD_OUT, [stock], lambda st, m=m: ("vibrance", v, "V-A", m)),
                       "heldout zero-bias m": (mean_metrics(held, HELD_OUT, [stock], lambda st, zb=zb: ("vibrance", v, "V-A", zb))
                                               if zb is not None else None),
                       "insample fitted": mean_metrics(ins, FILM_SOURCES, [stock], lambda st, m=m: ("vibrance", v, "V-A", m)),
                       "heldoutWouldAsk": {"leastRatio": grid_minimum(*grid_curve(held, HELD_OUT, stock, v, "ratio")),
                                           "zeroBias": zero_crossing(*grid_curve(held, HELD_OUT, stock, v))}}
        for sign, values in (("+", (50, 100)), ("-", (-100,))):
            grid = sorted(set.intersection(*(set(grid_curve(held, HELD_OUT, stock, v)[0]) for v in values)))
            rows[f"heldoutWouldAsk{sign}"] = {
                "leastRatio": grid_minimum(grid, np.mean([grid_curve(held, HELD_OUT, stock, v, "ratio", grid)[1] for v in values], axis=0)),
                "zeroBias": zero_crossing(grid, np.mean([grid_curve(held, HELD_OUT, stock, v, "bias", grid)[1] for v in values], axis=0))}
        rows["saturation"] = {v: mean_metrics(held, HELD_OUT, [stock], lambda st, v=v: ("saturation", v, "S-A", 1.0))
                              for v in HELD_VALUES["saturation"]}
        out["strength"][stock] = rows
    for slider, variant_of in (("saturation", lambda st: ("saturation", 100, "S-A", 1.0)),
                               ("vibrance", lambda st: ("vibrance", 100, "V-A", strength_of(st, 100, strengths)))):
        rows = {}
        for job in HELD_OUT:
            runs = [held[job][st][variant_key(variant_of(st))] for st in SCORE_STOCKS]
            per = [metrics(r) for r in runs]
            mean = lambda k: (float(np.mean([p[k] for p in per if p[k] is not None])) if any(p[k] is not None for p in per) else None)
            inside = [metrics(r, "inside") for r in runs]
            rows[job] = {**{k: mean(k) for k in ("ratio%", "bias%", "hueP95", "LP95")},
                         "insideRatio%": (float(np.mean([p["ratio%"] for p in inside if p["ratio%"] is not None]))
                                          if any(p["ratio%"] is not None for p in inside) else None),
                         "allRatio%": (float(np.mean([metrics(r, "all")["ratio%"] for r in runs if metrics(r, "all")["ratio%"] is not None]))
                                       if any(metrics(r, "all")["ratio%"] is not None for r in runs) else None),
                         "clippedShare": float(np.mean([r["clippedBlocks"] / r["blocks"] for r in runs])),
                         "outsideRec2020Share": float(np.mean([r["outsideRec2020Blocks"] / r["blocks"] for r in runs])),
                         "byHue": {st: r["byHue"] for st, r in zip(SCORE_STOCKS, runs)},
                         "chromaBlocks": int(np.mean([p["chromaBlocks"] for p in per])), **frame_properties(job)}
        out["ranking"][slider] = dict(sorted(rows.items(), key=lambda kv: -(kv[1]["ratio%"] if kv[1]["ratio%"] is not None else -1)))
        scored = [r for r in rows.values() if r["ratio%"] is not None]
        out.setdefault("missCorrelation", {})[slider] = {
            prop: spearman([r["ratio%"] for r in scored], [r[prop] for r in scored])
            for prop in ("clippedShare", "outsideRec2020Share", "chroma", "lightness", "spread", "chromaBlocks")}
    for job in HELD_OUT:
        row = {}
        for stock in SCORE_STOCKS:
            r = held[job][stock]
            sat = r[variant_key(("saturation", 100, "S-A", 1.0))]
            vib = r[variant_key(("vibrance", 100, "V-A", strength_of(stock, 100, strengths)))]
            row[stock] = {"argent base": r["base"], "argent saturation +100": sat["argentGamut"],
                          "argent vibrance +100": vib["argentGamut"]}
            row["lightroom base"], row["lightroom saturation +100"] = sat["lightroomBaseGamut"], sat["lightroomGamut"]
            row["lightroom vibrance +100"] = vib["lightroomGamut"]
        out["gamut"][job] = row
    return out


def level_check(frames, stocks=SCORE_STOCKS):
    """Where V-A's lightness weight (+100: a Gaussian in log2(Y / 0.18), centre l0, width sigma) falls on each frame:
    its mean over the frame on Argent's print (quarter-size decode, the app's preview) and on Lightroom's base taken
    back before its curve. The DNG grid's curve stands in for the ARW's under Adobe Standard, so Lightroom's level is
    approximate. A ratio above 1 means the print stage weights the frame's boost more than Lightroom does."""
    P, tone = vibrance_constants()["hsv"]["constants"]["pos"], Tone()
    weight = lambda l: np.exp(-0.5 * ((l - P["l0"]) / P["sigma"]) ** 2)
    out = {}
    for job in frames:
        lr = lightroom_blocks(job, "00_base")
        ok = (lr["clip"] == 0) & (lr["xyz"][..., 1] > 1e-4)
        pre = rgbtone(np.maximum(lr["xyz"][ok] @ np.linalg.inv(PROPHOTO_TO_XYZ).T, 0), tone.inverse)
        l_lr = lightness_stops(pre)
        row = {"lightroomLevel": float(np.median(l_lr)), "lightroomWeight": float(weight(l_lr).mean())}
        for stock in stocks:
            p = render_print(job, stock, QUARTER)
            l_a = lightness_stops(np.maximum(to_prophoto(np.asarray(p, np.float64).reshape(-1, 3), "rec2020"), 0))
            row[stock] = {"argentLevel": float(np.median(l_a)), "argentWeight": float(weight(l_a).mean()),
                          "weightRatio": float(weight(l_a).mean() / row["lightroomWeight"])}
        out[job] = row
        print(f"  level {job}: Lightroom {row['lightroomLevel']:+.2f} stops, " + ", ".join(
            f"{s.replace('kodak-', '')} {row[s]['argentLevel']:+.2f} (weight x{row[s]['weightRatio']:.2f})" for s in stocks), flush=True)
    return out


def level_step():
    result = level_check(FILM_SOURCES + HELD_OUT)
    write_json("level-check.json", result)
    return result


def spearman(a, b):
    """Spearman's rank correlation of two equal-length lists (no ties expected)."""
    ra, rb = (np.argsort(np.argsort(np.asarray(x, float))) for x in (a, b))
    return float(np.corrcoef(ra, rb)[0, 1])


def on_grid(runs, frames, stock, value, m, field):
    """A clip-rule mean (bias or ratio) at strength m, interpolated linearly in log m along the kept strength grid: for
    strengths that were not rendered themselves."""
    grid, ys = grid_curve(runs, frames, stock, value, field)
    return float(np.interp(np.log(m), np.log(grid), ys))


def strength_forms(held, ins_fit):
    """Two forms of the strength, both fitted on round 1's frames and read on the held-out ones from the grid: one m
    per sign (the m+ and m- used) against one m per value (the least-ratio m at each of round 1's values; -100 and
    +50, +100 are the held-out values)."""
    out = {}
    for stock in ALL_STOCKS:
        row = {}
        for v in HELD_VALUES["vibrance"]:
            per_sign = ins_fit[stock]["m+" if v > 0 else "m-"]
            per_value = ins_fit[stock]["byValue"][str(v)]["leastRatio"]
            row[v] = {name: {"m": m, "ratio%": on_grid(held, HELD_OUT, stock, v, m, "ratio"),
                             "bias%": on_grid(held, HELD_OUT, stock, v, m, "bias")}
                      for name, m in (("per sign", per_sign), ("per value", per_value))}
        out[stock] = row
    return out


def print_heldout(s):
    f = lambda x, w=6, d=2: f"{x:{w}.{d}f}" if isinstance(x, (int, float)) and x is not None and np.isfinite(x) else " " * (w - 1) + "-"
    print("Held-out frames:", ", ".join(s["frames"]))
    print("Registration (block shift, gradient correlation):",
          ", ".join(f"{j.replace('r-photo-', '')} {r['shift']} {r['correlation']:.2f}" for j, r in s["registration"].items()))
    cols = ("ratio%", "bias%", "hueP95", "LP95", "strength", "greyC", "dE")
    print("Step 2: constants unchanged (S-A; V-A at m = 1), Portra 400 and Ektar 100, mean over runs. Columns: " + " ".join(cols)
          + ", runs, clipped blocks left out")
    for slider, vals in s["methods"].items():
        for v, row in vals.items():
            for name, m in row.items():
                if m is None:
                    continue
                print(f"  {slider[:3]} {v:+4d} {name:18s} " + " ".join(f(m.get(k)) for k in cols)
                      + f"  {m.get('runs', '-'):>3}  {m.get('leftOut', '-')}")
    print("Step 3: V-A at each stock's strength on the held-out frames (clip rule): ratio / bias / hue / L")
    for stock, rows in s["strength"].items():
        for v in HELD_VALUES["vibrance"]:
            r = rows[v]
            line = " | ".join(f"{name} {f(r[name]['ratio%'], 5, 1)} {f(r[name]['bias%'], 6, 1)} {f(r[name]['hueP95'], 4, 1)} {f(r[name]['LP95'], 4, 2)}"
                              for name in ("heldout m=1", "heldout fitted", "heldout zero-bias m", "insample fitted") if r[name])
            ask = r["heldoutWouldAsk"]
            print(f"  {stock:20s} {v:+4d} m {r['m']:.2f} | {line} | held-out would ask {f(ask['leastRatio'], 4, 2)} (zero bias {f(ask['zeroBias'], 4, 2)})")
        print(f"  {stock:20s} held-out would ask m+ {f(rows['heldoutWouldAsk+']['leastRatio'], 4, 2)}, m- {f(rows['heldoutWouldAsk-']['leastRatio'], 4, 2)}"
              f" | S-A +100 ratio {f(rows['saturation'][100]['ratio%'], 5, 1)} bias {f(rows['saturation'][100]['bias%'], 6, 1)}")
    for slider, rows in s["ranking"].items():
        print(f"Step 5: frames by +100 miss, {slider} (mean of the two stocks, clip rule): ratio, bias, hue, L, ratio inside "
              "Rec. 2020, ratio F3 protocol, clipped share, outside-Rec. 2020 share, LR chroma, LR L*")
        for job, r in rows.items():
            print(f"  {job:24s} {f(r['ratio%'], 5, 1)} {f(r['bias%'], 6, 1)} {f(r['hueP95'], 5, 1)} {f(r['LP95'], 5, 2)} "
                  f"{f(r['insideRatio%'], 5, 1)} {f(r['allRatio%'], 5, 1)} {r['clippedShare']:6.3f} {r['outsideRec2020Share']:6.3f} "
                  f"{f(r.get('chroma'), 5, 1)} {f(r.get('lightness'), 5, 1)}")
    print("One strength per sign against one per value (fitted on round 1, read on the held-out grid): ratio % / bias %")
    for stock, rows in s.get("strengthForms", {}).items():
        print(f"  {stock:20s} " + " | ".join(f"{v:+d}: " + " ".join(f"{name} m {d['m']:.2f} {d['ratio%']:.1f}/{d['bias%']:+.1f}"
                                                                for name, d in r.items()) for v, r in rows.items()))
    print("Rank correlation of a frame's +100 miss with its properties:", json.dumps(
        {k: {p: round(r, 2) for p, r in v.items()} for k, v in s["missCorrelation"].items()}))
    print("Step 6: share of pixels outside sRGB / Display P3 (below zero), Lightroom against Argent")
    keys = ("sRGBNeg", "sRGBOut", "P3Neg", "P3Out")
    agg = {}
    for job, row in s["gamut"].items():
        for name, g in row.items():
            if name in SCORE_STOCKS:
                for sub, gg in g.items():
                    agg.setdefault(f"{sub} ({name})", []).append([gg[k] for k in keys])
            else:
                agg.setdefault(name, []).append([g[k] for k in keys])
    for name, rows in agg.items():
        m = np.mean(rows, axis=0)
        print(f"  {name:45s} " + " ".join(f"{k} {x:.3f}" for k, x in zip(keys, m)))


def per_frame_tables(held, ins, strengths):
    """heldout-per-frame.md: every frame's numbers for S-A and V-A (m = 1 and the stock's strength) on Portra 400 and
    Ektar 100, clip rule, with F3's protocol's ratio beside, the in-sample frames first."""
    f = lambda x, d=1: "-" if x is None else f"{x:.{d}f}"
    lines = ["# Per-frame scores (V3)", "",
             "Clip rule unless marked. ratio: chroma-ratio error %; bias: signed, Argent minus Lightroom %; hue: p95 "
             "degrees; L: p95 L*; all: F3's protocol's ratio error; left out: chroma blocks the clip rule removed; "
             "grey: C* left at Saturation -100. '-': fewer than 1,000 chroma blocks.", ""]
    rows = [("saturation", v, "S-A", lambda st: 1.0) for v in HELD_VALUES["saturation"]]
    rows += [("vibrance", v, "V-A", lambda st: 1.0) for v in HELD_VALUES["vibrance"]]
    rows += [("vibrance", v, "V-A", lambda st, v=v: strength_of(st, v, strengths)) for v in HELD_VALUES["vibrance"]]
    for slider, v, method, m_of in rows:
        tag = "m = 1" if method == "V-A" and m_of(SCORE_STOCKS[0]) == 1.0 else ("the stock's strength" if method == "V-A" else "")
        lines += [f"## {slider.capitalize()} {v:+d} {method} {tag}".rstrip(), "",
                  "| frame | " + " | ".join(f"{st.replace('kodak-', '')} {c}" for st in SCORE_STOCKS
                                          for c in ("ratio", "bias", "hue", "L", "all", "left out", "grey")) + " |",
                  "| --- |" + " ---: |" * (7 * len(SCORE_STOCKS))]
        for group, runs in (("in", ins), ("held", held)):
            for job in (FILM_SOURCES if group == "in" else HELD_OUT):
                cells = []
                for st in SCORE_STOCKS:
                    key = variant_key((slider, v, method, m_of(st)))
                    r = runs.get(job, {}).get(st, {}).get(key)
                    if r is None or (v not in FIT_VALUES and group == "in"):
                        cells += ["."] * 7
                        continue
                    c = metrics(r)
                    a = metrics(r, "all")["ratio%"] if "all" in r else None
                    if slider == "saturation" and v == -100:
                        cells += ["", "", "", f(c["LP95"], 2), "", "", f(c["greyC"], 2)]
                        continue
                    cells += [f(c["ratio%"]), f(c["bias%"]), f(c["hueP95"]), f(c["LP95"], 2), f(a), str(c["leftOut"]), ""]
                lines.append(f"| {job}{' (in-sample)' if group == 'in' else ''} | " + " | ".join(cells) + " |")
        lines.append("")
    (OUT / "heldout-per-frame.md").write_text("\n".join(lines))


def heldout_step(argv=()):
    """The held-out scores from the kept runs (one JSON per frame and stock under runs/). With --fresh the kept runs of
    the held-out frames are moved aside first, so every print is rendered and scored again."""
    if "--fresh" in argv:
        for job in HELD_OUT:
            for path in RUNS.glob(f"{job}-*.json"):
                path.rename(path.with_suffix(".json.old"))
        pass_step(HELD_OUT, heldout_variants)
    held, ins = load_runs(HELD_OUT), load_runs(FILM_SOURCES)
    summary = heldout_summary(held, ins, fitted_strengths())
    summary["strengthForms"] = strength_forms(held, json.loads((OUT / "strength-fit.json").read_text())["fit"])
    write_json("heldout-summary.json", summary)
    per_frame_tables(held, ins, fitted_strengths())
    print_heldout(summary)
    return summary


# MARK: Pass bars for the Swift build, fixed on the held-out frames

BAR_METRICS = {("saturation", -100): ("greyC", "LP95"), ("saturation", 100): ("ratio%", "hueP95", "LP95"),
               ("vibrance", -100): ("ratio%", "hueP95", "LP95"), ("vibrance", 50): ("ratio%", "hueP95", "LP95"),
               ("vibrance", 100): ("ratio%", "hueP95", "LP95")}
BAR_FLOOR = {"ratio%": 0.5, "hueP95": 0.5, "LP95": 0.1, "greyC": 0.05}
BAR_RELATIVE = 0.05
BAR_PORT_TIMES = 3


def stage_variant(slider, value, stock, strengths):
    return (slider, value, "S-A", 1.0) if slider == "saturation" else (slider, value, "V-A", strength_of(stock, value, strengths))


def port_shift(port, slider, value, metric):
    """The mean |change| of a metric when the stage's output is rounded to half floats, over the port-checked runs."""
    key = variant_key((slider, value, "S-A", 1.0)) if slider == "saturation" else None
    shifts = []
    for runs in port.values():
        for k, r in runs.items():
            if (key and k == key) or (not key and k.startswith(f"{slider}{value:+d} V-A")):
                a, b = (metrics({"clip": r[x]}) for x in ("prototype", "half"))
                if a.get(metric) is not None and b.get(metric) is not None:
                    shifts.append(abs(a[metric] - b[metric]))
    return float(np.mean(shifts)) if shifts else 0.0


def judge(scores, bars):
    """Each bar against a build's scores: [(slider, stock, value, metric, score, bar, passed)]; a missing score fails."""
    out = []
    for slider, stocks in bars.items():
        for stock, values in stocks.items():
            for value, ms in values.items():
                for metric, b in ms.items():
                    got = scores.get(slider, {}).get(stock, {}).get(str(value), {}).get(metric)
                    out.append((slider, stock, int(value), metric, got, b["bar"], got is not None and got <= b["bar"]))
    return out


def bars_step():
    """bars.json: the held-out protocol, every bar beside the prototype's score, the margin and its basis, and whether
    the plausible slips fail."""
    strengths = fitted_strengths()
    held = load_runs(HELD_OUT)
    port = {p.stem: json.loads(p.read_text()) for p in sorted(PORT.glob("*.json"))}
    bars, slips = {}, {}
    for (slider, value), names in BAR_METRICS.items():
        for stock in ALL_STOCKS:
            proto = mean_metrics(held, HELD_OUT, [stock], lambda st: stage_variant(slider, value, st, strengths))
            row = {}
            for metric in names:
                p = proto[metric]
                shift = port_shift(port, slider, value, metric)
                margin = max(BAR_PORT_TIMES * shift, BAR_RELATIVE * abs(p), BAR_FLOOR[metric])
                row[metric] = {"bar": round(p + margin, 3), "prototype": round(p, 3), "margin": round(margin, 3),
                               "portShift": round(shift, 4), "runs": proto[f"{metric}Runs"]}
            bars.setdefault(slider, {}).setdefault(stock, {})[str(value)] = row
    slip_variants = {"S-A with Rec. 2020's luminance row": (SCORE_STOCKS, lambda sl, v, st: (sl, v, "S-A Rec. 2020 Y", 1.0), "saturation"),
                     "V-A with no strength (m = 1)": (ALL_STOCKS, lambda sl, v, st: (sl, v, "V-A", 1.0), "vibrance")}
    for name, (stocks, make, slider) in slip_variants.items():
        scores = {}
        for value in HELD_VALUES[slider]:
            for stock in stocks:
                m = mean_metrics(held, HELD_OUT, [stock], lambda st: make(slider, value, st))
                scores.setdefault(slider, {}).setdefault(stock, {})[str(value)] = {k: m[k] for k in METRIC_NAMES}
        verdict = judge(scores, {slider: {st: bars[slider][st] for st in stocks}})
        slips[name] = {"failed": [f"{st} {v:+d} {mt}: {sc:.2f} > {b:.2f}" for _, st, v, mt, sc, b, ok in verdict if not ok],
                       "bars": len(verdict)}
    reproduce = {}
    for slider in HELD_VALUES:
        d = [r["blockDE"] for runs in port.values() for k, r in runs.items() if k.startswith(slider)]
        if d:
            mean, p99 = float(np.max([x["mean"] for x in d])), float(np.max([x["p99"] for x in d]))
            reproduce[slider] = {"meanDE": round(max(BAR_PORT_TIMES * mean, 0.05), 3), "p99DE": round(max(BAR_PORT_TIMES * p99, 0.3), 3),
                                 "halfFloatMeasured": {"worstMean": mean, "worstP99": p99, "runs": len(d)}}
    out = {
        "made": time.strftime("%Y-%m-%d %H:%M"),
        "script": "scripts/lightroom-probe/fit_colour.py bars (from runs/ and port/)",
        "protocol": {
            "binary": "argent-spike, run as fit_colour.render_print does: <raw> --stock <stock> --out <tmp> --no-warmup "
                      + " ".join(map(str, FLAGS)) + " [--saturation V | --vibrance V] --print-out <tmp>/print.npy",
            "flags": list(map(str, FLAGS)),
            "frames": [{"job": j, "raw": str(source_raw(j))} for j in HELD_OUT],
            "stocks": ALL_STOCKS, "values": HELD_VALUES,
            "lightroom": "references/lightroom-probe/exports-<job>/<job>_00_base.tif and <job>_<slider>_<+value>.tif; each "
                         "render against the base of its own job",
            "score": "fit_colour.score_change on 4 x 4 blocks, clip rule ('clip'); a bar is the mean over the frames on one "
                     "stock at one value; chroma, hue and strength only from runs with at least "
                     f"{MIN_CHROMA_BLOCKS} chroma blocks",
            "stages": {"saturation": "S-A on the print: c' = max(0, Y + (1 + s)(c - Y)), Y = (0.2790187, 0.6753431, 0.0456382) . c",
                       "vibrance": "V-A on the print, F3's constants, strength m per stock and sign (strengths)"},
            "metrics": {"ratio%": "median |log2(C1/C0) - log2(C1lr/C0lr)| as percent",
                        "hueP95": "p95 |hue change - Lightroom's hue change|, degrees, blocks with C* > 10",
                        "LP95": "p95 |L* change - Lightroom's L* change|", "greyC": "mean C* of the print at -100"}},
        "margin": {"rule": f"bar = prototype + max({BAR_PORT_TIMES} x the half-float shift, {BAR_RELATIVE:.0%} of the prototype, floor)",
                   "floor": BAR_FLOOR, "halfFloatBasis": "port/: each stage's output rounded to half floats on the held-out "
                                                         "frames, Portra 400 and Ektar 100"},
        "identity": "slider 0 writes a print array equal, element for element, to the print with no flag",
        "reproduce": reproduce,
        "strengths": strengths,
        "bars": bars,
        "slips": slips,
    }
    write_json("bars.json", out)
    print("Pass bars (held-out frames, clip rule): bar (prototype) per stock")
    for slider, stocks in bars.items():
        for stock, values in stocks.items():
            print(f"  {slider[:3]} {stock:20s} " + " | ".join(
                f"{v}: " + " ".join(f"{k} {b['bar']:.2f} ({b['prototype']:.2f})" for k, b in ms.items()) for v, ms in values.items()))
    print("Reproduce bars:", json.dumps(reproduce))
    for name, d in slips.items():
        print(f"Slip '{name}': fails {len(d['failed'])} of {d['bars']} bars: " + "; ".join(d["failed"][:8]))
    return out


def validation_constants_step():
    """constants.json for the design: F3's constants as F3 left them, the placement, Vibrance's six strengths and the
    rule behind them, and what round 3's renders said about Vibrance's law and Exposure."""
    f3 = json.loads((FIT / "constants.json").read_text())
    strength = json.loads((OUT / "strength-fit.json").read_text())
    terms = json.loads((OUT / "round3-lightroom-terms.json").read_text())
    held = json.loads((OUT / "heldout-summary.json").read_text())
    rule = strength["rule"]
    best = {t: min(fits.items(), key=lambda kv: kv[1]["looRms"]) for t, fits in rule["fits"].items()}
    one = {t: {"property": "chromaRatio", **fits["chromaRatio"]} for t, fits in rule["fits"].items()}
    out = {
        "made": time.strftime("%Y-%m-%d %H:%M"),
        "script": "scripts/lightroom-probe/fit_colour.py (V3, from F3's)",
        "rerun": ".venv/bin/python -I scripts/lightroom-probe/fit_colour.py validate",
        "f3": {k: f3[k] for k in ("saturation", "vibrance", "toneCurve", "composition")},
        "f3Note": "F3's constants, unchanged (fit/colour/constants.json, 2026-11-11 11:41). F3's saturation 'method' line "
                  "says 'on the scene'; F3's report and the coordinator place both stages on the print.",
        "placement": "both stages on the print array (display-linear Rec. 2020), after the film and Auto's balance; "
                     "Vibrance after Saturation",
        "vibranceStrength": {
            "definition": "strengthen(): the positive gain's departure from 1 times m (F3's a1 and a2 times m); the negative "
                          "side's c over m (what -100 leaves)",
            "fittedOn": strength["frames"], "grid": strength["grid"],
            "criterion": "m+ and m-: the m minimising the mean clip-rule chroma-ratio error of round 1's frames at +50 and "
                         "+100, and at -50 and -100. zeroBias: where the mean chroma bias crosses zero (None: not reached)",
            "perStock": {s: {"+": r["m+"], "-": r["m-"], "zeroBias+": r["zeroBias+"], "zeroBias-": r["zeroBias-"],
                             "spreadAcrossFrames": {"+": r["m+Spread"], "-": r["m-Spread"]},
                             "byValue": {v: {k: d[k] for k in ("leastRatio", "zeroBias", "biasAtM1")} for v, d in r["byValue"].items()}}
                         for s, r in strength["fit"].items()},
            "carried": held["strengths"],
            "rule": {"property": "chromaRatio: the median over 4 x 4 blocks of Argent's base-print C* over Lightroom's base C* "
                                 "(L* 3 to 97, C* above 5, nothing clipped), averaged over round 1's five frames",
                     "m = slope * chromaRatio + intercept": one,
                     "why one property": "it predicts both signs; the best property per sign (bestPerSign) does no better "
                                         "than the six stocks can tell"},
            "bestPerSign": {t: {"property": p, **d} for t, (p, d) in best.items()},
            "ruleCandidates": rule,
            "heldOutWouldAsk": {s: {k: v for k, v in rows.items() if k.startswith("heldoutWouldAsk")}
                                for s, rows in held["strength"].items()},
        },
        "vibranceBetweenKnots": terms["betweenKnots"],
        "exposure": terms["exposure"],
        "passBars": "bars.json",
    }
    write_json("constants.json", out)
    return out


def validate_step(argv):
    """Every V3 step in order; each pass keeps its runs, so a second call renders nothing."""
    reproduce_step()
    lightroom_terms_step()
    pass_step(FILM_SOURCES, fit_variants, part=part_of(argv))
    strength_step()
    pass_step(FILM_SOURCES, insample_variants, part=part_of(argv))
    pass_step(HELD_OUT, heldout_variants, part=part_of(argv))
    P, strengths = vibrance_constants()["hsv"]["constants"], fitted_strengths()
    for job in HELD_OUT:
        for stock in SCORE_STOCKS:
            port_check(job, stock, P, strengths)
    level_step()
    heldout_step()
    bars_step()
    validation_constants_step()


# MARK: Scoring a Swift build (argent-spike with --saturation and --vibrance)

def spike_flags(binary):
    """The slider flags a spike binary lists in its --help."""
    text = subprocess.run([str(binary), "--help"], capture_output=True, text=True).stdout
    return {s for s in HELD_VALUES if f"--{s} " in text or f"--{s}\n" in text}


def score_build(binary, sliders, frames=HELD_OUT, stocks=ALL_STOCKS):
    """Renders every frame with the build's own stage (--saturation V or --vibrance V) in place of the Python one and
    scores it as the bars were made: per slider, stock and value the clip-rule means over the frames; the block dE76
    between the build's print and the prototype's (the Python stage on the build's own base print); and whether
    slider 0 leaves the print unchanged."""
    P, strengths = vibrance_constants()["hsv"]["constants"], fitted_strengths()
    runs, reproduce, identity = {}, {s: [] for s in sliders}, {s: [] for s in sliders}
    for job in frames:
        lr = {}

        def get(name):
            if name not in lr:
                lr[name] = lightroom_blocks(job, name)
            return lr[name]
        for stock in stocks:
            p = render_print(job, stock, binary=binary)
            base = staged_stats(p, [], P, base=True)["base"]
            for slider in sliders:
                zero = render_print(job, stock, binary=binary, extra=(f"--{slider}", 0))
                identity[slider].append(bool(np.array_equal(zero, p)))
                del zero
                for value in HELD_VALUES[slider]:
                    built = render_print(job, stock, binary=binary, extra=(f"--{slider}", value))
                    res = staged_stats(built, [], P, base=True)["base"]
                    del built
                    proto = staged_stats(p, [stage_variant(slider, value, stock, strengths)], P)
                    a, b = lab_of_xyz(res["xyz"]), lab_of_xyz(next(iter(proto.values()))["xyz"])
                    d = np.linalg.norm(a - b, axis=-1)
                    reproduce[slider].append({"mean": float(d.mean()), "p99": float(np.percentile(d, 99))})
                    runs.setdefault(job, {}).setdefault(stock, {})[variant_key((slider, value, "build", 1.0))] = \
                        score_change(get("00_base"), get(lr_name(slider, value)), base, res)
            del p
            print(f"  {job} {stock} scored", flush=True)
    scores = {s: {st: {str(v): {k: x for k, x in mean_metrics(runs, frames, [st], lambda _: (s, v, "build", 1.0)).items()
                                 if k in METRIC_NAMES}
                       for v in HELD_VALUES[s]} for st in stocks} for s in sliders}
    return scores, reproduce, identity


def spike_bars_step(argv):
    """Step 8: python -I fit_colour.py spike-bars --binary PATH [--slider saturation|vibrance]. Prints every bar with
    the build's score and PASS or FAIL, and exits 1 on any failure. Stops at once if the binary lacks a slider's flag."""
    binary = Path(argv[argv.index("--binary") + 1]) if "--binary" in argv else SPIKE
    sliders = [argv[argv.index("--slider") + 1]] if "--slider" in argv else list(HELD_VALUES)
    missing = [s for s in sliders if s not in spike_flags(binary)]
    if missing:
        raise SystemExit(f"{binary} has no {' or '.join('--' + s for s in missing)} flag: its --help does not list it. "
                         "The scorer renders each frame with that flag in place of the Python stage, so it needs a build "
                         "of argent-spike that applies the stage on the print. Nothing was rendered.")
    bars = json.loads((OUT / "bars.json").read_text())
    scores, reproduce, identity = score_build(binary, sliders)
    verdict = judge(scores, {s: bars["bars"][s] for s in sliders})
    failed = 0
    for slider, stock, value, metric, got, bar, ok in verdict:
        failed += not ok
        print(f"  {'PASS' if ok else 'FAIL'} {slider:10s} {stock:20s} {value:+4d} {metric:7s} "
              f"{'-' if got is None else f'{got:.3f}'} <= {bar:.3f}")
    for slider in sliders:
        worst = max(reproduce[slider], key=lambda d: d["mean"])
        bar = bars["reproduce"][slider]
        ok = all(d["mean"] <= bar["meanDE"] and d["p99"] <= bar["p99DE"] for d in reproduce[slider])
        failed += not ok
        print(f"  {'PASS' if ok else 'FAIL'} {slider:10s} reproduces the prototype: worst block dE mean {worst['mean']:.3f} "
              f"<= {bar['meanDE']}, p99 {max(d['p99'] for d in reproduce[slider]):.3f} <= {bar['p99DE']}")
        ok = all(identity[slider])
        failed += not ok
        print(f"  {'PASS' if ok else 'FAIL'} {slider:10s} at 0 leaves the print unchanged on {sum(identity[slider])} of {len(identity[slider])} runs")
    print(f"{failed} failed")
    if failed:
        raise SystemExit(1)


def part_of(argv):
    """`--part i/n` runs every n-th frame from the i-th, so n processes share a pass without sharing a file."""
    for a in argv:
        if a.startswith("--part"):
            i, n = a.split("=", 1)[1].split("/")
            return int(i), int(n)
    return 0, 1


def pass_step(frames, variants_for, stocks=ALL_STOCKS, part=(0, 1)):
    P = vibrance_constants()["hsv"]["constants"]
    i, n = part
    for job in frames[i::n]:
        lr = {}
        for stock in stocks:
            frame_runs(job, stock, variants_for(stock), P, lr=lr, full=full_for(stock))


def main(argv):
    step = argv[1] if len(argv) > 1 else "all"
    t = time.time()
    np.set_printoptions(precision=4, suppress=True, linewidth=160)
    if step in ("tables", "all"):
        for which in GRIDS:
            meta, renders = grid_table(which, refresh=True)
            print(f"{which}: {len(meta['group'])} patches, {len(renders)} renders")
        meta, renders = combo_table(refresh=True)
        print(f"combo: {len(meta['h'])} patches, {len(renders)} renders")
    if step in ("saturation", "all"):
        saturation_step()
    if step in ("saturation-film", "film", "all"):
        saturation_film(quick="--quick" in argv)
    if step in ("vibrance", "all"):
        vibrance_step()
    if step in ("vibrance-film", "film", "all"):
        vibrance_film(quick="--quick" in argv)
    if step in ("extras", "film", "all"):
        film_extras_step()
    if step in ("mapping", "film", "all"):
        mapping_step()
    if step in ("constants", "all"):
        constants_step()
    if step == "reproduce":
        reproduce_step()
    if step == "lightroom-terms":
        lightroom_terms_step()
    if step == "strength":
        strength_step()
    if step == "fit-pass":
        pass_step(FILM_SOURCES, fit_variants, part=part_of(argv))
    if step == "heldout":
        heldout_step(argv)
    if step == "bars":
        bars_step()
    if step == "level":
        level_step()
    if step == "constants-v3":
        validation_constants_step()
    if step == "validate":
        validate_step(argv)
    if step == "spike-bars":
        spike_bars_step(argv)
    if step == "port-pass":
        P, strengths = vibrance_constants()["hsv"]["constants"], fitted_strengths()
        i, n = part_of(argv)
        for job in HELD_OUT[i::n]:
            for stock in SCORE_STOCKS:
                port_check(job, stock, P, strengths)
    if step == "heldout-pass":
        pass_step(HELD_OUT, heldout_variants, part=part_of(argv))
    if step == "insample-pass":
        pass_step(FILM_SOURCES, insample_variants, part=part_of(argv))
    print(f"{step} done in {time.time() - t:.0f} s")


if __name__ == "__main__":
    main(sys.argv)
