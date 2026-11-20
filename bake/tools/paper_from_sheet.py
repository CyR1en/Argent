#!/usr/bin/env python3
"""Write paper profiles straight from Kodak's paper datasheet PDFs: KODAK PROFESSIONAL PORTRA ENDURA and
SUPRA ENDURA (E-4021), SUPRA ENDURA VC Digital (E-4042), and KODAK EDGE (E-7020) and ROYAL Digital (E-7021),
docs/research/film-sim/print.md sections 2 and 4.

ENDURA Premier (E-4070) was digitized from reviewed CSVs kept outside the repository
(tools/profile_from_extraction.py). The papers here are digitized by this one script from the PDF itself,
so the extraction is reproducible from the sheet alone:

    .venv/bin/python -I bake/tools/paper_from_sheet.py --e4021 <e4021_2008.pdf> --e4042 <E4042.pdf> \
        --e4070 <E-4070_2017-12_kodakalaris.pdf> [--raster-check] [--write]

What it does, for every plot it reads:

1. Interprets the page's content stream with pypdf (m, l, c, v, y, re, h and cm; Beziers flattened at
   64 samples per segment), keeping every stroked or filled path inside the plot's frame.
2. Calibrates each axis by least squares on the plot's labelled tick or grid lines (their PDF coordinates
   are listed per plot below, read from the same content stream, and the script checks each is a line
   it found).
3. Takes as curves the paths that are not straight lines, chains pieces that end where the next begins
   (within 0.05 pt), keeps chains spanning at least a quarter of the frame, and names them: characteristic
   curves by the order each plot's labels give (checked: R, G and B by D-max order, or as configured),
   sensitivities and dyes by the wavelength of their peak.
4. Resamples every curve by linear interpolation of the flattened path, every 0.05 log H and 5 nm.

Review: `--e4070` runs the same code on ENDURA Premier's sheet and compares it with the reviewed profile
in bake/papers/kodak-endura-premier.json (the check that this code reads a Kodak plot the way the
reviewed extraction did); `--raster-check` renders each page with macOS sips (Quartz, an independent
renderer) and compares the vector curves with the dark pixels on vertical scan lines.

Nothing is written unless `--write` is given; the profiles go to bake/papers/.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import pypdf
from pypdf.generic import ContentStream

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from profile_from_extraction import Fixed, emit, fixed_list  # noqa: E402

DIGITIZED = "2026-10-08"
SAMPLES = 64
JOIN = 0.05  # pt: a curve's pieces share their end points; neighbouring curves' toes can lie 0.1 pt apart
LAYERS = ("red", "green", "blue")
DYES = ("cyan", "magenta", "yellow")


# The content stream: paths in page coordinates.


def _mul(a, b):
    return [a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3], a[2] * b[0] + a[3] * b[2],
            a[2] * b[1] + a[3] * b[3], a[4] * b[0] + a[5] * b[2] + b[4], a[4] * b[1] + a[5] * b[3] + b[5]]


def _apply(m, x, y):
    return (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5])


def _bezier(p0, p1, p2, p3, n=SAMPLES):
    t = np.arange(1, n + 1) / n
    u = 1 - t
    x = u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0]
    y = u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1]
    return list(zip(x, y))


def page_paths(pdf: Path, page_number: int) -> list[np.ndarray]:
    """Every stroked subpath of a page (1-based), flattened, in page coordinates (y up), in stream order."""
    reader = pypdf.PdfReader(str(pdf))
    page = reader.pages[page_number - 1]
    stream = ContentStream(page.get_contents(), reader)
    ctm, stack, path, sub, cur = [1, 0, 0, 1, 0, 0], [], [], [], None
    out = []
    for operands, op in stream.operations:
        op = op.decode() if isinstance(op, bytes) else op
        a = [float(v) for v in operands] if op in ("cm", "m", "l", "c", "v", "y", "re") else None
        if op == "q":
            stack.append(ctm[:])
        elif op == "Q":
            ctm = stack.pop() if stack else ctm
        elif op == "cm":
            ctm = _mul(a, ctm)
        elif op == "m":
            if sub:
                path.append(sub)
            cur = _apply(ctm, a[0], a[1])
            sub = [cur]
        elif op == "l":
            cur = _apply(ctm, a[0], a[1])
            sub.append(cur)
        elif op == "c":
            p1, p2, p3 = _apply(ctm, a[0], a[1]), _apply(ctm, a[2], a[3]), _apply(ctm, a[4], a[5])
            sub += _bezier(cur, p1, p2, p3)
            cur = p3
        elif op == "v":
            p2, p3 = _apply(ctm, a[0], a[1]), _apply(ctm, a[2], a[3])
            sub += _bezier(cur, cur, p2, p3)
            cur = p3
        elif op == "y":
            p1, p3 = _apply(ctm, a[0], a[1]), _apply(ctm, a[2], a[3])
            sub += _bezier(cur, p1, p3, p3)
            cur = p3
        elif op == "re":
            x, y, w, h = a
            if sub:
                path.append(sub)
            path.append([_apply(ctm, x, y), _apply(ctm, x + w, y), _apply(ctm, x + w, y + h), _apply(ctm, x, y + h)])
            sub = []
        elif op in ("S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n"):
            if sub:
                path.append(sub)
                sub = []
            if op in ("S", "s", "B", "B*", "b", "b*"):  # stroked: lines, ticks and curves, not fills
                out += [np.asarray(s, dtype=float) for s in path if len(s) >= 2]
            path = []
    return out


# Plots.


@dataclass
class Axis:
    ticks: list  # (value, page coordinate) of labelled tick or grid lines, or of the frame where it carries a label

    def fit(self):
        values = np.array([t[0] for t in self.ticks], dtype=float)
        coords = np.array([t[1] for t in self.ticks], dtype=float)
        slope, offset = np.polyfit(coords, values, 1)
        residual = np.abs(slope * coords + offset - values) / abs(slope)  # in page points
        return slope, offset, float(residual.max())


@dataclass
class Plot:
    name: str
    page: int
    frame: tuple  # x0, y0, x1, y1 of the plot frame, page coordinates
    x: Axis
    y: Axis
    kind: str  # "char", "sens" or "dye"
    order: tuple = ()  # for char: the channels from the highest D-max to the lowest, as the sheet's labels stand
    notes: list = field(default_factory=list)


def _is_line(p: np.ndarray) -> bool:
    span = p.max(axis=0) - p.min(axis=0)
    return len(np.unique(np.round(p, 2), axis=0)) <= 2 or min(span) < 0.2  # straight, or a hairline box


def _check_ticks(paths, axis: Axis, which: int, frame, label: str):
    """Every configured tick must be a line the stream draws at that coordinate, or the frame's edge."""
    edges = (frame[0], frame[2]) if which == 0 else (frame[1], frame[3])
    for value, coord in axis.ticks:
        if any(abs(coord - e) < 0.02 for e in edges):
            continue
        hits = [p for p in paths if _is_line(p) and np.all(np.abs(p[:, which] - coord) < 0.02)]
        if not hits:
            raise SystemExit(f"{label}: no tick or grid line at {coord} for {value}")


def read_plot(pdf: Path, plot: Plot):
    paths = page_paths(pdf, plot.page)
    x0, y0, x1, y1 = plot.frame
    inside = [p for p in paths if p[:, 0].min() >= x0 - 1 and p[:, 0].max() <= x1 + 1
              and p[:, 1].min() >= y0 - 1 and p[:, 1].max() <= y1 + 1]
    _check_ticks(paths, plot.x, 0, plot.frame, f"{pdf.name} {plot.name} x")
    _check_ticks(paths, plot.y, 1, plot.frame, f"{pdf.name} {plot.name} y")
    # Everything stroked inside the frame but the frame itself; ticks and grid lines fall out below, as chains
    # of one straight piece. A curve's own straight pieces (a flat toe) stay, chained to their neighbours.
    pieces = [p for p in inside if not (len(p) in (4, 5) and np.ptp(p[:, 0]) > 0.9 * (x1 - x0)
                                        and np.ptp(p[:, 1]) > 0.9 * (y1 - y0))]
    # Chain pieces end to start whatever order the stream draws them in (EDGE and ROYAL Digital draw one
    # piece of a curve out of turn).
    chains = []
    for p in pieces:
        for c in chains:
            if np.hypot(*(c[-1][-1] - p[0])) < JOIN:
                c.append(p)
                break
            if np.hypot(*(p[-1] - c[0][0])) < JOIN:
                c.insert(0, p)
                break
        else:
            chains.append([p])
    merged = True
    while merged:  # two chains that meet end to start become one
        merged = False
        for i in range(len(chains)):
            for j in range(len(chains)):
                if i != j and np.hypot(*(chains[i][-1][-1] - chains[j][0][0])) < JOIN:
                    head, tail = chains[i], chains[j]
                    chains = [c for k, c in enumerate(chains) if k not in (i, j)] + [head + tail]
                    merged = True
                    break
            if merged:
                break
    chains = [c for c in chains if not all(_is_line(p) for p in c)]  # ticks, grid and frame lines, whole or in pieces
    curves = [np.vstack(c) for c in chains]
    curves = [c for c in curves if np.ptp(c[:, 0]) > 0.25 * (x1 - x0)]
    sx, ox, rx = plot.x.fit()
    sy, oy, ry = plot.y.fit()
    data = []
    for c in curves:
        xv = sx * c[:, 0] + ox
        yv = sy * c[:, 1] + oy
        keep = np.concatenate([[True], np.diff(xv) > 1e-9])  # the path runs left to right; drop doubled points
        data.append((xv[keep], yv[keep]))
    return data, (rx, ry), curves


def resample(xv, yv, step, decimals):
    lo = np.ceil(xv.min() / step - 1e-6) * step
    hi = np.floor(xv.max() / step + 1e-6) * step
    grid = np.round(np.arange(lo, hi + step / 2, step), decimals)
    return grid, np.interp(grid, xv, yv)


def name_curves(plot: Plot, data):
    if plot.kind == "char":
        if len(data) != 3:
            raise SystemExit(f"{plot.name}: {len(data)} characteristic curves, expected 3")
        # By D-max, highest first, in the order the sheet's labels give; a tie (within 0.005 D) goes to the curve
        # that is denser at log H -0.9, where PORTRA ENDURA's R label stands above its curve.
        ranked = sorted(data, key=lambda c: (round(c[1].max() / 0.005), np.interp(-0.9, c[0], c[1])), reverse=True)
        named = dict(zip(plot.order, ranked))
        dmax = {k: v[1].max() for k, v in named.items()}
        print(f"   {plot.name}: D-max " + ", ".join(f"{k} {dmax[k]:.3f}" for k in LAYERS))
        return named
    if len(data) != 3:
        raise SystemExit(f"{plot.name}: {len(data)} curves, expected 3")
    peaks = [xv[np.argmax(yv)] for xv, yv in data]
    order = np.argsort(peaks)  # shortest peak first
    names = ("blue", "green", "red") if plot.kind == "sens" else ("yellow", "magenta", "cyan")
    named = {names[i]: data[j] for i, j in enumerate(order)}
    print(f"   {plot.name}: peaks " + ", ".join(f"{k} {named[k][0][np.argmax(named[k][1])]:.0f} nm" for k in names))
    return named


# The sheets. Coordinates are page points (y up), read from the content stream (pdfpaths.py's dump).

E4021_PORTRA = Plot(
    "PORTRA ENDURA characteristic curves", 7, (374.19, 521.08, 558.70, 705.59),
    x=Axis([(-2.0, 436.15), (-1.0, 497.96)]), y=Axis([(1.0, 581.52), (2.0, 643.33)]), kind="char",
    order=("red", "green", "blue"),
    notes=["R and G end at the same density; R is the curve above at log H -0.9, where the sheet prints its R label, "
           "and B the lowest, by the label printed below its end",
           "the frame's bottom edge sits 0.022 D above the ticks' zero and its right edge 0.017 log H short of the ticks' "
           "0.0; the tick reading is kept, as for Portra 160's sheet, so the densities carry plus or minus 0.02 D"])
E4021_SUPRA = Plot(
    "SUPRA ENDURA characteristic curves", 7, (370.40, 268.21, 554.91, 452.71),
    x=Axis([(-3.0, 370.40), (0.0, 554.91)]), y=Axis([(1.0, 329.05), (2.0, 390.96)]), kind="char",
    order=("red", "green", "blue"),
    notes=["the x axis's -1.0 tick is drawn 0.25 log H right of where the frame and the -2.0 tick put it (a drafting "
           "error, like the label errors in the film sheets), so x is calibrated on the frame, whose ends carry the "
           "-3.0 and 0.0 labels; on the -2.0 tick instead the log H scale would be 1 percent longer",
           "R, G and B by D-max, the order the sheet's labels stand in at the curves' ends"])
E4021_DYE = Plot(
    "dye density (both papers)", 8, (81.44, 494.40, 265.41, 678.78),
    x=Axis([(400.0, 81.44), (450.0, 112.11), (500.0, 142.78), (550.0, 173.39), (600.0, 204.06), (650.0, 234.74),
            (700.0, 265.41)]),
    y=Axis([(0.0, 494.40), (0.5, 531.25), (1.0, 568.16), (1.5, 605.01), (2.0, 641.93)]), kind="dye")
E4021_SENS = Plot(
    "spectral sensitivity (both papers)", 8, (74.10, 271.24, 274.62, 422.72),
    x=Axis([(250.0, 74.10), (300.0, 94.19), (350.0, 114.29), (400.0, 134.38), (450.0, 154.48), (500.0, 174.58),
            (550.0, 194.67), (600.0, 214.77), (650.0, 234.87), (700.0, 254.96), (750.0, 274.62)]),
    y=Axis([(-2.0, 271.24), (-1.0, 309.11), (0.0, 346.98), (1.0, 384.85), (2.0, 422.72)]), kind="sens")

E4070_CHAR = Plot(
    "ENDURA Premier characteristic curves", 4, (364.68, 534.83, 549.20, 719.45),
    x=Axis([(-3.0, 364.68), (-2.0, 426.16), (-1.0, 487.72)]), y=Axis([(0.0, 534.83), (1.0, 596.35), (2.0, 657.93)]),
    kind="char", order=("red", "green", "blue"))
E4070_SENS = Plot(
    "ENDURA Premier spectral sensitivity", 4, (350.59, 324.67, 551.08, 476.26),
    x=Axis([(250.0 + 50 * i, c) for i, c in enumerate(
        (350.59, 370.64, 390.69, 410.75, 430.80, 450.86, 470.87, 490.92, 510.98, 531.03, 551.08))]),
    y=Axis([(-2.0, 324.67), (-1.0, 362.59), (0.0, 400.46), (1.0, 438.39), (2.0, 476.26)]), kind="sens")
E4070_DYE = Plot(
    "ENDURA Premier dye density", 5, (88.83, 557.09, 273.26, 741.43),
    x=Axis([(400.0, 88.83), (450.0, 119.63), (500.0, 150.35), (550.0, 181.08), (600.0, 211.81), (650.0, 242.54),
            (700.0, 273.26)]),
    y=Axis([(0.0, 557.09), (0.5, 593.98), (1.0, 630.81), (1.5, 667.70), (2.0, 704.53)]), kind="dye")


E4042_CHAR = Plot(
    "SUPRA ENDURA VC Digital characteristic curves", 5, (95.06, 530.12, 279.54, 714.65),
    x=Axis([(-3.0, 95.06), (-2.0, 156.60), (-1.0, 218.07)]), y=Axis([(0.0, 530.12), (1.0, 591.61), (2.0, 653.16)]),
    kind="char", order=("red", "green", "blue"),
    notes=["R, G and B by D-max, the order the sheet's labels stand in at the curves' ends"])
E4042_DYE = Plot(
    "SUPRA ENDURA VC Digital dye density", 5, (373.44, 531.97, 557.78, 716.33),
    x=Axis([(400.0, 373.44), (450.0, 404.20), (500.0, 434.93), (550.0, 465.59), (600.0, 496.32), (650.0, 527.05),
            (700.0, 557.78)]),
    y=Axis([(0.0, 531.97), (0.5, 568.84), (1.0, 605.71), (1.5, 642.58), (2.0, 679.46)]), kind="dye")
E4042_SENS = Plot(
    "SUPRA ENDURA VC Digital spectral sensitivity", 5, (227.43, 299.18, 427.98, 450.60),
    x=Axis([(250.0 + 50 * i, c) for i, c in enumerate(
        (227.43, 247.51, 267.54, 287.62, 307.65, 327.73, 347.76, 367.84, 387.87, 407.95, 427.98))]),
    y=Axis([(-2.0, 299.18), (-1.0, 337.02), (0.0, 374.86), (1.0, 412.76), (2.0, 450.60)]), kind="sens")


def _sens_axes(frame, grid):
    """A sensitivity plot's axes: 250 to 750 nm on the frame and its grid lines, log S -2 to 2."""
    x0, y0, x1, y1 = frame
    xs, ys = grid
    return (Axis([(250.0, x0)] + [(300.0 + 50 * i, c) for i, c in enumerate(xs)] + [(750.0, x1)]),
            Axis([(-2.0, y0)] + [(-1.0 + i, c) for i, c in enumerate(ys)] + [(2.0, y1)]))


def _dye_axes(frame, ticks, y_ticks):
    x0, y0, x1, y1 = frame
    return (Axis([(400.0, x0)] + [(450.0 + 50 * i, c) for i, c in enumerate(ticks)] + [(700.0, x1)]),
            Axis([(0.0, y0)] + [(0.5 * (i + 1), c) for i, c in enumerate(y_ticks)]))


# EDGE (E-7020, 2017-12) and ROYAL Digital (E-7021, 2019-04): characteristic and dye plots on page 3,
# sensitivity on page 4. The characteristic curves are drawn in short pieces. G ends highest, then R, then B
# (the labels at the curves' ends, looked at on the rendered pages).
_x, _y = _sens_axes((73.60, 539.46, 274.13, 690.93),
                    ((93.70, 113.80, 133.89, 153.99, 174.08, 194.18, 214.28, 234.37, 254.47), (577.33, 615.20, 653.06)))
_dx, _dy = _dye_axes((367.34, 277.02, 551.77, 461.36), (398.14, 428.86, 459.59, 490.32, 521.05),
                     (313.91, 350.74, 387.63, 424.46))
E7020_PLOTS = {
    "char": Plot("EDGE characteristic curves", 3, (368.40, 522.68, 555.63, 705.04),
                 x=Axis([(-3.0, 405.60), (-2.0, 443.09), (-1.0, 480.50), (0.0, 517.99)]),
                 y=Axis([(1.0, 567.86), (2.0, 613.45), (3.0, 659.04)]), kind="char", order=("green", "red", "blue"),
                 notes=["G ends highest, then R, then B, as the labels at the curves' ends stand"]),
    "dye": Plot("EDGE dye density", 3, (367.34, 277.02, 551.77, 461.36), x=_dx, y=_dy, kind="dye"),
    "sens": Plot("EDGE spectral sensitivity", 4, (73.60, 539.46, 274.13, 690.93), x=_x, y=_y, kind="sens"),
}
_x, _y = _sens_axes((73.57, 536.25, 274.09, 687.72),
                    ((93.66, 113.76, 133.85, 153.95, 174.05, 194.14, 214.24, 234.34, 254.43), (574.12, 611.98, 649.85)))
_dx, _dy = _dye_axes((365.92, 276.30, 550.35, 460.64), (396.71, 427.44, 458.16, 488.89, 519.62),
                     (313.20, 350.03, 386.92, 423.75))
E7021_PLOTS = {
    "char": Plot("ROYAL Digital characteristic curves", 3, (362.33, 536.78, 537.53, 712.43),
                 x=Axis([(-3.0, 397.37), (-2.0, 432.41), (-1.0, 467.44), (0.0, 502.49)]),
                 y=Axis([(1.0, 580.67), (2.0, 624.61), (3.0, 668.49)]), kind="char", order=("green", "red", "blue"),
                 notes=["G ends highest, then R, then B, as the labels at the curves' ends stand"]),
    "dye": Plot("ROYAL Digital dye density", 3, (365.92, 276.30, 550.35, 460.64), x=_dx, y=_dy, kind="dye"),
    "sens": Plot("ROYAL Digital spectral sensitivity", 4, (73.57, 536.25, 274.09, 687.72), x=_x, y=_y, kind="sens"),
}


def located(pdf: Path, plot: Plot) -> Plot:
    """The same plot in another edition of the sheet: moved to where that edition draws a frame of the same size."""
    x0, y0, x1, y1 = plot.frame
    best = None
    for p in page_paths(pdf, plot.page):
        if len(p) != 4 and len(p) != 5:
            continue
        bx0, by0 = p.min(axis=0)
        bx1, by1 = p.max(axis=0)
        if abs((bx1 - bx0) - (x1 - x0)) < 0.2 and abs((by1 - by0) - (y1 - y0)) < 0.2:
            d = np.hypot(bx0 - x0, by0 - y0)
            if best is None or d < best[0]:
                best = (d, bx0 - x0, by0 - y0)
    if best is None or best[0] > 20:
        raise SystemExit(f"{pdf.name}: no frame like {plot.name}'s")
    dx, dy = best[1], best[2]
    return Plot(plot.name, plot.page, (x0 + dx, y0 + dy, x1 + dx, y1 + dy),
                Axis([(v, c + dx) for v, c in plot.x.ticks]), Axis([(v, c + dy) for v, c in plot.y.ticks]),
                plot.kind, plot.order, plot.notes)


def extract(pdf: Path, plots: dict) -> dict:
    out = {}
    for key, plot in plots.items():
        data, residuals, raw = read_plot(pdf, plot)
        print(f"   {plot.name}: {len(data)} curves; axis tick residuals {residuals[0]:.3f} and {residuals[1]:.3f} pt"
              "")
        out[key] = (plot, name_curves(plot, data), raw)
    return out


def char_table(named):
    grids = {k: resample(*named[k], 0.05, 2) for k in LAYERS}
    lo = max(g[0][0] for g in grids.values())
    hi = min(g[0][-1] for g in grids.values())
    x = np.round(np.arange(lo, hi + 0.025, 0.05), 2)
    return x, {k: np.interp(x, grids[k][0], grids[k][1]) for k in LAYERS}


def spectral_table(named, keys, shared: bool):
    grids = {k: resample(*named[k], 5.0, 0) for k in keys}
    if shared:
        lo = max(g[0][0] for g in grids.values())
        hi = min(g[0][-1] for g in grids.values())
    else:
        lo = min(g[0][0] for g in grids.values())
        hi = max(g[0][-1] for g in grids.values())
    x = np.arange(lo, hi + 2.5, 5.0)
    table = {}
    for k in keys:
        gx, gy = grids[k]
        v = np.full(x.size, np.nan)
        inside = (x >= gx[0] - 1e-6) & (x <= gx[-1] + 1e-6)
        v[inside] = np.interp(x[inside], gx, gy)
        table[k] = v
    return x, table


# Review against the reviewed ENDURA Premier profile.


def review_e4070(pdf: Path):
    print(f"== review: {pdf.name} through this script against bake/papers/kodak-endura-premier.json")
    got = extract(pdf, {"char": E4070_CHAR, "sens": E4070_SENS, "dye": E4070_DYE})
    ref = json.loads((ROOT / "papers" / "kodak-endura-premier.json").read_text())
    x, curves = char_table(got["char"][1])
    rx = np.array(ref["characteristicCurves"]["logExposure"])
    worst = {}
    for k in LAYERS:
        rv = np.array(ref["characteristicCurves"][k])
        both = (rx >= x[0] - 1e-9) & (rx <= x[-1] + 1e-9)
        worst[f"char {k}"] = np.max(np.abs(np.interp(rx[both], x, curves[k]) - rv[both]))
    sx, sens = spectral_table(got["sens"][1], ("red", "green", "blue"), shared=False)
    rw = np.array(ref["spectralSensitivity"]["wavelengths"], dtype=float)
    for k in LAYERS:
        rv = np.array([np.nan if v is None else v for v in ref["spectralSensitivity"][k]], dtype=float)
        mine = np.interp(rw, sx, sens[k], left=np.nan, right=np.nan)
        both = ~np.isnan(rv) & ~np.isnan(mine)
        worst[f"sens {k}"] = np.max(np.abs(mine[both] - rv[both]))
    dx, dyes = spectral_table(got["dye"][1], DYES, shared=True)
    rw = np.array(ref["dyeDensity"]["wavelengths"], dtype=float)
    for k in DYES:
        rv = np.array(ref["dyeDensity"][k])
        both = (rw >= dx[0]) & (rw <= dx[-1])
        worst[f"dye {k}"] = np.max(np.abs(np.interp(rw[both], dx, dyes[k]) - rv[both]))
    for k, v in worst.items():
        print(f"   {k}: largest difference {v:.4f}")
    return worst


# Raster check: an independent renderer.


def raster_check(pdf: Path, plots: dict, extracted: dict, scale: float = 8.0):
    """Render the page with sips (Quartz, a renderer independent of this script) and measure how far each
    vector curve lies from the ink: for points every 2 pt along every curve, the distance in page points to the
    nearest dark pixel within 3 pt. Overlapping curves share ink, so this checks placement, not naming.
    """
    from PIL import Image
    results = {}
    with tempfile.TemporaryDirectory() as tmp:
        cache = {}
        for key, plot in plots.items():
            if plot.page not in cache:
                one = Path(tmp) / f"p{plot.page}.pdf"
                writer = pypdf.PdfWriter()
                writer.add_page(pypdf.PdfReader(str(pdf)).pages[plot.page - 1])
                writer.write(str(one))
                png = Path(tmp) / f"p{plot.page}.png"
                height_pt = float(pypdf.PdfReader(str(one)).pages[0].mediabox.height)
                subprocess.run(["sips", "-s", "format", "png", "-Z", str(int(scale * height_pt)), str(one),
                                "--out", str(png)], check=True, capture_output=True)
                image = np.asarray(Image.open(png).convert("L")) < 128
                cache[plot.page] = (image, image.shape[0] / height_pt)
            image, s = cache[plot.page]
            height = image.shape[0]
            sx, ox, _ = plot.x.fit()
            sy, oy, _ = plot.y.fit()
            distances = []
            for xv, yv in extracted[key][1].values():
                X = (xv - ox) / sx
                Y = (yv - oy) / sy
                arc = np.concatenate([[0.0], np.cumsum(np.hypot(np.diff(X), np.diff(Y)))])
                for a in np.arange(1.0, arc[-1] - 1.0, 2.0):
                    px, py = np.interp(a, arc, X) * s, (height_pt := height / s) * s - np.interp(a, arc, Y) * s
                    r = int(3 * s)
                    c0, r0 = int(px) - r, int(py) - r
                    window = image[max(r0, 0):r0 + 2 * r + 1, max(c0, 0):c0 + 2 * r + 1]
                    rows, cols = np.nonzero(window)
                    if rows.size == 0:
                        distances.append(3.0)
                        continue
                    d = np.hypot(rows + max(r0, 0) + 0.5 - py, cols + max(c0, 0) + 0.5 - px).min() / s
                    distances.append(d)
            distances = np.array(distances)
            results[key] = (float(np.median(distances)), float(np.percentile(distances, 99)), distances.size)
            print(f"   raster {plot.name}: the vector curves lie a median {results[key][0]:.3f} pt (99th percentile "
                  f"{results[key][1]:.3f} pt) from the rendered ink, {results[key][2]} points")
    return results


# Profiles.

COMMON = {
    "manufacturer": "Kodak",
    "status": "datasheet",
    "process": "RA-4, 95 F (35 C), 45 s; sensitometric exposure 0.5 s; Status A densitometry",
    "enlarger": {"kind": "blackbody", "kelvin": 3200},
    "viewing": {"kind": "daylight", "kelvin": 5003},
}


def method_text(tool_residual: float, review: dict, raster: dict | None) -> str:
    text = (f"vector paths of the datasheet PDF read with pypdf {pypdf.__version__} by bake/tools/paper_from_sheet.py "
            f"(Beziers flattened at {SAMPLES} samples per segment), axes calibrated by least squares on the labelled "
            f"tick and grid lines (largest residual {tool_residual:.4f} axis units), curves resampled by linear "
            f"interpolation every 0.05 log H and 5 nm; the same script reads E-4070 within "
            f"{max(v for k, v in review.items() if k.startswith('char')):.4f} Status A density, "
            f"{max(v for k, v in review.items() if k.startswith('sens')):.4f} log S and "
            f"{max(v for k, v in review.items() if k.startswith('dye')):.4f} D of the reviewed ENDURA Premier "
            f"profile")
    if raster:
        text += (f"; on a Quartz rendering of the page the curves lie a median {max(v[0] for v in raster.values()):.2f} pt "
                 f"(99th percentile {max(v[1] for v in raster.values()):.2f} pt) from the ink")
    return text


def profile(pid, display, publication, edition, url, notes, method, label_errors, char, sens, dye):
    x, curves = char
    sx, sv = sens
    dx, dv = dye
    data = {
        "schema": 2,
        "id": pid,
        "displayName": display,
        "manufacturer": COMMON["manufacturer"],
        "status": COMMON["status"],
        "notes": notes,
        "source": {"publication": publication, "edition": edition, "url": url, "digitized": DIGITIZED,
                   "method": method},
        "process": COMMON["process"],
        "spectralSensitivity": {"wavelengths": [int(w) for w in sx], **{k: fixed_list(sv[k], 4) for k in LAYERS}},
        "characteristicCurves": {"densitometry": "statusA", "logExposure": fixed_list(x, 2),
                                 **{k: fixed_list(curves[k], 4) for k in LAYERS}},
        "dyeDensity": {"wavelengths": [int(w) for w in dx], **{k: fixed_list(dv[k], 4) for k in DYES}},
        "minimumDensity": {"statusA": [Fixed(curves[k][0], 3) for k in LAYERS]},
        "enlarger": COMMON["enlarger"],
        "viewing": COMMON["viewing"],
    }
    if label_errors:
        data["source"]["labelErrors"] = label_errors
    return data


def write(path: Path, data: dict):
    text = emit(data) + "\n"
    json.loads(text)
    path.write_text(text, encoding="utf-8")
    print(f"   wrote {path}")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--e4021", type=Path, required=True, help="E-4021, September 2008 edition")
    parser.add_argument("--e4021-2009", type=Path, help="E-4021, September 2009 edition, for the cross-edition check")
    parser.add_argument("--e4042", type=Path, help="E-4042, July 2008 edition")
    parser.add_argument("--e4070", type=Path, required=True, help="E-4070, December 2017 edition (the review)")
    parser.add_argument("--e7020", type=Path, help="E-7020 (EDGE), December 2017 edition")
    parser.add_argument("--e7021", type=Path, help="E-7021 (ROYAL Digital), April 2019 edition")
    parser.add_argument("--raster-check", action="store_true")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args(argv)

    review = review_e4070(args.e4070)

    print(f"== {args.e4021.name}")
    plots = {"portra": E4021_PORTRA, "supra": E4021_SUPRA, "dye": E4021_DYE, "sens": E4021_SENS}
    got = extract(args.e4021, plots)
    residual = max(max(p.x.fit()[2], p.y.fit()[2]) for p in plots.values())
    raster = raster_check(args.e4021, plots, got) if args.raster_check else None
    if args.e4021_2009:
        print(f"== cross-edition: {args.e4021_2009.name}")
        other = extract(args.e4021_2009, {k: located(args.e4021_2009, p) for k, p in plots.items()})
        for key in plots:
            a, b = got[key][1], other[key][1]
            worst = max(np.max(np.abs(np.interp(a[k][0], b[k][0], b[k][1]) - a[k][1])) for k in a)
            print(f"   {plots[key].name}: largest difference between editions {worst:.4f}")

    sens = spectral_table(got["sens"][1], LAYERS, shared=False)
    dye = spectral_table(got["dye"][1], DYES, shared=True)
    for k in DYES:
        print(f"   {k} dye peak {np.nanmax(dye[1][k]):.4f} at {dye[0][int(np.nanargmax(dye[1][k]))]:.0f} nm")
    url = "https://125px.com/docs/paper/kodak/e4021.pdf"
    method = method_text(residual, review, raster)
    shared = ("The sheet prints one spectral sensitivity and one dye density plot for PORTRA ENDURA and SUPRA ENDURA "
              "together; both profiles carry them. Status A curves for a 0.5 s sensitometric exposure; the sheet does "
              "not say what light the sensitometer used, so the enlarger here is the same stand-in as ENDURA "
              "Premier's. No granularity and no MTF on the sheet.")
    portra = profile(
        "kodak-portra-endura", "Kodak Professional Portra Endura", "E-4021", "2008-09", url,
        "Digitized from the Kodak E-4021 datasheet of September 2008. Kodak calls it \"a low contrast paper, making "
        "it an ideal choice for portrait, studio, and wedding photography\"; the 2009 edition says it \"was "
        "discontinued in late 2006\". " + shared + " " + " ".join(n[0].upper() + n[1:] + "." for n in E4021_PORTRA.notes),
        method, None, char_table(got["portra"][1]), sens, dye)
    supra = profile(
        "kodak-supra-endura", "Kodak Professional Supra Endura", "E-4021", "2008-09", url,
        "Digitized from the Kodak E-4021 datasheet of September 2008. Kodak: \"slightly higher contrast and color "
        "saturation\" than PORTRA ENDURA; rolls \"discontinued by year end 2009\", SUPRA ENDURA VC Digital being "
        "\"the alternative replacement\". " + shared + " " + " ".join(n[0].upper() + n[1:] + "." for n in E4021_SUPRA.notes),
        method, "The characteristic plot's x axis -1.0 tick is drawn 0.25 log H right of its place.",
        char_table(got["supra"][1]), sens, dye)
    papers = [("PORTRA ENDURA", portra, "kodak-portra-endura.json"), ("SUPRA ENDURA", supra, "kodak-supra-endura.json")]
    if args.e4042:
        print(f"== {args.e4042.name}")
        plots42 = {"char": E4042_CHAR, "dye": E4042_DYE, "sens": E4042_SENS}
        got42 = extract(args.e4042, plots42)
        residual42 = max(max(p.x.fit()[2], p.y.fit()[2]) for p in plots42.values())
        raster42 = raster_check(args.e4042, plots42, got42) if args.raster_check else None
        dye42 = spectral_table(got42["dye"][1], DYES, shared=True)
        for k in DYES:
            print(f"   {k} dye peak {np.nanmax(dye42[1][k]):.4f} at {dye42[0][int(np.nanargmax(dye42[1][k]))]:.0f} nm")
        vc = profile(
            "kodak-supra-endura-vc-digital", "Kodak Professional Supra Endura VC Digital", "E-4042", "2008-07",
            "https://125px.com/docs/paper/kodak/E4042.pdf",
            "Digitized from the Kodak E-4042 datasheet of July 2008. Kodak: \"vivid color, neutral tone scale, and "
            "excellent flesh tones\", \"for making color prints from digital camera files or files from scanned "
            "negatives\" in digital printers; named for optical printing by the first sheets of today's Portra 400 "
            "(E-4050, 2010) and Portra 160 (E-4051, 2011); since replaced by ENDURA Premier. Status A curves for a "
            "0.5 s sensitometric exposure; the enlarger is the same stand-in as ENDURA Premier's. No granularity and "
            "no MTF on the sheet. " + " ".join(n[0].upper() + n[1:] + "." for n in E4042_CHAR.notes),
            method_text(residual42, review, raster42), None, char_table(got42["char"][1]),
            spectral_table(got42["sens"][1], LAYERS, shared=False), dye42)
        papers.append(("SUPRA ENDURA VC Digital", vc, "kodak-supra-endura-vc-digital.json"))
    minilab = (
        ("e7020", E7020_PLOTS, "kodak-edge", "Kodak Ektacolor Edge", "E-7020", "2017-12",
         "https://business.kodakmoments.com/sites/default/files/files/products/e7020.pdf",
         "Digitized from the Kodak E-7020 datasheet of December 2017. Kodak: \"for making direct digital prints from "
         "digital files, as well as optical prints from color negatives\", \"enhanced color reproduction\"; named "
         "first by Gold 200's (E-7022, 2023) and UltraMax 400's (E-7023, 2016) sheets. Process RA-4 at 100 F (38 C), "
         "45 s; the sheet gives no sensitometric exposure time. The characteristic curves are drawn in short pieces, "
         "chained end to end."),
        ("e7021", E7021_PLOTS, "kodak-royal-digital", "Kodak Royal Digital", "E-7021", "2019-04",
         "https://business.kodakmoments.com/sites/default/files/files/products/e7021.pdf",
         "Digitized from the Kodak E-7021 datasheet of April 2019. Kodak: \"bold, saturated colors\"; named by "
         "Gold 200's and UltraMax 400's sheets. Process RA-4 at 100 F (38 C), 45 s; the sheet gives no sensitometric "
         "exposure time. The characteristic curves are drawn in short pieces, chained end to end."),
    )
    for arg, plots_m, pid, display, publication, edition, url, notes in minilab:
        pdf = getattr(args, arg)
        if pdf is None:
            continue
        print(f"== {pdf.name}")
        got_m = extract(pdf, plots_m)
        residual_m = max(max(p.x.fit()[2], p.y.fit()[2]) for p in plots_m.values())
        raster_m = raster_check(pdf, plots_m, got_m) if args.raster_check else None
        dye_m = spectral_table(got_m["dye"][1], DYES, shared=True)
        data = profile(pid, display, publication, edition, url,
                       notes + " Status A curves; the enlarger is the same stand-in as ENDURA Premier's. No granularity "
                       "and no MTF on the sheet. " + " ".join(n[0].upper() + n[1:] + "." for n in plots_m["char"].notes),
                       method_text(residual_m, review, raster_m), None, char_table(got_m["char"][1]),
                       spectral_table(got_m["sens"][1], LAYERS, shared=False), dye_m)
        data["process"] = "RA-4, 100 F (38 C), 45 s; Status A densitometry; the sheet states no sensitometric exposure time"
        papers.append((display, data, f"{pid}.json"))
    for name, data, _ in papers:
        c = data["characteristicCurves"]
        print(f"   {name}: log H {c['logExposure'][0].text()} to {c['logExposure'][-1].text()}, D-min "
              + "/".join(v.text() for v in data["minimumDensity"]["statusA"]))
    if args.write:
        for _, data, file in papers:
            write(ROOT / "papers" / file, data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
