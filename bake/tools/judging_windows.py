#!/usr/bin/env python3
"""Print each stock against its sheet's "Judging negative exposures" table.

Every sheet prints the Status M red density a normally exposed and processed negative should
have for three subjects: a KODAK Gray Card (gray side), the lightest step of a KODAK Paper Gray
Scale (nominal density 0.1, so 10^-0.1 reflectance; Kodak's product page), and the highest
diffuse density on a normally lit forehead of light and of dark complexion, which the sheets
call a guide only. They are the only published densities of processed patches for these
stocks (docs/research/film.md, section 3). The gray card and the white step are bake gates
(`negative.check_gates`); the forehead rows are compared here with NIST's 100 forearms, which
are not foreheads and not their highest diffuse density, so they are a sanity check only.

For each stock it prints the red density at the bake's mid-gray and at the white step, the
exposure shift in stops that would put both on their windows' centres (least squares on the
red curve), and the NIST forearms' red densities, computed spectrally: each reflectance under
the bake's D55 through the stock's red sensitivity, relative to an 18 percent gray, placed by
the bake's mid-gray and read off the red curve.

NIST's Reference Data Set of Human Skin Reflectance is a work of NIST employees, not subject to
copyright in the United States (https://www.nist.gov/open/license); `tools/skin_locus.py` says
how it is read.

    cd bake && PYTHONPATH=. ../.venv/bin/python tools/judging_windows.py [path to skinrefl_v3.txt]
"""

import math
import sys
from pathlib import Path

import numpy as np

from argent_bake.negative import (MID_GRAY, REFERENCE_ILLUMINANT, WHITE_STEP_REFLECTANCE, gray_card_red_density,
                                  mid_gray_log_exposure, white_step_red_density)
from argent_bake.profile import load_profile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from skin_locus import DEFAULT, load_nist  # noqa: E402

STOCKS = ["portra400", "portra160", "portra800", "ektar100", "gold200", "ultramax400"]


def centring_shift(profile) -> float:
    """Stops of exposure that put the gray card and the white step nearest their windows' centres."""
    mid = mid_gray_log_exposure(profile.box_speed)
    targets = [sum(profile.gray_card) / 2, sum(profile.white_step) / 2]
    offsets = [0.0, math.log10(WHITE_STEP_REFLECTANCE / MID_GRAY)]
    shifts = np.linspace(-1.0, 1.0, 2001)  # log H
    errors = [sum((float(np.interp(mid + s + o, profile.log_exposure, profile.curves[:, 0])) - t) ** 2
                  for o, t in zip(offsets, targets)) for s in shifts]
    return float(shifts[int(np.argmin(errors))] / math.log10(2.0))


def main(argv: list[str]) -> int:
    path = Path(argv[1]) if len(argv) > 1 else DEFAULT
    skins = load_nist(path) if path.exists() else None
    root = Path(__file__).resolve().parents[1] / "stocks"
    print("stock        gray card (window)        white step (window)       shift to centres  "
          "NIST forearms p10 / median / p90 (light; dark window)")
    for name in STOCKS:
        profile = load_profile(root / f"{name}.json")
        gray, white = gray_card_red_density(profile), white_step_red_density(profile)
        line = (f"{name:12s} {gray:.3f} ({profile.gray_card[0]:.2f}-{profile.gray_card[1]:.2f})    "
                f"{white:.3f} ({profile.white_step[0]:.2f}-{profile.white_step[1]:.2f})    "
                f"{centring_shift(profile):+.2f} stops       ")
        if skins is not None:
            red = profile.sensitivity[:, 0] * REFERENCE_ILLUMINANT
            relative = (skins @ red) / (MID_GRAY * red.sum())
            x = mid_gray_log_exposure(profile.box_speed) + np.log10(relative)
            density = np.interp(x, profile.log_exposure, profile.curves[:, 0])
            p10, p50, p90 = np.percentile(density, [10, 50, 90])
            light, dark = profile.forehead["lightComplexion"], profile.forehead["darkComplexion"]
            line += (f"{p10:.3f} / {p50:.3f} / {p90:.3f} ({light[0]:.2f}-{light[1]:.2f}; "
                     f"{dark[0]:.2f}-{dark[1]:.2f}), lightest forearm reflects {relative.max() * MID_GRAY:.2f} "
                     f"to the red layer, darkest {relative.min() * MID_GRAY:.2f}")
        else:
            line += f"(no NIST data at {path})"
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
