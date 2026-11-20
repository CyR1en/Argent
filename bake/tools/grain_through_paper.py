#!/usr/bin/env python3
"""Print the grain numbers through the Endura Premier print model, as Markdown tables.

The M3 grain research measured tone gain and channel correlation through the synthetic
print; this re-runs them through the digitized paper for every stock, and adds the full
chain (sigma48 from each profile, r(p), s(net D)) at full size and at a 2048 px export:

    cd bake && PYTHONPATH=. ../.venv/bin/python tools/grain_through_paper.py

The synthetic stock through the synthetic paper is printed first, as the check that this
code reproduces the research agent's own numbers.
"""

from pathlib import Path

import numpy as np

from argent_bake import synthetic
from argent_bake.grain import net_density, print_noise, stock_sigma_density
from argent_bake.negative import MID_GRAY, density_range, dye_amounts
from argent_bake.paper import paper_named
from argent_bake.printing import GRAY_TARGET, Printer, calibrate
from argent_bake.profile import load_profile

STOCKS = ("portra400", "portra160", "portra800", "ektar100", "gold200", "ultramax400")
STOPS = (-6, -4, -2, -1, 0, 1, 2, 3, 4)
SIGMA = 0.01  # Status M density per layer for the tone-gain table, as the research used


def setup(profile, paper):
    printer = Printer(paper, profile.dyes, profile.base)
    return printer, calibrate(printer, dye_amounts(profile, np.full(3, MID_GRAY)), GRAY_TARGET)


def main() -> None:
    stocks_dir = Path(__file__).resolve().parents[1] / "stocks"
    endura = paper_named("kodak-endura-premier")
    profiles = {name: load_profile(stocks_dir / f"{name}.json") for name in STOCKS}

    print(f"Relative luminance noise sigma_Y / Y, percent, for sigma_D = {SIGMA} per layer, by scene stops from mid-gray\n")
    print("| Stock, paper | " + " | ".join(f"{s:+d}" for s in STOPS) + " | peak / +4 |")
    print("| --- |" + " --- |" * (len(STOPS) + 1))
    rows = [("synthetic, synthetic paper", synthetic.profile(), synthetic.paper())]
    rows += [(f"{profiles[name].display_name}, Endura", profiles[name], endura) for name in STOCKS]
    for label, profile, paper in rows:
        printer, filtration = setup(profile, paper)
        values = [print_noise(profile, printer, filtration, s, [SIGMA] * 3).relative_luminance_sigma * 100 for s in STOPS]
        print(f"| {label} | " + " | ".join(f"{v:.2f}" for v in values) + f" | {max(values) / values[-1]:.0f} |")

    print("\nOutput channel correlation from independent layer noise, at -2, 0 and +2 stops (R-G, G-B, R-B)\n")
    print("| Stock, paper | -2 | 0 | +2 |")
    print("| --- | --- | --- | --- |")
    for label, profile, paper in rows:
        printer, filtration = setup(profile, paper)
        cells = []
        for s in (-2, 0, 2):
            c = print_noise(profile, printer, filtration, s, [SIGMA] * 3).correlation
            cells.append(f"{c[0, 1]:+.2f}, {c[1, 2]:+.2f}, {c[0, 2]:+.2f}")
        print(f"| {label} | " + " | ".join(cells) + " |")

    print("\nFull chain: sigma48 x r(p) x s(net D), luminance noise percent per pixel at 7008 px unless named\n")
    print("| Stock | sigma48 R, G, B (x1e-3) | net D at mid-gray | -2 | 0 | +2 | 0 at 3504 px | 0 at 2048 px | dye sigma at 0, 7008 px, LUT units |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for name in STOCKS:
        profile = profiles[name]
        printer, filtration = setup(profile, endura)
        sigma48 = profile.grain_rms48
        cells = []
        for s in (-2, 0, 2):
            noise = print_noise(profile, printer, filtration, s, stock_sigma_density(profile, sigma48, s, 7008))
            cells.append(f"{noise.relative_luminance_sigma * 100:.1f}")
        mid = print_noise(profile, printer, filtration, 0, stock_sigma_density(profile, sigma48, 0, 7008))
        half = print_noise(profile, printer, filtration, 0, stock_sigma_density(profile, sigma48, 0, 3504))
        small = print_noise(profile, printer, filtration, 0, stock_sigma_density(profile, sigma48, 0, 2048))


        net = net_density(profile, 0)
        lut = mid.sigma_amounts / density_range(profile)
        print(f"| {profile.display_name} | {', '.join(f'{v * 1000:.1f}' for v in sigma48)} | "
              f"{', '.join(f'{v:.2f}' for v in net)} | {' | '.join(cells)} | "
              f"{half.relative_luminance_sigma * 100:.1f} | {small.relative_luminance_sigma * 100:.1f} | {', '.join(f'{v:.4f}' for v in lut)} |")


if __name__ == "__main__":
    main()
