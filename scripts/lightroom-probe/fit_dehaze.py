"""Dehaze: what Lightroom Classic's slider does, measured on the Presence probe's renders, and candidate stages
for Argent scored against it, in Lightroom's terms and through Argent's film.

    python -I scripts/lightroom-probe/fit_dehaze.py COMMAND

    measure   the chart measurements (M1 to M4)
    fit       the candidates' constants, fitted on the probe raw and the photographs in Lightroom's terms
    photos    the fitted candidates in Lightroom's terms on photographs and charts; M5, M6, noise and skies
    film      every candidate through Argent's film on both stocks, with the floor
    negative  the negative side's alternative laws, in Lightroom's terms and through the film
    auto      what --auto's tone step would add to the change through --scene-in (fit-common fact 2)
    scale     the stage at a quarter-size decode against full size
    calibrate a per-stock multiplier on the slider law, fitted through the film on two sources
    report    the film tables of report.md, printed from film.json

    held-out  V2: F2's constants on round 3's twenty held-out photographs through the film, both protocols, the floor
    in-sample V2: the same scorer on F2's five film sources, at the held-out values
    answers   V2: round 3's answers to F2's requests: the law at every value on the neutral chart, the white patch,
              the crop, and the sky's profile share
    law       V2: F2's slider table against one smooth law between the knots, on the chart and the probe raw
    summary   V2: the held-out scores beside the in-sample ones, the verdict, the ranking and the protocol gap
    airlights V2: the airlight Lightroom implies on each photograph against the field's rule
    airlight-screen  V2: step 4's fit of a brighter airlight on round 1's raws and half A, in Lightroom's terms
    variant   V2: one of VARIANTS (--name) through the film on half B (or --frames), against F2's constants
    bar       V2: bars.json, the pass bar for the app's automatic print, from held-out.json
    spike     V2: score an argent-spike that has --dehaze against bars.json; prints pass or fail (exit 1 on a fail)
    spike-check  V2: `spike` run on a stand-in spike (today's spike with this prototype's stage behind --dehaze, see
              emulate_spike), on one frame (or --frames) with parity and identity: every bar must pass
    stability    F2's stability bar on an argent-spike that has --dehaze: a quarter-size render with its own field
              against the prototype's with the full frame's field (exit 1 on a fail)
    stability-check  `stability` run on the same stand-in spike: it must reproduce `scale_check`'s estimate

Each command writes its JSON under the evidence folder (EVIDENCE below; VALIDATION for V2's) and prints what the report
quotes. `fit` writes constants.json, which `photos`, `film` and `scale` read.

The data shapes. A Lightroom export is linear ProPhoto RGB (D50), read by `lightroom()`. A chart's input and Argent's
scene are linear Rec. 2020 (D65), middle grey 0.18. A candidate is a `Field`, made once per frame from the untouched
frame (the airlight A and the transmission's coefficient grids), and `dehaze(scene, value, field, constants)`, the
per-pixel step a slider move recomputes: O = A + (I - A) G(t, value).
"""
import argparse
import json
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field as dc_field, asdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import presence_charts  # noqa: E402
import presence_stats  # noqa: E402
import probe  # noqa: E402
import scene_io  # noqa: E402

MAIN = Path("/Users/cyr1en/Developer/Argent")
DATA = MAIN / "references" / "lightroom-probe"
SPIKE = MAIN / ".build" / "release" / "argent-spike"
STOCKS = MAIN / "build" / "stocks"
EVIDENCE = Path("/Users/cyr1en/Documents/ArgentResearch/presence-20261111.noindex/fit/dehaze")
VALIDATION = EVIDENCE.parent.parent / "validate" / "dehaze"
MANIFEST = EVIDENCE.parent.parent / "probe" / "manifest.json"
ROUND3 = EVIDENCE.parent.parent / "probe" / "round3" / "manifest.json"

Y2020 = np.array([0.2627, 0.6780, 0.0593])
PROPHOTO_XYZ = presence_stats.PROPHOTO_XYZ
REC2020_TO_PROPHOTO = np.linalg.inv(PROPHOTO_XYZ) @ scene_io.REC2020_TO_XYZ_D50
SRGB_TO_XYZ = np.array([[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750],
                        [0.0193339, 0.1191920, 0.9503041]])
SRGB_TO_REC2020 = np.linalg.inv(presence_charts.REC2020_TO_XYZ) @ SRGB_TO_XYZ
D50 = np.array([0.96422, 1.0, 0.82521])
CHART_VALUES = [-100, -50, -25, 25, 50, 100]
RAW_VALUES = [-100, -75, -50, -25, -10, 10, 25, 50, 75, 100]
PHOTO_VALUES = [-100, -50, 50, 100]


# MARK: Colour

def lab_xyz(xyz):
    """CIELAB (D50) of XYZ with white Y = 1."""
    xyz = np.asarray(xyz, dtype=np.float64) / D50
    f = np.where(xyz > (6 / 29) ** 3, np.cbrt(np.maximum(xyz, 0)), xyz / (3 * (6 / 29) ** 2) + 4 / 29)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], axis=-1)


def lab_prophoto(rgb):
    return lab_xyz(np.asarray(rgb, dtype=np.float64) @ PROPHOTO_XYZ.T)


def blocks(a, k=probe.BLOCK):
    """k x k means of an (h, w, ...) array, in linear light."""
    h, w = a.shape[0] // k * k, a.shape[1] // k * k
    return a[:h, :w].reshape(h // k, k, w // k, k, *a.shape[2:]).mean(axis=(1, 3))


# MARK: Lightroom's renders

def export_path(job, name):
    return DATA / f"exports-{job}" / f"{job}_{name}.tif"


def value_name(value):
    return "00_base" if value == 0 else f"dehaze_{value:+d}"


def lightroom(job, value=0, name=None):
    """A Lightroom export as linear ProPhoto RGB (D50), float32."""
    return presence_stats.linear(export_path(job, name or value_name(value)))[0]


class ToneModel:
    """Lightroom's render of a DNG chart after the develop settings: its raw tone curve f, measured on the base render
    of p-dehaze-flat's neutral ramp, applied to the largest and smallest channel and the middle one interpolated between
    them (hue preserving). Its inverse undoes a render pixel by pixel. On p-haze-none's base the forward model is
    within a median Delta E of 0.53 (measured)."""

    SHOULDER = 0.14

    def __init__(self):
        chart = presence_charts.CHARTS["p-dehaze-flat"]()
        ramp_in = (chart.img[20:380].astype(np.float64) @ REC2020_TO_PROPHOTO.T).mean(axis=(0, 2))
        ramp_out = lightroom("p-dehaze-flat")[20:380].astype(np.float64).mean(axis=(0, 2))
        ok = ramp_out > 2e-4
        self.xi, xo = np.log(ramp_in[ok]), np.log(ramp_out[ok])
        self.xo = np.maximum.accumulate(xo + np.arange(len(xo)) * 1e-12)

    def curve(self, v):
        lv = np.log(np.maximum(v, 1e-12))
        out = np.interp(lv, self.xi, self.xo, left=-60.0)
        return np.exp(np.where(lv > self.xi[-1], self.xo[-1] + (lv - self.xi[-1]) * self.SHOULDER, out))

    def inverse_curve(self, v):
        lv = np.log(np.maximum(v, 1e-12))
        out = np.interp(lv, self.xo, self.xi, left=-60.0)
        return np.exp(np.where(lv > self.xo[-1], self.xi[-1] + (lv - self.xo[-1]) / self.SHOULDER, out))

    def _apply(self, rgb, fn):
        rgb = np.maximum(np.asarray(rgb, dtype=np.float64), 0)
        hi, lo = rgb.max(-1, keepdims=True), rgb.min(-1, keepdims=True)
        share = np.where(hi > lo, (rgb - lo) / np.maximum(hi - lo, 1e-15), 0)
        f_hi, f_lo = fn(hi), fn(lo)
        return f_lo + (f_hi - f_lo) * share

    def render(self, linear_prophoto):
        return self._apply(linear_prophoto, self.curve)

    def unrender(self, export):
        return self._apply(export, self.inverse_curve)


_TONE = None


def tone():
    global _TONE
    if _TONE is None:
        _TONE = ToneModel()
    return _TONE


def chart_input(name):
    """A chart's input as linear Rec. 2020 (D65), as Argent's scene would hold it."""
    chart = presence_charts.CHARTS[name]()
    img = chart.img.astype(np.float64)
    if chart.primaries == "sRGB":
        img = img @ SRGB_TO_REC2020.T
    return img, chart


# MARK: The candidates

def area_down(img, long_side):
    """Exact area averaging of an (h, w, c) array to `long_side` on its longer side, as ToneBaseField's guide pass."""
    h, w = img.shape[:2]
    n = min(long_side, max(h, w))
    fw, fh = (n, probe.rounded(h * n / w)) if w >= h else (probe.rounded(w * n / h), n)
    rows = probe.area_matrix(h, fh).astype(np.float32)
    cols = probe.area_matrix(w, fw).astype(np.float32)
    return np.stack([rows @ np.ascontiguousarray(img[..., c], dtype=np.float32) @ cols.T for c in range(img.shape[2])],
                    axis=-1).astype(np.float64)


def _running(x, r, fn):
    """`fn` (np.minimum or np.maximum) over a (2r+1)-square window, edges clamped."""
    for axis in (0, 1):
        n = x.shape[axis]
        p = np.take(x, np.clip(np.arange(-r, n + r), 0, n - 1), axis=axis)
        out = np.take(p, np.arange(n), axis=axis)
        for k in range(1, 2 * r + 1):
            out = fn(out, np.take(p, np.arange(k, k + n), axis=axis))
        x = out
    return x


def erode(x, r):
    return _running(x, r, np.minimum) if r > 0 else x


def dilate(x, r):
    return _running(x, r, np.maximum) if r > 0 else x


def sample_at(grid, shape, step=1, rows=None):
    """A field-size grid read bilinearly at the pixels of a frame of `shape` taken every `step` from step // 2, at
    uv = (p + 0.5) / size, as the GPU samples it (step 1 is every pixel); `rows` (y0, y1) limits it to those rows."""
    fh, fw = grid.shape

    def coords(n, fn, span=None):
        p = np.arange(step // 2, n, step) if span is None else np.arange(*span)
        t = np.clip((p + 0.5) / n * fn - 0.5, 0, fn - 1)
        i = np.minimum(np.floor(t).astype(int), fn - 2)
        return i, t - i

    y0, fy = coords(shape[0], fh, rows)
    x0, fx = coords(shape[1], fw)
    top = grid[y0][:, x0] * (1 - fx) + grid[y0][:, x0 + 1] * fx
    bottom = grid[y0 + 1][:, x0] * (1 - fx) + grid[y0 + 1][:, x0 + 1] * fx
    return top * (1 - fy)[:, None] + bottom * fy[:, None]


@dataclass
class Constants:
    """Every constant of the stage. Radii are shares of the field's long side; epsilon is in stops squared."""
    method: str = "dark-channel"   # or "global-veil"
    long_side: int = 1024
    omega: float = 0.95
    airlight_radius: float = 0.012
    airlight_quantile: float = 0.999
    airlight_bright: float = 0.0    # keep only the brightest (1 - this) of the chosen pixels before the median
    airlight_gain: float = 1.0      # the chosen colour times this (Lightroom's own is often brighter on photographs)
    dark_radius: float = 0.012
    opening: bool = True
    guide_radius: float = 0.03
    epsilon: float = 0.5
    veil_quantile: float = 0.01
    t_min: float = 0.05
    fade: bool = True
    # Positive values: G = t^-kappa(v) ("beer-lambert") or 1 / (1 - kappa (1 - t)) ("linear-t"), kappa linear between
    # the knots.
    positive_law: str = "beer-lambert"
    # Negative values: "crossfade", G = 1 - s(v) (1 - t^c(v)); "power", the same law with the sign turned,
    # G = t^s(v); "mirror", the positive result reflected about the input, G = 2 - t^-s(v).
    negative_law: str = "crossfade"
    # Where negative values pull toward A: "linear" light, or "gamma", values encoded as (I / A)^(1 / 2.2) (on the haze
    # charts Lightroom's negative map is affine with R² 0.999 there, against 0.9955 in linear light, at -50).
    negative_space: str = "linear"
    kappa_values: list = dc_field(default_factory=lambda: [0, 25, 50, 100])
    kappa: list = dc_field(default_factory=lambda: [0, 0.3, 0.55, 1.0])
    haze_values: list = dc_field(default_factory=lambda: [0, 25, 50, 100])
    haze_share: list = dc_field(default_factory=lambda: [0, 0.25, 0.5, 1.0])
    haze_power: list = dc_field(default_factory=lambda: [2.0, 2.0, 2.3, 4.0])

    def gain(self, t, value):
        """G for transmission `t` at slider `value` (-100 to 100)."""
        if value > 0:
            k = np.interp(value, self.kappa_values, self.kappa)
            return t ** (-k) if self.positive_law == "beer-lambert" else 1 / np.maximum(1 - k * (1 - t), 1e-3)
        s = np.interp(-value, self.haze_values, self.haze_share)
        if self.negative_law == "power":
            return t ** s
        if self.negative_law == "mirror":
            return 2 - t ** (-s)
        c = np.interp(-value, self.haze_values, self.haze_power)
        return 1 - s * (1 - t ** c)


class Field:
    """What the stage makes once per frame from the untouched frame: the airlight colour A, and the transmission's
    coefficient grids (a, b) at field size, so t = a g + b at any pixel, g the pixel's own log2 luminance. For the
    global veil the grids are constant: a = 0 and b the frame's one transmission."""

    def __init__(self, scene, c: Constants, F=None):
        F = area_down(scene, c.long_side) if F is None else F
        n = max(F.shape[:2])
        self.shape = F.shape[:2]
        r_a = max(0, probe.rounded(c.airlight_radius * n))
        dark0 = erode(F.min(-1), r_a)
        chosen = F[dark0 >= np.quantile(dark0, c.airlight_quantile)]
        if c.airlight_bright > 0:
            y = chosen @ Y2020
            chosen = chosen[y >= np.quantile(y, c.airlight_bright)]
        self.A = np.maximum(np.median(chosen, axis=0), 1e-4) * c.airlight_gain
        normalised = (F / self.A).min(-1)
        if c.method == "global-veil":
            t = 1 - c.omega * np.quantile(normalised, c.veil_quantile)
            self.a, self.b = np.zeros(self.shape), np.full(self.shape, t)
            return
        r_d = max(0, probe.rounded(c.dark_radius * n))
        dark = erode(normalised, r_d)
        if c.opening:
            dark = dilate(dark, r_d)
        t_raw = 1 - c.omega * dark
        g = np.log2(np.maximum(F @ Y2020, 1e-6))
        r_g = max(1, probe.rounded(c.guide_radius * n))
        mu_g, mu_t = probe.box(g, r_g), probe.box(t_raw, r_g)
        var = np.maximum(probe.box(g * g, r_g) - mu_g ** 2, 0)
        a = (probe.box(g * t_raw, r_g) - mu_g * mu_t) / (var + c.epsilon)
        b = mu_t - a * mu_g
        r_c = max(1, probe.rounded(r_g / 2))
        self.a, self.b = probe.box(a, r_c), probe.box(b, r_c)

    def transmission(self, scene, c: Constants, frame_shape=None, step=1, rows=None):
        """t at every pixel of `scene`, which may be the frame of `frame_shape` read every `step` pixels from
        step // 2, or its rows `rows` (the grids are then read where those pixels sit in the frame)."""
        g = np.log2(np.maximum(scene @ Y2020, 1e-6))
        shape = frame_shape or scene.shape[:2]
        return np.clip(sample_at(self.a, shape, step, rows) * g + sample_at(self.b, shape, step, rows), c.t_min, 1.0)


def dehaze(scene, value, fld: Field, c: Constants, t=None):
    """The per-pixel step: O = A + (I - A) G. Slider 0 returns the scene itself (the stage is bypassed)."""
    if value == 0:
        return scene
    t = fld.transmission(scene, c) if t is None else t
    G = c.gain(t, value)
    if value > 0 and c.fade:
        # Light brighter than the airlight (sun, specular light, the airlight's own patch) is not haze.
        ratio = (scene @ Y2020) / (fld.A @ Y2020)
        G = 1 + (G - 1) * np.clip(2 - ratio, 0, 1)
    if value < 0 and c.negative_space == "gamma":
        encoded = np.maximum(scene / fld.A, 0) ** (1 / 2.2)
        return fld.A * np.maximum(1 + (encoded - 1) * G[..., None], 0) ** 2.2
    return fld.A + (scene - fld.A) * G[..., None]


# MARK: Argent's render

class NegativeLUT:
    """A stock's Negative LUT read from its .cube (red fastest), sampled tetrahedrally as LUT3D.sample does."""

    def __init__(self, stock):
        meta = json.loads((stock / "stock.json").read_text())
        rows = [line.split() for line in (stock / meta["negative"]["file"]).read_text().splitlines()]
        values = np.array([[float(x) for x in r] for r in rows if len(r) == 3 and r[0][0] in "0123456789-."])
        self.n = meta["negative"]["size"]
        self.values = values.reshape(self.n, self.n, self.n, 3)  # [b][g][r]
        enc = meta["negative"]["logEncoding"]
        self.below, self.range, self.mid = enc["stopsBelowMidGray"], enc["stopsBelowMidGray"] + enc["stopsAboveMidGray"], enc["midGray"]
        self.per_unit = np.array(meta["print"]["exposurePerUnit"])
        self.density_range = meta["densityRange"]

    def encode(self, linear):
        return np.clip((np.log2(np.maximum(linear, 1e-6) / self.mid) + self.below) / self.range, 0, 1)

    def sample(self, e):
        n = self.n
        p = np.clip(e, 0, 1) * (n - 1)
        i0 = np.clip(p.astype(int), 0, n - 2)
        f = p - i0
        c = lambda dx, dy, dz: self.values[i0[2] + dz, i0[1] + dy, i0[0] + dx]  # noqa: E731
        fx, fy, fz = f
        if fx > fy:
            if fy > fz:
                return (1 - fx) * c(0, 0, 0) + (fx - fy) * c(1, 0, 0) + (fy - fz) * c(1, 1, 0) + fz * c(1, 1, 1)
            if fx > fz:
                return (1 - fx) * c(0, 0, 0) + (fx - fz) * c(1, 0, 0) + (fz - fy) * c(1, 0, 1) + fy * c(1, 1, 1)
            return (1 - fz) * c(0, 0, 0) + (fz - fx) * c(0, 0, 1) + (fx - fy) * c(1, 0, 1) + fy * c(1, 1, 1)
        if fz > fy:
            return (1 - fz) * c(0, 0, 0) + (fz - fy) * c(0, 0, 1) + (fy - fx) * c(0, 1, 1) + fx * c(1, 1, 1)
        if fz > fx:
            return (1 - fy) * c(0, 0, 0) + (fy - fz) * c(0, 1, 0) + (fz - fx) * c(0, 1, 1) + fx * c(1, 1, 1)
        return (1 - fy) * c(0, 0, 0) + (fy - fx) * c(0, 1, 0) + (fx - fz) * c(1, 1, 0) + fz * c(1, 1, 1)

    def gray_compensation(self, stops):
        """RollControls.grayCompensation: the print exposure per channel that brings a gray exposed `stops` off a metered
        mid-gray back to a neutral mid-gray's dye amounts at box speed."""
        stops = np.asarray(stops, dtype=np.float64)
        if not stops.any():
            return np.zeros(3)
        at_box = self.sample(np.full(3, self.encode(self.mid)))
        shifted = self.sample(self.encode(self.mid * np.exp2(stops)))
        return -(shifted - at_box) * self.per_unit * self.density_range / np.log10(2.0)


def auto_balance_correction(cast):
    """AutoBalance.correction: 0.7 of the cast within 60 mired either way, green against magenta half that."""
    limit = 60 * 1.24 / 130
    red_blue, green_magenta = cast[0] - cast[2], cast[1] - (cast[0] + cast[2]) / 2
    rb = np.clip(0.7 * red_blue, -limit, limit)
    gm = np.clip(0.7 * green_magenta, -limit / 2, limit / 2)
    return np.array([rb / 2 - gm / 3, 2 * gm / 3, -rb / 2 - gm / 3])


def aim_flags(raw, stock, binary=SPIKE):
    """The spike's flags that print `raw` as `--auto` does, without Auto's tone step: the aim's level as the manual
    reference and the lab balance RollControls derives from the aim (box speed). Auto's tone step reads its base from
    the scene it is given, so it would read a dehazed scene's base through --scene-in, which the app's stage would not
    (fit-common fact 2); leaving the step out keeps that out of the scores."""
    with tempfile.TemporaryDirectory() as out:
        text = probe.spike(raw, out, stock, "--auto", "--scale", 0.25, "--tiff", "--no-lens", binary=binary)
    line = next(l for l in text.splitlines() if "auto:" in l and "aim level" in l)
    level = float(line.split("aim level")[1].split("stops")[0])
    cast = np.array([float(x) for x in line.split("cast")[1].strip().split(",")])
    balance = NegativeLUT(stock).gray_compensation(level + auto_balance_correction(cast))
    return ["--lab-balance", ",".join(f"{x:.6f}" for x in balance), "--reference-stops", f"{level:.6f}"], level, cast


# MARK: Lightroom's terms on the charts

STEP = 4


class ChartCase:
    """A chart in Lightroom's terms: its input read every STEP pixels, the tone model's render of it, and Lightroom's
    change from its own base at each value, in CIELAB. A candidate's change is its output rendered by the same tone
    model less the input rendered by it, so the model's own error (median Delta E 0.13 on p-haze-neutral's base)
    mostly cancels."""

    def __init__(self, name, values=CHART_VALUES, job=None):
        """`job` reads Lightroom's renders of chart `name` from another job (round 3's r-haze-neutral)."""
        img, _ = chart_input(name)
        job = job or name
        self.name, self.shape = job, img.shape[:2]
        self.downsampled = {}
        self.img = img
        self.I = img[STEP // 2::STEP, STEP // 2::STEP]
        self.base = lab_prophoto(tone().render(self.I @ REC2020_TO_PROPHOTO.T))
        lr0 = lab_prophoto(lightroom(job)[STEP // 2::STEP, STEP // 2::STEP])
        self.change = {v: lab_prophoto(lightroom(job, v)[STEP // 2::STEP, STEP // 2::STEP]) - lr0 for v in values}

    def field(self, c):
        """The candidate's field; the chart's area-averaged downsample is kept between calls."""
        if c.long_side not in self.downsampled:
            self.downsampled[c.long_side] = area_down(self.img, c.long_side)
        return Field(self.img, c, F=self.downsampled[c.long_side])

    def candidate_change(self, c, value, fld=None, t=None):
        fld = fld or self.field(c)
        if t is None:
            t = fld.transmission(self.I, c, self.shape, STEP)
        out = dehaze(self.I, value, fld, c, t=t)
        return lab_prophoto(tone().render(out @ REC2020_TO_PROPHOTO.T)) - self.base

    def error(self, c, value, fld=None, t=None):
        """Mean CIE76 distance between the candidate's change and Lightroom's, over the chart's sampled pixels."""
        return float(np.linalg.norm(self.candidate_change(c, value, fld, t) - self.change[value], axis=-1).mean())


def golden(fn, lo, hi, tol=0.01):
    """The minimum of a unimodal `fn` on [lo, hi]."""
    r = (5 ** 0.5 - 1) / 2
    a, b = lo, hi
    c, d = b - r * (b - a), a + r * (b - a)
    fc, fd = fn(c), fn(d)
    while b - a > tol:
        if fc < fd:
            b, d, fd = d, c, fc
            c = b - r * (b - a)
            fc = fn(c)
        else:
            a, c, fc = c, d, fd
            d = a + r * (b - a)
            fd = fn(d)
    return (a + b) / 2


def fit_law(cases, c, values, log=print):
    """With the field's constants fixed, the slider's law at each value, fitted on every case that has a render at
    that value (mean change error over those cases): kappa for positive values, and for negative ones the parameters of
    `c.negative_law` (crossfade: share and power; power and mirror: one exponent). Returns {value: fit}."""
    fields = {id(k): k.field(c) for k in cases}
    fits = {}
    for value in values:
        group = [k for k in cases if value in k.change]
        trial = Constants(**asdict(c))

        def total(trial=trial, group=group, value=value):
            return float(np.mean([k.error(trial, value, fields[id(k)]) for k in group]))

        if value > 0:
            def at(x):
                trial.kappa_values, trial.kappa = [0, 100], [0, x * 100 / value]
                return total()
            x = golden(at, 0.02, 2.0)
            fits[value] = {"kappa": x, "error": at(x), "cases": [k.name for k in group]}
        elif c.negative_law in ("power", "mirror"):
            def at(x):
                trial.haze_values, trial.haze_share = [0, 100], [0, x * 100 / -value]
                return total()
            x = golden(at, 0.02, 8.0 if c.negative_law == "power" else 2.0)
            fits[value] = {"share": x, "error": at(x), "cases": [k.name for k in group]}
        else:
            def at(share, power):
                trial.haze_values, trial.haze_share, trial.haze_power = [0, 100], [0, share * 100 / -value], [power, power]
                return total()
            best = min(((golden(lambda s, p=p: at(s, p), 0.02, 1.0, tol=0.02), p) for p in (1, 2, 4, 8)),
                       key=lambda sp: at(*sp))
            share, power = best
            for _ in range(2):
                power = golden(lambda p: at(share, p), max(0.25, power / 2), power * 2, tol=0.05)
                share = golden(lambda s: at(s, power), 0.02, 1.0)
            fits[value] = {"share": share, "power": power, "error": at(share, power), "cases": [k.name for k in group]}
        log(f"  {c.method} {c.negative_law if value < 0 else c.positive_law} {value:+d}: "
            + " ".join(f"{k} {v:.3f}" for k, v in fits[value].items() if k != "cases"))
    return fits


def with_law(c, fits):
    """Constants whose slider tables are the per-value fits."""
    out = Constants(**asdict(c))
    pos = sorted(v for v in fits if v > 0)
    neg = sorted(-v for v in fits if v < 0)
    if pos:
        out.kappa_values, out.kappa = [0] + pos, [0.0] + [fits[v]["kappa"] for v in pos]
    if neg:
        out.haze_values = [0] + neg
        out.haze_share = [0.0] + [fits[-v]["share"] for v in neg]
        if c.negative_law == "crossfade":
            out.haze_power = [fits[-neg[0]]["power"]] + [fits[-v]["power"] for v in neg]
    return out


def dehaze_frame(scene, value, fld: Field, c: Constants, k=1, tile=512):
    """`dehaze` over a whole frame in bands of `tile` rows, so a 33 MP frame never holds more than a band of
    temporaries; with k > 1 it returns the k x k block means of the result instead."""
    h = scene.shape[0] // k * k if k > 1 else scene.shape[0]
    out = [] if k > 1 else np.empty(scene.shape, np.float32)
    for y0 in range(0, h, tile):
        y1 = min(h, y0 + tile)
        band = scene[y0:y1].astype(np.float64)
        t = fld.transmission(band, c, scene.shape[:2], rows=(y0, y1))
        o = dehaze(band, value, fld, c, t=t)
        if k > 1:
            out.append(blocks(o, k))
        else:
            out[y0:y1] = o
    return np.concatenate(out, axis=0) if k > 1 else out


def scaled_by(scene, R, tile=512):
    """`scene` times a per-channel ratio grid `R`, read bilinearly at every pixel, in bands of `tile` rows."""
    out = np.empty(scene.shape, np.float32)
    for y0 in range(0, scene.shape[0], tile):
        y1 = min(scene.shape[0], y0 + tile)
        out[y0:y1] = scene[y0:y1] * np.stack([sample_at(R[..., i], scene.shape[:2], rows=(y0, y1)) for i in range(3)],
                                             axis=-1).astype(np.float32)
    return out


# MARK: The photographs in Lightroom's terms

def sources():
    """Each raw job's source raw, from the probe's manifests (round 1 and round 3)."""
    jobs = json.loads(MANIFEST.read_text())["jobs"] + json.loads(ROUND3.read_text())["jobs"]
    return {j["name"]: Path(j["source"]) for j in jobs if j["kind"] in ("probe raw", "photo")}


def oriented(scene, shape):
    """Argent's decode turned to the export's orientation (Lightroom writes a portrait frame upright)."""
    if scene.shape[:2] == tuple(shape):
        return scene
    if scene.shape[:2] == tuple(shape)[::-1]:
        return np.ascontiguousarray(np.rot90(scene, -1))
    raise SystemExit(f"decode {scene.shape[:2]} does not match the export {shape}")


class RenderModel:
    """A photograph's render by Lightroom, modelled as one monotone curve from linear luminance to the export's linear
    luminance, applied hue-preservingly (as ToneModel). It is fitted on Argent's decode against Lightroom's base, so its
    input scale is Argent's scene; Dehaze's math is exposure-equivariant, so only the curve's shape matters."""

    def __init__(self, scene_prophoto, export):
        x = np.log2(np.maximum(scene_prophoto @ probe.PROPHOTO_Y, 1e-7)).ravel()
        y = np.log2(np.maximum(export @ probe.PROPHOTO_Y, 1e-7)).ravel()
        ok = (export.min(-1).ravel() > 1e-4) & (export.max(-1).ravel() < 0.995)
        c, m, n = probe.binned_median(x[ok], y[ok], np.arange(-14, 6, 0.1), minimum=40)
        m = probe.pava(m, np.minimum(n, 2000))
        self.xi, self.xo = c, np.maximum.accumulate(m + np.arange(len(m)) * 1e-9)

    def curve(self, v):
        lv = np.log2(np.maximum(v, 1e-12))
        lo_slope = (self.xo[3] - self.xo[0]) / (self.xi[3] - self.xi[0])
        hi_slope = max((self.xo[-1] - self.xo[-4]) / (self.xi[-1] - self.xi[-4]), 0.05)
        out = np.interp(lv, self.xi, self.xo)
        out = np.where(lv < self.xi[0], self.xo[0] + (lv - self.xi[0]) * lo_slope, out)
        out = np.where(lv > self.xi[-1], self.xo[-1] + (lv - self.xi[-1]) * hi_slope, out)
        return np.exp2(out)

    TOP = 0.97

    def inverse_curve(self, v):
        """The inverse, with exports held at TOP: above it the curve is too flat to read back. Unheld, the probe raw's
        near-white sky read back 55 % bluer from 8-pixel blocks than from 4-pixel blocks, and so did its airlight."""
        lv = np.log2(np.clip(v, 1e-12, self.TOP))
        lo_slope = (self.xo[3] - self.xo[0]) / (self.xi[3] - self.xi[0])
        out = np.interp(lv, self.xo, self.xi)
        out = np.where(lv < self.xo[0], self.xi[0] + (lv - self.xo[0]) / lo_slope, out)
        return np.exp2(out)

    render = ToneModel.render
    unrender = ToneModel.unrender
    _apply = ToneModel._apply


def scene_blocks(raw, stock, *flags, shape=None):
    """Argent's decode of `raw` (full size, no lens corrections), turned to `shape`, as 4 x 4 block means."""
    scene = scene_io.scene_of(raw, stock, "--no-lens", *flags, binary=SPIKE)
    if shape is not None:
        scene = oriented(scene, shape)
    out = blocks(scene)
    del scene
    return out


def global_airlight_fit(I, O, iterations=25):
    """M5: the one airlight A that best explains O = A + (I - A) G(x) with a free gain per sample, and that gain.
    Samples are rows of (n, 3)."""
    A = np.quantile(I, 0.999, axis=0)
    for _ in range(iterations):
        d = I - A
        G = (((O - A) * d).sum(-1) / np.maximum((d * d).sum(-1), 1e-12))
        # For fixed G the model is linear in A: O - I G = A (1 - G).
        w = (1 - G)
        A_new = ((O - I * G[:, None]) * w[:, None]).sum(0) / np.maximum((w * w).sum(), 1e-12)
        if np.abs(A_new - A).max() < 1e-6:
            A = A_new
            break
        A = A_new
    d = I - A
    G = ((O - A) * d).sum(-1) / np.maximum((d * d).sum(-1), 1e-12)
    return A, G


class PhotoCase:
    """A raw job in Lightroom's terms: Lightroom's base and changes at 4 x 4 blocks, its base linearised by the photo's
    render model, and a candidate's change rendered back through that model; with k = 8 the linearised data are then
    averaged 2 x 2, so both sizes share one model. The candidate's field is made from Lightroom's linearised base, so
    its airlight has Lightroom's colours: made from Argent's decode, whose colours differ from Lightroom's by a median
    Delta E of 3 to 12 on these photographs, the mean error at +100 rose from 6.2 to 8.7. Near white the model's curve
    is flat and its inverse ill-conditioned: a sky there reads back with an uncertain colour (55 % apart in blue on the
    probe raw between models fitted at 4- and 8-pixel blocks), so an airlight taken from such a sky is uncertain too."""

    def __init__(self, job, values, stock=STOCKS / "kodak-portra-400", k=probe.BLOCK, lr=None, scene=None):
        """`lr`, a LightroomFrame, and `scene`, Argent's decode as 4 x 4 blocks already turned onto the export, spare
        the case its own reads when the caller holds them."""
        self.job = self.name = job
        lr0 = lr.lin[0] if lr is not None else blocks(lightroom(job))
        self.shape = (lr0.shape[0] * probe.BLOCK, lr0.shape[1] * probe.BLOCK)
        if scene is None:
            scene = scene_blocks(sources()[job], stock, shape=self.shape)
        self.model = RenderModel(scene @ REC2020_TO_PROPHOTO.T, lr0)
        self.base_error = float(np.median(np.linalg.norm(
            lab_prophoto(self.model.render(scene @ REC2020_TO_PROPHOTO.T)) - lab_prophoto(lr0), axis=-1)))
        del scene
        f = k // probe.BLOCK
        self.lin0 = blocks(self.model.unrender(lr0), f)
        self.lr0 = blocks(lr0, f)
        self.lab0 = lab_prophoto(self.lr0)
        self.I = self.lin0 @ np.linalg.inv(REC2020_TO_PROPHOTO).T
        self.base = lab_prophoto(self.model.render(self.lin0))
        self.out = {v: blocks(lr.lin[v] if lr is not None else blocks(lightroom(job, v)), f) for v in values}
        self.change = {v: lab_prophoto(o) - self.lab0 for v, o in self.out.items()}
        self.valid = (self.lr0.min(-1) > 2e-4) & (self.lr0.max(-1) < 0.99)

    def field(self, c):
        return Field(self.I, c)

    def candidate_change(self, c, value, fld=None):
        fld = fld or self.field(c)
        out = dehaze(self.I, value, fld, c)
        return lab_prophoto(self.model.render(out @ REC2020_TO_PROPHOTO.T)) - self.base

    def error(self, c, value, fld=None):
        e = np.linalg.norm(self.candidate_change(c, value, fld) - self.change[value], axis=-1)
        return float(e[self.valid].mean())


# MARK: Through Argent's film

FILM_SOURCES = ["p-raw", "p-photo-hazy", "p-photo-sky", "p-photo-foliage", "p-photo-flat"]
FILM_STOCKS = ["kodak-portra-400", "kodak-ektar-100"]
L_BINS = np.arange(0, 100.001, 5.0)


def change_scores(dA, dL, base_A, valid):
    """The scores of one value: Argent's change dA against Lightroom's dL (CIELAB, per block), over `valid` blocks.

    - change error: mean CIE76 length of dA - dL, in Delta E;
    - L* rms: rms of the two changes' L* difference;
    - curve rms: rms over 5-L* bins of the base L* of the two binned-median L* changes (as score.py, coarser);
    - reach: Lightroom's mean change length, for scale;
    - L* bias: the mean of Argent's L* change less Lightroom's (positive: Argent's print ends lighter)."""
    e = np.linalg.norm(dA - dL, axis=-1)[valid]
    dl = (dA[..., 0] - dL[..., 0])[valid]
    ca = probe.binned_median(base_A[valid], dA[..., 0][valid], L_BINS, minimum=200)
    cl = probe.binned_median(base_A[valid], dL[..., 0][valid], L_BINS, minimum=200)
    common = sorted(set(np.round(ca[0], 2)) & set(np.round(cl[0], 2)))
    a = dict(zip(np.round(ca[0], 2), ca[1]))
    b = dict(zip(np.round(cl[0], 2), cl[1]))
    curve = float(np.sqrt(np.mean([(a[k] - b[k]) ** 2 for k in common]))) if common else float("nan")
    return {"change": float(e.mean()), "changeP95": float(np.percentile(e, 95)), "lRms": float(np.sqrt(np.mean(dl ** 2))),
            "curve": curve, "reach": float(np.linalg.norm(dL, axis=-1)[valid].mean()), "lBias": float(dl.mean())}


def print_lab(raw, stock, scene, flags, shape):
    p = scene_io.print_of(raw, stock, scene, *flags, binary=SPIKE)
    p = oriented(p, shape)
    out = lab_xyz(blocks(scene_io.print_xyz(p)))
    del p
    return out


def lightroom_ratio(case, value):
    """Lightroom's own change on `case` as a per-block, per-channel ratio of linear light (its export and its base, both
    read back through the photo's render model), in Rec. 2020 channels. Applied to Argent's scene it is a perfect
    scene-side copy of Lightroom's change: what it still misses through Argent's film is the floor of any stage placed
    before the stock."""
    out = case.model.unrender(case.out[value]) @ np.linalg.inv(REC2020_TO_PROPHOTO).T
    ratio = out / np.where(np.abs(case.I) > 1e-6, case.I, 1e-6)
    return np.clip(np.where(case.valid[..., None], ratio, 1.0), 0, 50)


def film_case(job, stock_name, candidates, values, oracle=True, auto=False, log=print):
    """One source on one stock: Argent's base print and each candidate's, against Lightroom's changes."""
    raw, stock = sources()[job], STOCKS / stock_name
    flags, level, cast = aim_flags(raw, stock)
    flags = (["--auto"] if auto else flags) + ["--no-lens"]
    lr0 = lab_prophoto(blocks(lightroom(job)))
    shape = (lr0.shape[0] * probe.BLOCK, lr0.shape[1] * probe.BLOCK)
    lr = {v: lab_prophoto(blocks(lightroom(job, v))) - lr0 for v in values}
    scene = scene_io.scene_of(raw, stock, *flags, binary=SPIKE)
    base = print_lab(raw, stock, scene, flags, shape)
    valid = (lr0[..., 0] > 0.5) & (lr0[..., 0] < 99.5) & (base[..., 0] > 0.5) & (base[..., 0] < 99.5)
    rows = {}
    for name, c in candidates.items():
        fld = Field(scene, c)
        for v in values:
            out = dehaze_frame(scene, v, fld, c)
            dA = print_lab(raw, stock, out, flags, shape) - base
            del out
            rows[(name, v)] = change_scores(dA, lr[v], base[..., 0], valid)
            log(f"  {job} {stock_name} {name} {v:+d}: " + " ".join(f"{k} {x:.2f}" for k, x in rows[(name, v)].items()))
        rows[(name, "airlight")] = [float(x) for x in fld.A]
    if oracle:
        case = PhotoCase(job, values, stock=stock)
        for v in values:
            R = lightroom_ratio(case, v)
            Rf = np.stack([sample_at(R[..., i], shape) for i in range(3)], axis=-1).astype(np.float32)
            if scene.shape[:2] != shape:
                Rf = np.ascontiguousarray(np.rot90(Rf, 1))
            out = scene * Rf
            del Rf
            dA = print_lab(raw, stock, out, flags, shape) - base
            del out
            rows[("oracle", v)] = change_scores(dA, lr[v], base[..., 0], valid)
            log(f"  {job} {stock_name} oracle {v:+d}: " + " ".join(f"{k} {x:.2f}" for k, x in rows[("oracle", v)].items()))
        del case
    del scene
    return {"aim": {"level": level, "cast": cast.tolist(), "flags": flags}, "rows": rows}


# MARK: Held-out frames (V2)

# Round 3's twenty photographs in rank order of round 2's quick-decode median, ties by name. Odd ranks are half A
# (a revision's fit half), even ranks half B (its test half): the rule was fixed before any of them was scored.
HELD_OUT = ["r-photo-mirror-lights", "r-photo-magenta-night", "r-photo-disco", "r-photo-chandeliers", "r-photo-hall",
            "r-photo-gull-flight", "r-photo-tower", "r-photo-horizon", "r-photo-fog-woods", "r-photo-flower",
            "r-photo-concrete", "r-photo-wave", "r-photo-bird-branches", "r-photo-holly", "r-photo-chickadee",
            "r-photo-birches", "r-photo-dog-woods", "r-photo-wave-shore", "r-photo-gulls", "r-photo-dog-snow"]
HALF = {job: "AB"[i % 2] for i, job in enumerate(HELD_OUT)}
HELD_OUT_VALUES = [-100, 50, 100]
PROTOCOLS = ("aim", "auto")


class LightroomFrame:
    """Lightroom's renders of one frame at 4 x 4 blocks, each value against its own job's base: linear ProPhoto means
    (`lin`, keyed by value, 0 the base), the base in CIELAB, each value's change, and the blocks holding a clipped pixel
    (a channel at code 0 or 65535) in the base or that value's render, where the export no longer records the change."""

    def __init__(self, job, values):
        self.job, self.values = job, list(values)
        self.lin, clipped = {}, {}
        for v in [0] + self.values:
            full = lightroom(job, v)
            clipped[v] = blocks(((full.min(-1) <= 0) | (full.max(-1) >= 1)).astype(np.float32)) > 0
            self.lin[v] = blocks(full)
            del full
        self.lab0 = lab_prophoto(self.lin[0])
        self.change = {v: lab_prophoto(self.lin[v]) - self.lab0 for v in self.values}
        self.clipped = {v: clipped[0] | clipped[v] for v in self.values}


def registration(decode_blocks, lab0):
    """The quarter turns k for which np.rot90(decode, k) lies on Lightroom's export: of the turns that give the export's
    shape, the one whose log luminance correlates best with the export's L* over 32-pixel blocks. A frame no turn
    registers (correlation under 0.8) is refused rather than scored misaligned."""
    y = np.log2(np.maximum(decode_blocks @ Y2020, 1e-6))
    L = blocks(lab0[..., 0], 8).ravel()
    corr = {k: float(np.corrcoef(blocks(np.rot90(y, k), 8).ravel(), L)[0, 1])
            for k in range(4) if np.rot90(y, k).shape == lab0.shape[:2]}
    k = max(corr, key=corr.get)
    if corr[k] < 0.8:
        raise SystemExit(f"the decode does not register on the export: correlation by quarter turn {corr}")
    return k, corr[k]


def print_blocks(raw, stock, scene, flags, k, binary=SPIKE):
    """The print of `scene` as CIELAB (D50) 4 x 4 blocks, turned onto the export."""
    p = scene_io.print_of(raw, stock, scene, *flags, binary=binary)
    out = lab_xyz(np.rot90(blocks(scene_io.print_xyz(p)), k))
    del p
    return out


def describe_frame(case, lr, candidates):
    """What step 2 ranks the misses by, from Lightroom's renders alone: the airlight Lightroom implies (M5) over the
    field's rule at ±100, the share of clear-sky blocks (F2's rule: top quarter, hue 220 to 300, L* over 50, C* over 5),
    the share of clipped blocks, Lightroom's reach, the field's median transmission, and each candidate in Lightroom's
    terms (mean CIE76, F2's blocks and with clipped blocks left out). The field is the first candidate's."""
    c = next(iter(candidates.values()))
    fld = case.field(c)
    lab = case.lab0
    hue = np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360
    sky = np.zeros(lab.shape[:2], bool)
    sky[: lab.shape[0] // 4] = True
    sky &= (hue > 220) & (hue < 300) & (lab[..., 0] > 50) & (np.hypot(lab[..., 1], lab[..., 2]) > 5)
    out = {"skyShare": float(sky[case.valid].mean()),
           "medianT": float(np.median(fld.transmission(case.I, c)[case.valid])),
           "clipShare": {v: float(lr.clipped[v].mean()) for v in lr.values},
           "reach": {v: float(np.linalg.norm(lr.change[v], axis=-1)[case.valid].mean()) for v in lr.values},
           "renderModelError": case.base_error, "airlightRatio": {}, "lrTerms": {}}
    A_rule = fld.A @ REC2020_TO_PROPHOTO.T
    for v in (100, -100):
        if v in lr.values:
            m = case.valid & (case.out[v].min(-1) > 2e-4)
            A, _ = global_airlight_fit(case.lin0[m], case.model.unrender(case.out[v])[m])
            out["airlightRatio"][v] = float((A @ probe.PROPHOTO_Y) / (A_rule @ probe.PROPHOTO_Y))
    for name, cand in candidates.items():
        f = case.field(cand)
        rows = {}
        for v in lr.values:
            e = np.linalg.norm(case.candidate_change(cand, v, f) - case.change[v], axis=-1)
            rows[v] = {"f2": float(e[case.valid].mean()), "clip": float(e[case.valid & ~lr.clipped[v]].mean())}
        out["lrTerms"][name] = rows
    return out


def airlights(job, values, c):
    """The airlight Lightroom implies on a photograph (M5: one A with a free gain per block, fitted on its linearised
    base and render, at -100 where the pull toward A pins it best, and at +100) against the field's rule on the same
    linearised base: both in linear ProPhoto, their luminance ratio and their distance in u'v'."""
    lr = LightroomFrame(job, values)
    case = PhotoCase(job, values, lr=lr)
    A_rule = case.field(c).A @ REC2020_TO_PROPHOTO.T
    xyz = lambda rgb: np.asarray(rgb) @ PROPHOTO_XYZ.T  # noqa: E731
    uv = lambda X: np.array([4 * X[0], 9 * X[1]]) / (X[0] + 15 * X[1] + 3 * X[2])  # noqa: E731
    out = {"rule": A_rule.tolist(), "renderModelError": case.base_error}
    for v in (-100, 100):
        if v in values:
            m = case.valid & (case.out[v].min(-1) > 2e-4)
            A, _ = global_airlight_fit(case.lin0[m], case.model.unrender(case.out[v])[m])
            out[str(v)] = {"lightroom": A.tolist(), "luminanceRatio": float((A @ probe.PROPHOTO_Y) / (A_rule @ probe.PROPHOTO_Y)),
                           "uv": float(np.linalg.norm(uv(xyz(A)) - uv(xyz(A_rule))))}
    return out


def held_out_case(job, candidates, values=HELD_OUT_VALUES, stocks=FILM_STOCKS, floor=True, log=print):
    """One frame through Argent's film on each stock, with F2's protocol and metrics, and the same stage under the
    app's automatic print.

    - "aim": F2's protocol. The explicit aim (`aim_flags`), no tone step, the stage's field from the untouched decode.
    - "auto": `--auto` through `--scene-in`. Auto's tone step reads its base from the dehazed scene it is given, which
      the app's stage would not show it (fit-common fact 2); it is the nearest the prototype comes to the app's print.
    - "floor": Lightroom's own change copied onto Argent's scene (F2's oracle), under "aim".

    Each row holds the scores over F2's blocks ("f2") and with Lightroom's clipped blocks left out ("clip")."""
    raw = sources()[job]
    lr = LightroomFrame(job, values)
    scene = scene_io.scene_of(raw, STOCKS / stocks[0], "--no-lens", binary=SPIKE)
    decode_blocks = blocks(scene)
    k, corr = registration(decode_blocks, lr.lab0)
    case = PhotoCase(job, values, lr=lr, scene=np.rot90(decode_blocks, k))
    del decode_blocks
    fields = {n: Field(scene, c) for n, c in candidates.items()}
    result = {"source": str(raw), "registration": {"quarterTurns": k, "correlation": corr},
              "airlight": {n: f.A.tolist() for n, f in fields.items()},
              "descriptors": describe_frame(case, lr, candidates), "stocks": {}}
    for stock_name in stocks:
        stock = STOCKS / stock_name
        aim, level, cast = aim_flags(raw, stock)
        flags = {"aim": aim + ["--no-lens"], "auto": ["--auto", "--no-lens"]}
        bases = {p: print_blocks(raw, stock, scene, f, k) for p, f in flags.items()}
        rows = {}

        def score(name, protocol, v, out):
            base = bases[protocol]
            dA = print_blocks(raw, stock, out, flags[protocol], k) - base
            valid = (lr.lab0[..., 0] > 0.5) & (lr.lab0[..., 0] < 99.5) & (base[..., 0] > 0.5) & (base[..., 0] < 99.5)
            rows[f"{name} {protocol} {v:+d}"] = {
                "f2": change_scores(dA, lr.change[v], base[..., 0], valid),
                "clip": change_scores(dA, lr.change[v], base[..., 0], valid & ~lr.clipped[v])}
            r = rows[f"{name} {protocol} {v:+d}"]["f2"]
            log(f"  {job} {stock_name} {name} {protocol} {v:+d}: change {r['change']:.2f} L* rms {r['lRms']:.2f} "
                f"curve {r['curve']:.2f} reach {r['reach']:.2f}")

        for name, c in candidates.items():
            for v in values:
                out = dehaze_frame(scene, v, fields[name], c)
                for protocol in PROTOCOLS:
                    score(name, protocol, v, out)
                del out
        if floor:
            for v in values:
                out = scaled_by(scene, np.rot90(lightroom_ratio(case, v), -k))
                score("floor", "aim", v, out)
                del out
        result["stocks"][stock_name] = {"aim": {"level": level, "cast": cast.tolist(), "flags": flags}, "rows": rows}
    del scene, case
    return result


def frame_score(entry, stock, name, protocol="aim", mask="f2", metric="change", values=HELD_OUT_VALUES):
    """One frame's score: the mean over `values` of one metric of one row family."""
    rows = entry["stocks"][stock]["rows"]
    return float(np.mean([rows[f"{name} {protocol} {v:+d}"][mask][metric] for v in values]))


def set_score(data, jobs, stock, name, protocol="aim", mask="f2", metric="change", values=HELD_OUT_VALUES):
    """The mean over `jobs` of each frame's mean over `values` (F2's "mean of the sources")."""
    return float(np.mean([frame_score(data[j], stock, name, protocol, mask, metric, values) for j in jobs]))


def spearman(x, y):
    rank = lambda a: np.argsort(np.argsort(a)).astype(float)  # noqa: E731
    return float(np.corrcoef(rank(np.asarray(x)), rank(np.asarray(y)))[0, 1])


def summarise(held, inside, log=print):
    """Step 1's comparison and verdict, step 2's ranking and step 5's protocol gap, as markdown and as numbers."""
    names = {"kodak-portra-400": "Portra 400", "kodak-ektar-100": "Ektar 100"}
    jobs, ins = [j for j in HELD_OUT if j in held], [j for j in FILM_SOURCES if j in inside]
    out = {"frames": jobs, "inSample": ins, "means": {}, "verdict": {}, "byValue": {}, "rank": [], "protocol": {}}
    log("| Stock | Set | Field: change error / L* rms / curve | Global veil | Floor | Field above the floor: ΔE / L* rms |")
    log("| --- | --- | --- | --- | --- | --- |")
    for stock in FILM_STOCKS:
        for label, data, js in (("in-sample (5)", inside, ins), (f"held out ({len(jobs)})", held, jobs)):
            m = {n: {k: set_score(data, js, stock, n, metric=k) for k in ("change", "lRms", "curve")}
                 for n in ("dark-channel", "global-veil", "floor")}
            out["means"][f"{stock} {label.split()[0]}"] = m
            cell = lambda n: f"{m[n]['change']:.2f} / {m[n]['lRms']:.2f} / {m[n]['curve']:.2f}"  # noqa: E731
            log(f"| {names[stock]} | {label} | {cell('dark-channel')} | {cell('global-veil')} | {cell('floor')} | "
                f"{m['dark-channel']['change'] - m['floor']['change']:.2f} / {m['dark-channel']['lRms'] - m['floor']['lRms']:.2f} |")
        i, h = out["means"][f"{stock} in-sample"], out["means"][f"{stock} held"]
        above = lambda m, k: m["dark-channel"][k] - m["floor"][k]  # noqa: E731
        out["verdict"][stock] = {
            "fieldBeatsVeil": h["dark-channel"]["lRms"] < h["global-veil"]["lRms"],
            "lRmsAboveFloor": [above(h, "lRms"), 1.5 * above(i, "lRms")],
            "changeAboveFloor": [above(h, "change"), above(i, "change") + 1.0]}
        v = out["verdict"][stock]
        v["holds"] = bool(v["fieldBeatsVeil"] and v["lRmsAboveFloor"][0] <= v["lRmsAboveFloor"][1]
                          and v["changeAboveFloor"][0] <= v["changeAboveFloor"][1])
    log("")
    log("Per frame (F2's protocol and blocks; change error / L* rms, each the mean of the frame's values):")
    log("")
    log("| Frame | Half | Portra 400: field | veil | floor | Ektar 100: field | veil | floor | Lightroom's change |")
    log("| --- | --- | --- | --- | --- | --- | --- | --- | ---: |")
    for label, data, js in (("in", inside, ins), ("held", held, jobs)):
        for j in js:
            cells = [f"{frame_score(data[j], s, n):.2f} / {frame_score(data[j], s, n, metric='lRms'):.2f}"
                     for s in FILM_STOCKS for n in ("dark-channel", "global-veil", "floor")]
            reach = frame_score(data[j], FILM_STOCKS[0], "floor", metric="reach")
            log(f"| {j} | {data[j].get('half') or 'in-sample'} | " + " | ".join(cells) + f" | {reach:.2f} |")
    log("")
    log(f"Verdict (fixed before the run): {json.dumps(out['verdict'], default=float)}")
    log("")
    log("| Stock | Value | Field, held out: change / L* rms / L* bias | Floor | In-sample field | In-sample floor |")
    log("| --- | ---: | --- | --- | --- | --- |")
    for stock in FILM_STOCKS:
        for v in HELD_OUT_VALUES:
            row = {}
            for key, data, js in (("held", held, jobs), ("in", inside, ins)):
                for n in ("dark-channel", "floor"):
                    row[f"{key} {n}"] = {k: set_score(data, js, stock, n, metric=k, values=[v]) for k in ("change", "lRms", "lBias")}
            out["byValue"][f"{stock} {v:+d}"] = row
            f = lambda r: f"{r['change']:.2f} / {r['lRms']:.2f} / {r['lBias']:+.2f}"  # noqa: E731
            log(f"| {names[stock]} | {v:+d} | {f(row['held dark-channel'])} | {f(row['held floor'])} | "
                f"{f(row['in dark-channel'])} | {f(row['in floor'])} |")
    log("")
    log("Ranked by the field's L* rms above the floor, Lightroom's clipped blocks left out (mean of both stocks and the "
        "three values):")
    log("")
    lights = json.loads((VALIDATION / "airlights.json").read_text()) if (VALIDATION / "airlights.json").exists() else {}
    log("| Rank | Frame | Half | L* rms above floor | ΔE above floor | -100 L* bias | +100 L* bias | Lightroom's airlight "
        "over the rule's at -100: luminance, u'v' | Sky | Clipped at +100 | Median t | Reach +100 | LR terms field / veil +100 |")
    log("| ---: | --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | --- |")
    for j in jobs:
        e, d = held[j], held[j]["descriptors"]
        miss = {k: float(np.mean([frame_score(e, s, "dark-channel", mask="clip", metric=k) - frame_score(e, s, "floor", mask="clip", metric=k)
                                  for s in FILM_STOCKS])) for k in ("lRms", "change")}
        bias = {v: float(np.mean([frame_score(e, s, "dark-channel", mask="clip", metric="lBias", values=[v]) for s in FILM_STOCKS]))
                for v in (-100, 100)}
        out["rank"].append({"frame": j, "half": e["half"], "lRmsAboveFloor": miss["lRms"], "changeAboveFloor": miss["change"],
                            "biasMinus100": bias[-100], "biasPlus100": bias[100],
                            "airlightPlus100": d["airlightRatio"].get("100"), "airlightMinus100": d["airlightRatio"].get("-100"),
                            "sky": d["skyShare"], "clipPlus100": d["clipShare"]["100"], "medianT": d["medianT"],
                            "airlightUV": lights.get(j, {}).get("-100", {}).get("uv", float("nan")),
                            "reachPlus100": d["reach"]["100"], "lrField100": d["lrTerms"]["dark-channel"]["100"]["clip"],
                            "lrVeil100": d["lrTerms"]["global-veil"]["100"]["clip"]})
    out["rank"].sort(key=lambda r: -r["lRmsAboveFloor"])
    for i, r in enumerate(out["rank"], 1):
        log(f"| {i} | {r['frame'][8:]} | {r['half']} | {r['lRmsAboveFloor']:.2f} | {r['changeAboveFloor']:.2f} | "
            f"{r['biasMinus100']:+.2f} | {r['biasPlus100']:+.2f} | {r['airlightMinus100']:.2f}, {r['airlightUV']:.3f} | "
            f"{r['sky']:.3f} | {r['clipPlus100']:.3f} | {r['medianT']:.2f} | {r['reachPlus100']:.1f} | "
            f"{r['lrField100']:.2f} / {r['lrVeil100']:.2f} |")
    keys = ["airlightPlus100", "airlightMinus100", "airlightUV", "sky", "clipPlus100", "medianT", "reachPlus100",
            "biasMinus100", "biasPlus100"]
    out["correlation"] = {k: spearman([r[k] for r in out["rank"]], [r["lRmsAboveFloor"] for r in out["rank"]]) for k in keys}
    log("")
    log("Spearman correlation of the L* rms above the floor with: "
        + ", ".join(f"{k} {v:+.2f}" for k, v in out["correlation"].items()))
    log("")
    log("The two protocols: the field's score with --auto through --scene-in less with the explicit aim (clipped blocks out):")
    for stock in FILM_STOCKS:
        for metric in ("change", "lRms"):
            gaps = np.array([[held[j]["stocks"][stock]["rows"][f"dark-channel auto {v:+d}"]["clip"][metric]
                              - held[j]["stocks"][stock]["rows"][f"dark-channel aim {v:+d}"]["clip"][metric]
                              for v in HELD_OUT_VALUES] for j in jobs])
            out["protocol"][f"{stock} {metric}"] = {"meanByValue": gaps.mean(0).tolist(), "mean": float(gaps.mean()),
                                                    "minFrame": float(gaps.mean(1).min()), "maxFrame": float(gaps.mean(1).max()),
                                                    "absMaxCell": float(np.abs(gaps).max())}
            log(f"  {names[stock]} {metric}: mean {gaps.mean():+.2f}, by value {np.round(gaps.mean(0), 2).tolist()}, "
                f"frames {gaps.mean(1).min():+.2f} to {gaps.mean(1).max():+.2f}, largest cell {np.abs(gaps).max():.2f}")
    return out


LAW_VALUES = [10, 25, 50, 75, 100, -100, -75, -50, -25, -10]
# Step 4's variants of F2's constants: the overrides, and whether the slider's law is refitted for them (on round 1's
# eleven raws and half A, in Lightroom's terms, as F2's `fit` did on the eleven alone).
VARIANTS = {"no fade": (lambda: {"fade": False}, False),
            "brighter airlight": (lambda: {"airlight_gain": float(json.loads(
                (VALIDATION / "airlight-screen.json").read_text())["best"])}, True)}


def variant_constants(name, log=print):
    """F2's recommended constants with a variant's overrides, the law refitted at every knot when the variant asks."""
    overrides, refit = VARIANTS[name][0](), VARIANTS[name][1]
    c = Constants(**{**asdict(load_constants()["dark-channel"]), **overrides})
    if not refit:
        return c, None
    cases = photo_cases(log=log) + [PhotoCase(j, HELD_OUT_VALUES, k=8) for j in HELD_OUT if HALF[j] == "A"]
    fits = fit_law(cases, c, LAW_VALUES, log=log)
    return with_law(c, fits), {str(v): f for v, f in fits.items()}


def airlight_screen(gains=(1.0, 1.25, 1.5, 2.0), log=print):
    """Step 4's fit for a brighter airlight, on round 1's eleven raws and half A in Lightroom's terms (8 x 8 blocks, as
    F2's fit): for each gain on the rule's airlight, the best kappa at +50 and +100 and the best -100 share at F2's
    -100 power, each by the mean change error over the cases that have the value. A gain that does not beat 1 here is
    rejected before any film test."""
    base = load_constants()["dark-channel"]
    cases = photo_cases(log=log) + [PhotoCase(j, HELD_OUT_VALUES, k=8) for j in HELD_OUT if HALF[j] == "A"]
    power = float(np.interp(100, base.haze_values, base.haze_power))
    out = {}
    for g in gains:
        c = Constants(**{**asdict(base), "airlight_gain": g})
        fields = {id(k): k.field(c) for k in cases}

        def mean_error(trial, v):
            return float(np.mean([k.error(trial, v, fields[id(k)]) for k in cases if v in k.change]))

        row = {}
        for v in (50, 100):
            def at(x, v=v):
                return mean_error(Constants(**{**asdict(c), "kappa_values": [0, 100], "kappa": [0, x * 100 / v]}), v)
            x = golden(at, 0.02, 2.0)
            row[v] = {"kappa": x, "error": at(x)}

        def at_share(s):
            return mean_error(Constants(**{**asdict(c), "haze_values": [0, 100], "haze_share": [0, s],
                                           "haze_power": [power, power]}), -100)
        s = golden(at_share, 0.02, 1.0)
        row[-100] = {"share": s, "power": power, "error": at_share(s)}
        row["mean"] = float(np.mean([row[v]["error"] for v in (50, 100, -100)]))
        out[g] = row
        log(f"  airlight x{g}: " + ", ".join(f"{v:+d} {r}" for v, r in row.items() if v != "mean") + f"; mean {row['mean']:.3f}")
    return {"cases": [k.name for k in cases], "gains": out, "best": min(out, key=lambda g: out[g]["mean"])}


def compare_on(held, variant, jobs, name, log=print):
    """A variant's film scores against F2's constants' on `jobs` (F2's protocol, F2's blocks and without clipped
    ones): per stock and metric, F2's mean, the variant's, and whether the variant beats F2's."""
    out = {}
    for stock in FILM_STOCKS:
        for mask in ("f2", "clip"):
            for metric in ("change", "lRms"):
                f2 = set_score(held, jobs, stock, "dark-channel", "aim", mask, metric)
                var = set_score(variant, jobs, stock, name, "aim", mask, metric)
                out[f"{stock} {mask} {metric}"] = {"f2": f2, "variant": var, "beats": var < f2}
                log(f"  {stock} {mask} {metric}: F2 {f2:.3f}, {name} {var:.3f}")
    out["adopt"] = all(out[f"{s} f2 {m}"]["beats"] for s in FILM_STOCKS for m in ("change", "lRms"))
    return out


def run_frames(path, jobs, candidates, values, fresh=False, floor=True, log=print):
    """Scores `jobs` into the JSON at `path`, one frame at a time, keeping frames already there (`fresh` rescores
    `jobs` and keeps the rest), so an interrupted run resumes where it stopped."""
    done = json.loads(path.read_text()) if path.exists() else {}
    for job in jobs:
        if job in done and not fresh:
            log(f"  {job}: kept from {path.name}")
            continue
        t0 = time.time()
        done[job] = {"half": HALF.get(job), **held_out_case(job, candidates, values, floor=floor, log=log)}
        done[job]["seconds"] = round(time.time() - t0)
        path.write_text(json.dumps(done, indent=1, default=float))
        log(f"  {job}: {done[job]['seconds']} s")
    return done


# MARK: The pass bar and the Swift build's scorer (V2)

BARS = VALIDATION / "bars.json"
APP_FLAGS = ["--auto", "--no-lens"]
MEAN_MARGIN = 0.05
FRAME_MARGIN = 0.5
PARITY_FRAMES = ["r-photo-fog-woods", "r-photo-mirror-lights"]


def make_bars(held, frames, constants_path):
    """The pass bar for the app's automatic print (`APP_FLAGS` with `--dehaze VALUE`, against the same flags without
    it), from the prototype's held-out scores with Lightroom's clipped blocks left out. The prototype cannot render
    that protocol: through `--scene-in`, Auto's tone step reads the dehazed scene, where the app's reads the untouched
    frame. So each bar takes the worse of the prototype's two renders, `--auto` through `--scene-in` and the explicit
    aim without the tone step, plus a margin: 5 % on the means (half floats and the GPU's bilinear reads, a guess),
    and per frame the larger of 0.5 ΔE and 10 %. Parity against the prototype, under the explicit aim where the
    prototype is exact, is what catches an implementation error the margins could hide."""
    bars = {
        "made": time.strftime("%Y-%m-%d %H:%M"), "script": "scripts/lightroom-probe/fit_dehaze.py bar",
        "constants": str(constants_path), "frames": frames, "values": HELD_OUT_VALUES, "stocks": FILM_STOCKS,
        "protocol": {
            "base": APP_FLAGS, "stage": "--dehaze VALUE, added to the base flags",
            "compare": "CIELAB (D50) of 4 x 4 block means: the print (--print-out, Bradford to D50) against Lightroom's "
                       "export of the round 3 job (linear ProPhoto), each change from its own base (Lightroom: the "
                       "job's 00_base; Argent: the same build and flags without --dehaze)",
            "mask": "blocks whose Lightroom base and Argent base have L* in (0.5, 99.5) and that hold no pixel at code "
                    "0 or 65535 in Lightroom's base or that value's render",
            "metrics": {"change": "mean CIE76 length of Argent's change less Lightroom's",
                        "lRms": "rms of the two changes' L* difference"},
            "aggregate": "per frame the mean over the values, then the mean over the frames"},
        "fidelity": {}, "perFrame": {},
        "parity": {"frames": PARITY_FRAMES, "values": HELD_OUT_VALUES, "flags": "aim_flags(raw, stock) + --no-lens",
                   "rule": "the Swift print with --dehaze VALUE against the prototype's stage rendered through "
                           "--scene-in by the same binary and flags: mean CIE76 over 4 x 4 blocks at most meanMax, "
                           "its 99th percentile at most p99Max, at every frame, stock and value",
                   "meanMax": 0.5, "p99Max": 2.0},
        "identity": {"rule": "--dehaze 0 writes the same print as no --dehaze, bit for bit", "frame": PARITY_FRAMES[0]}}
    for stock in FILM_STOCKS:
        bars["fidelity"][stock] = {}
        for metric in ("change", "lRms"):
            auto = set_score(held, frames, stock, "dark-channel", "auto", "clip", metric)
            aim = set_score(held, frames, stock, "dark-channel", "aim", "clip", metric)
            bars["fidelity"][stock][metric] = {"max": round(max(auto, aim) * (1 + MEAN_MARGIN), 2),
                                               "prototypeAuto": auto, "prototypeAim": aim}
        bars["perFrame"][stock] = {}
        for j in frames:
            auto = frame_score(held[j], stock, "dark-channel", "auto", "clip", "change")
            aim = frame_score(held[j], stock, "dark-channel", "aim", "clip", "change")
            worse = max(auto, aim)
            bars["perFrame"][stock][j] = {"max": round(worse + max(FRAME_MARGIN, 0.1 * worse), 2),
                                          "prototypeAuto": auto, "prototypeAim": aim}
    return bars


def judge(bars, scores):
    """The Swift build's scores against the bar. `scores[stock][frame][value]` holds `change_scores`' metrics. A
    fidelity mean over fewer than every bar frame is another number, so it comes with the count of its frames and
    `pass` None: a subset's value, not a verdict."""
    rows = []
    for stock in bars["stocks"]:
        got = scores.get(stock, {})
        scored = [j for j in bars["frames"] if j in got]
        if scored:
            for metric, bar in bars["fidelity"][stock].items():
                m = float(np.mean([np.mean([got[j][v][metric] for v in bars["values"]]) for j in scored]))
                rows.append({"bar": f"fidelity, mean {metric}", "stock": stock, "measured": m, "max": bar["max"],
                             "prototype": max(bar["prototypeAuto"], bar["prototypeAim"]), "frames": len(scored),
                             "pass": m <= bar["max"] if len(scored) == len(bars["frames"]) else None})
        for j, bar in bars["perFrame"][stock].items():
            if j in got:
                m = float(np.mean([got[j][v]["change"] for v in bars["values"]]))
                rows.append({"bar": f"frame {j}, change", "stock": stock, "measured": m, "max": bar["max"],
                             "prototype": max(bar["prototypeAuto"], bar["prototypeAim"]), "pass": m <= bar["max"]})
    return rows


def has_dehaze_flag(binary):
    """Whether the spike's usage lists --dehaze. The spike prints its usage on --help; an unknown flag would be read
    as an input file, so the flag cannot be probed by passing it."""
    run = subprocess.run([str(binary), "--help"], capture_output=True, text=True)
    return "--dehaze" in run.stdout + run.stderr


def require_dehaze_flag(binary):
    if not Path(binary).is_file():
        raise SystemExit(f"no argent-spike at {binary}")
    if not has_dehaze_flag(binary):
        raise SystemExit(
            f"{binary} has no --dehaze flag yet, so there is no Swift Dehaze stage to score. The scorer renders "
            "`argent-spike RAW --stock STOCK --auto --no-lens --dehaze VALUE --print-out FILE` against the same "
            "command without --dehaze; build a spike that takes the flag and rerun with --binary.")


def spike_blocks(binary, raw, stock, flags, k):
    """The spike's own print of `raw` with `flags` as CIELAB (D50) 4 x 4 blocks, turned onto the export."""
    with tempfile.TemporaryDirectory() as out:
        probe.spike(raw, out, stock, *flags, "--print-out", Path(out) / "print.npy", binary=binary)
        p = np.load(Path(out) / "print.npy")
    lab = lab_xyz(np.rot90(blocks(scene_io.print_xyz(p)), k))
    del p
    return lab


def score_spike(binary, bars, frames=None, parity=True, log=print):
    """The Swift build's Dehaze through its own render, scored against the bar: every bar frame at every value on each
    stock with the app's flags, then parity with this prototype under the explicit aim and identity at 0. Returns the
    judged rows."""
    require_dehaze_flag(binary)
    scores = {s: {} for s in bars["stocks"]}
    for job in frames or bars["frames"]:
        raw = sources()[job]
        lr = LightroomFrame(job, bars["values"])
        k, _ = registration(blocks(scene_io.scene_of(raw, STOCKS / bars["stocks"][0], "--no-lens", binary=binary)), lr.lab0)
        for stock_name in bars["stocks"]:
            stock = STOCKS / stock_name
            base = spike_blocks(binary, raw, stock, bars["protocol"]["base"], k)
            valid = (lr.lab0[..., 0] > 0.5) & (lr.lab0[..., 0] < 99.5) & (base[..., 0] > 0.5) & (base[..., 0] < 99.5)
            scores[stock_name][job] = {}
            for v in bars["values"]:
                dA = spike_blocks(binary, raw, stock, bars["protocol"]["base"] + ["--dehaze", str(v)], k) - base
                scores[stock_name][job][v] = change_scores(dA, lr.change[v], base[..., 0], valid & ~lr.clipped[v])
            log(f"  {job} {stock_name}: " + ", ".join(f"{v:+d} change {r['change']:.2f} L* rms {r['lRms']:.2f}"
                                                     for v, r in scores[stock_name][job].items()))
    rows = judge(bars, scores)
    if parity:
        rows += parity_rows(binary, bars, log=log)
    return rows


def parity_rows(binary, bars, log=print):
    """Parity: the Swift stage against this prototype's, both rendered by `binary` under the explicit aim, where the
    prototype's protocol is exact; and identity: --dehaze 0 against no --dehaze."""
    c = Constants(**json.loads(Path(bars["constants"]).read_text())["candidates"]["dark-channel"]["constants"])
    p = bars["parity"]
    rows = []
    for job in p["frames"]:
        raw = sources()[job]
        scene = scene_io.scene_of(raw, STOCKS / bars["stocks"][0], "--no-lens", binary=binary)
        k, _ = registration(blocks(scene), LightroomFrame(job, []).lab0)
        fld = Field(scene, c)
        for stock_name in bars["stocks"]:
            stock = STOCKS / stock_name
            flags = aim_flags(raw, stock, binary)[0] + ["--no-lens"]
            for v in p["values"]:
                swift = spike_blocks(binary, raw, stock, flags + ["--dehaze", str(v)], k)
                ours = print_blocks(raw, stock, dehaze_frame(scene, v, fld, c), flags, k, binary=binary)
                e = np.linalg.norm(swift - ours, axis=-1)
                mean, p99 = float(e.mean()), float(np.percentile(e, 99))
                rows.append({"bar": f"parity {job} {v:+d}", "stock": stock_name, "measured": mean, "max": p["meanMax"],
                             "p99": p99, "p99Max": p["p99Max"], "pass": mean <= p["meanMax"] and p99 <= p["p99Max"]})
                log(f"  parity {job} {stock_name} {v:+d}: mean {mean:.3f} p99 {p99:.3f}")
        del scene
    job = bars["identity"]["frame"]
    with tempfile.TemporaryDirectory() as out:
        stock = STOCKS / bars["stocks"][0]
        prints = []
        for extra in ([], ["--dehaze", "0"]):
            probe.spike(sources()[job], out, stock, *bars["protocol"]["base"], *extra, "--print-out",
                        Path(out) / "print.npy", binary=binary)
            prints.append(np.load(Path(out) / "print.npy"))
    same = bool(np.array_equal(*prints))
    rows.append({"bar": f"identity {job} at 0", "stock": bars["stocks"][0], "measured": float(not same), "max": 0.0,
                 "pass": same})
    return rows


def emulate_spike(argv):
    """A stand-in for a spike that has --dehaze, built from today's spike and this prototype, so `spike` can be run
    end to end before the Swift stage exists: --dehaze V decodes with --scene-out, applies the recommended constants'
    stage (its field from that untouched scene) and renders the result through --scene-in with the same flags. It is
    the prototype's "auto" protocol when the flags hold --auto, and exactly the prototype under the explicit aim, so
    the bar must pass and parity must be 0."""
    if "--help" in argv or "-h" in argv:
        run = subprocess.run([str(SPIKE), "--help"], capture_output=True, text=True)
        print(run.stdout + "  --dehaze V       Dehaze -100...100, emulated by fit_dehaze.py through --scene-in")
        return 2
    args, value = list(argv), 0.0
    if "--dehaze" in args:
        i = args.index("--dehaze")
        value = float(args[i + 1])
        del args[i:i + 2]
    if value == 0:
        return subprocess.run([str(SPIKE), *args]).returncode
    c = Constants(**json.loads((VALIDATION / "constants.json").read_text())["candidates"]["dark-channel"]["constants"])
    with tempfile.TemporaryDirectory() as tmp:
        decode = list(args)
        if "--print-out" in decode:
            i = decode.index("--print-out")
            del decode[i:i + 2]
        subprocess.run([str(SPIKE), *decode, "--scene-out", f"{tmp}/scene.npy"], check=True, capture_output=True)
        scene = np.load(f"{tmp}/scene.npy")
        np.save(f"{tmp}/dehazed.npy", dehaze_frame(scene, value, Field(scene, c), c))
        del scene
        return subprocess.run([str(SPIKE), *args, "--scene-in", f"{tmp}/dehazed.npy"]).returncode


def command_spike(binary, frames=None, parity=True, log=print):
    require_dehaze_flag(binary)
    bars = json.loads(BARS.read_text())
    rows = score_spike(binary, bars, frames, parity, log)
    log("")
    log("| Bar | Stock | Measured | Allowed | Prototype | Result |")
    log("| --- | --- | ---: | ---: | ---: | --- |")
    for r in rows:
        log(f"| {r['bar']} | {r['stock']} | {r['measured']:.3f} | {r['max']:.3f} | "
            f"{r.get('prototype', float('nan')):.3f} | "
            f"{'subset' if r['pass'] is None else 'pass' if r['pass'] else 'FAIL'} |")
    failed = [r for r in rows if r["pass"] is False]
    subset = [r for r in rows if r["pass"] is None]
    log("")
    log(f"{'FAIL' if failed else 'NOT JUDGED' if subset else 'PASS'}: {len(rows) - len(failed) - len(subset)} of "
        f"{len(rows)} bars met, {len(subset)} a subset's value")
    return 1 if failed else 3 if subset else 0


# MARK: Stability on a Swift build (F2 section 10, which V2 leaves standing)

STABILITY_FRAMES = ["p-raw", "p-photo-hazy"]
# F2 section 10 measured Portra 400 alone and wrote "same" for Ektar 100. On Ektar 100 at -100 the prototype measured 1.713
# (p-raw) and 1.733 (p-photo-hazy) through stability-check, so that limit is the worse plus 5 %, as every other bar is set.
STABILITY_MAX = {"kodak-portra-400": {100: 0.8, -100: 1.5}, "kodak-ektar-100": {100: 0.8, -100: 1.82}}


def stability_rows(binary, bars, frames=STABILITY_FRAMES, log=print):
    """F2's stability bar on a build, at a quarter-size decode under the explicit aim: the build's print with --dehaze
    VALUE, whose stage makes its field from that decode, against this prototype's stage on the same decode with the
    full frame's field, both printed by `binary`. A build cannot be handed another decode's field, so the prototype
    carries the full frame's. The measure is `scale_check`'s estimate, mean CIE76 per quarter pixel between the two
    prints. For the prototype itself (stability-check) it is `scale_check`'s estimateDE. For a build it also holds the
    build's own difference from the prototype, which parity bounds at full size."""
    require_dehaze_flag(binary)
    c = Constants(**json.loads(Path(bars["constants"]).read_text())["candidates"]["dark-channel"]["constants"])
    rows = []
    for job in frames:
        raw = sources()[job]
        decode = STOCKS / bars["stocks"][0]
        f_full = Field(scene_io.scene_of(raw, decode, "--no-lens", binary=binary), c)
        quarter = scene_io.scene_of(raw, decode, "--no-lens", "--scale", 0.25, binary=binary)
        for stock_name in bars["stocks"]:
            stock = STOCKS / stock_name
            flags = aim_flags(raw, stock, binary)[0] + ["--no-lens", "--scale", "0.25"]
            for v, limit in STABILITY_MAX[stock_name].items():
                with tempfile.TemporaryDirectory() as out:
                    probe.spike(raw, out, stock, *flags, "--dehaze", str(v), "--print-out", Path(out) / "print.npy",
                                binary=binary)
                    own = lab_xyz(scene_io.print_xyz(np.load(Path(out) / "print.npy")))
                borrowed = lab_xyz(scene_io.print_xyz(scene_io.print_of(
                    raw, stock, dehaze(quarter, v, f_full, c).astype(np.float32), *flags, binary=binary)))
                e = np.linalg.norm(own - borrowed, axis=-1)
                mean, p99 = float(e.mean()), float(np.percentile(e, 99))
                rows.append({"bar": f"stability {job} {v:+d}", "stock": stock_name, "measured": mean, "max": limit,
                             "p99": p99, "pass": mean <= limit})
                log(f"  stability {job} {stock_name} {v:+d}: mean {mean:.3f} p99 {p99:.3f}")
        del quarter
    return rows


def command_stability(binary, frames=None, log=print):
    rows = stability_rows(binary, json.loads(BARS.read_text()), frames or STABILITY_FRAMES, log)
    log("")
    log("| Bar | Stock | Measured | Allowed | p99 | Result |")
    log("| --- | --- | ---: | ---: | ---: | --- |")
    for r in rows:
        log(f"| {r['bar']} | {r['stock']} | {r['measured']:.3f} | {r['max']:.3f} | {r['p99']:.3f} | "
            f"{'pass' if r['pass'] else 'FAIL'} |")
    failed = [r for r in rows if not r["pass"]]
    log("")
    log(f"{'FAIL' if failed else 'PASS'}: {len(rows) - len(failed)} of {len(rows)} bars met")
    return 1 if failed else 0


def stand_in_spike(folder):
    """A launcher for `emulate_spike`: today's spike with this prototype's stage behind --dehaze."""
    launcher = Path(folder) / "argent-spike"
    launcher.write_text(f"#!/bin/sh\nexec {sys.executable} -I {Path(__file__).resolve()} emulate-spike \"$@\"\n")
    launcher.chmod(0o755)
    return launcher


# MARK: Composition with the Light controls and Saturation (M6)

PAIRS = {"ex-1": "deh+50_ex-1", "ex+1": "deh+50_ex+1", "sat+50": "deh+50_sat+50", "hl-100": "deh+50_hl-100",
         "sh+100": "deh+50_sh+100"}


def composition(job="p-raw-combos", single_job="p-raw"):
    """Which order Lightroom composes Dehaze +50 with each partner in, told from its own renders in its linearised
    space: each order is built from the two single renders and scored against the pair's render (mean CIE76).

    - "dehaze first": the partner acts on the dehazed light. Exposure, Highlights and Shadows as their per-block gain
      from the single (their base read from the untouched frame); Saturation as its chroma factor in CIELAB.
    - "partner first": Dehaze acts on the partner's output, with the airlight and per-block gain of the Dehaze single
      (one airlight, M5): O = A + (P - A) G.
    - "sum": the two singles' CIELAB changes added, no interaction, for scale."""
    case = PhotoCase(single_job, [50])
    model, lin0, lab0 = case.model, case.lin0, case.lab0
    deh = model.unrender(case.out[50])
    m = case.valid & (case.out[50].min(-1) > 2e-4)
    A, _ = global_airlight_fit(lin0[m], deh[m])
    d = lin0 - A
    G = ((deh - A) * d).sum(-1) / np.maximum((d * d).sum(-1), 1e-12)
    lab_deh = lab_prophoto(case.out[50])
    out = {"airlight": A.tolist()}
    base_check = float(np.abs(blocks(lightroom(job)) - case.lr0).max())
    out["baseIdentical"] = base_check
    for partner, pair in PAIRS.items():
        part_path = export_path(single_job, f"saturation_+50") if partner == "sat+50" else export_path(job, partner)
        part = blocks(presence_stats.linear(part_path)[0])
        target = lab_prophoto(blocks(presence_stats.linear(export_path(job, pair))[0]))
        lin_part = model.unrender(part)
        lab_part = lab_prophoto(part)
        if partner == "sat+50":
            C0, Cp, Cd = (np.hypot(x[..., 1], x[..., 2]) for x in (lab0, lab_part, lab_deh))
            factor = np.where(C0 > 0.5, Cp / np.maximum(C0, 1e-6), 1.0)
            first = lab_deh.copy()
            first[..., 1:] *= factor[..., None]
        else:
            gain = (lin_part @ probe.PROPHOTO_Y) / np.maximum(lin0 @ probe.PROPHOTO_Y, 1e-9)
            first = lab_prophoto(model.render(deh * gain[..., None]))
        second = lab_prophoto(model.render(A + (lin_part - A) * G[..., None]))
        additive = lab0 + (lab_deh - lab0) + (lab_part - lab0)
        ok = m & (target[..., 0] > 0.5) & (target[..., 0] < 99.5)
        score = lambda p: float(np.linalg.norm(p - target, axis=-1)[ok].mean())  # noqa: E731
        out[partner] = {"dehazeFirst": score(first), "partnerFirst": score(second), "sum": score(additive),
                        "pairChange": float(np.linalg.norm(target - lab0, axis=-1)[ok].mean())}
    return out


# MARK: Noise and skies

def noise_gain(job, value=100, tile=64, c=None):
    """Lightroom's noise gain against its own gain: in 64-pixel tiles of the linearised luminance at full size, the
    rms of the pixel less its 5 x 5 mean (noise, where the tile is flat) after Dehaze over before, against the tile's
    gain about the airlight's luminance. Lightroom's noise reduction is off in every render. The candidate's is
    measured the same way on Lightroom's linearised base, so both see the same noise; its field is made from the base's
    4 x 4 blocks, which give the same field as the full frame up to the area resampling."""
    c = c or Constants()
    case = PhotoCase(job, [value])
    fld = Field(case.I, c)
    to2020 = np.linalg.inv(REC2020_TO_PROPHOTO).T
    base = lightroom(job)
    y_lr0 = case.model.inverse_curve(base @ probe.PROPHOTO_Y.astype(np.float32)).astype(np.float32)
    y_c0 = np.empty(base.shape[:2], np.float32)
    y_c1 = np.empty(base.shape[:2], np.float32)
    for y0 in range(0, base.shape[0], 512):
        y1 = min(base.shape[0], y0 + 512)
        band = case.model.unrender(base[y0:y1]) @ to2020
        t = fld.transmission(band, c, base.shape[:2], rows=(y0, y1))
        y_c0[y0:y1] = band @ Y2020
        y_c1[y0:y1] = dehaze(band, value, fld, c, t=t) @ Y2020
    del base
    y_lr1 = case.model.inverse_curve(lightroom(job, value) @ probe.PROPHOTO_Y.astype(np.float32)).astype(np.float32)
    A_y = float(fld.A @ Y2020)
    out = {"airlightY": A_y}
    for name, (ya, yb) in (("lightroom", (y_lr0, y_lr1)), ("candidate", (y_c0, y_c1))):
        stats = []
        for y in (ya, yb):
            hp = y - probe.box(y, 2)
            h, w = (y.shape[0] // tile) * tile, (y.shape[1] // tile) * tile
            stats.append((hp[:h, :w].reshape(h // tile, tile, w // tile, tile).std(axis=(1, 3)),
                          y[:h, :w].reshape(h // tile, tile, w // tile, tile).mean(axis=(1, 3))))
            del hp
        (s0, m0), (s1, m1) = stats
        G = (m1 - A_y) / np.minimum(m0 - A_y, -1e-9)
        rel = s0 / np.maximum(m0, 1e-9)
        ok = (rel < np.quantile(rel, 0.3)) & (m0 > 0.002) & (m0 < 0.9 * A_y) & (G > 0.2)
        ratio = s1[ok] / s0[ok]
        rows = []
        for lo, hi in ((0.2, 0.8), (0.8, 1.05), (1.05, 1.25), (1.25, 1.6), (1.6, 2.2), (2.2, 3.5), (3.5, 8)):
            sel = (G[ok] >= lo) & (G[ok] < hi)
            if sel.sum() >= 5:
                rows.append({"gain": [lo, hi], "tiles": int(sel.sum()), "medianGain": float(np.median(G[ok][sel])),
                             "noiseRatio": float(np.median(ratio[sel]))})
        out[name] = rows
    return out


def sky(job="p-photo-sky", value=100, c=None):
    """What Dehaze does to a clear blue sky: Lightroom's change and the candidate's (Lightroom's terms) over the sky's
    blocks (the frame's top quarter where CIELAB hue is 220 to 300 degrees and L* above 50)."""
    c = c or Constants()
    case = PhotoCase(job, [value])
    lab = case.lab0
    h = lab.shape[0]
    hue = np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360
    region = np.zeros(lab.shape[:2], bool)
    region[: h // 4] = True
    region &= (hue > 220) & (hue < 300) & (lab[..., 0] > 50) & (np.hypot(lab[..., 1], lab[..., 2]) > 5)
    fld = Field(case.I, c)
    t = fld.transmission(case.I, c)
    cand = case.candidate_change(c, value, fld)
    lr = case.change[value]
    after_lr, after_c = lab + lr, case.base + cand

    def describe(before, after):
        dh = (np.degrees(np.arctan2(after[..., 2], after[..., 1])) - np.degrees(np.arctan2(before[..., 2], before[..., 1])) + 180) % 360 - 180
        dC = np.hypot(after[..., 1], after[..., 2]) - np.hypot(before[..., 1], before[..., 2])
        return {"dL": float(np.median((after - before)[..., 0][region])), "dC": float(np.median(dC[region])),
                "dHue": float(np.median(dh[region])), "dE": float(np.median(np.linalg.norm(after - before, axis=-1)[region]))}

    return {"blocks": int(region.sum()), "medianT": float(np.median(t[region])), "lightroom": describe(lab, after_lr),
            "candidate": describe(case.base, after_c),
            "changeError": float(np.linalg.norm(cand - lr, axis=-1)[region].mean())}


# MARK: The chart measurements (M1 to M4)

HAZE_CHARTS = ["p-haze-none", "p-haze-neutral", "p-haze-blue", "p-haze-warm", "p-haze-two"]
STRIPS = 24


def strip_regression(job, value, rows=None, step=4, name=None):
    """M3: per strip of constant true transmission and per channel, Lightroom's linearised output regressed on its
    linearised base, O_c = alpha_c I_c + beta_c. Returns per strip the true t, the gain (mean alpha), the channels'
    spread, the implied airlight beta / (1 - alpha) where the gain is 10 % off 1, the smallest R2 and the sample count.
    `name` reads another render of `value` in the job (a repeat)."""
    W = presence_charts.HAZE_SIZE[0]
    base = lightroom(job)[::step, ::step]
    out_v = lightroom(job, value, name)[::step, ::step]
    if rows is not None:
        base, out_v = base[rows], out_v[rows]
    I, O = tone().unrender(base), tone().unrender(out_v)
    ok = (base.min(-1) > 3e-4) & (base.max(-1) < 0.97) & (out_v.min(-1) > 3e-4)
    x = np.arange(0, W, step) + 0.5
    result = []
    for b in range(STRIPS):
        cols = slice(b * W // STRIPS // step, (b + 1) * W // STRIPS // step)
        m = ok[:, cols]
        alpha, beta, r2 = [], [], []
        for c in range(3):
            i, o = I[:, cols, c][m], O[:, cols, c][m]
            a, b0 = np.polyfit(i, o, 1)
            alpha.append(a)
            beta.append(b0)
            r2.append(1 - np.var(o - a * i - b0) / np.var(o))
        alpha, beta = np.array(alpha), np.array(beta)
        gain = float(alpha.mean())
        implied = (beta / (1 - alpha)).tolist() if abs(1 - gain) > 0.1 else None
        result.append({"t": float(np.mean(1 - 0.8 * x[cols] / W)), "gain": gain, "spread": float(alpha.max() - alpha.min()),
                       "airlight": implied, "r2": float(min(r2)), "n": int(m.sum())})
    return result


def law_fit(strips):
    """ln G against ln t over the strips with t below 0.9: the slope (-kappa for Beer-Lambert) and intercept, and the
    R2 of a line through the strips; and the same for 1 / G against t (linear in t for the linear-t law)."""
    t = np.array([s["t"] for s in strips])
    g = np.array([s["gain"] for s in strips])
    m = (t < 0.9) & (g > 0)
    out = {}
    for name, x, y in (("lnG-lnT", np.log(t[m]), np.log(g[m])), ("invG-t", t[m], 1 / g[m])):
        slope, icpt = np.polyfit(x, y, 1)
        out[name] = {"slope": float(slope), "intercept": float(icpt), "r2": float(probe.r_squared(y, slope * x + icpt))}
    return out


def flats_and_ramp():
    """M1 and M2 on p-dehaze-flat: Lightroom's change of L*, a* and b* over the centre half of each flat field, and the
    ramp's linearised transfer as the gain about a white airlight, (1 - O) / (1 - I), at ten levels; and p-flat-grey's
    largest change of L*."""
    chart = presence_charts.CHARTS["p-dehaze-flat"]()
    I = chart.img.astype(np.float64) @ REC2020_TO_PROPHOTO.T
    base = lightroom("p-dehaze-flat")
    ramp_in = I[20:380].mean(axis=(0, 2))
    picks = [1200, 1500, 1800, 2000, 2200, 2400, 2600, 2800, 2900, 2950]
    out = {"flats": {}, "ramp": {}, "levels": [float(ramp_in[x]) for x in picks]}
    for v in CHART_VALUES:
        o = lightroom("p-dehaze-flat", v)
        ramp_out = tone().unrender(o[20:380].mean(0, keepdims=True))[0].mean(-1)
        out["ramp"][v] = [float((1 - ramp_out[x]) / (1 - ramp_in[x])) for x in picks]
        flats = []
        for r in chart.regions[1:]:
            x0, y0, x1, y1 = r["box"]
            sl = (slice(y0 + (y1 - y0) // 4, y1 - (y1 - y0) // 4), slice(x0 + (x1 - x0) // 4, x1 - (x1 - x0) // 4))
            lb, lo = lab_prophoto(base[sl].reshape(-1, 3).mean(0)), lab_prophoto(o[sl].reshape(-1, 3).mean(0))
            flats.append({"input": r.get("lch", r.get("stops")), "dLab": (lo - lb).tolist()})
        out["flats"][v] = flats
    grey0 = lab_prophoto(blocks(lightroom("p-flat-grey")))[..., 0]
    out["flatGreyMaxDL"] = max(float(np.abs(lab_prophoto(blocks(lightroom("p-flat-grey", v)))[..., 0] - grey0).max())
                               for v in CHART_VALUES)
    return out


def edge_profiles():
    """M4 and scale: on p-steps and p-steps-half, the linearised output over input across the rising edge of three
    bands, at offsets that are shares of the width; on p-locality and its half twin, the gain about white at the centre
    of each square (bright on dark, bright on mid) and output over input for the dark squares on bright."""
    out = {}
    offsets = [-0.3, -0.1, -0.04, -0.01, 0.01, 0.04, 0.1, 0.3]
    for job in ("p-steps", "p-steps-half"):
        chart = presence_charts.CHARTS[job]()
        H, W = chart.img.shape[:2]
        band = H // 9
        b = tone().unrender(lightroom(job)).mean(-1)
        rows = {}
        for v in (100, -100):
            o = tone().unrender(lightroom(job, v)).mean(-1)
            for k in (5, 7):
                y0, y1 = k * band + band // 4, (k + 1) * band - band // 4
                ratio = o[y0:y1].mean(0) / b[y0:y1].mean(0)
                rows[f"{v:+d} band {k}"] = [float(ratio[W // 3 + int(f * W)]) for f in offsets]
        out[job] = {"offsets": offsets, "ratio": rows}
    for job in ("p-locality", "p-locality-half"):
        layout = json.loads((EVIDENCE.parent.parent / "probe" / "chart-layouts" / f"{job}.json").read_text())
        b = tone().unrender(lightroom(job)).mean(-1)
        rows = {}
        for v in (100, 50, -50, -100):
            o = tone().unrender(lightroom(job, v)).mean(-1)
            for r in layout["regions"]:
                if r["kind"] != "square":
                    continue
                x0, y0, x1, y1 = r["box"]
                q = max(1, (x1 - x0) // 4)
                cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
                bi, oi = b[cy - q:cy + q, cx - q:cx + q].mean(), o[cy - q:cy + q, cx - q:cx + q].mean()
                value = oi / bi if r["row"] == "dark on bright" else (1 - oi) / (1 - bi)
                rows.setdefault(f"{v:+d} {r['row']}", []).append([r["sizePx"] / layout["width"], float(value)])
        out[job] = rows
    return out


def measure():
    """Every chart measurement, as one JSON-ready dict."""
    out = {"strips": {}, "law": {}}
    for job in HAZE_CHARTS:
        for v in CHART_VALUES:
            if job == "p-haze-two":
                h = presence_charts.HAZE_SIZE[1] // 4
                for half, rows in (("blue", slice(0, h // 2 - 20)), ("warm", slice(h // 2 + 20, None))):
                    out["strips"][f"{job} {half} {v:+d}"] = strip_regression(job, v, rows)
            else:
                out["strips"][f"{job} {v:+d}"] = strip_regression(job, v)
                out["law"][f"{job} {v:+d}"] = law_fit(out["strips"][f"{job} {v:+d}"])
    out["flats"] = flats_and_ramp()
    out["edges"] = edge_profiles()
    out["airlightByChart"] = {}
    for job in ("p-haze-neutral", "p-haze-blue", "p-haze-warm", "p-haze-two"):
        img, _ = chart_input(job)
        A = Field(img, Constants()).A @ REC2020_TO_PROPHOTO.T
        true = [presence_charts.AIRLIGHT[k] for k in (("blue", "warm") if job == "p-haze-two" else (job.split("-")[-1],))]
        out["airlightByChart"][job] = {"true": [(np.array(a) @ REC2020_TO_PROPHOTO.T).tolist() for a in true],
                                       "candidate": A.tolist()}
    return out


# MARK: Round 3's answers to F2's requests (V2)

# Every render of p-haze-neutral's settings at each value: round 3's ten values from one job, round 3's repeats and
# round 1's. Their bases are identical to the code; their Dehaze renders scatter (round 3's manifest).
NEUTRAL_RENDERS = {v: [("r-haze-neutral", None)] for v in RAW_VALUES}
for _v in (-100, -50, 25, 50, 100):
    NEUTRAL_RENDERS[_v] += [("r-again-haze-neutral", None), ("r-again-haze-neutral", "again_" + value_name(_v))]
for _v in CHART_VALUES:
    NEUTRAL_RENDERS[_v].append(("p-haze-neutral", None))


def crossfade_fit(t, G):
    """The crossfade's share s and power c that best give gains G at true transmissions t, G = 1 - s (1 - t^c), by
    least squares in ln G on a grid (s to 0.005, c to 0.125)."""
    s = np.linspace(0.005, 1.0, 200)[:, None, None]
    c = np.linspace(0.25, 12.0, 95)[None, :, None]
    model = np.maximum(1 - s * (1 - t[None, None, :] ** c), 1e-6)
    err = ((np.log(model) - np.log(np.maximum(G, 1e-6))[None, None, :]) ** 2).mean(-1)
    i, j = np.unravel_index(np.argmin(err), err.shape)
    return float(s[i, 0, 0]), float(c[0, j, 0]), float(np.sqrt(err[i, j]))


def chart_law():
    """The slider's law at every value on the neutral haze chart, per render (M3's strips against the true t):
    kappa = -d ln G / d ln t for positive values (strips with t under 0.9), the crossfade's share and power for
    negative ones. The spread over the renders of one value is the chart's own scatter in the law's units."""
    out = {}
    for v, renders in NEUTRAL_RENDERS.items():
        fits = []
        for job, name in renders:
            strips = strip_regression(job, v, name=name)
            t, G = np.array([s["t"] for s in strips]), np.array([s["gain"] for s in strips])
            label = f"{job} {name or value_name(v)}"
            if v > 0:
                lf = law_fit(strips)["lnG-lnT"]
                fits.append({"render": label, "kappa": -lf["slope"], "r2": lf["r2"]})
            else:
                s, c, rms = crossfade_fit(t, G)
                fits.append({"render": label, "share": s, "power": c, "rmsLnG": rms, "thickestGain": float(G[-1])})
        out[v] = fits
    return out


def smooth_law(c):
    """`c` with its slider tables replaced by one smooth law per side, through its knots at 50 and 100 (the knots that
    rest on eleven photographs), tabulated at every whole value:

    - positive: kappa(v) = K v / (v + h), the form that fits round 3's neutral chart at all ten values;
    - negative: share s(v) = S (|v| / 100)^q and power c(v) = C (|v| / 100)^r."""
    at = lambda values, table, v: float(np.interp(v, values, table))  # noqa: E731
    k50, k100 = at(c.kappa_values, c.kappa, 50), at(c.kappa_values, c.kappa, 100)
    rho = k50 / k100
    if not 0.5 < rho < 1:
        raise ValueError(f"kappa(50) / kappa(100) = {rho:.3f}: no K v / (v + h) passes through both knots")
    h = 5000 * (1 - rho) / (100 * rho - 50)
    K = k100 * (100 + h) / 100
    s50, s100 = at(c.haze_values, c.haze_share, 50), at(c.haze_values, c.haze_share, 100)
    c50, c100 = at(c.haze_values, c.haze_power, 50), at(c.haze_values, c.haze_power, 100)
    q, r = np.log2(s100 / s50), np.log2(c100 / c50)
    v = np.arange(0, 101)
    out = Constants(**asdict(c))
    out.kappa_values, out.kappa = v.tolist(), (K * v / (v + h)).tolist()
    out.haze_values, out.haze_share = v.tolist(), (s100 * (v / 100) ** q).tolist()
    out.haze_power = (c100 * (np.maximum(v, 1) / 100) ** r).tolist()
    return out, {"K": K, "h": h, "S": s100, "q": q, "C": c100, "r": r}


BETWEEN = [-75, -25, -10, 10, 25, 75]


def law_check(c, log=print):
    """F2's slider table against the smooth law at the values between its photo-backed knots: in Lightroom's terms on
    round 3's neutral chart (all ten values from one session) and on the probe raw, and through the film on the probe
    raw (F2's protocol), the only photograph rendered at those values."""
    smooth, params = smooth_law(c)
    laws = {"table": c, "smooth": smooth}
    chart = ChartCase("p-haze-neutral", RAW_VALUES, job="r-haze-neutral")
    raw = PhotoCase("p-raw", RAW_VALUES)
    out = {"params": params, "chart": {}, "rawLightroomTerms": {}}
    for name, law in laws.items():
        fc, fr = chart.field(law), raw.field(law)
        out["chart"][name] = {v: chart.error(law, v, fc) for v in RAW_VALUES}
        out["rawLightroomTerms"][name] = {v: raw.error(law, v, fr) for v in RAW_VALUES}
        log(f"  {name}: chart {np.round(list(out['chart'][name].values()), 2)}, "
            f"p-raw {np.round(list(out['rawLightroomTerms'][name].values()), 2)}")
    del chart, raw
    out["film"] = held_out_case("p-raw", laws, BETWEEN, floor=False, log=log)["stocks"]
    return out


WHITE_PATCH = (slice(1600, 1664), slice(4600, 4664))


def white_patch(c):
    """F2's request 4: r-haze-white's 0.95 patch, brighter than the airlight, at +50 and +100.

    - Lightroom: the share of the patch's pixels at code 65535 in every channel, and its base's largest linear value.
    - The candidate, with and without the fade above the airlight: the patch's gain about A and the share of its pixels
      the chart's tone model renders at 1.0 or over (the export's white).
    - Around the patch (a ring 4 to 128 pixels out): Lightroom's r-haze-white less r-haze-neutral at the same value,
      against two renders of r-haze-white (the scatter), and the candidate's same difference (whether the patch moves
      its surround through the field)."""
    img_w, _ = chart_input("r-haze-white")
    img_n, _ = chart_input("p-haze-neutral")
    ys, xs = WHITE_PATCH
    near = np.zeros(img_w.shape[:2], bool)
    near[ys.start - 128:ys.stop + 128, xs.start - 128:min(xs.stop + 128, img_w.shape[1])] = True
    near[ys.start - 4:ys.stop + 4, xs.start - 4:xs.stop + 4] = False
    out = {"airlight": {}, "values": {}}
    variants = {"fade": c, "no fade": Constants(**{**asdict(c), "fade": False})}
    fields = {"white": Field(img_w, c), "neutral": Field(img_n, c)}
    out["airlight"] = {k: f.A.tolist() for k, f in fields.items()}
    base_w = lightroom("r-haze-white")
    out["baseLargestLinear"] = float(base_w[WHITE_PATCH].max())
    lab_w0, lab_n0 = lab_prophoto(base_w[near]), lab_prophoto(lightroom("r-haze-neutral")[near])
    for v in (50, 100):
        lr_w = lightroom("r-haze-white", v)
        row = {"lightroomPatchAtWhite": float((lr_w[WHITE_PATCH].min(-1) >= 1).mean())}
        d_lr = (lab_prophoto(lr_w[near]) - lab_w0) - (lab_prophoto(lightroom("r-haze-neutral", v)[near]) - lab_n0)
        row["lightroomRingDE"] = float(np.linalg.norm(d_lr, axis=-1).mean())
        if v == 100:
            again = lab_prophoto(lightroom("r-again-haze-white", v)[near])
            row["lightroomRingScatterDE"] = float(np.linalg.norm(lab_prophoto(lr_w[near]) - again, axis=-1).mean())
        del lr_w
        for name, cv in variants.items():
            f = fields["white"]
            I = img_w[WHITE_PATCH]
            O = dehaze(I, v, f, cv, t=f.transmission(img_w[ys], cv, img_w.shape[:2], rows=(ys.start, ys.stop))[:, xs])
            rendered = tone().render(O @ REC2020_TO_PROPHOTO.T)
            gain = float(np.median((O - f.A) / (I - f.A)))
            ring = {}
            y0, y1 = ys.start - 128, ys.stop + 128
            for key, img in (("white", img_w), ("neutral", img_n)):
                fk, band = fields[key], img[y0:y1]
                o = dehaze(band, v, fk, cv, t=fk.transmission(band, cv, img.shape[:2], rows=(y0, y1)))
                ring[key] = lab_prophoto(tone().render(o[near[y0:y1]] @ REC2020_TO_PROPHOTO.T)) - lab_prophoto(
                    tone().render(band[near[y0:y1]] @ REC2020_TO_PROPHOTO.T))
            row[name] = {"patchGain": gain, "patchAtWhite": float((rendered.min(-1) >= 1).mean()),
                         "patchRenderedMin": float(rendered.min()),
                         "ringDE": float(np.linalg.norm(ring["white"] - ring["neutral"], axis=-1).mean())}
        out["values"][v] = row
    return out


def crop_check():
    """F2's request 2, rechecked from the exports' codes: each cropped +100 render against the same pixels of the
    uncropped +100 render of its session, beside two uncropped renders of the same settings (the chart scatter)."""
    def codes(job, name):
        return probe.read_tiff(export_path(job, name))[0]
    out = {}
    crop = codes("r-haze-neutral-crop", "dehaze_+100")
    whole = codes("r-haze-neutral", "dehaze_+100")[:, :crop.shape[1]]
    out["neutral"] = {"cropShape": list(crop.shape[:2]), "meanCodes": float(np.abs(crop - whole).mean() * 65535),
                      "maxCodes": float(np.abs(crop - whole).max() * 65535)}
    crop = codes("r-haze-two-crop", "dehaze_+100")
    full = codes("r-haze-two", "dehaze_+100")
    whole = full[full.shape[0] - crop.shape[0]:]
    again = codes("r-again-haze-two", "again_dehaze_+100")[full.shape[0] - crop.shape[0]:]
    out["two"] = {"cropShape": list(crop.shape[:2]), "meanCodes": float(np.abs(crop - whole).mean() * 65535),
                  "maxCodes": float(np.abs(crop - whole).max() * 65535),
                  "uncroppedScatterMeanCodes": float(np.abs(again - whole).mean() * 65535),
                  "dehazeMovesMeanCodes": float(np.abs(whole - codes("r-haze-two", "00_base")[full.shape[0] - crop.shape[0]:]).mean() * 65535)}
    return out


def hue(lab):
    return np.degrees(np.arctan2(lab[..., 2], lab[..., 1]))


def sky_floor(c, values=(50, 100), stocks=FILM_STOCKS, log=print):
    """How much of the field's miss on the sky photograph is Adobe Standard's hue turn, which Argent will not copy.
    Through the film (F2's protocol), the field's change against three targets: Lightroom's change under Adobe
    Standard (r-sky-standard, the same pixels as p-photo-sky's), the same with each sky block's hue turn replaced by the
    matrix render's at that block (r-sky-matrix, the photograph through a colour matrix alone), and the matrix
    render's own change. Over the sky's blocks (F2's rule) and over the whole frame."""
    raw = sources()["p-photo-sky"]
    std, mat = LightroomFrame("r-sky-standard", values), LightroomFrame("r-sky-matrix", values)
    scene = scene_io.scene_of(raw, STOCKS / stocks[0], "--no-lens", binary=SPIKE)
    k, corr = registration(blocks(scene), std.lab0)
    k_m, corr_m = registration(blocks(scene), mat.lab0)
    lab = std.lab0
    sky = np.zeros(lab.shape[:2], bool)
    sky[: lab.shape[0] // 4] = True
    sky &= ((hue(lab) % 360) > 220) & ((hue(lab) % 360) < 300) & (lab[..., 0] > 50) & (np.hypot(lab[..., 1], lab[..., 2]) > 5)
    fld = Field(scene, c)
    out = {"registration": [k, corr, k_m, corr_m], "skyBlocks": int(sky.sum()), "lightroom": {}, "stocks": {}}
    targets = {}
    for v in values:
        turn = lambda f: (hue(f.lab0 + f.change[v]) - hue(f.lab0) + 180) % 360 - 180  # noqa: E731
        after = std.lab0 + std.change[v]
        C1, h = np.hypot(after[..., 1], after[..., 2]), np.radians(hue(std.lab0) + turn(mat))
        fixed = np.where(sky[..., None], np.stack([after[..., 0], C1 * np.cos(h), C1 * np.sin(h)], -1), after)
        targets[v] = {"Adobe Standard": std.change[v], "Standard, matrix hue turn": fixed - std.lab0,
                      "matrix": mat.change[v]}
        out["lightroom"][v] = {name: {"dL": float(np.median(f.change[v][..., 0][sky])),
                                      "dC": float(np.median((np.hypot(*(f.lab0 + f.change[v])[..., 1:].transpose(2, 0, 1))
                                                             - np.hypot(*f.lab0[..., 1:].transpose(2, 0, 1)))[sky])),
                                      "dHue": float(np.median(turn(f)[sky]))} for name, f in (("standard", std), ("matrix", mat))}
    for stock_name in stocks:
        stock = STOCKS / stock_name
        flags = aim_flags(raw, stock)[0] + ["--no-lens"]
        base = print_blocks(raw, stock, scene, flags, k)
        valid = (lab[..., 0] > 0.5) & (lab[..., 0] < 99.5) & (base[..., 0] > 0.5) & (base[..., 0] < 99.5)
        rows = {}
        for v in values:
            out_v = dehaze_frame(scene, v, fld, c)
            dA = print_blocks(raw, stock, out_v, flags, k) - base
            del out_v
            after = base + dA
            rows[v] = {"field": {"dL": float(np.median(dA[..., 0][sky & valid])),
                                 "dC": float(np.median((np.hypot(after[..., 1], after[..., 2]) - np.hypot(base[..., 1], base[..., 2]))[sky & valid])),
                                 "dHue": float(np.median(((hue(after) - hue(base) + 180) % 360 - 180)[sky & valid]))}}
            for name, target in targets[v].items():
                e = np.linalg.norm(dA - target, axis=-1)
                rows[v][name] = {"sky": float(e[sky & valid].mean()), "frame": float(e[valid].mean())}
            log(f"  sky {stock_name} {v:+d}: {rows[v]}")
        out["stocks"][stock_name] = rows
    del scene
    return out


# MARK: Preview against develop (scale)

def uv_prime(rgb2020):
    xyz = np.asarray(rgb2020, dtype=np.float64) @ presence_charts.REC2020_TO_XYZ.T
    d = xyz[..., 0] + 15 * xyz[..., 1] + 3 * xyz[..., 2]
    return np.stack([4 * xyz[..., 0] / d, 9 * xyz[..., 1] / d], axis=-1)


def scale_check(job, stock_name, c, values=(100, -100), log=print):
    """The stage at a quarter-size decode (the preview) against full size (the develop), on one source and stock:

    - the estimate: the airlight's relative difference per channel and in u'v', and the transmission at the quarter's
      pixels against the full frame's 4 x 4 block means of its own per-pixel transmission (p50 and p99 of |difference|);
    - its effect in the metric's unit: the quarter render's change with its own field against the same render with
      the full frame's field (only the estimate differs), mean CIE76 and L* rms;
    - the whole preview against the develop: the quarter render's change against the full print's 4 x 4 blocks."""
    raw, stock = sources()[job], STOCKS / stock_name
    flags, _, _ = aim_flags(raw, stock)
    flags = flags + ["--no-lens"]
    full = scene_io.scene_of(raw, stock, *flags, binary=SPIKE)
    f_full = Field(full, c)
    shape = full.shape[:2]
    h4 = shape[0] - shape[0] % 4
    t_full = np.concatenate([blocks(f_full.transmission(full[y:min(y + 512, h4)].astype(np.float64), c, shape,
                                                        rows=(y, min(y + 512, h4)))[..., None])[..., 0]
                             for y in range(0, h4, 512)], axis=0)
    p_full0 = blocks(scene_io.print_xyz(scene_io.print_of(raw, stock, full, *flags, binary=SPIKE)))
    d_full = {}
    for v in values:
        out = dehaze_frame(full, v, f_full, c)
        d_full[v] = lab_xyz(blocks(scene_io.print_xyz(scene_io.print_of(raw, stock, out, *flags, binary=SPIKE)))) - lab_xyz(p_full0)
        del out
    del full
    quarter = scene_io.scene_of(raw, stock, *flags, "--scale", 0.25, binary=SPIKE)
    f_q = Field(quarter, c)
    t_q = f_q.transmission(quarter.astype(np.float64), c)
    h, w = min(t_q.shape[0], t_full.shape[0]), min(t_q.shape[1], t_full.shape[1])
    dt = np.abs(t_q[:h, :w] - t_full[:h, :w])
    q0 = lab_xyz(scene_io.print_xyz(scene_io.print_of(raw, stock, quarter, *flags, "--scale", 0.25, binary=SPIKE)))
    out = {"airlightFull": f_full.A.tolist(), "airlightQuarter": f_q.A.tolist(),
           "airlightRelative": (f_q.A / f_full.A - 1).tolist(),
           "airlightUV": float(np.linalg.norm(uv_prime(f_q.A) - uv_prime(f_full.A))),
           "transmissionP50": float(np.median(dt)), "transmissionP99": float(np.percentile(dt, 99)), "values": {}}
    for v in values:
        own = lab_xyz(scene_io.print_xyz(scene_io.print_of(raw, stock, dehaze(quarter, v, f_q, c).astype(np.float32),
                                                             *flags, "--scale", 0.25, binary=SPIKE))) - q0
        borrowed = lab_xyz(scene_io.print_xyz(scene_io.print_of(raw, stock, dehaze(quarter, v, f_full, c).astype(np.float32),
                                                                  *flags, "--scale", 0.25, binary=SPIKE))) - q0
        e_est = np.linalg.norm(own - borrowed, axis=-1)
        a, b = own[:h, :w], d_full[v][:h, :w]
        e_all = np.linalg.norm(a - b, axis=-1)
        out["values"][v] = {"estimateDE": float(e_est.mean()), "estimateDEp99": float(np.percentile(e_est, 99)),
                            "estimateLRms": float(np.sqrt(np.mean((own - borrowed)[..., 0] ** 2))),
                            "previewDE": float(e_all.mean()), "previewLRms": float(np.sqrt(np.mean((a - b)[..., 0] ** 2)))}
        log(f"  {job} {stock_name} {v:+d}: {out['values'][v]}")
    log(f"  {job} airlight full {np.round(f_full.A, 4)} quarter {np.round(f_q.A, 4)} u'v' {out['airlightUV']:.5f}, "
        f"|dt| p50 {out['transmissionP50']:.4f} p99 {out['transmissionP99']:.4f}")
    return out


# MARK: The commands

PHOTO_JOBS = ["p-raw", "p-photo-hazy", "p-photo-sky", "p-photo-foliage", "p-photo-texture", "p-photo-flat",
              "p-photo-contrast", "p-photo-night", "p-photo-iso", "p-photo-saturated", "p-photo-skin"]
LR_CHARTS = ["p-haze-neutral", "p-haze-blue", "p-haze-warm", "p-haze-two", "p-haze-none", "p-dehaze-flat",
             "p-locality", "p-steps"]
# The field constants tried, each scored at +50 and +100 with its best kappa (the photos' mean change error).
FIELD_GRID = {
    "literature": {},
    "airlight top 0.01 %": {"airlight_quantile": 0.9999},
    "airlight brightest half": {"airlight_bright": 0.5},
    "airlight radius 0.004": {"airlight_radius": 0.004},
    "dark radius 0.006, erosion": {"dark_radius": 0.006, "opening": False},
    "dark radius 0.025": {"dark_radius": 0.025},
    "guide radius 0.06": {"guide_radius": 0.06},
    "guide radius 0.12": {"guide_radius": 0.12},
    "guide radius 0.06, dark radius 0.006, erosion": {"guide_radius": 0.06, "dark_radius": 0.006, "opening": False},
    "guide radius 0.06, epsilon 2": {"guide_radius": 0.06, "epsilon": 2.0},
    "epsilon 4": {"epsilon": 4.0},
    "omega 0.85": {"omega": 0.85},
}


def load_constants():
    data = json.loads((EVIDENCE / "constants.json").read_text())
    return {name: Constants(**entry["constants"]) for name, entry in data["candidates"].items()}


def photo_cases(k=8, log=print):
    cases = []
    for job in PHOTO_JOBS:
        cases.append(PhotoCase(job, RAW_VALUES if job == "p-raw" else PHOTO_VALUES, k=k))
        log(f"  loaded {job} (render model's base error, median Delta E {cases[-1].base_error:.2f})")
    return cases


def kappa_score(cases, c, values=(50, 100)):
    """Mean change error over the cases at each value, with the best single kappa for it."""
    fits = fit_law(cases, c, list(values), log=lambda *_: None)
    return {v: (fits[v]["kappa"], fits[v]["error"]) for v in values}


def command_fit(log=print):
    t0 = time.time()
    cases = photo_cases(log=log)
    grid = {}
    for name, overrides in FIELD_GRID.items():
        grid[name] = kappa_score(cases, Constants(**overrides))
        log(f"  field {name}: " + ", ".join(f"{v:+d} kappa {k:.3f} error {e:.3f}" for v, (k, e) in grid[name].items()))
    best = min(grid, key=lambda n: np.mean([e for _, e in grid[n].values()]))
    log(f"  chosen field: {best}")
    base = Constants(**FIELD_GRID[best])
    laws = {}
    for law in ("crossfade", "power", "mirror"):
        trial = Constants(**{**asdict(base), "negative_law": law})
        laws[law] = fit_law(cases, trial, [-100, -75, -50, -25, -10], log=log)
    negative = min(laws, key=lambda n: np.mean([f["error"] for f in laws[n].values()]))
    positive_fits = {}
    for law in ("beer-lambert", "linear-t"):
        trial = Constants(**{**asdict(base), "positive_law": law})
        positive_fits[law] = fit_law(cases, trial, [10, 25, 50, 75, 100], log=log)
    positive = min(positive_fits, key=lambda n: np.mean([f["error"] for f in positive_fits[n].values()]))
    recommended = with_law(Constants(**{**asdict(base), "negative_law": negative, "positive_law": positive}),
                           {**positive_fits[positive], **laws[negative]})
    veil_grid = {}
    for q in (0.001, 0.01, 0.05):
        trial = Constants(**{**asdict(base), "method": "global-veil", "veil_quantile": q})
        veil_grid[q] = kappa_score(cases, trial)
        log(f"  veil quantile {q}: " + ", ".join(f"{v:+d} kappa {k:.3f} error {e:.3f}" for v, (k, e) in veil_grid[q].items()))
    q = min(veil_grid, key=lambda q: np.mean([e for _, e in veil_grid[q].values()]))
    veil_base = Constants(**{**asdict(base), "method": "global-veil", "veil_quantile": q, "negative_law": negative,
                             "positive_law": positive})
    veil_fits = fit_law(cases, veil_base, [10, 25, 50, 75, 100, -100, -75, -50, -25, -10], log=log)
    veil = with_law(veil_base, veil_fits)
    result = {
        "made": time.strftime("%Y-%m-%d %H:%M"), "script": "scripts/lightroom-probe/fit_dehaze.py fit",
        "data": "Lightroom's renders of the probe raw and ten photographs (8 x 8 blocks), Lightroom's terms: each "
                "candidate's change through the photo's render model against Lightroom's, mean CIE76",
        "fieldGrid": {n: {str(v): {"kappa": k, "error": e} for v, (k, e) in g.items()} for n, g in grid.items()},
        "chosenField": best,
        "negativeLaws": {n: {str(v): f for v, f in fits.items()} for n, fits in laws.items()},
        "positiveLaws": {n: {str(v): f for v, f in fits.items()} for n, fits in positive_fits.items()},
        "veilGrid": {str(q): {str(v): {"kappa": k, "error": e} for v, (k, e) in g.items()} for q, g in veil_grid.items()},
        "veilFits": {str(v): f for v, f in veil_fits.items()},
        "candidates": {"dark-channel": {"constants": asdict(recommended)}, "global-veil": {"constants": asdict(veil)}},
        "seconds": round(time.time() - t0),
    }
    (EVIDENCE / "constants.json").write_text(json.dumps(result, indent=1, default=float))
    log(f"wrote {EVIDENCE / 'constants.json'} in {time.time() - t0:.0f} s")


def command_photos(log=print):
    """Lightroom's terms with the fitted constants: every photo at 4 x 4 blocks and every chart, per candidate and
    value; M5 on each photo; composition; noise and skies."""
    candidates = load_constants()
    out = {"photos": {}, "charts": {}, "m5": {}}
    for job in PHOTO_JOBS:
        case = PhotoCase(job, RAW_VALUES if job == "p-raw" else PHOTO_VALUES)
        row = {"baseModelError": case.base_error}
        for name, c in candidates.items():
            fld = case.field(c)
            row[name] = {v: case.error(c, v, fld) for v in case.change}
            row[name + " airlight"] = fld.A.tolist()
        row["reach"] = {v: float(np.linalg.norm(case.change[v], axis=-1)[case.valid].mean()) for v in case.change}
        m5 = {}
        c = candidates["dark-channel"]
        fld = case.field(c)
        t = fld.transmission(case.I, c)
        for v in (100, 50, -50, -100):
            O = case.model.unrender(case.out[v])
            m = case.valid & (case.out[v].min(-1) > 2e-4)
            A, G = global_airlight_fit(case.lin0[m], O[m])
            pred = A + (case.lin0[m] - A) * G[:, None]
            d_lr = lab_prophoto(case.out[v][m]) - case.lab0[m]
            d_md = lab_prophoto(case.model.render(pred)) - case.lab0[m]
            r2 = 1 - ((d_lr - d_md) ** 2).sum() / ((d_lr - d_lr.mean(0)) ** 2).sum()
            chroma = lambda L: np.hypot(L[..., 1], L[..., 2])  # noqa: E731
            extra = (chroma(case.lab0[m] + d_lr) - chroma(case.lab0[m] + d_md))
            ok = np.abs(G - 1) < 5
            x, y = -np.log(t[m][ok]), np.log(np.clip(G[ok], 0.02, 50))
            slope, icpt = np.polyfit(x, y, 1)
            m5[v] = {"airlightLightroom": A.tolist(), "airlightCandidate": (fld.A @ REC2020_TO_PROPHOTO.T).tolist(),
                     "r2Change": float(r2), "extraChromaMedian": float(np.median(extra)), "extraChromaMean": float(extra.mean()),
                     "lnGslope": float(slope), "lnGintercept": float(icpt), "lnGr2": float(np.corrcoef(x, y)[0, 1] ** 2)}
        out["m5"][job] = m5
        out["photos"][job] = row
        log(f"  {job}: " + "; ".join(f"{n} " + " ".join(f"{v:+d}:{e:.2f}" for v, e in row[n].items()) for n in candidates))
        del case
    for name in LR_CHARTS:
        case = ChartCase(name)
        out["charts"][name] = {n: {v: case.error(c, v) for v in CHART_VALUES} for n, c in candidates.items()}
        out["charts"][name]["reach"] = {v: float(np.linalg.norm(case.change[v], axis=-1).mean()) for v in CHART_VALUES}
        log(f"  {name}: " + "; ".join(f"{n} " + " ".join(f"{v:+d}:{e:.2f}" for v, e in out['charts'][name][n].items())
                                       for n in candidates))
        del case
    out["composition"] = composition()
    log(f"  composition: {out['composition']}")
    out["noise"] = {job: noise_gain(job, 100, c=candidates["dark-channel"]) for job in ("p-photo-hazy", "p-photo-iso", "p-photo-night")}
    out["sky"] = {job: sky(job, 100, candidates["dark-channel"]) for job in ("p-photo-sky", "p-photo-hazy")}
    log(f"  noise: {out['noise']}\n  sky: {out['sky']}")
    (EVIDENCE / "photos.json").write_text(json.dumps(out, indent=1, default=float))


def command_film(log=print):
    candidates = load_constants()
    out = {}
    for job in FILM_SOURCES:
        for stock in FILM_STOCKS:
            values = RAW_VALUES if job == "p-raw" else PHOTO_VALUES
            r = film_case(job, stock, candidates, values, oracle=True, log=log)
            out[f"{job} {stock}"] = {"aim": r["aim"], "rows": {f"{k[0]} {k[1]}" if not isinstance(k[1], int) else f"{k[0]} {k[1]:+d}": v
                                                              for k, v in r["rows"].items()}}
            (EVIDENCE / "film.json").write_text(json.dumps(out, indent=1, default=float))
    r = film_case("p-raw", FILM_STOCKS[0], {"dark-channel": candidates["dark-channel"]}, [100, 50, -50, -100],
                  oracle=False, auto=True, log=log)
    out["auto p-raw kodak-portra-400"] = {"rows": {f"{k[0]} {k[1]}" if not isinstance(k[1], int) else f"{k[0]} {k[1]:+d}": v
                                                   for k, v in r["rows"].items()}}
    (EVIDENCE / "film.json").write_text(json.dumps(out, indent=1, default=float))


def scaled_law(c, value, m):
    """`c` with its law at `value` multiplied by m: kappa for positive values, the haze share for negative ones."""
    out = Constants(**asdict(c))
    if value > 0:
        out.kappa = [k * m for k in c.kappa]
    else:
        out.haze_share = [min(1.0, s * m) for s in c.haze_share]
    return out


def calibrate(c, jobs=("p-raw", "p-photo-hazy"), values=(100, -100), log=print):
    """Per stock and sign, the one multiplier on the slider law that minimises the mean L* rms of the change through
    the film over `jobs` (the per-stock calibration the literature note proposes; scored only on these sources)."""
    out = {}
    for stock_name in FILM_STOCKS:
        stock = STOCKS / stock_name
        prepared = []
        for job in jobs:
            raw = sources()[job]
            flags = aim_flags(raw, stock)[0] + ["--no-lens"]
            lr0 = lab_prophoto(blocks(lightroom(job)))
            shape = (lr0.shape[0] * probe.BLOCK, lr0.shape[1] * probe.BLOCK)
            scene = scene_io.scene_of(raw, stock, *flags, binary=SPIKE)
            base = print_lab(raw, stock, scene, flags, shape)
            valid = (lr0[..., 0] > 0.5) & (lr0[..., 0] < 99.5) & (base[..., 0] > 0.5) & (base[..., 0] < 99.5)
            prepared.append((job, raw, flags, scene, base, valid, shape, lr0, Field(scene, c)))
        for value in values:
            lr = {job: lab_prophoto(blocks(lightroom(job, value))) - lr0 for job, *_, lr0, _ in prepared}

            def cost(m):
                total = []
                for job, raw, flags, scene, base, valid, shape, lr0, fld in prepared:
                    cm = scaled_law(c, value, m)
                    dA = print_lab(raw, stock, dehaze_frame(scene, value, fld, cm), flags, shape) - base
                    total.append(change_scores(dA, lr[job], base[..., 0], valid)["lRms"])
                log(f"  calibrate {stock_name} {value:+d} x{m:.3f}: L* rms {np.round(total, 2).tolist()}")
                return float(np.mean(total))
            m = golden(cost, 0.4, 1.6, tol=0.06)
            out[f"{stock_name} {value:+d}"] = {"multiplier": m, "lRms": cost(m), "lRmsUncalibrated": cost(1.0)}
        del prepared
    return out


def auto_contamination(c, job="p-raw", stock_name=FILM_STOCKS[0], values=(100, -100)):
    """What `--auto` would add to the stage's change through `--scene-in` (fit-common fact 2): the change rendered with
    `--auto` (its tone step reading the dehazed scene) less the change rendered with the explicit aim (no tone step),
    in L* and CIE76 over 4 x 4 blocks. It holds the contamination and the tone step's own legitimate effect on the
    change, so the contamination is at most this size."""
    raw, stock = sources()[job], STOCKS / stock_name
    explicit = aim_flags(raw, stock)[0] + ["--no-lens"]
    auto = ["--auto", "--no-lens"]
    scene = scene_io.scene_of(raw, stock, *explicit, binary=SPIKE)
    shape = scene.shape[:2]
    fld = Field(scene, c)
    base_e, base_a = print_lab(raw, stock, scene, explicit, shape), print_lab(raw, stock, scene, auto, shape)
    out = {}
    for v in values:
        o = dehaze_frame(scene, v, fld, c)
        d = (print_lab(raw, stock, o, auto, shape) - base_a) - (print_lab(raw, stock, o, explicit, shape) - base_e)
        out[v] = {"medianDL": float(np.median(d[..., 0])), "p5": float(np.percentile(d[..., 0], 5)),
                  "p95": float(np.percentile(d[..., 0], 95)), "meanAbs": float(np.abs(d[..., 0]).mean()),
                  "dE": float(np.linalg.norm(d, axis=-1).mean())}
    return out


def command_negative(log=print):
    """The negative side's alternatives to the recommended law: the crossfade in gamma-encoded light fitted in Lightroom's
    terms, then it and the sign-turned law (fitted by `fit`) through the film at -50 and -100 on the five sources."""
    data = json.loads((EVIDENCE / "constants.json").read_text())
    c = Constants(**data["candidates"]["dark-channel"]["constants"])
    cases = photo_cases(log=log)
    gamma = fit_law(cases, Constants(**{**asdict(c), "negative_space": "gamma"}), [-100, -75, -50, -25, -10], log=log)
    del cases
    variants = {
        "gamma crossfade": with_law(Constants(**{**asdict(c), "negative_space": "gamma"}), gamma),
        "sign-turned": with_law(Constants(**{**asdict(c), "negative_law": "power"}),
                                {int(v): f for v, f in data["negativeLaws"]["power"].items()}),
    }
    out = {"gammaFits": {str(v): f for v, f in gamma.items()}, "film": {}}
    for job in FILM_SOURCES:
        for stock in FILM_STOCKS:
            r = film_case(job, stock, variants, [-100, -50], oracle=False, log=log)
            out["film"][f"{job} {stock}"] = {f"{k[0]} {k[1]}": v for k, v in r["rows"].items()}
            (EVIDENCE / "negative.json").write_text(json.dumps(out, indent=1, default=float))


def command_scale(log=print):
    c = load_constants()["dark-channel"]
    out = {f"{job} {stock}": scale_check(job, stock, c, log=log)
           for job in ("p-raw", "p-photo-hazy") for stock in FILM_STOCKS[:1]}
    (EVIDENCE / "scale.json").write_text(json.dumps(out, indent=1, default=float))


def command_report(log=print):
    """The report's score tables, printed as markdown from film.json and photos.json."""
    film = json.loads((EVIDENCE / "film.json").read_text())
    log("Through Argent's film: change error (mean CIE76 of Argent's change less Lightroom's), L* rms, curve rms; "
        "per source and stock, mean over values")
    log("")
    log("| Source | Stock | Values | Dark channel | Global veil | Floor (Lightroom's change copied onto the scene) | Lightroom's reach |")
    log("| --- | --- | --- | --- | --- | --- | ---: |")
    totals = {}
    for key, entry in film.items():
        if key.startswith("auto"):
            continue
        job, stock = key.split(" ")
        rows = entry["rows"]
        values = sorted({int(k.split(" ")[-1]) for k in rows if k.split(" ")[-1].lstrip("+-").isdigit()})
        cells = []
        for name in ("dark-channel", "global-veil", "oracle"):
            r = [rows[f"{name} {v:+d}"] for v in values]
            m = {k: float(np.mean([x[k] for x in r])) for k in ("change", "lRms", "curve")}
            totals.setdefault((stock, name), []).append(m)
            cells.append(f"{m['change']:.2f} / {m['lRms']:.2f} / {m['curve']:.2f}")
        reach = np.mean([rows[f"oracle {v:+d}"]["reach"] for v in values])
        log(f"| {job} | {stock} | {len(values)} | " + " | ".join(cells) + f" | {reach:.2f} |")
    log("")
    log("| Stock | Candidate | Change error | L* rms | Curve rms | Runs |")
    log("| --- | --- | ---: | ---: | ---: | ---: |")
    for (stock, name), ms in sorted(totals.items()):
        log(f"| {stock} | {name} | {np.mean([m['change'] for m in ms]):.2f} | {np.mean([m['lRms'] for m in ms]):.2f} | "
            f"{np.mean([m['curve'] for m in ms]):.2f} | {len(ms)} |")
    for key, entry in film.items():
        if not key.startswith("auto"):
            continue
        base = film["p-raw kodak-portra-400"]["rows"]
        log("")
        log(f"With --auto (the tone step reading the dehazed scene), {key[5:]}:")
        for k, r in entry["rows"].items():
            if k.split(" ")[-1].lstrip("+-").isdigit():
                b = base[k]
                log(f"  {k}: change {r['change']:.2f} (explicit aim {b['change']:.2f}), L* rms {r['lRms']:.2f} "
                    f"({b['lRms']:.2f}), curve {r['curve']:.2f} ({b['curve']:.2f})")


def main():
    if sys.argv[1:2] == ["emulate-spike"]:
        sys.exit(emulate_spike(sys.argv[2:]))
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["measure", "fit", "photos", "film", "negative", "auto", "scale",
                                                 "calibrate", "report", "held-out", "in-sample", "answers", "law", "summary", "bar", "spike", "variant", "airlights", "airlight-screen",
                                                 "spike-check", "stability", "stability-check"])
    parser.add_argument("--frames", nargs="*", help="held-out or in-sample: only these jobs")
    parser.add_argument("--fresh", action="store_true", help="held-out or in-sample: rescore frames already scored")
    parser.add_argument("--binary", default=str(SPIKE), help="spike: the argent-spike to score")
    parser.add_argument("--no-parity", action="store_true", help="spike: skip parity and identity")
    parser.add_argument("--name", choices=sorted(VARIANTS), help="variant: which of F2's constants to change")
    args = parser.parse_args()
    log = lambda *a: print(*a, flush=True)  # noqa: E731
    if args.command in ("held-out", "in-sample"):
        VALIDATION.mkdir(parents=True, exist_ok=True)
        jobs = HELD_OUT if args.command == "held-out" else FILM_SOURCES
        run_frames(VALIDATION / f"{args.command}.json", args.frames or jobs, load_constants(), HELD_OUT_VALUES,
                   fresh=args.fresh, log=log)
        return
    if args.command == "variant":
        slug = args.name.replace(" ", "-")
        c, fits = variant_constants(args.name, log)
        jobs = args.frames or [j for j in HELD_OUT if HALF[j] == "B"]
        frames = run_frames(VALIDATION / f"variant-{slug}-frames.json", jobs, {args.name: c}, HELD_OUT_VALUES,
                            fresh=args.fresh, floor=False, log=log)
        held = json.loads((VALIDATION / "held-out.json").read_text())
        test = [j for j in jobs if HALF[j] == "B"]
        result = {"name": args.name, "overrides": VARIANTS[args.name][0](), "constants": asdict(c), "fits": fits,
                  "testHalf": compare_on(held, frames, test, args.name, log)}
        if any(HALF[j] == "A" for j in jobs):
            result["fitHalf"] = compare_on(held, frames, [j for j in jobs if HALF[j] == "A"], args.name, log)
        (VALIDATION / f"variant-{slug}.json").write_text(json.dumps(result, indent=1, default=float))
        log(f"adopt on half B: {result['testHalf']['adopt']}")
        return
    if args.command == "bar":
        held = json.loads((VALIDATION / "held-out.json").read_text())
        bars = make_bars(held, args.frames or HELD_OUT, VALIDATION / "constants.json")
        BARS.write_text(json.dumps(bars, indent=1, default=float))
        log(json.dumps({k: bars[k] for k in ("fidelity", "parity", "identity")}, indent=1, default=float))
        return
    if args.command == "spike":
        sys.exit(command_spike(Path(args.binary), args.frames, not args.no_parity, log))
    if args.command == "spike-check":
        with tempfile.TemporaryDirectory() as tmp:
            launcher = Path(tmp) / "argent-spike"
            launcher.write_text(f"#!/bin/sh\nexec {sys.executable} -I {Path(__file__).resolve()} emulate-spike \"$@\"\n")
            launcher.chmod(0o755)
            sys.exit(command_spike(launcher, args.frames or ["r-photo-fog-woods"], not args.no_parity, log))
    if args.command == "stability":
        sys.exit(command_stability(Path(args.binary), args.frames, log))
    if args.command == "stability-check":
        with tempfile.TemporaryDirectory() as tmp:
            sys.exit(command_stability(stand_in_spike(tmp), args.frames, log))
    if args.command == "summary":
        held = json.loads((VALIDATION / "held-out.json").read_text())
        inside = json.loads((VALIDATION / "in-sample.json").read_text())
        (VALIDATION / "summary.json").write_text(json.dumps(summarise(held, inside, log), indent=1, default=float))
        return
    if args.command == "airlight-screen":
        result = airlight_screen(log=log)
        (VALIDATION / "airlight-screen.json").write_text(json.dumps(result, indent=1, default=float))
        log(f"best gain in the fit: {result['best']}")
        return
    if args.command == "airlights":
        c = load_constants()["dark-channel"]
        result = {}
        for job in args.frames or (PHOTO_JOBS + HELD_OUT):
            result[job] = airlights(job, HELD_OUT_VALUES if job in HELD_OUT else PHOTO_VALUES, c)
            r = result[job]
            log(f"  {job}: rule {np.round(r['rule'], 3)}, " + ", ".join(
                f"{v}: Lightroom {np.round(r[v]['lightroom'], 3)} ratio {r[v]['luminanceRatio']:.2f} u'v' {r[v]['uv']:.4f}"
                for v in ("-100", "100") if v in r))
        (VALIDATION / "airlights.json").write_text(json.dumps(result, indent=1, default=float))
        return
    if args.command == "law":
        result = law_check(load_constants()["dark-channel"], log=log)
        (VALIDATION / "law.json").write_text(json.dumps(result, indent=1, default=float))
        return
    if args.command == "answers":
        c = load_constants()["dark-channel"]
        result = {"chartLaw": chart_law(), "whitePatch": white_patch(c), "crop": crop_check(), "sky": sky_floor(c, log=log)}
        (VALIDATION / "answers.json").write_text(json.dumps(result, indent=1, default=float))
        log(json.dumps({k: v for k, v in result.items() if k != "chartLaw"}, indent=1, default=float))
        return
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    if args.command == "measure":
        (EVIDENCE / "measure.json").write_text(json.dumps(measure(), indent=1, default=float))
    elif args.command == "fit":
        command_fit(log)
    elif args.command == "photos":
        command_photos(log)
    elif args.command == "film":
        command_film(log)
    elif args.command == "negative":
        command_negative(log)
    elif args.command == "auto":
        result = auto_contamination(load_constants()["dark-channel"])
        log(json.dumps(result))
        (EVIDENCE / "auto-contamination.json").write_text(json.dumps(result, indent=1, default=float))
    elif args.command == "scale":
        command_scale(log)
    elif args.command == "calibrate":
        result = calibrate(load_constants()["dark-channel"], log=log)
        (EVIDENCE / "calibrate.json").write_text(json.dumps(result, indent=1, default=float))
    else:
        command_report(log)


if __name__ == "__main__":
    main()
