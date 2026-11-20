#!/usr/bin/env python3
"""Print where skin sits in the decode's colour under the reference light, for auto lab balance's
skin estimate (`SkinBalance` in Sources/ArgentRoll/RollControls.swift).

The decode pins a CIE D55 neutral, so a gray lit by D55 decodes to equal red, green and blue in
linear Rec. 2020. A skin's colour there is its reflectance under D55 through the CIE 1931 observer,
adapted from D55's white to D65's (Bradford) and taken into Rec. 2020; the camera and Apple's matrix
stand in for the observer (inference). Each colour is given as auto lab balance's axes: red against
blue and green against magenta, in stops (`AutoBalance.axes`).

The reflectances are NIST's Reference Data Set of Human Skin Reflectance (Cooksey, Allen and Tsai,
J. Res. NIST 122:26, 2017, https://doi.org/10.6028/jres.122.026; data https://doi.org/10.18434/M38597):
100 subjects, the inside of the right forearm, 8/h reflectance factor, 250 to 2500 nm every 3 nm, no
selection by skin tone. Data of the National Institute of Standards and Technology, not subject to
copyright in the United States (https://www.nist.gov/open/license, read 2026-10-07). Here the
average of each subject's three scans is resampled to 380 to 780 nm every 5 nm; nothing else in the
data is changed. The set is light-skewed, so the ColorChecker's light and dark skin (BabelColor's
published averages, CIELAB under D50: 65.71, 18.13, 17.81 and 37.99, 13.56, 14.06) are given beside
it, adapted from D50 the same way.

A first try darkened each NIST skin with melanin's published absorption, (lambda / 500 nm)^-3.5
(Jacques, Phys. Med. Biol. 58 R37, 2013), through the epidermis twice: it carried red against blue
to +4 stops for 2.6 stops darker, against +1.18 for the ColorChecker's dark skin, so a bare
Beer-Lambert layer does not describe skin and is not used (docs/M3-auto.md section 16).

    cd bake && PYTHONPATH=. ../.venv/bin/python tools/skin_locus.py [path to skinrefl_v3.txt]
"""

import math
import sys
from pathlib import Path

import numpy as np

from argent_bake.spectral import (D55, D65_XY, WAVELENGTHS, adaptation_matrix, cie_1931, rgb_to_xyz_matrix,
                                  white_point, xy_to_xyz)

DEFAULT = Path(__file__).resolve().parents[2] / "references/auto-printing/nist-skin-reflectance/skinrefl_v3.txt"
COLORCHECKER_D50 = {"light skin": (65.71, 18.13, 17.81), "dark skin": (37.99, 13.56, 14.06)}
D50_WHITE = np.array([0.9642, 1.0, 0.8251])


def load_nist(path: Path) -> np.ndarray:
    """Each subject's average reflectance on the bake grid, (subjects, wavelengths)."""
    rows = []
    for line in path.read_bytes().decode("latin-1").splitlines():
        fields = line.split(",")
        try:
            wavelength = float(fields[0])
        except ValueError:
            continue
        rows.append([wavelength] + [float(v) if v.strip() else math.nan for v in fields[1:401]])
    table = np.asarray(rows)
    wl, scans = table[:, 0], table[:, 1:]
    averages = scans[:, 3::4]  # R1, R2, R3, Average for each subject
    return np.stack([np.interp(WAVELENGTHS, wl, averages[:, s]) for s in range(averages.shape[1])])


def decode_rgb(reflectance: np.ndarray) -> np.ndarray:
    """Linear Rec. 2020 of reflectances under D55 in a D55-pinned decode, a D55 gray of 1 at (1, 1, 1)."""
    cmf = cie_1931()
    xyz = (reflectance * D55) @ cmf / (D55 @ cmf)[1]
    adapted = xyz @ adaptation_matrix(white_point(D55), xy_to_xyz(*D65_XY)).T
    return adapted @ np.linalg.inv(rgb_to_xyz_matrix()).T


def lab_d50_rgb(lab) -> np.ndarray:
    """Linear Rec. 2020 of a CIELAB colour under D50, adapted to D65's white."""
    lightness, a, b = lab
    fy = (lightness + 16) / 116
    f = [fy + a / 500, fy, fy - b / 200]
    xyz = np.array([t ** 3 if t ** 3 > 216 / 24389 else (116 * t - 16) / (24389 / 27) for t in f]) * D50_WHITE
    return np.linalg.inv(rgb_to_xyz_matrix()) @ (adaptation_matrix(D50_WHITE, xy_to_xyz(*D65_XY)) @ xyz)


def axes(rgb: np.ndarray) -> np.ndarray:
    """Red against blue and green against magenta, stops."""
    r, g, b = (np.log2(rgb[..., k]) for k in range(3))
    return np.stack([r - b, g - (r + b) / 2], axis=-1)


def luminance(rgb: np.ndarray) -> np.ndarray:
    return rgb @ np.array([0.2627, 0.6780, 0.0593])


def main() -> None:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
    rgb = decode_rgb(load_nist(path))
    gray = decode_rgb(np.full((1, WAVELENGTHS.size), 0.18))[0]
    print(f"A D55 gray of 0.18 decodes to {gray[0]:.4f} {gray[1]:.4f} {gray[2]:.4f}")
    a, y = axes(rgb), luminance(rgb)
    print(f"NIST forearms, n={len(rgb)}: Y median {np.median(y):.3f} (p10 {np.percentile(y, 10):.3f}, p90 {np.percentile(y, 90):.3f})")
    for k, name in enumerate(("red against blue", "green against magenta")):
        v = a[:, k]
        print(f"  {name}: median {np.median(v):+.3f}, min {v.min():+.3f}, p5 {np.percentile(v, 5):+.3f}, p95 {np.percentile(v, 95):+.3f}, max {v.max():+.3f}")
    stops = np.log2(y)
    fit = np.vstack([stops, np.ones_like(stops)]).T
    slope_rb = np.linalg.lstsq(fit, a[:, 0], rcond=None)[0][0]
    slope_gm = np.linalg.lstsq(fit, a[:, 1], rcond=None)[0][0]
    print(f"  per stop darker: red against blue {-slope_rb:+.3f}, green against magenta {-slope_gm:+.3f}"
          f" (correlation of red against blue with log luminance {np.corrcoef(stops, a[:, 0])[0, 1]:+.2f})")
    for name, lab in COLORCHECKER_D50.items():
        c = lab_d50_rgb(lab)
        print(f"ColorChecker {name}: Y {luminance(c):.3f}, red against blue {axes(c)[0]:+.3f}, green against magenta {axes(c)[1]:+.3f}")


if __name__ == "__main__":
    main()
