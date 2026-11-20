#!/usr/bin/env python3
"""Fit each stock's inter-layer couplers to the gamma ratios published for commercial films.

No sheet publishes a stock's interimage. What is published (docs/research/film.md, section 4.2) is
the gamma ratio, a layer's Status M gamma under a separation exposure over its gamma under white
light, measured on commercial colour negatives: Fuji's EP1693702A1 (2005), Table 3, gives KODAK MAX
400 1.36, 1.61, 1.29, KODAK HD 400 1.38, 1.81, 1.33 and FUJICOLOR NPH 400 1.50, 1.27, 0.97 (red,
green, blue; verified), and Kodak's US6696232B2 says films for optical printing run 1.3 to 2.2
(verified). Each stock takes the anchor of its class (inference, section 4.2):

- Gold 200 and UltraMax 400, Kodak's consumer films: MAX 400.
- Ektar 100, sold for "high saturation and ultra-vivid color": HD 400, Kodak's high-saturation film.
- Portra 160, the natural one: NPH 400's green and blue, Fuji's professional portrait film beside
  it in the same table, with red at the 1.36 both Kodak films share.
- Portra 400 ("exceptional color saturation"): halfway between.
- Portra 800: 0.62 of the way from natural to MAX 400 (since 2026-10-07). Kodak's 2023 catalogue and
  2017 colour negative brochure both rank its saturation above Portra 400's and below Ektar's; at
  halfway it printed just below Portra 400 once the exposure matrix stopped losing chroma, and 0.62
  is the smallest step (in hundredths) that puts it 0.02 above (docs/research/film-sim/bakelook.md
  section 4, `bakelook/portra800.py`). Still inside the class, strictly below Ektar's HD 400.

Each receiving layer's coupling is split between the two layers that inhibit it as Kodak's
patents describe it (US6620580B2, US5314792A; inference): green takes half from red and half
from blue; red three quarters from green and a quarter from blue; blue three quarters from green
and a quarter from red. One scale per receiving layer is then found by bisection so the model's
gamma ratio (`negative.gamma_ratios`) meets the anchor, the three in turn until they hold
together. The matrices printed are what `profile_from_extraction.py` writes into the profiles.

    cd bake && PYTHONPATH=. ../.venv/bin/python tools/fit_couplers.py
"""

import dataclasses
from pathlib import Path

import numpy as np

from argent_bake.negative import gamma_ratios, mid_gray_log_exposure
from argent_bake.profile import load_profile

ANCHORS = {
    "KODAK MAX 400": (1.36, 1.61, 1.29),
    "KODAK HD 400": (1.38, 1.81, 1.33),
    "natural": (1.36, 1.27, 0.97),  # NPH 400's green and blue, the Kodak films' red
}
ANCHORS["between"] = tuple(round((a + b) / 2, 3) for a, b in zip(ANCHORS["natural"], ANCHORS["KODAK MAX 400"]))
PORTRA_800_STEP = 0.62
ANCHORS["0.62 of the way"] = tuple(round(a + PORTRA_800_STEP * (b - a), 3)
                                   for a, b in zip(ANCHORS["natural"], ANCHORS["KODAK MAX 400"]))
CLASS = {
    "portra160": "natural", "portra400": "between", "portra800": "0.62 of the way",
    "ektar100": "KODAK HD 400", "gold200": "KODAK MAX 400", "ultramax400": "KODAK MAX 400",
}
# SPLIT[j][k]: the share of receiving layer j's coupling that comes from layer k.
SPLIT = np.array([[0.0, 0.75, 0.25], [0.5, 0.0, 0.5], [0.25, 0.75, 0.0]])


def amount_gamma(profile) -> np.ndarray:
    """Each dye amount's gradient per log H over a stop either side of mid-gray."""
    mid = mid_gray_log_exposure(profile.box_speed)
    return np.array([(np.interp(mid + 0.3, profile.log_exposure, profile.amount_curves[:, k])
                      - np.interp(mid - 0.3, profile.log_exposure, profile.amount_curves[:, k])) / 0.6 for k in range(3)])


def fit(profile, target, rounds: int = 8) -> np.ndarray:
    """The coupler matrix whose gamma ratios meet `target`, with SPLIT's shares per receiving layer."""
    per_unit = SPLIT / amount_gamma(profile)[None, :]
    couplers = np.zeros((3, 3))
    for j in [0, 1, 2] * rounds:
        low, high = 0.0, 4.0
        for _ in range(50):
            scale = (low + high) / 2
            couplers[j] = scale * per_unit[j]
            if gamma_ratios(dataclasses.replace(profile, couplers=couplers))[j] < target[j]:
                low = scale
            else:
                high = scale
        couplers[j] = (low + high) / 2 * per_unit[j]
    return couplers


def main() -> None:
    root = Path(__file__).resolve().parents[1] / "stocks"
    for name, anchor in CLASS.items():
        profile = load_profile(root / f"{name}.json")
        target = ANCHORS[anchor]
        before = gamma_ratios(dataclasses.replace(profile, couplers=np.zeros((3, 3))))
        couplers = np.round(fit(profile, target), 3)
        after = gamma_ratios(dataclasses.replace(profile, couplers=couplers))
        print(f"{name:12s} anchor {anchor} {target}: gamma ratios with no couplers "
              + ", ".join(f"{v:.3f}" for v in before) + "; fitted, rounded " + ", ".join(f"{v:.3f}" for v in after))
        print("             interLayer " + str([[float(v) for v in row] for row in couplers]))


if __name__ == "__main__":
    main()
