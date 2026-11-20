"""A ColorChecker through a stock and the print, for checks against what Kodak says of each stock.

The 24 patches are BabelColor's published averages (CIELAB under D50; the same source
`tools/skin_locus.py` uses for the skin patches), adapted to D65 by Bradford and taken into
white-balanced linear Rec. 2020 with the neutral 5 patch at the metered mid-gray, which is what
a D55-pinned decode of a daylight scene gives a gray. `render` takes them through a stock's
negative model and its print (its paper and, if it names one, its tone stage) at the daylight reference filtration (mid-gray prints at 0.18) and
reads the print back as CIELAB under D65 with paper white at 100. `tools/checker_through_stocks.py`
prints the numbers; docs/research/film.md section 4.2 discusses them.
"""

import numpy as np

from .negative import MID_GRAY, dye_amounts
from .paper import paper_named
from .printing import Printer, calibrate
from .spectral import D65_XY, adaptation_matrix, rgb_to_xyz_matrix, xy_to_xyz

NAMES = ["dark skin", "light skin", "blue sky", "foliage", "blue flower", "bluish green", "orange", "purplish blue",
         "moderate red", "purple", "yellow green", "orange yellow", "blue", "green", "red", "yellow", "magenta", "cyan",
         "white", "neutral 8", "neutral 6.5", "neutral 5", "neutral 3.5", "black"]
BABELCOLOR_D50 = np.array([
    [37.99, 13.56, 14.06], [65.71, 18.13, 17.81], [49.93, -4.88, -21.93], [43.14, -13.10, 21.91],
    [55.11, 8.84, -25.40], [70.72, -33.40, -0.20], [62.66, 36.07, 57.10], [40.02, 10.41, -45.96],
    [51.12, 48.24, 16.25], [30.33, 22.98, -21.59], [72.53, -23.71, 57.26], [71.94, 19.36, 67.86],
    [28.78, 14.18, -50.30], [55.26, -38.34, 31.37], [42.10, 53.38, 28.19], [81.73, 4.04, 79.82],
    [51.94, 49.99, -14.57], [51.04, -28.63, -28.64], [96.54, -0.43, 1.19], [81.26, -0.64, -0.34],
    [66.77, -0.73, -0.50], [50.87, -0.15, -0.27], [35.66, -0.42, -1.23], [20.46, -0.08, -0.97]])
COLOURED = slice(0, 18)
NEUTRAL_5 = 21
D50 = np.array([0.9642, 1.0, 0.8251])
D65 = xy_to_xyz(*D65_XY)
TO_XYZ = rgb_to_xyz_matrix(white_xyz=D65)


def lab_to_xyz(lab: np.ndarray, white: np.ndarray) -> np.ndarray:
    fy = (lab[:, 0] + 16) / 116
    f = np.stack([fy + lab[:, 1] / 500, fy, fy - lab[:, 2] / 200], axis=-1)
    return np.where(f ** 3 > 216 / 24389, f ** 3, (116 * f - 16) / (24389 / 27)) * white


def xyz_to_lab(xyz: np.ndarray, white: np.ndarray) -> np.ndarray:
    t = xyz / white
    f = np.where(t > 216 / 24389, np.cbrt(t), (24389 / 27 * t + 16) / 116)
    return np.stack([116 * f[:, 1] - 16, 500 * (f[:, 0] - f[:, 1]), 200 * (f[:, 1] - f[:, 2])], axis=-1)


def delta_e_2000(lab1: np.ndarray, lab2: np.ndarray) -> np.ndarray:
    l1, a1, b1 = lab1.T
    l2, a2, b2 = lab2.T
    c_bar = (np.hypot(a1, b1) + np.hypot(a2, b2)) / 2
    g = 0.5 * (1 - np.sqrt(c_bar ** 7 / (c_bar ** 7 + 25 ** 7)))
    a1p, a2p = (1 + g) * a1, (1 + g) * a2
    c1p, c2p = np.hypot(a1p, b1), np.hypot(a2p, b2)
    h1, h2 = np.degrees(np.arctan2(b1, a1p)) % 360, np.degrees(np.arctan2(b2, a2p)) % 360
    dh = h2 - h1
    dh = np.where(dh > 180, dh - 360, np.where(dh < -180, dh + 360, dh))
    dh = np.where(c1p * c2p == 0, 0, dh)
    d_h = 2 * np.sqrt(c1p * c2p) * np.sin(np.radians(dh / 2))
    l_bar, cp_bar = (l1 + l2) / 2, (c1p + c2p) / 2
    total = h1 + h2
    h_bar = np.where(c1p * c2p == 0, total,
                     np.where(np.abs(h1 - h2) > 180, np.where(total < 360, (total + 360) / 2, (total - 360) / 2), total / 2))
    t = (1 - 0.17 * np.cos(np.radians(h_bar - 30)) + 0.24 * np.cos(np.radians(2 * h_bar))
         + 0.32 * np.cos(np.radians(3 * h_bar + 6)) - 0.20 * np.cos(np.radians(4 * h_bar - 63)))
    rotation = 30 * np.exp(-((h_bar - 275) / 25) ** 2)
    r_c = 2 * np.sqrt(cp_bar ** 7 / (cp_bar ** 7 + 25 ** 7))
    s_l = 1 + 0.015 * (l_bar - 50) ** 2 / np.sqrt(20 + (l_bar - 50) ** 2)
    s_c, s_h = 1 + 0.045 * cp_bar, 1 + 0.015 * cp_bar * t
    r_t = -np.sin(np.radians(2 * rotation)) * r_c
    dl, dc = l2 - l1, c2p - c1p
    return np.sqrt((dl / s_l) ** 2 + (dc / s_c) ** 2 + (d_h / s_h) ** 2 + r_t * (dc / s_c) * (d_h / s_h))


def scene() -> tuple[np.ndarray, np.ndarray]:
    """(linear Rec. 2020 with neutral 5 at mid-gray, the scene's CIELAB under D65 on the same scale)."""
    xyz = lab_to_xyz(BABELCOLOR_D50, D50) @ adaptation_matrix(D50, D65).T
    xyz = xyz * (MID_GRAY / xyz[NEUTRAL_5, 1])
    return xyz @ np.linalg.inv(TO_XYZ).T, xyz_to_lab(xyz, D65)


def render(profile, rgb: np.ndarray) -> np.ndarray:
    """CIELAB under D65 of the print, paper white at L* 100."""
    from .print_stage import stage_for
    paper = paper_named(profile.paper)
    printer = Printer(paper, profile.dyes, profile.base, stage=stage_for(profile, paper))
    offsets = calibrate(printer, dye_amounts(profile, np.full(3, MID_GRAY)))
    out = np.array([printer(dye_amounts(profile, colour), offsets) for colour in rgb])
    return xyz_to_lab(out @ TO_XYZ.T, D65)
