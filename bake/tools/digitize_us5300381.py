#!/usr/bin/env python3
"""Digitize US5300381's FIG. 1 and FIG. 2 (Kodak, Buhr and Franchino, 1994): the tone reproduction "as
perceived" of "a typical amateur film/paper system" (FIG. 1) and "a typical professional film/paper system"
(FIG. 2), solid curves D and D' against scene exposure density, docs/research/film-sim/print.md section 3.

The drawings are raster scans in the patent's PDF (patentimages.storage.googleapis.com, US5300381.pdf, pages
2 and 3, 2320 by 3408 pixels). Usage:

    python -I bake/tools/digitize_us5300381.py US5300381.pdf

prints, for each figure, the frame it found, the solid curve every 0.05 of scene density from -0.6 to 2.4,
and its read-back at the axis labels. The axes are the frame: scene density 2.4 at the left edge and -0.6 at
the right, density 0.0 at the bottom and 2.6 at the top, as the figure labels them; the tick marks between are
used as a check (each labelled tick within the stated tolerance of where the frame puts it).

Method: binarize at half intensity; find the frame's four lines; on every pixel column between them find the
dark runs; follow the solid curve from its right end (scene density -0.6, where it is alone and flat) leftward,
predicting each column from the last five and taking the nearest run within 8 pixels; the dashed gradient
curve and the tick marks are left behind because the solid line is continuous and the prediction rejects
jumps. A column where the dashed curve crosses gives two runs; the nearer to the prediction is taken.
"""

from __future__ import annotations

import sys

import numpy as np
import pypdf
from PIL import Image

SCENE = np.round(np.arange(-0.6, 2.4001, 0.05), 2)


def page_image(pdf: str, page: int) -> np.ndarray:
    reader = pypdf.PdfReader(pdf)
    image = list(reader.pages[page - 1].images)[0].image.convert("L")
    return np.asarray(image) < 128


def frame(dark: np.ndarray):
    h, w = dark.shape
    rows = dark.sum(axis=1)
    horizontal = [y for y in range(h) if rows[y] > 0.35 * w]
    groups = np.split(np.array(horizontal), np.flatnonzero(np.diff(horizontal) > 3) + 1)
    top, bottom = groups[0].mean(), groups[-1].mean()
    band = dark[int(top) + 10:int(bottom) - 10]
    cols = band.sum(axis=0)
    left_half, right_half = cols[: w // 2], cols[w // 2:]
    left = float(np.argmax(left_half))
    right = float(w // 2 + np.argmax(right_half))
    # The lines are several pixels thick: take the centre of the run around each maximum.
    def centre(profile, at):
        lo = at
        while lo > 0 and profile[lo - 1] > 0.5 * profile[at]:
            lo -= 1
        hi = at
        while hi < profile.size - 1 and profile[hi + 1] > 0.5 * profile[at]:
            hi += 1
        return (lo + hi) / 2, hi - lo + 1
    left, lw = centre(cols, int(left))
    right, rw = centre(cols, int(right))
    return top, bottom, left, right, (groups[0].size, groups[-1].size, lw, rw)


def _runs(dark, x, y0, y1):
    ys = np.flatnonzero(dark[y0:y1, x]) + y0
    if ys.size == 0:
        return []
    cuts = np.flatnonzero(np.diff(ys) > 1)
    starts = np.concatenate([[ys[0]], ys[cuts + 1]])
    ends = np.concatenate([ys[cuts], [ys[-1]]])
    return [((s + e) / 2, e - s + 1) for s, e in zip(starts, ends)]


def _track(runs, columns, start, width):
    """Follow a continuous line along `columns` from pixel row `start`. Where it meets another line their runs
    merge into one thicker run, whose centre is biased: there the prediction from the last five columns is kept."""
    ys = [start]
    for x in columns[1:]:
        slope = (ys[-1] - ys[-6]) / 5 if len(ys) >= 6 else 0.0
        pred = ys[-1] + slope
        near = [(c, w) for c, w in runs[x] if abs(c - pred) < 8 + abs(slope)]
        if near:
            c, w = min(near, key=lambda r: abs(r[0] - pred))
            # A steep line's run is longer, by its slope; longer still means two lines overlap.
            ys.append(c if w <= 1.6 * width * np.hypot(1.0, slope) + abs(slope) else pred)
        else:
            ys.append(pred)
    return np.array(ys, dtype=float)


def _without_dashes(dark, x0, x1, y0, y1):
    """The plot's interior with every connected piece of ink smaller than a fifth of the frame's width removed:
    the gradient curve is dashed, so its dashes go and the continuous solid curve stays (a dash that touches the
    solid curve stays with it; the tracker's overlap rule handles those few columns)."""
    inner = dark[y0:y1, x0:x1].copy()
    h, w = inner.shape
    seen = np.zeros_like(inner, dtype=bool)
    keep = np.zeros_like(inner, dtype=bool)
    for sy, sx in zip(*np.nonzero(inner)):
        if seen[sy, sx]:
            continue
        stack = [(sy, sx)]
        seen[sy, sx] = True
        pixels = []
        while stack:
            y, x = stack.pop()
            pixels.append((y, x))
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < h and 0 <= nx < w and inner[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True
                        stack.append((ny, nx))
        xs = [p[1] for p in pixels]
        if max(xs) - min(xs) > 0.2 * w:
            for y, x in pixels:
                keep[y, x] = True
    out = np.zeros_like(dark)
    out[y0:y1, x0:x1] = keep
    return out


def solid_curve(dark, top, bottom, left, right, thickness):
    pad = int(max(thickness)) + 3
    x0, x1 = int(left) + pad, int(right) - pad
    y0, y1 = int(top) + pad, int(bottom) - pad
    dark = _without_dashes(dark, x0, x1, y0, y1)
    runs = {x: _runs(dark, x, y0, y1) for x in range(x0, x1)}
    # The solid line's own thickness, where it runs flat and alone at the right end.
    width = float(np.median([min(runs[x], key=lambda r: abs(r[0] - (bottom - 0.12 / 2.6 * (bottom - top))))[1]
                             for x in range(x1 - 40, x1)]))

    def to_px(d):
        return bottom - d / 2.6 * (bottom - top)
    # From the right end (scene -0.6), where the solid curve is the run nearest 0.12 of the axis (the dashed one
    # is near 0.02), leftward; and from the left end (scene 2.4), where it is the topmost run, rightward.
    leftward = list(range(x1 - 1, x0 - 1, -1))
    a = _track(runs, leftward, min(runs[x1 - 1], key=lambda r: abs(r[0] - to_px(0.12)))[0], width)[::-1]
    b = _track(runs, list(range(x0, x1)), min(r[0] for r in runs[x0]), width)
    # The two agree from where the curve leaves the crossings behind; join them at the column, nearest the middle
    # of the frame, where they agree best.
    xs = np.arange(x0, x1)
    agree = np.abs(a - b)
    middle = np.argmin(np.abs(xs - (x0 + x1) / 2))
    candidates = np.flatnonzero(agree < 1.0)
    join = candidates[np.argmin(np.abs(candidates - middle))] if candidates.size else middle
    ys = np.where(xs <= xs[join], b, a)
    scene = 2.4 - 3.0 * (xs - left) / (right - left)
    density = 2.6 * (bottom - ys) / (bottom - top)
    order = np.argsort(scene)
    return scene[order], density[order], float(scene[join]), float(np.median(agree[candidates])) if candidates.size else np.nan


def main(argv) -> int:
    pdf = argv[1]
    for page, name in ((2, "FIG. 1, typical amateur film/paper system"), (3, "FIG. 2, typical professional film/paper system")):
        dark = page_image(pdf, page)
        top, bottom, left, right, thickness = frame(dark)
        scene, density, joined, agreement = solid_curve(dark, top, bottom, left, right, thickness)
        print(f"{name}: frame top {top:.1f}, bottom {bottom:.1f}, left {left:.1f}, right {right:.1f} px "
              f"(line widths {thickness}); {(right - left) / 3.0:.1f} px per unit of scene density, "
              f"{(bottom - top) / 2.6:.1f} px per unit of density")
        print(f"  the two passes joined at scene density {joined:.2f}, where they agree within 1 px")
        table = np.interp(SCENE, scene, density)
        print("  scene: " + " ".join(f"{s:.2f}" for s in SCENE))
        print("  D:     " + " ".join(f"{d:.3f}" for d in table))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
