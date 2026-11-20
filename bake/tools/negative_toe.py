#!/usr/bin/env python3
"""Print where each stock's negative stops responding in its toe, against a metered mid-gray.

Auto development counts light under five stops below mid-gray as five under (`ExposureAnalyzer
.floorStops`, and the roll's histograms from the same floor), so that sensor noise below the toe
does not move a dark frame's level. This reads the datasheet characteristic curves of the six
stocks and prints, per layer, in stops against the mid-gray the bake places at 11.49 / S, where
the curve's gradient first reaches a tenth and a quarter of its gradient at mid-gray, and where the
density first stands 0.02 and 0.05 above the curve's lowest value (docs/provenance.md):

    cd bake && PYTHONPATH=. ../.venv/bin/python tools/negative_toe.py
"""

import json
import math
from pathlib import Path

import numpy as np

from argent_bake.negative import mid_gray_log_exposure

STOCKS = ("portra400", "portra160", "portra800", "gold200", "ultramax400", "ektar100")
STOCKS_DIR = Path(__file__).resolve().parents[1] / "stocks"


def main() -> None:
    tenths = []
    print("| Stock | Layer | Curve starts | Gradient at mid-gray | 10% of it | 25% of it | +0.02 D | +0.05 D |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for name in STOCKS:
        profile = json.loads((STOCKS_DIR / f"{name}.json").read_text())
        curves = profile["characteristicCurves"]
        mid = mid_gray_log_exposure(profile["boxSpeed"])
        log_h = np.asarray(curves["logExposure"], dtype=float)
        for layer in ("red", "green", "blue"):
            density = np.asarray([np.nan if v is None else v for v in curves[layer]], dtype=float)
            ok = ~np.isnan(density)
            x, y = log_h[ok], density[ok]
            gradient = np.gradient(y, x)
            at_mid = float(np.interp(mid, x, gradient))
            stops = (x - mid) / math.log10(2.0)

            def first(mask: np.ndarray) -> float:
                index = np.flatnonzero(mask)
                return float(stops[index[0]]) if index.size else float("nan")

            tenth = first(gradient >= 0.1 * at_mid)
            tenths.append(tenth)
            print(f"| {name} | {layer} | {stops[0]:+.2f} | {at_mid:.3f} | {tenth:+.2f} | {first(gradient >= 0.25 * at_mid):+.2f}"
                  f" | {first(y - y.min() >= 0.02):+.2f} | {first(y - y.min() >= 0.05):+.2f} |")
    print(f"\nA tenth of the mid-gray gradient: {min(tenths):+.2f} to {max(tenths):+.2f} stops, median {float(np.median(tenths)):+.2f}")


if __name__ == "__main__":
    main()
