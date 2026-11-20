#!/usr/bin/env python3
"""Print a ColorChecker through each stock and the Endura print: chroma and colour error against the
scene, and what the profiles' couplers do to them.

The patches and the render are `argent_bake.checker`. Numbers in docs/research/film.md
section 4.2.

`--couplers c` replaces every off-diagonal coupler with c, to see what a given interimage strength
does; without it the profiles' own couplers are used.

    cd bake && PYTHONPATH=. ../.venv/bin/python tools/checker_through_stocks.py [--couplers 0.2]
"""

import argparse
import dataclasses
from pathlib import Path

import numpy as np

from argent_bake.checker import COLOURED, NEUTRAL_5, delta_e_2000, render, scene
from argent_bake.profile import load_profile

STOCKS = ["portra160", "portra400", "portra800", "ektar100", "gold200", "ultramax400", "portra160natural"]

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--couplers", type=float, default=None, help="every off-diagonal coupler set to this")
    args = parser.parse_args()
    rgb, scene_lab = scene()
    scene_chroma = np.hypot(scene_lab[COLOURED, 1], scene_lab[COLOURED, 2])
    root = Path(__file__).resolve().parents[1] / "stocks"
    print(f"scene: mean chroma of the 18 coloured patches {scene_chroma.mean():.1f}")
    print("stock         chroma / scene  mean  median   dE2000 to scene  median  p90   light skin L* a* b*      neutral 5 a* b*")
    for name in STOCKS:
        profile = load_profile(root / f"{name}.json")
        if args.couplers is not None:
            couplers = np.full((3, 3), args.couplers)
            np.fill_diagonal(couplers, 0.0)
            profile = dataclasses.replace(profile, couplers=couplers)
        lab = render(profile, rgb)
        ratio = np.hypot(lab[COLOURED, 1], lab[COLOURED, 2]) / scene_chroma
        error = delta_e_2000(scene_lab[COLOURED], lab[COLOURED])
        skin, gray = lab[1], lab[NEUTRAL_5]
        print(f"{name:12s}                {ratio.mean():.3f}  {np.median(ratio):.3f}                    "
              f"{np.median(error):5.2f} {np.percentile(error, 90):5.2f}   {skin[0]:5.1f} {skin[1]:5.1f} {skin[2]:5.1f}"
              f"        {gray[1]:+.2f} {gray[2]:+.2f}")


if __name__ == "__main__":
    main()
