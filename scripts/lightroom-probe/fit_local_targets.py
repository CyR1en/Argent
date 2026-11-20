"""A mask's tone controls as output-L* targets (docs/masking-plan.md section 4, P0-L1c section 4).

Lightroom's Contrast, Whites and Blacks in a mask are fixed curves of output lightness, the same on
every picture, and its Highlights and Shadows are the panel's times a multiplier of the slider's
size. All of it is read here off the ramp chart's exports (`mask-ramp.dng`, every row the same ramp,
12 stops under white to white), so no raw, no renderer and no plug-in are needed:

- `contrast`, `whites`, `blacks`: the change of output L* by input L*. A gradient's rows at coverage
  c render the whole-frame mask at c x 100 (slider scaling is exact), which gives every value to
  +-100 on one export. Amount 2 gives +-200 (`m06-confirm` on one sign, `m07-law` on the other).
- `highlightsScale`, `shadowsScale`: k(|s|), local change over panel change on the same chart.
- `blackPoint`, `outputFloor`, `whitePoint`: one levels stretch fitted to each single control.

Writes Sources/ArgentCore/Film/LightroomLocalToneTargets.swift and a JSON report, and prints each
fit's error against the numbers P0-L1c published. numpy only, and on purpose nothing from the rest
of this folder: the mask session's kit is not in the repository.

    .venv/bin/python -I scripts/lightroom-probe/fit_local_targets.py [--data DIR] [--swift FILE]
                                                                     [--report FILE]
"""
import argparse
import json
import struct
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "references" / "lightroom-probe"
# Newest first, as an item keeps the id it was first exported under.
JOBS = ("m07-law", "m06-confirm", "m05-extra", "m04-base", "m02-overlap", "m01-partial", "m00-smoke")
# The output L* grid, as LightroomToneTargets'.
LIGHTNESS = np.round(np.arange(0, 100.001, 2.5), 2)
BLOCK = 4
PROPHOTO_Y = np.array([0.2880402, 0.7118741, 0.0000857])

# Values with a row that a render measures, to +-100, then the +-200 axis. Past 100 only 200 is measured
# (Amount 2), and 150 for Whites + (Amount 1.5); `full_axis` fills the rest.
VALUES = [-100, -75, -50, -25, 25, 50, 75, 100]
AXIS = [-200, -175, -150, -125, -100, -75, -50, -25, 25, 50, 75, 100, 125, 150, 175, 200]
STRETCH_AXIS = list(range(-200, 201, 25))
SCALE_MAGNITUDES = [25, 50, 75, 100]
TABLE_NAMES = {"C": "contrast", "W": "whites", "B": "blacks"}


def fmt(value):
    """+50, -1.5, +0.25: a signed number, as the session's item ids have it."""
    return f"{value:+g}"


# MARK: Reading

TYPES = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 16: 8}


def read_tiff(path):
    """An uncompressed 8- or 16-bit TIFF's first three channels in 0...1, and its ICC profile."""
    b = Path(path).read_bytes()
    e = "<" if b[:2] == b"II" else ">"
    off = struct.unpack(e + "I", b[4:8])[0]
    n = struct.unpack(e + "H", b[off:off + 2])[0]
    tags = {}
    for i in range(n):
        t, ty, c, v = struct.unpack(e + "HHI4s", b[off + 2 + 12 * i:off + 14 + 12 * i])
        size = TYPES.get(ty, 1) * c
        at = struct.unpack(e + "I", v)[0]
        data = v if size <= 4 else b[at:at + size]
        if ty == 3:
            tags[t] = struct.unpack(e + f"{c}H", data[:2 * c])
        elif ty == 4:
            tags[t] = struct.unpack(e + f"{c}I", data[:4 * c])
        else:
            tags[t] = data[:size]
    w, h = tags[256][0], tags[257][0]
    if tags.get(259, (1,))[0] != 1:
        raise SystemExit(f"{path}: compressed TIFF; export uncompressed")
    spp, bps = tags[277][0], tags[258][0]
    raw = b"".join(b[o:o + c] for o, c in zip(tags[273], tags[279]))
    dt = np.dtype(e + ("u2" if bps == 16 else "u1"))
    img = np.frombuffer(raw, dt).reshape(h, w, spp)[:, :, :3]
    return img.astype(np.float32) / (65535 if bps == 16 else 255), tags.get(34675)


def icc_gamma(icc):
    """The pure gamma of an ICC profile's rTRC, or None when it is a table or parametric curve."""
    count = struct.unpack(">I", icc[128:132])[0]
    for i in range(count):
        sig, o, _ = struct.unpack(">4sII", icc[132 + 12 * i:144 + 12 * i])
        if sig == b"rTRC" and icc[o:o + 4] == b"curv" and struct.unpack(">I", icc[o + 8:o + 12])[0] == 1:
            return struct.unpack(">H", icc[o + 12:o + 14])[0] / 256
    return None


def lightroom_luminance(path):
    """Linear luminance of a Lightroom export: 16-bit ProPhoto RGB with its pure-gamma rTRC."""
    img, icc = read_tiff(path)
    gamma = icc_gamma(icc) if icc else None
    if gamma is None:
        raise SystemExit(f"{path}: expected ProPhoto RGB with a pure-gamma profile")
    return np.power(img, gamma) @ PROPHOTO_Y.astype(np.float32)


def block_mean(a, k=BLOCK):
    h, w = a.shape[0] // k * k, a.shape[1] // k * k
    return a[:h, :w].reshape(h // k, k, w // k, k).mean(axis=(1, 3))


def lstar(Y):
    """CIE L* of relative luminance, white Y = 1 at L* 100."""
    Y = np.maximum(Y, 0)
    return 116 * np.where(Y > (6 / 29) ** 3, np.cbrt(Y), Y / (3 * (6 / 29) ** 2) + 4 / 29) - 16


class Exports:
    """The session's exports by item id, as L* of 4 x 4 blocks averaged in linear light."""

    def __init__(self, data=DATA):
        self.data = Path(data)
        self.memo = {}

    def path(self, item):
        for job in JOBS:
            path = self.data / f"exports-{job}" / f"{job}_{item}.tif"
            if path.exists():
                return path
        raise SystemExit(f"no export of {item} under {self.data}")

    def has(self, item):
        return any((self.data / f"exports-{job}" / f"{job}_{item}.tif").exists() for job in JOBS)

    def blocks(self, item):
        if item not in self.memo:
            self.memo[item] = lstar(block_mean(lightroom_luminance(self.path(item))).astype(np.float64))
        return self.memo[item]

    def column(self, item):
        return np.median(self.blocks(item), axis=0)


# MARK: The ramp

class Ramp:
    """The ramp as data: each column's level, the chart's transfer from its Exposure series, and
    Lightroom's local response F(control, slider, input L*) from a gradient's coverage family."""

    # The chart's global Exposure renders; R-gE+1 is in the smoke job, the rest in m01.
    GLOBAL_EXPOSURES = (1, -3, -2, -1.5, -1, -0.5, -0.25, 0.25, 0.5, 0.75, 1.5, 2, 3)

    def __init__(self, exports):
        self.exports = exports
        layout = json.loads((exports.data / "charts-dng" / "mask-ramp-layout.json").read_text())
        low, high = layout["ramp"]["stops"]
        self.base = exports.column("R-base")
        columns = len(self.base)
        self.x = low + (high - low) * (np.arange(columns) + 0.5) / columns
        share = np.arange(columns) / columns
        self.usable = (self.base > 3.0) & (self.base < 97.0) & (share > 0.03) & (share < 0.97)
        self.tg, self.tv = self._transfer()
        self.coverage = np.mean(list(self._coverage_profiles().values()), axis=0)
        self.partial = np.where((self.coverage > 0.0) & (self.coverage < 1.0))[0]
        self.families = {}

    def _transfer(self):
        """T(level) in L*: a column at level x under global Exposure e shows T(x + e)."""
        xs, ls = [self.x], [self.base]
        for e in self.GLOBAL_EXPOSURES:
            xs.append(self.x + e)
            ls.append(self.exports.column(f"R-gE{fmt(e)}"))
        xa, la = np.concatenate(xs), np.concatenate(ls)
        grid = np.arange(xa.min(), xa.max() + 1e-9, 0.02)
        bins = np.clip(np.digitize(xa, grid) - 1, 0, len(grid) - 1)
        s = np.bincount(bins, la, len(grid))
        n = np.bincount(bins, None, len(grid))
        ok = n > 0
        return grid[ok], np.maximum.accumulate(s[ok] / n[ok])

    def t(self, level):
        return np.interp(level, self.tg, self.tv)

    def t_inverse(self, lightness):
        return np.interp(lightness, self.tv + np.arange(len(self.tv)) * 1e-9, self.tg)

    def full(self, control, value):
        return self.exports.column(f"R-q7-full-{control}{fmt(value)}")

    def glob(self, control, value):
        return self.exports.column(f"R-g{control}{fmt(value)}")

    def _coverage_profiles(self):
        """c(row) from local Exposure on the gradient: stops moved over the full render's stops."""
        out = {}
        for e in (2, 1, -1, -2):
            observed = self.exports.blocks(f"R-q1-G1-E{fmt(e)}")
            stops = np.median((self.t_inverse(self.full("E", e)) - self.x)[self.usable & (self.base < 90)])
            estimate = (self.t_inverse(observed) - self.x[None, :]) / stops
            out[e] = np.median(estimate[:, self.usable & (self.base < 90) & (self.base > 5)], axis=1)
        return out

    def family(self, control, sign):
        """Coverage ascending, and output L* [coverage, column], with the base and the full render
        as coverage 0 and 1."""
        key = (control, sign)
        if key not in self.families:
            observed = self.exports.blocks(f"R-q1-G1-{control}{fmt(100 * sign)}")
            c = self.coverage[self.partial]
            order = np.argsort(c)
            grid = np.concatenate([[0.0], c[order], [1.0]])
            rows = np.vstack([self.base[None, :], observed[self.partial][order], self.full(control, 100 * sign)[None, :]])
            self.families[key] = (grid, rows)
        return self.families[key]

    def response(self, control, slider, lightness):
        """Output L* at `slider` (-100...100) for input `lightness`: the mask's whole-frame curve."""
        if slider == 0:
            return np.asarray(lightness, dtype=np.float64)
        grid, rows = self.family(control, 1 if slider > 0 else -1)
        c = abs(slider) / 100.0
        j = int(np.clip(np.searchsorted(grid, c), 1, len(grid) - 1))
        t = (c - grid[j - 1]) / (grid[j] - grid[j - 1])
        return np.interp(lightness, self.base, (1 - t) * rows[j - 1] + t * rows[j])

    def amount(self, control, value, amount):
        """Output L* of the whole-frame mask at `value` and Amount `amount`, on the ramp's own columns."""
        return self.exports.column(f"R-q3-{control}{fmt(value)}-a{amount:g}")


# MARK: The targets

def measured_rows(ramp, control):
    """The change of L* at each grid column for each value to +-100.

    L1c (`local_targets.py`) set the column at L* 100 to 0, as the panel's file does. That holds for
    every control but Whites below 0, whose white point is above 100, so white itself falls: Whites
    -100 takes it from 100 to 79.7. The measured column stays; under 0.1 it reads as white stays white.
    """
    rows = {}
    for value in VALUES:
        row = ramp.response(control, value, LIGHTNESS) - LIGHTNESS
        row[-1] = row[-1] if abs(row[-1]) >= 0.1 else 0.0
        rows[value] = row
    return rows


def amount_row(ramp, control, value, amount):
    row = np.interp(LIGHTNESS, ramp.base, ramp.amount(control, value, amount)) - LIGHTNESS
    row[-1] = row[-1] if abs(row[-1]) >= 0.1 else 0.0
    return row


def through_three(x, y, s):
    """The quadratic through three (x, y) at s. `y` may be arrays, per column."""
    (x0, x1, x2), (y0, y1, y2) = x, y
    return (y0 * (s - x1) * (s - x2) / ((x0 - x1) * (x0 - x2))
            + y1 * (s - x0) * (s - x2) / ((x1 - x0) * (x1 - x2))
            + y2 * (s - x0) * (s - x1) / ((x2 - x0) * (x2 - x1)))


def stretch(lightness, black, white):
    return np.clip(100.0 * (lightness - black) / (white - black), 0.0, 100.0)


def golden_minimum(f, low, high, steps=90):
    """The minimum of a unimodal `f` on [low, high]."""
    ratio = (np.sqrt(5) - 1) / 2
    a, b = low, high
    c, d = b - ratio * (b - a), a + ratio * (b - a)
    fc, fd = f(c), f(d)
    for _ in range(steps):
        if fc < fd:
            b, d, fd = d, c, fc
            c = b - ratio * (b - a)
            fc = f(c)
        else:
            a, c, fc = c, d, fd
            d = a + ratio * (b - a)
            fd = f(d)
    return (a + b) / 2


def fit_point(ramp, control, curve):
    """Whites' white point or Blacks' black point: the single stretch closest to `curve`, least
    squares over the chart's levels. The same estimator at every value, so the rows are one family
    (L1c's 72.18 and 67.78 past 100 were a median ratio, which reads about 0.5 under this at +100)."""
    ok = ramp.usable & (ramp.base > 1.0) & (ramp.base < 99.0)
    if control == "W":
        return golden_minimum(lambda p: float(np.sum((stretch(ramp.base, 0.0, p) - curve)[ok] ** 2)), 30.0, 400.0)
    return golden_minimum(lambda p: float(np.sum((stretch(ramp.base, p, 100.0) - curve)[ok] ** 2)), -200.0, 95.0)


def point_rms(ramp, control, curve, point):
    ok = ramp.usable & (ramp.base > 1.0) & (ramp.base < 99.0)
    fitted = stretch(ramp.base, 0.0, point) if control == "W" else stretch(ramp.base, point, 100.0)
    return float(np.sqrt(np.mean((fitted - curve)[ok] ** 2)))


def warped_row(ramp, control, anchors, curves, s):
    """A row where a clip moves with the slider (Whites above 0, Blacks below 0): the anchors' outputs
    are interpolated at the same place in the stretch, not at the same input L*, so the kink stays
    one kink. Per column it would be smeared across every column it passes."""
    points = [fit_point(ramp, control, curves[a]) for a in anchors]
    point = through_three(anchors, points, s)
    if control == "W":
        unit = LIGHTNESS / point
        outputs = [np.interp(unit * q, ramp.base, curves[a]) for a, q in zip(anchors, points)]
    else:
        unit = (LIGHTNESS - point) / (100.0 - point)
        outputs = [np.interp(q + unit * (100.0 - q), ramp.base, curves[a]) for a, q in zip(anchors, points)]
    return through_three(anchors, outputs, s) - LIGHTNESS


def clip_moves(control, sign):
    return (control == "W" and sign > 0) or (control == "B" and sign < 0)


def filled_row(ramp, control, sign, anchors, curves, s):
    """A row between measured ones: warped where a clip moves, else the quadratic per column,
    which keeps the response's curvature. `report["pastHundred"]` holds the test that chose them."""
    if clip_moves(control, sign):
        return warped_row(ramp, control, anchors, curves, s)
    rows = [np.interp(LIGHTNESS, ramp.base, curves[a]) - LIGHTNESS for a in anchors]
    return through_three(anchors, rows, s)


def full_axis(ramp, control):
    """Rows at every value of `AXIS`, and how each past 100 was made."""
    rows = measured_rows(ramp, control)
    how = {}
    for sign in (-1, 1):
        curves = {75: ramp.response(control, sign * 75, ramp.base), 100: ramp.response(control, sign * 100, ramp.base),
                  200: ramp.amount(control, sign * 100, 2)}
        rows[sign * 200] = amount_row(ramp, control, sign * 100, 2)
        how[fmt(sign * 200)] = "measured, Amount 2"
        anchors, fill = (75, 100, 200), (125, 150, 175)
        if control == "W" and sign > 0:
            curves[150] = ramp.amount(control, 100, 1.5)
            rows[150] = amount_row(ramp, control, 100, 1.5)
            how[fmt(150)] = "measured, Amount 1.5"
            anchors, fill = (100, 150, 200), (125, 175)
        for s in fill:
            rows[sign * s] = filled_row(ramp, control, sign, anchors, curves, s)
            how[fmt(sign * s)] = f"{'warped' if clip_moves(control, sign) else 'quadratic'} through {anchors}"
    return rows, how


def fill_test(ramp):
    """What fills 125 to 175, tried where the answer is known. Value 75 from 37.5, 50, 100 has the
    same ratios as 150 from 75, 100, 200, on both signs of every control, and slider scaling gives
    all four; Whites +150 itself is the one render past 100. rms and worst change of L*."""
    def score(d):
        return {"rms": float(np.sqrt(np.mean(d[1:-1] ** 2))), "max": float(np.abs(d[1:-1]).max())}

    def row(curve):
        return np.interp(LIGHTNESS, ramp.base, curve) - LIGHTNESS

    out = {}
    for control in TABLE_NAMES:
        for sign in (1, -1):
            curves = {a: ramp.response(control, sign * a, ramp.base) for a in (37.5, 50, 75, 100)}
            anchors = (37.5, 50, 100)
            truth = row(curves[75])
            entry = {"linear": score(0.5 * (row(curves[50]) + row(curves[100])) - truth),
                     "quadratic": score(through_three(anchors, [row(curves[a]) for a in anchors], 75) - truth)}
            if clip_moves(control, sign):
                entry["warped"] = score(warped_row(ramp, control, anchors, curves, 75) - truth)
            out[f"{control}{'+' if sign > 0 else '-'}75"] = entry
    curves = {75: ramp.response("W", 75, ramp.base), 100: ramp.response("W", 100, ramp.base), 200: ramp.amount("W", 100, 2)}
    truth = amount_row(ramp, "W", 100, 1.5)
    out["W+150"] = {"linear": score(0.5 * (row(curves[100]) + row(curves[200])) - truth),
                    "quadratic": score(through_three((75, 100, 200), [row(curves[a]) for a in (75, 100, 200)], 150) - truth),
                    "warped": score(warped_row(ramp, "W", (75, 100, 200), curves, 150) - truth)}
    return out


def scales(ramp, control):
    """k(|s|) by sign: the least-squares ratio of the mask's change to the panel's on the chart, the
    100 fixed at exactly 1 (the panel itself; measured 1.000 to 1.011), so a whole-frame mask at
    +-100 is the panel's table bit for bit."""
    ok = ramp.usable & (ramp.base > 3) & (ramp.base < 97)
    fitted = {}
    for sign in (-1, 1):
        for size in SCALE_MAGNITUDES:
            panel = ramp.glob(control, sign * size) - ramp.base
            local = ramp.response(control, sign * size, ramp.base) - ramp.base
            k = float((local[ok] * panel[ok]).sum() / (panel[ok] ** 2).sum())
            residual = float(np.sqrt(np.mean((local - k * panel)[ok] ** 2)))
            fitted[sign * size] = {"k": k, "residual": residual,
                                   "localMinusPanel": float(np.sqrt(np.mean((local - panel)[ok] ** 2)))}
    return fitted


def stretch_points(ramp):
    """The rows of the single stretch: white point from Whites alone, black point from Blacks alone
    below 0, and above 0 the output floor its negative black point means. Past 100 measured where a
    render exists, else the quadratic in |s| through 75, 100, 200 (100, 150, 200 where 150 is)."""
    curves = {
        "B": {**{s: ramp.response("B", s, ramp.base) for s in VALUES}, -200: ramp.amount("B", -100, 2), 200: ramp.amount("B", 100, 2)},
        "W": {**{s: ramp.response("W", s, ramp.base) for s in VALUES}, -200: ramp.amount("W", -100, 2), 200: ramp.amount("W", 100, 2),
              150: ramp.amount("W", 100, 1.5)},
    }
    of = {c: {s: fit_point(ramp, c, curve) for s, curve in curves[c].items()} for c in curves}
    fits = {c: {fmt(s): {"point": of[c][s], "rms": point_rms(ramp, c, curves[c][s], of[c][s])} for s in sorted(of[c])} for c in of}

    def filled(points, s):
        if s in points:
            return points[s]
        sign = 1 if s > 0 else -1
        anchors = (100, 150, 200) if sign * 150 in points else (75, 100, 200)
        return through_three(anchors, [points[sign * a] for a in anchors], abs(s))

    black, floor, white = [], [], []
    for s in STRETCH_AXIS:
        if s == 0:
            black.append(0.0)
            floor.append(0.0)
            white.append(100.0)
            continue
        white.append(filled(of["W"], s))
        b = filled(of["B"], s)
        black.append(b if s < 0 else 0.0)
        floor.append(0.0 if s < 0 else -100.0 * b / (100.0 - b))
    return black, floor, white, fits


# MARK: ManualToneTables' construction over any transfer, for the errors below

MIN_SLOPE, MIN_TARGET_SLOPE, KNEE, LIMIT = 1.0, 0.05, 2.0, 4.0


def tangents(x, y):
    """`ToneCurves`' tangents, as ManualToneTables.Target's."""
    n = len(x)
    slopes = [(y[i + 1] - y[i]) / (x[i + 1] - x[i]) for i in range(n - 1)]
    tg = [0.0] * n
    tg[0], tg[-1] = slopes[0], slopes[-1]
    for i in range(1, n - 1):
        if slopes[i - 1] * slopes[i] > 0:
            h0, h1 = x[i] - x[i - 1], x[i + 1] - x[i]
            w0, w1 = 2 * h1 + h0, h1 + 2 * h0
            tg[i] = (w0 + w1) / (w0 / slopes[i - 1] + w1 / slopes[i])
    for i in range(len(slopes)):
        if slopes[i] == 0:
            tg[i] = 0
            tg[i + 1] = 0
            continue
        a, b = tg[i] / slopes[i], tg[i + 1] / slopes[i]
        length = a * a + b * b
        if length > 9:
            s = 3 / np.sqrt(length)
            tg[i] = s * a * slopes[i]
            tg[i + 1] = s * b * slopes[i]
    return tg


class Target:
    """One control's lightness change at its value: ManualToneTables.Target over any rows."""

    def __init__(self, rows, values, lightness, value):
        values = [float(v) for v in values]
        table = [list(r) for r in rows]
        zero = next((i for i, v in enumerate(values) if v > 0), len(values))
        values.insert(zero, 0.0)
        table.insert(zero, [0.0] * len(lightness))
        clamped = min(max(value, values[0]), values[-1])
        upper = next((i for i, v in enumerate(values) if v >= clamped), len(values) - 1)
        upper = max(1, min(len(values) - 1, upper))
        t = (clamped - values[upper - 1]) / (values[upper] - values[upper - 1])
        self.lightness = [float(v) for v in lightness]
        self.change = [a + (b - a) * t for a, b in zip(table[upper - 1], table[upper])]
        self.tangents = tangents(self.lightness, self.change)

    def at(self, value):
        lg, ch, tg = self.lightness, self.change, self.tangents
        last = len(lg) - 1
        if value <= lg[0]:
            return ch[0]
        if value >= lg[last]:
            return ch[last]
        i = 0
        while i < last - 1 and value > lg[i + 1]:
            i += 1
        h = lg[i + 1] - lg[i]
        u = (value - lg[i]) / h
        u2 = u * u
        u3 = u2 * u
        return ((2 * u3 - 3 * u2 + 1) * ch[i] + (u3 - 2 * u2 + u) * h * tg[i]
                + (-2 * u3 + 3 * u2) * ch[i + 1] + (u3 - u2) * h * tg[i + 1])


def regularize(transfer, step):
    """The print's lightness 0...100 and its slope-floored copy T~ (ManualToneTables.init)."""
    t = np.asarray(transfer, dtype=np.float64)
    black = t[0]
    own = 100 * (t - black) / max(t[-1] - black, 1.0)
    rises = np.diff(own)
    anchor = int(np.argmax(rises))
    out = own.copy()
    least = MIN_SLOPE * step
    for i in range(anchor + 1, len(t)):
        out[i] = out[i - 1] + max(rises[i - 1], least)
    for i in range(anchor - 1, -1, -1):
        out[i] = out[i + 1] - max(rises[i], least)
    return out


def inverse(lightness, reg, start, step):
    """The stops where T~ reaches `lightness`, at the minimum slope beyond the samples."""
    last = len(reg) - 1
    if lightness <= reg[0]:
        return start + (lightness - reg[0]) / MIN_SLOPE
    if lightness >= reg[last]:
        return start + last * step + (lightness - reg[last]) / MIN_SLOPE
    low, high = 0, last
    while high - low > 1:
        middle = (low + high) // 2
        if reg[middle] <= lightness:
            low = middle
        else:
            high = middle
    return start + (low + (lightness - reg[low]) / (reg[low + 1] - reg[low])) * step


def limited(gain):
    size = abs(gain)
    if size <= KNEE:
        return gain
    room = LIMIT - KNEE
    return (-1 if gain < 0 else 1) * (KNEE + room * np.tanh((size - KNEE) / room))


def gains(targets, reg, start, step):
    """`x' - x` at every sample, `x'` where T~ reaches the composed targets of T~(x), softly limited."""
    n = len(reg)
    if not targets:
        return np.zeros(n)
    out = np.empty(n)
    previous = -np.inf
    for i in range(n):
        aim = reg[i]
        for t in targets:
            aim += t.at(aim)
        if i > 0:
            aim = max(aim, previous + MIN_TARGET_SLOPE * (reg[i] - reg[i - 1]))
        previous = aim
        out[i] = limited(inverse(aim, reg, start, step) - (start + step * i))
    return out


class System:
    """A neutral transfer's geometry: Lightroom's own from the ramp, or a stock's from the Swift tables."""

    def __init__(self, name, start, step, reg):
        self.name, self.start, self.step = name, start, step
        self.reg = np.asarray(reg, dtype=np.float64)
        self.xs = start + step * np.arange(len(self.reg))

    def x_of(self, lightness):
        return np.array([inverse(float(v), self.reg, self.start, self.step) for v in np.atleast_1d(lightness)])

    def l_at(self, x):
        x = np.asarray(x, dtype=np.float64)
        out = np.interp(x, self.xs, self.reg)
        out = np.where(x < self.xs[0], self.reg[0] + (x - self.xs[0]) * MIN_SLOPE, out)
        return np.where(x > self.xs[-1], self.reg[-1] + (x - self.xs[-1]) * MIN_SLOPE, out)


def lightroom_system(ramp):
    start, count = -14.5, 512
    step = 17.5 / (count - 1)
    return System("LR", start, step, regularize(ramp.t(start + step * np.arange(count)), step))


# MARK: The errors, against L1c's

def picture_weights(exports, grid):
    """The real picture's L* histogram on the input grid: "rms_pic" in L1c, as the audit's."""
    counts, _ = np.histogram(exports.blocks("P-base").ravel(), bins=np.append(grid - 0.5, grid[-1] + 0.5))
    return counts / counts.sum()


def table_errors(ramp, exports, rows, system):
    """A single control on a knot through `system`, against the mask's measured curve: L1c's
    "full coverage" rows. rms over levels weighted by the picture, and the worst level."""
    grid = np.arange(3, 97.01, 1.0)
    weights = picture_weights(exports, grid)
    x = system.x_of(grid)
    out = {}
    for control, table in rows.items():
        values = sorted(table)
        matrix = [[float(v) for v in table[k]] for k in values]
        for value in VALUES:
            g = gains([Target(matrix, values, LIGHTNESS, value)], system.reg, system.start, system.step)
            predicted = system.l_at(x + np.interp(x, system.xs, g))
            err = predicted - ramp.response(control, value, grid)
            out[(control, value)] = (float(np.sqrt(np.sum(weights * err ** 2))), float(np.abs(err).max()))
    return out


def pool(errors, values):
    sel = [errors[k] for k in errors if k[1] in values]
    return float(np.sqrt(np.mean([e[0] ** 2 for e in sel]))), float(max(e[1] for e in sel))


# MARK: The Swift file

def swift_number(v):
    return f"{v:.2f}".rstrip("0").rstrip(".") if abs(v) >= 0.005 else "0"


def swift_rows(rows):
    def row(values):
        return "[" + ", ".join(swift_number(v) for v in values) + "]"
    return "[\n" + ",\n".join(f"        {row(rows[v])}" for v in AXIS) + ",\n    ]"


def swift_list(values, digits=2):
    return "[" + ", ".join(f"{v:.{digits}f}".rstrip("0").rstrip(".") if abs(v) >= 0.5 * 10 ** -digits else "0"
                           for v in values) + "]"


def write_swift(path, targets, scale, black, floor, white, source):
    labels = [f"{v:g}" for v in LIGHTNESS]
    grid = ",\n        ".join(", ".join(labels[i:i + 14]) for i in range(0, len(labels), 14))
    body = f"""// Generated by scripts/lightroom-probe/fit_local_targets.py; do not edit by hand.
/// Lightroom Classic's tone controls in a mask, read off its ramp chart (`source`; P0-L1c section 4,
/// docs/provenance.md): what `LocalScene`'s tables are built over, one control at a time.
/// Contrast, Whites and Blacks in a mask are fixed curves of output lightness, the same on every
/// picture and not the panel's: the change of output CIE L* by unadjusted output L*, rows at the
/// slider's value. Past 100 is Amount 2, which multiplies the slider; 125, 150 and 175 are filled
/// (`fit_local_targets.py`). Highlights and Shadows in a mask are the panel's times `...Scale`.
public enum LightroomLocalToneTargets {{
    public static let source = "{source}"
    /// Output L* where changes are given; ascending, first 0 and last 100.
    public static let lightness: [Float] = [
        {grid},
    ]
    /// Control values with a row; value 0 is implicit and changes nothing.
    public static let values: [Float] = [{", ".join(str(v) for v in AXIS)}]
    /// Output L* change, [value row][lightness column].
    public static let contrast: [[Float]] = {swift_rows(targets["C"])}
    public static let whites: [[Float]] = {swift_rows(targets["W"])}
    public static let blacks: [[Float]] = {swift_rows(targets["B"])}
    /// The slider's size at which k(|s|) is given: a mask's Highlights or Shadows over the panel's.
    /// Linear between; below the first, the first's. At 100 it is the panel itself.
    public static let scaleMagnitudes: [Float] = [{", ".join(str(v) for v in SCALE_MAGNITUDES)}]
    public static let highlightsScaleNegative: [Float] = {swift_list(scale["H"][-1], 3)}
    public static let highlightsScalePositive: [Float] = {swift_list(scale["H"][1], 3)}
    public static let shadowsScaleNegative: [Float] = {swift_list(scale["S"][-1], 3)}
    public static let shadowsScalePositive: [Float] = {swift_list(scale["S"][1], 3)}
    /// The slider values of the three rows below, linear between: Whites' white point, Blacks' black
    /// point below 0 and its output floor above 0, as one levels stretch fits each control alone.
    public static let stretchValues: [Float] = [{", ".join(str(v) for v in STRETCH_AXIS)}]
    public static let blackPoint: [Float] = {swift_list(black)}
    public static let outputFloor: [Float] = {swift_list(floor)}
    public static let whitePoint: [Float] = {swift_list(white)}
}}
"""
    Path(path).write_text(body)


# MARK: What L1c published, for the printout

L1C_SCALE = {
    ("H", -1): [1.30, 1.19, 1.09, 1.00], ("H", 1): [1.23, 1.12, 1.05, 1.00],
    ("S", -1): [1.26, 1.15, 1.07, 1.00], ("S", 1): [1.34, 1.24, 1.12, 1.00],
}
L1C_POINTS = {
    "black": [30.32, 24.85, 18.19, 9.97],
    "floor": [10.18, 18.47, 25.21, 30.74],
    "white": [126.58, 120.41, 113.88, 107.05, 100, 93.42, 87.79, 82.98, 78.88],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data", default=DATA)
    parser.add_argument("--swift", default=ROOT / "Sources" / "ArgentCore" / "Film" / "LightroomLocalToneTargets.swift")
    parser.add_argument("--report", default=None)
    args = parser.parse_args()
    report_path = Path(args.report) if args.report else Path(args.data) / "fit" / "local-report.json"

    started = time.time()
    exports = Exports(args.data)
    ramp = Ramp(exports)
    system = lightroom_system(ramp)
    report = {"data": str(args.data), "chart": "mask-ramp.dng", "lightness": LIGHTNESS.tolist()}

    # The rows.
    targets, how = {}, {}
    for control in TABLE_NAMES:
        targets[control], how[control] = full_axis(ramp, control)
    report["rowsPastHundred"] = how
    report["targets"] = {TABLE_NAMES[c]: {fmt(v): [round(float(x), 3) for x in targets[c][v]] for v in AXIS} for c in targets}

    # What fills 125 to 175, tried where the answer is known.
    report["pastHundred"] = fill_test(ramp)
    print("Rows past 100, each method on a value it did not see (rms / worst change of L*):")
    for name, entry in report["pastHundred"].items():
        print(f"  {name:6s}" + "".join(f"  {k} {v['rms']:.2f} / {v['max']:.2f}" for k, v in entry.items()))

    # Amount 2's effect over Amount 1, the sign m06 did not try included (the coordinator's reading).
    selection = (ramp.base > 5) & (ramp.base < 95)
    ratios = {}
    for control, value in (("W", 100), ("W", -100), ("B", -100), ("B", 100), ("C", 100), ("C", -100)):
        one = np.abs(ramp.full(control, value) - ramp.base)[selection].mean()
        two = np.abs(ramp.amount(control, value, 2) - ramp.base)[selection].mean()
        ratios[f"{control}{fmt(value)}"] = float(two / one)
    report["amountTwoOverOne"] = ratios
    print("Amount 2 over Amount 1, mean |dL*| at L* 5 to 95:", {k: round(v, 2) for k, v in ratios.items()})

    # k(|s|).
    fitted = {c: scales(ramp, c) for c in "HS"}
    scale = {c: {sign: [1.0 if size == 100 else round(fitted[c][sign * size]["k"], 3) for size in SCALE_MAGNITUDES]
                 for sign in (-1, 1)} for c in "HS"}
    report["scale"] = {c: {fmt(k): v for k, v in fitted[c].items()} for c in fitted}
    print("k(|s|) of the panel's Highlights and Shadows at 25, 50, 75, 100, against L1c section 4:")
    worst_k = 0.0
    for (c, sign), theirs in L1C_SCALE.items():
        mine = scale[c][sign]
        worst_k = max(worst_k, max(abs(a - b) for a, b in zip(mine, theirs)))
        residual = [fitted[c][sign * s]["residual"] for s in SCALE_MAGNITUDES]
        print(f"  {c}{'-' if sign < 0 else '+'}: {mine}  L1c {theirs}  residual L* {[round(r, 3) for r in residual]}")
    print(f"  worst |mine - L1c| {worst_k:.4f}")
    report["scaleWorstAgainstL1c"] = worst_k

    # The stretch's rows.
    black, floor, white, points = stretch_points(ramp)
    report["stretch"] = {"values": STRETCH_AXIS, "blackPoint": black, "outputFloor": floor, "whitePoint": white, "fits": points}
    index = {s: i for i, s in enumerate(STRETCH_AXIS)}
    print("The stretch's rows, against L1c section 4:")
    mine_b = [black[index[s]] for s in (-100, -75, -50, -25)]
    mine_f = [floor[index[s]] for s in (25, 50, 75, 100)]
    mine_w = [white[index[s]] for s in (-100, -75, -50, -25, 0, 25, 50, 75, 100)]
    print(f"  black point at -100...-25   {np.round(mine_b, 2).tolist()}  L1c {L1C_POINTS['black']}")
    print(f"  output floor at 25...100    {np.round(mine_f, 2).tolist()}  L1c {L1C_POINTS['floor']}")
    print(f"  white point at -100...100   {np.round(mine_w, 2).tolist()}  L1c {L1C_POINTS['white']}")
    print(f"  past 100: white point at 150, 200, -200: {white[index[150]]:.2f}, {white[index[200]]:.2f}, {white[index[-200]]:.2f}"
          f" (L1c's 72.18 and 67.78 at 150 and 200 were a median ratio: 78.4 at +100 by the same estimator);"
          f" black point at -200: {black[index[-200]]:.2f}; output floor at 200: {floor[index[200]]:.2f}")
    fits = {f"{c}{k}": v["rms"] for c in points for k, v in points[c].items()}
    moderate = [v for k, v in fits.items() if k[1:] in ("-100", "-50", "+50", "+100")]
    print(f"  single-control fits, rms L*: {min(moderate):.2f} to {max(moderate):.2f} at +-50 and +-100 (L1c: 0.4 to 0.6 at +-50, up to 0.73 at +-100);"
          f" past 100: {', '.join(f'{k} {v:.2f}' for k, v in fits.items() if abs(float(k[1:])) > 100)}")

    # The tables, through Lightroom's own transfer.
    tables = {c: dict(targets[c]) for c in targets}
    errors = table_errors(ramp, exports, tables, system)
    moderate, strong = pool(errors, (-50, -25, 25, 50)), pool(errors, (-100, 100))
    report["tableError"] = {"plus-minus-50": {"rms": moderate[0], "worst": moderate[1]},
                            "plus-minus-100": {"rms": strong[0], "worst": strong[1]},
                            "byValue": {f"{c}{fmt(v)}": {"rms": e[0], "worst": e[1]} for (c, v), e in errors.items()}}
    print("The tables, a single control on a knot through Lightroom's transfer against the mask's curve, rms over the picture's L* (worst level):")
    print(f"  to +-50  {moderate[0]:.2f} ({moderate[1]:.2f})   L1c 0.07 (1.05)")
    print(f"  at +-100 {strong[0]:.2f} ({strong[1]:.2f})   L1c 0.30 (2.64)")

    source = "Lightroom Classic 15.6, PV 15.4, Adobe Standard, mask-ramp.dng: m01-partial, m06-confirm, m07-law"
    write_swift(args.swift, targets, scale, black, floor, white, source)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=1))
    print(f"wrote {args.swift} and {report_path} in {time.time() - started:.0f} s")


if __name__ == "__main__":
    main()
